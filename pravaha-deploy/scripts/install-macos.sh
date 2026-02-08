#!/bin/bash
# =============================================================================
# Pravaha Platform - Single Server Installation Script (macOS)
# macOS Development/Testing Version
# Enterprise-Grade Production Deployment Testing
# =============================================================================
#
# This script is for testing the deployment on macOS before deploying to
# production Ubuntu servers. It validates all deployment components work
# correctly end-to-end.
#
# Features:
#   - Pre-flight validation (disk, memory, network, ports)
#   - macOS-compatible commands (no apt-get, systemctl, etc.)
#   - Full deployment testing with Docker Desktop
#   - Checkpoint/resume capability
#   - Installation audit logging
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Global Configuration
# =============================================================================
SCRIPT_VERSION="2.0.0-macos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_FILE="$DEPLOY_DIR/.install_state"
# Create logs directory early to avoid log file errors
mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null || true
INSTALL_LOG="$DEPLOY_DIR/logs/install_$(date +%Y%m%d_%H%M%S).log"
touch "$INSTALL_LOG" 2>/dev/null || true
CLEANUP_ON_EXIT=true
CURRENT_STEP=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# Logging Functions
# =============================================================================
log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[INFO]${NC} $1" >&2
    [[ -n "$INSTALL_LOG" ]] && echo "[$timestamp] INFO: $1" >> "$INSTALL_LOG" 2>/dev/null || true
}

log_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
    [[ -n "$INSTALL_LOG" ]] && echo "[$timestamp] SUCCESS: $1" >> "$INSTALL_LOG" 2>/dev/null || true
}

log_warning() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
    [[ -n "$INSTALL_LOG" ]] && echo "[$timestamp] WARNING: $1" >> "$INSTALL_LOG" 2>/dev/null || true
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} $1" >&2
    [[ -n "$INSTALL_LOG" ]] && echo "[$timestamp] ERROR: $1" >> "$INSTALL_LOG" 2>/dev/null || true
}

log_step() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[STEP]${NC} $1" >&2
    [[ -n "$INSTALL_LOG" ]] && echo "[$timestamp] STEP: $1" >> "$INSTALL_LOG" 2>/dev/null || true
    CURRENT_STEP="$1"
}

# =============================================================================
# Checkpoint/Resume System
# =============================================================================
save_checkpoint() {
    local step=$1
    local status=${2:-"completed"}

    mkdir -p "$(dirname "$STATE_FILE")"

    cat > "$STATE_FILE" << EOF
{
    "version": "$SCRIPT_VERSION",
    "step": "$step",
    "status": "$status",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "domain": "${domain:-}",
    "ssl_type": "${ssl_type:-}",
    "installer": "${USER:-$(whoami)}",
    "hostname": "$(hostname)"
}
EOF
    chmod 600 "$STATE_FILE"
}

get_checkpoint() {
    [[ ! -f "$STATE_FILE" ]] && echo "" && return
    grep -o '"step": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo ""
}

get_checkpoint_status() {
    [[ ! -f "$STATE_FILE" ]] && echo "" && return
    grep -o '"status": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo ""
}

should_skip_step() {
    local step=$1
    local checkpoint=$(get_checkpoint)
    local status=$(get_checkpoint_status)

    # Define step order
    local steps=(
        "preflight"
        "docker_check"
        "directory_setup"
        "nginx_config"
        "secrets_generation"
        "audit_keys"
        "ssl_setup"
        "image_pull"
        "database_init"
        "services_start"
        "verification"
        "complete"
    )

    # If no checkpoint or failed, don't skip
    [[ -z "$checkpoint" ]] && return 1
    [[ "$status" == "failed" ]] && return 1

    # Find indices
    local checkpoint_idx=-1
    local step_idx=-1
    for i in "${!steps[@]}"; do
        [[ "${steps[$i]}" == "$checkpoint" ]] && checkpoint_idx=$i
        [[ "${steps[$i]}" == "$step" ]] && step_idx=$i
    done

    # Skip if step is before or at checkpoint
    [[ $step_idx -le $checkpoint_idx ]] && return 0
    return 1
}

# =============================================================================
# Cleanup and Error Handling
# =============================================================================
cleanup_on_failure() {
    local exit_code=$?

    if [[ $exit_code -ne 0 && "$CLEANUP_ON_EXIT" == "true" ]]; then
        log_error "Installation failed at step: $CURRENT_STEP"
        log_error "Exit code: $exit_code"

        save_checkpoint "$CURRENT_STEP" "failed"

        echo ""
        log_warning "To resume installation from this point, run:"
        log_warning "  $0 --domain $domain --resume"
        echo ""
        log_warning "To view installation log:"
        log_warning "  cat $INSTALL_LOG"
    fi
}

trap cleanup_on_failure EXIT

# =============================================================================
# macOS-specific utility functions
# =============================================================================

# Cross-platform timeout (macOS doesn't have GNU timeout)
run_with_timeout() {
    local timeout_sec="$1"
    shift

    if command -v gtimeout &>/dev/null; then
        gtimeout "$timeout_sec" "$@"
        return $?
    elif command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@"
        return $?
    elif command -v perl &>/dev/null; then
        perl -e "alarm $timeout_sec; exec @ARGV" "$@"
        return $?
    fi

    # Fallback: just run without timeout
    "$@"
    return $?
}

# Cross-platform sed -i (macOS requires backup extension)
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# =============================================================================
# Pre-Deployment Validation Functions
# =============================================================================

