#!/bin/bash
# =============================================================================
# Pravaha Platform - PostgreSQL Installation Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Installs and configures PostgreSQL 17 on a dedicated database server
#   for Pravaha platform two-server deployment.
#
# Supported OS:
#   - Ubuntu 22.04 LTS
#   - Ubuntu 24.04 LTS
#   - Debian 12
#
# Usage:
#   sudo ./install-postgres.sh --app-server-ip <IP> --password <PASSWORD> [OPTIONS]
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_VERSION="1.0.0"
POSTGRES_VERSION="17"
PRAVAHA_USER="pravaha"
PLATFORM_DB="autoanalytics"
SUPERSET_DB="superset"

# Options with defaults
APP_SERVER_IP=""
PASSWORD=""
ENABLE_SSL=false
SSL_CERT_DAYS=365
DATA_DIR=""  # Uses default if not specified
LISTEN_ALL=true
MAX_CONNECTIONS=200
SHARED_BUFFERS="256MB"

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
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF
Usage: $0 --app-server-ip <IP> --password <PASSWORD> [OPTIONS]

Install and configure PostgreSQL for Pravaha platform two-server deployment.

REQUIRED:
    --app-server-ip IP      IP address of the application server
    --password PASSWORD     Password for the pravaha database user

OPTIONS:
    --enable-ssl            Enable SSL/TLS for connections
    --ssl-cert-days DAYS    SSL certificate validity (default: $SSL_CERT_DAYS)
    --data-dir DIR          Custom PostgreSQL data directory
    --max-connections N     Maximum connections (default: $MAX_CONNECTIONS)
    --shared-buffers SIZE   Shared buffers (default: $SHARED_BUFFERS)
    --postgres-version VER  PostgreSQL version (default: $POSTGRES_VERSION)
    --no-listen-all         Only listen on localhost (not recommended)
    -h, --help              Show this help message

EXAMPLES:
    # Basic installation
    sudo $0 --app-server-ip 192.168.1.10 --password "SecurePass123!"

    # With SSL enabled
    sudo $0 --app-server-ip 192.168.1.10 --password "SecurePass123!" --enable-ssl

    # With custom settings
    sudo $0 --app-server-ip 192.168.1.10 --password "SecurePass123!" \\
        --max-connections 300 --shared-buffers 512MB

NETWORK REQUIREMENTS:
    - Port 5432 must be open from the app server to this server
    - Ensure firewall allows incoming connections on port 5432

AFTER INSTALLATION:
    1. Copy the connection details to the app server's .env file
    2. If SSL is enabled, copy certificates to the app server
    3. Run the app server installer

EOF
    exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --app-server-ip)
                APP_SERVER_IP="$2"
                shift 2
                ;;
            --password)
                PASSWORD="$2"
                shift 2
                ;;
            --enable-ssl)
                ENABLE_SSL=true
                shift
                ;;
            --ssl-cert-days)
                SSL_CERT_DAYS="$2"
                shift 2
                ;;
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --max-connections)
                MAX_CONNECTIONS="$2"
                shift 2
                ;;
            --shared-buffers)
                SHARED_BUFFERS="$2"
                shift 2
                ;;
            --postgres-version)
                POSTGRES_VERSION="$2"
                shift 2
                ;;
            --no-listen-all)
                LISTEN_ALL=false
                shift
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

    # Validate required arguments
    if [[ -z "$APP_SERVER_IP" ]]; then
        log_error "--app-server-ip is required"
        log_info "This is the IP address of the server that will run the Pravaha application"
        exit 1
    fi

    if [[ -z "$PASSWORD" ]]; then
        log_error "--password is required"
        log_info "This password will be used by the application to connect to the database"
        exit 1
    fi

    # Validate IP format
    if ! [[ "$APP_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Could be hostname or CIDR, allow it but warn
        if [[ "$APP_SERVER_IP" =~ / ]]; then
            log_info "Using CIDR notation: $APP_SERVER_IP"
        else
            log_warning "APP_SERVER_IP may be a hostname: $APP_SERVER_IP"
        fi
    fi
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        exit 1
    fi

    source /etc/os-release

    case "$ID" in
        ubuntu|debian)
            log_info "Detected OS: $PRETTY_NAME"
            ;;
        *)
            log_warning "Unsupported OS: $ID. This script is designed for Ubuntu/Debian."
            read -p "Continue anyway? (y/N): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                exit 1
            fi
            ;;
    esac
}

check_existing_postgres() {
    if command -v psql &>/dev/null; then
        local version=$(psql --version 2>/dev/null | grep -oP '\d+' | head -1)
        log_warning "PostgreSQL $version is already installed"

        if systemctl is-active --quiet postgresql; then
            log_warning "PostgreSQL service is running"
        fi

        read -p "Continue with configuration? (y/N): " continue_config
        if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
            exit 0
        fi

        return 1  # Already installed
    fi

    return 0  # Not installed
}

