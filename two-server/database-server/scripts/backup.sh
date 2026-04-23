#!/bin/bash
# =============================================================================
# Pravaha Platform - PostgreSQL Backup Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Enterprise-grade backup solution for dedicated PostgreSQL server.
#   Supports pg_dump for logical backups and pg_basebackup for physical backups.
#   Implements retention policies: daily, weekly, and monthly backups.
#
# Usage:
#   sudo ./backup.sh [OPTIONS]
#
# Options:
#   --type TYPE        Backup type: dump (default), basebackup, or both
#   --database DB      Backup specific database (default: all)
#   --retention N      Override default retention days
#   --compress LEVEL   Compression level 0-9 (default: 9)
#   --parallel N       Parallel jobs for pg_dump (default: 4)
#   --no-retention     Skip retention cleanup
#   --dry-run          Show what would be done without executing
#   -h, --help         Show this help message
#
# Retention Policy (default):
#   - Daily backups: 7 days
#   - Weekly backups: 4 weeks (Sundays)
#   - Monthly backups: 3 months (1st of month)
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

# Backup configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"
BACKUP_TYPE="dump"
TARGET_DATABASE="all"
COMPRESS_LEVEL=9
PARALLEL_JOBS=4
DRY_RUN=false
SKIP_RETENTION=false

# Retention policy (in number of backups to keep)
DAILY_RETENTION=7
WEEKLY_RETENTION=4
MONTHLY_RETENTION=3

# Timestamp and backup naming
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_ONLY=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
DAY_OF_MONTH=$(date +%d)

# Logging
LOG_DIR="/var/log/pravaha"
LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d).log"

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
    echo "Backup started at $(date)"
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
Usage: $0 [OPTIONS]

Enterprise-grade PostgreSQL backup script with retention policies.

OPTIONS:
    --type TYPE        Backup type: dump (default), basebackup, or both
    --database DB      Backup specific database (default: all)
    --retention N      Override default retention days
    --compress LEVEL   Compression level 0-9 (default: 9)
    --parallel N       Parallel jobs for pg_dump (default: 4)
    --no-retention     Skip retention cleanup
    --dry-run          Show what would be done without executing
    -h, --help         Show this help message

BACKUP TYPES:
    dump        Logical backup using pg_dump (recommended for most cases)
    basebackup  Physical backup using pg_basebackup (for PITR)
    both        Create both dump and basebackup

RETENTION POLICY:
    Daily backups:   Keep last $DAILY_RETENTION days
    Weekly backups:  Keep last $WEEKLY_RETENTION weeks (Sundays)
    Monthly backups: Keep last $MONTHLY_RETENTION months (1st of month)

EXAMPLES:
    # Standard daily backup
    sudo $0

    # Backup specific database
    sudo $0 --database autoanalytics

    # Physical backup for point-in-time recovery
    sudo $0 --type basebackup

    # Both backup types
    sudo $0 --type both

    # Dry run
    sudo $0 --dry-run

BACKUP LOCATION:
    $BACKUP_DIR/
    ├── daily/
    │   ├── autoanalytics_YYYYMMDD_HHMMSS.dump
    │   └── superset_YYYYMMDD_HHMMSS.dump
    ├── weekly/
    │   └── ...
    ├── monthly/
    │   └── ...
    └── basebackup/
        └── YYYYMMDD_HHMMSS/

CRON EXAMPLES:
    # Daily backup at 2 AM
    0 2 * * * /opt/pravaha/scripts/backup.sh >> /var/log/pravaha/backup-cron.log 2>&1

    # Weekly full backup Sundays at 3 AM
    0 3 * * 0 /opt/pravaha/scripts/backup.sh --type both >> /var/log/pravaha/backup-cron.log 2>&1

EOF
    exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                BACKUP_TYPE="$2"
                if [[ ! "$BACKUP_TYPE" =~ ^(dump|basebackup|both)$ ]]; then
                    log_error "Invalid backup type: $BACKUP_TYPE"
                    exit 1
                fi
                shift 2
                ;;
            --database)
                TARGET_DATABASE="$2"
                shift 2
                ;;
            --retention)
                DAILY_RETENTION="$2"
                shift 2
                ;;
            --compress)
                COMPRESS_LEVEL="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --no-retention)
                SKIP_RETENTION=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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

