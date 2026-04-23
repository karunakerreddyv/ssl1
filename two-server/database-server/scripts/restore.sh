#!/bin/bash
# =============================================================================
# Pravaha Platform - PostgreSQL Restore Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Enterprise-grade restore script for PostgreSQL databases.
#   Supports pg_dump files (.dump, .sql, .sql.gz) and pg_basebackup restoration.
#   Includes pre-restore validation and post-restore verification.
#
# Usage:
#   sudo ./restore.sh --file <backup_file> [OPTIONS]
#   sudo ./restore.sh --database <db> --latest [OPTIONS]
#
# Options:
#   --file FILE        Path to backup file to restore
#   --database DB      Target database (required for dump restore)
#   --latest           Restore from latest backup for specified database
#   --tier TIER        Backup tier: daily, weekly, monthly (default: daily)
#   --create-db        Create database if it doesn't exist
#   --drop-existing    Drop existing objects before restore (DANGEROUS)
#   --no-owner         Skip restoring object ownership
#   --no-privileges    Skip restoring privileges
#   --jobs N           Number of parallel jobs (default: 4)
#   --dry-run          Show what would be done without executing
#   --force            Skip confirmation prompts
#   -h, --help         Show this help message
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
BACKUP_FILE=""
TARGET_DATABASE=""
RESTORE_LATEST=false
BACKUP_TIER="daily"
CREATE_DB=false
DROP_EXISTING=false
NO_OWNER=false
NO_PRIVILEGES=false
PARALLEL_JOBS=4
DRY_RUN=false
FORCE=false

# Logging
LOG_DIR="/var/log/pravaha"
LOG_FILE="$LOG_DIR/restore-$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================
log_init() {
    mkdir -p "$LOG_DIR"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    echo ""
    echo "=============================================="
    echo "Restore started at $(date)"
    echo "=============================================="
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 --file <backup_file> --database <db> [OPTIONS]
       $0 --database <db> --latest [OPTIONS]

Enterprise-grade PostgreSQL restore script.

REQUIRED:
    --file FILE        Path to backup file to restore
    --database DB      Target database name

OPTIONS:
    --latest           Restore from latest backup for specified database
    --tier TIER        Backup tier: daily, weekly, monthly (default: daily)
    --create-db        Create database if it doesn't exist
    --drop-existing    Drop existing objects before restore (DANGEROUS)
    --no-owner         Skip restoring object ownership
    --no-privileges    Skip restoring privileges
    --jobs N           Number of parallel jobs (default: 4)
    --dry-run          Show what would be done without executing
    --force            Skip confirmation prompts
    -h, --help         Show this help message

SUPPORTED BACKUP FORMATS:
    .dump       PostgreSQL custom format (pg_dump -Fc)
    .sql        Plain SQL dump
    .sql.gz     Gzipped SQL dump
    .tar.gz     pg_basebackup archive (requires special handling)

EXAMPLES:
    # Restore from specific file
    sudo $0 --file /var/backups/postgresql/daily/autoanalytics_20240101_020000.dump --database autoanalytics

    # Restore latest backup
    sudo $0 --database autoanalytics --latest

    # Restore from weekly backup tier
    sudo $0 --database autoanalytics --latest --tier weekly

    # Restore with database creation
    sudo $0 --file backup.dump --database autoanalytics --create-db

    # Dry run to see what would happen
    sudo $0 --file backup.dump --database autoanalytics --dry-run

SAFETY:
    - By default, existing data is preserved (may cause conflicts)
    - Use --drop-existing to clear database first (DATA LOSS WARNING)
    - Always verify backups before restoring to production
    - Consider restoring to a test database first

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
                BACKUP_FILE="$2"
                shift 2
                ;;
            --database)
                TARGET_DATABASE="$2"
                shift 2
                ;;
            --latest)
                RESTORE_LATEST=true
                shift
                ;;
            --tier)
                BACKUP_TIER="$2"
                shift 2
                ;;
            --create-db)
                CREATE_DB=true
                shift
                ;;
            --drop-existing)
                DROP_EXISTING=true
                shift
                ;;
            --no-owner)
                NO_OWNER=true
                shift
                ;;
            --no-privileges)
                NO_PRIVILEGES=true
                shift
                ;;
            --jobs)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$TARGET_DATABASE" ]]; then
        log_error "--database is required"
        exit 1
    fi

    if [[ "$RESTORE_LATEST" == "false" && -z "$BACKUP_FILE" ]]; then
        log_error "Either --file or --latest is required"
        exit 1
    fi
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_postgresql() {
    if ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL is not running"
        exit 1
    fi

    if ! sudo -u postgres pg_isready -q 2>/dev/null; then
        log_error "PostgreSQL is not accepting connections"
        exit 1
    fi

    log_info "PostgreSQL is running and accepting connections"
}

