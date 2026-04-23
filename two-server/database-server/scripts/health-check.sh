#!/bin/bash
# =============================================================================
# Pravaha Platform - PostgreSQL Health Check Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Comprehensive health check for dedicated PostgreSQL database server.
#   Validates: PostgreSQL service, connections, replication status (if configured),
#   disk space, connection count, lock status, and overall database health.
#
# Usage:
#   ./health-check.sh [OPTIONS]
#
# Options:
#   --quick, -q        Quick check (service status only)
#   --json             Output results as JSON
#   --verbose, -v      Show detailed information
#   --exit-code        Only return exit code (silent)
#   --replication      Include replication status checks
#   -h, --help         Show this help message
#
# Exit codes:
#   0    All checks passed
#   1    Warnings only (non-critical)
#   2    Critical failures detected
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_VERSION="1.0.0"
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
PRAVAHA_USER="${PRAVAHA_USER:-pravaha}"
PLATFORM_DB="${PLATFORM_DB:-autoanalytics}"
SUPERSET_DB="${SUPERSET_DB:-superset}"

# Warning thresholds
DISK_WARNING_PERCENT=80
DISK_CRITICAL_PERCENT=90
CONNECTION_WARNING_PERCENT=70
CONNECTION_CRITICAL_PERCENT=90
LOCK_WARNING_COUNT=10
LOCK_CRITICAL_COUNT=50
LONG_QUERY_WARNING_SECONDS=300
LONG_QUERY_CRITICAL_SECONDS=3600
REPLICATION_LAG_WARNING_MB=100
REPLICATION_LAG_CRITICAL_MB=500

# Options
QUICK=false
JSON_OUTPUT=false
VERBOSE=false
EXIT_CODE_ONLY=false
CHECK_REPLICATION=false

# Results
CRITICAL_FAILURES=0
WARNINGS=0
PASSED=0
JSON_RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================
log_info() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    local check_name="$1"
    local message="$2"
    [[ "$EXIT_CODE_ONLY" == "true" ]] && { ((PASSED++)); return; }
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${GREEN}[PASS]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"pass\", \"message\": \"$message\"}")
    ((PASSED++))
}

log_warn() {
    local check_name="$1"
    local message="$2"
    [[ "$EXIT_CODE_ONLY" == "true" ]] && { ((WARNINGS++)); return; }
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${YELLOW}[WARN]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"warn\", \"message\": \"$message\"}")
    ((WARNINGS++))
}

log_fail() {
    local check_name="$1"
    local message="$2"
    [[ "$EXIT_CODE_ONLY" == "true" ]] && { ((CRITICAL_FAILURES++)); return; }
    [[ "$JSON_OUTPUT" == "false" ]] && echo -e "${RED}[FAIL]${NC} $check_name: $message"
    JSON_RESULTS+=("{\"check\": \"$check_name\", \"status\": \"fail\", \"message\": \"$message\"}")
    ((CRITICAL_FAILURES++))
}

log_detail() {
    [[ "$EXIT_CODE_ONLY" == "true" ]] && return
    [[ "$VERBOSE" == "true" && "$JSON_OUTPUT" == "false" ]] && echo "       $1"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Comprehensive health check for dedicated PostgreSQL database server.

OPTIONS:
    --quick, -q        Quick check (service status only)
    --json             Output results as JSON
    --verbose, -v      Show detailed information
    --exit-code        Only return exit code (silent)
    --replication      Include replication status checks
    -h, --help         Show this help message

EXIT CODES:
    0    All checks passed
    1    Warnings only (non-critical)
    2    Critical failures detected

EXAMPLES:
    $0                   # Full health check
    $0 --quick           # Quick service status check
    $0 --json            # JSON output for monitoring
    $0 --verbose         # Detailed output
    $0 --replication     # Include replication checks

EOF
    exit 0
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
            --replication)
                CHECK_REPLICATION=true
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
# PostgreSQL Command Helper
# =============================================================================
psql_exec() {
    local db="${1:-postgres}"
    local query="$2"
    sudo -u postgres psql -d "$db" -t -A -c "$query" 2>/dev/null
}