# =============================================================================
# Installation Functions
# =============================================================================

install_postgresql() {
    log_step "Installing PostgreSQL $POSTGRES_VERSION..."

    # Add PostgreSQL APT repository
    log_info "Adding PostgreSQL APT repository..."

    apt-get update
    apt-get install -y wget gnupg2 lsb-release

    # Add PostgreSQL signing key
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg

    # Add repository
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

    # Install PostgreSQL
    apt-get update
    apt-get install -y postgresql-$POSTGRES_VERSION postgresql-contrib-$POSTGRES_VERSION

    # Start and enable PostgreSQL
    systemctl start postgresql
    systemctl enable postgresql

    log_success "PostgreSQL $POSTGRES_VERSION installed"
}

configure_postgresql() {
    log_step "Configuring PostgreSQL..."

    local pg_conf="/etc/postgresql/$POSTGRES_VERSION/main/postgresql.conf"
    local pg_hba="/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"

    # Backup original config
    cp "$pg_conf" "${pg_conf}.backup.$(date +%Y%m%d)"
    cp "$pg_hba" "${pg_hba}.backup.$(date +%Y%m%d)"

    # Configure listen_addresses
    if [[ "$LISTEN_ALL" == "true" ]]; then
        log_info "Configuring to listen on all interfaces..."
        sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$pg_conf"
        sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" "$pg_conf"
    fi

    # Configure max_connections
    log_info "Setting max_connections to $MAX_CONNECTIONS..."
    sed -i "s/max_connections = [0-9]*/max_connections = $MAX_CONNECTIONS/" "$pg_conf"

    # Configure shared_buffers
    log_info "Setting shared_buffers to $SHARED_BUFFERS..."
    sed -i "s/shared_buffers = [0-9A-Za-z]*/shared_buffers = $SHARED_BUFFERS/" "$pg_conf"

    # Additional performance settings for production
    log_info "Applying production performance settings..."

    cat >> "$pg_conf" << EOF

# Pravaha Platform - Production Settings
# Added by install-postgres.sh on $(date)

# Memory settings
effective_cache_size = 1GB
maintenance_work_mem = 256MB
work_mem = 16MB

# Checkpoint settings
checkpoint_completion_target = 0.9
wal_buffers = 16MB
min_wal_size = 1GB
max_wal_size = 4GB

# Query planning
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100

# Logging
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

# Timezone
timezone = 'UTC'
EOF

    log_success "PostgreSQL configuration updated"
}

configure_remote_access() {
    log_step "Configuring remote access from $APP_SERVER_IP..."

    local pg_hba="/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"

    # Determine connection type (SSL or not)
    local conn_type="host"
    if [[ "$ENABLE_SSL" == "true" ]]; then
        conn_type="hostssl"
    fi

    # Add entries for app server
    log_info "Adding pg_hba.conf entries for $APP_SERVER_IP..."

    # Handle CIDR or single IP
    local ip_spec="$APP_SERVER_IP"
    if [[ ! "$ip_spec" =~ / ]]; then
        ip_spec="${APP_SERVER_IP}/32"
    fi

    cat >> "$pg_hba" << EOF

# Pravaha Platform - App Server Access
# Added by install-postgres.sh on $(date)
# App Server: $APP_SERVER_IP

# Platform database access
$conn_type    $PLATFORM_DB    $PRAVAHA_USER    $ip_spec    scram-sha-256

# Superset database access
$conn_type    $SUPERSET_DB    $PRAVAHA_USER    $ip_spec    scram-sha-256

# Allow user to connect to any database (for migrations)
$conn_type    all             $PRAVAHA_USER    $ip_spec    scram-sha-256
EOF

    log_success "Remote access configured for $APP_SERVER_IP"
}

create_user_and_databases() {
    log_step "Creating user and databases..."

    # Create user
    log_info "Creating user: $PRAVAHA_USER"
    sudo -u postgres psql << EOF
-- Create user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$PRAVAHA_USER') THEN
        CREATE USER $PRAVAHA_USER WITH PASSWORD '$PASSWORD' CREATEDB;
    ELSE
        ALTER USER $PRAVAHA_USER WITH PASSWORD '$PASSWORD';
    END IF;
END
\$\$;
EOF

    # Create platform database
    log_info "Creating database: $PLATFORM_DB"
    sudo -u postgres psql << EOF
-- Create platform database
SELECT 'CREATE DATABASE $PLATFORM_DB OWNER $PRAVAHA_USER ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$PLATFORM_DB')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $PLATFORM_DB TO $PRAVAHA_USER;

