#!/bin/bash
# =============================================================================
# Pravaha Platform - Configure Remote Access Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Adds or updates pg_hba.conf entries to allow connections from app servers.
#   Use this when adding new app servers or updating access rules.
#
# Usage:
#   sudo ./configure-remote-access.sh --app-server-ip <IP> [OPTIONS]
#
# =============================================================================

set -euo pipefail

# Configuration
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
PRAVAHA_USER="${PRAVAHA_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"

# Options
APP_SERVER_IP=""
USE_SSL=false
REMOVE_ACCESS=false

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

usage() {
    cat << EOF
Usage: $0 --app-server-ip <IP> [OPTIONS]

Configure PostgreSQL remote access for Pravaha app servers.

REQUIRED:
    --app-server-ip IP      IP address or CIDR of the app server

OPTIONS:
    --ssl                   Use SSL-only connections (hostssl)
    --remove                Remove access for the specified IP
    --user USER             Database user (default: $PRAVAHA_USER)
    --postgres-version VER  PostgreSQL version (default: $POSTGRES_VERSION)
    -h, --help              Show this help message

EXAMPLES:
    # Add access for a single server
    sudo $0 --app-server-ip 192.168.1.10

    # Add access with SSL required
    sudo $0 --app-server-ip 192.168.1.10 --ssl

    # Add access for a subnet
    sudo $0 --app-server-ip 192.168.1.0/24

    # Remove access
    sudo $0 --app-server-ip 192.168.1.10 --remove

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --app-server-ip)
                APP_SERVER_IP="$2"
                shift 2
                ;;
            --ssl)
                USE_SSL=true
                shift
                ;;
            --remove)
                REMOVE_ACCESS=true
                shift
                ;;
            --user)
                PRAVAHA_USER="$2"
                shift 2
                ;;
            --postgres-version)
                POSTGRES_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$APP_SERVER_IP" ]]; then
        log_error "--app-server-ip is required"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

add_access() {
    local pg_hba="/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"

    if [[ ! -f "$pg_hba" ]]; then
        log_error "pg_hba.conf not found at $pg_hba"
        exit 1
    fi

    # Determine connection type
    local conn_type="host"
    if [[ "$USE_SSL" == "true" ]]; then
        conn_type="hostssl"
    fi

    # Handle CIDR
    local ip_spec="$APP_SERVER_IP"
    if [[ ! "$ip_spec" =~ / ]]; then
        ip_spec="${APP_SERVER_IP}/32"
    fi

    # Check if entry already exists
    if grep -q "$ip_spec.*$PRAVAHA_USER" "$pg_hba"; then
        log_warning "Entry for $ip_spec already exists in pg_hba.conf"
        log_info "Current entries:"
        grep "$ip_spec" "$pg_hba" || true
        read -p "Replace existing entries? (y/N): " replace
        if [[ "$replace" =~ ^[Yy]$ ]]; then
            # Remove existing entries
            sed -i "/$ip_spec.*$PRAVAHA_USER/d" "$pg_hba"
        else
            log_info "Keeping existing entries"
            return 0
        fi
    fi

    # Backup pg_hba.conf
    cp "$pg_hba" "${pg_hba}.backup.$(date +%Y%m%d_%H%M%S)"

    # Add new entries
    log_info "Adding entries for $APP_SERVER_IP..."

    cat >> "$pg_hba" << EOF

# Pravaha App Server: $APP_SERVER_IP
# Added on $(date)
$conn_type    $PLATFORM_DB    $PRAVAHA_USER    $ip_spec    scram-sha-256
$conn_type    $SUPERSET_DB    $PRAVAHA_USER    $ip_spec    scram-sha-256
$conn_type    all             $PRAVAHA_USER    $ip_spec    scram-sha-256
EOF

    log_success "Access entries added for $APP_SERVER_IP"
}

remove_access() {
    local pg_hba="/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"

    if [[ ! -f "$pg_hba" ]]; then
        log_error "pg_hba.conf not found at $pg_hba"
        exit 1
    fi

    # Handle CIDR
    local ip_spec="$APP_SERVER_IP"
    if [[ ! "$ip_spec" =~ / ]]; then
        ip_spec="${APP_SERVER_IP}/32"
    fi

    # Escape dots for sed
    local escaped_ip=$(echo "$ip_spec" | sed 's/\./\\./g')

    # Backup pg_hba.conf
    cp "$pg_hba" "${pg_hba}.backup.$(date +%Y%m%d_%H%M%S)"

    # Remove entries
    log_info "Removing entries for $APP_SERVER_IP..."

    # Remove the comment line and the following entries
    sed -i "/# Pravaha App Server: $APP_SERVER_IP/,/^$/d" "$pg_hba" 2>/dev/null || true
    sed -i "/$escaped_ip.*$PRAVAHA_USER/d" "$pg_hba"

    log_success "Access entries removed for $APP_SERVER_IP"
}

reload_postgresql() {
    log_info "Reloading PostgreSQL configuration..."

    if systemctl reload postgresql; then
        log_success "PostgreSQL configuration reloaded"
    else
        log_warning "Could not reload PostgreSQL. You may need to restart manually:"
        log_info "  sudo systemctl restart postgresql"
    fi
}

show_current_access() {
    local pg_hba="/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"

    echo ""
    log_info "Current Pravaha access entries in pg_hba.conf:"
    echo ""
    grep -E "(host|hostssl).*$PRAVAHA_USER" "$pg_hba" 2>/dev/null || echo "  No entries found"
    echo ""
}

main() {
    echo ""
    echo "=============================================="
    echo "Pravaha - Configure Remote Access"
    echo "=============================================="
    echo ""

    parse_args "$@"
    check_root

    if [[ "$REMOVE_ACCESS" == "true" ]]; then
        remove_access
    else
        add_access
    fi

    reload_postgresql
    show_current_access
}

main "$@"
