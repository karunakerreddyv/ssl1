#!/bin/bash
# =============================================================================
# Pravaha Platform - Restore Script
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Restores application configuration and Docker volumes from backup.
#   Database restoration should be performed separately on the database server.
#
# Usage:
#   ./restore.sh <backup_file.tar.gz>              # Full restore
#   ./restore.sh <backup_file.tar.gz> --config     # Config only
#   ./restore.sh <backup_file.tar.gz> --volumes    # Volumes only
#   ./restore.sh <backup_file.tar.gz> --dry-run    # Show what would be restored
#
# Architecture Notes:
#   - This script does NOT restore database (done on database server)
#   - Restores Docker volumes for app services (redis, superset, ml-models, etc.)
#   - Restores configuration files (.env, nginx, ssl)
#   - Coordinate with database server admin for complete disaster recovery
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "$SCRIPT_DIR")}"

# Configuration
RESTORE_TYPE="full"
DRY_RUN=false
SKIP_DB_WARNING=false

# =============================================================================
# Parse Arguments
# =============================================================================
BACKUP_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            RESTORE_TYPE="config"
            shift
            ;;
        --volumes)
            RESTORE_TYPE="volumes"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-db-warning)
            SKIP_DB_WARNING=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <backup_file.tar.gz> [options]"
            echo ""
            echo "Options:"
            echo "  --config          Restore configuration only"
            echo "  --volumes         Restore Docker volumes only"
            echo "  --dry-run         Show what would be restored"
            echo "  --skip-db-warning Skip database restore warning"
            echo ""
            echo "Example: $0 backups/pravaha_backup_20240101_120000.tar.gz"
            echo ""
            echo "Note: Database restoration must be performed on the database server."
            echo "      This script only restores app server components."
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

# =============================================================================
# Colors and Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Validate Backup File
# =============================================================================
if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <backup_file.tar.gz> [options]"
    echo ""
    echo "Options:"
    echo "  --config          Restore configuration only"
    echo "  --volumes         Restore Docker volumes only"
    echo "  --dry-run         Show what would be restored"
    echo ""
    echo "Example: $0 backups/pravaha_backup_20240101_120000.tar.gz"
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    # Try relative to backup directory
    if [[ -f "$DEPLOY_DIR/backups/$BACKUP_FILE" ]]; then
        BACKUP_FILE="$DEPLOY_DIR/backups/$BACKUP_FILE"
    else
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
fi

# =============================================================================
# Load Environment
# =============================================================================
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi


# =============================================================================
# Display Restore Information
# =============================================================================
echo "=============================================="
echo "Pravaha Platform - Restore (App Server)"
echo "=============================================="
echo "Deployment:  Two-Server (App Server)"
echo "Backup:      $(basename "$BACKUP_FILE")"
echo "Type:        $RESTORE_TYPE"
echo "Dry run:     $DRY_RUN"
echo ""

# =============================================================================
# Extract Backup
# =============================================================================
log_info "Extracting backup..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
BACKUP_DIR="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

# =============================================================================
# Show Backup Contents
# =============================================================================
echo "Backup contents:"
ls -la "$BACKUP_DIR"
echo ""

# Check for manifest
if [[ -f "$BACKUP_DIR/manifest.json" ]]; then
    echo "Backup manifest:"
    cat "$BACKUP_DIR/manifest.json" | jq . 2>/dev/null || cat "$BACKUP_DIR/manifest.json"
    echo ""
fi

# Check for database dumps (to warn user)
HAS_DATABASE_BACKUP=false
if [[ -d "$BACKUP_DIR/database" ]]; then
    if ls "$BACKUP_DIR/database/"*.dump 2>/dev/null | head -1 > /dev/null; then
        HAS_DATABASE_BACKUP=true
    fi
fi

