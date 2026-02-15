#!/bin/bash
# =============================================================================
# Pravaha Platform - Restore Script
# Restores database, configuration, and volumes from backup
# =============================================================================
#
# Usage:
#   ./restore.sh <backup_file.tar.gz>              # Full restore
#   ./restore.sh <backup_file.tar.gz> --db-only    # Database only
#   ./restore.sh <backup_file.tar.gz> --config     # Config only
#   ./restore.sh <backup_file.tar.gz> --dry-run    # Show what would be restored
#
# =============================================================================

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"
RESTORE_TYPE="full"
DRY_RUN=false

# Parse arguments
BACKUP_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-only)
            RESTORE_TYPE="db-only"
            shift
            ;;
        --config)
            RESTORE_TYPE="config"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <backup_file.tar.gz> [options]"
    echo ""
    echo "Options:"
    echo "  --db-only    Restore databases only"
    echo "  --config     Restore configuration only"
    echo "  --dry-run    Show what would be restored"
    echo ""
    echo "Example: $0 /opt/pravaha/backups/pravaha_backup_full_20240101_120000.tar.gz"
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

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
echo "Pravaha Platform - Restore"
echo "=============================================="
echo "Backup:  $BACKUP_FILE"
echo "Type:    $RESTORE_TYPE"
echo "Mode:    POSTGRES_MODE=$POSTGRES_MODE"
echo "Dry run: $DRY_RUN"
echo ""

# Validate archive integrity before extraction
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT
log_info "Validating backup archive integrity..."
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
    log_error "Backup archive is corrupted (gzip integrity check failed)"
    log_error "File: $BACKUP_FILE"
    exit 1
fi

# Extract backup
log_info "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
BACKUP_DIR="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

# Show manifest
if [[ -f "$BACKUP_DIR/manifest.json" ]]; then
    echo "Backup manifest:"
    cat "$BACKUP_DIR/manifest.json"
    echo ""
fi

# List contents
echo "Backup contents:"
ls -la "$BACKUP_DIR"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run - no changes made"
    rm -rf "$TEMP_DIR"
    exit 0
fi

log_warning "This will OVERWRITE current data!"
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    log_info "Restore cancelled"
    rm -rf "$TEMP_DIR"
    exit 0
fi

cd "$DEPLOY_DIR"

# Concurrent execution guard (flock) -- prevents running simultaneously with update/rollback
LOCK_FILE="$DEPLOY_DIR/.pravaha-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_error "Another update, rollback, or restore operation is already in progress."
    log_error "If you're sure no other operation is running, remove: $LOCK_FILE"
    exit 1
fi