psql_exec_quiet() {
    local db="${1:-postgres}"
    local query="$2"
    sudo -u postgres psql -d "$db" -t -A -c "$query" 2>/dev/null || echo ""
}

# =============================================================================
# Health Check Functions
# =============================================================================

check_postgresql_service() {
    log_info "Checking PostgreSQL service status..."

    if systemctl is-active --quiet postgresql; then
        log_pass "PostgreSQL Service" "Running"
        log_detail "Service: postgresql@$POSTGRES_VERSION-main"
    else
        log_fail "PostgreSQL Service" "Not running"
        return 1
    fi

    # Check if enabled for boot
    if systemctl is-enabled --quiet postgresql 2>/dev/null; then
        log_pass "PostgreSQL Autostart" "Enabled"
    else
        log_warn "PostgreSQL Autostart" "Not enabled for boot"
    fi

    return 0
}

check_postgresql_accepting_connections() {
    log_info "Checking PostgreSQL accepting connections..."

    if sudo -u postgres pg_isready -q 2>/dev/null; then
        log_pass "PostgreSQL Connections" "Accepting connections"
    else
        log_fail "PostgreSQL Connections" "Not accepting connections"
        return 1
    fi

    return 0
}

check_database_existence() {
    log_info "Checking database existence..."

    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        if psql_exec "postgres" "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
            local size=$(psql_exec "$db" "SELECT pg_size_pretty(pg_database_size('$db'))")
            log_pass "Database: $db" "Exists (Size: $size)"
            log_detail "Owner: $(psql_exec postgres "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'")"
        else
            log_fail "Database: $db" "Does not exist"
        fi
    done
}

check_user_existence() {
    log_info "Checking database user..."

    if psql_exec "postgres" "SELECT 1 FROM pg_roles WHERE rolname = '$PRAVAHA_USER'" | grep -q 1; then
        local can_login=$(psql_exec postgres "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$PRAVAHA_USER'")
        if [[ "$can_login" == "t" ]]; then
            log_pass "Database User: $PRAVAHA_USER" "Exists with login privilege"
        else
            log_warn "Database User: $PRAVAHA_USER" "Exists but cannot login"
        fi
    else
        log_fail "Database User: $PRAVAHA_USER" "Does not exist"
    fi
}

check_connection_count() {
    log_info "Checking connection count..."

    local max_connections=$(psql_exec postgres "SHOW max_connections")
    local current_connections=$(psql_exec postgres "SELECT count(*) FROM pg_stat_activity")
    local reserved_connections=$(psql_exec postgres "SHOW superuser_reserved_connections")

    local available_connections=$((max_connections - reserved_connections))
    local usage_percent=$((current_connections * 100 / available_connections))

    log_detail "Current: $current_connections, Max: $max_connections (Reserved: $reserved_connections)"

    if [[ $usage_percent -ge $CONNECTION_CRITICAL_PERCENT ]]; then
        log_fail "Connection Count" "${current_connections}/${available_connections} (${usage_percent}% - CRITICAL)"
    elif [[ $usage_percent -ge $CONNECTION_WARNING_PERCENT ]]; then
        log_warn "Connection Count" "${current_connections}/${available_connections} (${usage_percent}%)"
    else
        log_pass "Connection Count" "${current_connections}/${available_connections} (${usage_percent}%)"
    fi

    # Show connection breakdown if verbose
    if [[ "$VERBOSE" == "true" ]]; then
        log_detail "Connection breakdown by database:"
        psql_exec postgres "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname ORDER BY count DESC LIMIT 5" | while read line; do
            log_detail "  $line"
        done
    fi
}

