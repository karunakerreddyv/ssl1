#!/bin/bash
# =============================================================================
# Pravaha Platform - Rollback Script
# Rollback to previous state after failed update
# =============================================================================
#
# Usage:
#   ./rollback.sh                          # Rollback to last checkpoint
#   ./rollback.sh --list                   # List available checkpoints
#   ./rollback.sh --checkpoint <name>      # Rollback to specific checkpoint
#   ./rollback.sh --verify                 # Verify current state vs last checkpoint
#   ./rollback.sh --auto                   # Auto-rollback if health checks fail
#
# Checkpoint Files:
#   .checkpoint/                           # Checkpoint directory
#   .checkpoint/latest/                    # Latest checkpoint
#   .checkpoint/<timestamp>/               # Named checkpoints
#
# =============================================================================

set -e

DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"

# Source environment for POSTGRES_MODE
source_env() {
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        set -a
        source "$DEPLOY_DIR/.env"
        set +a
    fi
    POSTGRES_MODE="${POSTGRES_MODE:-bundled}"
}

# Docker compose wrapper with profile support
compose_cmd() {
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        docker compose --profile bundled-db "$@"
    else
        docker compose "$@"
    fi
}
CHECKPOINT_DIR="$DEPLOY_DIR/.checkpoint"
ROLLBACK_TARGET=""
LIST_CHECKPOINTS=false
VERIFY_ONLY=false
AUTO_ROLLBACK=false

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

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            LIST_CHECKPOINTS=true
            shift
            ;;
        --checkpoint)
            ROLLBACK_TARGET="$2"
            shift 2
            ;;
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        --auto)
            AUTO_ROLLBACK=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --list                List available checkpoints"
            echo "  --checkpoint <name>   Rollback to specific checkpoint"
            echo "  --verify              Verify current state vs checkpoint"
            echo "  --auto                Auto-rollback if health check fails"
            echo ""
            echo "Examples:"
            echo "  $0                    # Rollback to latest checkpoint"
            echo "  $0 --list             # List all checkpoints"
            echo "  $0 --checkpoint pre_update_20240115_120000"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Create Checkpoint Function (called by update.sh)