# =============================================================================
# Restore Databases
# =============================================================================
restore_databases() {
    log_info "Stopping application services..."
    compose_cmd stop backend superset ml-service celery-beat celery-worker-monitoring celery-worker-prediction celery-worker-training 2>/dev/null || true

    if [[ "$POSTGRES_MODE" == "bundled" ]]; then
        # Ensure PostgreSQL container is running before restore
        log_info "Ensuring PostgreSQL is running..."
        compose_cmd up -d postgres
        local max_wait=30
        local waited=0
        while ! compose_cmd exec -T postgres pg_isready -U "$POSTGRES_USER" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
            if [[ $waited -ge $max_wait ]]; then
                log_error "PostgreSQL did not become ready within ${max_wait}s"
                exit 1
            fi
        done
        log_success "PostgreSQL is ready"
    fi

    if [[ "$POSTGRES_MODE" == "external" ]]; then
        # External PostgreSQL: use psql/pg_restore over the network
        if ! command -v pg_restore &>/dev/null || ! command -v psql &>/dev/null; then
            log_error "pg_restore/psql not found. Install postgresql-client to restore external databases."
            exit 1
        fi

        if [[ -f "$BACKUP_DIR/${PLATFORM_DB}.dump" ]]; then
            log_info "Restoring platform database from dump (external)..."
            PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore \
                -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                --clean --if-exists \
                < "$BACKUP_DIR/${PLATFORM_DB}.dump" || {
                log_warning "pg_restore had warnings, trying SQL fallback..."
                PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                    -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                    -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                    < "$BACKUP_DIR/${PLATFORM_DB}.sql"
            }
        elif [[ -f "$BACKUP_DIR/${PLATFORM_DB}.sql" ]]; then
            log_info "Restoring platform database from SQL (external)..."
            PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                < "$BACKUP_DIR/${PLATFORM_DB}.sql"
        fi

        if [[ -f "$BACKUP_DIR/${SUPERSET_DB}.dump" ]]; then
            log_info "Restoring Superset database from dump (external)..."
            PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore \
                -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                --clean --if-exists \
                < "$BACKUP_DIR/${SUPERSET_DB}.dump" || {
                log_warning "pg_restore had warnings, trying SQL fallback..."
                PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                    -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                    -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                    < "$BACKUP_DIR/${SUPERSET_DB}.sql"
            }
        elif [[ -f "$BACKUP_DIR/${SUPERSET_DB}.sql" ]]; then
            log_info "Restoring Superset database from SQL (external)..."
            PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
                -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                < "$BACKUP_DIR/${SUPERSET_DB}.sql"
        fi
    else
        # Bundled PostgreSQL: use docker compose exec
        if [[ -f "$BACKUP_DIR/${PLATFORM_DB}.dump" ]]; then
            log_info "Restoring platform database from dump (bundled)..."
            compose_cmd exec -T postgres pg_restore \
                -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                --clean --if-exists \
                < "$BACKUP_DIR/${PLATFORM_DB}.dump" || {
                log_warning "pg_restore had warnings, trying SQL fallback..."
                compose_cmd exec -T postgres psql \
                    -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                    < "$BACKUP_DIR/${PLATFORM_DB}.sql"
            }
        elif [[ -f "$BACKUP_DIR/${PLATFORM_DB}.sql" ]]; then
            log_info "Restoring platform database from SQL (bundled)..."
            compose_cmd exec -T postgres psql \
                -U "$POSTGRES_USER" -d "$PLATFORM_DB" \
                < "$BACKUP_DIR/${PLATFORM_DB}.sql"
        fi

        if [[ -f "$BACKUP_DIR/${SUPERSET_DB}.dump" ]]; then
            log_info "Restoring Superset database from dump (bundled)..."
            compose_cmd exec -T postgres pg_restore \
                -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                --clean --if-exists \
                < "$BACKUP_DIR/${SUPERSET_DB}.dump" || {
                log_warning "pg_restore had warnings, trying SQL fallback..."
                compose_cmd exec -T postgres psql \
                    -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                    < "$BACKUP_DIR/${SUPERSET_DB}.sql"
            }
        elif [[ -f "$BACKUP_DIR/${SUPERSET_DB}.sql" ]]; then
            log_info "Restoring Superset database from SQL (bundled)..."
            compose_cmd exec -T postgres psql \
                -U "$POSTGRES_USER" -d "$SUPERSET_DB" \
                < "$BACKUP_DIR/${SUPERSET_DB}.sql"
        fi
    fi

    log_success "Database restore completed"
}

# =============================================================================
# Restore Configuration
# =============================================================================
restore_config() {
    log_info "Restoring configuration..."

    if [[ -f "$BACKUP_DIR/.env" ]]; then
        log_info "  Restoring .env (backup of current saved to .env.pre-restore)"
        cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.pre-restore" 2>/dev/null || true
        cp "$BACKUP_DIR/.env" "$DEPLOY_DIR/.env"
    fi

    if [[ -d "$BACKUP_DIR/nginx" ]]; then
        log_info "  Restoring NGINX configuration"
        cp -r "$BACKUP_DIR/nginx/"* "$DEPLOY_DIR/nginx/"
    fi

    if [[ -d "$BACKUP_DIR/ssl" ]]; then
        log_info "  Restoring SSL certificates"
        cp -r "$BACKUP_DIR/ssl/"* "$DEPLOY_DIR/ssl/"
    fi

    # Branding configuration
    if [[ -d "$BACKUP_DIR/branding" ]]; then
        log_info "  Restoring branding configuration"
        mkdir -p "$DEPLOY_DIR/branding"
        cp -r "$BACKUP_DIR/branding/"* "$DEPLOY_DIR/branding/" 2>/dev/null || true
    fi

    # Audit signature keys
    for pem_file in "$BACKUP_DIR"/audit-*.pem; do
        if [[ -f "$pem_file" ]]; then
            log_info "  Restoring $(basename "$pem_file")"
            cp "$pem_file" "$DEPLOY_DIR/"
        fi
    done

    # Admin credential files
    for cred_file in "$BACKUP_DIR"/.admin_email "$BACKUP_DIR"/.admin_password; do
        if [[ -f "$cred_file" ]]; then
            cp "$cred_file" "$DEPLOY_DIR/"
            chmod 600 "$DEPLOY_DIR/$(basename "$cred_file")"
        fi
    done

    # Monitoring configuration
    if [[ -d "$BACKUP_DIR/monitoring" ]]; then
        log_info "  Restoring monitoring configuration"
        mkdir -p "$DEPLOY_DIR/monitoring"
        cp -r "$BACKUP_DIR/monitoring/"* "$DEPLOY_DIR/monitoring/" 2>/dev/null || true
    fi

    # Logging configuration
    if [[ -d "$BACKUP_DIR/logging" ]]; then
        log_info "  Restoring logging configuration"
        mkdir -p "$DEPLOY_DIR/logging"
        cp -r "$BACKUP_DIR/logging/"* "$DEPLOY_DIR/logging/" 2>/dev/null || true
    fi

    # Docker compose overlay files
    for compose_file in "$BACKUP_DIR"/docker-compose*.yml; do
        if [[ -f "$compose_file" ]]; then
            log_info "  Restoring $(basename "$compose_file")"
            cp "$compose_file" "$DEPLOY_DIR/"
        fi
    done

    log_success "Configuration restore completed"
}

