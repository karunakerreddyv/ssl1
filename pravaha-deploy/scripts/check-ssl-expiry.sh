#!/bin/bash
# =============================================================================
# Pravaha Platform - SSL Certificate Expiry Check and Renewal Verification
# Monitors SSL certificates and validates renewal status
# =============================================================================
#
# Usage:
#   ./check-ssl-expiry.sh                    # Check certificates
#   ./check-ssl-expiry.sh --warn-days 30     # Custom warning threshold
#   ./check-ssl-expiry.sh --renew            # Check and attempt renewal
#   ./check-ssl-expiry.sh --json             # Output in JSON format
#   ./check-ssl-expiry.sh --log              # Log to file for audit
#
# Exit codes:
#   0 - All certificates valid
#   1 - Certificate expiring within warning threshold
#   2 - Certificate expired or critical error
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SSL_DIR="$DEPLOY_DIR/ssl"
LOG_DIR="$DEPLOY_DIR/logs"

# Default configuration
WARN_DAYS=30
CRITICAL_DAYS=7
ATTEMPT_RENEWAL=false
JSON_OUTPUT=false
LOG_TO_FILE=false
RENEW_METHOD="certbot"  # certbot or acme

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --warn-days)
            WARN_DAYS="$2"
            shift 2
            ;;
        --critical-days)
            CRITICAL_DAYS="$2"
            shift 2
            ;;
        --renew)
            ATTEMPT_RENEWAL=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --log)
            LOG_TO_FILE=true
            shift
            ;;
        --renew-method)
            RENEW_METHOD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --warn-days <N>      Days before expiry to warn (default: 30)"
            echo "  --critical-days <N>  Days before expiry for critical alert (default: 7)"
            echo "  --renew              Attempt certificate renewal if expiring"
            echo "  --renew-method <M>   Renewal method: certbot or acme (default: certbot)"
            echo "  --json               Output in JSON format"
            echo "  --log                Log to file for audit trail"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
    log_to_audit "INFO" "$1"
}

log_success() {
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    fi
    log_to_audit "SUCCESS" "$1"
}

log_warning() {
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} $1"
    fi
    log_to_audit "WARNING" "$1"
}

log_error() {
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${RED}[ERROR]${NC} $1"
    fi
    log_to_audit "ERROR" "$1"
}

log_to_audit() {
    if [[ "$LOG_TO_FILE" == "true" ]]; then
        mkdir -p "$LOG_DIR"
        echo "[$(date -Iseconds)] [$1] $2" >> "$LOG_DIR/ssl-audit.log"
    fi
}

# Load environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

DOMAIN="${DOMAIN:-localhost}"

# =============================================================================
# Certificate Validation Functions
# =============================================================================

# Check if certificate exists
check_cert_exists() {
    local cert_file="$1"
    if [[ ! -f "$cert_file" ]]; then
        return 1
    fi
    return 0
}

# Get certificate expiry date in seconds from now
get_cert_expiry_seconds() {
    local cert_file="$1"
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry_date" ]]; then
        echo "-1"
        return
    fi

    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    echo $((expiry_epoch - now_epoch))
}

# Get certificate details
get_cert_info() {
    local cert_file="$1"

    local subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
    local issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//')
    local not_before=$(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | cut -d= -f2)
    local not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    local serial=$(openssl x509 -in "$cert_file" -noout -serial 2>/dev/null | cut -d= -f2)
    local fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

    # Get SANs
    local sans=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/DNS://g; s/,//g; s/^ *//')

    echo "subject:$subject"
    echo "issuer:$issuer"
    echo "not_before:$not_before"
    echo "not_after:$not_after"
    echo "serial:$serial"
    echo "fingerprint:$fingerprint"
    echo "sans:$sans"
}

# Check if certificate matches private key
validate_cert_key_match() {
    local cert_file="$1"
    local key_file="$2"

    if [[ ! -f "$key_file" ]]; then
        return 1
    fi

    local cert_modulus=$(openssl x509 -in "$cert_file" -noout -modulus 2>/dev/null | md5sum | cut -d' ' -f1)
    local key_modulus=$(openssl rsa -in "$key_file" -noout -modulus 2>/dev/null | md5sum | cut -d' ' -f1)

    if [[ "$cert_modulus" == "$key_modulus" ]]; then
        return 0
    else
        return 1
    fi
}

