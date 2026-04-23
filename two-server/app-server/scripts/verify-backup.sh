#!/bin/bash
# =============================================================================
# Pravaha Platform - Backup Verification Utility
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Validates backup integrity and tests restore capability for app-only backups.
#   For two-server deployments, this verifies configuration and volume backups.
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
# Architecture Notes:
#   - Verifies app server backups (configs, volumes)
#   - Database verification requires access to database server
#   - Test restore validates volume integrity without affecting running services
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "$SCRIPT_DIR")}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"

# Configuration
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

# =============================================================================
# Parse Arguments
# =============================================================================
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
            echo ""
            echo "Note: For two-server deployments, this verifies app server"
            echo "      components only (configs, volumes). Database backup"
            echo "      verification should be done on the database server."
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

    # ==========================================================================
    # Configuration Verification
    # ==========================================================================
    local config_dir="$backup_dir/configs"
    if [[ ! -d "$config_dir" ]]; then
        config_dir="$backup_dir"  # Fallback for older format
    fi

    log_info "  Checking configuration files..."

    # Check .env
    if [[ -f "$config_dir/.env" ]]; then
        local env_lines=$(wc -l < "$config_dir/.env" | tr -d '[:space:]')
        log_success "    .env: Found ($env_lines lines)"

        # Verify critical settings exist
        if grep -q "POSTGRES_HOST" "$config_dir/.env"; then
            log_verbose "      POSTGRES_HOST configured (external DB)"
        fi
        if grep -q "JWT_SECRET" "$config_dir/.env"; then
            log_verbose "      JWT_SECRET configured"
        fi
    else
        log_warning "    .env: Missing"
    fi

    # Check docker-compose files
    local compose_count=$(ls "$config_dir"/docker-compose*.yml 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ $compose_count -gt 0 ]]; then
        log_success "    Docker Compose files: $compose_count found"
    else
        log_verbose "    Docker Compose files: None included"
    fi

    # Check NGINX config
    if [[ -d "$config_dir/nginx" ]]; then
        log_success "    NGINX config: Found"
    else
        log_verbose "    NGINX config: Not included"
    fi

    # Check SSL certificates
    if [[ -d "$config_dir/ssl" ]]; then
        local cert_count=$(ls "$config_dir/ssl"/*.pem 2>/dev/null | wc -l | tr -d '[:space:]')
        log_success "    SSL certificates: $cert_count files found"
    else
        log_verbose "    SSL certificates: Not included"
    fi

    # Check audit keys
    if [[ -f "$config_dir/audit-private.pem" ]]; then
        log_success "    Audit keys: Found"
    else
        log_verbose "    Audit keys: Not included"
    fi

    # ==========================================================================
    # Volume Verification
    # ==========================================================================
    local volumes_dir="$backup_dir/volumes"

    if [[ -d "$volumes_dir" ]]; then
        log_info "  Checking volume backups..."

        local volumes_found=0
        local volumes_verified=0

        # Check all expected volume backups (including Jupyter)
        for volume in "redis_data.tar.gz" "superset_home.tar.gz" "ml_models.tar.gz" "ml_logs.tar.gz" "training_data.tar.gz" "uploads.tar.gz" "app_logs.tar.gz" "nginx_logs.tar.gz" "celery_beat_schedule.tar.gz" "ml_storage.tar.gz" "plugins.tar.gz" "solution_packs.tar.gz" "jupyter_notebooks.tar.gz" "jupyter_data.tar.gz"; do
            if [[ -f "$volumes_dir/$volume" ]]; then
                volumes_found=$((volumes_found + 1))
                local vol_name=$(basename "$volume" .tar.gz)
                local vol_size=$(du -h "$volumes_dir/$volume" | cut -f1)

                # Verify volume archive integrity
                if gzip -t "$volumes_dir/$volume" 2>/dev/null; then
                    log_success "    Volume $vol_name: OK ($vol_size)"
                    volumes_verified=$((volumes_verified + 1))
                else
                    log_error "    Volume $vol_name: CORRUPTED"
                fi
            fi
        done

        # Also check for any unexpected volume files
        for vol_file in "$volumes_dir"/*.tar.gz; do
            if [[ -f "$vol_file" ]]; then
                local vol_basename=$(basename "$vol_file")
                case "$vol_basename" in
                    redis_data.tar.gz|superset_home.tar.gz|ml_models.tar.gz|ml_logs.tar.gz|training_data.tar.gz|uploads.tar.gz|app_logs.tar.gz|nginx_logs.tar.gz|celery_beat_schedule.tar.gz|ml_storage.tar.gz|plugins.tar.gz|solution_packs.tar.gz|jupyter_notebooks.tar.gz|jupyter_data.tar.gz)
                        ;; # Already checked above
                    *)
                        volumes_found=$((volumes_found + 1))
                        local vol_name=$(basename "$vol_file" .tar.gz)
                        local vol_size=$(du -h "$vol_file" | cut -f1)
                        if gzip -t "$vol_file" 2>/dev/null; then
                            log_success "    Volume $vol_name: OK ($vol_size) [extra]"
                            volumes_verified=$((volumes_verified + 1))
                        else
                            log_error "    Volume $vol_name: CORRUPTED [extra]"
                        fi
                        ;;
                esac
            fi
        done

        if [[ $volumes_found -eq 0 ]]; then
            log_warning "    No volume backups found"
        else
            log_success "  Volume backups: $volumes_verified/$volumes_found verified"
        fi
    else
        log_warning "  Volume backups: Directory not found"
    fi

    # ==========================================================================
    # Database Backup Check (informational only)
    # ==========================================================================
    local db_dir="$backup_dir/database"

    if [[ -d "$db_dir" ]]; then
        log_info "  Checking database backups (informational)..."

        local db_dumps=$(ls "$db_dir"/*.dump 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ $db_dumps -gt 0 ]]; then
            log_success "    Database dumps: $db_dumps found"

            # Check each dump
            for dump_file in "$db_dir"/*.dump; do
                if [[ -f "$dump_file" ]]; then
                    local dump_name=$(basename "$dump_file")
                    local dump_size=$(du -h "$dump_file" | cut -f1)

                    # Verify dump format
                    if head -c 5 "$dump_file" | grep -q "PGDMP"; then
                        log_success "      $dump_name: PostgreSQL custom format ($dump_size)"
                    else
                        log_warning "      $dump_name: Unknown format ($dump_size)"
                    fi
                fi
            done

            log_warning "    Note: Database restore must be performed on the database server"
        else
            log_verbose "    No database dumps (app-only backup)"
        fi
    else
        log_verbose "  Database backups: Not included (app-only backup)"
    fi

    rm -rf "$temp_dir"

    return 0
}

# =============================================================================
# Test Restore (Dry Run for Volumes)
# =============================================================================
test_restore() {
    local backup_file="$1"

    log_info "Testing restore capability (dry run)..."

    # Extract backup
    local temp_dir=$(mktemp -d)
    local test_volume="pravaha-restore-test-$$"

    # Cleanup function for test_restore resources
    test_restore_cleanup() {
        docker volume rm "$test_volume" 2>/dev/null || true
        rm -rf "$temp_dir" 2>/dev/null || true
    }
    trap test_restore_cleanup EXIT

    tar -xzf "$backup_file" -C "$temp_dir"
    local backup_dir="$temp_dir/$(ls "$temp_dir" | head -1)"
    local volumes_dir="$backup_dir/volumes"

    if [[ ! -d "$volumes_dir" ]]; then
        log_warning "No volumes directory found in backup"
        log_info "Config-only backup - restore would copy configuration files"
        test_restore_cleanup
        trap - EXIT
        return 0
    fi

    # Test volume restoration in isolated container
    log_info "Testing volume restore in isolated container..."

    local all_passed=true

    for vol_file in "$volumes_dir"/*.tar.gz; do
        if [[ -f "$vol_file" ]]; then
            local vol_name=$(basename "$vol_file" .tar.gz)
            log_info "  Testing restore of volume: $vol_name"

            # Create test volume
            docker volume create "$test_volume" > /dev/null 2>&1

            # Try to extract volume content to test volume
            if docker run --rm \
                -v "$test_volume:/target" \
                -v "$(dirname "$vol_file"):/backup:ro" \
                alpine sh -c "tar xzf /backup/$(basename "$vol_file") -C /target 2>/dev/null" 2>/dev/null; then

                # Verify some content was extracted
                local file_count=$(docker run --rm -v "$test_volume:/target" alpine sh -c "find /target -type f | wc -l" 2>/dev/null | tr -d '[:space:]')

                if [[ "$file_count" -gt 0 ]]; then
                    log_success "    $vol_name: Restore test PASSED ($file_count files)"
                else
                    log_warning "    $vol_name: Restored but empty (may be expected)"
                fi
            else
                log_error "    $vol_name: Restore test FAILED"
                all_passed=false
            fi

            # Cleanup test volume
            docker volume rm "$test_volume" > /dev/null 2>&1 || true
        fi
    done

    # Cleanup
    test_restore_cleanup
    trap - EXIT

    if [[ "$all_passed" == "true" ]]; then
        log_success "Restore test completed successfully"
        return 0
    else
        log_error "Some restore tests failed"
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
    echo "Deployment:       Two-Server (App Server)"
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

        # Determine type from filename or contents
        local type="standard"
        if [[ "$filename" == *"volumes"* ]]; then
            type="volumes-only"
        elif [[ "$filename" == *"configs"* ]]; then
            type="configs-only"
        fi

        # Check if it includes database
        if tar -tzf "$backup" 2>/dev/null | grep -q "database/"; then
            type="full+db"
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

    # Database backup note
    log_info "Note: Database backups should be verified on the database server."
}

# =============================================================================
# Verify All Backups
# =============================================================================
verify_all_backups() {
    echo "=============================================="
    echo "Pravaha Platform - Verify All Backups"
    echo "=============================================="
    echo "Deployment: Two-Server (App Server)"
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
echo "Deployment: Two-Server (App Server)"
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
echo ""
if tar -tzf "$VERIFY_FILE" 2>/dev/null | grep -q "database/"; then
    log_warning "This backup contains database dumps."
    log_warning "Database restore must be performed on the database server."
fi
