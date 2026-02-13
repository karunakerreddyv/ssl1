#!/bin/bash
# =============================================================================
# Pravaha Platform - Comprehensive Health Check Script
# Validates all services, databases, and system resources
# =============================================================================
#
# Usage:
#   ./health-check.sh                  # Full health check
#   ./health-check.sh --quick          # Quick container status only
#   ./health-check.sh --json           # JSON output for monitoring
#   ./health-check.sh --quiet          # Only output failures
#   ./health-check.sh --exit-code      # Return 1 if any check fails
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Critical failure (database, core services)
#
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Options
QUICK_MODE=false
JSON_OUTPUT=false
QUIET_MODE=false
EXIT_ON_FAIL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet|-q)
            QUIET_MODE=true
            shift
            ;;
        --exit-code)
            EXIT_ON_FAIL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --quick       Quick container status check only"
            echo "  --json        Output results in JSON format"
            echo "  --quiet, -q   Only show failures"
            echo "  --exit-code   Return exit code 1 if any check fails"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors (disabled for JSON output)
if [[ "$JSON_OUTPUT" == "true" ]]; then
    GREEN=''
    RED=''
    YELLOW=''
    BLUE=''
    NC=''
else
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# Results tracking
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
CRITICAL_FAILURES=0
RESULTS_JSON=()

log_check() {
    local name="$1"
    local status="$2"
    local message="$3"
    local is_critical="${4:-false}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [[ "$status" == "pass" ]]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        if [[ "$QUIET_MODE" != "true" ]] && [[ "$JSON_OUTPUT" != "true" ]]; then
            printf "  %-25s ${GREEN}%s${NC} %s\n" "$name:" "PASS" "$message"
        fi
    elif [[ "$status" == "warn" ]]; then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            printf "  %-25s ${YELLOW}%s${NC} %s\n" "$name:" "WARN" "$message"
        fi
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        if [[ "$is_critical" == "true" ]]; then
            CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1))
        fi
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            printf "  %-25s ${RED}%s${NC} %s\n" "$name:" "FAIL" "$message"
        fi
    fi

    RESULTS_JSON+=("{\"name\":\"$name\",\"status\":\"$status\",\"message\":\"$message\",\"critical\":$is_critical}")
}

# Load environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

DOMAIN="${DOMAIN:-localhost}"
PROTOCOL="https"
POSTGRES_USER="${POSTGRES_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"

# =============================================================================
# Container Health Checks
# =============================================================================
check_container() {
    local name=$1
    local is_critical=${2:-false}

    local container_name="pravaha-$name"
    local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "not_found")

    if [[ "$status" == "not_found" ]]; then
        # Check if container exists but has no healthcheck
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            log_check "$name" "pass" "running (no healthcheck)" "$is_critical"
            return 0
        else
            log_check "$name" "fail" "container not found" "$is_critical"
            return 1
        fi
    fi

    case $status in
        "healthy")
            log_check "$name" "pass" "healthy" "$is_critical"
            return 0
            ;;
        "unhealthy")
            log_check "$name" "fail" "unhealthy" "$is_critical"
            return 1
            ;;
        "starting")
            log_check "$name" "warn" "starting..." "$is_critical"
            return 0
            ;;
        *)
            log_check "$name" "fail" "$status" "$is_critical"
            return 1
            ;;
    esac
}

