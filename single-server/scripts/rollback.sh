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

set -euo pipefail

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
# Health Check
# =============================================================================
check_health() {
    log_info "Checking service health..."

    cd "$DEPLOY_DIR"

    local all_healthy=true
    # All 12 services (11 without bundled postgres)
    local services=("redis" "backend" "frontend" "superset" "ml-service" "jupyter" "nginx" "celery-training" "celery-prediction" "celery-monitoring" "celery-beat")
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        services=("postgres" "${services[@]}")
    fi

    for service in "${services[@]}"; do
        local container_name="pravaha-$service"

        # Determine per-service timeout (seconds)
        # ML service: 360s (start_period=300s + margin)
        # Superset: 210s (start_period=180s + margin)
        local svc_timeout=60
        case "$service" in
            postgres)    svc_timeout=120 ;;
            backend)     svc_timeout=120 ;;
            superset)    svc_timeout=210 ;;
            ml-service)  svc_timeout=360 ;;
            celery-*)    svc_timeout=90  ;;
            *)           svc_timeout=60  ;;
        esac

        # Poll health status with timeout instead of single-shot check
        local elapsed=0
        local final_status="unknown"
        while [[ $elapsed -lt $svc_timeout ]]; do
            local status
            status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "not_found")

            case $status in
                "healthy")
                    final_status="healthy"
                    break
                    ;;
                "unhealthy")
                    final_status="unhealthy"
                    break
                    ;;
                "not_found")
                    # Check if container exists but has no healthcheck
                    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                        final_status="running_no_healthcheck"
                        break
                    fi
                    final_status="not_found"
                    ;;
                *)
                    final_status="$status"
                    ;;
            esac

            sleep 5
            elapsed=$((elapsed + 5))
        done

        case $final_status in
            "healthy")
                log_success "  $service: healthy"
                ;;
            "running_no_healthcheck")
                log_success "  $service: running (no healthcheck)"
                ;;
            "unhealthy")
                case "$service" in
                    celery-*|jupyter)
                        log_warning "  $service: unhealthy (non-critical, will not trigger rollback failure)"
                        ;;
                    *)
                        log_error "  $service: UNHEALTHY"
                        all_healthy=false
                        ;;
                esac
                ;;
            "not_found")
                case "$service" in
                    celery-*|jupyter)
                        log_warning "  $service: not running (non-critical, will not trigger rollback failure)"
                        ;;
                    *)
                        log_error "  $service: NOT RUNNING"
                        all_healthy=false
                        ;;
                esac
                ;;
            *)
                # For celery workers and jupyter, treat "running" as acceptable (non-critical)
                case "$service" in
                    celery-*|jupyter)
                        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                            log_warning "  $service: running (health check inconclusive)"
                        else
                            log_warning "  $service: not running (non-critical, will not trigger rollback failure)"
                        fi
                        ;;
                    *)
                        log_error "  $service: FAILED (timeout after ${svc_timeout}s, last status: $final_status)"
                        all_healthy=false
                        ;;
                esac
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

    # Set EXIT trap to ensure services are restarted if script fails unexpectedly
    # after stopping them (e.g., SIGTERM, network error during pull, OOM kill).
    SERVICES_STOPPED=false
    rollback_cleanup_on_failure() {
        local exit_code=$?
        if [[ "$SERVICES_STOPPED" == "true" && $exit_code -ne 0 ]]; then
            echo ""
            log_error "Rollback script exited unexpectedly (exit code $exit_code) while services were stopped!"
            log_warning "Attempting emergency service restart..."
            if [[ -f "$DEPLOY_DIR/.env" ]]; then
                set -a; source "$DEPLOY_DIR/.env" 2>/dev/null || true; set +a
            fi
            compose_cmd up -d 2>/dev/null || true
            log_info "Emergency restart issued. Check service status: docker compose ps"
        fi
    }
    trap rollback_cleanup_on_failure EXIT

    # Step 1: Stop services
    log_info "Stopping services..."
    SERVICES_STOPPED=true
    compose_cmd down --timeout 30 || {
        log_warning "Graceful stop failed, forcing..."
        compose_cmd kill 2>/dev/null || true
        compose_cmd down 2>/dev/null || true
    }

    # Step 2: Restore .env
    if [[ -f "$checkpoint_path/.env" ]]; then
        log_info "Restoring .env configuration..."
        cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.pre-rollback" 2>/dev/null || true
        cp "$checkpoint_path/.env" "$DEPLOY_DIR/.env"
    fi

    # Re-source environment after .env restoration to update POSTGRES_MODE
    source_env

    # Step 3: Restore docker-compose.yml if changed
    if [[ -f "$checkpoint_path/docker-compose.yml" ]]; then
        log_info "Restoring docker-compose.yml..."
        cp "$DEPLOY_DIR/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml.pre-rollback" 2>/dev/null || true
        cp "$checkpoint_path/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
    fi

    # Step 3b: Restore docker-compose override files
    for compose_override in "$checkpoint_path"/docker-compose.*.yml; do
        if [[ -f "$compose_override" ]]; then
            local override_name
            override_name=$(basename "$compose_override")
            log_info "Restoring $override_name..."
            cp "$DEPLOY_DIR/$override_name" "$DEPLOY_DIR/${override_name}.pre-rollback" 2>/dev/null || true
            cp "$compose_override" "$DEPLOY_DIR/$override_name"
        fi
    done

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

    # Step 6: Start services in dependency order
    log_info "Starting services in dependency order..."
    if [[ "${POSTGRES_MODE:-bundled}" == "bundled" ]]; then
        log_info "  Starting PostgreSQL (bundled mode)..."
        compose_cmd up -d postgres
        log_info "  Waiting for PostgreSQL to become healthy..."
        if ! wait_for_healthy "pravaha-postgres" 120; then
            log_error "  PostgreSQL failed to become healthy within 120s"
            log_error "  Check logs: docker compose logs postgres"
            exit 1
        fi
        log_success "  PostgreSQL is healthy"
    fi
    log_info "  Starting Redis..."
    compose_cmd up -d redis
    log_info "  Waiting for Redis to become healthy..."
    if ! wait_for_healthy "pravaha-redis" 60; then
        log_error "  Redis failed to become healthy within 60s"
        log_error "  Check logs: docker compose logs redis"
        exit 1
    fi
    log_success "  Redis is healthy"
    log_info "  Starting all remaining services..."
    compose_cmd up -d
    SERVICES_STOPPED=false  # Services are running again, disable emergency restart

    # Step 7: Wait for services to be healthy
    # check_health() has per-service timeouts (ml-service=360s, superset=210s, etc.)
    log_info "Waiting for services to become healthy (per-service timeouts apply)..."
    if check_health; then
        log_success "All services are healthy!"
    else
        log_error "Some services did not become healthy after rollback"
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

# Concurrent execution guard (flock) — skip for read-only operations
if [[ "$LIST_CHECKPOINTS" != "true" ]] && [[ "$VERIFY_ONLY" != "true" ]]; then
    LOCK_FILE="$DEPLOY_DIR/.pravaha-update.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_error "Another update or rollback operation is already in progress."
        log_error "If you're sure no other operation is running, remove: $LOCK_FILE"
        exit 1
    fi
fi

if [[ "$LIST_CHECKPOINTS" == "true" ]]; then
    list_checkpoints
elif [[ "$VERIFY_ONLY" == "true" ]]; then
    verify_checkpoint
elif [[ "$AUTO_ROLLBACK" == "true" ]]; then
    auto_rollback
else
    rollback
fi
