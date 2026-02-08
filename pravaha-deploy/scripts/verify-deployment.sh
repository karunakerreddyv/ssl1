#!/bin/bash
# =============================================================================
# Pravaha Platform - Post-Deployment Verification Script
# Single-Server Deployment - 267 Comprehensive Checks
# =============================================================================
#
# Usage:
#   ./scripts/verify-deployment.sh [OPTIONS]
#
# Options:
#   --quick           Run critical checks only (faster)
#   --full            Run all 267 checks (default)
#   --category CAT    Run specific category only
#   --json            Output JSON report only
#   --html            Output HTML report only
#   --txt             Output TXT report only
#   --all-reports     Generate all report formats (default)
#   --quiet           Only show failures
#   --ci              CI/CD mode (exit codes, no colors, no interactive)
#   --report-dir DIR  Custom report output directory
#   --timeout SEC     Per-check timeout (default: 30s)
#   -v, --verbose     Verbose output
#   -h, --help        Show help
#
# Exit Codes:
#   0 - All critical checks passed
#   1 - One or more critical checks failed
#   2 - Configuration error
#   3 - Script error
#
# =============================================================================

set -uo pipefail

# =============================================================================
# Script Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SHARED_LIB_DIR="${DEPLOY_DIR}/../scripts/lib"
DEPLOYMENT_TYPE="single-server"
SCRIPT_VERSION="1.0.0"

# Default options
RUN_MODE="full"  # full, quick, category
SELECTED_CATEGORY=""
OUTPUT_JSON="true"
OUTPUT_HTML="true"
OUTPUT_TXT="true"
QUIET_MODE="false"
CI_MODE="false"
VERBOSE="false"
REPORT_DIR="${DEPLOY_DIR}/reports"
CHECK_TIMEOUT=30
START_TIME=$(date +%s)

# =============================================================================
# Help Function
# =============================================================================
show_help() {
    cat << 'EOF'
Pravaha Platform - Post-Deployment Verification Script
Single-Server Deployment - 267 Comprehensive Checks

Usage:
  ./scripts/verify-deployment.sh [OPTIONS]

Options:
  --quick           Run critical checks only (~48 checks, faster)
  --full            Run all 267 checks (default)
  --category CAT    Run specific category only
                    Categories: containers, celery, database, redis, http,
                    auth, ssl, env, monitoring, interservice, data, resources,
                    network, backup, app, nginx, docker, logging, performance,
                    secrets, api, ml, superset, compliance, dr

  --json            Output JSON report only
  --html            Output HTML report only
  --txt             Output TXT report only
  --all-reports     Generate all report formats (default)

  --quiet           Only show failures and summary
  --ci              CI/CD mode (no colors, machine-readable output)
  --report-dir DIR  Custom report output directory (default: ./reports)
  --timeout SEC     Per-check timeout in seconds (default: 30)

  -v, --verbose     Verbose output with timing details
  -h, --help        Show this help message

Exit Codes:
  0 - All critical checks passed
  1 - One or more critical checks failed
  2 - Configuration error
  3 - Script error

Examples:
  # Run full verification with all reports
  ./scripts/verify-deployment.sh

  # Quick critical-only check for CI/CD
  ./scripts/verify-deployment.sh --quick --ci

  # Check only SSL certificates
  ./scripts/verify-deployment.sh --category ssl

  # Generate only JSON report in custom directory
  ./scripts/verify-deployment.sh --json --report-dir /tmp/reports

Report Files:
  Reports are saved to: ./reports/verification-YYYYMMDD-HHMMSS.{json,html,txt}
EOF
}

# =============================================================================
# Parse Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            RUN_MODE="quick"
            shift
            ;;
        --full)
            RUN_MODE="full"
            shift
            ;;
        --category)
            RUN_MODE="category"
            SELECTED_CATEGORY="$2"
            shift 2
            ;;
        --json)
            OUTPUT_JSON="true"
            OUTPUT_HTML="false"
            OUTPUT_TXT="false"
            shift
            ;;
        --html)
            OUTPUT_JSON="false"
            OUTPUT_HTML="true"
            OUTPUT_TXT="false"
            shift
            ;;
        --txt)
            OUTPUT_JSON="false"
            OUTPUT_HTML="false"
            OUTPUT_TXT="true"
            shift
            ;;
        --all-reports)
            OUTPUT_JSON="true"
            OUTPUT_HTML="true"
            OUTPUT_TXT="true"
            shift
            ;;
        --quiet|-q)
            QUIET_MODE="true"
            shift
            ;;
        --ci)
            CI_MODE="true"
            QUIET_MODE="true"
            export NO_COLOR="true"
            shift
            ;;
        --report-dir)
            REPORT_DIR="$2"
            shift 2
            ;;
        --timeout)
            CHECK_TIMEOUT="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 2
            ;;
    esac
done

# =============================================================================
# Load Libraries
# =============================================================================
if [[ ! -f "$SHARED_LIB_DIR/common-checks.sh" ]]; then
    echo "ERROR: Cannot find shared library at $SHARED_LIB_DIR/common-checks.sh"
    echo "Make sure deploy/scripts/lib/common-checks.sh exists"
    exit 3
fi

if [[ ! -f "$SHARED_LIB_DIR/report-generators.sh" ]]; then
    echo "ERROR: Cannot find report generators at $SHARED_LIB_DIR/report-generators.sh"
    exit 3
fi

# Export variables before sourcing
export DEPLOY_DIR
export CHECK_TIMEOUT
export QUIET_MODE
export CI_MODE

