#!/bin/bash
# =============================================================================
# Pravaha Platform - Backup Script
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Creates backups of application data, configuration, and optionally
#   connects to external PostgreSQL for database backup.
#
# Usage:
#   ./backup.sh [OPTIONS]
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
RETENTION_DAYS=30
BACKUP_DATABASE=false
BACKUP_CONFIGS=true
BACKUP_VOLUMES=true
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="pravaha_backup_$TIMESTAMP"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Create backups for Pravaha two-server app deployment.

OPTIONS:
    --database, -d     Include external database backup (requires pg_dump access)
    --configs-only     Backup configuration files only
    --volumes-only     Backup Docker volumes only
    --output DIR       Backup output directory (default: $BACKUP_DIR)
    --retention DAYS   Keep backups for N days (default: $RETENTION_DAYS)
    --name NAME        Custom backup name prefix
    -h, --help         Show this help message

EXAMPLES:
    $0                              # Full backup (configs + volumes)
    $0 --database                   # Include database backup
    $0 --configs-only               # Configuration only
    $0 --output /mnt/backups        # Custom output directory

NOTES:
    - For database backup, ensure pg_dump is available and POSTGRES_HOST is configured
    - Volume backup requires Docker to be running
    - Old backups are automatically cleaned up based on retention policy

EOF
    exit 0
}

# =============================================================================
# Logging
# =============================================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --database|-d)
                BACKUP_DATABASE=true
                shift
                ;;
            --configs-only)
                BACKUP_CONFIGS=true
                BACKUP_VOLUMES=false
                BACKUP_DATABASE=false
                shift
                ;;
            --volumes-only)
                BACKUP_CONFIGS=false
                BACKUP_VOLUMES=true
                BACKUP_DATABASE=false
                shift
                ;;
            --output)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --retention)
                RETENTION_DAYS="$2"
                shift 2
                ;;
            --name)
                BACKUP_NAME="${2}_$TIMESTAMP"
                shift 2
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
# Backup Functions
# =============================================================================

setup_backup_dir() {
    log_info "Setting up backup directory..."

    mkdir -p "$BACKUP_DIR"
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    mkdir -p "$BACKUP_PATH"

    # Cleanup partial backup on failure
    trap "rm -rf '$BACKUP_DIR/$BACKUP_NAME' '$BACKUP_DIR/$BACKUP_NAME.tar.gz' 2>/dev/null; rm -f '$LOCK_FILE'" ERR INT TERM

    log_success "Backup directory: $BACKUP_PATH"
}

backup_configs() {
    if [[ "$BACKUP_CONFIGS" != "true" ]]; then
        return 0
    fi

    log_info "Backing up configuration files..."

    local config_dir="$BACKUP_PATH/configs"
    mkdir -p "$config_dir"

    # Backup .env (sensitive - will be encrypted)
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        cp "$DEPLOY_DIR/.env" "$config_dir/"
        chmod 600 "$config_dir/.env"
        log_success "Backed up .env"
    fi

    # Backup docker-compose files (all overlays)
    for compose_file in "$DEPLOY_DIR"/docker-compose*.yml; do
        [[ -f "$compose_file" ]] && cp "$compose_file" "$config_dir/"
    done
    log_success "Backed up docker-compose files"

    # Backup nginx configuration
    if [[ -d "$DEPLOY_DIR/nginx" ]]; then
        cp -r "$DEPLOY_DIR/nginx" "$config_dir/"
        log_success "Backed up nginx configuration"
    fi

    # Backup SSL certificates
    if [[ -d "$DEPLOY_DIR/ssl" ]]; then
        cp -r "$DEPLOY_DIR/ssl" "$config_dir/"
        chmod -R 600 "$config_dir/ssl"
        log_success "Backed up SSL certificates"
    fi

    # Branding configuration
    if [[ -d "$DEPLOY_DIR/branding" ]]; then
        cp -r "$DEPLOY_DIR/branding" "$config_dir/"
        log_success "Backed up branding configuration"
    fi

    # Audit signature keys
    for pem_file in "$DEPLOY_DIR"/audit-*.pem; do
        [[ -f "$pem_file" ]] && cp "$pem_file" "$config_dir/"
    done
    log_success "Backed up audit keys"

    # Admin credential files
    for cred_file in "$DEPLOY_DIR"/.admin_email "$DEPLOY_DIR"/.admin_password; do
        [[ -f "$cred_file" ]] && cp "$cred_file" "$config_dir/"
    done

    # Monitoring configuration
    if [[ -d "$DEPLOY_DIR/monitoring" ]]; then
        cp -r "$DEPLOY_DIR/monitoring" "$config_dir/"
        log_success "Backed up monitoring configuration"
    fi

    # Logging configuration
    if [[ -d "$DEPLOY_DIR/logging" ]]; then
        cp -r "$DEPLOY_DIR/logging" "$config_dir/"
        log_success "Backed up logging configuration"
    fi

    log_success "Configuration backup complete"
}

