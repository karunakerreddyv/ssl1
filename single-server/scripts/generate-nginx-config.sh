#!/bin/bash
# =============================================================================
# Generate NGINX Configuration from Template
# Substitutes environment variables into NGINX config
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment from .env if exists
if [ -f "$DEPLOY_DIR/.env" ]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

# Validate required variables
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN environment variable is not set"
    echo "Please set DOMAIN in .env file or export it"
    exit 1
fi

TEMPLATE_FILE="$DEPLOY_DIR/nginx/conf.d/pravaha.conf.template"
OUTPUT_FILE="$DEPLOY_DIR/nginx/conf.d/pravaha.conf"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

echo "Generating NGINX configuration..."
echo "  Domain: $DOMAIN"
echo "  Template: $TEMPLATE_FILE"
echo "  Output: $OUTPUT_FILE"

# Set default for MAX_UPLOAD_SIZE_MB if not already set
MAX_UPLOAD_SIZE_MB="${MAX_UPLOAD_SIZE_MB:-500}"

echo "  Max Upload Size: ${MAX_UPLOAD_SIZE_MB}MB"

# Use envsubst to substitute variables
# Only substitute DOMAIN and MAX_UPLOAD_SIZE_MB to avoid replacing nginx variables like $host, $uri, etc.
envsubst '${DOMAIN} ${MAX_UPLOAD_SIZE_MB}' < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

# Verify the generated file exists and is not empty
if [ ! -s "$OUTPUT_FILE" ]; then
    echo "ERROR: Generated config file is empty or missing!"
    exit 1
fi

echo ""
echo "NGINX configuration generated successfully!"
echo ""
echo "Generated config preview (first 10 lines):"
head -10 "$OUTPUT_FILE"
echo "..."
echo ""
echo "To apply changes:"
echo "  docker compose exec nginx nginx -s reload"
echo "  # or restart nginx container"
echo "  docker compose restart nginx"