# Source libraries
source "$SHARED_LIB_DIR/common-checks.sh"
source "$SHARED_LIB_DIR/report-generators.sh"

# =============================================================================
# Load Environment
# =============================================================================
load_environment() {
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        set -a
        source "$DEPLOY_DIR/.env"
        set +a
        [[ "$VERBOSE" == "true" ]] && echo "Loaded environment from $DEPLOY_DIR/.env"
    else
        echo "WARNING: No .env file found at $DEPLOY_DIR/.env"
        echo "Some checks may fail or produce inaccurate results"
    fi

    # Set defaults
    DOMAIN="${DOMAIN:-localhost}"
    POSTGRES_USER="${POSTGRES_USER:-pravaha}"
    PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
    SUPERSET_DB="${SUPERSET_DB:-superset}"
}

# =============================================================================
# Print Header
# =============================================================================
print_header() {
    if [[ "$CI_MODE" == "true" ]]; then
        echo "Pravaha Platform - Post-Deployment Verification"
        echo "Deployment: $DEPLOYMENT_TYPE | Domain: ${DOMAIN:-localhost}"
        echo "Mode: $RUN_MODE | Started: $(date -Iseconds)"
        return
    fi

    echo ""
    echo -e "${BLUE}${BOLD}================================================================================${NC}"
    echo -e "${BLUE}${BOLD}  PRAVAHA PLATFORM - POST-DEPLOYMENT VERIFICATION${NC}"
    echo -e "${BLUE}${BOLD}  ${DEPLOYMENT_TYPE^} Deployment${NC}"
    echo -e "${BLUE}${BOLD}================================================================================${NC}"
    echo ""
    echo "  Domain:     ${DOMAIN:-localhost}"
    echo "  Deploy Dir: $DEPLOY_DIR"
    echo "  Mode:       $RUN_MODE"
    echo "  Started:    $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
}

# =============================================================================
# Run Category by Name
# =============================================================================
run_category() {
    local category="$1"

    case "$category" in
        containers)     check_containers ;;
        celery)         check_celery_workers ;;
        database)       check_database_connectivity ;;
        redis)          check_redis_connectivity ;;
        http)           check_http_endpoints ;;
        auth)           check_authentication_security ;;
        ssl)            check_ssl_certificates ;;
        env)            check_environment_configuration ;;
        monitoring)     check_monitoring_stack ;;
        interservice)   check_inter_service_communication ;;
        data)           check_data_integrity ;;
        resources)      check_system_resources ;;
        network)        check_network_ports ;;
        backup)         check_backup_recovery ;;
        app)            check_application_functionality ;;
        nginx)          check_nginx_configuration ;;
        docker)         check_docker_configuration ;;
        logging)        check_logging_infrastructure ;;
        performance)    check_performance_baseline ;;
        secrets)        check_secret_management ;;
        api)            check_api_functionality ;;
        ml)             check_ml_platform ;;
        superset)       check_superset_integration ;;
        compliance)     check_compliance_audit ;;
        dr)             check_disaster_recovery ;;
        *)
            echo "Unknown category: $category"
            echo "Valid categories: containers, celery, database, redis, http, auth, ssl, env,"
            echo "                  monitoring, interservice, data, resources, network, backup,"
            echo "                  app, nginx, docker, logging, performance, secrets, api, ml,"
            echo "                  superset, compliance, dr"
            exit 2
            ;;
    esac
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    # Setup
    load_environment
    print_header

    # Create report directory
    mkdir -p "$REPORT_DIR"

    # Run checks based on mode
    case "$RUN_MODE" in
        quick)
            run_critical_checks_only
            ;;
        category)
            run_category "$SELECTED_CATEGORY"
            ;;
        full)
            run_all_base_checks
            ;;
    esac

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    # Generate reports
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local report_base="$REPORT_DIR/verification-$timestamp"

    echo ""
    echo -e "${BLUE}${BOLD}Generating Reports...${NC}"
    echo "────────────────────────────────────────────────────────────────"

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        generate_json_report "${report_base}.json" "$DEPLOYMENT_TYPE" "$duration"
    fi

    if [[ "$OUTPUT_HTML" == "true" ]]; then
        generate_html_report "${report_base}.html" "$DEPLOYMENT_TYPE" "$duration"
    fi

    if [[ "$OUTPUT_TXT" == "true" ]]; then
        generate_txt_report "${report_base}.txt" "$DEPLOYMENT_TYPE" "$duration"
    fi

    # Print summary
    print_summary "$duration"

    # CI mode output
    if [[ "$CI_MODE" == "true" ]]; then
        echo ""
        echo "CI_RESULT:total=$TOTAL_CHECKS,passed=$PASSED_CHECKS,failed=$FAILED_CHECKS,critical_failed=$CRITICAL_FAILED"
    fi

    # Determine exit code
    if [[ $CRITICAL_FAILED -gt 0 ]]; then
        [[ "$CI_MODE" != "true" ]] && echo -e "\n${RED}CRITICAL FAILURES DETECTED - Deployment may not be production ready${NC}"
        exit 1
    elif [[ $FAILED_CHECKS -gt 0 ]]; then
        [[ "$CI_MODE" != "true" ]] && echo -e "\n${YELLOW}Non-critical issues detected - Review warnings above${NC}"
        exit 0
    else
        [[ "$CI_MODE" != "true" ]] && echo -e "\n${GREEN}All checks passed - Deployment verified successfully${NC}"
        exit 0
    fi
}

# Run main
main "$@"