# =============================================================================
# Restore Volumes (Full restore only)
# =============================================================================
restore_volumes() {
    log_info "Restoring volumes..."

    # Start containers temporarily for volume restore (exec requires running containers)
    log_info "  Starting containers for volume restore..."
    compose_cmd up -d backend ml-service superset celery-beat jupyter 2>/dev/null || true

    # Wait for containers to be running (not healthy, just started)
    log_info "  Waiting for containers to start..."
    local max_container_wait=60
    local container_waited=0
    local required_containers=("pravaha-backend" "pravaha-ml-service" "pravaha-superset" "pravaha-celery-beat" "pravaha-jupyter")
    while [[ $container_waited -lt $max_container_wait ]]; do
        local all_running=true
        for container in "${required_containers[@]}"; do
            if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                all_running=false
                break
            fi
        done
        if [[ "$all_running" == "true" ]]; then
            break
        fi
        sleep 2
        container_waited=$((container_waited + 2))
    done
    if [[ $container_waited -ge $max_container_wait ]]; then
        log_warning "  Some containers may not be fully started; volume restore may have partial results"
    fi

    if [[ -f "$BACKUP_DIR/uploads.tar.gz" ]]; then
        log_info "  Restoring uploads..."
        compose_cmd exec -T backend tar xzf - -C / < "$BACKUP_DIR/uploads.tar.gz" || log_warning "Could not restore uploads"
    fi

    if [[ -f "$BACKUP_DIR/ml_models.tar.gz" ]]; then
        log_info "  Restoring ML models..."
        compose_cmd exec -T ml-service tar xzf - -C / < "$BACKUP_DIR/ml_models.tar.gz" || log_warning "Could not restore ML models"
    fi

    if [[ -f "$BACKUP_DIR/superset_home.tar.gz" ]]; then
        log_info "  Restoring Superset home..."
        compose_cmd exec -T superset tar xzf - -C / < "$BACKUP_DIR/superset_home.tar.gz" || log_warning "Could not restore Superset home"
    fi

    if [[ -f "$BACKUP_DIR/ml_storage.tar.gz" ]]; then
        log_info "  Restoring ML storage..."
        compose_cmd exec -T ml-service tar xzf - -C / < "$BACKUP_DIR/ml_storage.tar.gz" || log_warning "Could not restore ML storage"
    fi

    if [[ -f "$BACKUP_DIR/training_data.tar.gz" ]]; then
        log_info "  Restoring training data..."
        compose_cmd exec -T ml-service tar xzf - -C / < "$BACKUP_DIR/training_data.tar.gz" || log_warning "Could not restore training data"
    fi

    if [[ -f "$BACKUP_DIR/plugins.tar.gz" ]]; then
        log_info "  Restoring plugins..."
        compose_cmd exec -T backend tar xzf - -C / < "$BACKUP_DIR/plugins.tar.gz" || log_warning "Could not restore plugins"
    fi

    if [[ -f "$BACKUP_DIR/celery_beat_schedule.tar.gz" ]]; then
        log_info "  Restoring celery beat schedule..."
        compose_cmd exec -T celery-beat tar xzf - -C / < "$BACKUP_DIR/celery_beat_schedule.tar.gz" || log_warning "Could not restore celery beat schedule"
    fi

    if [[ -f "$BACKUP_DIR/workflow_configs.tar.gz" ]]; then
        log_info "  Restoring workflow configs..."
        compose_cmd exec -T backend tar xzf - -C / < "$BACKUP_DIR/workflow_configs.tar.gz" || log_warning "Could not restore workflow configs"
    fi

    if [[ -f "$BACKUP_DIR/jupyter_notebooks.tar.gz" ]]; then
        log_info "  Restoring Jupyter notebooks..."
        compose_cmd exec -T jupyter tar xzf - -C / < "$BACKUP_DIR/jupyter_notebooks.tar.gz" || log_warning "Could not restore Jupyter notebooks"
    fi

    if [[ -f "$BACKUP_DIR/jupyter_data.tar.gz" ]]; then
        log_info "  Restoring Jupyter data..."
        compose_cmd exec -T jupyter tar xzf - -C / < "$BACKUP_DIR/jupyter_data.tar.gz" || log_warning "Could not restore Jupyter data"
    fi

    # Stop containers again before the final full restart
    compose_cmd stop backend ml-service superset celery-beat jupyter 2>/dev/null || true

    log_success "Volume restore completed"
}

