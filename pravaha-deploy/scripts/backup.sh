#!/bin/bash
# =============================================================================
# Pravaha Platform - Backup Script
# Creates backups of database, volumes, and configuration
# =============================================================================
#
# Usage:
#   ./backup.sh                    # Full backup (database + config)
#   ./backup.sh --db-only          # Database only (faster)
#   ./backup.sh --full             # Full backup including volumes
#   ./backup.sh --retention 14     # Keep 14 days of backups
#
# Environment Variables:
#   DEPLOY_DIR    - Deployment directory (default: /opt/pravaha)
#   BACKUP_DIR    - Backup storage directory (default: $DEPLOY_DIR/backups)
#   RETENTION     - Number of backups to keep (default: 7)
#   POSTGRES_USER - Database user (reads from .env if not set)
#
# =============================================================================

set -euo pipefail

# Configuration
DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
RETENTION="${RETENTION:-7}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_TYPE="standard"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-only)
            BACKUP_TYPE="db-only"
            shift
            ;;
        --full)
            BACKUP_TYPE="full"
            shift
            ;;
        --retention)
            RETENTION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

BACKUP_NAME="pravaha_backup_${BACKUP_TYPE}_$TIMESTAMP"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"
POSTGRES_MODE="${POSTGRES_MODE:-bundled}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# =============================================================================
# Docker Compose wrapper for POSTGRES_MODE support
# Adds --profile bundled-db when POSTGRES_MODE=bundled
# =============================================================================
compose_cmd() {
    if [[ "${POSTGRES_MODE}" == "bundled" ]]; then
        docker compose --profile bundled-db "$@"
    else
        docker compose "$@"
    fi
}

echo "=============================================="
echo "Pravaha Platform - Backup"
echo "=============================================="
echo "Type:      $BACKUP_TYPE"
echo "Mode:      POSTGRES_MODE=$POSTGRES_MODE"
echo "Directory: $BACKUP_DIR"
echo "Retention: $RETENTION backups"
echo ""

# Concurrent execution guard -- prevents running simultaneously with another backup/restore/update
LOCK_FILE="$DEPLOY_DIR/.pravaha-backup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_error "Another backup or restore operation is already in progress."
    log_error "If you're sure no other operation is running, remove: $LOCK_FILE"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR/$BACKUP_NAME"

# Cleanup partial backup on failure
trap "rm -rf '$BACKUP_DIR/$BACKUP_NAME' '$BACKUP_DIR/$BACKUP_NAME.tar.gz' 2>/dev/null; rm -f '$LOCK_FILE'" ERR INT TERM

log_info "Starting backup: $BACKUP_NAME"

# =============================================================================
# Database Backup
# =============================================================================
backup_databases() {
    log_info "Backing up PostgreSQL databases (mode: $POSTGRES_MODE)..."

    cd "$DEPLOY_DIR"

    if [[ "$POSTGRES_MODE" == "external" ]]; then
        # External PostgreSQL: use pg_dump over the network
        if ! command -v pg_dump &>/dev/null; then
            log_error "pg_dump not found. Install postgresql-client to backup external databases."
            exit 1
        fi

        # Platform database (custom format)
        log_info "  Dumping $PLATFORM_DB (external)..."
        PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
            -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
            -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
            --format=custom --compress=9 \
            > "$BACKUP_DIR/$BACKUP_NAME/${PLATFORM_DB}.dump"

        # Superset database (custom format)
        log_info "  Dumping $SUPERSET_DB (external)..."
        PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
            -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
            -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
            --format=custom --compress=9 \
            > "$BACKUP_DIR/$BACKUP_NAME/${SUPERSET_DB}.dump"

        # SQL dumps for portability
        log_info "  Creating SQL exports (external)..."
        PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
            -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
            -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
            > "$BACKUP_DIR/$BACKUP_NAME/${PLATFORM_DB}.sql"

        PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
            -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
            -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
            > "$BACKUP_DIR/$BACKUP_NAME/${SUPERSET_DB}.sql"
    else
        # Bundled PostgreSQL: use docker compose exec
        # Platform database (custom format)
        log_info "  Dumping $PLATFORM_DB (bundled)..."
        compose_cmd exec -T postgres \
            pg_dump -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
            --format=custom --compress=9 \
            > "$BACKUP_DIR/$BACKUP_NAME/${PLATFORM_DB}.dump"

        # Superset database (custom format)
        log_info "  Dumping $SUPERSET_DB (bundled)..."
        compose_cmd exec -T postgres \
            pg_dump -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
            --format=custom --compress=9 \
            > "$BACKUP_DIR/$BACKUP_NAME/${SUPERSET_DB}.dump"

        # SQL dumps for portability
        log_info "  Creating SQL exports (bundled)..."
        compose_cmd exec -T postgres \
            pg_dump -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
            > "$BACKUP_DIR/$BACKUP_NAME/${PLATFORM_DB}.sql"

        compose_cmd exec -T postgres \
            pg_dump -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
            > "$BACKUP_DIR/$BACKUP_NAME/${SUPERSET_DB}.sql"
    fi

    log_success "Database backups completed"
}