# Check if certificate is self-signed
is_self_signed() {
    local cert_file="$1"
    local subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | md5sum | cut -d' ' -f1)
    local issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | md5sum | cut -d' ' -f1)

    if [[ "$subject" == "$issuer" ]]; then
        return 0
    else
        return 1
    fi
}

# Check if certificate domain matches
validate_cert_domain() {
    local cert_file="$1"
    local expected_domain="$2"

    # Check CN (portable alternative to grep -oP)
    local cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p' | head -1)
    if [[ "$cn" == "$expected_domain" ]]; then
        return 0
    fi

    # Check SANs
    local sans=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1)
    if echo "$sans" | grep -q "DNS:$expected_domain"; then
        return 0
    fi

    # Check wildcard
    local parent_domain=$(echo "$expected_domain" | cut -d. -f2-)
    if echo "$sans" | grep -q "DNS:\*\.$parent_domain"; then
        return 0
    fi

    return 1
}

# =============================================================================
# Certificate Renewal
# =============================================================================

attempt_certbot_renewal() {
    log_info "Attempting certificate renewal via certbot..."

    # Check if certbot is available
    if ! command -v certbot &> /dev/null; then
        # Try using docker
        if docker run --rm certbot/certbot --version &> /dev/null; then
            log_info "Using certbot via Docker"

            # Run certbot renew
            docker run --rm \
                -v "$SSL_DIR:/etc/letsencrypt/live/$DOMAIN:rw" \
                -v "$DEPLOY_DIR/certbot_www:/var/www/certbot:rw" \
                certbot/certbot renew \
                --webroot \
                --webroot-path=/var/www/certbot \
                --quiet

            local result=$?
            if [[ $result -eq 0 ]]; then
                log_success "Certificate renewed successfully"

                # Reload nginx
                log_info "Reloading nginx..."
                docker compose -f "$DEPLOY_DIR/docker-compose.yml" exec nginx nginx -s reload 2>/dev/null || \
                    docker compose restart nginx 2>/dev/null || \
                    log_warning "Could not reload nginx automatically"

                return 0
            else
                log_error "Certificate renewal failed"
                return 1
            fi
        else
            log_error "Certbot not available. Install certbot or use Docker."
            return 1
        fi
    else
        # Use local certbot
        certbot renew --quiet
        local result=$?

        if [[ $result -eq 0 ]]; then
            log_success "Certificate renewed successfully"

            # Reload nginx
            docker compose exec nginx nginx -s reload 2>/dev/null || \
                systemctl reload nginx 2>/dev/null || \
                log_warning "Could not reload nginx automatically"

            return 0
        else
            log_error "Certificate renewal failed"
            return 1
        fi
    fi
}

# =============================================================================
# Main Check Function
# =============================================================================

