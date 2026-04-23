#!/bin/bash
# =============================================================================
# Pravaha Platform - Backup Verification Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Enterprise-grade backup verification utility.
#   Validates backup integrity, file format, checksums, and optionally
#   tests restore to a temporary database.
#
# Usage:
#   sudo ./verify-backup.sh [OPTIONS]
#
# Options:
#   --file FILE        Verify specific backup file
#   --latest           Verify latest backup for all databases
#   --database DB      Verify backups for specific database
#   --tier TIER        Backup tier: daily, weekly, monthly (default: daily)
#   --all              Verify all backups
#   --test-restore     Test restore to temporary database
#   --max-age HOURS    Warn if backup is older than N hours (default: 48)
#   --json             Output results as JSON
#   --verbose, -v      Show detailed information
#   -h, --help         Show this help message
#
# Exit Codes:
#   0    All verifications passed
#   1    Verification failed
#   2    Backup too old (warning)
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_VERSION="1.0.0"
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
PRAVAHA_USER="${PRAVAHA_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"

# Options
VERIFY_FILE=""
VERIFY_LATEST=false
VERIFY_ALL=false
TARGET_DATABASE=""
BACKUP_TIER="daily"
TEST_RESTORE=false
MAX_AGE_HOURS=48
JSON_OUTPUT=false
VERBOSE=false

# Results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0
JSON_RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================
log_info() {
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    local check_name="$1"
    local message="$2"
    ((TOTAL_CHECKS++))
    ((PASSED_CHECKS++))
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${GREEN}[PASS]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"pass\", \"message\": \"$message\"}")
}

log_warn() {
    local check_name="$1"
    local message="$2"
    ((TOTAL_CHECKS++))
    ((WARNING_CHECKS++))
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${YELLOW}[WARN]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"warn\", \"message\": \"$message\"}")
}

log_fail() {
    local check_name="$1"
    local message="$2"
    ((TOTAL_CHECKS++))
    ((FAILED_CHECKS++))
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${RED}[FAIL]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"fail\", \"message\": \"$message\"}")
}

log_detail() {
    [[ "$VERBOSE" == "true" && "$JSON_OUTPUT" == "false" ]] && echo "       $1"
}

log_step() {
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "\n${BLUE}=== $1 ===${NC}"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Verify PostgreSQL backup integrity and optionally test restore.

OPTIONS:
    --file FILE        Verify specific backup file
    --latest           Verify latest backup for all databases
    --database DB      Verify backups for specific database only
    --tier TIER        Backup tier: daily, weekly, monthly (default: daily)
    --all              Verify all backups
    --test-restore     Test restore to temporary database (thorough but slow)
    --max-age HOURS    Warn if backup is older than N hours (default: 48)
    --json             Output results as JSON
    --verbose, -v      Show detailed information
    -h, --help         Show this help message

EXIT CODES:
    0    All verifications passed
    1    Verification failed (critical)
    2    Backup too old or warnings only

VERIFICATION CHECKS:
    1. File existence and accessibility
    2. File size validation (minimum size)
    3. Archive integrity (gzip/tar)
    4. PostgreSQL dump format validation
    5. Checksum verification (if .sha256 exists)
    6. Backup age check
    7. Optional: Test restore to temporary database

EXAMPLES:
    # Verify latest backup
    sudo $0 --latest

    # Verify specific file
    sudo $0 --file /var/backups/postgresql/daily/autoanalytics_20240101_020000.dump

    # Verify with test restore (recommended for critical backups)
    sudo $0 --latest --test-restore

    # Verify all backups
    sudo $0 --all

    # JSON output for monitoring
    sudo $0 --latest --json

MONITORING INTEGRATION:
    # Nagios/Icinga style check
    $0 --latest --json | jq -e '.failed == 0' && echo "OK" || echo "CRITICAL"

    # Cron job to verify backups
    0 6 * * * /opt/pravaha/scripts/verify-backup.sh --latest --max-age 24 >> /var/log/pravaha/backup-verify.log 2>&1

EOF
    exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --file)
                VERIFY_FILE="$2"
                shift 2
                ;;
            --latest)
                VERIFY_LATEST=true
                shift
                ;;
            --all)
                VERIFY_ALL=true
                shift
                ;;
            --database)
                TARGET_DATABASE="$2"
                shift 2
                ;;
            --tier)
                BACKUP_TIER="$2"
                shift 2
                ;;
            --test-restore)
                TEST_RESTORE=true
                shift
                ;;
            --max-age)
                MAX_AGE_HOURS="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Default to --latest if nothing specified
    if [[ -z "$VERIFY_FILE" && "$VERIFY_LATEST" == "false" && "$VERIFY_ALL" == "false" ]]; then
        VERIFY_LATEST=true
    fi
}

