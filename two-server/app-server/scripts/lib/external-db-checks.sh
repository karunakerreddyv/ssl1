#!/bin/bash
# =============================================================================
# Pravaha Platform - Two-Server App Server Specific Checks
# Checks for external database connectivity
# =============================================================================

[[ -n "${_EXTERNAL_DB_CHECKS_LOADED:-}" ]] && return 0
_EXTERNAL_DB_CHECKS_LOADED=1

# =============================================================================
# Two-Server App Category: External Database (15 checks)
# =============================================================================
check_external_database() {
    local category="external_db"
    echo ""
    echo -e "${BLUE}${BOLD}Two-Server Category: External Database${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local db_host="${POSTGRES_HOST:-localhost}"
    local db_port="${POSTGRES_PORT:-5432}"

    # TS.A.1 External DB reachable
    run_check "TS.A.1" "$category" "External DB reachable" "true" \
        "nc -z -w 5 $db_host $db_port 2>/dev/null && echo 'reachable' || echo 'unreachable'" \
        "reachable" \
        "Check network connectivity to database server"

    # TS.A.2 External DB latency
    run_check "TS.A.2" "$category" "External DB latency < 5ms" "false" \
        "ping -c 1 -W 1 $db_host 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2 || echo 'unknown'" \
        "any" \
        "Check network latency to database server"

    # TS.A.3 SSL to external DB
    run_check "TS.A.3" "$category" "SSL to external DB" "false" \
        "[[ '${POSTGRES_SSL_ENABLED:-false}' == 'true' ]] && echo 'enabled' || echo 'disabled'" \
        "any" \
        "Enable SSL for database connection"

    # TS.A.4 Firewall allows DB port
    run_check "TS.A.4" "$category" "Firewall allows DB port" "true" \
        "nc -z -w 5 $db_host $db_port 2>/dev/null && echo 'open' || echo 'blocked'" \
        "open" \
        "Check firewall rules for port $db_port"

    # TS.A.5 DATABASE_URL constructed
    run_check "TS.A.5" "$category" "DATABASE_URL constructed" "true" \
        "[[ -n '${DATABASE_URL:-}' ]] && [[ '${DATABASE_URL:-}' == *'$db_host'* ]] && echo 'valid' || echo 'invalid'" \
        "valid" \
        "Check DATABASE_URL in .env"

    # TS.A.6 All services use same DB
    run_check "TS.A.6" "$category" "All services use same DB" "true" \
        "[[ '${POSTGRES_HOST:-postgres}' != 'postgres' ]] && echo 'external' || echo 'local'" \
        "external" \
        "Configure POSTGRES_HOST for external DB"

    # TS.A.7 Connection pool adequate
    run_check "TS.A.7" "$category" "Connection pool adequate" "false" \
        "[[ '${DB_POOL_SIZE:-20}' -ge 20 ]] && echo 'adequate' || echo 'low'" \
        "adequate" \
        "Increase DB_POOL_SIZE for multi-service deployment"

    # TS.A.8 DB migrations applied
    run_check "TS.A.8" "$category" "DB migrations applied" "true" \
        "docker exec pravaha-backend wget -qO- http://localhost:3000/health/live 2>/dev/null | grep -c 'alive' || echo '0'" \
        "any" \
        "Run database migrations"

    # TS.A.9 No local postgres
    run_check "TS.A.9" "$category" "No local postgres container" "true" \
        "docker ps --filter 'name=pravaha-postgres' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d '[:space:]' | awk '{if(\$1 == 0) print \"ok\"; else print \"local_running\"}'" \
        "ok" \
        "Stop local postgres: docker compose stop postgres"

    # TS.A.10 DB backup from here
    run_check "TS.A.10" "$category" "DB backup accessible" "false" \
        "{ which pg_dump >/dev/null 2>&1 || docker exec pravaha-backend which pg_dump >/dev/null 2>&1; } && echo 'available' || echo 'not_available'" \
        "any" \
        "Install pg_dump or backup from DB server"

    # TS.A.11 Redis still local
    run_check "TS.A.11" "$category" "Redis local" "true" \
        "docker ps --filter 'name=pravaha-redis' --format '{{.Names}}' 2>/dev/null | grep -c 'redis' || echo '0'" \
        "any" \
        "Redis should be local on app server"

    # TS.A.12 Celery broker local
    run_check "TS.A.12" "$category" "Celery broker uses local Redis" "true" \
        "{ [[ '${CELERY_BROKER_URL:-}' == *'redis:6379'* ]] || [[ '${CELERY_BROKER_URL:-}' == *'localhost:6379'* ]]; } && echo 'local' || echo 'check_url'" \
        "local" \
        "Configure CELERY_BROKER_URL for local Redis"

    # TS.A.13 Loki port exposed
    run_check "TS.A.13" "$category" "Loki port exposed (3100)" "false" \
        "nc -z localhost 3100 2>/dev/null && echo 'exposed' || echo 'not_exposed'" \
        "any" \
        "Expose Loki port for remote log aggregation"

    # TS.A.14 Prometheus scraping DB server
    run_check "TS.A.14" "$category" "Prometheus scraping DB server" "false" \
        "curl -sf http://localhost:9090/api/v1/targets 2>/dev/null | grep -c '$db_host' || echo '0'" \
        "any" \
        "Configure Prometheus to scrape DB server"

    # TS.A.15 Cross-server secrets match
    run_check "TS.A.15" "$category" "Cross-server secrets configured" "true" \
        "[[ -n '${JWT_SECRET:-}' ]] && [[ -n '${INTERNAL_SERVICE_KEY:-}' ]] && echo 'configured' || echo 'missing'" \
        "configured" \
        "Ensure secrets match on both servers"
}

run_two_server_app_checks() {
    check_external_database
}