# =============================================================================
# Find Latest Backup
# =============================================================================
find_latest_backup() {
    local db="$1"
    local tier="$2"
    local tier_dir="$BACKUP_DIR/$tier"

    if [[ ! -d "$tier_dir" ]]; then
        log_error "Backup tier directory not found: $tier_dir"
        return 1
    fi

    # Find the most recent .dump file for the database
    local latest=$(ls -t "$tier_dir/${db}_"*.dump 2>/dev/null | head -1)

    if [[ -z "$latest" ]]; then
        # Fall back to SQL dumps
        latest=$(ls -t "$tier_dir/${db}_"*.sql.gz 2>/dev/null | head -1)
    fi

    if [[ -z "$latest" ]]; then
        latest=$(ls -t "$tier_dir/${db}_"*.sql 2>/dev/null | head -1)
    fi

    if [[ -z "$latest" ]]; then
        log_error "No backups found for database '$db' in tier '$tier'"
        return 1
    fi

    echo "$latest"
}

# =============================================================================
# Backup File Validation
# =============================================================================
validate_backup_file() {
    local file="$1"

    log_step "Validating backup file..."

    # Check file exists
    if [[ ! -f "$file" ]]; then
        log_error "Backup file not found: $file"
        return 1
    fi

    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    local file_size_human=$(du -h "$file" | cut -f1)

    log_info "Backup file: $file"
    log_info "File size: $file_size_human"

    # Check file is not empty
    if [[ $file_size -lt 100 ]]; then
        log_error "Backup file is suspiciously small ($file_size bytes)"
        return 1
    fi

    # Determine file type and validate
    local file_ext="${file##*.}"
    local file_type=""

    case "$file" in
        *.dump)
            file_type="custom"
            # Validate custom format
            if ! head -c 5 "$file" | grep -q "PGDMP"; then
                log_error "File does not appear to be a valid PostgreSQL custom dump"
                return 1
            fi
            log_info "Format: PostgreSQL custom format (pg_restore compatible)"
            ;;
        *.sql.gz)
            file_type="sql_gzip"
            # Validate gzip
            if ! gzip -t "$file" 2>/dev/null; then
                log_error "File is not a valid gzip archive"
                return 1
            fi
            log_info "Format: Gzipped SQL dump"
            ;;
        *.sql)
            file_type="sql"
            # Basic validation - check for SQL statements
            if ! head -100 "$file" | grep -qiE "(CREATE|INSERT|ALTER|DROP|SET)" ; then
                log_warning "File may not be a valid SQL dump"
            fi
            log_info "Format: Plain SQL dump"
            ;;
        *.tar.gz)
            file_type="basebackup"
            log_info "Format: pg_basebackup archive"
            log_error "Basebackup restoration requires special handling. See documentation."
            return 1
            ;;
        *)
            log_error "Unknown backup file format: $file_ext"
            return 1
            ;;
    esac

    # Verify checksum if available
    if [[ -f "${file}.sha256" ]]; then
        log_info "Verifying checksum..."
        if sha256sum -c "${file}.sha256" --status 2>/dev/null; then
            log_success "Checksum verification passed"
        else
            log_warning "Checksum verification failed!"
            if [[ "$FORCE" != "true" ]]; then
                read -p "Continue anyway? (yes/no): " confirm
                if [[ "$confirm" != "yes" ]]; then
                    return 1
                fi
            fi
        fi
    else
        log_info "No checksum file found (skipping verification)"
    fi

    echo "$file_type"
    return 0
}

