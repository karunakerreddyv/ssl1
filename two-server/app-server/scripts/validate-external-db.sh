#!/bin/bash
# =============================================================================
# Pravaha Platform - External Database Validation Script
# Two-Server Deployment
# =============================================================================
#
# Purpose:
#   Validates connectivity and configuration of external PostgreSQL server
#   for two-server deployment architecture.
#
# Usage:
#   ./validate-external-db.sh [options]
#
# Options:
#   --env-file PATH    Path to .env file (default: ../.env)
#   --verbose          Show detailed output
#   --quick            Quick check (TCP only)
#   --json             Output results as JSON
#   --help             Show this help message
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
DEFAULT_ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"

# Options
ENV_FILE=""
VERBOSE=false
QUICK=false
JSON_OUTPUT=false

# Results tracking
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

# =============================================================================
# Functions
# =============================================================================

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Validate external PostgreSQL database connectivity for two-server deployment.

OPTIONS:
    --env-file PATH    Path to .env file (default: $DEFAULT_ENV_FILE)
    --verbose          Show detailed output
    --quick            Quick check (TCP connectivity only)
    --json             Output results as JSON
    -h, --help         Show this help message

EXAMPLES:
    $0
    $0 --env-file /path/to/.env --verbose
    $0 --quick
    $0 --json

ENVIRONMENT VARIABLES (from .env):
    POSTGRES_HOST      Database server IP/hostname (required)
    POSTGRES_PORT      Database port (default: 5432)
    POSTGRES_USER      Database username (required)
    POSTGRES_PASSWORD  Database password (required)
    PLATFORM_DB        Platform database name (default: autoanalytics)
    SUPERSET_DB        Superset database name (default: superset)
    POSTGRES_SSL_ENABLED    Enable SSL (default: false)
    POSTGRES_SSL_MODE       SSL mode (default: prefer)

EOF
    exit 0
}

log_info() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${GREEN}[PASS]${NC} $1"
    fi
    ((CHECKS_PASSED++))
}

log_warning() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
    ((CHECKS_WARNED++))
}

log_error() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${RED}[FAIL]${NC} $1"
    fi
    ((CHECKS_FAILED++))
}

log_detail() {
    if [[ "$VERBOSE" == "true" && "$JSON_OUTPUT" == "false" ]]; then
        echo "       $1"
    fi
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --quick|-q)
                QUICK=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
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

    # Set default env file
    if [[ -z "$ENV_FILE" ]]; then
        ENV_FILE="$DEFAULT_ENV_FILE"
    fi
}

# =============================================================================
# Load Environment
# =============================================================================
load_environment() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Environment file not found: $ENV_FILE"
        log_info "Create .env from .env.example and configure database settings"
        exit 1
    fi

    # Source the environment file
    set -a
    source "$ENV_FILE" 2>/dev/null || true
    set +a

    # Set defaults
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
    SUPERSET_DB="${SUPERSET_DB:-superset}"
    POSTGRES_SSL_ENABLED="${POSTGRES_SSL_ENABLED:-false}"
    POSTGRES_SSL_MODE="${POSTGRES_SSL_MODE:-prefer}"
}

# =============================================================================
# Validation Functions
# =============================================================================

check_required_variables() {
    log_info "Checking required environment variables..."

    local missing=0

    if [[ -z "$POSTGRES_HOST" ]]; then
        log_error "POSTGRES_HOST is not set"
        missing=1
    else
        log_success "POSTGRES_HOST is set: $POSTGRES_HOST"
    fi

    if [[ -z "$POSTGRES_USER" ]]; then
        log_error "POSTGRES_USER is not set"
        missing=1
    else
        log_success "POSTGRES_USER is set: $POSTGRES_USER"
    fi

    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        log_error "POSTGRES_PASSWORD is not set"
        missing=1
    else
        log_success "POSTGRES_PASSWORD is set: [hidden]"
    fi

    if [[ $missing -eq 1 ]]; then
        return 1
    fi

    return 0
}