# =============================================================================
# Find Backup Files
# =============================================================================
find_latest_backup() {
    local db="$1"
    local tier="$2"
    local tier_dir="$BACKUP_DIR/$tier"

    if [[ ! -d "$tier_dir" ]]; then
        return 1
    fi

    # Find the most recent backup
    local latest=$(ls -t "$tier_dir/${db}_"*.dump 2>/dev/null | head -1)

    if [[ -z "$latest" ]]; then
        latest=$(ls -t "$tier_dir/${db}_"*.sql.gz 2>/dev/null | head -1)
    fi

    if [[ -z "$latest" ]]; then
        latest=$(ls -t "$tier_dir/${db}_"*.sql 2>/dev/null | head -1)
    fi

    echo "$latest"
}

find_all_backups() {
    local pattern="$1"

    find "$BACKUP_DIR" -name "$pattern" -type f 2>/dev/null | sort -r
}

# =============================================================================
# Verification Functions
# =============================================================================
verify_file_exists() {
    local file="$1"
    local basename=$(basename "$file")

    if [[ ! -f "$file" ]]; then
        log_fail "File Exists" "$basename: File not found"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        log_fail "File Readable" "$basename: File not readable"
        return 1
    fi

    log_pass "File Exists" "$basename"
    return 0
}

verify_file_size() {
    local file="$1"
    local basename=$(basename "$file")
    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    local file_size_human=$(du -h "$file" | cut -f1)

    log_detail "File size: $file_size_human ($file_size bytes)"

    # Minimum size check (1KB for dump files)
    local min_size=1024

    if [[ $file_size -lt $min_size ]]; then
        log_fail "File Size" "$basename: Suspiciously small ($file_size_human)"
        return 1
    fi

    log_pass "File Size" "$basename: $file_size_human"
    return 0
}

verify_archive_integrity() {
    local file="$1"
    local basename=$(basename "$file")

    case "$file" in
        *.dump)
            # Check PostgreSQL custom format header
            if head -c 5 "$file" | grep -q "PGDMP"; then
                log_pass "Format Check" "$basename: Valid PostgreSQL custom format"

                # Additional validation using pg_restore --list
                if sudo -u postgres pg_restore -l "$file" &>/dev/null; then
                    log_pass "Dump Integrity" "$basename: pg_restore can read TOC"

                    if [[ "$VERBOSE" == "true" ]]; then
                        local item_count=$(sudo -u postgres pg_restore -l "$file" 2>/dev/null | grep -c ";" || echo "0")
                        log_detail "Backup contains $item_count items"
                    fi
                else
                    log_fail "Dump Integrity" "$basename: pg_restore cannot read file"
                    return 1
                fi
            else
                log_fail "Format Check" "$basename: Invalid PostgreSQL dump format"
                return 1
            fi
            ;;
        *.sql.gz)
            # Verify gzip integrity
            if gzip -t "$file" 2>/dev/null; then
                log_pass "Gzip Integrity" "$basename: Valid gzip archive"

                # Check SQL content
                local sql_check=$(gunzip -c "$file" 2>/dev/null | head -100 | grep -cE "(CREATE|INSERT|SET)" || echo "0")
                if [[ $sql_check -gt 0 ]]; then
                    log_pass "SQL Content" "$basename: Contains SQL statements"
                else
                    log_warn "SQL Content" "$basename: No SQL statements found in header"
                fi
            else
                log_fail "Gzip Integrity" "$basename: Corrupted gzip archive"
                return 1
            fi
            ;;
        *.sql)
            # Check for SQL content
            local sql_check=$(head -100 "$file" | grep -cE "(CREATE|INSERT|SET)" || echo "0")
            if [[ $sql_check -gt 0 ]]; then
                log_pass "SQL Content" "$basename: Contains SQL statements"
            else
                log_warn "SQL Content" "$basename: No SQL statements found in header"
            fi
            ;;
        *.tar.gz)
            # Verify tar archive
            if tar -tzf "$file" &>/dev/null; then
                log_pass "Tar Integrity" "$basename: Valid tar.gz archive"
            else
                log_fail "Tar Integrity" "$basename: Corrupted tar archive"
                return 1
            fi
            ;;
        *)
            log_warn "Format Check" "$basename: Unknown file format"
            ;;
    esac

    return 0
}

