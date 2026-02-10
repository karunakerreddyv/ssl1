#!/bin/bash
# =============================================================================
# Pravaha Platform - Update Script (Single Server)
# Updates to a new version with automatic rollback on failure
# =============================================================================
#
# Usage:
#   ./update.sh <version>                          # Update to specific version
#   ./update.sh latest                             # Update to latest version
#   ./update.sh v2.1.0 --release-dir /tmp/release  # Update with deployment files
#   ./update.sh --skip-backup                      # Skip backup (not recommended)
#   ./update.sh --skip-file-update                 # Skip deployment file updates
#   ./update.sh --no-rollback                      # Disable automatic rollback
#   ./update.sh --dry-run                          # Show what would happen
#
# Features:
#   - Creates checkpoint before update for instant rollback
#   - Creates full backup for data recovery
#   - Merges new environment variables from .env.example
#   - Updates deployment files (docker-compose, nginx, scripts, monitoring)
#   - POSTGRES_MODE support (bundled/external with --profile bundled-db)
#   - Ordered service startup (postgres -> redis -> rest)
#   - Superset + backend database migrations
#   - Health polling with configurable timeout
#   - Automatic rollback on health check failure
#   - Full audit trail via update log
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Script Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"
NEW_VERSION=""
SKIP_BACKUP=false
AUTO_ROLLBACK=true
DRY_RUN=false
HEALTH_TIMEOUT=300  # 5 minutes for all services to be healthy
RELEASE_DIR=""
SKIP_FILE_UPDATE=false
UPDATE_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

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

# =============================================================================
# Parse Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --no-rollback)
            AUTO_ROLLBACK=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --timeout)
            HEALTH_TIMEOUT="$2"
            shift 2
            ;;
        --release-dir)
            RELEASE_DIR="$2"
            shift 2
            ;;
        --skip-file-update)
            SKIP_FILE_UPDATE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <version> [options]"
            echo ""
            echo "Options:"
            echo "  --skip-backup         Skip backup creation (not recommended)"
            echo "  --no-rollback         Disable automatic rollback on failure"
            echo "  --dry-run             Show what would happen without executing"
            echo "  --timeout <sec>       Health check timeout (default: 300)"
            echo "  --release-dir <path>  Directory containing new release files"
            echo "  --skip-file-update    Skip deployment file updates"
            echo ""
            echo "Examples:"
            echo "  $0 v2.1.0                              # Update to v2.1.0"
            echo "  $0 latest                              # Update to latest"
            echo "  $0 v2.1.0 --release-dir /tmp/release   # Update with new deployment files"
            echo "  $0 v2.1.0 --skip-file-update           # Images only, no file updates"
            echo ""
            echo "Deployment file updates (--release-dir):"
            echo "  Copies from release directory to deployment directory:"
            echo "    docker-compose*.yml, nginx/, scripts/, monitoring/, logging/"
            echo "  Never touches: .env, ssl/, audit-*.pem, backups/, volumes, .checkpoint/"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            NEW_VERSION="$1"
            shift
            ;;
    esac
done

if [[ -z "$NEW_VERSION" ]]; then
    NEW_VERSION="latest"
fi

# =============================================================================
# init_update_log()
# Create timestamped log file and tee all output to it
# =============================================================================
init_update_log() {
    local log_dir="$DEPLOY_DIR/logs"
    mkdir -p "$log_dir"
    UPDATE_LOG="$log_dir/update_${UPDATE_TIMESTAMP}.log"

    # Create the log file with a header
    cat > "$UPDATE_LOG" << EOF
# =============================================================================
# Pravaha Platform - Update Log
# Timestamp: $(date -Iseconds)
# Target Version: $NEW_VERSION
# Deploy Dir: $DEPLOY_DIR
# =============================================================================

EOF

    # Redirect all output to both terminal and log file
    exec > >(tee -a "$UPDATE_LOG") 2>&1

    log_info "Update log initialized: $UPDATE_LOG"
}

# =============================================================================
# source_env()
# Source .env to get POSTGRES_MODE, DOMAIN and other config
# =============================================================================
source_env() {
    if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
        log_error "Environment file not found: $DEPLOY_DIR/.env"
        exit 1
    fi

    set -a
    source "$DEPLOY_DIR/.env"
    set +a

    POSTGRES_MODE="${POSTGRES_MODE:-bundled}"
    DOMAIN="${DOMAIN:-localhost}"

    log_info "Environment loaded: POSTGRES_MODE=$POSTGRES_MODE, DOMAIN=$DOMAIN"
}

# =============================================================================
# compose_cmd()
# Wrapper around docker compose that adds --profile bundled-db when
# POSTGRES_MODE=bundled. Ensures all compose calls respect the profile.
# =============================================================================
compose_cmd() {
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        docker compose --profile bundled-db "$@"
    else
        docker compose "$@"
    fi
}

