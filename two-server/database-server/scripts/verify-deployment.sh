#!/bin/bash
# =============================================================================
# Pravaha Platform - Post-Deployment Verification Script
# Two-Server Database Server - 20 Checks (PostgreSQL focused)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SHARED_LIB_DIR="${DEPLOY_DIR}/../../scripts/lib"
LOCAL_LIB_DIR="${SCRIPT_DIR}/lib"
DEPLOYMENT_TYPE="two-server-database"
SCRIPT_VERSION="1.0.0"

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
        --json)       OUTPUT_JSON="true"; OUTPUT_HTML="false"; OUTPUT_TXT="false"; shift ;;
        --html)       OUTPUT_JSON="false"; OUTPUT_HTML="true"; OUTPUT_TXT="false"; shift ;;
        --txt)        OUTPUT_JSON="false"; OUTPUT_HTML="false"; OUTPUT_TXT="true"; shift ;;
        --quiet|-q)   QUIET_MODE="true"; shift ;;
        --ci)         CI_MODE="true"; QUIET_MODE="true"; export NO_COLOR="true"; shift ;;
        --report-dir) REPORT_DIR="$2"; shift 2 ;;
        -h|--help)    echo "Database Server Verification (20 checks)"; exit 0 ;;
        *)            shift ;;
    esac
done

export DEPLOY_DIR CHECK_TIMEOUT QUIET_MODE CI_MODE
source "$SHARED_LIB_DIR/common-checks.sh"
source "$SHARED_LIB_DIR/report-generators.sh"
source "$LOCAL_LIB_DIR/database-checks.sh"

[[ -f "$DEPLOY_DIR/.env" ]] && { set -a; source "$DEPLOY_DIR/.env"; set +a; }
POSTGRES_USER="${POSTGRES_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"

print_header() {
    [[ "$CI_MODE" == "true" ]] && return
    echo -e "\n${BLUE}${BOLD}PRAVAHA - DATABASE SERVER VERIFICATION${NC}\n"
}

main() {
    print_header
    mkdir -p "$REPORT_DIR"

    # Run database-server specific checks only
    run_database_server_checks

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
