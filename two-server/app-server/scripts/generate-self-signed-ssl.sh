#!/bin/bash
# =============================================================================
# Pravaha Platform - Generate Self-Signed SSL Certificates
# Two-Server Deployment - App Server
# For testing and internal deployments only
# =============================================================================
#
# Usage:
#   ./generate-self-signed-ssl.sh                    # Uses DOMAIN from .env
#   ./generate-self-signed-ssl.sh your-domain.com   # Explicit domain
#
# Note: Self-signed certificates will show browser warnings.
#       Use Let's Encrypt for production deployments.
#
# Generated certificates are placed in the ssl/ directory, which is
# volume-mounted into nginx at /etc/nginx/ssl (see docker-compose.yml).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Verify openssl is available
if ! command -v openssl &> /dev/null; then
    log_error "openssl is required but not installed."
    exit 1
fi

# Load environment from .env if exists
if [ -f "$DEPLOY_DIR/.env" ]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

# Get domain from argument or environment
DOMAIN="${1:-${DOMAIN:-}}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain>"
    echo ""
    echo "Or set DOMAIN in .env file"
    exit 1
fi

SSL_DIR="$DEPLOY_DIR/ssl"

echo "=============================================="
echo "Pravaha Platform - Self-Signed SSL Generator"
echo "Deployment:    Two-Server (App Server)"
echo "=============================================="
echo ""
log_info "Domain: $DOMAIN"
log_info "Output: $SSL_DIR"
echo ""

# Back up existing certificates if present
if [ -f "$SSL_DIR/fullchain.pem" ] || [ -f "$SSL_DIR/privkey.pem" ]; then
    BACKUP_DIR="$SSL_DIR/backup-$(date +%Y%m%d-%H%M%S)"
    log_warning "Existing certificates found. Backing up to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    [ -f "$SSL_DIR/fullchain.pem" ] && cp "$SSL_DIR/fullchain.pem" "$BACKUP_DIR/"
    [ -f "$SSL_DIR/privkey.pem" ] && cp "$SSL_DIR/privkey.pem" "$BACKUP_DIR/"
fi

# Create SSL directory
mkdir -p "$SSL_DIR"

# Generate self-signed certificate with X.509 v3 extensions
log_info "Generating self-signed certificate (RSA 2048-bit, valid 365 days)..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_DIR/privkey.pem" \
    -out "$SSL_DIR/fullchain.pem" \
    -subj "/CN=$DOMAIN/O=Pravaha Platform/C=US" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN,DNS:localhost,IP:127.0.0.1" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"

# Set proper permissions
chmod 600 "$SSL_DIR/privkey.pem"
chmod 644 "$SSL_DIR/fullchain.pem"

echo ""
log_success "Self-signed SSL certificate generated!"
echo ""
echo "Certificate details:"
openssl x509 -in "$SSL_DIR/fullchain.pem" -noout -subject -dates -ext subjectAltName
echo ""
log_warning "This is a self-signed certificate - browsers will show a warning."
log_warning "For production, use Let's Encrypt or a trusted CA certificate."
echo ""
echo "Files created:"
echo "  $SSL_DIR/fullchain.pem (certificate)"
echo "  $SSL_DIR/privkey.pem (private key)"
echo ""
echo "Next steps:"
echo "  1. Start/restart services: docker compose up -d"
echo "  2. Verify SSL: ./scripts/check-ssl-expiry.sh"
echo ""