check_disk_space() {
    log_info "Checking disk space..."

    # Get PostgreSQL data directory
    local data_dir=$(psql_exec postgres "SHOW data_directory")

    if [[ -z "$data_dir" ]]; then
        data_dir="/var/lib/postgresql/$POSTGRES_VERSION/main"
    fi

    local disk_info=$(df -h "$data_dir" 2>/dev/null | tail -1)
    local usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
    local available=$(echo "$disk_info" | awk '{print $4}')
    local total=$(echo "$disk_info" | awk '{print $2}')

    log_detail "Data directory: $data_dir"
    log_detail "Total: $total, Available: $available"

    if [[ $usage_percent -ge $DISK_CRITICAL_PERCENT ]]; then
        log_fail "Disk Space" "${usage_percent}% used ($available available) - CRITICAL"
    elif [[ $usage_percent -ge $DISK_WARNING_PERCENT ]]; then
        log_warn "Disk Space" "${usage_percent}% used ($available available)"
    else
        log_pass "Disk Space" "${usage_percent}% used ($available available)"
    fi

    # Check WAL disk space (may be on different partition)
    local wal_dir=$(psql_exec postgres "SHOW wal_directory" 2>/dev/null || echo "$data_dir/pg_wal")
    if [[ -d "$wal_dir" ]]; then
        local wal_size=$(du -sh "$wal_dir" 2>/dev/null | awk '{print $1}')
        log_detail "WAL directory size: $wal_size"
    fi
}

check_wal_status() {
    log_info "Checking WAL status..."

    local wal_level=$(psql_exec postgres "SHOW wal_level")
    local archive_mode=$(psql_exec postgres "SHOW archive_mode")

    log_detail "WAL level: $wal_level"
    log_detail "Archive mode: $archive_mode"

    # Check WAL file count
    local data_dir=$(psql_exec postgres "SHOW data_directory")
    local wal_count=$(ls -1 "$data_dir/pg_wal" 2>/dev/null | grep -c "^0" || echo "0")

    if [[ $wal_count -gt 100 ]]; then
        log_warn "WAL Files" "$wal_count files (may indicate archiving issues)"
    else
        log_pass "WAL Files" "$wal_count files"
    fi
}

check_locks() {
    log_info "Checking database locks..."

    local lock_count=$(psql_exec postgres "SELECT count(*) FROM pg_locks WHERE NOT granted")

    if [[ $lock_count -ge $LOCK_CRITICAL_COUNT ]]; then
        log_fail "Blocked Locks" "$lock_count waiting locks - CRITICAL"
    elif [[ $lock_count -ge $LOCK_WARNING_COUNT ]]; then
        log_warn "Blocked Locks" "$lock_count waiting locks"
    else
        log_pass "Blocked Locks" "$lock_count waiting locks"
    fi

    # Show blocking queries if verbose and locks exist
    if [[ "$VERBOSE" == "true" && $lock_count -gt 0 ]]; then
        log_detail "Top blocking queries:"
        psql_exec postgres "SELECT pid, usename, left(query, 50) as query FROM pg_stat_activity WHERE pid IN (SELECT pid FROM pg_locks WHERE NOT granted) LIMIT 3" | while read line; do
            log_detail "  $line"
        done
    fi
}

check_long_running_queries() {
    log_info "Checking long-running queries..."

    local long_queries=$(psql_exec postgres "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%' AND now() - query_start > interval '$LONG_QUERY_WARNING_SECONDS seconds'")
    local critical_queries=$(psql_exec postgres "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%' AND now() - query_start > interval '$LONG_QUERY_CRITICAL_SECONDS seconds'")

    if [[ $critical_queries -gt 0 ]]; then
        log_fail "Long-running Queries" "$critical_queries queries running > 1 hour"
    elif [[ $long_queries -gt 0 ]]; then
        log_warn "Long-running Queries" "$long_queries queries running > 5 minutes"
    else
        log_pass "Long-running Queries" "None"
    fi

    # Show long running queries if verbose
    if [[ "$VERBOSE" == "true" && $long_queries -gt 0 ]]; then
        log_detail "Long running queries:"
        psql_exec postgres "SELECT pid, usename, extract(epoch from now() - query_start)::int as runtime_sec, left(query, 50) as query FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%' AND now() - query_start > interval '$LONG_QUERY_WARNING_SECONDS seconds' ORDER BY query_start LIMIT 3" | while read line; do
            log_detail "  $line"
        done
    fi
}