# =============================================================================
# Configuration Backup
# =============================================================================
backup_config() {
    log_info "Backing up configuration..."

    # Environment file (contains secrets - handle carefully)
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        cp "$DEPLOY_DIR/.env" "$BACKUP_DIR/$BACKUP_NAME/.env"
    fi

    # NGINX configuration
    if [[ -d "$DEPLOY_DIR/nginx" ]]; then
        cp -r "$DEPLOY_DIR/nginx" "$BACKUP_DIR/$BACKUP_NAME/"
    fi

    # SSL certificates
    if [[ -d "$DEPLOY_DIR/ssl" ]]; then
        cp -r "$DEPLOY_DIR/ssl" "$BACKUP_DIR/$BACKUP_NAME/"
    fi

    # Branding configuration
    if [[ -d "$DEPLOY_DIR/branding" ]]; then
        cp -r "$DEPLOY_DIR/branding" "$BACKUP_DIR/$BACKUP_NAME/"
    fi

    # Audit signature keys (critical - if lost, audit log verification breaks)
    for pem_file in "$DEPLOY_DIR"/audit-*.pem; do
        [[ -f "$pem_file" ]] && cp "$pem_file" "$BACKUP_DIR/$BACKUP_NAME/"
    done

    # Admin credential files
    for cred_file in "$DEPLOY_DIR"/.admin_email "$DEPLOY_DIR"/.admin_password; do
        [[ -f "$cred_file" ]] && cp "$cred_file" "$BACKUP_DIR/$BACKUP_NAME/"
    done

    # Monitoring configuration (Prometheus, Alertmanager, alerts, Grafana dashboards)
    if [[ -d "$DEPLOY_DIR/monitoring" ]]; then
        cp -r "$DEPLOY_DIR/monitoring" "$BACKUP_DIR/$BACKUP_NAME/"
    fi

    # Logging configuration (Loki, Promtail)
    if [[ -d "$DEPLOY_DIR/logging" ]]; then
        cp -r "$DEPLOY_DIR/logging" "$BACKUP_DIR/$BACKUP_NAME/"
    fi

    # Docker compose files (main + all overlays)
    for compose_file in "$DEPLOY_DIR"/docker-compose*.yml; do
        [[ -f "$compose_file" ]] && cp "$compose_file" "$BACKUP_DIR/$BACKUP_NAME/"
    done

    log_success "Configuration backup completed"
}

