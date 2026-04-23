#!/bin/bash
# =============================================================================
# Pravaha Platform - Health Check Script
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Comprehensive health check for all services in two-server app deployment.
#   Validates: Docker containers, service health endpoints, Redis, and
#   external PostgreSQL connectivity.
#
# Usage:
#   ./health-check.sh [OPTIONS]
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

# Load environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    source "$DEPLOY_DIR/.env" 2>/dev/null || true
fi

# Options
QUICK=false
JSON_OUTPUT=false
VERBOSE=false
EXIT_CODE_ONLY=false

# Results
CRITICAL_FAILURES=0
WARNINGS=0
PASSED=0

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Check health of all Pravaha services in two-server app deployment.

OPTIONS:
    --quick, -q        Quick check (container status only)
    --json             Output results as JSON
    --verbose, -v      Show detailed information
    --exit-code        Only return exit code (silent)
    -h, --help         Show this help message

EXIT CODES:
    0    All services healthy
    1    Warnings only (non-critical)
    2    Critical failures detected

EXAMPLES:
    $0
    $0 --quick
    $0 --json
    $0 --verbose

EOF
    exit 0
}

# =============================================================================
# Logging Functions
# =============================================================================
log_info() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

log_warn() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
}

log_fail() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${RED}[FAIL]${NC} $1"
    ((CRITICAL_FAILURES++))
}

log_detail() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$VERBOSE" == "true" && "$JSON_OUTPUT" == "false" ]] && echo "       $1"
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick|-q)
                QUICK=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --exit-code)
                EXIT_CODE_ONLY=true
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
}

# =============================================================================
# Health Check Functions
# =============================================================================

check_docker_running() {
    log_info "Checking Docker daemon..."

    if ! docker info &>/dev/null; then
        log_fail "Docker daemon is not running"
        return 1
    fi

    log_pass "Docker daemon is running"
    return 0
}

check_container_status() {
    log_info "Checking container status..."

    local containers=(
        "pravaha-nginx"
        "pravaha-frontend"
        "pravaha-backend"
        "pravaha-superset"
        "pravaha-ml-service"
        "pravaha-jupyter"
        "pravaha-celery-training"
        "pravaha-celery-prediction"
        "pravaha-celery-monitoring"
        "pravaha-celery-beat"
        "pravaha-redis"
    )

    # Add Ollama if its container exists
    if docker ps -a --format '{{.Names}}' | grep -q "pravaha-ollama"; then
        containers+=("pravaha-ollama")
    fi

    for container in "${containers[@]}"; do
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
        local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null)

        if [[ -z "$status" ]]; then
            log_fail "$container: Not found"
        elif [[ "$status" != "running" ]]; then
            log_fail "$container: Not running (status: $status)"
        elif [[ -n "$health" && "$health" != "healthy" ]]; then
            log_warn "$container: Running but not healthy (health: $health)"
        else
            log_pass "$container: Running${health:+ ($health)}"
        fi
    done
}

check_nginx_health() {
    log_info "Checking NGINX health endpoint..."

    # Try wget first (Alpine-based images), fall back to curl (Debian/Python images)
    if docker exec pravaha-nginx wget -q -O /dev/null http://localhost/health 2>/dev/null; then
        log_pass "NGINX health endpoint responding"
    elif docker exec pravaha-nginx curl -sf -o /dev/null http://localhost/health 2>/dev/null; then
        log_pass "NGINX health endpoint responding"
    else
        log_fail "NGINX health endpoint not responding"
    fi
}