check_replication_status() {
    if [[ "$CHECK_REPLICATION" != "true" ]]; then
        return 0
    fi

    log_info "Checking replication status..."

    # Check if this is a primary or replica
    local is_recovery=$(psql_exec postgres "SELECT pg_is_in_recovery()")

    if [[ "$is_recovery" == "t" ]]; then
        # This is a replica
        log_detail "Server role: Replica"

        # Check replication lag
        local lag_bytes=$(psql_exec postgres "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())")
        local lag_mb=$((lag_bytes / 1024 / 1024))

        if [[ $lag_mb -ge $REPLICATION_LAG_CRITICAL_MB ]]; then
            log_fail "Replication Lag" "${lag_mb}MB behind - CRITICAL"
        elif [[ $lag_mb -ge $REPLICATION_LAG_WARNING_MB ]]; then
            log_warn "Replication Lag" "${lag_mb}MB behind"
        else
            log_pass "Replication Lag" "${lag_mb}MB behind"
        fi

        # Check last receive time
        local last_receive=$(psql_exec postgres "SELECT now() - pg_last_xact_replay_timestamp()")
        log_detail "Last replay: $last_receive ago"

    else
        # This is a primary
        log_detail "Server role: Primary"

        # Check connected replicas
        local replica_count=$(psql_exec postgres "SELECT count(*) FROM pg_stat_replication")

        if [[ $replica_count -gt 0 ]]; then
            log_pass "Connected Replicas" "$replica_count replica(s)"

            if [[ "$VERBOSE" == "true" ]]; then
                psql_exec postgres "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication" | while read line; do
                    log_detail "  Replica: $line"
                done
            fi
        else
            log_warn "Connected Replicas" "No replicas connected"
        fi
    fi
}