check_tcp_connectivity() {
    log_info "Testing TCP connectivity to $POSTGRES_HOST:$POSTGRES_PORT..."

    if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$POSTGRES_HOST/$POSTGRES_PORT" 2>/dev/null; then
        log_success "TCP connection successful"
        return 0
    else
        log_error "Cannot connect to $POSTGRES_HOST:$POSTGRES_PORT"
        log_detail "Check: firewall rules, network routing, PostgreSQL is running"
        log_detail "On database server: sudo ss -tlnp | grep $POSTGRES_PORT"
        return 1
    fi
}

check_dns_resolution() {
    log_info "Checking DNS resolution for $POSTGRES_HOST..."

    # Skip if it's an IP address
    if [[ "$POSTGRES_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_success "POSTGRES_HOST is an IP address (no DNS lookup needed)"
        return 0
    fi

    if nslookup "$POSTGRES_HOST" &>/dev/null || host "$POSTGRES_HOST" &>/dev/null; then
        local resolved_ip=$(getent hosts "$POSTGRES_HOST" 2>/dev/null | awk '{print $1}' | head -1)
        log_success "DNS resolution successful: $POSTGRES_HOST -> ${resolved_ip:-[resolved]}"
        return 0
    else
        log_error "DNS resolution failed for $POSTGRES_HOST"
        log_detail "Check your DNS configuration or use IP address directly"
        return 1
    fi
}

check_postgresql_authentication() {
    log_info "Testing PostgreSQL authentication..."

    local conn_opts=""
    if [[ "$POSTGRES_SSL_ENABLED" == "true" ]]; then
        conn_opts="?sslmode=$POSTGRES_SSL_MODE"
    fi

    # Test connection using Docker
    if docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB$conn_opts" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        log_success "PostgreSQL authentication successful"
        return 0
    else
        log_error "PostgreSQL authentication failed"
        log_detail "Check username/password and pg_hba.conf configuration"
        return 1
    fi
}

check_databases_exist() {
    log_info "Verifying databases exist..."

    local conn_opts=""
    if [[ "$POSTGRES_SSL_ENABLED" == "true" ]]; then
        conn_opts="?sslmode=$POSTGRES_SSL_MODE"
    fi

    # Check platform database
    if docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB$conn_opts" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        log_success "Platform database '$PLATFORM_DB' exists and accessible"
    else
        log_error "Platform database '$PLATFORM_DB' not accessible"
        return 1
    fi

    # Check superset database
    if docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$SUPERSET_DB$conn_opts" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        log_success "Superset database '$SUPERSET_DB' exists and accessible"
    else
        log_error "Superset database '$SUPERSET_DB' not accessible"
        return 1
    fi

    return 0
}

check_extensions() {
    log_info "Checking PostgreSQL extensions..."

    local conn_opts=""
    if [[ "$POSTGRES_SSL_ENABLED" == "true" ]]; then
        conn_opts="?sslmode=$POSTGRES_SSL_MODE"
    fi

    local extensions=$(docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB$conn_opts" \
        -t -c "SELECT extname FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto');" 2>/dev/null | tr -d '[:space:]' | tr '\n' ',')

    if [[ "$extensions" == *"uuid-ossp"* && "$extensions" == *"pgcrypto"* ]]; then
        log_success "Required extensions installed: uuid-ossp, pgcrypto"
        return 0
    else
        log_warning "Some extensions may be missing (uuid-ossp, pgcrypto)"
        log_detail "Install with: CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"; CREATE EXTENSION IF NOT EXISTS pgcrypto;"
        return 0
    fi
}

check_write_permissions() {
    log_info "Checking write permissions..."

    local conn_opts=""
    if [[ "$POSTGRES_SSL_ENABLED" == "true" ]]; then
        conn_opts="?sslmode=$POSTGRES_SSL_MODE"
    fi

    local result=$(docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB$conn_opts" \
        -t -c "CREATE TABLE IF NOT EXISTS _validation_test (id int); DROP TABLE IF EXISTS _validation_test; SELECT 'ok';" 2>/dev/null | tr -d '[:space:]')

    if [[ "$result" == "ok" ]]; then
        log_success "Write permissions verified"
        return 0
    else
        log_error "Write permission test failed"
        log_detail "Grant permissions: GRANT ALL ON DATABASE $PLATFORM_DB TO $POSTGRES_USER;"
        return 1
    fi
}

check_ssl_connection() {
    if [[ "$POSTGRES_SSL_ENABLED" != "true" ]]; then
        log_info "SSL is disabled (POSTGRES_SSL_ENABLED=false)"
        return 0
    fi

    log_info "Checking SSL connection (mode: $POSTGRES_SSL_MODE)..."

    local ssl_status=$(docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB?sslmode=$POSTGRES_SSL_MODE" \
        -t -c "SHOW ssl;" 2>/dev/null | tr -d '[:space:]')

    if [[ "$ssl_status" == "on" ]]; then
        log_success "SSL connection verified (server SSL enabled)"
        return 0
    else
        log_warning "SSL connection may not be fully configured on server"
        return 0
    fi
}

check_version() {
    log_info "Checking PostgreSQL version..."

    local conn_opts=""
    if [[ "$POSTGRES_SSL_ENABLED" == "true" ]]; then
        conn_opts="?sslmode=$POSTGRES_SSL_MODE"
    fi

    local version=$(docker run --rm --network host \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:17-alpine \
        psql "postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/$PLATFORM_DB$conn_opts" \
        -t -c "SELECT version();" 2>/dev/null | head -1 | tr -s ' ')

    if [[ -n "$version" ]]; then
        log_success "PostgreSQL version: $version"
        return 0
    else
        log_warning "Could not determine PostgreSQL version"
        return 0
    fi
}

# =============================================================================
# Output Results
# =============================================================================

output_json() {
    cat << EOF
{
    "status": "$([[ $CHECKS_FAILED -eq 0 ]] && echo "success" || echo "failed")",
    "checks": {
        "passed": $CHECKS_PASSED,
        "failed": $CHECKS_FAILED,
        "warnings": $CHECKS_WARNED
    },
    "configuration": {
        "host": "$POSTGRES_HOST",
        "port": $POSTGRES_PORT,
        "user": "$POSTGRES_USER",
        "platform_db": "$PLATFORM_DB",
        "superset_db": "$SUPERSET_DB",
        "ssl_enabled": $POSTGRES_SSL_ENABLED,
        "ssl_mode": "$POSTGRES_SSL_MODE"
    }
}
EOF
}

output_summary() {
    echo ""
    echo "=============================================="
    echo "External Database Validation Summary"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Host:        $POSTGRES_HOST:$POSTGRES_PORT"
    echo "  User:        $POSTGRES_USER"
    echo "  Platform DB: $PLATFORM_DB"
    echo "  Superset DB: $SUPERSET_DB"
    echo "  SSL:         $POSTGRES_SSL_ENABLED (mode: $POSTGRES_SSL_MODE)"
    echo ""
    echo "Results:"
    echo -e "  Passed:   ${GREEN}$CHECKS_PASSED${NC}"
    echo -e "  Failed:   ${RED}$CHECKS_FAILED${NC}"
    echo -e "  Warnings: ${YELLOW}$CHECKS_WARNED${NC}"
    echo ""

    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All critical checks passed!${NC}"
        echo "External database is ready for Pravaha platform."
    else
        echo -e "${RED}Some checks failed.${NC}"
        echo "Please fix the issues above before deploying."
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    load_environment

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo ""
        echo "=============================================="
        echo "Pravaha External Database Validation"
        echo "=============================================="
        echo ""
    fi

    # Run checks
    check_required_variables || exit 1

    check_dns_resolution
    check_tcp_connectivity || exit 1

    if [[ "$QUICK" == "true" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            output_json
        else
            output_summary
        fi
        exit $([[ $CHECKS_FAILED -eq 0 ]] && echo 0 || echo 1)
    fi

    check_postgresql_authentication || exit 1
    check_databases_exist || exit 1
    check_extensions
    check_write_permissions || exit 1
    check_ssl_connection
    check_version

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi

    exit $([[ $CHECKS_FAILED -eq 0 ]] && echo 0 || echo 1)
}

main "$@"