verify_checksum() {
    local file="$1"
    local basename=$(basename "$file")
    local checksum_file="${file}.sha256"

    if [[ ! -f "$checksum_file" ]]; then
        log_warn "Checksum" "$basename: No checksum file found"
        return 0
    fi

    local dir=$(dirname "$file")
    cd "$dir"

    if sha256sum -c "$(basename "$checksum_file")" --status 2>/dev/null; then
        log_pass "Checksum" "$basename: SHA256 verified"
    else
        log_fail "Checksum" "$basename: SHA256 mismatch!"
        cd - > /dev/null
        return 1
    fi

    cd - > /dev/null
    return 0
}

verify_backup_age() {
    local file="$1"
    local basename=$(basename "$file")

    local file_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
    local current_time=$(date +%s)
    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))
    local age_days=$((age_hours / 24))

    local age_str
    if [[ $age_days -gt 0 ]]; then
        age_str="${age_days} days"
    else
        age_str="${age_hours} hours"
    fi

    log_detail "Backup age: $age_str"

    if [[ $age_hours -gt $MAX_AGE_HOURS ]]; then
        log_warn "Backup Age" "$basename: $age_str old (threshold: $MAX_AGE_HOURS hours)"
        return 2
    fi

    log_pass "Backup Age" "$basename: $age_str old"
    return 0
}