check_database_health_metrics() {
    log_info "Checking database health metrics..."

    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        # Check if database is accessible
        if ! psql_exec "$db" "SELECT 1" &>/dev/null; then
            log_warn "Database Health: $db" "Cannot connect"
            continue
        fi

        # Check table count
        local table_count=$(psql_exec "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
        log_detail "$db: $table_count tables"

        # Check for tables needing VACUUM
        local needs_vacuum=$(psql_exec "$db" "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > 10000")
        if [[ $needs_vacuum -gt 0 ]]; then
            log_warn "Database Health: $db" "$needs_vacuum tables need vacuum"
        else
            log_pass "Database Health: $db" "Healthy ($table_count tables)"
        fi

        # Check for bloated indexes
        if [[ "$VERBOSE" == "true" ]]; then
            local bloated=$(psql_exec "$db" "SELECT count(*) FROM pg_stat_user_indexes WHERE idx_scan = 0 AND idx_tup_read = 0 AND idx_tup_fetch = 0")
            if [[ $bloated -gt 0 ]]; then
                log_detail "  $bloated potentially unused indexes"
            fi
        fi
    done
}

check_backup_status() {
    log_info "Checking backup status..."

    local backup_dir="/var/backups/postgresql"

    if [[ -d "$backup_dir" ]]; then
        local latest_backup=$(ls -t "$backup_dir"/*.dump "$backup_dir"/*.sql.gz "$backup_dir"/*.tar.gz 2>/dev/null | head -1)

        if [[ -n "$latest_backup" ]]; then
            local backup_age_hours=$(( ($(date +%s) - $(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null)) / 3600 ))

            if [[ $backup_age_hours -gt 48 ]]; then
                log_warn "Backup Status" "Latest backup is ${backup_age_hours} hours old"
            else
                log_pass "Backup Status" "Latest backup is ${backup_age_hours} hours old"
            fi
            log_detail "Latest: $(basename "$latest_backup")"
        else
            log_warn "Backup Status" "No backups found in $backup_dir"
        fi
    else
        log_warn "Backup Status" "Backup directory not found"
    fi
}

check_pg_extensions() {
    log_info "Checking required extensions..."

    local required_extensions=("uuid-ossp" "pgcrypto")

    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        for ext in "${required_extensions[@]}"; do
            if psql_exec "$db" "SELECT 1 FROM pg_extension WHERE extname = '$ext'" | grep -q 1; then
                log_pass "Extension: $ext ($db)" "Installed"
            else
                log_warn "Extension: $ext ($db)" "Not installed"
            fi
        done
    done
}

check_configuration_status() {
    log_info "Checking configuration status..."

    # Check if listening on all interfaces
    local listen_addr=$(psql_exec postgres "SHOW listen_addresses")
    if [[ "$listen_addr" == "*" ]]; then
        log_pass "Listen Addresses" "All interfaces (*)"
    else
        log_detail "Listen addresses: $listen_addr"
    fi

    # Check SSL
    local ssl_enabled=$(psql_exec postgres "SHOW ssl")
    if [[ "$ssl_enabled" == "on" ]]; then
        log_pass "SSL" "Enabled"
    else
        log_warn "SSL" "Disabled"
    fi

    # Check shared_buffers
    local shared_buffers=$(psql_exec postgres "SHOW shared_buffers")
    log_detail "shared_buffers: $shared_buffers"

    # Check effective_cache_size
    local cache_size=$(psql_exec postgres "SHOW effective_cache_size")
    log_detail "effective_cache_size: $cache_size"
}

# =============================================================================
# Output Functions
# =============================================================================

output_json() {
    echo "{"
    echo "  \"status\": \"$([[ $CRITICAL_FAILURES -eq 0 ]] && echo "healthy" || echo "unhealthy")\","
    echo "  \"deployment\": \"two-server-db\","
    echo "  \"server_type\": \"database-server\","
    echo "  \"postgres_version\": \"$POSTGRES_VERSION\","
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\","
    echo "  \"results\": {"
    echo "    \"passed\": $PASSED,"
    echo "    \"warnings\": $WARNINGS,"
    echo "    \"failures\": $CRITICAL_FAILURES"
    echo "  },"
    echo "  \"checks\": ["
    local first=true
    for result in "${JSON_RESULTS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo -n "    $result"
    done
    echo ""
    echo "  ]"
    echo "}"
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
        echo -e "${GREEN}PostgreSQL is healthy!${NC}"
    elif [[ $CRITICAL_FAILURES -eq 0 ]]; then
        echo -e "${YELLOW}PostgreSQL is running with warnings${NC}"
    else
        echo -e "${RED}Critical issues detected!${NC}"
        echo ""
        echo "Troubleshooting:"
        echo "  - Check logs: sudo journalctl -u postgresql -f"
        echo "  - Check config: sudo -u postgres psql -c 'SHOW config_file'"
        echo "  - Restart service: sudo systemctl restart postgresql"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    if [[ "$JSON_OUTPUT" == "false" && "$EXIT_CODE_ONLY" == "false" ]]; then
        echo ""
        echo "=============================================="
        echo "Pravaha Health Check - Database Server"
        echo "Version: $SCRIPT_VERSION"
        echo "=============================================="
        echo ""
    fi

    # Always check service first
    if ! check_postgresql_service; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            output_json
        elif [[ "$EXIT_CODE_ONLY" == "false" ]]; then
            output_summary
        fi
        exit 1
    fi

    # Check accepting connections
    if ! check_postgresql_accepting_connections; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            output_json
        elif [[ "$EXIT_CODE_ONLY" == "false" ]]; then
            output_summary
        fi
        exit 1
    fi

    # Quick mode - service status only
    if [[ "$QUICK" == "true" ]]; then
        check_database_existence
        check_user_existence
    else
        # Full health checks
        check_database_existence
        check_user_existence
        check_connection_count
        check_disk_space
        check_wal_status
        check_locks
        check_long_running_queries
        check_replication_status
        check_database_health_metrics
        check_backup_status
        check_pg_extensions
        check_configuration_status
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
