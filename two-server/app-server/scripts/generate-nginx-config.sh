#!/bin/bash
# =============================================================================
# Pravaha Platform - NGINX Configuration Generator
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Generates NGINX configuration from template by substituting the DOMAIN
#   environment variable.
#
# Usage:
#   DOMAIN=example.com ./generate-nginx-config.sh
#   ./generate-nginx-config.sh --domain example.com
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# Template and output paths
TEMPLATE_FILE="$DEPLOY_DIR/nginx/conf.d/pravaha.conf.template"
OUTPUT_FILE="$DEPLOY_DIR/nginx/conf.d/pravaha.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate NGINX configuration from template.

OPTIONS:
    --domain DOMAIN    Domain name to substitute (can also use DOMAIN env var)
    --template FILE    Custom template file path
    --output FILE      Custom output file path
    -h, --help         Show this help message

EXAMPLES:
    DOMAIN=example.com $0
    $0 --domain analytics.example.com
    $0 --domain example.com --output /custom/path/nginx.conf

EOF
    exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --template)
            TEMPLATE_FILE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
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

# =============================================================================
# Main
# =============================================================================

# Load from .env if DOMAIN not set
if [[ -z "$DOMAIN" && -f "$DEPLOY_DIR/.env" ]]; then
    source "$DEPLOY_DIR/.env" 2>/dev/null || true
fi

# Validate DOMAIN
if [[ -z "$DOMAIN" ]]; then
    log_error "DOMAIN is required"
    log_info "Set DOMAIN environment variable or use --domain flag"
    log_info "Example: DOMAIN=example.com $0"
    exit 1
fi

# Validate template exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log_error "Template file not found: $TEMPLATE_FILE"
    exit 1
fi

log_info "Generating NGINX configuration..."
log_info "  Domain:   $DOMAIN"
log_info "  Template: $TEMPLATE_FILE"
log_info "  Output:   $OUTPUT_FILE"

# Create output directory if needed
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Generate configuration using envsubst
# Only substitute DOMAIN and MAX_UPLOAD_SIZE_MB to avoid breaking nginx variables like $host, $request_uri
export DOMAIN
MAX_UPLOAD_SIZE_MB="${MAX_UPLOAD_SIZE_MB:-500}"
export MAX_UPLOAD_SIZE_MB
envsubst '${DOMAIN} ${MAX_UPLOAD_SIZE_MB}' < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

# Verify output is not empty
if [[ ! -s "$OUTPUT_FILE" ]]; then
    log_error "Generated configuration is empty!"
    exit 1
fi

# Validate configuration syntax (if nginx is available)
if command -v nginx &>/dev/null; then
    log_info "Validating NGINX configuration syntax..."
    if nginx -t -c "$DEPLOY_DIR/nginx/nginx.conf" 2>/dev/null; then
        log_success "Configuration syntax is valid"
    else
        log_error "Configuration syntax validation failed"
        exit 1
    fi
fi

log_success "NGINX configuration generated successfully"
log_info ""
log_info "To apply the configuration:"
log_info "  docker compose restart nginx"
log_info ""
log_info "Or reload without restart:"
log_info "  docker exec pravaha-nginx nginx -s reload"