# =============================================================================
# Test Restore Function
# =============================================================================
test_restore_to_temp() {
    local file="$1"
    local basename=$(basename "$file")

    log_step "Testing restore to temporary database"

    # Only for .dump files
    if [[ ! "$file" =~ \.dump$ ]]; then
        log_warn "Test Restore" "Only .dump files can be test-restored"
        return 0
    fi

    # Check if PostgreSQL is running
    if ! sudo -u postgres pg_isready -q 2>/dev/null; then
        log_fail "Test Restore" "PostgreSQL is not running"
        return 1
    fi

    local test_db="pravaha_restore_test_$$"

    # Cleanup function for test_restore resources
    test_restore_cleanup() {
        log_info "Cleaning up test database..."
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $test_db;" &>/dev/null || true
    }
    trap test_restore_cleanup EXIT

    log_info "Creating temporary database: $test_db"

    # Create test database
    if ! sudo -u postgres psql -c "CREATE DATABASE $test_db OWNER $PRAVAHA_USER;" &>/dev/null; then
        log_fail "Test Restore" "Failed to create test database"
        return 1
    fi

    # Restore to test database
    log_info "Restoring backup to test database..."
    local restore_result=0

    if sudo -u postgres pg_restore -d "$test_db" --no-owner --no-privileges "$file" 2>/dev/null; then
        restore_result=0
    else
        # pg_restore often returns non-zero even on success
        restore_result=$?
    fi

    # Verify restore
    local table_count=$(sudo -u postgres psql -d "$test_db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null || echo "0")

    if [[ $table_count -gt 0 ]]; then
        log_pass "Test Restore" "$basename: Restored $table_count tables successfully"
        log_detail "Tables restored: $table_count"

        # Count rows in some tables
        if [[ "$VERBOSE" == "true" ]]; then
            local key_tables=("users" "organizations" "projects")
            for table in "${key_tables[@]}"; do
                local row_count=$(sudo -u postgres psql -d "$test_db" -tAc "SELECT count(*) FROM $table" 2>/dev/null || echo "N/A")
                if [[ "$row_count" != "N/A" && "$row_count" != "0" ]]; then
                    log_detail "  $table: $row_count rows"
                fi
            done
        fi
    else
        log_warn "Test Restore" "$basename: No tables restored (may be schema-only or empty backup)"
    fi

    # Cleanup explicitly and clear trap
    test_restore_cleanup
    trap - EXIT

    return 0
}

# =============================================================================
# Verify Single Backup
# =============================================================================
verify_backup() {
    local file="$1"
    local basename=$(basename "$file")

    [[ "$JSON_OUTPUT" == "false" ]] && echo ""
    log_step "Verifying: $basename"

    local failed=0

    # Run all checks
    verify_file_exists "$file" || ((failed++))
    verify_file_size "$file" || ((failed++))
    verify_archive_integrity "$file" || ((failed++))
    verify_checksum "$file" || ((failed++))
    verify_backup_age "$file"  # Don't count as failure

    # Test restore if requested
    if [[ "$TEST_RESTORE" == "true" && $failed -eq 0 ]]; then
        test_restore_to_temp "$file" || ((failed++))
    fi

    return $failed
}

# =============================================================================
# Output Functions
# =============================================================================
output_json() {
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"backup_dir\": \"$BACKUP_DIR\","
    echo "  \"tier\": \"$BACKUP_TIER\","
    echo "  \"results\": {"
    echo "    \"total\": $TOTAL_CHECKS,"
    echo "    \"passed\": $PASSED_CHECKS,"
    echo "    \"warnings\": $WARNING_CHECKS,"
    echo "    \"failed\": $FAILED_CHECKS"
    echo "  },"
    echo "  \"status\": \"$([[ $FAILED_CHECKS -eq 0 ]] && ([[ $WARNING_CHECKS -eq 0 ]] && echo "ok" || echo "warning") || echo "failed")\","
    echo "  \"checks\": ["
    local first=true
    for result in "${JSON_RESULTS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo -n "    $result"
    done
    echo ""
    echo "  ]"
    echo "}"
}

output_summary() {
    echo ""
    echo "=============================================="
    echo "Backup Verification Summary"
    echo "=============================================="
    echo ""
    echo -e "  Total Checks: $TOTAL_CHECKS"
    echo -e "  Passed:       ${GREEN}$PASSED_CHECKS${NC}"
    echo -e "  Warnings:     ${YELLOW}$WARNING_CHECKS${NC}"
    echo -e "  Failed:       ${RED}$FAILED_CHECKS${NC}"
    echo ""

    if [[ $FAILED_CHECKS -eq 0 && $WARNING_CHECKS -eq 0 ]]; then
        echo -e "${GREEN}All backup verifications passed!${NC}"
    elif [[ $FAILED_CHECKS -eq 0 ]]; then
        echo -e "${YELLOW}Backups verified with warnings${NC}"
    else
        echo -e "${RED}Backup verification failed!${NC}"
        echo ""
        echo "Recommended actions:"
        echo "  1. Check backup logs: /var/log/pravaha/backup-*.log"
        echo "  2. Run a new backup: ./backup.sh"
        echo "  3. Verify disk space: df -h $BACKUP_DIR"
    fi
    echo ""
}

# =============================================================================
# List Backups
# =============================================================================
list_backups() {
    echo ""
    echo "=============================================="
    echo "Backup Inventory: $BACKUP_DIR"
    echo "=============================================="
    echo ""

    for tier in daily weekly monthly; do
        local tier_dir="$BACKUP_DIR/$tier"
        if [[ -d "$tier_dir" ]]; then
            echo "=== $tier ==="
            local count=0
            for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
                local files=$(ls -t "$tier_dir/${db}_"*.dump 2>/dev/null || true)
                for file in $files; do
                    local size=$(du -h "$file" | cut -f1)
                    local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
                    local age=$((( $(date +%s) - mtime ) / 3600))
                    echo "  $(basename "$file"): $size (${age}h ago)"
                    ((count++))
                done
            done
            if [[ $count -eq 0 ]]; then
                echo "  (no backups)"
            fi
            echo ""
        fi
    done

    # Basebackups
    if [[ -d "$BACKUP_DIR/basebackup" ]]; then
        echo "=== basebackup ==="
        ls -dt "$BACKUP_DIR/basebackup"/*/ 2>/dev/null | head -5 | while read dir; do
            local size=$(du -sh "$dir" | cut -f1)
            echo "  $(basename "$dir"): $size"
        done
        echo ""
    fi

    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo "Total backup storage: $total_size"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo ""
        echo "=============================================="
        echo "Pravaha Backup Verification"
        echo "Version: $SCRIPT_VERSION"
        echo "=============================================="
    fi

    # Verify specific file
    if [[ -n "$VERIFY_FILE" ]]; then
        verify_backup "$VERIFY_FILE"

    # Verify latest backups
    elif [[ "$VERIFY_LATEST" == "true" ]]; then
        local databases=("$PLATFORM_DB" "$SUPERSET_DB")

        if [[ -n "$TARGET_DATABASE" ]]; then
            databases=("$TARGET_DATABASE")
        fi

        for db in "${databases[@]}"; do
            local latest=$(find_latest_backup "$db" "$BACKUP_TIER")
            if [[ -n "$latest" ]]; then
                verify_backup "$latest"
            else
                log_fail "Latest Backup" "$db: No backups found in tier '$BACKUP_TIER'"
            fi
        done

    # Verify all backups
    elif [[ "$VERIFY_ALL" == "true" ]]; then
        [[ "$JSON_OUTPUT" == "false" ]] && list_backups

        for tier in daily weekly monthly; do
            local tier_dir="$BACKUP_DIR/$tier"
            if [[ -d "$tier_dir" ]]; then
                for file in $(ls -t "$tier_dir"/*.dump 2>/dev/null | head -10); do
                    verify_backup "$file"
                done
            fi
        done
    fi

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi

    # Exit code
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        exit 1
    elif [[ $WARNING_CHECKS -gt 0 ]]; then
        exit 2
    else
        exit 0
    fi
}

main "$@"