# =============================================================================
# Dry Run Mode
# =============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN - no changes will be made"
    echo ""
    echo "Would restore the following:"

    if [[ "$RESTORE_TYPE" == "full" ]] || [[ "$RESTORE_TYPE" == "config" ]]; then
        echo ""
        echo "Configuration files:"
        [[ -f "$BACKUP_DIR/configs/.env" ]] && echo "  - .env"
        [[ -d "$BACKUP_DIR/configs/nginx" ]] && echo "  - nginx configuration"
        [[ -d "$BACKUP_DIR/configs/ssl" ]] && echo "  - SSL certificates"
        [[ -f "$BACKUP_DIR/configs/audit-private.pem" ]] && echo "  - Audit keys"
    fi

    if [[ "$RESTORE_TYPE" == "full" ]] || [[ "$RESTORE_TYPE" == "volumes" ]]; then
        echo ""
        echo "Docker volumes:"
        for vol in "$BACKUP_DIR/volumes/"*.tar.gz; do
            [[ -f "$vol" ]] && echo "  - $(basename "$vol" .tar.gz)"
        done 2>/dev/null
    fi

    if [[ "$HAS_DATABASE_BACKUP" == "true" ]]; then
        echo ""
        log_warning "Backup contains database dumps."
        log_warning "Database restore must be performed on the database server."
        echo "  Database dumps found in backup:"
        ls "$BACKUP_DIR/database/"*.dump 2>/dev/null | while read f; do
            echo "    - $(basename "$f")"
        done
    fi

    rm -rf "$TEMP_DIR"
    trap - EXIT
    exit 0
fi

# =============================================================================
# Confirmation
# =============================================================================
echo ""
log_warning "This will OVERWRITE current data on the app server!"
echo ""

if [[ "$HAS_DATABASE_BACKUP" == "true" ]] && [[ "$SKIP_DB_WARNING" != "true" ]]; then
    log_warning "IMPORTANT: This backup contains database dumps."
    log_warning "Database restoration must be done separately on the database server."
    log_warning "Coordinate with your database administrator for complete recovery."
    echo ""
fi

read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    log_info "Restore cancelled"
    rm -rf "$TEMP_DIR"
    trap - EXIT
    exit 0
fi

cd "$DEPLOY_DIR"