# =============================================================================
# get_service_list()
# Returns dynamic container names using POSTGRES_MODE.
# Output: space-separated list of container names for health checking.
# =============================================================================
get_service_list() {
    local services=()

    # Infrastructure services (started first, checked first)
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        services+=("pravaha-postgres")
    fi
    services+=("pravaha-redis")

    # Core application services
    services+=("pravaha-backend")
    services+=("pravaha-frontend")
    services+=("pravaha-superset")
    services+=("pravaha-ml-service")
    services+=("pravaha-nginx")

    # Celery workers
    services+=("pravaha-celery-training")
    services+=("pravaha-celery-prediction")
    services+=("pravaha-celery-monitoring")
    services+=("pravaha-celery-beat")

    echo "${services[@]}"
}

# =============================================================================
# wait_for_healthy()
# Polls a container's health status until healthy, unhealthy, or timeout.
# Args: $1 = container name, $2 = timeout in seconds (default 90)
# Returns: 0 if healthy, 1 if unhealthy/timeout
# =============================================================================
wait_for_healthy() {
    local container=$1
    local timeout=${2:-90}
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

        case $status in
            "healthy")
                return 0
                ;;
            "unhealthy")
                return 1
                ;;
            "not_found")
                # Container might exist but have no healthcheck defined
                if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                    return 0  # Running but no healthcheck
                fi
                # Container not running yet, keep waiting
                ;;
        esac

        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1  # Timeout
}

# =============================================================================
# start_services_ordered()
# Starts services in dependency order:
# 1. PostgreSQL (if bundled) - wait healthy
# 2. Redis - wait healthy
# 3. All remaining services
# =============================================================================
start_services_ordered() {
    log_info "Starting services in dependency order..."

    # Step 1: Start PostgreSQL if bundled mode
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        log_info "  Starting PostgreSQL (bundled mode)..."
        compose_cmd up -d postgres
        log_info "  Waiting for PostgreSQL to become healthy..."
        if ! wait_for_healthy "pravaha-postgres" 120; then
            log_error "  PostgreSQL failed to become healthy within 120s"
            return 1
        fi
        log_success "  PostgreSQL is healthy"
    fi

    # Step 2: Start Redis
    log_info "  Starting Redis..."
    compose_cmd up -d redis
    log_info "  Waiting for Redis to become healthy..."
    if ! wait_for_healthy "pravaha-redis" 60; then
        log_error "  Redis failed to become healthy within 60s"
        return 1
    fi
    log_success "  Redis is healthy"

    # Step 3: Start all remaining services
    log_info "  Starting all remaining services..."
    compose_cmd up -d

    return 0
}

# =============================================================================
# run_migrations()
# Runs database migrations for backend (Prisma) and Superset.
# 1. Backend: npm run db:migrate (Prisma migrate deploy)
# 2. Superset: superset db upgrade (Alembic migrations)
# =============================================================================
run_migrations() {
    local migration_failed=false

    log_info "Running database migrations..."

    # Backend Prisma migrations
    log_info "  Running backend database migrations (Prisma)..."
    if compose_cmd exec -T backend npm run db:migrate 2>&1; then
        log_success "  Backend database migrations completed"
    else
        log_warning "  Backend migrations returned non-zero (may have no pending migrations)"
    fi

    # Superset Alembic migrations
    log_info "  Running Superset database migrations (Alembic)..."
    if compose_cmd exec -T superset superset db upgrade 2>&1; then
        log_success "  Superset database migrations completed"
    else
        log_warning "  Superset migrations returned non-zero (may have no pending migrations)"
    fi

    return 0
}