backup_volumes() {
    if [[ "$BACKUP_VOLUMES" != "true" ]]; then
        return 0
    fi

    log_info "Backing up Docker volumes..."

    local volumes_dir="$BACKUP_PATH/volumes"
    mkdir -p "$volumes_dir"

    # Get project name from directory
    local project=$(basename "$DEPLOY_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

    # Volumes to backup (no postgres_data - it's external)
    local volumes=(
        "redis_data"
        "superset_home"
        "ml_models"
        "ml_logs"
        "training_data"
        "uploads"
        "app_logs"
        "nginx_logs"
        "celery_beat_schedule"
    )

    for vol in "${volumes[@]}"; do
        local full_vol="${project}_${vol}"

        # Check if volume exists
        if docker volume inspect "$full_vol" &>/dev/null; then
            log_info "Backing up volume: $vol"

            # Create tarball of volume data
            docker run --rm \
                -v "$full_vol:/source:ro" \
                -v "$volumes_dir:/backup" \
                alpine tar czf "/backup/${vol}.tar.gz" -C /source . 2>/dev/null

            if [[ -f "$volumes_dir/${vol}.tar.gz" ]]; then
                log_success "Volume $vol backed up"
            else
                log_warning "Failed to backup volume $vol"
            fi
        else
            log_warning "Volume $full_vol not found, skipping"
        fi
    done

    # ML storage (datasets, prepared data)
    log_info "  Backing up ML storage..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T ml-service tar czf - /data/ml-storage 2>/dev/null \
        > "$volumes_dir/ml_storage.tar.gz" || log_warning "No ML storage to backup"

    # Training data
    log_info "  Backing up training data..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T ml-service tar czf - /app/training_data 2>/dev/null \
        > "$volumes_dir/training_data.tar.gz" || log_warning "No training data to backup"

    # Plugins (uploaded plugin packages + extracted)
    log_info "  Backing up plugins..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T backend tar czf - /app/plugins 2>/dev/null \
        > "$volumes_dir/plugins.tar.gz" || log_warning "No plugins to backup"

    # Solution Packs (uploaded solution pack archives)
    log_info "  Backing up solution packs..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T backend tar czf - /app/solution-packs 2>/dev/null \
        > "$volumes_dir/solution_packs.tar.gz" || log_warning "No solution packs to backup"

    # Jupyter notebooks (user notebooks and work files)
    log_info "  Backing up Jupyter notebooks..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T jupyter tar czf - /home/jovyan/work 2>/dev/null \
        > "$volumes_dir/jupyter_notebooks.tar.gz" || log_warning "No Jupyter notebooks to backup"

    # Jupyter data (datasets and additional data)
    log_info "  Backing up Jupyter data..."
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec -T jupyter tar czf - /home/jovyan/data 2>/dev/null \
        > "$volumes_dir/jupyter_data.tar.gz" || log_warning "No Jupyter data to backup"

    log_success "Volume backup complete"
}

backup_external_database() {
    if [[ "$BACKUP_DATABASE" != "true" ]]; then
        return 0
    fi

    log_info "Backing up external PostgreSQL database..."

    # Load environment
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        source "$DEPLOY_DIR/.env" 2>/dev/null || true
    fi

    if [[ -z "$POSTGRES_HOST" ]]; then
        log_warning "POSTGRES_HOST not configured, skipping database backup"
        log_warning "To backup the database, run pg_dump on the database server"
        return 0
    fi

    local db_dir="$BACKUP_PATH/database"
    mkdir -p "$db_dir"

    local host="${POSTGRES_HOST}"
    local port="${POSTGRES_PORT:-5432}"
    local user="${POSTGRES_USER:-pravaha}"
    local password="${POSTGRES_PASSWORD:-}"
    local platform_db="${PLATFORM_DB:-autoanalytics}"
    local superset_db="${SUPERSET_DB:-superset}"

    # Backup platform database
    log_info "Backing up platform database: $platform_db"
    if docker run --rm --network host \
        -e PGPASSWORD="$password" \
        -v "$db_dir:/backup" \
        postgres:17-alpine \
        pg_dump -h "$host" -p "$port" -U "$user" -d "$platform_db" \
        -Fc -f "/backup/${platform_db}.dump" 2>/dev/null; then
        log_success "Platform database backed up"
    else
        log_error "Failed to backup platform database"
        log_warning "Ensure the app server has network access to the database server"
    fi

    # Backup superset database
    log_info "Backing up superset database: $superset_db"
    if docker run --rm --network host \
        -e PGPASSWORD="$password" \
        -v "$db_dir:/backup" \
        postgres:17-alpine \
        pg_dump -h "$host" -p "$port" -U "$user" -d "$superset_db" \
        -Fc -f "/backup/${superset_db}.dump" 2>/dev/null; then
        log_success "Superset database backed up"
    else
        log_error "Failed to backup superset database"
    fi

    log_success "Database backup complete"
}

create_manifest() {
    log_info "Creating backup manifest..."

    # Load environment for version info
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        source "$DEPLOY_DIR/.env" 2>/dev/null || true
    fi

    cat > "$BACKUP_PATH/manifest.json" << MANIFEST_EOF
{
    "timestamp": "$TIMESTAMP",
    "deployment_type": "two-server-app",
    "created_at": "$(date -Iseconds)",
    "version": "$(grep '^IMAGE_TAG=' "$DEPLOY_DIR/.env" 2>/dev/null | cut -d= -f2 || echo 'unknown')",
    "contents": {
        "databases": $(if [[ "$BACKUP_DATABASE" == "true" ]]; then echo '["autoanalytics", "superset"]'; else echo '[]'; fi),
        "volumes": $(if [[ "$BACKUP_VOLUMES" == "true" ]]; then echo '["redis_data", "superset_home", "ml_models", "ml_logs", "training_data", "uploads", "app_logs", "nginx_logs", "celery_beat_schedule", "ml_storage", "plugins", "solution_packs", "jupyter_notebooks", "jupyter_data"]'; else echo '[]'; fi),
        "config": $(if [[ "$BACKUP_CONFIGS" == "true" ]]; then echo 'true'; else echo 'false'; fi)
    }
}
MANIFEST_EOF

    log_success "Manifest created"
}

create_backup_archive() {
    log_info "Creating backup archive..."

    cd "$BACKUP_DIR"

    # Create compressed archive
    tar czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"

    # Restrict backup permissions (contains secrets in .env)
    chmod 600 "${BACKUP_NAME}.tar.gz"

    # Calculate checksum
    sha256sum "${BACKUP_NAME}.tar.gz" > "${BACKUP_NAME}.tar.gz.sha256"

    # Remove uncompressed backup directory
    rm -rf "$BACKUP_NAME"

    local size=$(du -h "${BACKUP_NAME}.tar.gz" | cut -f1)

    log_success "Backup archive created: ${BACKUP_NAME}.tar.gz ($size)"
    log_info "Checksum: ${BACKUP_NAME}.tar.gz.sha256"
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."

    local count=$(find "$BACKUP_DIR" -name "pravaha_backup_*.tar.gz" -mtime "+$RETENTION_DAYS" 2>/dev/null | wc -l)

    if [[ $count -gt 0 ]]; then
        find "$BACKUP_DIR" -name "pravaha_backup_*.tar.gz" -mtime "+$RETENTION_DAYS" -delete 2>/dev/null
        find "$BACKUP_DIR" -name "pravaha_backup_*.tar.gz.sha256" -mtime "+$RETENTION_DAYS" -delete 2>/dev/null
        log_success "Cleaned up $count old backup(s)"
    else
        log_info "No old backups to clean up"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    echo ""
    echo "=============================================="
    echo "Pravaha Backup - Two-Server (App)"
    echo "=============================================="
    echo ""

    # Concurrent execution guard -- prevents running simultaneously with another backup/restore/update
    LOCK_FILE="$DEPLOY_DIR/.pravaha-backup.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_error "Another backup or restore operation is already in progress."
        log_error "If you're sure no other operation is running, remove: $LOCK_FILE"
        exit 1
    fi

    setup_backup_dir
    backup_configs
    backup_volumes
    backup_external_database
    create_manifest
    create_backup_archive
    cleanup_old_backups

    echo ""
    echo "=============================================="
    log_success "Backup completed successfully!"
    echo "=============================================="
    echo ""
    echo "Backup location: $BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    echo ""
    echo "To restore, use:"
    echo "  ./scripts/restore.sh --backup $BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    echo ""
}

main "$@"