# =============================================================================
# Restore Configuration
# =============================================================================
restore_config() {
    log_info "Restoring configuration files..."

    local config_dir="$BACKUP_DIR/configs"

    if [[ ! -d "$config_dir" ]]; then
        # Try alternate location (older backup format)
        config_dir="$BACKUP_DIR"
    fi

    # Restore .env
    if [[ -f "$config_dir/.env" ]]; then
        log_info "  Restoring .env (backup saved to .env.pre-restore)"
        cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.pre-restore" 2>/dev/null || true
        cp "$config_dir/.env" "$DEPLOY_DIR/.env"
        chmod 600 "$DEPLOY_DIR/.env"
        log_success "  .env restored"
    fi

    # Restore docker-compose files
    for compose_file in "$config_dir"/docker-compose*.yml; do
        if [[ -f "$compose_file" ]]; then
            local filename=$(basename "$compose_file")
            log_info "  Restoring $filename"
            cp "$DEPLOY_DIR/$filename" "$DEPLOY_DIR/${filename}.pre-restore" 2>/dev/null || true
            cp "$compose_file" "$DEPLOY_DIR/$filename"
        fi
    done

    # Restore NGINX configuration
    if [[ -d "$config_dir/nginx" ]]; then
        log_info "  Restoring NGINX configuration"
        cp -r "$DEPLOY_DIR/nginx" "$DEPLOY_DIR/nginx.pre-restore" 2>/dev/null || true
        cp -r "$config_dir/nginx/"* "$DEPLOY_DIR/nginx/"
        log_success "  NGINX configuration restored"
    fi

    # Restore SSL certificates
    if [[ -d "$config_dir/ssl" ]]; then
        log_info "  Restoring SSL certificates"
        mkdir -p "$DEPLOY_DIR/ssl"
        cp -r "$config_dir/ssl/"* "$DEPLOY_DIR/ssl/"
        chmod -R 600 "$DEPLOY_DIR/ssl"
        log_success "  SSL certificates restored"
    fi

    # Restore audit keys
    for pem_file in "$config_dir"/audit-*.pem; do
        if [[ -f "$pem_file" ]]; then
            log_info "  Restoring $(basename "$pem_file")"
            cp "$pem_file" "$DEPLOY_DIR/"
            chmod 600 "$DEPLOY_DIR/$(basename "$pem_file")" 2>/dev/null || true
        fi
    done

    # Admin credential files
    for cred_file in "$config_dir"/.admin_email "$config_dir"/.admin_password; do
        if [[ -f "$cred_file" ]]; then
            cp "$cred_file" "$DEPLOY_DIR/"
            chmod 600 "$DEPLOY_DIR/$(basename "$cred_file")"
        fi
    done

    # Branding configuration
    if [[ -d "$config_dir/branding" ]]; then
        log_info "  Restoring branding configuration"
        mkdir -p "$DEPLOY_DIR/branding"
        cp -r "$config_dir/branding/"* "$DEPLOY_DIR/branding/" 2>/dev/null || true
        log_success "  Branding configuration restored"
    fi

    # Monitoring configuration
    if [[ -d "$config_dir/monitoring" ]]; then
        log_info "  Restoring monitoring configuration"
        mkdir -p "$DEPLOY_DIR/monitoring"
        cp -r "$config_dir/monitoring/"* "$DEPLOY_DIR/monitoring/" 2>/dev/null || true
        log_success "  Monitoring configuration restored"
    fi

    # Logging configuration
    if [[ -d "$config_dir/logging" ]]; then
        log_info "  Restoring logging configuration"
        mkdir -p "$DEPLOY_DIR/logging"
        cp -r "$config_dir/logging/"* "$DEPLOY_DIR/logging/" 2>/dev/null || true
        log_success "  Logging configuration restored"
    fi

    log_success "Configuration restore completed"
}

