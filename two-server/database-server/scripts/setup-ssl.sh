#!/bin/bash
# =============================================================================
# Pravaha Platform - PostgreSQL SSL Setup Script
# Two-Server Deployment - Database Server
# =============================================================================
#
# Purpose:
#   Generates SSL/TLS certificates for PostgreSQL secure connections.
#   Creates server certificates and client certificates for app server.
#
# Usage:
#   sudo ./setup-ssl.sh [OPTIONS]
#
# =============================================================================

set -euo pipefail

# Configuration
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
PRAVAHA_USER="${PRAVAHA_USER:-pravaha}"
SSL_CERT_DAYS=365
OUTPUT_DIR="/tmp/pravaha-client-certs"

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
Usage: $0 [OPTIONS]

Generate SSL certificates for PostgreSQL.

OPTIONS:
    --cert-days DAYS        Certificate validity (default: $SSL_CERT_DAYS)
    --output-dir DIR        Output directory for client certs (default: $OUTPUT_DIR)
    --postgres-version VER  PostgreSQL version (default: $POSTGRES_VERSION)
    --regenerate            Regenerate all certificates (overwrites existing)
    -h, --help              Show this help message

EXAMPLES:
    sudo $0
    sudo $0 --cert-days 730  # 2-year certificates
    sudo $0 --regenerate     # Regenerate all certs

OUTPUT:
    Server certificates: /etc/postgresql/$POSTGRES_VERSION/main/ssl/
    Client certificates: $OUTPUT_DIR/
    Client cert bundle:  $OUTPUT_DIR.tar.gz

EOF
    exit 0
}

REGENERATE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cert-days)
                SSL_CERT_DAYS="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --postgres-version)
                POSTGRES_VERSION="$2"
                shift 2
                ;;
            --regenerate)
                REGENERATE=true
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
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_existing_certs() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    if [[ -f "$ssl_dir/server.crt" && -f "$ssl_dir/server.key" ]]; then
        if [[ "$REGENERATE" != "true" ]]; then
            log_warning "SSL certificates already exist at $ssl_dir"

            # Show certificate expiry
            local expiry=$(openssl x509 -enddate -noout -in "$ssl_dir/server.crt" 2>/dev/null | cut -d= -f2)
            log_info "Server certificate expires: $expiry"

            read -p "Regenerate certificates? (y/N): " regen
            if [[ ! "$regen" =~ ^[Yy]$ ]]; then
                log_info "Keeping existing certificates"

                # Still create client cert bundle if requested
                create_client_bundle
                return 1
            fi
        fi

        log_info "Backing up existing certificates..."
        local backup_dir="$ssl_dir/backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp "$ssl_dir"/*.crt "$ssl_dir"/*.key "$backup_dir/" 2>/dev/null || true
    fi

    return 0
}

generate_ca_certificate() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"
    mkdir -p "$ssl_dir"

    log_info "Generating CA certificate..."

    # Generate CA private key
    openssl genrsa -out "$ssl_dir/ca.key" 4096 2>/dev/null

    # Generate CA certificate
    openssl req -new -x509 -days "$SSL_CERT_DAYS" \
        -key "$ssl_dir/ca.key" \
        -out "$ssl_dir/ca.crt" \
        -subj "/CN=Pravaha-PostgreSQL-CA/O=Pravaha Platform/OU=Database/C=US"

    log_success "CA certificate generated"
}

generate_server_certificate() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    log_info "Generating server certificate..."

    # Get server information
    local server_hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(hostname -I | awk '{print $1}')

    # Generate server private key
    openssl genrsa -out "$ssl_dir/server.key" 2048 2>/dev/null

    # Create server CSR configuration
    cat > "$ssl_dir/server.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $server_hostname
O = Pravaha Platform
OU = Database Server

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $server_hostname
DNS.2 = localhost
IP.1 = $server_ip
IP.2 = 127.0.0.1
EOF

    # Generate CSR
    openssl req -new -key "$ssl_dir/server.key" \
        -out "$ssl_dir/server.csr" \
        -config "$ssl_dir/server.cnf"

    # Sign server certificate with CA
    openssl x509 -req -days "$SSL_CERT_DAYS" \
        -in "$ssl_dir/server.csr" \
        -CA "$ssl_dir/ca.crt" \
        -CAkey "$ssl_dir/ca.key" \
        -CAcreateserial \
        -out "$ssl_dir/server.crt" \
        -extensions v3_req \
        -extfile "$ssl_dir/server.cnf" 2>/dev/null

    log_success "Server certificate generated"
}

generate_client_certificate() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    log_info "Generating client certificate for $PRAVAHA_USER..."

    # Generate client private key
    openssl genrsa -out "$ssl_dir/client.key" 2048 2>/dev/null

    # Create client CSR configuration
    cat > "$ssl_dir/client.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $PRAVAHA_USER
O = Pravaha Platform
OU = Application

[v3_req]
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

    # Generate CSR
    openssl req -new -key "$ssl_dir/client.key" \
        -out "$ssl_dir/client.csr" \
        -config "$ssl_dir/client.cnf"

    # Sign client certificate with CA
    openssl x509 -req -days "$SSL_CERT_DAYS" \
        -in "$ssl_dir/client.csr" \
        -CA "$ssl_dir/ca.crt" \
        -CAkey "$ssl_dir/ca.key" \
        -CAcreateserial \
        -out "$ssl_dir/client.crt" \
        -extensions v3_req \
        -extfile "$ssl_dir/client.cnf" 2>/dev/null

    log_success "Client certificate generated"
}