-- Connect to platform database and create extensions
\c $PLATFORM_DB

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Grant schema privileges
GRANT ALL ON SCHEMA public TO $PRAVAHA_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $PRAVAHA_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $PRAVAHA_USER;
EOF

    # Create superset database
    log_info "Creating database: $SUPERSET_DB"
    sudo -u postgres psql << EOF
-- Create superset database
SELECT 'CREATE DATABASE $SUPERSET_DB OWNER $PRAVAHA_USER ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$SUPERSET_DB')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $SUPERSET_DB TO $PRAVAHA_USER;

-- Connect to superset database and create extensions
\c $SUPERSET_DB

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Grant schema privileges
GRANT ALL ON SCHEMA public TO $PRAVAHA_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $PRAVAHA_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $PRAVAHA_USER;
EOF

    log_success "User and databases created"
}

setup_ssl() {
    if [[ "$ENABLE_SSL" != "true" ]]; then
        log_info "SSL is disabled. Skipping certificate generation."
        return 0
    fi

    log_step "Setting up SSL certificates..."

    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"
    mkdir -p "$ssl_dir"

    # Generate CA certificate
    log_info "Generating CA certificate..."
    openssl genrsa -out "$ssl_dir/ca.key" 4096 2>/dev/null
    openssl req -new -x509 -days "$SSL_CERT_DAYS" -key "$ssl_dir/ca.key" \
        -out "$ssl_dir/ca.crt" -subj "/CN=Pravaha-PostgreSQL-CA/O=Pravaha/C=US"

    # Generate server certificate
    log_info "Generating server certificate..."
    openssl genrsa -out "$ssl_dir/server.key" 2048 2>/dev/null

    # Create CSR with SAN
    local server_hostname=$(hostname -f)
    local server_ip=$(hostname -I | awk '{print $1}')

    cat > "$ssl_dir/server.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $server_hostname

[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $server_hostname
DNS.2 = localhost
IP.1 = $server_ip
IP.2 = 127.0.0.1
EOF

    openssl req -new -key "$ssl_dir/server.key" -out "$ssl_dir/server.csr" \
        -config "$ssl_dir/server.cnf"

    openssl x509 -req -days "$SSL_CERT_DAYS" -in "$ssl_dir/server.csr" \
        -CA "$ssl_dir/ca.crt" -CAkey "$ssl_dir/ca.key" -CAcreateserial \
        -out "$ssl_dir/server.crt" -extensions v3_req -extfile "$ssl_dir/server.cnf" 2>/dev/null

    # Generate client certificate (for app server)
    log_info "Generating client certificate for app server..."
    openssl genrsa -out "$ssl_dir/client.key" 2048 2>/dev/null
    openssl req -new -key "$ssl_dir/client.key" \
        -out "$ssl_dir/client.csr" -subj "/CN=$PRAVAHA_USER"
    openssl x509 -req -days "$SSL_CERT_DAYS" -in "$ssl_dir/client.csr" \
        -CA "$ssl_dir/ca.crt" -CAkey "$ssl_dir/ca.key" -CAcreateserial \
        -out "$ssl_dir/client.crt" 2>/dev/null

    # Set permissions
    chown postgres:postgres "$ssl_dir"/*
    chmod 600 "$ssl_dir"/*.key
    chmod 644 "$ssl_dir"/*.crt
    chmod 600 "$ssl_dir/ca.key"

    # Configure PostgreSQL for SSL
    local pg_conf="/etc/postgresql/$POSTGRES_VERSION/main/postgresql.conf"

    log_info "Configuring PostgreSQL for SSL..."
    sed -i "s/#ssl = off/ssl = on/" "$pg_conf"
    sed -i "s/ssl = off/ssl = on/" "$pg_conf"

    # Add SSL certificate paths
    cat >> "$pg_conf" << EOF

# SSL Configuration
ssl_cert_file = '$ssl_dir/server.crt'
ssl_key_file = '$ssl_dir/server.key'
ssl_ca_file = '$ssl_dir/ca.crt'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'
EOF

    log_success "SSL certificates generated"

    # Create a tarball of client certificates for transfer
    local client_cert_dir="/tmp/pravaha-client-certs"
    mkdir -p "$client_cert_dir"
    cp "$ssl_dir/ca.crt" "$client_cert_dir/"
    cp "$ssl_dir/client.crt" "$client_cert_dir/"
    cp "$ssl_dir/client.key" "$client_cert_dir/"
    chmod 600 "$client_cert_dir"/*

    tar czf /tmp/pravaha-client-certs.tar.gz -C /tmp pravaha-client-certs
    chmod 644 /tmp/pravaha-client-certs.tar.gz

    log_info ""
    log_info "Client certificates bundle created at: /tmp/pravaha-client-certs.tar.gz"
    log_info "Transfer this file to the app server and extract to ssl/postgres/"
}

configure_firewall() {
    log_step "Configuring firewall..."

    if command -v ufw &>/dev/null; then
        log_info "Configuring UFW firewall..."

        # Allow PostgreSQL from app server
        ufw allow from "$APP_SERVER_IP" to any port 5432 proto tcp comment "Pravaha App Server PostgreSQL"

        # Ensure UFW is enabled
        if ! ufw status | grep -q "Status: active"; then
            log_warning "UFW is not active. Enable it manually if needed."
        else
            log_success "Firewall rule added for PostgreSQL"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$APP_SERVER_IP' port port='5432' protocol='tcp' accept"
        firewall-cmd --reload
        log_success "Firewall rule added for PostgreSQL"
    else
        log_warning "No firewall manager detected. Please configure firewall manually."
        log_warning "Allow port 5432/tcp from $APP_SERVER_IP"
    fi
}

restart_postgresql() {
    log_step "Restarting PostgreSQL..."

    systemctl restart postgresql

    # Wait for PostgreSQL to start
    sleep 3

    if systemctl is-active --quiet postgresql; then
        log_success "PostgreSQL restarted successfully"
    else
        log_error "PostgreSQL failed to start"
        log_error "Check logs: journalctl -u postgresql"
        exit 1
    fi
}

verify_installation() {
    log_step "Verifying installation..."

    # Check PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL is not running"
        return 1
    fi
    log_success "PostgreSQL service is running"

    # Check user exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PRAVAHA_USER'" | grep -q 1; then
        log_success "User '$PRAVAHA_USER' exists"
    else
        log_error "User '$PRAVAHA_USER' not found"
        return 1
    fi

    # Check databases exist
    for db in "$PLATFORM_DB" "$SUPERSET_DB"; do
        if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
            log_success "Database '$db' exists"
        else
            log_error "Database '$db' not found"
            return 1
        fi
    done

    # Check extensions
    local extensions=$(sudo -u postgres psql -d "$PLATFORM_DB" -tAc "SELECT extname FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto')" | wc -l)
    if [[ $extensions -ge 2 ]]; then
        log_success "Required extensions installed"
    else
        log_warning "Some extensions may be missing"
    fi

    # Test local connection
    if PGPASSWORD="$PASSWORD" psql -h localhost -U "$PRAVAHA_USER" -d "$PLATFORM_DB" -c "SELECT 1" &>/dev/null; then
        log_success "Local connection test passed"
    else
        log_warning "Local connection test failed (may need pg_hba.conf update for localhost)"
    fi

    log_success "Installation verification complete"
}

print_summary() {
    local server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "=============================================="
    echo -e "${GREEN}PostgreSQL Installation Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Connection Details (for app server .env):"
    echo "  POSTGRES_HOST=$server_ip"
    echo "  POSTGRES_PORT=5432"
    echo "  POSTGRES_USER=$PRAVAHA_USER"
    echo "  POSTGRES_PASSWORD=[configured password]"
    echo "  PLATFORM_DB=$PLATFORM_DB"
    echo "  SUPERSET_DB=$SUPERSET_DB"

    if [[ "$ENABLE_SSL" == "true" ]]; then
        echo ""
        echo "SSL Certificates:"
        echo "  POSTGRES_SSL_ENABLED=true"
        echo "  POSTGRES_SSL_MODE=verify-ca"
        echo ""
        echo "  Transfer client certificates to app server:"
        echo "    scp /tmp/pravaha-client-certs.tar.gz user@$APP_SERVER_IP:~/"
        echo "    # On app server:"
        echo "    tar xzf pravaha-client-certs.tar.gz"
        echo "    mv pravaha-client-certs/* /opt/pravaha/ssl/postgres/"
    else
        echo ""
        echo "SSL: Disabled"
        echo "  POSTGRES_SSL_ENABLED=false"
    fi

    echo ""
    echo "Database URL for app server:"
    echo "  DATABASE_URL=postgresql://$PRAVAHA_USER:[PASSWORD]@$server_ip:5432/$PLATFORM_DB"
    echo ""
    echo "Useful commands:"
    echo "  - Check status: systemctl status postgresql"
    echo "  - View logs: journalctl -u postgresql -f"
    echo "  - Connect: sudo -u postgres psql"
    echo "  - Backup: pg_dump -h localhost -U $PRAVAHA_USER $PLATFORM_DB > backup.sql"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "Pravaha Platform - PostgreSQL Installation"
    echo "Version: $SCRIPT_VERSION"
    echo "=============================================="
    echo ""

    parse_args "$@"
    check_root
    check_os

    local already_installed=false
    check_existing_postgres || already_installed=true

    if [[ "$already_installed" == "false" ]]; then
        install_postgresql
    fi

    configure_postgresql
    configure_remote_access
    create_user_and_databases
    setup_ssl
    configure_firewall
    restart_postgresql
    verify_installation
    print_summary
}

main "$@"
