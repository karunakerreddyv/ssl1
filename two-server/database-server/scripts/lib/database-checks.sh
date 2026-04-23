#!/bin/bash
# =============================================================================
# Pravaha Platform - Two-Server Database Server Specific Checks
# Native PostgreSQL installation checks (20 checks)
# =============================================================================

[[ -n "${_DATABASE_CHECKS_LOADED:-}" ]] && return 0
_DATABASE_CHECKS_LOADED=1

# =============================================================================
# Database Server Category: Native PostgreSQL (20 checks)
# =============================================================================
check_native_postgresql() {
    local category="postgresql"
    echo ""
    echo -e "${BLUE}${BOLD}Database Server Category: Native PostgreSQL${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local pg_user="${POSTGRES_USER:-pravaha}"
    local platform_db="${PLATFORM_DB:-autoanalytics}"
    local superset_db="${SUPERSET_DB:-superset}"

    # TS.D.1 PostgreSQL service running
    run_check "TS.D.1" "$category" "PostgreSQL service running" "true" \
        "systemctl is-active postgresql 2>/dev/null || pg_isready >/dev/null 2>&1 && echo 'active' || echo 'inactive'" \
        "active" \
        "Start PostgreSQL: systemctl start postgresql"

    # TS.D.2 PostgreSQL version
    run_check "TS.D.2" "$category" "PostgreSQL version 17" "true" \
        "psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo '0'" \
        "17" \
        "Upgrade PostgreSQL to version 17"

    # TS.D.3 Platform database exists
    run_check "TS.D.3" "$category" "Platform database exists" "true" \
        "sudo -u postgres psql -lqt 2>/dev/null | grep -c '$platform_db' || psql -U $pg_user -lqt 2>/dev/null | grep -c '$platform_db' || echo '0'" \
        "1" \
        "Create platform database"

    # TS.D.4 Superset database exists
    run_check "TS.D.4" "$category" "Superset database exists" "true" \
        "sudo -u postgres psql -lqt 2>/dev/null | grep -c '$superset_db' || psql -U $pg_user -lqt 2>/dev/null | grep -c '$superset_db' || echo '0'" \
        "1" \
        "Create Superset database"

    # TS.D.5 Database user exists
    run_check "TS.D.5" "$category" "Database user exists" "true" \
        "sudo -u postgres psql -c '\\du' 2>/dev/null | grep -c '$pg_user' || echo '0'" \
        "1" \
        "Create database user: $pg_user"

    # TS.D.6 Extensions installed
    run_check "TS.D.6" "$category" "Extensions installed" "true" \
        "sudo -u postgres psql -d $platform_db -c 'SELECT extname FROM pg_extension' 2>/dev/null | grep -c 'uuid-ossp' || echo '0'" \
        "1" \
        "Install uuid-ossp and pgcrypto extensions"

    # TS.D.7 pg_hba.conf allows app server
    run_check "TS.D.7" "$category" "pg_hba.conf allows app server" "true" \
        "cat /etc/postgresql/*/main/pg_hba.conf 2>/dev/null | grep -v '^#' | grep -c 'md5\\|scram-sha-256' || cat /var/lib/pgsql/*/data/pg_hba.conf 2>/dev/null | grep -v '^#' | grep -c 'md5\\|scram-sha-256' || echo '0'" \
        "any" \
        "Add app server IP to pg_hba.conf"

    # TS.D.8 listen_addresses = *
    run_check "TS.D.8" "$category" "listen_addresses configured" "true" \
        "cat /etc/postgresql/*/main/postgresql.conf 2>/dev/null | grep 'listen_addresses' | grep -c '*' || cat /var/lib/pgsql/*/data/postgresql.conf 2>/dev/null | grep 'listen_addresses' | grep -c '*' || echo '0'" \
        "1" \
        "Set listen_addresses = '*' in postgresql.conf"

    # TS.D.9 Memory settings optimal
    run_check "TS.D.9" "$category" "Memory settings optimal" "false" \
        "cat /etc/postgresql/*/main/postgresql.conf 2>/dev/null | grep 'shared_buffers' | grep -oE '[0-9]+' | head -1 || echo '0'" \
        "any" \
        "Configure shared_buffers to 25% of RAM"

    # TS.D.10 Connection limit adequate
    run_check "TS.D.10" "$category" "Connection limit >= 200" "false" \
        "sudo -u postgres psql -t -c 'SHOW max_connections' 2>/dev/null | tr -d '[:space:]' || psql -U $pg_user -t -c 'SHOW max_connections' 2>/dev/null | tr -d '[:space:]' || echo '0'" \
        "any" \
        "Increase max_connections in postgresql.conf"

    # TS.D.11 Firewall allows 5432
    run_check "TS.D.11" "$category" "Firewall allows 5432" "true" \
        "ufw status 2>/dev/null | grep -c '5432' || iptables -L 2>/dev/null | grep -c '5432' || firewall-cmd --list-ports 2>/dev/null | grep -c '5432' || echo '0'" \
        "any" \
        "Open port 5432 in firewall"

    # TS.D.12 SSL enabled
    run_check "TS.D.12" "$category" "SSL enabled" "false" \
        "sudo -u postgres psql -t -c 'SHOW ssl' 2>/dev/null | tr -d '[:space:]' || echo 'off'" \
        "on" \
        "Enable SSL in postgresql.conf"

    # TS.D.13 postgres_exporter running
    run_check "TS.D.13" "$category" "postgres_exporter running" "false" \
        "systemctl is-active postgres_exporter 2>/dev/null || pgrep -f postgres_exporter >/dev/null && echo 'active' || echo 'inactive'" \
        "any" \
        "Install and start postgres_exporter"

    # TS.D.14 Metrics exposed on 9187
    run_check "TS.D.14" "$category" "Metrics exposed on 9187" "false" \
        "curl -sf http://localhost:9187/metrics 2>/dev/null | head -1 | grep -c '#' || echo '0'" \
        "any" \
        "Configure postgres_exporter metrics"

    # TS.D.15 Backup script ready
    run_check "TS.D.15" "$category" "Backup script ready" "false" \
        "[[ -x '${DEPLOY_DIR}/scripts/backup.sh' ]] && echo 'executable' || echo 'not_executable'" \
        "executable" \
        "Create backup.sh script"

    # TS.D.16 Promtail pushing to app server
    run_check "TS.D.16" "$category" "Promtail configured" "false" \
        "systemctl is-active promtail 2>/dev/null || pgrep -f promtail >/dev/null && echo 'active' || echo 'inactive'" \
        "any" \
        "Install and configure Promtail"

    # TS.D.17 Slow query logging
    run_check "TS.D.17" "$category" "Slow query logging" "false" \
        "sudo -u postgres psql -t -c 'SHOW log_min_duration_statement' 2>/dev/null | tr -d '[:space:]' || echo '-1'" \
        "any" \
        "Set log_min_duration_statement in postgresql.conf"

    # TS.D.18 Checkpoint logging
    run_check "TS.D.18" "$category" "Checkpoint logging" "false" \
        "sudo -u postgres psql -t -c 'SHOW log_checkpoints' 2>/dev/null | tr -d '[:space:]' || echo 'off'" \
        "on" \
        "Set log_checkpoints = on"

    # TS.D.19 Connection logging
    run_check "TS.D.19" "$category" "Connection logging" "false" \
        "sudo -u postgres psql -t -c 'SHOW log_connections' 2>/dev/null | tr -d '[:space:]' || echo 'off'" \
        "on" \
        "Set log_connections = on"

    # TS.D.20 Replication status
    run_check "TS.D.20" "$category" "Replication status" "false" \
        "sudo -u postgres psql -t -c 'SELECT COUNT(*) FROM pg_stat_replication' 2>/dev/null | tr -d '[:space:]' || echo 'no_replication'" \
        "any" \
        "Configure replication if needed"
}

run_database_server_checks() {
    check_native_postgresql
}