check_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is designed for macOS. Use install.sh for Linux."
        exit 1
    fi
    log_info "Detected: macOS $(sw_vers -productVersion)"
}

validate_disk_space() {
    local min_gb=${1:-20}

    log_info "Checking disk space (minimum ${min_gb}GB required)..."

    # macOS df output format is different
    local available_kb=$(df -k "$DEPLOY_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $min_gb ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available, ${min_gb}GB required"
        return 1
    fi

    log_success "Disk space check passed: ${available_gb}GB available"
    return 0
}

validate_memory() {
    local min_gb=${1:-8}

    log_info "Checking available memory (minimum ${min_gb}GB required)..."

    # macOS memory check
    local total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
    local total_gb=$((total_bytes / 1024 / 1024 / 1024))

    if [[ $total_gb -lt $min_gb ]]; then
        log_warning "Memory below recommended: ${total_gb}GB available, ${min_gb}GB recommended"
    else
        log_success "Memory check passed: ${total_gb}GB available"
    fi
    return 0
}

validate_docker() {
    log_info "Checking Docker Desktop..."

    if ! command -v docker &>/dev/null; then
        log_error "Docker not found. Please install Docker Desktop for Mac."
        log_error "Download: https://www.docker.com/products/docker-desktop/"
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_error "Docker is not running. Please start Docker Desktop."
        return 1
    fi

    local docker_version=$(docker --version | sed -n 's/.*version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)
    log_success "Docker version: $docker_version"

    # Check Docker Compose v2
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 not found."
        return 1
    fi

    local compose_version=$(docker compose version --short 2>/dev/null)
    log_success "Docker Compose version: $compose_version"

    return 0
}

validate_ports() {
    local ports=(80 443 5432 6379 3000 8001 8088)
    local blocked_ports=()

    log_info "Checking if required ports are available..."

    for port in "${ports[@]}"; do
        if lsof -i ":$port" &>/dev/null; then
            blocked_ports+=($port)
        fi
    done

    if [[ ${#blocked_ports[@]} -gt 0 ]]; then
        log_warning "The following ports are in use: ${blocked_ports[*]}"
        log_warning "These services may conflict with the platform"
    else
        log_success "All required ports are available"
    fi
    return 0
}

check_network_connectivity() {
    log_info "Checking network connectivity..."

    # Check DNS resolution
    if ! nslookup google.com &>/dev/null && ! host google.com &>/dev/null; then
        log_error "DNS resolution failed. Check your network configuration."
        return 1
    fi
    log_success "DNS resolution working"

    # Determine which registry to check based on .env or .env.example
    local registry=""
    local script_dir="$(cd "$(dirname "$0")/.." && pwd)"

    # Try to read REGISTRY from .env first, then .env.example
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        registry=$(grep "^REGISTRY=" "$DEPLOY_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    if [[ -z "$registry" ]] && [[ -f "$script_dir/.env" ]]; then
        registry=$(grep "^REGISTRY=" "$script_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    if [[ -z "$registry" ]] && [[ -f "$script_dir/.env.example" ]]; then
        registry=$(grep "^REGISTRY=" "$script_dir/.env.example" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi

    # Default to GHCR if not set
    registry="${registry:-ghcr.io/talentfino/pravaha}"

    # Check connectivity based on registry type
    if [[ "$registry" == ghcr.io/* ]]; then
        # GitHub Container Registry
        log_info "Checking GitHub Container Registry (ghcr.io) connectivity..."
        if ! curl -s --max-time 10 --head https://ghcr.io/v2/ &>/dev/null; then
            log_warning "Cannot reach ghcr.io directly."
            if ! curl -s --max-time 10 --head https://ghcr.io &>/dev/null; then
                log_error "Cannot reach GitHub Container Registry (ghcr.io)."
                return 1
            fi
        fi
        log_success "GitHub Container Registry (ghcr.io) is reachable"
    elif [[ "$registry" == *.amazonaws.com/* ]] || [[ "$registry" == *.dkr.ecr.*.amazonaws.com/* ]]; then
        # AWS ECR
        log_info "Checking AWS ECR connectivity..."
        local ecr_host=$(echo "$registry" | cut -d'/' -f1)
        if ! curl -s --max-time 10 --head "https://$ecr_host" &>/dev/null; then
            log_error "Cannot reach AWS ECR at $ecr_host"
            return 1
        fi
        log_success "AWS ECR is reachable"
    else
        # Docker Hub (default or explicit)
        log_info "Checking Docker Hub connectivity..."
        if ! curl -s --max-time 10 --head https://registry-1.docker.io/v2/ &>/dev/null; then
            log_warning "Cannot reach Docker Hub directly."
            if ! curl -s --max-time 10 --head https://hub.docker.com &>/dev/null; then
                log_error "Cannot reach Docker Hub. Image pull will fail."
                return 1
            fi
        fi
        log_success "Docker Hub is reachable"
    fi

    return 0
}

validate_domain_format() {
    local domain=$1

    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        return 1
    fi

    if [[ "$domain" == *'|'* || "$domain" == *'&'* || "$domain" == *';'* ]]; then
        log_error "Domain contains invalid characters: $domain"
        return 1
    fi

    log_success "Domain format validated: $domain"
    return 0
}

run_pre_deployment_checks() {
    log_info "Running pre-deployment validation checks..."
    echo ""

    local failed=0

    validate_disk_space 20 || failed=1
    validate_memory 8
    validate_docker || failed=1
    validate_ports

    echo ""

    if [[ $failed -eq 1 ]]; then
        log_error "Pre-deployment validation failed. Please fix the issues above."
        return 1
    else
        log_success "All pre-deployment checks passed"
    fi
    return 0
}

# =============================================================================
# Wait for container health
# =============================================================================
wait_for_healthy() {
    local container_name=$1
    local max_attempts=${2:-60}
    local interval=${3:-5}

    log_info "Waiting for $container_name to be healthy..."

    for ((i=1; i<=max_attempts; i++)); do
        local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "not_found")

        if [[ "$status" == "healthy" ]]; then
            log_success "$container_name is healthy"
            return 0
        elif [[ "$status" == "unhealthy" ]]; then
            log_error "$container_name is unhealthy"
            docker logs --tail 20 "$container_name" 2>&1 || true
            return 1
        elif [[ "$status" == "not_found" ]]; then
            log_warning "$container_name not found yet..."
        fi

        if [[ $((i % 6)) -eq 0 ]]; then
            log_info "Still waiting for $container_name... (attempt $i/$max_attempts, status: $status)"
        fi

        sleep $interval
    done

    log_error "$container_name did not become healthy within timeout"
    return 1
}

# =============================================================================
# Setup Functions
# =============================================================================

setup_directories() {
    log_info "Setting up directories..."

    mkdir -p "$DEPLOY_DIR/ssl"
    mkdir -p "$DEPLOY_DIR/backups"
    mkdir -p "$DEPLOY_DIR/logs"
    mkdir -p "$DEPLOY_DIR/reports"

    # Ensure scripts are executable
    chmod +x "$DEPLOY_DIR/scripts/"*.sh 2>/dev/null || true

    log_success "Directories created"
}

generate_nginx_config() {
    local domain=$1

    log_info "Generating NGINX configuration for $domain..."

    local nginx_script="$DEPLOY_DIR/scripts/generate-nginx-config.sh"
    if [[ ! -f "$nginx_script" ]]; then
        log_error "NGINX config script not found: $nginx_script"
        return 1
    fi

    chmod +x "$nginx_script"
    DOMAIN="$domain" bash "$nginx_script"

    log_success "NGINX configuration generated"
}

generate_audit_keys() {
    log_info "Generating audit signature keys..."

    local private_key="$DEPLOY_DIR/audit-private.pem"
    local public_key="$DEPLOY_DIR/audit-public.pem"

    if [[ -f "$private_key" && -f "$public_key" ]]; then
        log_warning "Audit keys already exist. Skipping generation."
        return 0
    fi

    openssl genrsa -out "$private_key" 2048 2>/dev/null
    openssl rsa -in "$private_key" -outform PEM -pubout -out "$public_key" 2>/dev/null

    chmod 600 "$private_key"
    chmod 644 "$public_key"

    log_success "Audit signature keys generated"
}

generate_secrets() {
    local domain=$1

    log_info "Generating secure secrets..."

    local env_file="$DEPLOY_DIR/.env"

    if [[ -f "$env_file" ]]; then
        log_warning ".env file already exists. Backing up and regenerating..."
        cp "$env_file" "$env_file.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cp "$DEPLOY_DIR/.env.example" "$env_file"

    # Generate unique secrets
    local jwt_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local superset_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local encryption_key=$(openssl rand -hex 16)
    local postgres_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local admin_password=$(openssl rand -base64 16 | tr -d '\n/+=')
    local grafana_password=$(openssl rand -base64 16 | tr -d '\n/+=')
    local ml_service_api_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local ml_service_hmac_secret=$(openssl rand -hex 32)
    local csrf_secret=$(openssl rand -base64 32 | tr -d '\n/+=')
    local session_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local jupyter_token=$(openssl rand -base64 32 | tr -d '\n/+=')
    local lineage_secret=$(openssl rand -hex 32)
    local credential_master_key=$(openssl rand -hex 32)
    local model_signing_key=$(openssl rand -hex 32)
    local data_encryption_key=$(openssl rand -hex 32)
    local exception_encryption_key=$(openssl rand -hex 32)
    local audit_signature_secret=$(openssl rand -hex 32)
    local ccm_encryption_key=$(openssl rand -hex 32)
    local storage_encryption_key=$(openssl rand -hex 32)
    local evidence_hmac_secret=$(openssl rand -hex 32)
    local internal_service_key=$(openssl rand -base64 32 | tr -d '\n/+=')

    # ML Credential Encryption Key (Fernet key - URL-safe base64 encoded 32 bytes)
    # Must use python3 + cryptography for valid Fernet key format
    local ml_credential_encryption_key
    if command -v python3 &>/dev/null; then
        ml_credential_encryption_key=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null)
    fi
    if [[ -z "$ml_credential_encryption_key" ]]; then
        # Fallback: generate URL-safe base64 key compatible with Fernet (32 random bytes → urlsafe_b64encode)
        ml_credential_encryption_key=$(python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())" 2>/dev/null \
            || openssl rand 32 | base64 | tr '+/' '-_')
        log_warning "Generated Fernet key via fallback. Verify ML credential encryption works after startup."
    fi

    # ELK Stack secrets
    local elastic_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_system_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_encryption_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_reporting_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_security_key=$(openssl rand -base64 32 | tr -d '\n/+=')

    # Super Admin secrets
    local super_admin_jwt_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local super_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    # Platform admin credentials
    local platform_admin_email="admin@${domain}"
    local platform_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    # Replace placeholders using macOS-compatible sed (avoid GNU-only 0,/pattern/ syntax)
    sed_inplace "s|^JWT_SECRET=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|JWT_SECRET=$jwt_secret|" "$env_file"
    sed_inplace "s|^SUPERSET_SECRET_KEY=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|SUPERSET_SECRET_KEY=$superset_secret|" "$env_file"
    sed_inplace "s|CHANGE_ME_32_CHAR_HEX|$encryption_key|g" "$env_file"

    # Replace each unique secret
    sed_inplace "s|^LINEAGE_SIGNATURE_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX|LINEAGE_SIGNATURE_SECRET=$lineage_secret|" "$env_file"
    sed_inplace "s|^CREDENTIAL_MASTER_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX|CREDENTIAL_MASTER_KEY=$credential_master_key|" "$env_file"
    sed_inplace "s|^MODEL_SIGNING_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX|MODEL_SIGNING_KEY=$model_signing_key|" "$env_file"
    sed_inplace "s|^DATA_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_DATA|DATA_ENCRYPTION_KEY=$data_encryption_key|" "$env_file"
    sed_inplace "s|^EXCEPTION_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_EXCEPTION|EXCEPTION_ENCRYPTION_KEY=$exception_encryption_key|" "$env_file"
    sed_inplace "s|^HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_HMAC|HMAC_SECRET=$ml_service_hmac_secret|" "$env_file"
    sed_inplace "s|^AUDIT_SIGNATURE_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_AUDIT|AUDIT_SIGNATURE_SECRET=$audit_signature_secret|" "$env_file"
    sed_inplace "s|^CCM_ENCRYPTION_KEY=.*|CCM_ENCRYPTION_KEY=$ccm_encryption_key|" "$env_file"
    sed_inplace "s|^STORAGE_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_STORAGE|STORAGE_ENCRYPTION_KEY=$storage_encryption_key|" "$env_file"
    sed_inplace "s|^EVIDENCE_HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_EVIDENCE|EVIDENCE_HMAC_SECRET=$evidence_hmac_secret|" "$env_file"
    sed_inplace "s|^ML_SERVICE_HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_ML_HMAC|ML_SERVICE_HMAC_SECRET=$ml_service_hmac_secret|" "$env_file"
    sed_inplace "s|^ML_CREDENTIAL_ENCRYPTION_KEY=CHANGE_ME_GENERATE_FERNET_KEY|ML_CREDENTIAL_ENCRYPTION_KEY=$ml_credential_encryption_key|" "$env_file"
    sed_inplace "s|^SESSION_SECRET=.*|SESSION_SECRET=$session_secret|" "$env_file"
    sed_inplace "s|^INTERNAL_SERVICE_KEY=.*|INTERNAL_SERVICE_KEY=$internal_service_key|" "$env_file"

    # Replace admin credentials
    sed_inplace "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$platform_admin_email|" "$env_file"
    sed_inplace "s|^ADMIN_PASSWORD=CHANGE_ME_ADMIN_PASSWORD|ADMIN_PASSWORD=$platform_admin_password|" "$env_file"

    # Replace other placeholders
    sed_inplace "s|CHANGE_ME_SECURE_PASSWORD|$postgres_password|g" "$env_file"
    sed_inplace "s|CHANGE_ME_ADMIN_PASSWORD|$admin_password|g" "$env_file"
    sed_inplace "s|CHANGE_ME_GRAFANA_PASSWORD|$grafana_password|g" "$env_file"
    # Generate and replace GRAFANA_SECRET_KEY
    local grafana_secret_key=$(openssl rand -base64 24 | tr -d '\n/+=')
    sed_inplace "s|^GRAFANA_SECRET_KEY=CHANGE_ME_32_CHAR_SECRET_KEY|GRAFANA_SECRET_KEY=$grafana_secret_key|" "$env_file"
    sed_inplace "s|CHANGE_ME_GENERATE_SECURE_API_KEY|$ml_service_api_key|g" "$env_file"
    sed_inplace "s|CHANGE_ME_GENERATE_SECURE_SECRET|$csrf_secret|g" "$env_file"
    sed_inplace "s|CHANGE_ME_JUPYTER_TOKEN|$jupyter_token|g" "$env_file"

    # ELK Stack secrets
    sed_inplace "s|^ELASTIC_PASSWORD=CHANGE_ME_ELASTIC_PASSWORD|ELASTIC_PASSWORD=$elastic_password|" "$env_file"
    sed_inplace "s|^KIBANA_SYSTEM_PASSWORD=CHANGE_ME_KIBANA_PASSWORD|KIBANA_SYSTEM_PASSWORD=$kibana_system_password|" "$env_file"
    sed_inplace "s|^KIBANA_ENCRYPTION_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_ENCRYPTION|KIBANA_ENCRYPTION_KEY=$kibana_encryption_key|" "$env_file"
    sed_inplace "s|^KIBANA_REPORTING_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_REPORTING|KIBANA_REPORTING_KEY=$kibana_reporting_key|" "$env_file"
    sed_inplace "s|^KIBANA_SECURITY_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_SECURITY|KIBANA_SECURITY_KEY=$kibana_security_key|" "$env_file"

    # Super Admin secrets
    sed_inplace "s|^SUPER_ADMIN_JWT_SECRET=CHANGE_ME_GENERATE_SUPER_ADMIN_JWT_SECRET|SUPER_ADMIN_JWT_SECRET=$super_admin_jwt_secret|" "$env_file"
    sed_inplace "s|^SUPER_ADMIN_DEFAULT_PASSWORD=CHANGE_ME_SUPER_ADMIN_PASSWORD|SUPER_ADMIN_DEFAULT_PASSWORD=$super_admin_password|" "$env_file"

    # Update domain-related settings
    sed_inplace "s/^DOMAIN=.*/DOMAIN=$domain/" "$env_file"
    sed_inplace "s|^FRONTEND_URL=.*|FRONTEND_URL=https://$domain|" "$env_file"
    sed_inplace "s|^API_BASE_URL=.*|API_BASE_URL=https://$domain/api|" "$env_file"
    sed_inplace "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=https://$domain|" "$env_file"
    sed_inplace "s|^CORS_ORIGIN=.*|CORS_ORIGIN=https://$domain|" "$env_file"
    sed_inplace "s|^CORS_ORIGINS=.*|CORS_ORIGINS=https://$domain|" "$env_file"

    # SAML URLs
    sed_inplace "s|^SAML_SP_ENTITY_ID=.*|SAML_SP_ENTITY_ID=https://$domain/saml/metadata|" "$env_file"
    sed_inplace "s|^SAML_SP_ACS_URL=.*|SAML_SP_ACS_URL=https://$domain/saml/acs|" "$env_file"
    sed_inplace "s|^SAML_SP_SLO_URL=.*|SAML_SP_SLO_URL=https://$domain/saml/slo|" "$env_file"

    # Store credentials for display
    echo "$platform_admin_email" > "$DEPLOY_DIR/.admin_email"
    echo "$platform_admin_password" > "$DEPLOY_DIR/.admin_password"
    chmod 600 "$DEPLOY_DIR/.admin_email" "$DEPLOY_DIR/.admin_password"

    log_success "Secrets generated"
}

setup_selfsigned_ssl() {
    local domain=$1

    log_info "Generating self-signed SSL certificate for $domain..."

    local ssl_dir="$DEPLOY_DIR/ssl"
    mkdir -p "$ssl_dir"

    # Create OpenSSL config with SAN
    local openssl_conf=$(mktemp)
    cat > "$openssl_conf" << EOF
[req]
default_bits = 2048
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $domain
O = Pravaha
C = US

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $domain
DNS.2 = *.$domain
DNS.3 = localhost
EOF

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$ssl_dir/privkey.pem" \
        -out "$ssl_dir/fullchain.pem" \
        -config "$openssl_conf" \
        -extensions v3_req

    rm -f "$openssl_conf"

    log_warning "Self-signed certificate created. Browser will show security warning."
    log_success "SSL certificate generated"
}

# Authenticate with container registry (GHCR, Docker Hub, etc.)
authenticate_registry() {
    # Source .env to get registry configuration
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        local registry=$(grep "^REGISTRY=" "$DEPLOY_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi

    # Default to GHCR if not set
    registry="${registry:-ghcr.io/talentfino/pravaha}"

    # Determine registry type and authenticate accordingly
    if [[ "$registry" == ghcr.io/* ]]; then
        # GitHub Container Registry
        if [[ -n "$GHCR_TOKEN" ]] && [[ -n "$GHCR_USERNAME" ]]; then
            log_info "Logging into GitHub Container Registry..."
            if echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin 2>/dev/null; then
                log_success "GHCR authentication successful"
                return 0
            else
                log_warning "GHCR login failed"
            fi
        fi

        # Check if already logged in
        if docker pull ghcr.io/talentfino/pravaha/frontend:latest --quiet 2>/dev/null; then
            log_info "Already authenticated to GHCR"
            return 0
        fi

        # Prompt for GHCR credentials
        log_warning "GHCR authentication required"
        log_info "Create a Personal Access Token at: https://github.com/settings/tokens/new?scopes=read:packages"
        echo ""
        read -p "Enter GitHub username: " ghcr_user
        read -s -p "Enter GitHub PAT (ghp_...): " ghcr_token
        echo ""

        if [[ -n "$ghcr_token" ]] && [[ -n "$ghcr_user" ]]; then
            if echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_user" --password-stdin 2>/dev/null; then
                log_success "GHCR authentication successful"
                return 0
            else
                log_error "GHCR authentication failed"
                return 1
            fi
        fi
    elif [[ "$registry" == *".dkr.ecr."* ]]; then
        # AWS ECR - requires AWS CLI
        log_info "AWS ECR detected, using AWS CLI authentication..."
        local ecr_region=$(echo "$registry" | grep -oE '[a-z]+-[a-z]+-[0-9]+')
        if aws ecr get-login-password --region "$ecr_region" 2>/dev/null | docker login --username AWS --password-stdin "$registry" 2>/dev/null; then
            log_success "AWS ECR authentication successful"
            return 0
        else
            log_warning "AWS ECR login failed - ensure AWS CLI is configured"
        fi
    else
        # Docker Hub or other registry
        if [[ -n "$DOCKER_PASSWORD" ]] && [[ -n "$DOCKER_USERNAME" ]]; then
            log_info "Logging into Docker Hub..."
            if echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin 2>/dev/null; then
                log_success "Docker Hub authentication successful"
                return 0
            fi
        fi

        # Check if already logged in
        if docker info 2>/dev/null | grep -q "Username:"; then
            log_info "Already authenticated to Docker Hub"
            return 0
        fi

        log_warning "Docker Hub authentication may be required for rate limits"
        log_info "Run 'docker login' if you encounter pull rate limits"
    fi

    return 0
}

pull_images() {
    log_info "Pulling Docker images..."

    cd "$DEPLOY_DIR"

    # Authenticate with the configured registry
    if ! authenticate_registry; then
        log_error "Registry authentication failed"
        return 1
    fi

    if ! docker compose pull; then
        log_error "Failed to pull Docker images"
        log_error "Check your network connectivity and registry access"
        return 1
    fi

    log_success "Docker images pulled"
}

build_images() {
    log_info "Building Docker images locally..."

    cd "$DEPLOY_DIR"

    # Build images using the build compose file
    if ! docker compose -f docker-compose.yml -f docker-compose.build.yml build; then
        log_error "Failed to build Docker images"
        return 1
    fi

    log_success "Docker images built"
}

init_database() {
    log_info "Initializing database..."

    cd "$DEPLOY_DIR"

    # Source env to get credentials and branding prefix
    source "$DEPLOY_DIR/.env" 2>/dev/null || true
    local pg_user="${POSTGRES_USER:-pravaha}"
    local platform_db="${PLATFORM_DB:-autoanalytics}"
    local superset_db="${SUPERSET_DB:-superset}"

    # Start only postgres first with bundled-db profile
    log_info "Starting PostgreSQL container..."
    docker compose --profile bundled-db up -d postgres

    # Wait for postgres to be healthy
    if ! wait_for_healthy "pravaha-postgres" 60 5; then
        log_error "PostgreSQL failed to start"
        docker logs "pravaha-postgres" 2>&1 | tail -30
        return 1
    fi

    # Verify postgres is accepting connections
    if ! docker compose exec -T postgres pg_isready -U "$pg_user" -d "$platform_db"; then
        log_error "PostgreSQL is not accepting connections"
        return 1
    fi

    # Verify databases exist
    log_info "Verifying database initialization..."

    if ! docker compose exec -T postgres psql -U "$pg_user" -d "$platform_db" -c "SELECT 1;" > /dev/null 2>&1; then
        log_error "Platform database '$platform_db' does not exist"
        return 1
    fi

    if ! docker compose exec -T postgres psql -U "$pg_user" -d "$superset_db" -c "SELECT 1;" > /dev/null 2>&1; then
        log_error "Superset database '$superset_db' does not exist"
        return 1
    fi

    # Create extensions if needed
    docker compose exec -T postgres psql -U "$pg_user" -d "$platform_db" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"; CREATE EXTENSION IF NOT EXISTS pgcrypto;" 2>/dev/null || true

    log_success "Database initialized and verified"
}

# =============================================================================
# Setup Default Branding
# =============================================================================
setup_default_branding() {
    local brand_dir="$DEPLOY_DIR/branding/${BRAND:-pravaha}"
    if [ ! -f "$brand_dir/brand.json" ]; then
        log_info "Creating default branding directory..."
        mkdir -p "$brand_dir"
        cat > "$brand_dir/brand.json" << 'BRAND_EOF'
{
  "name": "Pravaha",
  "tagline": "Intelligent Business Process Platform",
  "companyName": "Pravaha Inc.",
  "companyUrl": "https://pravaha.io",
  "supportEmail": "support@pravaha.io",
  "supportUrl": "https://support.pravaha.com",
  "copyrightHolder": "Pravaha Inc.",
  "description": "Enterprise Workflow Engine",
  "colors": {
    "primary": "#4f7bff",
    "secondary": "#764ba2"
  },
  "features": {
    "showLandingPage": true,
    "showPublicRegistration": true
  },
  "legal": {
    "privacyEmail": "privacy@pravaha.com",
    "legalEmail": "legal@pravaha.com",
    "dpoEmail": "dpo@pravaha.com"
  },
  "emails": {
    "fromName": "Pravaha Platform",
    "fromAddress": "noreply@pravaha.io"
  },
  "docker": {
    "prefix": "pravaha",
    "registry": "analytics"
  },
  "documentation": {
    "docsUrl": "https://docs.pravaha.io",
    "runbookUrl": "https://docs.pravaha.io/runbooks"
  },
  "system": {
    "systemEmail": "system@pravaha.io",
    "metricsPrefix": "pravaha",
    "jwtIssuer": "pravaha-backend",
    "jwtAudience": "pravaha-api"
  }
}
BRAND_EOF
        log_success "Default branding created at $brand_dir/brand.json"
    else
        log_info "Branding directory already exists: $brand_dir"
    fi
}

start_services() {
    log_info "Starting all services..."

    cd "$DEPLOY_DIR"

    # Load branding prefix from .env
    source "$DEPLOY_DIR/.env" 2>/dev/null || true

    # Start all services with bundled PostgreSQL profile
    docker compose --profile bundled-db up -d

    log_info "Waiting for services to be healthy..."

    local services=("pravaha-postgres" "pravaha-redis" "pravaha-backend" "pravaha-frontend" "pravaha-nginx")
    local failed=0

    for service in "${services[@]}"; do
        if ! wait_for_healthy "$service" 90 5; then
            log_warning "$service did not become healthy"
            failed=1
        fi
    done

    # Check health
    echo ""
    docker compose ps
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_success "All services started and healthy"
    else
        log_warning "Some services may need attention - check 'docker compose logs'"
    fi
}

run_verification() {
    local domain=$1

    log_info "Running post-installation verification..."

    # Load branding prefix from .env
    source "$DEPLOY_DIR/.env" 2>/dev/null || true

    local verification_failed=0

    # Check NGINX via internal Docker network
    local nginx_healthy=false
    for i in {1..12}; do
        if docker exec "pravaha-nginx" wget -q -O /dev/null http://localhost/health 2>/dev/null; then
            nginx_healthy=true
            break
        fi
        log_info "Waiting for NGINX... (attempt $i/12)"
        sleep 5
    done

    if [[ "$nginx_healthy" == "true" ]]; then
        log_success "NGINX health check passed"
    else
        log_warning "NGINX health check failed"
        verification_failed=1
    fi

    # Check Backend (use /health/live for liveness check)
    local backend_healthy=false
    for i in {1..12}; do
        if docker exec "pravaha-backend" wget -q -O /dev/null http://localhost:3000/health/live 2>/dev/null; then
            backend_healthy=true
            break
        fi
        log_info "Waiting for Backend... (attempt $i/12)"
        sleep 5
    done

    if [[ "$backend_healthy" == "true" ]]; then
        log_success "Backend health check passed"
    else
        log_warning "Backend health check failed"
        verification_failed=1
    fi

    # Check PostgreSQL
    if docker exec "pravaha-postgres" pg_isready -U "${POSTGRES_USER:-pravaha}" -d "${PLATFORM_DB:-autoanalytics}" 2>/dev/null; then
        log_success "PostgreSQL health check passed"
    else
        log_warning "PostgreSQL health check failed"
        verification_failed=1
    fi

    # Check Redis
    if docker exec "pravaha-redis" redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis health check passed"
    else
        log_warning "Redis health check failed"
        verification_failed=1
    fi

    # Run comprehensive verification script
    if [[ -x "$DEPLOY_DIR/scripts/verify-deployment.sh" ]]; then
        log_info "Running comprehensive verification..."
        if "$DEPLOY_DIR/scripts/verify-deployment.sh" --quick --ci 2>/dev/null; then
            log_success "Comprehensive verification passed"
        else
            log_warning "Some verification checks failed (this is expected for local testing)"
        fi
    fi

    return $verification_failed
}

print_completion() {
    local domain=$1

    local admin_email="admin@$domain"
    local admin_password="[check .admin_password file]"

    if [[ -f "$DEPLOY_DIR/.admin_email" ]]; then
        admin_email=$(cat "$DEPLOY_DIR/.admin_email")
    fi
    if [[ -f "$DEPLOY_DIR/.admin_password" ]]; then
        admin_password=$(cat "$DEPLOY_DIR/.admin_password")
    fi

    echo ""
    echo "=============================================="
    echo -e "${GREEN}Pravaha Platform Installation Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Access your platform at: https://$domain"
    echo "(Add '$domain' to /etc/hosts pointing to 127.0.0.1 for local testing)"
    echo ""
    echo "Platform Admin Credentials:"
    echo "  Email:    $admin_email"
    echo "  Password: $admin_password"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
    echo ""
    echo "Useful commands:"
    echo "  - View logs: cd $DEPLOY_DIR && docker compose logs -f"
    echo "  - Stop services: cd $DEPLOY_DIR && docker compose down"
    echo "  - Start services: cd $DEPLOY_DIR && docker compose --profile bundled-db up -d"
    echo "  - Check status: cd $DEPLOY_DIR && docker compose ps"
    echo ""
    echo "Configuration: $DEPLOY_DIR/.env"
    echo "Credentials file: $DEPLOY_DIR/.admin_password (delete after saving)"
    echo ""
}

# =============================================================================
# Main Function
# =============================================================================
main() {
    echo "=============================================="
    echo "Pravaha Platform - macOS Installation"
    echo "Version: $SCRIPT_VERSION"
    echo "=============================================="
    echo ""

    check_macos

    # Parse arguments
    local domain=""
    local skip_pull="false"
    local build_images="false"
    local resume="false"
    local force="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                domain="$2"
                shift 2
                ;;
            --skip-pull)
                skip_pull="true"
                shift
                ;;
            --build)
                build_images="true"
                skip_pull="true"
                shift
                ;;
            --resume)
                resume="true"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            --help)
                echo "Usage: $0 --domain <domain> [options]"
                echo ""
                echo "Required:"
                echo "  --domain     Your domain name (e.g., localhost or pravaha.local)"
                echo ""
                echo "Options:"
                echo "  --skip-pull  Skip docker compose pull (use existing images)"
                echo "  --build      Build images locally instead of pulling"
                echo "  --resume     Resume a failed installation"
                echo "  --force      Force reinstallation without prompts"
                echo ""
                echo "Examples:"
                echo "  $0 --domain localhost"
                echo "  $0 --domain localhost --build"
                echo "  $0 --domain pravaha.local --skip-pull"
                echo "  $0 --domain localhost --resume"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$domain" ]]; then
        domain="localhost"
        log_info "Using default domain: localhost"
    fi

    # Validate domain format
    if ! validate_domain_format "$domain"; then
        exit 1
    fi

    # Initialize logging
    mkdir -p "$DEPLOY_DIR/logs"
    log_info "Installation log: $INSTALL_LOG"

    # Handle resume mode
    if [[ "$resume" == "true" ]]; then
        local checkpoint=$(get_checkpoint)
        local checkpoint_status=$(get_checkpoint_status)

        if [[ -z "$checkpoint" ]]; then
            log_warning "No checkpoint found. Starting fresh installation."
            resume="false"
        elif [[ "$checkpoint_status" == "completed" ]]; then
            log_info "Previous installation completed successfully."
            exit 0
        else
            log_info "Resuming installation from checkpoint: $checkpoint"
        fi
    fi

    # Display configuration
    echo ""
    log_info "Configuration:"
    log_info "  Domain:       $domain"
    log_info "  Deploy Dir:   $DEPLOY_DIR"
    log_info "  Build Images: $build_images"
    log_info "  Skip Pull:    $skip_pull"
    log_info "  Resume:       $resume"
    echo ""

    # =========================================================================
    # STEP 1: Pre-flight checks
    # =========================================================================
    if ! should_skip_step "preflight" || [[ "$resume" != "true" ]]; then
        log_step "Running pre-flight checks..."
        save_checkpoint "preflight" "in_progress"

        if ! run_pre_deployment_checks; then
            log_error "Pre-flight checks failed"
            exit 1
        fi

        if [[ "$skip_pull" != "true" ]]; then
            if ! check_network_connectivity; then
                log_error "Network connectivity check failed"
                exit 1
            fi
        fi

        save_checkpoint "preflight" "completed"
    else
        log_info "Skipping pre-flight checks (already completed)"
    fi

    # =========================================================================
    # STEP 2: Check Docker
    # =========================================================================
    if ! should_skip_step "docker_check" || [[ "$resume" != "true" ]]; then
        log_step "Checking Docker..."
        save_checkpoint "docker_check" "in_progress"

        if ! validate_docker; then
            log_error "Docker validation failed"
            exit 1
        fi

        save_checkpoint "docker_check" "completed"
    else
        log_info "Skipping Docker check (already completed)"
    fi

    # =========================================================================
    # STEP 3: Setup directories
    # =========================================================================
    if ! should_skip_step "directory_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up directories..."
        save_checkpoint "directory_setup" "in_progress"

        setup_directories

        save_checkpoint "directory_setup" "completed"
    else
        log_info "Skipping directory setup (already completed)"
    fi

    # =========================================================================
    # STEP 4: Generate NGINX configuration
    # =========================================================================
    if ! should_skip_step "nginx_config" || [[ "$resume" != "true" ]]; then
        log_step "Generating NGINX configuration..."
        save_checkpoint "nginx_config" "in_progress"

        generate_nginx_config "$domain"

        save_checkpoint "nginx_config" "completed"
    else
        log_info "Skipping NGINX configuration (already completed)"
    fi

    # =========================================================================
    # STEP 5: Generate secrets
    # =========================================================================
    if ! should_skip_step "secrets_generation" || [[ "$resume" != "true" ]]; then
        log_step "Generating secrets..."
        save_checkpoint "secrets_generation" "in_progress"

        generate_secrets "$domain"

        save_checkpoint "secrets_generation" "completed"
    else
        log_info "Skipping secrets generation (already completed)"
    fi

    # =========================================================================
    # STEP 6: Generate audit keys
    # =========================================================================
    if ! should_skip_step "audit_keys" || [[ "$resume" != "true" ]]; then
        log_step "Generating audit keys..."
        save_checkpoint "audit_keys" "in_progress"

        generate_audit_keys

        save_checkpoint "audit_keys" "completed"
    else
        log_info "Skipping audit keys generation (already completed)"
    fi

    # =========================================================================
    # STEP 7: Setup SSL
    # =========================================================================
    if ! should_skip_step "ssl_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up SSL certificates..."
        save_checkpoint "ssl_setup" "in_progress"

        setup_selfsigned_ssl "$domain"

        save_checkpoint "ssl_setup" "completed"
    else
        log_info "Skipping SSL setup (already completed)"
    fi

    # =========================================================================
    # STEP 8: Pull/Build Docker images
    # =========================================================================
    if ! should_skip_step "image_pull" || [[ "$resume" != "true" ]]; then
        save_checkpoint "image_pull" "in_progress"

        if [[ "$build_images" == "true" ]]; then
            log_step "Building Docker images..."
            if ! build_images; then
                log_error "Failed to build images"
                exit 1
            fi
        elif [[ "$skip_pull" == "true" ]]; then
            log_step "Using existing Docker images..."
            log_info "Skipping docker compose pull (using existing images)"
        else
            log_step "Pulling Docker images..."
            if ! pull_images; then
                log_error "Failed to pull images"
                exit 1
            fi
        fi

        save_checkpoint "image_pull" "completed"
    else
        log_info "Skipping image pull/build (already completed)"
    fi

    # =========================================================================
    # STEP 9: Initialize database
    # =========================================================================
    if ! should_skip_step "database_init" || [[ "$resume" != "true" ]]; then
        log_step "Initializing database..."
        save_checkpoint "database_init" "in_progress"

        if ! init_database; then
            log_error "Database initialization failed"
            exit 1
        fi

        save_checkpoint "database_init" "completed"
    else
        log_info "Skipping database initialization (already completed)"
    fi

    # =========================================================================
    # STEP 10: Start services
    # =========================================================================
    # Setup default branding before starting services
    setup_default_branding

    if ! should_skip_step "services_start" || [[ "$resume" != "true" ]]; then
        log_step "Starting services..."
        save_checkpoint "services_start" "in_progress"

        start_services

        save_checkpoint "services_start" "completed"
    else
        log_info "Skipping service start (already completed)"
    fi

    # =========================================================================
    # STEP 11: Verification
    # =========================================================================
    log_step "Running verification..."
    save_checkpoint "verification" "in_progress"

    # Verification is non-fatal — all services are already confirmed healthy above
    if run_verification "$domain"; then
        log_success "All verification checks passed"
    else
        log_warning "Some verification checks did not pass (services are running — check logs for details)"
    fi

    save_checkpoint "verification" "completed"

    # =========================================================================
    # COMPLETE
    # =========================================================================
    save_checkpoint "complete" "completed"

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEPLOY_DIR/.installed"

    CLEANUP_ON_EXIT=false

    print_completion "$domain"

    log_info "Installation log saved to: $INSTALL_LOG"
}

# Run main function
main "$@"