# =============================================================================
# Service Endpoint Checks
# =============================================================================
check_internal_service() {
    local name=$1
    local container=$2
    local url=$3
    local is_critical=${4:-false}

    # Try wget first (Alpine-based images), fall back to curl (Debian/Python images)
    local response
    response=$(docker exec "pravaha-$container" wget -q -O /dev/null -S "$url" 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}' 2>/dev/null || echo "000")
    if [[ "$response" == "000" ]]; then
        response=$(docker exec "pravaha-$container" curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    fi

    if [[ "$response" == "200" ]]; then
        log_check "$name endpoint" "pass" "HTTP 200" "$is_critical"
        return 0
    else
        log_check "$name endpoint" "fail" "HTTP $response" "$is_critical"
        return 1
    fi
}

check_external_service() {
    local name=$1
    local url=$2
    local is_critical=${3:-false}

    local response=$(curl -k -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [[ "$response" == "200" ]]; then
        log_check "$name" "pass" "HTTP 200" "$is_critical"
        return 0
    else
        log_check "$name" "fail" "HTTP $response" "$is_critical"
        return 1
    fi
}

# =============================================================================
# Database Checks
# =============================================================================
check_postgres() {
    # Check PostgreSQL connectivity
    if docker exec pravaha-postgres pg_isready -U "$POSTGRES_USER" -d "$PLATFORM_DB" > /dev/null 2>&1; then
        log_check "PostgreSQL" "pass" "accepting connections" "true"
    else
        log_check "PostgreSQL" "fail" "not accepting connections" "true"
        return 1
    fi

    # Check platform database
    local table_count=$(docker exec pravaha-postgres psql -U "$POSTGRES_USER" -d "$PLATFORM_DB" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$table_count" ]] && [[ "$table_count" -gt 0 ]]; then
        log_check "Platform DB" "pass" "$table_count tables" "true"
    else
        log_check "Platform DB" "fail" "no tables or inaccessible" "true"
        return 1
    fi

    # Check superset database
    local superset_tables=$(docker exec pravaha-postgres psql -U "$POSTGRES_USER" -d "$SUPERSET_DB" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$superset_tables" ]] && [[ "$superset_tables" -gt 0 ]]; then
        log_check "Superset DB" "pass" "$superset_tables tables" "false"
    else
        log_check "Superset DB" "warn" "no tables (may be initializing)" "false"
    fi
}

check_redis() {
    # Use REDISCLI_AUTH env var instead of -a flag to avoid password exposure in process list
    local redis_auth_env=""
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
        redis_auth_env="REDISCLI_AUTH=$REDIS_PASSWORD"
    fi

    local ping_result=$(docker exec ${redis_auth_env:+-e "$redis_auth_env"} pravaha-redis redis-cli ping 2>/dev/null || echo "FAILED")

    if [[ "$ping_result" == "PONG" ]]; then
        log_check "Redis" "pass" "responsive" "true"

        # Check memory usage
        local used_memory=$(docker exec ${redis_auth_env:+-e "$redis_auth_env"} pravaha-redis redis-cli INFO memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]\r')
        if [[ -n "$used_memory" ]]; then
            log_check "Redis memory" "pass" "$used_memory" "false"
        fi
    else
        log_check "Redis" "fail" "not responding" "true"
        return 1
    fi
}

# =============================================================================
# System Resource Checks
# =============================================================================
check_disk_space() {
    local deploy_disk=$(df -h "$DEPLOY_DIR" 2>/dev/null | tail -1)
    local usage=$(echo "$deploy_disk" | awk '{print $5}' | tr -d '%')
    local available=$(echo "$deploy_disk" | awk '{print $4}')

    if [[ -z "$usage" ]]; then
        log_check "Disk space" "warn" "could not determine" "false"
        return 0
    fi

    if [[ $usage -ge 90 ]]; then
        log_check "Disk space" "fail" "${usage}% used ($available free)" "false"
        return 1
    elif [[ $usage -ge 80 ]]; then
        log_check "Disk space" "warn" "${usage}% used ($available free)" "false"
    else
        log_check "Disk space" "pass" "${usage}% used ($available free)" "false"
    fi
}

check_docker_disk() {
    local docker_usage=$(docker system df 2>/dev/null | grep "Images" | awk '{print $5}')
    if [[ -n "$docker_usage" ]]; then
        log_check "Docker images" "pass" "$docker_usage reclaimable" "false"
    fi
}

# =============================================================================
# SSL Certificate Check
# =============================================================================
check_ssl() {
    local ssl_dir="$DEPLOY_DIR/ssl"

    if [[ ! -f "$ssl_dir/fullchain.pem" ]]; then
        log_check "SSL certificate" "warn" "not configured" "false"
        return 0
    fi

    # Check expiry
    local expiry_date=$(openssl x509 -in "$ssl_dir/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry_date" ]]; then
        log_check "SSL certificate" "warn" "could not read" "false"
        return 0
    fi

    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -le 0 ]]; then
        log_check "SSL certificate" "fail" "EXPIRED" "false"
        return 1
    elif [[ $days_remaining -le 7 ]]; then
        log_check "SSL certificate" "fail" "$days_remaining days remaining (CRITICAL)" "false"
        return 1
    elif [[ $days_remaining -le 30 ]]; then
        log_check "SSL certificate" "warn" "$days_remaining days remaining" "false"
    else
        log_check "SSL certificate" "pass" "$days_remaining days remaining" "false"
    fi
}

# =============================================================================
# Celery Queue Check
# =============================================================================
check_celery_queues() {
    # Check if there are stuck tasks
    # Use REDISCLI_AUTH env var instead of -a flag to avoid password exposure in process list
    local redis_auth_env=""
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
        redis_auth_env="REDISCLI_AUTH=$REDIS_PASSWORD"
    fi
    local queue_length=$(docker exec ${redis_auth_env:+-e "$redis_auth_env"} pravaha-redis redis-cli LLEN celery 2>/dev/null || echo "0")
    queue_length=${queue_length:-0}

    if [[ "$queue_length" -gt 1000 ]]; then
        log_check "Celery queue" "warn" "$queue_length pending tasks" "false"
    else
        log_check "Celery queue" "pass" "$queue_length pending tasks" "false"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

if [[ "$JSON_OUTPUT" != "true" ]]; then
    echo "=============================================="
    echo "Pravaha Platform - Health Check"
    echo "=============================================="
    echo ""
    echo "Domain: $DOMAIN"
    echo "Deploy: $DEPLOY_DIR"
    echo ""
fi

# Container Status
if [[ "$JSON_OUTPUT" != "true" ]]; then
    echo -e "${BLUE}Container Status:${NC}"
    echo "----------------------------------------------"
fi

POSTGRES_MODE="${POSTGRES_MODE:-bundled}"
if [[ "$POSTGRES_MODE" == "bundled" ]]; then
    check_container "postgres" true
fi
check_container "redis" true
check_container "backend" true
check_container "frontend" false
check_container "superset" false
check_container "ml-service" false
check_container "jupyter" false
check_container "nginx" false
check_container "celery-training" false
check_container "celery-prediction" false
check_container "celery-monitoring" false
check_container "celery-beat" false

if [[ "$QUICK_MODE" != "true" ]]; then
    # Database Checks
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${BLUE}Database Status:${NC}"
        echo "----------------------------------------------"
    fi

    if [[ "$POSTGRES_MODE" == "bundled" ]]; then
        check_postgres
    fi
    check_redis

    # Service Endpoints
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${BLUE}Service Endpoints:${NC}"
        echo "----------------------------------------------"
    fi

    check_internal_service "Backend" "backend" "http://localhost:3000/health/live" true
    check_internal_service "Frontend" "frontend" "http://localhost:80/health" false
    check_internal_service "Superset" "superset" "http://localhost:8088/insights/health" false
    check_internal_service "ML Service" "ml-service" "http://localhost:8001/api/v1/health" false
    check_internal_service "Jupyter" "jupyter" "http://localhost:8888/notebooks/api/status" false

    # Celery Workers - check container health status (they don't have HTTP endpoints)
    for worker in training prediction monitoring; do
        container_name="pravaha-celery-${worker}"
        worker_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "not_found")
        if [[ "$worker_status" == "healthy" ]]; then
            log_check "Celery ${worker}" "pass" "healthy" "false"
        elif [[ "$worker_status" == "starting" ]]; then
            log_check "Celery ${worker}" "warn" "starting" "false"
        else
            log_check "Celery ${worker}" "fail" "$worker_status" "false"
        fi
    done

    # Celery Beat - scheduler
    beat_status=$(docker inspect --format='{{.State.Health.Status}}' "pravaha-celery-beat" 2>/dev/null || echo "not_found")
    if [[ "$beat_status" == "healthy" ]]; then
        log_check "Celery Beat" "pass" "healthy" "false"
    else
        log_check "Celery Beat" "fail" "$beat_status" "false"
    fi

    # External Access
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${BLUE}External Access:${NC}"
        echo "----------------------------------------------"
    fi

    check_external_service "HTTPS Main" "$PROTOCOL://$DOMAIN/" false
    check_external_service "API Health" "$PROTOCOL://$DOMAIN/api/v1/health" true

    # System Resources
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${BLUE}System Resources:${NC}"
        echo "----------------------------------------------"
    fi

    check_disk_space
    check_docker_disk
    check_ssl
    check_celery_queues
fi

# Output results
if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"deployment\": \"single-server\","
    echo "  \"domain\": \"$DOMAIN\","
    echo "  \"total_checks\": $TOTAL_CHECKS,"
    echo "  \"passed\": $PASSED_CHECKS,"
    echo "  \"failed\": $FAILED_CHECKS,"
    echo "  \"critical_failures\": $CRITICAL_FAILURES,"
    echo "  \"status\": \"$([ $CRITICAL_FAILURES -eq 0 ] && [ $FAILED_CHECKS -eq 0 ] && echo 'healthy' || ([ $CRITICAL_FAILURES -gt 0 ] && echo 'critical' || echo 'degraded'))\","
    echo "  \"checks\": ["
    first=true
    for result in "${RESULTS_JSON[@]}"; do
        if [[ "$first" != "true" ]]; then
            echo ","
        fi
        echo -n "    $result"
        first=false
    done
    echo ""
    echo "  ]"
    echo "}"
else
    echo ""
    echo "=============================================="

    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        echo -e "${RED}Status: CRITICAL${NC} - $CRITICAL_FAILURES critical failures"
    elif [[ $FAILED_CHECKS -gt 0 ]]; then
        echo -e "${YELLOW}Status: DEGRADED${NC} - $FAILED_CHECKS checks failed"
    else
        echo -e "${GREEN}Status: HEALTHY${NC} - All checks passed"
    fi

    echo "=============================================="
    echo "Checks: $PASSED_CHECKS/$TOTAL_CHECKS passed"
fi

# Exit code
if [[ "$EXIT_ON_FAIL" == "true" ]]; then
    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        exit 2
    elif [[ $FAILED_CHECKS -gt 0 ]]; then
        exit 1
    fi
fi

exit 0