check_backend_health() {
    log_info "Checking Backend health endpoints..."

    # Check liveness - try wget first (Alpine-based images), fall back to curl (Debian/Python images)
    if docker exec pravaha-backend wget -q -O /dev/null http://localhost:3000/health/live 2>/dev/null; then
        log_pass "Backend liveness check passed"
    elif docker exec pravaha-backend curl -sf -o /dev/null http://localhost:3000/health/live 2>/dev/null; then
        log_pass "Backend liveness check passed"
    else
        log_fail "Backend liveness check failed"
    fi

    # Check readiness - try wget first, fall back to curl
    if docker exec pravaha-backend wget -q -O /dev/null http://localhost:3000/health/ready 2>/dev/null; then
        log_pass "Backend readiness check passed"
    elif docker exec pravaha-backend curl -sf -o /dev/null http://localhost:3000/health/ready 2>/dev/null; then
        log_pass "Backend readiness check passed"
    else
        log_warn "Backend readiness check failed (may still be initializing)"
    fi
}

check_ml_service_health() {
    log_info "Checking ML Service health..."

    if docker exec pravaha-ml-service curl -sf http://localhost:8001/api/v1/health &>/dev/null; then
        log_pass "ML Service health check passed"
    else
        log_fail "ML Service health check failed"
    fi
}

check_jupyter_health() {
    log_info "Checking Jupyter health..."

    # Jupyter requires token auth — use docker exec with Authorization header
    local jupyter_response
    jupyter_response=$(docker exec pravaha-jupyter curl -sf -o /dev/null -w "%{http_code}" "http://localhost:8888/notebooks/api/status" -H "Authorization: token $JUPYTER_TOKEN" 2>/dev/null || echo "000")
    if [[ "$jupyter_response" == "200" ]]; then
        log_pass "Jupyter health check passed"
    else
        log_warn "Jupyter health check failed (HTTP $jupyter_response, may take time to start)"
    fi
}

check_superset_health() {
    log_info "Checking Superset health..."

    if docker exec pravaha-superset curl -sf http://localhost:8088/insights/health &>/dev/null; then
        log_pass "Superset health check passed"
    else
        log_warn "Superset health check failed (may take time to start)"
    fi
}

check_redis_health() {
    log_info "Checking Redis health..."

    # Load env for password
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        source "$DEPLOY_DIR/.env" 2>/dev/null || true
    fi

    # Use REDISCLI_AUTH env var instead of -a flag to avoid password exposure in process list
    local redis_auth_env=""
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
        redis_auth_env="REDISCLI_AUTH=$REDIS_PASSWORD"
    fi

    if docker exec ${redis_auth_env:+-e "$redis_auth_env"} pravaha-redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_pass "Redis health check passed"

        if [[ "$VERBOSE" == "true" ]]; then
            local info=$(docker exec ${redis_auth_env:+-e "$redis_auth_env"} pravaha-redis redis-cli info memory 2>/dev/null | grep "used_memory_human")
            log_detail "Memory: ${info#*:}"
        fi
    else
        log_fail "Redis health check failed"
    fi
}

check_external_postgresql() {
    log_info "Checking external PostgreSQL connectivity..."

    # Load environment
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        source "$DEPLOY_DIR/.env" 2>/dev/null || true
    fi

    if [[ -z "$POSTGRES_HOST" ]]; then
        log_warn "POSTGRES_HOST not configured in .env"
        return 0
    fi

    local port="${POSTGRES_PORT:-5432}"
    local user="${POSTGRES_USER:-pravaha}"
    local password="${POSTGRES_PASSWORD:-}"
    local db="${PLATFORM_DB:-autoanalytics}"

    # TCP connectivity
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$POSTGRES_HOST/$port" 2>/dev/null; then
        log_pass "PostgreSQL TCP connectivity OK ($POSTGRES_HOST:$port)"
    else
        log_fail "Cannot connect to PostgreSQL at $POSTGRES_HOST:$port"
        return 1
    fi

    # Authentication check
    if docker run --rm --network host \
        -e PGPASSWORD="$password" \
        postgres:17-alpine \
        psql "postgresql://$user@$POSTGRES_HOST:$port/$db" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        log_pass "PostgreSQL authentication OK"
    else
        log_fail "PostgreSQL authentication failed"
    fi
}