check_disk_space() {
    local available_gb=$(df -BG "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

    if [[ $available_gb -lt 5 ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available. Need at least 5GB."
        exit 1
    fi

    if [[ $available_gb -lt 20 ]]; then
        log_warning "Low disk space: ${available_gb}GB available"
    fi

    log_info "Disk space OK: ${available_gb}GB available"
}

# =============================================================================
# Directory Setup
# =============================================================================
setup_backup_directories() {
    log_step "Setting up backup directories..."

    local dirs=("$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly" "$BACKUP_DIR/basebackup" "$BACKUP_DIR/temp")

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would create directory: $dir"
            else
                mkdir -p "$dir"
                chown postgres:postgres "$dir"
                chmod 750 "$dir"
                log_info "Created directory: $dir"
            fi
        fi
    done
}

# =============================================================================
# Determine Backup Tier
# =============================================================================
get_backup_tier() {
    # Monthly: 1st of month
    if [[ "$DAY_OF_MONTH" == "01" ]]; then
        echo "monthly"
    # Weekly: Sunday
    elif [[ "$DAY_OF_WEEK" == "7" ]]; then
        echo "weekly"
    # Daily: everything else
    else
        echo "daily"
    fi
}

# =============================================================================
# pg_dump Backup Functions
# =============================================================================
backup_database_dump() {
    local database="$1"
    local tier="$2"
    local backup_file="$BACKUP_DIR/$tier/${database}_${TIMESTAMP}.dump"
    local sql_file="$BACKUP_DIR/$tier/${database}_${TIMESTAMP}.sql.gz"

    log_step "Backing up database: $database (tier: $tier)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create: $backup_file"
        return 0
    fi

    # Create custom format dump (best for restore flexibility)
    log_info "Creating custom format dump..."
    sudo -u postgres pg_dump \
        -Fc \
        -Z "$COMPRESS_LEVEL" \
        -j "$PARALLEL_JOBS" \
        -d "$database" \
        -f "$backup_file" \
        --verbose 2>&1 | while read line; do log_info "  $line"; done

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file was not created: $backup_file"
        return 1
    fi

    local file_size=$(du -h "$backup_file" | cut -f1)
    log_success "Custom format dump created: $backup_file ($file_size)"

    # Also create SQL dump for portability
    log_info "Creating SQL dump..."
    sudo -u postgres pg_dump \
        -d "$database" \
        --no-owner \
        --no-privileges | gzip -$COMPRESS_LEVEL > "$sql_file"

    local sql_size=$(du -h "$sql_file" | cut -f1)
    log_success "SQL dump created: $sql_file ($sql_size)"

    # Set permissions
    chown postgres:postgres "$backup_file" "$sql_file"
    chmod 640 "$backup_file" "$sql_file"

    # Create checksum
    sha256sum "$backup_file" > "${backup_file}.sha256"
    sha256sum "$sql_file" > "${sql_file}.sha256"

    return 0
}

backup_all_databases_dump() {
    local tier=$(get_backup_tier)
    local databases=()
    local failed=0

    if [[ "$TARGET_DATABASE" == "all" ]]; then
        databases=("$PLATFORM_DB" "$SUPERSET_DB")
    else
        databases=("$TARGET_DATABASE")
    fi

    log_step "Starting dump backups for tier: $tier"
    log_info "Databases: ${databases[*]}"

    for db in "${databases[@]}"; do
        if ! backup_database_dump "$db" "$tier"; then
            log_error "Failed to backup database: $db"
            ((failed++))
        fi
    done

    # Create global backup manifest
    create_backup_manifest "$tier"

    return $failed
}

# =============================================================================
# pg_basebackup Functions
# =============================================================================
backup_basebackup() {
    local backup_path="$BACKUP_DIR/basebackup/${TIMESTAMP}"

    log_step "Creating physical backup with pg_basebackup..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create basebackup at: $backup_path"
        return 0
    fi

    mkdir -p "$backup_path"
    chown postgres:postgres "$backup_path"

    log_info "Starting pg_basebackup (this may take a while)..."

    sudo -u postgres pg_basebackup \
        -D "$backup_path" \
        -Ft \
        -z \
        -P \
        --checkpoint=fast \
        --wal-method=stream \
        -l "pravaha_backup_${TIMESTAMP}" \
        2>&1 | while read line; do log_info "  $line"; done

    if [[ ! -f "$backup_path/base.tar.gz" ]]; then
        log_error "Basebackup failed - base.tar.gz not found"
        return 1
    fi

    local total_size=$(du -sh "$backup_path" | cut -f1)
    log_success "Basebackup completed: $backup_path ($total_size)"

    # Create checksum
    cd "$backup_path"
    sha256sum *.tar.gz > checksums.sha256
    cd - > /dev/null

    # Create manifest
    cat > "$backup_path/manifest.json" << EOF
{
    "type": "pg_basebackup",
    "timestamp": "$TIMESTAMP",
    "created_at": "$(date -Iseconds)",
    "postgres_version": "$POSTGRES_VERSION",
    "server_hostname": "$(hostname -f 2>/dev/null || hostname)",
    "size": "$total_size"
}
EOF

    return 0
}

# =============================================================================
# Backup Manifest
# =============================================================================
create_backup_manifest() {
    local tier="$1"
    local manifest_file="$BACKUP_DIR/$tier/manifest_${TIMESTAMP}.json"

    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    local databases_json="[]"
    if [[ "$TARGET_DATABASE" == "all" ]]; then
        databases_json="[\"$PLATFORM_DB\", \"$SUPERSET_DB\"]"
    else
        databases_json="[\"$TARGET_DATABASE\"]"
    fi

    cat > "$manifest_file" << EOF
{
    "backup_type": "pg_dump",
    "tier": "$tier",
    "timestamp": "$TIMESTAMP",
    "created_at": "$(date -Iseconds)",
    "postgres_version": "$POSTGRES_VERSION",
    "server_hostname": "$(hostname -f 2>/dev/null || hostname)",
    "databases": $databases_json,
    "compress_level": $COMPRESS_LEVEL,
    "files": [
$(for db in $PLATFORM_DB $SUPERSET_DB; do
    if [[ -f "$BACKUP_DIR/$tier/${db}_${TIMESTAMP}.dump" ]]; then
        local size=$(stat -c%s "$BACKUP_DIR/$tier/${db}_${TIMESTAMP}.dump" 2>/dev/null || stat -f%z "$BACKUP_DIR/$tier/${db}_${TIMESTAMP}.dump" 2>/dev/null)
        echo "        {\"database\": \"$db\", \"file\": \"${db}_${TIMESTAMP}.dump\", \"size\": $size},"
    fi
done | sed '$ s/,$//')
    ]
}
EOF

    chown postgres:postgres "$manifest_file"
    log_info "Manifest created: $manifest_file"
}

# =============================================================================
# Retention Management
# =============================================================================
apply_retention_policy() {
    if [[ "$SKIP_RETENTION" == "true" ]]; then
        log_info "Skipping retention cleanup (--no-retention)"
        return 0
    fi

    log_step "Applying retention policy..."

    # Daily retention
    apply_retention_for_tier "daily" "$DAILY_RETENTION"

    # Weekly retention
    apply_retention_for_tier "weekly" "$WEEKLY_RETENTION"

    # Monthly retention
    apply_retention_for_tier "monthly" "$MONTHLY_RETENTION"

    # Basebackup retention (keep same as daily)
    cleanup_old_basebackups "$DAILY_RETENTION"

    log_success "Retention policy applied"
}

apply_retention_for_tier() {
    local tier="$1"
    local keep_count="$2"
    local tier_dir="$BACKUP_DIR/$tier"

    if [[ ! -d "$tier_dir" ]]; then
        return 0
    fi

    log_info "Cleaning up $tier backups (keeping last $keep_count)..."

    # For each database, keep the most recent N backups
    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        # Clean up .dump files
        local dump_files=$(ls -t "$tier_dir/${db}_"*.dump 2>/dev/null || true)
        local count=0
        for file in $dump_files; do
            ((count++))
            if [[ $count -gt $keep_count ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY-RUN] Would delete: $file"
                else
                    rm -f "$file" "${file}.sha256"
                    log_info "Deleted: $(basename "$file")"
                fi
            fi
        done

        # Clean up .sql.gz files
        local sql_files=$(ls -t "$tier_dir/${db}_"*.sql.gz 2>/dev/null || true)
        count=0
        for file in $sql_files; do
            ((count++))
            if [[ $count -gt $keep_count ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY-RUN] Would delete: $file"
                else
                    rm -f "$file" "${file}.sha256"
                    log_info "Deleted: $(basename "$file")"
                fi
            fi
        done
    done

    # Clean up old manifests
    local manifests=$(ls -t "$tier_dir/manifest_"*.json 2>/dev/null || true)
    local count=0
    for file in $manifests; do
        ((count++))
        if [[ $count -gt $keep_count ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would delete: $file"
            else
                rm -f "$file"
            fi
        fi
    done
}

cleanup_old_basebackups() {
    local keep_count="$1"
    local basebackup_dir="$BACKUP_DIR/basebackup"

    if [[ ! -d "$basebackup_dir" ]]; then
        return 0
    fi

    log_info "Cleaning up old basebackups (keeping last $keep_count)..."

    local backup_dirs=$(ls -dt "$basebackup_dir"/*/ 2>/dev/null | tail -n +$((keep_count + 1)) || true)

    for dir in $backup_dirs; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would delete: $dir"
        else
            rm -rf "$dir"
            log_info "Deleted: $dir"
        fi
    done
}

# =============================================================================
# Backup Summary
# =============================================================================
print_backup_summary() {
    echo ""
    echo "=============================================="
    log_success "Backup completed successfully!"
    echo "=============================================="
    echo ""
    echo "Backup Details:"
    echo "  Type:      $BACKUP_TYPE"
    echo "  Tier:      $(get_backup_tier)"
    echo "  Timestamp: $TIMESTAMP"
    echo "  Location:  $BACKUP_DIR"
    echo ""

    if [[ "$BACKUP_TYPE" == "dump" ]] || [[ "$BACKUP_TYPE" == "both" ]]; then
        local tier=$(get_backup_tier)
        echo "Dump Backups:"
        for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
            local dump_file="$BACKUP_DIR/$tier/${db}_${TIMESTAMP}.dump"
            if [[ -f "$dump_file" ]]; then
                local size=$(du -h "$dump_file" | cut -f1)
                echo "  - $db: $size"
            fi
        done
        echo ""
    fi

    if [[ "$BACKUP_TYPE" == "basebackup" ]] || [[ "$BACKUP_TYPE" == "both" ]]; then
        local basebackup_path="$BACKUP_DIR/basebackup/${TIMESTAMP}"
        if [[ -d "$basebackup_path" ]]; then
            local size=$(du -sh "$basebackup_path" | cut -f1)
            echo "Basebackup: $size"
            echo ""
        fi
    fi

    echo "Disk Usage:"
    du -sh "$BACKUP_DIR"/* 2>/dev/null | while read line; do
        echo "  $line"
    done
    echo ""

    echo "To restore:"
    echo "  ./restore.sh --database <db> --file <backup_file>"
    echo ""
    echo "To verify backup:"
    echo "  ./verify-backup.sh --file <backup_file>"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    echo ""
    echo "=============================================="
    echo "Pravaha PostgreSQL Backup"
    echo "Version: $SCRIPT_VERSION"
    echo "=============================================="
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    check_root
    check_postgresql
    setup_backup_directories
    check_disk_space

    # Concurrent execution guard -- prevents running simultaneously with another backup/restore/update
    LOCK_FILE="$BACKUP_DIR/.pravaha-backup.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_error "Another backup or restore operation is already in progress."
        log_error "If you're sure no other operation is running, remove: $LOCK_FILE"
        exit 1
    fi
    trap "rm -f '$LOCK_FILE'" EXIT

    log_init

    local exit_code=0

    case $BACKUP_TYPE in
        dump)
            backup_all_databases_dump || exit_code=$?
            ;;
        basebackup)
            backup_basebackup || exit_code=$?
            ;;
        both)
            backup_all_databases_dump || exit_code=$?
            backup_basebackup || ((exit_code++))
            ;;
    esac

    apply_retention_policy

    if [[ $exit_code -eq 0 ]]; then
        print_backup_summary
    else
        log_error "Backup completed with errors"
        exit $exit_code
    fi

    echo "=============================================="
    echo "Backup finished at $(date)"
    echo "=============================================="
}

main "$@"