set_permissions() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    log_info "Setting certificate permissions..."

    # Set ownership
    chown postgres:postgres "$ssl_dir"/*.key "$ssl_dir"/*.crt 2>/dev/null || true
    chown postgres:postgres "$ssl_dir"/*.cnf "$ssl_dir"/*.csr "$ssl_dir"/*.srl 2>/dev/null || true

    # Set permissions
    chmod 600 "$ssl_dir"/*.key
    chmod 644 "$ssl_dir"/*.crt
    chmod 600 "$ssl_dir/ca.key"  # Extra protection for CA key

    log_success "Permissions set"
}

configure_postgresql_ssl() {
    local pg_conf="/etc/postgresql/$POSTGRES_VERSION/main/postgresql.conf"
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    log_info "Configuring PostgreSQL for SSL..."

    # Enable SSL
    sed -i "s/#ssl = off/ssl = on/" "$pg_conf"
    sed -i "s/ssl = off/ssl = on/" "$pg_conf"

    # Check if SSL paths are already configured
    if grep -q "ssl_cert_file = '$ssl_dir" "$pg_conf"; then
        log_info "SSL paths already configured in postgresql.conf"
    else
        # Remove any existing SSL path configurations
        sed -i '/^ssl_cert_file/d' "$pg_conf"
        sed -i '/^ssl_key_file/d' "$pg_conf"
        sed -i '/^ssl_ca_file/d' "$pg_conf"

        # Add SSL configuration
        cat >> "$pg_conf" << EOF

# SSL Configuration - Added by setup-ssl.sh on $(date)
ssl_cert_file = '$ssl_dir/server.crt'
ssl_key_file = '$ssl_dir/server.key'
ssl_ca_file = '$ssl_dir/ca.crt'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'
EOF
    fi

    log_success "PostgreSQL SSL configured"
}

create_client_bundle() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"

    log_info "Creating client certificate bundle..."

    # Create output directory
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    # Copy certificates
    cp "$ssl_dir/ca.crt" "$OUTPUT_DIR/"
    cp "$ssl_dir/client.crt" "$OUTPUT_DIR/"
    cp "$ssl_dir/client.key" "$OUTPUT_DIR/"

    # Set restrictive permissions
    chmod 600 "$OUTPUT_DIR"/*

    # Create tarball
    tar czf "${OUTPUT_DIR}.tar.gz" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
    chmod 644 "${OUTPUT_DIR}.tar.gz"

    log_success "Client certificate bundle created: ${OUTPUT_DIR}.tar.gz"
}

reload_postgresql() {
    log_info "Reloading PostgreSQL..."

    if systemctl reload postgresql 2>/dev/null; then
        log_success "PostgreSQL reloaded"
    else
        log_warning "Could not reload PostgreSQL. Attempting restart..."
        systemctl restart postgresql
        if systemctl is-active --quiet postgresql; then
            log_success "PostgreSQL restarted"
        else
            log_error "PostgreSQL failed to start"
            log_info "Check logs: journalctl -u postgresql"
            return 1
        fi
    fi
}

verify_ssl() {
    log_info "Verifying SSL configuration..."

    # Check if SSL is enabled
    local ssl_status=$(sudo -u postgres psql -tAc "SHOW ssl;" 2>/dev/null)

    if [[ "$ssl_status" == "on" ]]; then
        log_success "SSL is enabled in PostgreSQL"
    else
        log_warning "SSL may not be enabled. Current status: $ssl_status"
    fi

    # Show certificate info
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"
    local expiry=$(openssl x509 -enddate -noout -in "$ssl_dir/server.crt" 2>/dev/null | cut -d= -f2)
    log_info "Server certificate expires: $expiry"
}

print_summary() {
    local ssl_dir="/etc/postgresql/$POSTGRES_VERSION/main/ssl"
    local server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "=============================================="
    log_success "SSL Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Server Certificates Location:"
    echo "  $ssl_dir/"
    echo ""
    echo "Client Certificates Bundle:"
    echo "  ${OUTPUT_DIR}.tar.gz"
    echo ""
    echo "To transfer to app server:"
    echo "  scp ${OUTPUT_DIR}.tar.gz user@APP_SERVER_IP:~/"
    echo ""
    echo "On the app server:"
    echo "  tar xzf pravaha-client-certs.tar.gz"
    echo "  mv pravaha-client-certs/* /opt/pravaha/ssl/postgres/"
    echo "  chmod 600 /opt/pravaha/ssl/postgres/*"
    echo ""
    echo "App server .env configuration:"
    echo "  POSTGRES_SSL_ENABLED=true"
    echo "  POSTGRES_SSL_MODE=verify-ca"
    echo "  POSTGRES_SSL_CA=/app/ssl/postgres/ca.crt"
    echo "  POSTGRES_SSL_CERT=/app/ssl/postgres/client.crt"
    echo "  POSTGRES_SSL_KEY=/app/ssl/postgres/client.key"
    echo ""
    echo "Test SSL connection:"
    echo "  PGSSLMODE=verify-ca PGSSLROOTCERT=$OUTPUT_DIR/ca.crt \\"
    echo "    psql -h $server_ip -U $PRAVAHA_USER -d autoanalytics"
    echo ""
}

main() {
    echo ""
    echo "=============================================="
    echo "Pravaha - PostgreSQL SSL Setup"
    echo "=============================================="
    echo ""

    parse_args "$@"
    check_root

    check_existing_certs || exit 0

    generate_ca_certificate
    generate_server_certificate
    generate_client_certificate
    set_permissions
    configure_postgresql_ssl
    create_client_bundle
    reload_postgresql
    verify_ssl
    print_summary
}

main "$@"