# =============================================================================
# Restore Volumes
# =============================================================================
restore_volumes() {
    log_info "Restoring Docker volumes..."

    local volumes_dir="$BACKUP_DIR/volumes"

    if [[ ! -d "$volumes_dir" ]]; then
        log_warning "No volumes directory found in backup"
        return 0
    fi

    # Stop services before volume restore
    log_info "Stopping services for volume restore..."
    docker compose stop 2>/dev/null || true

    # Get project name from directory
    local project=$(basename "$DEPLOY_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    if [[ -z "$project" ]]; then
        project="app-server"
    fi

    # Volumes to restore (app server only - no postgres_data)
    local volume_files=$(ls "$volumes_dir"/*.tar.gz 2>/dev/null || true)

    if [[ -z "$volume_files" ]]; then
        log_warning "No volume backups found"
        return 0
    fi

    for vol_file in $volume_files; do
        local vol_name=$(basename "$vol_file" .tar.gz)

        # Skip Jupyter volumes - they use container exec restore (handled below)
        if [[ "$vol_name" == "jupyter_notebooks" ]] || [[ "$vol_name" == "jupyter_data" ]]; then
            continue
        fi

        local full_vol="${project}_${vol_name}"

        log_info "  Restoring volume: $vol_name"

        # Create volume if it doesn't exist
        docker volume create "$full_vol" 2>/dev/null || true

        # Restore volume data
        if docker run --rm \
            -v "$full_vol:/target" \
            -v "$(dirname "$vol_file"):/backup:ro" \
            alpine sh -c "rm -rf /target/* && tar xzf /backup/$(basename "$vol_file") -C /target" 2>/dev/null; then
            log_success "    Volume $vol_name restored"
        else
            log_warning "    Failed to restore volume $vol_name"
        fi
    done

    # Restore plugins and solution packs via container exec (backups contain absolute paths)
    if [[ -f "$volumes_dir/plugins.tar.gz" ]] || [[ -f "$volumes_dir/solution_packs.tar.gz" ]]; then
        log_info "  Starting backend container for volume restore..."
        docker compose up -d backend 2>/dev/null || true
        sleep 5

        if [[ -f "$volumes_dir/plugins.tar.gz" ]]; then
            log_info "  Restoring plugins..."
            docker compose exec -T backend tar xzf - -C / < "$volumes_dir/plugins.tar.gz" || log_warning "Could not restore plugins"
            log_success "    Plugins restored"
        fi

        if [[ -f "$volumes_dir/solution_packs.tar.gz" ]]; then
            log_info "  Restoring solution packs..."
            docker compose exec -T backend tar xzf - -C / < "$volumes_dir/solution_packs.tar.gz" || log_warning "Could not restore solution packs"
            log_success "    Solution packs restored"
        fi

        docker compose stop backend 2>/dev/null || true
    fi

    # Restore Jupyter volumes via container exec (backups contain absolute paths)
    if [[ -f "$volumes_dir/jupyter_notebooks.tar.gz" ]] || [[ -f "$volumes_dir/jupyter_data.tar.gz" ]]; then
        log_info "  Starting Jupyter container for volume restore..."
        docker compose up -d jupyter 2>/dev/null || true
        sleep 5

        if [[ -f "$volumes_dir/jupyter_notebooks.tar.gz" ]]; then
            log_info "  Restoring Jupyter notebooks..."
            docker compose exec -T jupyter tar xzf - -C / < "$volumes_dir/jupyter_notebooks.tar.gz" || log_warning "Could not restore Jupyter notebooks"
            log_success "    Jupyter notebooks restored"
        fi

        if [[ -f "$volumes_dir/jupyter_data.tar.gz" ]]; then
            log_info "  Restoring Jupyter data..."
            docker compose exec -T jupyter tar xzf - -C / < "$volumes_dir/jupyter_data.tar.gz" || log_warning "Could not restore Jupyter data"
            log_success "    Jupyter data restored"
        fi

        docker compose stop jupyter 2>/dev/null || true
    fi

    log_success "Volume restore completed"
}

# =============================================================================
# Execute Restore
# =============================================================================
case $RESTORE_TYPE in
    "config")
        restore_config
        ;;
    "volumes")
        restore_volumes
        ;;
    *)
        # Full restore
        restore_config
        restore_volumes
        ;;
esac

# =============================================================================
# Restart Services
# =============================================================================
log_info "Starting services..."
docker compose up -d

# Wait for services to start
log_info "Waiting for services to become healthy..."
sleep 30

# =============================================================================
# Validate External Database Connection
# =============================================================================
log_info "Validating external database connectivity..."
if [[ -x "$SCRIPT_DIR/validate-external-db.sh" ]]; then
    if "$SCRIPT_DIR/validate-external-db.sh" --quiet; then
        log_success "External database connection verified"
    else
        log_warning "External database connection could not be verified"
        log_warning "Check database server status and .env configuration"
    fi
fi

# =============================================================================
# Cleanup
# =============================================================================
rm -rf "$TEMP_DIR"
trap - EXIT

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
log_success "Restore completed successfully!"
echo "=============================================="
echo ""
echo "Verify with:"
echo "  docker compose ps"
echo "  ./scripts/health-check.sh"
echo ""

if [[ "$HAS_DATABASE_BACKUP" == "true" ]]; then
    echo "=============================================="
    log_warning "IMPORTANT: Database Restoration Required"
    echo "=============================================="
    echo ""
    echo "The backup contained database dumps that were NOT restored."
    echo "To complete disaster recovery:"
    echo ""
    echo "1. Copy database dumps to database server:"
    echo "   scp $BACKUP_FILE db-server:/tmp/"
    echo ""
    echo "2. On database server, extract and restore:"
    echo "   tar xzf /tmp/$(basename "$BACKUP_FILE")"
    echo "   pg_restore -U postgres -d autoanalytics < database/autoanalytics.dump"
    echo "   pg_restore -U postgres -d superset < database/superset.dump"
    echo ""
fi