# =============================================================================
# Volume Backup (Full backup only)
# =============================================================================
backup_volumes() {
    log_info "Backing up Docker volumes..."

    cd "$DEPLOY_DIR"

    # Uploads directory
    log_info "  Backing up uploads..."
    compose_cmd exec -T backend tar czf - /app/uploads 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/uploads.tar.gz" || log_warning "No uploads to backup"

    # ML models
    log_info "  Backing up ML models..."
    compose_cmd exec -T ml-service tar czf - /app/models 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/ml_models.tar.gz" || log_warning "No ML models to backup"

    # Superset home (dashboards, saved queries)
    log_info "  Backing up Superset home..."
    compose_cmd exec -T superset tar czf - /app/superset_home 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/superset_home.tar.gz" || log_warning "No Superset home to backup"

    # ML storage (datasets, prepared data)
    log_info "  Backing up ML storage..."
    compose_cmd exec -T ml-service tar czf - /data/ml-storage 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/ml_storage.tar.gz" || log_warning "No ML storage to backup"

    # Training data
    log_info "  Backing up training data..."
    compose_cmd exec -T ml-service tar czf - /app/training_data 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/training_data.tar.gz" || log_warning "No training data to backup"

    # Plugins (uploaded plugin packages + extracted)
    log_info "  Backing up plugins..."
    compose_cmd exec -T backend tar czf - /app/plugins 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/plugins.tar.gz" || log_warning "No plugins to backup"

    # Celery beat schedule (persistent scheduler state)
    log_info "  Backing up celery beat schedule..."
    compose_cmd exec -T celery-beat tar czf - /tmp/celerybeat-schedule 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/celery_beat_schedule.tar.gz" || log_warning "No celery beat schedule to backup"

    # Workflow configs (user-defined workflow configurations)
    log_info "  Backing up workflow configs..."
    compose_cmd exec -T backend tar czf - /app/workflow-configs 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/workflow_configs.tar.gz" || log_warning "No workflow configs to backup"

    # Jupyter notebooks (user notebooks and work files)
    log_info "  Backing up Jupyter notebooks..."
    compose_cmd exec -T jupyter tar czf - /home/jovyan/work 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/jupyter_notebooks.tar.gz" || log_warning "No Jupyter notebooks to backup"

    # Jupyter data (datasets and additional data)
    log_info "  Backing up Jupyter data..."
    compose_cmd exec -T jupyter tar czf - /home/jovyan/data 2>/dev/null \
        > "$BACKUP_DIR/$BACKUP_NAME/jupyter_data.tar.gz" || log_warning "No Jupyter data to backup"

    log_success "Volume backups completed"
}

# =============================================================================
# Execute Backup
# =============================================================================
case $BACKUP_TYPE in
    "db-only")
        backup_databases
        ;;
    "full")
        backup_databases
        backup_config
        backup_volumes
        ;;
    *)
        backup_databases
        backup_config
        ;;
esac

# Create backup manifest
cat > "$BACKUP_DIR/$BACKUP_NAME/manifest.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "type": "$BACKUP_TYPE",
    "postgres_mode": "$POSTGRES_MODE",
    "platform_db": "$PLATFORM_DB",
    "superset_db": "$SUPERSET_DB",
    "created_at": "$(date -Iseconds)",
    "version": "$(grep '^IMAGE_TAG=' "$DEPLOY_DIR/.env" 2>/dev/null | cut -d= -f2 || echo 'unknown')",
    "contents": {
        "databases": ["$PLATFORM_DB", "$SUPERSET_DB"],
        "volumes": $(if [[ "$BACKUP_TYPE" == "full" ]]; then echo '["uploads", "ml_models", "superset_home", "ml_storage", "training_data", "plugins", "celery_beat_schedule", "workflow_configs", "jupyter_notebooks", "jupyter_data"]'; else echo '[]'; fi),
        "config": $(if [[ "$BACKUP_TYPE" != "db-only" ]]; then echo 'true'; else echo 'false'; fi)
    }
}
EOF

# Compress backup
log_info "Compressing backup..."
cd "$BACKUP_DIR"
tar -czf "$BACKUP_NAME.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"

# Restrict backup permissions (contains secrets in .env)
chmod 600 "$BACKUP_NAME.tar.gz"

BACKUP_SIZE=$(du -h "$BACKUP_NAME.tar.gz" | cut -f1)
log_success "Backup compressed: $BACKUP_SIZE"

# Cleanup old backups
log_info "Cleaning up old backups (keeping last $RETENTION)..."
ls -t "$BACKUP_DIR"/pravaha_backup_*.tar.gz 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -f

echo ""
echo "=============================================="
log_success "Backup completed successfully!"
echo "=============================================="
echo "File:     $BACKUP_DIR/$BACKUP_NAME.tar.gz"
echo "Size:     $BACKUP_SIZE"
echo ""
echo "To restore: ./restore.sh $BACKUP_DIR/$BACKUP_NAME.tar.gz"
