#!/bin/bash
# =============================================================================
# Pravaha Platform - Post-Deployment Verification Script
# Two-Server App Server - 267 Checks (base minus bundled DB + external DB)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SHARED_LIB_DIR="${DEPLOY_DIR}/../../scripts/lib"
LOCAL_LIB_DIR="${SCRIPT_DIR}/lib"
DEPLOYMENT_TYPE="two-server-app"
SCRIPT_VERSION="1.0.0"

RUN_MODE="full"
SELECTED_CATEGORY=""
OUTPUT_JSON="true"
OUTPUT_HTML="true"
OUTPUT_TXT="true"
QUIET_MODE="false"
CI_MODE="false"
REPORT_DIR="${DEPLOY_DIR}/reports"
CHECK_TIMEOUT=30
START_TIME=$(date +%s)

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)      RUN_MODE="quick"; shift ;;
        --full)       RUN_MODE="full"; shift ;;
        --category)   RUN_MODE="category"; SELECTED_CATEGORY="$2"; shift 2 ;;
        --json)       OUTPUT_JSON="true"; OUTPUT_HTML="false"; OUTPUT_TXT="false"; shift ;;
        --html)       OUTPUT_JSON="false"; OUTPUT_HTML="true"; OUTPUT_TXT="false"; shift ;;
        --txt)        OUTPUT_JSON="false"; OUTPUT_HTML="false"; OUTPUT_TXT="true"; shift ;;
        --quiet|-q)   QUIET_MODE="true"; shift ;;
        --ci)         CI_MODE="true"; QUIET_MODE="true"; export NO_COLOR="true"; shift ;;
        --report-dir) REPORT_DIR="$2"; shift 2 ;;
        --timeout)    CHECK_TIMEOUT="$2"; shift 2 ;;
        -h|--help)    echo "Two-Server App Verification (267 checks)"; exit 0 ;;
        *)            echo "Unknown option: $1"; exit 2 ;;
    esac
done

export DEPLOY_DIR CHECK_TIMEOUT QUIET_MODE CI_MODE
source "$SHARED_LIB_DIR/common-checks.sh"
source "$SHARED_LIB_DIR/report-generators.sh"
source "$LOCAL_LIB_DIR/external-db-checks.sh"

[[ -f "$DEPLOY_DIR/.env" ]] && { set -a; source "$DEPLOY_DIR/.env"; set +a; }
DOMAIN="${DOMAIN:-localhost}"

print_header() {
    [[ "$CI_MODE" == "true" ]] && return
    echo -e "\n${BLUE}${BOLD}PRAVAHA - TWO-SERVER APP SERVER VERIFICATION${NC}\n"
}

# Override container checks to skip postgres (it's external)
check_containers_no_postgres() {
    local category="containers"
    echo -e "\n${BLUE}${BOLD}Category 1: Container Health (External DB Mode)${NC}"
    echo "────────────────────────────────────────────────────────────────"
    
    # Skip postgres checks 1.1 and 1.2 - database is external
    run_check "1.3" "$category" "redis container running" "true" \
        "docker inspect --format='{{.State.Status}}' pravaha-redis 2>/dev/null || echo 'not_found'" \
        "running" "Start redis"
    run_check "1.4" "$category" "redis healthy" "true" \
        "docker inspect --format='{{.State.Health.Status}}' pravaha-redis 2>/dev/null || echo 'no_healthcheck'" \
        "healthy" "Check redis logs"
    run_check "1.5" "$category" "backend container running" "true" \
        "docker inspect --format='{{.State.Status}}' pravaha-backend 2>/dev/null || echo 'not_found'" \
        "running" "Start backend"
    run_check "1.6" "$category" "backend healthy" "true" \
        "docker inspect --format='{{.State.Health.Status}}' pravaha-backend 2>/dev/null || echo 'no_healthcheck'" \
        "healthy" "Check backend logs"
    run_check "1.7" "$category" "frontend container running" "false" \
        "docker inspect --format='{{.State.Status}}' pravaha-frontend 2>/dev/null || echo 'not_found'" \
        "running" "Start frontend"
    run_check "1.9" "$category" "nginx container running" "true" \
        "docker inspect --format='{{.State.Status}}' pravaha-nginx 2>/dev/null || echo 'not_found'" \
        "running" "Start nginx"
    run_check "1.11" "$category" "ml-service container running" "false" \
        "docker inspect --format='{{.State.Status}}' pravaha-ml-service 2>/dev/null || echo 'not_found'" \
        "running" "Start ml-service"
    run_check "1.13" "$category" "superset container running" "false" \
        "docker inspect --format='{{.State.Status}}' pravaha-superset 2>/dev/null || echo 'not_found'" \
        "running" "Start superset"
}

main() {
    print_header
    mkdir -p "$REPORT_DIR"

    case "$RUN_MODE" in
        quick) run_critical_checks_only ;;
        category) 
            case "$SELECTED_CATEGORY" in
                external_db) check_external_database ;;
                *) run_category "$SELECTED_CATEGORY" 2>/dev/null || echo "Unknown category" ;;
            esac
            ;;
        full)
            check_containers_no_postgres
            check_celery_workers
            check_external_database
            check_redis_connectivity
            check_http_endpoints
            check_authentication_security
            check_ssl_certificates
            check_environment_configuration
            check_monitoring_stack
            check_inter_service_communication
            check_data_integrity
            check_system_resources
            check_network_ports
            check_backup_recovery
            check_application_functionality
            check_nginx_configuration
            check_docker_configuration
            check_logging_infrastructure
            check_performance_baseline
            check_secret_management
            check_api_functionality
            check_ml_platform
            check_superset_integration
            check_compliance_audit
            check_disaster_recovery
            run_two_server_app_checks
            ;;
    esac

    local duration=$(($(date +%s) - START_TIME))
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local report_base="$REPORT_DIR/verification-$timestamp"

    [[ "$OUTPUT_JSON" == "true" ]] && generate_json_report "${report_base}.json" "$DEPLOYMENT_TYPE" "$duration"
    [[ "$OUTPUT_HTML" == "true" ]] && generate_html_report "${report_base}.html" "$DEPLOYMENT_TYPE" "$duration"
    [[ "$OUTPUT_TXT" == "true" ]] && generate_txt_report "${report_base}.txt" "$DEPLOYMENT_TYPE" "$duration"

    print_summary "$duration"
    [[ $CRITICAL_FAILED -gt 0 ]] && exit 1 || exit 0
}

main "$@"
