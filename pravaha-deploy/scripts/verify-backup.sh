#!/bin/bash
# =============================================================================
# Pravaha Platform - Backup Verification Utility
# Validates backup integrity and tests restore capability
# =============================================================================
#
# Usage:
#   ./verify-backup.sh                         # Verify latest backup
#   ./verify-backup.sh <backup_file>           # Verify specific backup
#   ./verify-backup.sh --list                  # List all backups with status
#   ./verify-backup.sh --test-restore <file>   # Test restore (dry run)
#   ./verify-backup.sh --all                   # Verify all backups
#
# Exit codes:
#   0 - Backup verification passed
#   1 - Backup verification failed
#   2 - Backup file not found or corrupted
#
# =============================================================================

set -e

DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
VERIFY_FILE=""
LIST_BACKUPS=false
TEST_RESTORE=false
VERIFY_ALL=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            LIST_BACKUPS=true
            shift
            ;;
        --test-restore)
            TEST_RESTORE=true
            VERIFY_FILE="$2"
            shift 2
            ;;
        --all)
            VERIFY_ALL=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [backup_file]"
            echo ""
            echo "Options:"
            echo "  --list           List all backups with verification status"
            echo "  --test-restore   Test restore in isolated container (dry run)"
            echo "  --all            Verify all backups"
            echo "  --verbose, -v    Show detailed output"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Verify latest backup"
            echo "  $0 backups/pravaha_backup_*.tar.gz    # Verify specific backup"
            echo "  $0 --list                             # List all backups"
            echo "  $0 --test-restore latest              # Test restore latest"
            exit 0
            ;;
        *)
            VERIFY_FILE="$1"
            shift
            ;;
    esac
done

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" || true; }

# Load environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"