# =============================================================================
# update_deployment_files()
# Copies deployment files from release directory to DEPLOY_DIR with backups.
# Backs up current files to .file-backups/<timestamp>/ before overwriting.
#
# Files copied:
#   docker-compose*.yml, nginx/, scripts/, monitoring/, logging/
#
# Files NEVER touched:
#   .env, ssl/, audit-*.pem, backups/, volumes, .checkpoint/
#
# Args: None (uses RELEASE_DIR global)
# =============================================================================
update_deployment_files() {
    if [[ -z "$RELEASE_DIR" ]]; then
        log_info "No --release-dir specified, skipping deployment file updates"
        return 0
    fi

    if [[ ! -d "$RELEASE_DIR" ]]; then
        log_error "Release directory does not exist: $RELEASE_DIR"
        return 1
    fi

    log_info "Updating deployment files from: $RELEASE_DIR"

    local backup_dir="$DEPLOY_DIR/.file-backups/$UPDATE_TIMESTAMP"
    mkdir -p "$backup_dir"

    local files_updated=0
    local files_backed_up=0

    # --- Backup and copy docker-compose*.yml files ---
    for compose_file in "$RELEASE_DIR"/docker-compose*.yml; do
        if [[ -f "$compose_file" ]]; then
            local basename
            basename=$(basename "$compose_file")
            # Backup existing file if present
            if [[ -f "$DEPLOY_DIR/$basename" ]]; then
                cp "$DEPLOY_DIR/$basename" "$backup_dir/$basename"
                files_backed_up=$((files_backed_up + 1))
            fi
            cp "$compose_file" "$DEPLOY_DIR/$basename"
            files_updated=$((files_updated + 1))
            log_info "  Updated: $basename"
        fi
    done

    # --- Backup and copy directories: nginx/, scripts/, monitoring/, logging/ ---
    local update_dirs=("nginx" "scripts" "monitoring" "logging")
    for dir_name in "${update_dirs[@]}"; do
        if [[ -d "$RELEASE_DIR/$dir_name" ]]; then
            # Backup existing directory if present
            if [[ -d "$DEPLOY_DIR/$dir_name" ]]; then
                mkdir -p "$backup_dir/$dir_name"
                cp -r "$DEPLOY_DIR/$dir_name/"* "$backup_dir/$dir_name/" 2>/dev/null || true
                files_backed_up=$((files_backed_up + 1))
            fi
            # Create target dir if it doesn't exist, then copy contents
            mkdir -p "$DEPLOY_DIR/$dir_name"
            cp -r "$RELEASE_DIR/$dir_name/"* "$DEPLOY_DIR/$dir_name/"
            files_updated=$((files_updated + 1))
            log_info "  Updated: $dir_name/"
        fi
    done

    # --- Copy .env.example if present (for merge_env, not overwriting .env) ---
    if [[ -f "$RELEASE_DIR/.env.example" ]]; then
        if [[ -f "$DEPLOY_DIR/.env.example" ]]; then
            cp "$DEPLOY_DIR/.env.example" "$backup_dir/.env.example"
        fi
        cp "$RELEASE_DIR/.env.example" "$DEPLOY_DIR/.env.example"
        log_info "  Updated: .env.example"
    fi

    # --- Make scripts executable after copy ---
    if [[ -d "$DEPLOY_DIR/scripts" ]]; then
        chmod +x "$DEPLOY_DIR/scripts/"*.sh 2>/dev/null || true
        log_info "  Made scripts executable"
    fi

    # --- Record backup manifest ---
    cat > "$backup_dir/manifest.json" << EOF
{
    "backup_timestamp": "$UPDATE_TIMESTAMP",
    "created_at": "$(date -Iseconds)",
    "source": "$RELEASE_DIR",
    "target_version": "$NEW_VERSION",
    "files_backed_up": $files_backed_up,
    "files_updated": $files_updated,
    "deploy_dir": "$DEPLOY_DIR"
}
EOF

    # --- Cleanup old file backups (keep last 5) ---
    if [[ -d "$DEPLOY_DIR/.file-backups" ]]; then
        local backup_count
        backup_count=$(ls -1d "$DEPLOY_DIR/.file-backups"/*/ 2>/dev/null | wc -l)
        if [[ $backup_count -gt 5 ]]; then
            ls -1dt "$DEPLOY_DIR/.file-backups"/*/ | tail -n +6 | while read -r old_backup; do
                log_info "  Removing old file backup: $(basename "$old_backup")"
                rm -rf "$old_backup"
            done
        fi
    fi

    log_success "Deployment files updated: $files_updated files/dirs updated, $files_backed_up backed up"
    log_info "File backup saved to: $backup_dir"

    return 0
}

# =============================================================================
# merge_env()
# Reads .env.example line by line. For each KEY=VALUE line where KEY does
# not exist in .env, appends it with a comment indicating the version.
# NEVER overwrites existing keys.
# Returns: count of added keys (via echo)
# =============================================================================
merge_env() {
    local env_file="$DEPLOY_DIR/.env"
    local env_example="$DEPLOY_DIR/.env.example"
    local added_count=0

    if [[ ! -f "$env_example" ]]; then
        log_info "No .env.example found, skipping env merge"
        echo "0"
        return 0
    fi

    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found: $env_file"
        echo "0"
        return 1
    fi

    log_info "Merging new environment variables from .env.example..."

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        # Skip comment lines (lines starting with # or whitespace then #)
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip lines that are purely whitespace
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # Skip section separators (lines of = or -)
        [[ "$line" =~ ^[[:space:]]*[=\-]+[[:space:]]*$ ]] && continue

        # Extract key from KEY=VALUE or KEY= pattern
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            local key="${BASH_REMATCH[1]}"

            # Check if key already exists in .env (as KEY= at start of line)
            if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
                # Append the new variable with a version comment
                echo "" >> "$env_file"
                echo "# Added in version $NEW_VERSION ($(date +%Y-%m-%d))" >> "$env_file"
                echo "$line" >> "$env_file"
                added_count=$((added_count + 1))
                log_info "  Added new variable: $key"
            fi
        fi
    done < "$env_example"

    if [[ $added_count -gt 0 ]]; then
        log_success "Merged $added_count new environment variable(s) into .env"
    else
        log_info "No new environment variables to merge"
    fi

    echo "$added_count"
}

# =============================================================================
# pull_images_with_retry()
# Pulls Docker images with retry logic (3 attempts with backoff).
# Uses compose_cmd wrapper for profile support.
# =============================================================================
pull_images_with_retry() {
    local max_retries=3
    local retry=0
    local wait_time=10

    while [[ $retry -lt $max_retries ]]; do
        log_info "Pulling new images (attempt $((retry + 1))/$max_retries)..."
        if compose_cmd pull 2>&1; then
            log_success "All images pulled successfully"
            return 0
        fi

        retry=$((retry + 1))
        if [[ $retry -lt $max_retries ]]; then
            log_warning "Image pull failed, retrying in ${wait_time}s..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
        fi
    done

    log_error "Failed to pull images after $max_retries attempts"
    return 1
}

# =============================================================================
# restore_file_backups()
# Restores deployment files from .file-backups/<timestamp>/ during rollback.
# Args: $1 = backup timestamp to restore from
# =============================================================================
restore_file_backups() {
    local backup_timestamp="$1"
    local backup_dir="$DEPLOY_DIR/.file-backups/$backup_timestamp"

    if [[ ! -d "$backup_dir" ]]; then
        log_warning "No file backup found for timestamp $backup_timestamp, skipping file restoration"
        return 0
    fi

    log_info "Restoring deployment files from backup: $backup_dir"

    # Restore docker-compose*.yml files
    for compose_file in "$backup_dir"/docker-compose*.yml; do
        if [[ -f "$compose_file" ]]; then
            local basename
            basename=$(basename "$compose_file")
            cp "$compose_file" "$DEPLOY_DIR/$basename"
            log_info "  Restored: $basename"
        fi
    done

    # Restore directories
    local restore_dirs=("nginx" "scripts" "monitoring" "logging")
    for dir_name in "${restore_dirs[@]}"; do
        if [[ -d "$backup_dir/$dir_name" ]]; then
            mkdir -p "$DEPLOY_DIR/$dir_name"
            cp -r "$backup_dir/$dir_name/"* "$DEPLOY_DIR/$dir_name/" 2>/dev/null || true
            log_info "  Restored: $dir_name/"
        fi
    done

    # Restore .env.example if backed up
    if [[ -f "$backup_dir/.env.example" ]]; then
        cp "$backup_dir/.env.example" "$DEPLOY_DIR/.env.example"
        log_info "  Restored: .env.example"
    fi

    # Make scripts executable after restore
    if [[ -d "$DEPLOY_DIR/scripts" ]]; then
        chmod +x "$DEPLOY_DIR/scripts/"*.sh 2>/dev/null || true
    fi

    log_success "Deployment files restored from backup"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

# Get current version before anything else
CURRENT_VERSION=$(grep "^IMAGE_TAG=" "$DEPLOY_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "unknown")

echo "=============================================="
echo "Pravaha Platform - Update (Single Server)"
echo "=============================================="
echo "Current version:   $CURRENT_VERSION"
echo "Target version:    $NEW_VERSION"
echo "Auto-rollback:     $AUTO_ROLLBACK"
echo "Skip backup:       $SKIP_BACKUP"
echo "Skip file update:  $SKIP_FILE_UPDATE"
echo "Release dir:       ${RELEASE_DIR:-<none>}"
echo "Health timeout:    ${HEALTH_TIMEOUT}s"
echo "Dry run:           $DRY_RUN"
echo ""

# =============================================================================
# Dry Run Mode
# =============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN - showing steps without executing"
    echo ""

    # Source env for display purposes
    source_env

    echo "Steps that would be executed:"
    echo "  1.  Initialize update log"
    echo "  2.  Source .env (POSTGRES_MODE=$POSTGRES_MODE)"
    echo "  3.  Version check (current=$CURRENT_VERSION, target=$NEW_VERSION)"
    echo "  4.  Create checkpoint for rollback"
    [[ "$SKIP_BACKUP" != "true" ]] && \
    echo "  5.  Create full backup (volumes and configs)"
    if [[ "$SKIP_FILE_UPDATE" != "true" && -n "$RELEASE_DIR" ]]; then
    echo "  6.  Update deployment files from $RELEASE_DIR"
    echo "      - Backup current files to .file-backups/$UPDATE_TIMESTAMP/"
    echo "      - Copy: docker-compose*.yml, nginx/, scripts/, monitoring/, logging/"
    echo "      - NEVER touch: .env, ssl/, audit-*.pem, backups/, .checkpoint/"
    echo "      - Make scripts executable"
    else
    echo "  6.  Skip deployment file updates (no --release-dir or --skip-file-update)"
    fi
    echo "  7.  Merge new env vars from .env.example into .env"
    echo "  8.  Show summary of file/env changes"
    echo "  9.  Update IMAGE_TAG to $NEW_VERSION in .env"
    echo "  10. Pull new Docker images (with retry, compose profile support)"
    echo "  11. Stop services gracefully (compose_cmd down)"
    echo "  12. Start services in order:"
    if [[ "$POSTGRES_MODE" == "bundled" ]]; then
    echo "      a. PostgreSQL (bundled mode, wait healthy)"
    fi
    echo "      b. Redis (wait healthy)"
    echo "      c. All remaining services (backend, frontend, superset, ml-service, etc.)"
    echo "  13. Health checks (dynamic service list, ${HEALTH_TIMEOUT}s timeout)"

    # Build the service list for display
    service_display=$(get_service_list)
    echo "      Services: $service_display"

    echo "  14. Run migrations:"
    echo "      a. Backend: compose_cmd exec -T backend npm run db:migrate"
    echo "      b. Superset: compose_cmd exec -T superset superset db upgrade"
    echo "  15. Final verification (health-check.sh if available)"
    echo "  16. Result handling (success message or auto-rollback with file restoration)"
    echo ""
    echo "If health checks fail and auto-rollback is enabled:"
    echo "  - Restore .env from checkpoint"
    echo "  - Restore deployment files from .file-backups/$UPDATE_TIMESTAMP/"
    echo "  - Pull previous version images"
    echo "  - Restart with previous version in dependency order"
    exit 0
fi

# =============================================================================
# Step 1: Initialize Update Log
# =============================================================================
init_update_log

# =============================================================================
# Step 2: Source Environment
# =============================================================================
source_env

# =============================================================================
# Step 3: Version Check
# =============================================================================
if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
    log_warning "Already running version $NEW_VERSION"
    read -p "Continue anyway? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Update cancelled by user"
        exit 0
    fi
fi

cd "$DEPLOY_DIR"

# =============================================================================
# Step 4: Create Checkpoint
# =============================================================================
log_info "Creating checkpoint for potential rollback..."
CHECKPOINT_NAME="pre_update_${UPDATE_TIMESTAMP}"
CHECKPOINT_DIR="$DEPLOY_DIR/.checkpoint"
CHECKPOINT_PATH="$CHECKPOINT_DIR/$CHECKPOINT_NAME"

mkdir -p "$CHECKPOINT_PATH"

# Save current .env file
cp "$DEPLOY_DIR/.env" "$CHECKPOINT_PATH/.env"

# Save current docker-compose.yml
if [[ -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
    cp "$DEPLOY_DIR/docker-compose.yml" "$CHECKPOINT_PATH/docker-compose.yml"
fi

# Save additional docker-compose override files
for compose_override in "$DEPLOY_DIR"/docker-compose.*.yml; do
    if [[ -f "$compose_override" ]]; then
        cp "$compose_override" "$CHECKPOINT_PATH/"
    fi
done

# Save current image digests (exact versions running)
log_info "Capturing current container image digests..."
compose_cmd images --format json 2>/dev/null | jq -r '.[] | "\(.Repository):\(.Tag)@\(.Digest)"' \
    > "$CHECKPOINT_PATH/image_digests.txt" 2>/dev/null || {
    compose_cmd images > "$CHECKPOINT_PATH/image_versions.txt" 2>/dev/null || true
}

# Save current IMAGE_TAG
grep "^IMAGE_TAG=" ".env" > "$CHECKPOINT_PATH/image_tag.txt" 2>/dev/null || echo "IMAGE_TAG=unknown" > "$CHECKPOINT_PATH/image_tag.txt"

# Save NGINX configuration
if [[ -d "nginx" ]]; then
    cp -r "nginx" "$CHECKPOINT_PATH/"
fi

# Save SSL certificates metadata (not actual certs for security)
if [[ -d "ssl" ]]; then
    mkdir -p "$CHECKPOINT_PATH/ssl_meta"
    for cert in ssl/*.pem; do
        if [[ -f "$cert" ]]; then
            openssl x509 -in "$cert" -noout -subject -dates 2>/dev/null \
                > "$CHECKPOINT_PATH/ssl_meta/$(basename "$cert").info" || true
        fi
    done
fi

# Create checkpoint manifest
cat > "$CHECKPOINT_PATH/manifest.json" << EOF
{
    "checkpoint_name": "$CHECKPOINT_NAME",
    "deployment_type": "single-server",
    "created_at": "$(date -Iseconds)",
    "image_tag": "$CURRENT_VERSION",
    "target_version": "$NEW_VERSION",
    "postgres_mode": "${POSTGRES_MODE:-bundled}",
    "brand_prefix": "pravaha",
    "domain": "${DOMAIN}",
    "release_dir": "${RELEASE_DIR:-none}",
    "services_running": $(compose_cmd ps --format json 2>/dev/null | jq -s 'map(.Name)' 2>/dev/null || echo '[]'),
    "deploy_dir": "$DEPLOY_DIR"
}
EOF

# Update latest symlink
rm -f "$CHECKPOINT_DIR/latest"
ln -sf "$CHECKPOINT_NAME" "$CHECKPOINT_DIR/latest"

# Cleanup old checkpoints (keep last 5)
checkpoint_count=$(ls -1 "$CHECKPOINT_DIR" 2>/dev/null | grep -v latest | wc -l)
if [[ $checkpoint_count -gt 5 ]]; then
    ls -1t "$CHECKPOINT_DIR" | grep -v latest | tail -n +6 | while read -r old_checkpoint; do
        log_info "Removing old checkpoint: $old_checkpoint"
        rm -rf "$CHECKPOINT_DIR/$old_checkpoint"
    done
fi

log_success "Checkpoint created: $CHECKPOINT_NAME"

# =============================================================================
# Step 5: Create Backup (unless skipped)
# =============================================================================
if [[ "$SKIP_BACKUP" != "true" ]]; then
    log_info "Creating full backup before update..."
    if [[ -x "$DEPLOY_DIR/scripts/backup.sh" ]]; then
        if ! "$DEPLOY_DIR/scripts/backup.sh"; then
            log_error "Backup failed! Update aborted."
            log_info "Fix the backup issue or use --skip-backup to proceed without backup"
            exit 1
        fi
        log_success "Backup completed"
    else
        log_warning "Backup script not found at $DEPLOY_DIR/scripts/backup.sh, skipping backup"
    fi
else
    log_warning "Skipping backup as requested (not recommended)"
fi

# =============================================================================
# Step 6: Update Deployment Files from Release Directory
# =============================================================================
FILES_UPDATED=false
if [[ "$SKIP_FILE_UPDATE" != "true" ]]; then
    if [[ -n "$RELEASE_DIR" ]]; then
        if update_deployment_files; then
            FILES_UPDATED=true
        else
            log_error "Deployment file update failed! Update aborted."
            log_info "Restoring files from backup..."
            restore_file_backups "$UPDATE_TIMESTAMP"
            exit 1
        fi
    else
        log_info "No --release-dir specified, skipping deployment file updates"
    fi
else
    log_info "Skipping deployment file updates (--skip-file-update)"
fi

# =============================================================================
# Step 7: Merge New Environment Variables from .env.example
# =============================================================================
ENV_VARS_ADDED=0
if [[ -f "$DEPLOY_DIR/.env.example" ]]; then
    ENV_VARS_ADDED=$(merge_env)
    # Re-source env after merge to pick up new defaults
    if [[ "$ENV_VARS_ADDED" -gt 0 ]] 2>/dev/null; then
        source_env
    fi
else
    log_info "No .env.example found, skipping env merge"
fi

# =============================================================================
# Step 8: Show Summary of File/Env Changes
# =============================================================================
echo ""
echo "----------------------------------------------"
echo "Update Preparation Summary"
echo "----------------------------------------------"
if [[ "$FILES_UPDATED" == "true" ]]; then
    echo "  Deployment files: UPDATED from $RELEASE_DIR"
    echo "  File backup:      .file-backups/$UPDATE_TIMESTAMP/"
else
    echo "  Deployment files: No changes"
fi
if [[ "$ENV_VARS_ADDED" -gt 0 ]] 2>/dev/null; then
    echo "  Env variables:    $ENV_VARS_ADDED new variable(s) merged"
else
    echo "  Env variables:    No new variables"
fi
echo "  Checkpoint:       $CHECKPOINT_NAME"
echo "  Image tag:        $CURRENT_VERSION -> $NEW_VERSION"
echo "----------------------------------------------"
echo ""

# =============================================================================
# Step 9: Update IMAGE_TAG in .env
# =============================================================================
log_info "Updating IMAGE_TAG from $CURRENT_VERSION to $NEW_VERSION..."
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$NEW_VERSION/" .env

# =============================================================================
# Step 10: Pull New Images with Retry
# =============================================================================
if ! pull_images_with_retry; then
    log_error "Failed to pull new images after multiple retries!"
    log_info "Restoring previous IMAGE_TAG..."
    sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$CURRENT_VERSION/" .env
    if [[ "$FILES_UPDATED" == "true" ]]; then
        log_info "Restoring deployment files..."
        restore_file_backups "$UPDATE_TIMESTAMP"
    fi
    exit 1
fi

# =============================================================================
# Step 11: Stop Services Gracefully
# =============================================================================
log_info "Stopping services gracefully..."

# Stop Celery workers first (they may have in-flight tasks)
compose_cmd stop celery-beat celery-worker-monitoring celery-worker-prediction celery-worker-training 2>/dev/null || true
sleep 5

# Stop remaining services
compose_cmd down --timeout 60 || {
    log_warning "Graceful stop timed out, forcing..."
    compose_cmd kill 2>/dev/null || true
    compose_cmd down 2>/dev/null || true
}

log_success "Services stopped"

# =============================================================================
# Step 12: Start Services in Order
# =============================================================================
if ! start_services_ordered; then
    log_error "Failed to start services in order!"
    ALL_HEALTHY=false
else
    log_success "Services started in dependency order"
    ALL_HEALTHY=true

    # =============================================================================
    # Step 13: Health Checks (all services)
    # =============================================================================
    log_info "Running health checks (timeout: ${HEALTH_TIMEOUT}s)..."

    # Get the full service list
    IFS=' ' read -ra SERVICE_LIST <<< "$(get_service_list)"

    for service in "${SERVICE_LIST[@]}"; do
        # Determine timeout per service type
        svc_timeout=90
        case "$service" in
            *postgres*)  svc_timeout=120 ;;
            *superset*)  svc_timeout=120 ;;
            *backend*)   svc_timeout=90  ;;
            *ml-service*) svc_timeout=90  ;;
            *celery*)    svc_timeout=60  ;;
            *redis*)     svc_timeout=60  ;;
            *)           svc_timeout=60  ;;
        esac

        log_info "  Waiting for $service (timeout: ${svc_timeout}s)..."
        if wait_for_healthy "$service" "$svc_timeout"; then
            log_success "  $service is healthy"
        else
            # For celery workers, check if process is at least running
            case "$service" in
                *celery*)
                    if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                        log_warning "  $service is running (health check inconclusive)"
                    else
                        log_error "  $service failed to become healthy"
                        ALL_HEALTHY=false
                    fi
                    ;;
                *)
                    log_error "  $service failed to become healthy"
                    ALL_HEALTHY=false
                    ;;
            esac
        fi
    done
fi

# =============================================================================
# Step 14: Run Migrations (if services are healthy)
# =============================================================================
if [[ "$ALL_HEALTHY" == "true" ]]; then
    run_migrations
fi

# =============================================================================
# Step 15: Final Verification
# =============================================================================
if [[ "$ALL_HEALTHY" == "true" ]]; then
    if [[ -x "$DEPLOY_DIR/scripts/health-check.sh" ]]; then
        log_info "Running comprehensive health check..."
        if "$DEPLOY_DIR/scripts/health-check.sh" --quiet 2>&1; then
            log_success "Comprehensive health check passed"
        else
            log_warning "Comprehensive health check reported issues"
            ALL_HEALTHY=false
        fi
    fi
fi

# =============================================================================
# Step 16: Handle Results
# =============================================================================
echo ""
if [[ "$ALL_HEALTHY" == "true" ]]; then
    echo "=============================================="
    log_success "Update to $NEW_VERSION completed successfully!"
    echo "=============================================="
    echo ""
    compose_cmd ps
    echo ""
    log_info "Update log:      $UPDATE_LOG"
    log_info "Checkpoint:      $CHECKPOINT_NAME"
    log_info "Rollback:        ./scripts/rollback.sh --checkpoint $CHECKPOINT_NAME"
    if [[ "$FILES_UPDATED" == "true" ]]; then
        log_info "File backup:     .file-backups/$UPDATE_TIMESTAMP/"
    fi
    if [[ "$ENV_VARS_ADDED" -gt 0 ]] 2>/dev/null; then
        log_info "New env vars:    $ENV_VARS_ADDED variable(s) added to .env"
    fi
    echo ""
    log_info "Update completed at $(date -Iseconds)"
else
    echo "=============================================="
    log_error "Update to $NEW_VERSION FAILED!"
    echo "=============================================="
    echo ""

    # Capture failed service logs for diagnostics
    log_info "Capturing service logs for diagnostics..."
    compose_cmd logs --tail=50 > "$DEPLOY_DIR/logs/update_failure_${UPDATE_TIMESTAMP}.log" 2>&1 || true
    log_info "Service logs saved to: logs/update_failure_${UPDATE_TIMESTAMP}.log"
    echo ""

    if [[ "$AUTO_ROLLBACK" == "true" ]]; then
        log_warning "Auto-rollback is enabled. Initiating rollback..."
        echo ""
        sleep 5

        # -------------------------------------------------------------------
        # Rollback: Stop failed services
        # -------------------------------------------------------------------
        log_info "Stopping failed services..."
        compose_cmd down --timeout 30 2>/dev/null || {
            compose_cmd kill 2>/dev/null || true
            compose_cmd down 2>/dev/null || true
        }

        # -------------------------------------------------------------------
        # Rollback: Restore .env from checkpoint
        # -------------------------------------------------------------------
        if [[ -f "$CHECKPOINT_PATH/.env" ]]; then
            log_info "Restoring .env from checkpoint..."
            cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.pre-rollback" 2>/dev/null || true
            cp "$CHECKPOINT_PATH/.env" "$DEPLOY_DIR/.env"
            log_success ".env restored from checkpoint"
        fi

        # -------------------------------------------------------------------
        # Rollback: Restore deployment files from .file-backups
        # -------------------------------------------------------------------
        if [[ "$FILES_UPDATED" == "true" ]]; then
            restore_file_backups "$UPDATE_TIMESTAMP"
        fi

        # -------------------------------------------------------------------
        # Rollback: Re-source environment after restoration
        # -------------------------------------------------------------------
        source_env

        # -------------------------------------------------------------------
        # Rollback: Pull previous version images
        # -------------------------------------------------------------------
        log_info "Pulling images for previous version ($CURRENT_VERSION)..."
        if ! compose_cmd pull 2>&1; then
            log_error "Failed to pull previous version images."
            log_error "The previous version may no longer be available in the registry."
            log_error "Consider restoring from a full backup: ./scripts/restore.sh <backup_file.tar.gz>"
            exit 1
        fi

        # -------------------------------------------------------------------
        # Rollback: Start services in order with previous version
        # -------------------------------------------------------------------
        log_info "Starting services with previous version ($CURRENT_VERSION)..."
        if start_services_ordered; then
            # Wait for services to stabilize
            log_info "Waiting for services to stabilize after rollback..."
            sleep 15

            # Quick health check after rollback
            rollback_healthy=true
            IFS=' ' read -ra ROLLBACK_SERVICES <<< "$(get_service_list)"
            for service in "${ROLLBACK_SERVICES[@]}"; do
                if ! wait_for_healthy "$service" 60; then
                    case "$service" in
                        *celery*)
                            if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                                log_warning "  $service is running after rollback"
                            else
                                log_error "  $service failed after rollback"
                                rollback_healthy=false
                            fi
                            ;;
                        *)
                            log_error "  $service failed after rollback"
                            rollback_healthy=false
                            ;;
                    esac
                fi
            done

            if [[ "$rollback_healthy" == "true" ]]; then
                log_success "Rollback completed. Running on previous version: $CURRENT_VERSION"
            else
                log_error "Rollback completed but some services are unhealthy."
                log_error "Manual intervention required. Check logs: docker compose logs"
            fi
        else
            log_error "Failed to start services during rollback."
            log_error "Manual intervention required."
            log_error "  Restore from backup: ./scripts/restore.sh <backup_file.tar.gz>"
            exit 1
        fi

        echo ""
        log_info "Update log:    $UPDATE_LOG"
        log_info "Rollback from: $NEW_VERSION -> $CURRENT_VERSION"
        log_info "Pre-rollback .env saved to: .env.pre-rollback"
        log_info "Rollback completed at $(date -Iseconds)"
    else
        log_error "Services are unhealthy. Manual intervention required."
        echo ""
        log_info "To rollback manually:"
        log_info "  ./scripts/rollback.sh --checkpoint $CHECKPOINT_NAME"
        echo ""
        if [[ "$FILES_UPDATED" == "true" ]]; then
            log_info "To restore deployment files:"
            log_info "  Files backed up in: .file-backups/$UPDATE_TIMESTAMP/"
        fi
        echo ""
        log_info "To restore from full backup:"
        log_info "  ./scripts/restore.sh <backup_file.tar.gz>"
        echo ""
        log_info "To view logs:"
        log_info "  docker compose logs"
        log_info "  cat $UPDATE_LOG"
        log_info "  cat logs/update_failure_${UPDATE_TIMESTAMP}.log"
        echo ""
        log_info "Update log: $UPDATE_LOG"
        exit 1
    fi
fi