check_certificates() {
    local cert_file="$SSL_DIR/fullchain.pem"
    local key_file="$SSL_DIR/privkey.pem"
    local exit_code=0
    local results=()

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo "=============================================="
        echo "Pravaha Platform - SSL Certificate Check"
        echo "=============================================="
        echo ""
        echo "Domain:        $DOMAIN"
        echo "SSL Directory: $SSL_DIR"
        echo "Warn Days:     $WARN_DAYS"
        echo "Critical Days: $CRITICAL_DAYS"
        echo ""
    fi

    # Check certificate exists
    if ! check_cert_exists "$cert_file"; then
        log_error "Certificate file not found: $cert_file"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"status":"error","message":"Certificate file not found"}'
        fi
        return 2
    fi

    # Get certificate info
    local expiry_seconds=$(get_cert_expiry_seconds "$cert_file")
    local expiry_days=$((expiry_seconds / 86400))

    # Parse cert info
    local cert_info=$(get_cert_info "$cert_file")
    local not_after=$(echo "$cert_info" | grep "not_after:" | cut -d: -f2-)
    local issuer=$(echo "$cert_info" | grep "issuer:" | cut -d: -f2-)
    local serial=$(echo "$cert_info" | grep "serial:" | cut -d: -f2-)

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo "Certificate Details:"
        echo "  Expiry:      $not_after ($expiry_days days remaining)"
        echo "  Issuer:      $issuer"
        echo "  Serial:      $serial"
        echo ""
    fi

    # Determine status
    local status="valid"
    local status_message=""

    if [[ $expiry_seconds -le 0 ]]; then
        status="expired"
        status_message="Certificate has EXPIRED!"
        log_error "$status_message"
        exit_code=2
    elif [[ $expiry_days -le $CRITICAL_DAYS ]]; then
        status="critical"
        status_message="Certificate expires in $expiry_days days - CRITICAL!"
        log_error "$status_message"
        exit_code=2
    elif [[ $expiry_days -le $WARN_DAYS ]]; then
        status="warning"
        status_message="Certificate expires in $expiry_days days - renewal recommended"
        log_warning "$status_message"
        exit_code=1
    else
        status="valid"
        status_message="Certificate valid for $expiry_days more days"
        log_success "$status_message"
    fi

    # Validate certificate-key match
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo "Validation Checks:"
    fi

    if validate_cert_key_match "$cert_file" "$key_file"; then
        log_success "  Certificate and private key match"
        results+=("key_match:true")
    else
        log_error "  Certificate and private key DO NOT MATCH"
        results+=("key_match:false")
        exit_code=2
    fi

    # Validate domain
    if validate_cert_domain "$cert_file" "$DOMAIN"; then
        log_success "  Certificate domain matches: $DOMAIN"
        results+=("domain_match:true")
    else
        log_warning "  Certificate domain may not match: $DOMAIN"
        results+=("domain_match:false")
    fi

    # Check if self-signed
    if is_self_signed "$cert_file"; then
        log_warning "  Certificate is self-signed (not trusted by browsers)"
        results+=("self_signed:true")
    else
        log_success "  Certificate is CA-signed"
        results+=("self_signed:false")
    fi

    # JSON output
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat << EOF
{
    "status": "$status",
    "message": "$status_message",
    "domain": "$DOMAIN",
    "expiry_days": $expiry_days,
    "expiry_date": "$not_after",
    "issuer": "$issuer",
    "serial": "$serial",
    "key_match": $(echo "$results" | grep -q "key_match:true" && echo "true" || echo "false"),
    "domain_match": $(echo "$results" | grep -q "domain_match:true" && echo "true" || echo "false"),
    "self_signed": $(echo "$results" | grep -q "self_signed:true" && echo "true" || echo "false"),
    "checked_at": "$(date -Iseconds)"
}
EOF
    fi

    # Attempt renewal if requested and needed
    if [[ "$ATTEMPT_RENEWAL" == "true" ]] && [[ $exit_code -ne 0 ]] && [[ "$status" != "expired" ]]; then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo ""
            echo "Attempting renewal..."
        fi

        if ! is_self_signed "$cert_file"; then
            attempt_certbot_renewal
            local renewal_result=$?

            if [[ $renewal_result -eq 0 ]]; then
                # Re-check after renewal
                expiry_seconds=$(get_cert_expiry_seconds "$cert_file")
                expiry_days=$((expiry_seconds / 86400))

                if [[ $expiry_days -gt $WARN_DAYS ]]; then
                    log_success "Certificate renewal successful! New expiry: $expiry_days days"
                    exit_code=0
                fi
            fi
        else
            log_warning "Cannot auto-renew self-signed certificates"
            log_info "To renew self-signed: ./scripts/generate-self-signed-ssl.sh $DOMAIN"
        fi
    fi

    # Summary
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo "=============================================="
        if [[ $exit_code -eq 0 ]]; then
            log_success "Certificate status: OK"
        elif [[ $exit_code -eq 1 ]]; then
            log_warning "Certificate status: WARNING - renewal recommended"
        else
            log_error "Certificate status: CRITICAL - immediate action required"
        fi
        echo "=============================================="

        if [[ $exit_code -ne 0 ]]; then
            echo ""
            echo "Recommended actions:"
            if is_self_signed "$cert_file"; then
                echo "  1. Generate new self-signed: ./scripts/generate-self-signed-ssl.sh $DOMAIN"
                echo "  2. Or use Let's Encrypt: certbot certonly --webroot -w /var/www/certbot -d $DOMAIN"
            else
                echo "  1. Run: certbot renew"
                echo "  2. Or run: $0 --renew"
            fi
        fi
    fi

    return $exit_code
}

# =============================================================================
# Entry Point
# =============================================================================

log_to_audit "CHECK" "SSL certificate check started for domain: $DOMAIN"
check_certificates
exit_code=$?
log_to_audit "CHECK" "SSL certificate check completed with exit code: $exit_code"

exit $exit_code