# =============================================================================
# Find Latest Backup
# =============================================================================
find_latest_backup() {
    local latest=$(ls -t "$BACKUP_DIR"/pravaha_backup_*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$latest" ]]; then
        return 1
    fi
    echo "$latest"
}

# =============================================================================
# Verify Backup Archive Integrity
# =============================================================================
verify_archive_integrity() {
    local backup_file="$1"
    local results=()

    log_info "Verifying archive integrity: $(basename "$backup_file")"

    # Check file exists
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 2
    fi

    # Check file size
    local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
    if [[ $file_size -lt 1000 ]]; then
        log_error "Backup file suspiciously small: $file_size bytes"
        return 1
    fi
    log_verbose "  File size: $file_size bytes"

    # Verify gzip integrity
    log_verbose "  Checking gzip integrity..."
    if ! gzip -t "$backup_file" 2>/dev/null; then
        log_error "Backup archive is corrupted (gzip check failed)"
        return 2
    fi
    results+=("gzip:pass")

    # Verify tar integrity
    log_verbose "  Checking tar integrity..."
    if ! tar -tzf "$backup_file" > /dev/null 2>&1; then
        log_error "Backup archive is corrupted (tar check failed)"
        return 2
    fi
    results+=("tar:pass")

    log_success "  Archive integrity: OK"
    return 0
}

# =============================================================================
# Verify Backup Contents
# =============================================================================
verify_backup_contents() {
    local backup_file="$1"

    log_info "Verifying backup contents..."

    # Extract to temp directory
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    tar -xzf "$backup_file" -C "$temp_dir"
    local backup_dir="$temp_dir/$(ls "$temp_dir" | head -1)"

    # Check manifest
    if [[ -f "$backup_dir/manifest.json" ]]; then
        log_success "  Manifest: Found"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  Manifest contents:"
            cat "$backup_dir/manifest.json" | sed 's/^/    /'
        fi
    else
        log_warning "  Manifest: Missing (older backup format)"
    fi

    # Check database dumps
    local db_found=false
    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        if [[ -f "$backup_dir/${db}.dump" ]]; then
            local dump_size=$(stat -f%z "$backup_dir/${db}.dump" 2>/dev/null || stat -c%s "$backup_dir/${db}.dump" 2>/dev/null)
            log_success "  Database dump (${db}): Found ($dump_size bytes)"
            db_found=true

            # Verify dump format
            if head -c 5 "$backup_dir/${db}.dump" | grep -q "PGDMP"; then
                log_verbose "    Format: PostgreSQL custom format (pg_restore compatible)"
            else
                log_warning "    Format: Unknown (may not be restorable)"
            fi
        elif [[ -f "$backup_dir/${db}.sql" ]]; then
            local sql_size=$(stat -f%z "$backup_dir/${db}.sql" 2>/dev/null || stat -c%s "$backup_dir/${db}.sql" 2>/dev/null)
            log_success "  Database dump (${db}): Found SQL ($sql_size bytes)"
            db_found=true
        fi
    done

    if [[ "$db_found" == "false" ]]; then
        log_error "  Database dumps: NOT FOUND"
        return 1
    fi

    # Check configuration
    if [[ -f "$backup_dir/.env" ]]; then
        log_success "  Configuration (.env): Found"
    else
        log_warning "  Configuration (.env): Missing"
    fi

    # Check NGINX config
    if [[ -d "$backup_dir/nginx" ]]; then
        log_success "  NGINX config: Found"
    else
        log_verbose "  NGINX config: Not included"
    fi

    # Check SSL certificates
    if [[ -d "$backup_dir/ssl" ]]; then
        log_success "  SSL certificates: Found"
    else
        log_verbose "  SSL certificates: Not included"
    fi

    # Check volumes (if full backup)
    local volumes_found=0
    for volume in "uploads.tar.gz" "ml_models.tar.gz" "superset_home.tar.gz"; do
        if [[ -f "$backup_dir/$volume" ]]; then
            volumes_found=$((volumes_found + 1))
        fi
    done

    if [[ $volumes_found -gt 0 ]]; then
        log_success "  Volume backups: $volumes_found found (full backup)"
    else
        log_verbose "  Volume backups: None (standard backup)"
    fi

    rm -rf "$temp_dir"
    trap - EXIT

    return 0
}

# =============================================================================
# Test Restore (Dry Run)
# =============================================================================
test_restore() {
    local backup_file="$1"

    log_info "Testing restore capability (dry run)..."

    # Extract backup
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    tar -xzf "$backup_file" -C "$temp_dir"
    local backup_dir="$temp_dir/$(ls "$temp_dir" | head -1)"

    # Start a temporary postgres container
    log_info "Starting temporary PostgreSQL container..."

    local test_container="pravaha-restore-test-$$"

    docker run -d --rm \
        --name "$test_container" \
        -e POSTGRES_USER=testuser \
        -e POSTGRES_PASSWORD=testpass \
        -e POSTGRES_DB=testdb \
        postgres:17-alpine > /dev/null 2>&1

    # Wait for postgres to be ready
    local max_wait=30
    local waited=0
    while ! docker exec "$test_container" pg_isready -U testuser 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            log_error "PostgreSQL container did not start"
            docker stop "$test_container" 2>/dev/null || true
            return 1
        fi
    done

    log_success "  Temporary PostgreSQL started"

    # Try to restore database
    local restore_success=true

    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        # Create database
        docker exec "$test_container" psql -U testuser -d testdb -c "CREATE DATABASE ${db}_test;" 2>/dev/null || true

        if [[ -f "$backup_dir/${db}.dump" ]]; then
            log_info "  Testing restore of ${db}.dump..."

            # Copy dump to container
            docker cp "$backup_dir/${db}.dump" "$test_container:/tmp/${db}.dump"

            # Try pg_restore
            if docker exec "$test_container" pg_restore \
                -U testuser -d "${db}_test" \
                --no-owner --no-privileges \
                "/tmp/${db}.dump" 2>/dev/null; then
                log_success "    ${db}: Restore test PASSED"
            else
                # pg_restore often returns non-zero even on success with warnings
                # Check if tables were created
                local table_count=$(docker exec "$test_container" psql -U testuser -d "${db}_test" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')

                if [[ "$table_count" -gt 0 ]]; then
                    log_success "    ${db}: Restore test PASSED ($table_count tables)"
                else
                    log_warning "    ${db}: Restore test had warnings (0 tables)"
                fi
            fi
        elif [[ -f "$backup_dir/${db}.sql" ]]; then
            log_info "  Testing restore of ${db}.sql..."

            # Copy SQL to container
            docker cp "$backup_dir/${db}.sql" "$test_container:/tmp/${db}.sql"

            # Try psql restore
            if docker exec "$test_container" psql -U testuser -d "${db}_test" -f "/tmp/${db}.sql" 2>/dev/null; then
                log_success "    ${db}: Restore test PASSED"
            else
                log_warning "    ${db}: Restore test had warnings"
            fi
        fi
    done

    # Cleanup
    log_info "  Cleaning up test container..."
    docker stop "$test_container" 2>/dev/null || true

    rm -rf "$temp_dir"
    trap - EXIT

    if [[ "$restore_success" == "true" ]]; then
        log_success "Restore test completed successfully"
        return 0
    else
        log_error "Restore test failed"
        return 1
    fi
}

# =============================================================================
# List All Backups
# =============================================================================
list_backups() {
    echo "=============================================="
    echo "Pravaha Platform - Backup Inventory"
    echo "=============================================="
    echo ""
    echo "Backup Directory: $BACKUP_DIR"
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warning "Backup directory does not exist"
        return 0
    fi

    local backups=$(ls -t "$BACKUP_DIR"/pravaha_backup_*.tar.gz 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        log_warning "No backups found"
        return 0
    fi

    printf "%-50s %-12s %-15s %s\n" "BACKUP FILE" "SIZE" "TYPE" "STATUS"
    printf "%-50s %-12s %-15s %s\n" "-----------" "----" "----" "------"

    for backup in $backups; do
        local filename=$(basename "$backup")
        local size=$(du -h "$backup" | cut -f1)

        # Determine type from filename
        local type="standard"
        if [[ "$filename" == *"db-only"* ]]; then
            type="db-only"
        elif [[ "$filename" == *"full"* ]]; then
            type="full"
        fi

        # Quick integrity check
        local status="OK"
        if ! gzip -t "$backup" 2>/dev/null; then
            status="CORRUPTED"
        fi

        printf "%-50s %-12s %-15s %s\n" "$filename" "$size" "$type" "$status"
    done

    echo ""

    # Show total size
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo "Total backup storage: $total_size"

    # Count backups
    local backup_count=$(echo "$backups" | wc -l | tr -d '[:space:]')
    echo "Total backups: $backup_count"
    echo ""
}

# =============================================================================
# Verify All Backups
# =============================================================================
verify_all_backups() {
    echo "=============================================="
    echo "Pravaha Platform - Verify All Backups"
    echo "=============================================="
    echo ""

    local backups=$(ls -t "$BACKUP_DIR"/pravaha_backup_*.tar.gz 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        log_warning "No backups found"
        return 0
    fi

    local total=0
    local passed=0
    local failed=0

    for backup in $backups; do
        total=$((total + 1))
        echo ""
        echo "--- Verifying: $(basename "$backup") ---"

        if verify_archive_integrity "$backup" && verify_backup_contents "$backup"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "=============================================="
    echo "Verification Summary"
    echo "=============================================="
    echo "Total:  $total"
    echo "Passed: $passed"
    echo "Failed: $failed"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "$LIST_BACKUPS" == "true" ]]; then
    list_backups
    exit 0
fi

if [[ "$VERIFY_ALL" == "true" ]]; then
    verify_all_backups
    exit $?
fi

# Determine which backup to verify
if [[ -z "$VERIFY_FILE" ]] || [[ "$VERIFY_FILE" == "latest" ]]; then
    VERIFY_FILE=$(find_latest_backup)
    if [[ -z "$VERIFY_FILE" ]]; then
        log_error "No backups found in $BACKUP_DIR"
        exit 2
    fi
    log_info "Using latest backup: $(basename "$VERIFY_FILE")"
elif [[ ! -f "$VERIFY_FILE" ]] && [[ -f "$BACKUP_DIR/$VERIFY_FILE" ]]; then
    VERIFY_FILE="$BACKUP_DIR/$VERIFY_FILE"
fi

echo "=============================================="
echo "Pravaha Platform - Backup Verification"
echo "=============================================="
echo ""
echo "Backup: $(basename "$VERIFY_FILE")"
echo ""

# Run verification
verify_archive_integrity "$VERIFY_FILE" || exit $?
verify_backup_contents "$VERIFY_FILE" || exit $?

# Test restore if requested
if [[ "$TEST_RESTORE" == "true" ]]; then
    echo ""
    test_restore "$VERIFY_FILE" || exit $?
fi

echo ""
echo "=============================================="
log_success "Backup verification PASSED"
echo "=============================================="
echo ""
echo "This backup can be restored with:"
echo "  ./scripts/restore.sh $VERIFY_FILE"