check_celery_workers() {
    log_info "Checking Celery workers..."

    local workers=("training" "prediction" "monitoring")

    for worker in "${workers[@]}"; do
        local container="pravaha-celery-$worker"

        if docker exec "$container" pgrep -f "celery.*${worker}_worker" &>/dev/null; then
            log_pass "Celery $worker worker is running"
        else
            log_warn "Celery $worker worker process not found"
        fi
    done

    # Check beat
    if docker exec pravaha-celery-beat test -f /tmp/celerybeat.pid &>/dev/null; then
        log_pass "Celery beat scheduler is running"
    else
        log_warn "Celery beat scheduler not running"
    fi
}

check_disk_space() {
    log_info "Checking disk space..."

    local available_gb=$(df -BG "$DEPLOY_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

    if [[ $available_gb -lt 5 ]]; then
        log_fail "Low disk space: ${available_gb}GB available"
    elif [[ $available_gb -lt 20 ]]; then
        log_warn "Disk space warning: ${available_gb}GB available"
    else
        log_pass "Disk space OK: ${available_gb}GB available"
    fi
}

check_memory() {
    log_info "Checking system memory..."

    local total_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    local available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
    local available_gb=$((available_kb / 1024 / 1024))
    local total_gb=$((total_kb / 1024 / 1024))

    if [[ $available_gb -lt 2 ]]; then
        log_fail "Low memory: ${available_gb}GB available of ${total_gb}GB"
    elif [[ $available_gb -lt 4 ]]; then
        log_warn "Memory warning: ${available_gb}GB available of ${total_gb}GB"
    else
        log_pass "Memory OK: ${available_gb}GB available of ${total_gb}GB"
    fi
}

# =============================================================================
# Output
# =============================================================================

output_json() {
    cat << EOF
{
    "status": "$([[ $CRITICAL_FAILURES -eq 0 ]] && echo "healthy" || echo "unhealthy")",
    "deployment": "two-server-app",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "results": {
        "passed": $PASSED,
        "warnings": $WARNINGS,
        "failures": $CRITICAL_FAILURES
    },
    "external_database": {
        "host": "${POSTGRES_HOST:-not_configured}",
        "port": ${POSTGRES_PORT:-5432}
    }
}
EOF
}

output_summary() {
    echo ""
    echo "=============================================="
    echo "Health Check Summary"
    echo "=============================================="
    echo ""
    echo -e "  Passed:   ${GREEN}$PASSED${NC}"
    echo -e "  Warnings: ${YELLOW}$WARNINGS${NC}"
    echo -e "  Failures: ${RED}$CRITICAL_FAILURES${NC}"
    echo ""

    if [[ $CRITICAL_FAILURES -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}All services healthy!${NC}"
    elif [[ $CRITICAL_FAILURES -eq 0 ]]; then
        echo -e "${YELLOW}Services running with warnings${NC}"
    else
        echo -e "${RED}Critical issues detected!${NC}"
        echo "Run 'docker compose logs' for more details."
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    cd "$DEPLOY_DIR"

    if [[ "$JSON_OUTPUT" == "false" && "$EXIT_CODE_ONLY" == "false" ]]; then
        echo ""
        echo "=============================================="
        echo "Pravaha Health Check - Two-Server (App)"
        echo "=============================================="
        echo ""
    fi

    # Always check Docker first
    check_docker_running || exit 1

    # Quick mode - containers only
    if [[ "$QUICK" == "true" ]]; then
        check_container_status
    else
        check_container_status
        check_nginx_health
        check_backend_health
        check_ml_service_health
        check_jupyter_health
        check_superset_health
        check_redis_health
        check_external_postgresql
        check_celery_workers
        check_disk_space
        check_memory
    fi

    # Output
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    elif [[ "$EXIT_CODE_ONLY" == "false" ]]; then
        output_summary
    fi

    # Exit code: 0=healthy, 1=warning, 2=critical
    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        exit 2
    elif [[ $WARNINGS -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