# =============================================================================
# Execute Restore
# =============================================================================
case $RESTORE_TYPE in
    "db-only")
        restore_databases
        ;;
    "config")
        restore_config
        ;;
    *)
        restore_databases
        restore_config
        # Check if this is a full backup with volumes
        if [[ -f "$BACKUP_DIR/uploads.tar.gz" ]] || [[ -f "$BACKUP_DIR/ml_models.tar.gz" ]] || [[ -f "$BACKUP_DIR/superset_home.tar.gz" ]] || [[ -f "$BACKUP_DIR/ml_storage.tar.gz" ]] || [[ -f "$BACKUP_DIR/training_data.tar.gz" ]] || [[ -f "$BACKUP_DIR/plugins.tar.gz" ]] || [[ -f "$BACKUP_DIR/celery_beat_schedule.tar.gz" ]] || [[ -f "$BACKUP_DIR/workflow_configs.tar.gz" ]] || [[ -f "$BACKUP_DIR/jupyter_notebooks.tar.gz" ]] || [[ -f "$BACKUP_DIR/jupyter_data.tar.gz" ]]; then
            restore_volumes
        fi
        ;;
esac

# Restart services
log_info "Starting services (POSTGRES_MODE=$POSTGRES_MODE)..."
compose_cmd up -d

echo ""
log_info "Waiting for core services to become ready..."
max_stabilize_wait=120
stabilize_waited=0
core_services=("pravaha-backend" "pravaha-redis")
if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
    core_services+=("pravaha-postgres")
fi
while [[ $stabilize_waited -lt $max_stabilize_wait ]]; do
    all_core_ready=true
    for svc in "${core_services[@]}"; do
        svc_status=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "not_found")
        if [[ "$svc_status" != "healthy" ]]; then
            all_core_ready=false
            break
        fi
    done
    if [[ "$all_core_ready" == "true" ]]; then
        log_success "Core services are ready"
        break
    fi
    sleep 5
    stabilize_waited=$((stabilize_waited + 5))
done
if [[ $stabilize_waited -ge $max_stabilize_wait ]]; then
    log_warning "Core services did not become healthy within ${max_stabilize_wait}s, proceeding with health check..."
fi

# Post-restore health check
if [[ -x "$DEPLOY_DIR/scripts/health-check.sh" ]]; then
    log_info "Running health check..."
    local health_exit=0
    "$DEPLOY_DIR/scripts/health-check.sh" --quiet --exit-code 2>&1 || health_exit=$?
    if [[ $health_exit -eq 0 ]]; then
        log_success "All services are healthy after restore"
    elif [[ $health_exit -eq 2 ]]; then
        log_error "CRITICAL: Core services failed health check after restore"
        log_error "Check service status: docker compose ps"
        log_error "View logs: docker compose logs"
        exit 2
    else
        log_warning "Some services may not be healthy yet"
        log_info "Check service status: docker compose ps"
        log_info "View logs: docker compose logs"
    fi
else
    log_info "Health check script not found, skipping post-restore verification"
fi

echo ""
echo "=============================================="
log_success "Restore completed!"
echo "=============================================="
echo ""
echo "Verify with: docker compose ps"
echo "             ./scripts/health-check.sh"