# =============================================================================
create_checkpoint() {
    local checkpoint_name="${1:-pre_update_$(date +%Y%m%d_%H%M%S)}"
    local checkpoint_path="$CHECKPOINT_DIR/$checkpoint_name"

    log_info "Creating checkpoint: $checkpoint_name"

    mkdir -p "$checkpoint_path"

    cd "$DEPLOY_DIR"

    # Save current .env file
    if [[ -f ".env" ]]; then
        cp ".env" "$checkpoint_path/.env"
    fi

    # Save current docker-compose.yml
    if [[ -f "docker-compose.yml" ]]; then
        cp "docker-compose.yml" "$checkpoint_path/docker-compose.yml"
    fi

    # Save current image digests (exact versions running)
    log_info "Capturing current container image digests..."
    compose_cmd images --format json 2>/dev/null | jq -r '.[] | "\(.Repository):\(.Tag)@\(.Digest)"' \
        > "$checkpoint_path/image_digests.txt" 2>/dev/null || {
        # Fallback for older docker compose versions
        compose_cmd images > "$checkpoint_path/image_versions.txt" 2>/dev/null || true
    }

    # Save current IMAGE_TAG
    grep "^IMAGE_TAG=" ".env" > "$checkpoint_path/image_tag.txt" 2>/dev/null || echo "IMAGE_TAG=unknown" > "$checkpoint_path/image_tag.txt"

    # Save NGINX configuration
    if [[ -d "nginx" ]]; then
        cp -r "nginx" "$checkpoint_path/"
    fi

    # Save SSL certificates metadata (not the actual certs for security)
    if [[ -d "ssl" ]]; then
        mkdir -p "$checkpoint_path/ssl_meta"
        for cert in ssl/*.pem; do
            if [[ -f "$cert" ]]; then
                openssl x509 -in "$cert" -noout -subject -dates 2>/dev/null \
                    > "$checkpoint_path/ssl_meta/$(basename "$cert").info" || true
            fi
        done
    fi

    # Create checkpoint manifest
    cat > "$checkpoint_path/manifest.json" << EOF
{
    "checkpoint_name": "$checkpoint_name",
    "created_at": "$(date -Iseconds)",
    "image_tag": "$(grep '^IMAGE_TAG=' .env 2>/dev/null | cut -d= -f2 || echo 'unknown')",
    "services_running": $(compose_cmd ps --format json 2>/dev/null | jq -s 'map(.Name)' 2>/dev/null || echo '[]'),
    "postgres_version": "$( [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]] && compose_cmd exec -T postgres psql --version 2>/dev/null | head -1 || echo 'unknown')",
    "deploy_dir": "$DEPLOY_DIR"
}
EOF

    # Update latest symlink
    rm -f "$CHECKPOINT_DIR/latest"
    ln -sf "$checkpoint_name" "$CHECKPOINT_DIR/latest"

    # Cleanup old checkpoints (keep last 5)
    local checkpoint_count=$(ls -1 "$CHECKPOINT_DIR" 2>/dev/null | grep -v latest | wc -l)
    if [[ $checkpoint_count -gt 5 ]]; then
        ls -1t "$CHECKPOINT_DIR" | grep -v latest | tail -n +6 | while read old_checkpoint; do
            log_info "Removing old checkpoint: $old_checkpoint"
            rm -rf "$CHECKPOINT_DIR/$old_checkpoint"
        done
    fi

    log_success "Checkpoint created: $checkpoint_path"
    echo "$checkpoint_name"
}

# =============================================================================
# List Checkpoints
# =============================================================================
list_checkpoints() {
    echo "=============================================="
    echo "Pravaha Platform - Available Checkpoints"
    echo "=============================================="
    echo ""

    if [[ ! -d "$CHECKPOINT_DIR" ]]; then
        log_warning "No checkpoints found. Run an update first."
        exit 0
    fi

    local latest=$(readlink "$CHECKPOINT_DIR/latest" 2>/dev/null || echo "")

    printf "%-40s %-25s %-15s %s\n" "CHECKPOINT" "CREATED" "IMAGE TAG" "STATUS"
    printf "%-40s %-25s %-15s %s\n" "----------" "-------" "---------" "------"

    for checkpoint in $(ls -1t "$CHECKPOINT_DIR" | grep -v latest); do
        local manifest="$CHECKPOINT_DIR/$checkpoint/manifest.json"
        local created_at=""
        local image_tag=""
        local status=""

        if [[ -f "$manifest" ]]; then
            created_at=$(jq -r '.created_at // "unknown"' "$manifest" 2>/dev/null | cut -d'T' -f1,2 | tr 'T' ' ' | cut -c1-19)
            image_tag=$(jq -r '.image_tag // "unknown"' "$manifest" 2>/dev/null)
        fi

        if [[ "$checkpoint" == "$latest" ]]; then
            status="<- LATEST"
        fi

        printf "%-40s %-25s %-15s %s\n" "$checkpoint" "$created_at" "$image_tag" "$status"
    done

    echo ""
}

# =============================================================================
# Verify Checkpoint
# =============================================================================
verify_checkpoint() {
    local checkpoint_path="$CHECKPOINT_DIR/${ROLLBACK_TARGET:-latest}"

    if [[ ! -d "$checkpoint_path" ]]; then
        # Resolve symlink if latest
        if [[ -L "$checkpoint_path" ]]; then
            checkpoint_path="$CHECKPOINT_DIR/$(readlink "$checkpoint_path")"
        else
            log_error "Checkpoint not found: $checkpoint_path"
            exit 1
        fi
    fi

    echo "=============================================="
    echo "Pravaha Platform - Checkpoint Verification"
    echo "=============================================="
    echo ""

    log_info "Checkpoint: $(basename "$checkpoint_path")"

    if [[ -f "$checkpoint_path/manifest.json" ]]; then
        echo ""
        echo "Checkpoint manifest:"
        cat "$checkpoint_path/manifest.json" | jq .
        echo ""
    fi

    # Compare current vs checkpoint
    echo "Comparison with current state:"
    echo ""

    # Check IMAGE_TAG
    local checkpoint_tag=$(cat "$checkpoint_path/image_tag.txt" 2>/dev/null | cut -d= -f2)
    local current_tag=$(grep "^IMAGE_TAG=" "$DEPLOY_DIR/.env" 2>/dev/null | cut -d= -f2)

    if [[ "$checkpoint_tag" == "$current_tag" ]]; then
        log_success "IMAGE_TAG: $current_tag (matches checkpoint)"
    else
        log_warning "IMAGE_TAG: $current_tag (checkpoint: $checkpoint_tag)"
    fi

    # Check .env differences
    if [[ -f "$checkpoint_path/.env" ]] && [[ -f "$DEPLOY_DIR/.env" ]]; then
        local env_diff=$(diff "$checkpoint_path/.env" "$DEPLOY_DIR/.env" 2>/dev/null | wc -l)
        if [[ $env_diff -eq 0 ]]; then
            log_success ".env file: Identical"
        else
            log_warning ".env file: $env_diff lines differ"
        fi
    fi

    echo ""
}

# =============================================================================
# Health Check
# =============================================================================
check_health() {
    log_info "Checking service health..."

    cd "$DEPLOY_DIR"

    local all_healthy=true
    local services=("redis" "backend" "superset" "ml-service" "nginx")
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        services=("postgres" "${services[@]}")
    fi

    for service in "${services[@]}"; do
        local container_name="pravaha-$service"
        local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "not_found")

        case $status in
            "healthy")
                log_success "  $service: healthy"
                ;;
            "unhealthy")
                log_error "  $service: UNHEALTHY"
                all_healthy=false
                ;;
            "starting")
                log_warning "  $service: starting (wait longer)"
                ;;
            "not_found")
                # Check if container exists but has no healthcheck
                if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                    log_success "  $service: running (no healthcheck)"
                else
                    log_error "  $service: NOT RUNNING"
                    all_healthy=false
                fi
                ;;
            *)
                log_warning "  $service: $status"
                ;;
        esac
    done

    if [[ "$all_healthy" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# Rollback Function
# =============================================================================
rollback() {
    local target="${ROLLBACK_TARGET:-latest}"
    local checkpoint_path="$CHECKPOINT_DIR/$target"

    # Resolve symlink
    if [[ -L "$checkpoint_path" ]]; then
        target=$(readlink "$checkpoint_path")
        checkpoint_path="$CHECKPOINT_DIR/$target"
    fi

    if [[ ! -d "$checkpoint_path" ]]; then
        log_error "Checkpoint not found: $target"
        log_info "Use --list to see available checkpoints"
        exit 1
    fi

    echo "=============================================="
    echo "Pravaha Platform - Rollback"
    echo "=============================================="
    echo "Target:    $target"
    echo ""

    if [[ -f "$checkpoint_path/manifest.json" ]]; then
        log_info "Checkpoint details:"
        cat "$checkpoint_path/manifest.json" | jq .
        echo ""
    fi

    if [[ "$AUTO_ROLLBACK" != "true" ]]; then
        log_warning "This will restore the system to checkpoint: $target"
        read -p "Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Rollback cancelled"
            exit 0
        fi
    else
        log_warning "Auto-rollback initiated"
    fi

    cd "$DEPLOY_DIR"

    # Step 1: Stop services
    log_info "Stopping services..."
    compose_cmd down --timeout 30 || {
        log_warning "Graceful stop failed, forcing..."
        compose_cmd kill
        compose_cmd down
    }

    # Step 2: Restore .env
    if [[ -f "$checkpoint_path/.env" ]]; then
        log_info "Restoring .env configuration..."
        cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.pre-rollback" 2>/dev/null || true
        cp "$checkpoint_path/.env" "$DEPLOY_DIR/.env"
    fi

    # Step 3: Restore docker-compose.yml if changed
    if [[ -f "$checkpoint_path/docker-compose.yml" ]]; then
        log_info "Restoring docker-compose.yml..."
        cp "$DEPLOY_DIR/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml.pre-rollback" 2>/dev/null || true
        cp "$checkpoint_path/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
    fi

    # Step 4: Restore NGINX configuration
    if [[ -d "$checkpoint_path/nginx" ]]; then
        log_info "Restoring NGINX configuration..."
        cp -r "$checkpoint_path/nginx/"* "$DEPLOY_DIR/nginx/"
    fi

    # Step 5: Pull the previous images (using restored IMAGE_TAG)
    log_info "Pulling images for restored version..."
    compose_cmd pull || {
        log_error "Failed to pull images. The previous version may no longer be available."
        log_error "Consider restoring from a full backup instead."
        exit 1
    }

    # Step 6: Start services
    log_info "Starting services with restored configuration..."
    compose_cmd up -d

    # Step 7: Wait for services to be healthy
    log_info "Waiting for services to become healthy..."
    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        sleep 10
        waited=$((waited + 10))

        if check_health 2>/dev/null; then
            log_success "All services are healthy!"
            break
        fi

        log_info "Waiting for services... ($waited/${max_wait}s)"
    done

    if [[ $waited -ge $max_wait ]]; then
        log_error "Services did not become healthy within ${max_wait}s"
        log_error "Check logs with: docker compose logs"
        exit 1
    fi

    # Step 8: Verify rollback
    echo ""
    log_success "=============================================="
    log_success "Rollback completed successfully!"
    log_success "=============================================="
    echo ""
    log_info "Rolled back to checkpoint: $target"
    log_info "Previous configuration saved to .env.pre-rollback"
    echo ""
    log_info "Verify with: docker compose ps"
    log_info "             ./scripts/health-check.sh"
    echo ""

    # Check if database restore is also needed
    if [[ -f "$checkpoint_path/manifest.json" ]]; then
        local checkpoint_time=$(jq -r '.created_at' "$checkpoint_path/manifest.json" 2>/dev/null)
        log_warning "Note: This rollback restored configuration and images only."
        log_warning "If you also need to restore the database to this point,"
        log_warning "find a backup from around $checkpoint_time and run:"
        log_warning "  ./scripts/restore.sh <backup_file.tar.gz>"
    fi
}

# =============================================================================
# Auto-Rollback (called after failed update)
# =============================================================================
auto_rollback() {
    log_warning "Auto-rollback triggered - checking service health..."

    # Wait a bit for services to start
    sleep 30

    if check_health; then
        log_success "Services are healthy - no rollback needed"
        exit 0
    fi

    log_error "Services are not healthy - initiating automatic rollback"
    AUTO_ROLLBACK=true
    rollback
}

# =============================================================================
# Main
# =============================================================================

# Ensure checkpoint directory exists
source_env
mkdir -p "$CHECKPOINT_DIR"

if [[ "$LIST_CHECKPOINTS" == "true" ]]; then
    list_checkpoints
elif [[ "$VERIFY_ONLY" == "true" ]]; then
    verify_checkpoint
elif [[ "$AUTO_ROLLBACK" == "true" ]]; then
    auto_rollback
else
    # If called with "create" as first arg (from update.sh)
    if [[ "${1:-}" == "create" ]]; then
        create_checkpoint "${2:-}"
    else
        rollback
    fi
fi