# =============================================================================
# Database Preparation
# =============================================================================
prepare_database() {
    local db="$1"

    log_step "Preparing database: $db"

    # Check if database exists
    local db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null)

    if [[ "$db_exists" == "1" ]]; then
        log_info "Database '$db' exists"

        if [[ "$DROP_EXISTING" == "true" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would drop and recreate database: $db"
            else
                log_warning "Dropping existing database: $db"

                # Terminate existing connections
                sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" 2>/dev/null || true

                # Drop and recreate
                sudo -u postgres psql -c "DROP DATABASE IF EXISTS $db;"
                sudo -u postgres psql -c "CREATE DATABASE $db OWNER $PRAVAHA_USER ENCODING 'UTF8';"

                log_success "Database recreated: $db"
            fi
        else
            # Get current table count for reference
            local table_count=$(sudo -u postgres psql -d "$db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null || echo "0")
            log_info "Current table count: $table_count"
        fi
    else
        if [[ "$CREATE_DB" == "true" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would create database: $db"
            else
                log_info "Creating database: $db"
                sudo -u postgres psql -c "CREATE DATABASE $db OWNER $PRAVAHA_USER ENCODING 'UTF8';"

                # Create extensions
                sudo -u postgres psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
                sudo -u postgres psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS \"pgcrypto\";"

                log_success "Database created: $db"
            fi
        else
            log_error "Database '$db' does not exist. Use --create-db to create it."
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# Restore Functions
# =============================================================================
restore_custom_format() {
    local file="$1"
    local db="$2"

    log_step "Restoring from custom format dump..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would restore $file to $db"
        log_info "[DRY-RUN] Command: pg_restore -d $db -j $PARALLEL_JOBS ..."
        return 0
    fi

    # Build pg_restore options
    local restore_opts=("-d" "$db" "-j" "$PARALLEL_JOBS" "-v")

    if [[ "$NO_OWNER" == "true" ]]; then
        restore_opts+=("--no-owner")
    fi

    if [[ "$NO_PRIVILEGES" == "true" ]]; then
        restore_opts+=("--no-privileges")
    fi

    if [[ "$DROP_EXISTING" == "true" ]]; then
        restore_opts+=("--clean" "--if-exists")
    fi

    log_info "Running pg_restore with options: ${restore_opts[*]}"

    # pg_restore often returns non-zero even on success (due to pre-existing objects)
    # Capture output and check for actual errors
    local restore_output
    local restore_exit=0

    restore_output=$(sudo -u postgres pg_restore "${restore_opts[@]}" "$file" 2>&1) || restore_exit=$?

    # Log the output
    echo "$restore_output" | while read line; do
        if [[ -n "$line" ]]; then
            log_info "  $line"
        fi
    done

    # Check for critical errors (not just warnings)
    if echo "$restore_output" | grep -qiE "FATAL|could not|permission denied"; then
        log_error "Critical errors during restore"
        return 1
    fi

    if [[ $restore_exit -ne 0 ]]; then
        log_warning "pg_restore completed with warnings (exit code: $restore_exit)"
        log_info "This is often normal when objects already exist"
    fi

    return 0
}

restore_sql_dump() {
    local file="$1"
    local db="$2"
    local is_gzipped="$3"

    log_step "Restoring from SQL dump..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would restore $file to $db"
        return 0
    fi

    local restore_exit=0

    if [[ "$is_gzipped" == "true" ]]; then
        log_info "Decompressing and restoring..."
        gunzip -c "$file" | sudo -u postgres psql -d "$db" -v ON_ERROR_STOP=1 2>&1 || restore_exit=$?
    else
        log_info "Restoring..."
        sudo -u postgres psql -d "$db" -v ON_ERROR_STOP=1 -f "$file" 2>&1 || restore_exit=$?
    fi

    if [[ $restore_exit -ne 0 ]]; then
        log_warning "psql restore completed with warnings (exit code: $restore_exit)"
    fi

    return 0
}

# =============================================================================
# Post-Restore Verification
# =============================================================================
verify_restore() {
    local db="$1"

    log_step "Verifying restore..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would verify restore"
        return 0
    fi

    # Check database accessibility
    if ! sudo -u postgres psql -d "$db" -c "SELECT 1" &>/dev/null; then
        log_error "Cannot connect to restored database"
        return 1
    fi

    # Count tables
    local table_count=$(sudo -u postgres psql -d "$db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
    log_info "Tables restored: $table_count"

    if [[ $table_count -eq 0 ]]; then
        log_warning "No tables found in public schema"
    fi

    # Count rows in key tables (if they exist)
    local key_tables=("users" "organizations" "projects" "ml_models")
    for table in "${key_tables[@]}"; do
        local row_count=$(sudo -u postgres psql -d "$db" -tAc "SELECT count(*) FROM $table" 2>/dev/null || echo "N/A")
        if [[ "$row_count" != "N/A" ]]; then
            log_info "  $table: $row_count rows"
        fi
    done

    # Check extensions
    local extensions=$(sudo -u postgres psql -d "$db" -tAc "SELECT extname FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto')" | tr '\n' ',' | sed 's/,$//')
    log_info "Extensions: $extensions"

    # Check database size
    local db_size=$(sudo -u postgres psql -d "$db" -tAc "SELECT pg_size_pretty(pg_database_size('$db'))")
    log_info "Database size: $db_size"

    log_success "Restore verification completed"
    return 0
}

# =============================================================================
# Confirmation
# =============================================================================
confirm_restore() {
    if [[ "$FORCE" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    echo ""
    echo "=============================================="
    echo -e "${YELLOW}RESTORE CONFIRMATION${NC}"
    echo "=============================================="
    echo ""
    echo "Target database: $TARGET_DATABASE"
    echo "Backup file:     $BACKUP_FILE"
    echo ""

    if [[ "$DROP_EXISTING" == "true" ]]; then
        echo -e "${RED}WARNING: --drop-existing is set.${NC}"
        echo -e "${RED}All existing data in '$TARGET_DATABASE' will be DELETED!${NC}"
        echo ""
    fi

    read -p "Are you sure you want to proceed? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi
}

# =============================================================================
# Print Summary
# =============================================================================
print_restore_summary() {
    echo ""
    echo "=============================================="
    log_success "Restore completed successfully!"
    echo "=============================================="
    echo ""
    echo "Restore Details:"
    echo "  Database:    $TARGET_DATABASE"
    echo "  Backup file: $BACKUP_FILE"
    echo "  Log file:    $LOG_FILE"
    echo ""
    echo "Next Steps:"
    echo "  1. Verify application connectivity"
    echo "  2. Run application health checks"
    echo "  3. Check application logs for any issues"
    echo ""
    echo "Useful Commands:"
    echo "  - Connect to database: sudo -u postgres psql -d $TARGET_DATABASE"
    echo "  - Check tables: \\dt"
    echo "  - Check row counts: SELECT relname, n_live_tup FROM pg_stat_user_tables;"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    echo ""
    echo "=============================================="
    echo "Pravaha PostgreSQL Restore"
    echo "Version: $SCRIPT_VERSION"
    echo "=============================================="
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    check_root
    check_postgresql

    # Find latest backup if requested
    if [[ "$RESTORE_LATEST" == "true" ]]; then
        BACKUP_FILE=$(find_latest_backup "$TARGET_DATABASE" "$BACKUP_TIER")
        if [[ -z "$BACKUP_FILE" ]]; then
            exit 1
        fi
        log_info "Using latest backup: $BACKUP_FILE"
    fi

    # Validate backup file
    local file_type
    file_type=$(validate_backup_file "$BACKUP_FILE")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    # Confirm restore
    confirm_restore

    # Initialize logging
    log_init

    # Prepare database
    prepare_database "$TARGET_DATABASE"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    # Perform restore based on file type
    case "$file_type" in
        custom)
            restore_custom_format "$BACKUP_FILE" "$TARGET_DATABASE"
            ;;
        sql_gzip)
            restore_sql_dump "$BACKUP_FILE" "$TARGET_DATABASE" "true"
            ;;
        sql)
            restore_sql_dump "$BACKUP_FILE" "$TARGET_DATABASE" "false"
            ;;
        *)
            log_error "Unknown file type: $file_type"
            exit 1
            ;;
    esac

    # Verify restore
    verify_restore "$TARGET_DATABASE"

    # Print summary
    print_restore_summary

    echo "=============================================="
    echo "Restore finished at $(date)"
    echo "=============================================="
}

main "$@"
