#!/bin/bash
# =============================================================================
# Pravaha Platform - Single Server Installation Script
# Ubuntu 22.04/24.04 LTS (tested on 24.04 Noble)
# Enterprise-Grade Production Deployment
# =============================================================================
#
# Features:
#   - Pre-flight validation (disk, memory, network, ports)
#   - Retry logic with exponential backoff
#   - Checkpoint/resume capability
#   - Rollback on failure
#   - Installation audit logging
#   - Idempotency (safe to re-run)
#
# =============================================================================

set -e

# =============================================================================
# Global Configuration
# =============================================================================
SCRIPT_VERSION="2.0.0"
DEPLOY_DIR="/opt/pravaha"
STATE_FILE=""  # Set after deploy_dir is determined
INSTALL_LOG=""  # Set after deploy_dir is determined
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

    [[ -z "$STATE_FILE" ]] && return

    # Create state directory if needed
    mkdir -p "$(dirname "$STATE_FILE")"

    # Save checkpoint
    cat > "$STATE_FILE" << EOF
{
    "version": "$SCRIPT_VERSION",
    "step": "$step",
    "status": "$status",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "domain": "${domain:-}",
    "ssl_type": "${ssl_type:-}",
    "installer": "${SUDO_USER:-root}",
    "hostname": "$(hostname)"
}
EOF
    chmod 600 "$STATE_FILE"
}

get_checkpoint() {
    [[ -z "$STATE_FILE" ]] && echo "" && return
    [[ ! -f "$STATE_FILE" ]] && echo "" && return

    local step=$(grep -o '"step": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
    echo "$step"
}

get_checkpoint_status() {
    [[ -z "$STATE_FILE" ]] && echo "" && return
    [[ ! -f "$STATE_FILE" ]] && echo "" && return

    local status=$(grep -o '"status": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
    echo "$status"
}

should_skip_step() {
    local step=$1
    local checkpoint=$(get_checkpoint)
    local status=$(get_checkpoint_status)

    # Define step order
    local -a steps=(
        "preflight"
        "docker_install"
        "tools_install"
        "firewall_setup"
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

        # Save failed state for resume
        save_checkpoint "$CURRENT_STEP" "failed"

        echo ""
        log_warning "To resume installation from this point, run:"
        log_warning "  sudo $0 --domain $domain --resume"
        echo ""
        log_warning "To view installation log:"
        log_warning "  cat $INSTALL_LOG"
        echo ""
        log_warning "To rollback partial installation:"
        log_warning "  sudo $DEPLOY_DIR/scripts/rollback.sh --checkpoint pre_install"
    fi
}

trap cleanup_on_failure EXIT

# =============================================================================
# Retry Logic with Exponential Backoff
# =============================================================================
retry_with_backoff() {
    local max_attempts=${1:-5}
    local base_delay=${2:-2}
    local max_delay=${3:-60}
    shift 3
    local cmd="$@"

    local attempt=1
    local delay=$base_delay

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt of $max_attempts: $cmd"

        if eval "$cmd"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Command failed, retrying in ${delay}s..."
            sleep $delay
            # Exponential backoff with cap
            delay=$((delay * 2))
            [[ $delay -gt $max_delay ]] && delay=$max_delay
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# =============================================================================
# Network Connectivity Checks
# =============================================================================
check_network_connectivity() {
    log_info "Checking network connectivity..."

    # Check DNS resolution
    if ! nslookup google.com &>/dev/null && ! host google.com &>/dev/null; then
        log_error "DNS resolution failed. Check your network configuration."
        log_error "Try: cat /etc/resolv.conf"
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
            log_warning "Cannot reach ghcr.io directly. Checking API..."
            if ! curl -s --max-time 10 --head https://ghcr.io &>/dev/null; then
                log_error "Cannot reach GitHub Container Registry (ghcr.io)."
                log_error "Check firewall settings or use --skip-pull with pre-loaded images."
                log_error ""
                log_error "Note: GHCR requires authentication for private images."
                log_error "Set credentials before running install.sh:"
                log_error "  export GHCR_USERNAME=your-github-username"
                log_error "  export GHCR_TOKEN=ghp_your-personal-access-token"
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
            log_error "Check AWS credentials and firewall settings."
            return 1
        fi
        log_success "AWS ECR is reachable"
    else
        # Docker Hub (default or explicit)
        log_info "Checking Docker Hub connectivity..."
        if ! curl -s --max-time 10 --head https://registry-1.docker.io/v2/ &>/dev/null; then
            log_warning "Cannot reach Docker Hub. Checking alternative..."
            if ! curl -s --max-time 10 --head https://hub.docker.com &>/dev/null; then
                log_error "Cannot reach Docker Hub. Image pull will fail."
                log_error "Check firewall settings or use --skip-pull with pre-loaded images."
                return 1
            fi
        fi
        log_success "Docker Hub is reachable"
    fi

    # Check if behind proxy (informational)
    if [[ -n "${http_proxy:-}" ]] || [[ -n "${HTTP_PROXY:-}" ]]; then
        log_info "HTTP proxy detected: ${http_proxy:-$HTTP_PROXY}"
    fi
    if [[ -n "${https_proxy:-}" ]] || [[ -n "${HTTPS_PROXY:-}" ]]; then
        log_info "HTTPS proxy detected: ${https_proxy:-$HTTPS_PROXY}"
    fi

    return 0
}

check_domain_dns() {
    local domain=$1

    log_info "Checking DNS resolution for $domain..."

    if nslookup "$domain" &>/dev/null || host "$domain" &>/dev/null; then
        log_success "Domain $domain resolves correctly"
        return 0
    else
        log_warning "Domain $domain does not resolve yet"
        log_warning "Ensure DNS is configured before accessing the platform"
        return 0  # Non-fatal - domain may be configured later
    fi
}

# =============================================================================
# Domain Validation
# =============================================================================
validate_domain_format() {
    local domain=$1

    # Basic domain format validation
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        log_error "Domain must be a valid hostname (e.g., analytics.example.com)"
        return 1
    fi

    # Check for dangerous characters that could break sed/config
    if [[ "$domain" == *'|'* || "$domain" == *'&'* || "$domain" == *';'* || "$domain" == *'$'* || "$domain" == *'`'* || "$domain" == *'\'* ]]; then
        log_error "Domain contains invalid characters: $domain"
        return 1
    fi

    log_success "Domain format validated: $domain"
    return 0
}

# =============================================================================
# Idempotency Check
# =============================================================================
check_existing_installation() {
    local deploy_dir=$1
    local force=${2:-false}

    if [[ -f "$deploy_dir/.installed" ]]; then
        log_warning "Pravaha Platform is already installed at $deploy_dir"
        log_warning "Installation completed on: $(cat "$deploy_dir/.installed")"

        if [[ "$force" != "true" ]]; then
            echo ""
            read -p "Do you want to reinstall? This will preserve existing data. (y/N): " reinstall
            if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
                log_info "Installation cancelled. Use --force to skip this check."
                exit 0
            fi
        fi

        # Create backup checkpoint before reinstall
        if [[ -d "$deploy_dir/.checkpoint" ]]; then
            local checkpoint_name="pre_reinstall_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$deploy_dir/.checkpoint/$checkpoint_name"
            cp "$deploy_dir/.env" "$deploy_dir/.checkpoint/$checkpoint_name/" 2>/dev/null || true
            cp "$deploy_dir/docker-compose.yml" "$deploy_dir/.checkpoint/$checkpoint_name/" 2>/dev/null || true
            log_info "Created checkpoint: $checkpoint_name"
        fi
    fi

    # Check for existing containers that might conflict
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^pravaha-"; then
        log_warning "Found existing Pravaha containers:"
        docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | grep "pravaha-" || true

        if [[ "$force" != "true" ]]; then
            echo ""
            read -p "Stop and remove existing containers? (y/N): " remove_containers
            if [[ "$remove_containers" =~ ^[Yy]$ ]]; then
                log_info "Stopping existing containers..."
                cd "$deploy_dir" 2>/dev/null && docker compose down 2>/dev/null || true
            fi
        fi
    fi
}

# =============================================================================
# Installation Audit Logging
# =============================================================================
init_audit_log() {
    local deploy_dir=$1

    mkdir -p "$deploy_dir/logs"
    INSTALL_LOG="$deploy_dir/logs/install_$(date +%Y%m%d_%H%M%S).log"
    STATE_FILE="$deploy_dir/.install_state"

    # Create secure log file
    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"

    # Log installation metadata
    cat >> "$INSTALL_LOG" << EOF
================================================================================
PRAVAHA PLATFORM INSTALLATION LOG
================================================================================
Timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
Installer:    ${SUDO_USER:-root}
Hostname:     $(hostname)
OS:           $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)
Script:       $0
Version:      $SCRIPT_VERSION
Arguments:    $@
Working Dir:  $(pwd)
================================================================================

EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# =============================================================================
# Pre-Deployment Validation Functions
# =============================================================================

# Validate available disk space (minimum 50GB)
validate_disk_space() {
    local min_gb=${1:-50}
    local deploy_dir=${2:-/opt/pravaha}
    local mount_point=$(df -P "$deploy_dir" 2>/dev/null | tail -1 | awk '{print $1}' || echo "/")

    log_info "Checking disk space (minimum ${min_gb}GB required)..."

    local available_kb=$(df -P "$deploy_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $min_gb ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available, ${min_gb}GB required"
        return 1
    fi

    log_success "Disk space check passed: ${available_gb}GB available"
    return 0
}

# Validate available memory (minimum 16GB)
validate_memory() {
    local min_gb=${1:-16}

    log_info "Checking available memory (minimum ${min_gb}GB required)..."

    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_gb=$((total_kb / 1024 / 1024))

    if [[ $total_gb -lt $min_gb ]]; then
        log_warning "Memory below recommended: ${total_gb}GB available, ${min_gb}GB recommended"
        log_warning "Services may run slowly or fail under load"
    else
        log_success "Memory check passed: ${total_gb}GB available"
    fi
    return 0
}

# Validate Docker version (minimum 24.0)
validate_docker_version() {
    local min_version="24.0"

    if ! command -v docker &> /dev/null; then
        log_info "Docker not installed yet - will be installed"
        return 0
    fi

    log_info "Checking Docker version (minimum ${min_version} required)..."

    local docker_version=$(docker --version 2>/dev/null | sed -n 's/.*version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)

    if [[ -z "$docker_version" ]]; then
        log_warning "Could not determine Docker version"
        return 0
    fi

    # Simple version comparison
    local min_major=$(echo $min_version | cut -d. -f1)
    local current_major=$(echo $docker_version | cut -d. -f1)

    if [[ $current_major -lt $min_major ]]; then
        log_error "Docker version too old: ${docker_version}, minimum ${min_version} required"
        return 1
    fi

    log_success "Docker version check passed: ${docker_version}"
    return 0
}

# Validate Docker Compose version (require v2)
validate_compose_version() {
    if ! command -v docker &> /dev/null; then
        log_info "Docker not installed yet - Docker Compose will be installed with Docker"
        return 0
    fi

    log_info "Checking Docker Compose version (v2+ required)..."

    local compose_version
    compose_version=$(docker compose version --short 2>/dev/null || echo "0.0.0")

    if [[ "$compose_version" == "0.0.0" ]]; then
        log_error "Docker Compose v2 not found. Please install Docker Compose v2."
        log_info "Install: https://docs.docker.com/compose/install/"
        return 1
    fi

    local major_version=$(echo "$compose_version" | cut -d. -f1)
    if [[ "$major_version" -lt 2 ]]; then
        log_error "Docker Compose v2+ required. Found: $compose_version"
        log_info "Upgrade: https://docs.docker.com/compose/install/"
        return 1
    fi

    log_success "Docker Compose version: $compose_version"
    return 0
}

# Validate required ports are available (80, 443, 5432, 6379)
validate_ports() {
    local ports=(80 443 5432 6379)
    local blocked_ports=()

    log_info "Checking if required ports are available..."

    for port in "${ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            blocked_ports+=($port)
        fi
    done

    if [[ ${#blocked_ports[@]} -gt 0 ]]; then
        log_warning "The following ports are in use: ${blocked_ports[*]}"
        log_warning "These services may conflict with the platform"
        log_info "Note: Docker services will bind to these ports, existing services may need to be stopped"
    else
        log_success "All required ports are available"
    fi
    return 0
}

# Validate .env file has no CHANGE_ME placeholders
validate_env_placeholders() {
    local env_file=$1

    if [[ ! -f "$env_file" ]]; then
        return 0  # File doesn't exist yet, will be generated
    fi

    log_info "Validating environment configuration..."

    local placeholders=$(grep -c "CHANGE_ME" "$env_file" 2>/dev/null || echo "0")

    if [[ $placeholders -gt 0 ]]; then
        log_warning "Found $placeholders CHANGE_ME placeholders in $env_file"
        log_warning "These will be auto-generated during installation"
    fi
    return 0
}

# Validate SSL certificates if they exist
validate_ssl_certificates() {
    local ssl_dir=$1

    local fullchain="$ssl_dir/fullchain.pem"
    local privkey="$ssl_dir/privkey.pem"

    if [[ ! -f "$fullchain" ]] || [[ ! -f "$privkey" ]]; then
        return 0  # Certificates don't exist yet
    fi

    log_info "Validating SSL certificates..."

    # Check if certificate is expired or not yet valid
    if ! openssl x509 -checkend 0 -noout -in "$fullchain" 2>/dev/null; then
        log_error "SSL certificate is expired or invalid"
        return 1
    fi

    # Check if private key matches certificate
    local cert_modulus=$(openssl x509 -noout -modulus -in "$fullchain" 2>/dev/null | md5sum | awk '{print $1}')
    local key_modulus=$(openssl rsa -noout -modulus -in "$privkey" 2>/dev/null | md5sum | awk '{print $1}')

    if [[ "$cert_modulus" != "$key_modulus" ]]; then
        log_error "SSL certificate and private key do not match"
        return 1
    fi

    # Get certificate expiry date
    local expiry_date=$(openssl x509 -enddate -noout -in "$fullchain" 2>/dev/null | cut -d= -f2)
    log_success "SSL certificate valid until: $expiry_date"

    return 0
}

# Run all pre-deployment validations
run_pre_deployment_checks() {
    local deploy_dir=$1

    log_info "Running pre-deployment validation checks..."
    echo ""

    local failed=0

    validate_disk_space 50 "$deploy_dir" || failed=1
    validate_memory 16
    validate_docker_version || failed=1
    validate_compose_version || failed=1
    validate_ports
    validate_env_placeholders "$deploy_dir/.env"
    validate_ssl_certificates "$deploy_dir/ssl" || failed=1

    echo ""

    if [[ $failed -eq 1 ]]; then
        log_error "Pre-deployment validation failed. Please fix the issues above."
        read -p "Continue anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "All pre-deployment checks passed"
    fi
}

# Wait for a container to be healthy (replaces hardcoded sleep)
wait_for_healthy() {
    local container_name=$1
    local max_attempts=${2:-60}
    local interval=${3:-5}

    log_info "Waiting for $container_name to be healthy..."

    for ((i=1; i<=max_attempts; i++)); do
        local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)

        if [[ "$status" == "healthy" ]]; then
            log_success "$container_name is healthy"
            return 0
        elif [[ "$status" == "unhealthy" ]]; then
            log_error "$container_name is unhealthy"
            return 1
        fi

        # Show progress every 5 attempts
        if [[ $((i % 5)) -eq 0 ]]; then
            log_info "Still waiting for $container_name... (attempt $i/$max_attempts)"
        fi

        sleep $interval
    done

    log_error "$container_name did not become healthy within timeout"
    return 1
}

# Check Ubuntu version
check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        exit 1
    fi

    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_warning "This script is designed for Ubuntu. Detected: $ID"
    fi

    log_info "Detected OS: $PRETTY_NAME"
}

# Install Docker
install_docker() {
    # Check if Docker is already installed and working
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        log_info "Docker is already installed: $(docker --version)"
        # Ensure Docker is running
        if ! systemctl is-active --quiet docker; then
            log_info "Starting Docker service..."
            systemctl start docker
        fi
        return
    fi

    log_info "Installing Docker..."

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker
    systemctl start docker
    systemctl enable docker

    # Add current user to docker group (if not root)
    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi

    log_success "Docker installed successfully"
}

# Install additional tools
install_tools() {
    log_info "Installing additional tools..."

    apt-get install -y \
        git \
        curl \
        wget \
        htop \
        vim \
        jq \
        certbot

    log_success "Additional tools installed"
}

# Setup firewall
setup_firewall() {
    log_info "Configuring firewall..."

    # Install UFW if not present
    apt-get install -y ufw

    # Allow SSH
    ufw allow 22/tcp

    # Allow HTTP and HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Enable firewall
    ufw --force enable

    log_success "Firewall configured"
}

# Setup deployment directory
setup_deployment_dir() {
    local deploy_dir="/opt/pravaha"
    local script_dir="$(cd "$(dirname "$0")/.." && pwd)"

    log_info "Setting up deployment directory at $deploy_dir..."

    mkdir -p "$deploy_dir"
    mkdir -p "$deploy_dir/ssl"
    mkdir -p "$deploy_dir/backups"
    mkdir -p "$deploy_dir/logs"

    # Copy deployment files only if source and destination are different
    if [[ "$script_dir" != "$deploy_dir" ]]; then
        log_info "Copying deployment files from $script_dir to $deploy_dir..."
        # Copy all files including hidden files (like .env.example)
        cp -r "$script_dir"/* "$deploy_dir/" 2>/dev/null || true
        # Explicitly copy hidden files (dotfiles) - glob doesn't match them by default
        cp "$script_dir"/.env* "$deploy_dir/" 2>/dev/null || true
        cp "$script_dir"/.docker* "$deploy_dir/" 2>/dev/null || true
    else
        log_info "Already running from $deploy_dir, skipping file copy."
    fi

    # Ensure all scripts are executable
    chmod +x "$deploy_dir/scripts/"*.sh 2>/dev/null || true

    log_success "Deployment directory created at $deploy_dir"
    echo "$deploy_dir"
}

# Generate audit signature keys (RSA key pair for HIPAA/SOC2/SOX compliance)
generate_audit_keys() {
    local deploy_dir=$1

    log_info "Generating audit signature keys..."

    local private_key="$deploy_dir/audit-private.pem"
    local public_key="$deploy_dir/audit-public.pem"

    if [[ -f "$private_key" && -f "$public_key" ]]; then
        log_warning "Audit keys already exist. Skipping generation."
        return
    fi

    # Generate RSA key pair
    openssl genrsa -out "$private_key" 2048 2>/dev/null
    openssl rsa -in "$private_key" -outform PEM -pubout -out "$public_key" 2>/dev/null

    # Set permissions for backend container user (UID 1001 - 'pravaha' user)
    # See deploy/docker/backend.Dockerfile: adduser -S pravaha -u 1001
    # Private key: 600 (owner read/write only - required for RSA private keys)
    # Public key: 644 (world-readable is acceptable for public keys)
    chown 1001:1001 "$private_key" "$public_key"
    chmod 600 "$private_key"
    chmod 644 "$public_key"

    log_success "Audit signature keys generated"
}

# Generate secrets
generate_secrets() {
    log_info "Generating secure secrets..."

    local env_file="$1/.env"

    if [[ -f "$env_file" ]]; then
        if ! grep -q "CHANGE_ME" "$env_file"; then
            log_info ".env file exists with secrets already generated. Skipping."
            return
        fi
        log_info ".env file exists with CHANGE_ME placeholders. Generating secrets..."
    else
        cp "$1/.env.example" "$env_file"
    fi

    # Generate unique secrets for each placeholder
    # Note: Using tr -d '/+=' to remove characters that could break sed or cause issues in configs
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
    # Each 64-char hex secret must be unique for security
    local lineage_secret=$(openssl rand -hex 32)
    local credential_master_key=$(openssl rand -hex 32)
    local model_signing_key=$(openssl rand -hex 32)
    local data_encryption_key=$(openssl rand -hex 32)
    local exception_encryption_key=$(openssl rand -hex 32)
    # Note: hmac_secret removed - using ml_service_hmac_secret for both HMAC_SECRET and ML_SERVICE_HMAC_SECRET
    local audit_signature_secret=$(openssl rand -hex 32)
    local ccm_encryption_key=$(openssl rand -hex 32)
    local storage_encryption_key=$(openssl rand -hex 32)
    local evidence_hmac_secret=$(openssl rand -hex 32)
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
    local internal_service_key=$(openssl rand -base64 32 | tr -d '\n/+=')

    # ELK Stack secrets (Section 16)
    local elastic_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_system_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_encryption_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_reporting_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_security_key=$(openssl rand -base64 32 | tr -d '\n/+=')

    # Super Admin secrets (Section 17)
    local super_admin_jwt_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local super_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    # Replace JWT_SECRET and SUPERSET_SECRET_KEY using line-anchored patterns (more robust)
    sed -i "s|^JWT_SECRET=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|JWT_SECRET=$jwt_secret|" "$env_file"
    sed -i "s|^SUPERSET_SECRET_KEY=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|SUPERSET_SECRET_KEY=$superset_secret|" "$env_file"

    # Replace ENCRYPTION_KEY
    sed -i "s|CHANGE_ME_32_CHAR_HEX|$encryption_key|g" "$env_file"

    # Replace each 64-char hex secret individually (they share same placeholder but need unique values)
    sed -i "s|^LINEAGE_SIGNATURE_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX|LINEAGE_SIGNATURE_SECRET=$lineage_secret|" "$env_file"
    sed -i "s|^CREDENTIAL_MASTER_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX|CREDENTIAL_MASTER_KEY=$credential_master_key|" "$env_file"
    sed -i "s|^MODEL_SIGNING_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX|MODEL_SIGNING_KEY=$model_signing_key|" "$env_file"
    sed -i "s|^DATA_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_DATA|DATA_ENCRYPTION_KEY=$data_encryption_key|" "$env_file"
    sed -i "s|^EXCEPTION_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_EXCEPTION|EXCEPTION_ENCRYPTION_KEY=$exception_encryption_key|" "$env_file"
    # IMPORTANT: HMAC_SECRET and ML_SERVICE_HMAC_SECRET MUST be the same value
    # Node.js signs with ML_SERVICE_HMAC_SECRET, Python verifies with either
    sed -i "s|^HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_HMAC|HMAC_SECRET=$ml_service_hmac_secret|" "$env_file"
    sed -i "s|^AUDIT_SIGNATURE_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_AUDIT|AUDIT_SIGNATURE_SECRET=$audit_signature_secret|" "$env_file"
    sed -i "s|^CCM_ENCRYPTION_KEY=.*|CCM_ENCRYPTION_KEY=$ccm_encryption_key|" "$env_file"
    sed -i "s|^STORAGE_ENCRYPTION_KEY=CHANGE_ME_GENERATE_64_CHAR_HEX_STORAGE|STORAGE_ENCRYPTION_KEY=$storage_encryption_key|" "$env_file"
    sed -i "s|^EVIDENCE_HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_EVIDENCE|EVIDENCE_HMAC_SECRET=$evidence_hmac_secret|" "$env_file"
    sed -i "s|^ML_SERVICE_HMAC_SECRET=CHANGE_ME_GENERATE_64_CHAR_HEX_ML_HMAC|ML_SERVICE_HMAC_SECRET=$ml_service_hmac_secret|" "$env_file"
    sed -i "s|^ML_CREDENTIAL_ENCRYPTION_KEY=CHANGE_ME_GENERATE_FERNET_KEY|ML_CREDENTIAL_ENCRYPTION_KEY=$ml_credential_encryption_key|" "$env_file"
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=$session_secret|" "$env_file"
    sed -i "s|^INTERNAL_SERVICE_KEY=.*|INTERNAL_SERVICE_KEY=$internal_service_key|" "$env_file"

    # Generate platform admin credentials
    local platform_admin_email="admin@${domain:-example.com}"
    local platform_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    # Replace admin credential placeholders
    sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$platform_admin_email|" "$env_file"
    sed -i "s|^ADMIN_PASSWORD=CHANGE_ME_ADMIN_PASSWORD|ADMIN_PASSWORD=$platform_admin_password|" "$env_file"

    # Replace other placeholders
    sed -i "s|CHANGE_ME_SECURE_PASSWORD|$postgres_password|g" "$env_file"
    sed -i "s|CHANGE_ME_ADMIN_PASSWORD|$admin_password|g" "$env_file"
    sed -i "s|CHANGE_ME_GRAFANA_PASSWORD|$grafana_password|g" "$env_file"
    # Generate and replace GRAFANA_SECRET_KEY
    local grafana_secret_key=$(openssl rand -base64 24 | tr -d '\n/+=')
    sed -i "s|^GRAFANA_SECRET_KEY=CHANGE_ME_32_CHAR_SECRET_KEY|GRAFANA_SECRET_KEY=$grafana_secret_key|" "$env_file"

    # Store credentials for display at the end
    echo "$platform_admin_email" > "$1/.admin_email"
    echo "$platform_admin_password" > "$1/.admin_password"
    chmod 600 "$1/.admin_email" "$1/.admin_password"
    sed -i "s|CHANGE_ME_GENERATE_SECURE_API_KEY|$ml_service_api_key|g" "$env_file"
    sed -i "s|CHANGE_ME_GENERATE_SECURE_SECRET|$csrf_secret|g" "$env_file"
    sed -i "s|CHANGE_ME_JUPYTER_TOKEN|$jupyter_token|g" "$env_file"

    # ELK Stack secrets (Section 16)
    sed -i "s|^ELASTIC_PASSWORD=CHANGE_ME_ELASTIC_PASSWORD|ELASTIC_PASSWORD=$elastic_password|" "$env_file"
    sed -i "s|^KIBANA_SYSTEM_PASSWORD=CHANGE_ME_KIBANA_PASSWORD|KIBANA_SYSTEM_PASSWORD=$kibana_system_password|" "$env_file"
    sed -i "s|^KIBANA_ENCRYPTION_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_ENCRYPTION|KIBANA_ENCRYPTION_KEY=$kibana_encryption_key|" "$env_file"
    sed -i "s|^KIBANA_REPORTING_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_REPORTING|KIBANA_REPORTING_KEY=$kibana_reporting_key|" "$env_file"
    sed -i "s|^KIBANA_SECURITY_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_SECURITY|KIBANA_SECURITY_KEY=$kibana_security_key|" "$env_file"

    # Super Admin secrets (Section 17)
    sed -i "s|^SUPER_ADMIN_JWT_SECRET=CHANGE_ME_GENERATE_SUPER_ADMIN_JWT_SECRET|SUPER_ADMIN_JWT_SECRET=$super_admin_jwt_secret|" "$env_file"
    sed -i "s|^SUPER_ADMIN_DEFAULT_PASSWORD=CHANGE_ME_SUPER_ADMIN_PASSWORD|SUPER_ADMIN_DEFAULT_PASSWORD=$super_admin_password|" "$env_file"

    log_success "Secrets generated. Please review $env_file before starting."
}

# Setup Let's Encrypt SSL
setup_letsencrypt() {
    local domain=$1
    local email=$2
    local deploy_dir=$3

    log_info "Setting up Let's Encrypt SSL for $domain..."

    # Stop any services using port 80 temporarily
    docker compose -f "$deploy_dir/docker-compose.yml" stop nginx 2>/dev/null || true

    # Get certificate using standalone mode (simpler, works without running webserver)
    certbot certonly --standalone \
        -d "$domain" \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive

    # Copy certificates to deployment directory
    cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$deploy_dir/ssl/"
    cp "/etc/letsencrypt/live/$domain/privkey.pem" "$deploy_dir/ssl/"

    # Setup auto-renewal with pre/post hooks
    cat > /etc/cron.d/certbot-renewal << EOF
0 0,12 * * * root certbot renew --quiet --pre-hook "docker compose -f $deploy_dir/docker-compose.yml stop nginx || true" --post-hook "cp /etc/letsencrypt/live/$domain/*.pem $deploy_dir/ssl/ && docker compose -f $deploy_dir/docker-compose.yml start nginx"
EOF

    log_success "SSL certificate obtained and auto-renewal configured"
}

# Setup self-signed SSL (for testing)
setup_selfsigned_ssl() {
    local domain=$1
    local deploy_dir=$2

    log_info "Generating self-signed SSL certificate for $domain..."

    # Create OpenSSL config with SAN (Subject Alternative Name) for browser compatibility
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
EOF

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$deploy_dir/ssl/privkey.pem" \
        -out "$deploy_dir/ssl/fullchain.pem" \
        -config "$openssl_conf" \
        -extensions v3_req

    rm -f "$openssl_conf"

    log_warning "Self-signed certificate created. Not recommended for production!"
    log_success "SSL certificate generated"
}

# Authenticate with container registry
authenticate_registry() {
    local deploy_dir=$1

    # Source .env to get registry configuration
    if [[ -f "$deploy_dir/.env" ]]; then
        local registry=$(grep "^REGISTRY=" "$deploy_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    registry="${registry:-karunakervgrc}"

    log_info "Authenticating with container registry: $registry"

    # Determine registry type and authenticate accordingly
    if [[ "$registry" == ghcr.io/* ]]; then
        # GitHub Container Registry
        if [[ -n "$GHCR_TOKEN" ]] && [[ -n "$GHCR_USERNAME" ]]; then
            log_info "Logging into GitHub Container Registry..."
            if echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin; then
                log_success "GHCR authentication successful"
                return 0
            else
                log_warning "GHCR login failed with provided credentials"
            fi
        fi

        # Check if already logged in by attempting a test pull
        if docker pull ghcr.io/talentfino/pravaha/frontend:latest --quiet 2>/dev/null; then
            log_info "Already authenticated to GHCR (or images are public)"
            return 0
        fi

        # Interactive prompt for GHCR credentials
        log_warning "GHCR authentication required for private images"
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
                log_error "Please verify your GitHub username and Personal Access Token"
                return 1
            fi
        else
            log_error "GHCR credentials not provided"
            log_error "Cannot pull private images without authentication"
            return 1
        fi
    elif [[ "$registry" == *.amazonaws.com/* ]] || [[ "$registry" == *.dkr.ecr.*.amazonaws.com/* ]]; then
        # AWS Elastic Container Registry
        log_info "AWS ECR detected"
        if command -v aws &>/dev/null; then
            local ecr_region=$(echo "$registry" | sed -n 's/.*\.dkr\.ecr\.\([^.]*\)\.amazonaws\.com.*/\1/p')
            if [[ -n "$ecr_region" ]]; then
                log_info "Logging into AWS ECR in region: $ecr_region"
                if aws ecr get-login-password --region "$ecr_region" | docker login --username AWS --password-stdin "$registry" 2>/dev/null; then
                    log_success "AWS ECR authentication successful"
                    return 0
                else
                    log_warning "AWS ECR login failed"
                fi
            fi
        else
            log_warning "AWS CLI not installed, cannot authenticate with ECR"
        fi
    else
        # Docker Hub (default)
        if [[ -n "$DOCKER_PASSWORD" ]] && [[ -n "$DOCKER_USERNAME" ]]; then
            log_info "Logging into Docker Hub as $DOCKER_USERNAME..."
            if echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin 2>/dev/null; then
                log_success "Docker Hub authentication successful"
                return 0
            else
                log_warning "Docker Hub login failed"
                log_info "Tip: Use a Docker Hub Access Token instead of password"
                log_info "Create one at: https://hub.docker.com/settings/security"
            fi
        else
            log_info "Docker Hub credentials not provided (DOCKER_USERNAME, DOCKER_PASSWORD)"
            log_info "Anonymous pulls are limited to 100 pulls per 6 hours"
            log_info "To avoid rate limits, set credentials before running install.sh:"
            log_info "  export DOCKER_USERNAME=karunakervgrc"
            log_info "  export DOCKER_PASSWORD=<your-access-token>"
        fi
    fi

    return 0  # Continue even if authentication fails (may work with public images)
}

# Pull Docker images with retry logic
pull_images() {
    local deploy_dir=$1

    log_info "Pulling Docker images..."

    cd "$deploy_dir"

    # Authenticate with the configured registry
    authenticate_registry "$deploy_dir"

    # Pull images with retry logic (network can be flaky)
    # Include bundled-db profile to also pre-pull postgres image
    if ! retry_with_backoff 3 5 60 "docker compose --profile bundled-db pull"; then
        log_error "Failed to pull Docker images after multiple attempts"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Check network connectivity: curl -s https://registry-1.docker.io/v2/"
        log_error "  2. Verify registry access: docker pull karunakervgrc/pravaha-frontend:latest"
        log_error "  3. Check Docker Hub rate limits (100 pulls/6hr for anonymous)"
        log_error "  4. Set credentials to bypass rate limits:"
        log_error "     export DOCKER_USERNAME=karunakervgrc"
        log_error "     export DOCKER_PASSWORD=<access-token>"
        log_error ""
        log_error "You can retry later with: cd $deploy_dir && docker compose pull"
        return 1
    fi

    log_success "Docker images pulled"
}

# Initialize database
init_database() {
    local deploy_dir=$1

    log_info "Initializing database..."

    cd "$deploy_dir"

    # Load environment variables
    source "$deploy_dir/.env" 2>/dev/null || true
    local pg_mode="${POSTGRES_MODE:-bundled}"
    local pg_user="${POSTGRES_USER:-pravaha}"
    local pg_host="${POSTGRES_HOST:-postgres}"
    local pg_port="${POSTGRES_PORT:-5432}"
    local platform_db="${PLATFORM_DB:-autoanalytics}"
    local superset_db="${SUPERSET_DB:-superset}"

    # Handle bundled vs external PostgreSQL
    if [[ "$pg_mode" == "bundled" ]]; then
        log_info "Using bundled PostgreSQL (Docker container)"
        # Start only postgres first with bundled-db profile
        docker compose --profile bundled-db up -d postgres

        # Wait for postgres to be healthy using health polling
        wait_for_healthy "pravaha-postgres" 30 5

        # Verify postgres is accepting connections
        docker compose exec -T postgres pg_isready -U "$pg_user" -d "$platform_db"

        # Verify databases exist
        log_info "Verifying database initialization..."

        # Check platform database exists
        if ! docker compose exec -T postgres psql -U "$pg_user" -d "$platform_db" -c "SELECT 1;" > /dev/null 2>&1; then
            log_error "Platform database '$platform_db' does not exist or is not accessible"
            log_error "Check that PLATFORM_DB in .env matches the database created by PostgreSQL"
            return 1
        fi

        # Check superset database exists
        if ! docker compose exec -T postgres psql -U "$pg_user" -d "$superset_db" -c "SELECT 1;" > /dev/null 2>&1; then
            log_error "Superset database '$superset_db' does not exist or is not accessible"
            log_error "Check that SUPERSET_DB in .env matches the database created by PostgreSQL"
            return 1
        fi

        # Verify required extensions are installed
        local extensions_check=$(docker compose exec -T postgres psql -U "$pg_user" -d "$platform_db" -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto');" 2>/dev/null | tr -d '[:space:]')
        if [[ "$extensions_check" != "2" ]]; then
            log_warning "PostgreSQL extensions (uuid-ossp, pgcrypto) may not be fully installed"
            log_info "Attempting to create extensions..."
            docker compose exec -T postgres psql -U "$pg_user" -d "$platform_db" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"; CREATE EXTENSION IF NOT EXISTS pgcrypto;" || true
        fi
    else
        log_info "Using external PostgreSQL at $pg_host:$pg_port"
        log_info "Verifying external database connectivity..."

        # Use PGPASSWORD environment variable for password
        export PGPASSWORD="${POSTGRES_PASSWORD}"

        # Test connection to external PostgreSQL
        if ! psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$platform_db" -c "SELECT 1;" > /dev/null 2>&1; then
            log_error "Cannot connect to external PostgreSQL at $pg_host:$pg_port"
            log_error "Ensure the database server is reachable and credentials are correct"
            log_error "Required databases: $platform_db, $superset_db"
            log_error "Required extensions: uuid-ossp, pgcrypto"
            unset PGPASSWORD
            return 1
        fi

        # Verify superset database
        if ! psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$superset_db" -c "SELECT 1;" > /dev/null 2>&1; then
            log_error "Cannot connect to Superset database '$superset_db' at $pg_host:$pg_port"
            log_error "Ensure the database exists and user has access"
            unset PGPASSWORD
            return 1
        fi

        unset PGPASSWORD
        log_success "External PostgreSQL connection verified"
    fi

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

# Start services
start_services() {
    local deploy_dir=$1

    log_info "Starting all services..."

    cd "$deploy_dir"

    # Load environment variables to check POSTGRES_MODE
    source "$deploy_dir/.env" 2>/dev/null || true
    local pg_mode="${POSTGRES_MODE:-bundled}"

    # Start services with appropriate profile
    if [[ "$pg_mode" == "bundled" ]]; then
        log_info "Starting with bundled PostgreSQL..."
        docker compose --profile bundled-db up -d
    else
        log_info "Starting with external PostgreSQL at ${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}..."
        docker compose up -d
    fi

    log_info "Waiting for services to be healthy..."

    # Build service list based on POSTGRES_MODE
    local services
    if [[ "$pg_mode" == "bundled" ]]; then
        services=("pravaha-postgres" "pravaha-redis" "pravaha-backend" "pravaha-frontend" "pravaha-nginx")
    else
        # External PostgreSQL - don't wait for bundled postgres container
        services=("pravaha-redis" "pravaha-backend" "pravaha-frontend" "pravaha-nginx")
    fi

    local failed=0

    for service in "${services[@]}"; do
        if ! wait_for_healthy "$service" 60 5; then
            log_warning "$service did not become healthy"
            failed=1
        fi
    done

    # Check health
    docker compose ps

    if [[ $failed -eq 0 ]]; then
        log_success "All services started and healthy"
    else
        log_warning "Some services may need attention - check 'docker compose logs'"
    fi
}

# Generate after-deployment.md with deployment details
generate_after_deployment_doc() {
    local domain=$1
    local deploy_dir=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local doc_file="$deploy_dir/after-deployment.md"

    log_info "Generating after-deployment.md..."

    cat > "$doc_file" << EOF
# After Deployment Checklist - Single Server

**Deployment Date:** $timestamp
**Domain:** $domain
**Deployment Directory:** $deploy_dir

---

## Immediate Verification

Run these commands to verify all services are healthy:

\`\`\`bash
cd $deploy_dir
docker compose ps

# Test health endpoints
curl -k https://$domain/health
curl -k https://$domain/api/health
curl -k https://$domain/ml/api/v1/health
\`\`\`

---

## Login Verification

- [ ] Access https://$domain in browser
- [ ] Login with generated admin credentials (see credentials files in $deploy_dir):
  - **Email:** See \`.admin_email\` file
  - **Password:** See \`.admin_password\` file
- [ ] Change admin password immediately after first login
- [ ] Verify dashboard loads without errors
- [ ] Test creating a new project or workflow
- [ ] Delete credential files after saving: \`rm $deploy_dir/.admin_email $deploy_dir/.admin_password\`

---

## Security Keys Generated

The following secrets were auto-generated. Review in \`$deploy_dir/.env\`:

- [ ] JWT_SECRET
- [ ] SUPERSET_SECRET_KEY
- [ ] ENCRYPTION_KEY
- [ ] POSTGRES_PASSWORD
- [ ] ML_SERVICE_API_KEY
- [ ] CREDENTIAL_MASTER_KEY
- [ ] DATA_ENCRYPTION_KEY
- [ ] ML_CREDENTIAL_ENCRYPTION_KEY
- [ ] HMAC_SECRET
- [ ] AUDIT_SIGNATURE_SECRET
- [ ] MODEL_SIGNING_KEY

---

## Production Security Checklist

- [ ] Replace self-signed SSL certificate with valid CA certificate
- [ ] Change default admin passwords
- [ ] Review and restrict firewall rules
- [ ] Disable ENABLE_SWAGGER_DOCS in production
- [ ] Configure backup schedule
- [ ] Set up monitoring alerts

---

## Optional Services

### Jupyter Notebook Server
\`\`\`bash
cd $deploy_dir
docker compose -f docker-compose.jupyter.yml up -d
# Access at http://localhost:8888
\`\`\`

### Grafana Logging Stack
\`\`\`bash
cd $deploy_dir
docker compose -f docker-compose.logging.yml up -d
# Access at https://$domain/logs/
\`\`\`

---

## Common Commands

\`\`\`bash
# View logs
docker compose logs -f

# Restart services
docker compose restart

# Stop services
docker compose down

# Update images
docker compose pull
docker compose up -d
\`\`\`

---

*Generated by Pravaha Platform Installer*
EOF

    log_success "after-deployment.md generated at $doc_file"
}

# Print completion message
print_completion() {
    local domain=$1
    local deploy_dir=$2

    # Read generated admin credentials
    local admin_email="admin@$domain"
    local admin_password="[check .admin_password file]"

    if [[ -f "$deploy_dir/.admin_email" ]]; then
        admin_email=$(cat "$deploy_dir/.admin_email")
    fi
    if [[ -f "$deploy_dir/.admin_password" ]]; then
        admin_password=$(cat "$deploy_dir/.admin_password")
    fi

    echo ""
    echo "=============================================="
    echo -e "${GREEN}Pravaha Platform Installation Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Access your platform at: https://$domain"
    echo ""
    echo "Platform Admin Credentials (auto-generated):"
    echo "  Email:    $admin_email"
    echo "  Password: $admin_password"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely and change the password after first login!${NC}"
    echo ""
    echo "Useful commands:"
    echo "  - View logs: docker compose logs -f"
    echo "  - Stop services: docker compose down"
    echo "  - Start services: docker compose up -d"
    echo "  - Check status: docker compose ps"
    echo ""
    echo "Configuration: $deploy_dir/.env"
    echo "After deployment: $deploy_dir/after-deployment.md"
    echo "Credentials file: $deploy_dir/.admin_password (delete after saving)"
    echo ""
}

# Main installation function
main() {
    echo "=============================================="
    echo "Pravaha Platform - Single Server Installation"
    echo "Version: $SCRIPT_VERSION"
    echo "=============================================="
    echo ""

    check_root
    check_ubuntu

    # Parse arguments
    local domain=""
    local email=""
    local ssl_type="letsencrypt"
    local skip_ssl="false"
    local skip_pull="false"
    local resume="false"
    local force="false"
    local dry_run="false"
    local verbose="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                domain="$2"
                shift 2
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --ssl)
                ssl_type="$2"
                shift 2
                ;;
            --skip-ssl)
                skip_ssl="true"
                shift
                ;;
            --skip-pull)
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
            --dry-run)
                dry_run="true"
                shift
                ;;
            --verbose|-v)
                verbose="true"
                shift
                ;;
            --help)
                echo "Usage: $0 --domain <domain> --email <email> [options]"
                echo ""
                echo "Required:"
                echo "  --domain     Your domain name (e.g., analytics.example.com)"
                echo ""
                echo "Options:"
                echo "  --email      Email for Let's Encrypt notifications"
                echo "  --ssl        SSL type: letsencrypt (default) or selfsigned"
                echo "  --skip-ssl   Skip SSL certificate generation (use existing certs)"
                echo "  --skip-pull  Skip docker compose pull (use pre-loaded local images)"
                echo "  --resume     Resume a failed installation from last checkpoint"
                echo "  --force      Force reinstallation without prompts"
                echo "  --dry-run    Preview installation steps without executing"
                echo "  --verbose    Show detailed output during installation"
                echo ""
                echo "Examples:"
                echo "  $0 --domain analytics.example.com --ssl selfsigned"
                echo "  $0 --domain analytics.example.com --resume"
                echo "  $0 --domain analytics.example.com --force --skip-pull"
                echo "  $0 --domain analytics.example.com --dry-run"
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
        read -p "Enter your domain (e.g., analytics.example.com): " domain
    fi

    # Validate domain format early
    if ! validate_domain_format "$domain"; then
        exit 1
    fi

    # Initialize deployment directory and audit logging early
    mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null || true
    init_audit_log "$DEPLOY_DIR"
    log_info "Installation audit log: $INSTALL_LOG"

    # Handle resume mode
    if [[ "$resume" == "true" ]]; then
        local checkpoint=$(get_checkpoint)
        local checkpoint_status=$(get_checkpoint_status)

        if [[ -z "$checkpoint" ]]; then
            log_warning "No checkpoint found. Starting fresh installation."
            resume="false"
        elif [[ "$checkpoint_status" == "completed" ]]; then
            log_info "Previous installation completed successfully."
            log_info "Use --force to reinstall."
            exit 0
        else
            log_info "Resuming installation from checkpoint: $checkpoint"
            # Load domain from checkpoint if not provided
            if [[ -f "$STATE_FILE" ]]; then
                local saved_domain=$(grep -o '"domain": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
                local saved_ssl=$(grep -o '"ssl_type": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
                [[ -n "$saved_domain" && -z "$domain" ]] && domain="$saved_domain"
                [[ -n "$saved_ssl" ]] && ssl_type="$saved_ssl"
            fi
        fi
    fi

    # Check existing installation (idempotency)
    check_existing_installation "$DEPLOY_DIR" "$force"

    # Ask about SSL setup if not specified via --skip-ssl (only in interactive mode)
    if [[ "$skip_ssl" != "true" && "$force" != "true" ]]; then
        echo ""
        log_info "SSL Certificate Setup"
        echo "  If you already have SSL certificates (e.g., from GoDaddy, DigiCert, etc.),"
        echo "  you can skip SSL generation and place your certificates in the ssl/ folder:"
        echo "    - ssl/fullchain.pem (certificate + intermediate chain)"
        echo "    - ssl/privkey.pem (private key)"
        echo ""
        read -p "Do you want to skip SSL certificate generation? [y/N]: " skip_ssl_input
        if [[ "$skip_ssl_input" =~ ^[Yy]$ ]]; then
            skip_ssl="true"
        fi
    fi

    # Only ask for email if using Let's Encrypt and not skipping SSL
    if [[ "$skip_ssl" != "true" && -z "$email" && "$ssl_type" == "letsencrypt" && "$force" != "true" ]]; then
        read -p "Enter your email for SSL certificate notifications: " email
    fi

    # Validate ssl_type if not skipping SSL
    if [[ "$skip_ssl" != "true" && "$ssl_type" != "letsencrypt" && "$ssl_type" != "selfsigned" ]]; then
        log_error "Invalid SSL type: $ssl_type. Must be 'letsencrypt' or 'selfsigned'"
        exit 1
    fi

    # Display configuration summary
    echo ""
    log_info "=============================================="
    log_info "Installation Configuration:"
    log_info "  Domain:     $domain"
    if [[ "$skip_ssl" == "true" ]]; then
        log_info "  SSL:        Using existing certificates"
    else
        log_info "  SSL Type:   $ssl_type"
    fi
    log_info "  Skip Pull:  $skip_pull"
    log_info "  Resume:     $resume"
    log_info "  Force:      $force"
    log_info "  Dry Run:    $dry_run"
    log_info "  Verbose:    $verbose"
    log_info "=============================================="
    echo ""

    # Dry-run mode: preview steps and exit
    if [[ "$dry_run" == "true" ]]; then
        echo ""
        log_info "=============================================="
        log_info "DRY RUN MODE - Preview of installation steps"
        log_info "=============================================="
        echo ""
        echo "The following steps would be executed:"
        echo ""
        echo "  1.  Pre-flight checks"
        echo "      - Validate disk space (minimum 50GB)"
        echo "      - Validate memory (minimum 16GB recommended)"
        echo "      - Validate Docker version (24.0+)"
        echo "      - Check port availability (80, 443, 5432, 6379)"
        echo "      - Check network connectivity"
        echo "      - Check domain DNS resolution"
        echo ""
        echo "  2.  Install Docker"
        echo "      - Install Docker CE and Docker Compose plugin"
        echo "      - Enable and start Docker service"
        if [[ -n "$SUDO_USER" ]]; then
            echo "      - Add $SUDO_USER to docker group"
        fi
        echo ""
        echo "  3.  Install additional tools"
        echo "      - Install: git, curl, wget, htop, vim, jq, certbot"
        echo ""
        echo "  4.  Configure firewall (UFW)"
        echo "      - Allow ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)"
        echo ""
        echo "  5.  Setup deployment directory"
        echo "      - Create: $DEPLOY_DIR"
        echo "      - Copy deployment files"
        echo "      - Make scripts executable"
        echo ""
        echo "  6.  Generate NGINX configuration"
        echo "      - Substitute DOMAIN=$domain into nginx config"
        echo ""
        echo "  7.  Generate secrets"
        echo "      - Generate: JWT_SECRET, SUPERSET_SECRET_KEY, ENCRYPTION_KEY"
        echo "      - Generate: POSTGRES_PASSWORD, ML_SERVICE_API_KEY"
        echo "      - Generate: Admin email and password"
        echo "      - Update: DOMAIN, FRONTEND_URL, API_BASE_URL"
        echo ""
        echo "  8.  Generate audit keys"
        echo "      - Generate: RSA 2048-bit key pair for audit signatures"
        echo "      - Files: audit-private.pem, audit-public.pem"
        echo ""
        echo "  9.  Setup SSL certificates"
        if [[ "$skip_ssl" == "true" ]]; then
            echo "      - SKIPPED (using existing certificates)"
        elif [[ "$ssl_type" == "letsencrypt" ]]; then
            echo "      - Request Let's Encrypt certificate for $domain"
            echo "      - Setup auto-renewal cron job"
        else
            echo "      - Generate self-signed certificate for $domain"
        fi
        echo ""
        echo "  10. Pull Docker images"
        if [[ "$skip_pull" == "true" ]]; then
            echo "      - SKIPPED (using pre-loaded local images)"
        else
            echo "      - Pull images from ${REGISTRY:-karunakervgrc}/*:${IMAGE_TAG:-latest}"
        fi
        echo ""
        echo "  11. Initialize database"
        echo "      - Start PostgreSQL container"
        echo "      - Wait for healthy status"
        echo "      - Verify platform database (autoanalytics)"
        echo "      - Verify superset database"
        echo "      - Create extensions: uuid-ossp, pgcrypto"
        echo ""
        echo "  12. Start all services"
        echo "      - Start: nginx, frontend, backend, superset, ml-service"
        echo "      - Start: celery-worker-training, celery-worker-prediction"
        echo "      - Start: celery-worker-monitoring, celery-beat"
        echo "      - Start: postgres, redis"
        echo "      - Wait for all services to be healthy"
        echo ""
        echo "  13. Verification"
        echo "      - Check NGINX health endpoint"
        echo "      - Check Backend health endpoint"
        echo "      - Check PostgreSQL connectivity"
        echo "      - Check Redis connectivity"
        echo "      - Run comprehensive health check"
        echo ""
        echo "  14. Generate documentation"
        echo "      - Generate: after-deployment.md"
        echo "      - Display admin credentials"
        echo ""
        echo "=============================================="
        echo ""
        log_info "To execute the installation, remove --dry-run flag:"
        log_info "  sudo $0 --domain $domain ${ssl_type:+--ssl $ssl_type}"
        echo ""
        exit 0
    fi

    # =========================================================================
    # STEP 1: Pre-flight checks
    # =========================================================================
    if ! should_skip_step "preflight" || [[ "$resume" != "true" ]]; then
        log_step "Running pre-flight checks..."
        save_checkpoint "preflight" "in_progress"

        run_pre_deployment_checks "$DEPLOY_DIR"

        # Check network connectivity (critical for image pull)
        if [[ "$skip_pull" != "true" ]]; then
            if ! check_network_connectivity; then
                log_error "Network connectivity check failed"
                log_error "Use --skip-pull if you have pre-loaded images"
                exit 1
            fi
        fi

        # Check domain DNS (informational)
        check_domain_dns "$domain"

        save_checkpoint "preflight" "completed"
        log_success "Pre-flight checks completed"
    else
        log_info "Skipping pre-flight checks (already completed)"
    fi

    # =========================================================================
    # STEP 2: Install Docker
    # =========================================================================
    if ! should_skip_step "docker_install" || [[ "$resume" != "true" ]]; then
        log_step "Installing Docker..."
        save_checkpoint "docker_install" "in_progress"

        install_docker

        save_checkpoint "docker_install" "completed"
        log_success "Docker installation completed"
    else
        log_info "Skipping Docker installation (already completed)"
    fi

    # =========================================================================
    # STEP 3: Install additional tools
    # =========================================================================
    if ! should_skip_step "tools_install" || [[ "$resume" != "true" ]]; then
        log_step "Installing additional tools..."
        save_checkpoint "tools_install" "in_progress"

        install_tools

        save_checkpoint "tools_install" "completed"
        log_success "Tools installation completed"
    else
        log_info "Skipping tools installation (already completed)"
    fi

    # =========================================================================
    # STEP 4: Setup firewall
    # =========================================================================
    if ! should_skip_step "firewall_setup" || [[ "$resume" != "true" ]]; then
        log_step "Configuring firewall..."
        save_checkpoint "firewall_setup" "in_progress"

        setup_firewall

        save_checkpoint "firewall_setup" "completed"
        log_success "Firewall configuration completed"
    else
        log_info "Skipping firewall setup (already completed)"
    fi

    # =========================================================================
    # STEP 5: Setup deployment directory
    # =========================================================================
    if ! should_skip_step "directory_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up deployment directory..."
        save_checkpoint "directory_setup" "in_progress"

        deploy_dir=$(setup_deployment_dir)

        save_checkpoint "directory_setup" "completed"
        log_success "Deployment directory setup completed"
    else
        log_info "Skipping directory setup (already completed)"
        deploy_dir="$DEPLOY_DIR"
    fi

    # =========================================================================
    # STEP 6: Generate NGINX configuration
    # =========================================================================
    if ! should_skip_step "nginx_config" || [[ "$resume" != "true" ]]; then
        log_step "Generating NGINX configuration..."
        save_checkpoint "nginx_config" "in_progress"

        local nginx_script="$deploy_dir/scripts/generate-nginx-config.sh"
        if [[ ! -f "$nginx_script" ]]; then
            log_error "NGINX config script not found: $nginx_script"
            exit 1
        fi
        chmod +x "$nginx_script"
        DOMAIN="$domain" bash "$nginx_script"

        save_checkpoint "nginx_config" "completed"
        log_success "NGINX configuration completed"
    else
        log_info "Skipping NGINX configuration (already completed)"
    fi

    # =========================================================================
    # STEP 7: Generate secrets
    # =========================================================================
    if ! should_skip_step "secrets_generation" || [[ "$resume" != "true" ]]; then
        log_step "Generating secrets..."
        save_checkpoint "secrets_generation" "in_progress"

        generate_secrets "$deploy_dir"

        # Update domain in .env
        sed -i "s/^DOMAIN=.*/DOMAIN=$domain/" "$deploy_dir/.env"
        sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=https://$domain|" "$deploy_dir/.env"
        sed -i "s|^API_BASE_URL=.*|API_BASE_URL=https://$domain/api|" "$deploy_dir/.env"
        sed -i "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=https://$domain|" "$deploy_dir/.env"
        sed -i "s|^CORS_ORIGIN=.*|CORS_ORIGIN=https://$domain|" "$deploy_dir/.env"
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=https://$domain|" "$deploy_dir/.env"

        # Replace SAML URLs with actual domain
        sed -i "s|^SAML_SP_ENTITY_ID=.*|SAML_SP_ENTITY_ID=https://$domain/saml/metadata|" "$deploy_dir/.env"
        sed -i "s|^SAML_SP_ACS_URL=.*|SAML_SP_ACS_URL=https://$domain/saml/acs|" "$deploy_dir/.env"
        sed -i "s|^SAML_SP_SLO_URL=.*|SAML_SP_SLO_URL=https://$domain/saml/slo|" "$deploy_dir/.env"

        save_checkpoint "secrets_generation" "completed"
        log_success "Secrets generation completed"
    else
        log_info "Skipping secrets generation (already completed)"
    fi

    # =========================================================================
    # STEP 8: Generate audit keys
    # =========================================================================
    if ! should_skip_step "audit_keys" || [[ "$resume" != "true" ]]; then
        log_step "Generating audit signature keys..."
        save_checkpoint "audit_keys" "in_progress"

        generate_audit_keys "$deploy_dir"

        save_checkpoint "audit_keys" "completed"
        log_success "Audit keys generation completed"
    else
        log_info "Skipping audit keys generation (already completed)"
    fi

    # =========================================================================
    # STEP 9: Setup SSL
    # =========================================================================
    if ! should_skip_step "ssl_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up SSL certificates..."
        save_checkpoint "ssl_setup" "in_progress"

        if [[ "$skip_ssl" == "true" ]]; then
            if [[ -f "$deploy_dir/ssl/fullchain.pem" && -f "$deploy_dir/ssl/privkey.pem" ]]; then
                log_success "SSL certificates found in $deploy_dir/ssl/"
            else
                log_warning "SSL certificates not found in $deploy_dir/ssl/"
                log_warning "Please ensure the following files exist before starting NGINX:"
                log_warning "  - $deploy_dir/ssl/fullchain.pem"
                log_warning "  - $deploy_dir/ssl/privkey.pem"
                if [[ "$force" != "true" ]]; then
                    read -p "Continue anyway? [y/N]: " continue_without_ssl
                    if [[ ! "$continue_without_ssl" =~ ^[Yy]$ ]]; then
                        log_info "Installation paused at ssl_setup. Resume with --resume"
                        save_checkpoint "ssl_setup" "paused"
                        exit 0
                    fi
                fi
            fi
        else
            case $ssl_type in
                letsencrypt)
                    setup_letsencrypt "$domain" "$email" "$deploy_dir"
                    ;;
                selfsigned)
                    setup_selfsigned_ssl "$domain" "$deploy_dir"
                    ;;
            esac
        fi

        save_checkpoint "ssl_setup" "completed"
        log_success "SSL setup completed"
    else
        log_info "Skipping SSL setup (already completed)"
    fi

    # =========================================================================
    # STEP 10: Pull Docker images
    # =========================================================================
    if ! should_skip_step "image_pull" || [[ "$resume" != "true" ]]; then
        log_step "Pulling Docker images..."
        save_checkpoint "image_pull" "in_progress"

        if [[ "$skip_pull" == "true" ]]; then
            log_info "Skipping docker compose pull (using pre-loaded local images)"
        else
            if ! pull_images "$deploy_dir"; then
                log_error "Failed to pull images. Installation cannot continue."
                log_error "Try again with: sudo $0 --domain $domain --resume"
                exit 1
            fi
        fi

        save_checkpoint "image_pull" "completed"
        log_success "Image pull completed"
    else
        log_info "Skipping image pull (already completed)"
    fi

    # =========================================================================
    # STEP 11: Initialize database
    # =========================================================================
    if ! should_skip_step "database_init" || [[ "$resume" != "true" ]]; then
        log_step "Initializing database..."
        save_checkpoint "database_init" "in_progress"

        init_database "$deploy_dir"

        save_checkpoint "database_init" "completed"
        log_success "Database initialization completed"
    else
        log_info "Skipping database initialization (already completed)"
    fi

    # =========================================================================
    # STEP 12: Start services
    # =========================================================================
    # Setup default branding before starting services
    setup_default_branding

    if ! should_skip_step "services_start" || [[ "$resume" != "true" ]]; then
        log_step "Starting services..."
        save_checkpoint "services_start" "in_progress"

        start_services "$deploy_dir"

        save_checkpoint "services_start" "completed"
        log_success "Services started"
    else
        log_info "Skipping service start (already completed)"
    fi

    # =========================================================================
    # STEP 13: Verification
    # =========================================================================
    log_step "Running post-installation verification..."
    save_checkpoint "verification" "in_progress"

    # Verify all services are healthy
    local verification_failed=0

    # Wait for services to be fully initialized using health polling
    log_info "Verifying service health endpoints..."

    # Check NGINX via internal Docker network first (DNS-independent)
    local nginx_healthy=false
    for i in {1..12}; do
        if docker exec pravaha-nginx wget -q -O /dev/null http://localhost/health 2>/dev/null; then
            nginx_healthy=true
            break
        fi
        log_info "Waiting for NGINX... (attempt $i/12)"
        sleep 5
    done

    if [[ "$nginx_healthy" == "true" ]]; then
        log_success "NGINX health check passed (internal)"

        # Also check external access if DNS is configured
        if curl -ks --max-time 5 "https://$domain/health" | grep -q "ok\|healthy\|OK" 2>/dev/null; then
            log_success "NGINX health check passed (external: https://$domain)"
        else
            log_warning "External HTTPS check failed (DNS may not be propagated yet)"
            log_info "This is normal if DNS is not configured. The platform is accessible internally."
        fi
    else
        log_warning "NGINX internal health check failed"
        verification_failed=1
    fi

    # Check Backend via internal Docker network
    local backend_healthy=false
    for i in {1..12}; do
        if docker exec pravaha-backend wget -q -O /dev/null http://localhost:3000/health/live 2>/dev/null; then
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
    if docker exec pravaha-postgres pg_isready -U "${POSTGRES_USER:-pravaha}" -d "${PLATFORM_DB:-autoanalytics}" 2>/dev/null; then
        log_success "PostgreSQL health check passed"
    else
        log_warning "PostgreSQL health check failed"
        verification_failed=1
    fi

    # Check Redis
    if docker exec pravaha-redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis health check passed"
    else
        log_warning "Redis health check failed"
        verification_failed=1
    fi

    # Run comprehensive health check if available
    if [[ -x "$deploy_dir/scripts/health-check.sh" ]]; then
        log_info "Running comprehensive health check..."
        if "$deploy_dir/scripts/health-check.sh" --quick 2>/dev/null; then
            log_success "Comprehensive health check passed"
        else
            log_warning "Some services may need attention"
        fi
    fi

    save_checkpoint "verification" "completed"

    # =========================================================================
    # COMPLETE
    # =========================================================================
    save_checkpoint "complete" "completed"

    # Mark installation as complete
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$deploy_dir/.installed"

    # Generate after-deployment documentation
    generate_after_deployment_doc "$domain" "$deploy_dir"

    # Disable cleanup trap since we succeeded
    CLEANUP_ON_EXIT=false

    # Display comprehensive credential summary
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cred_summary_script="$script_dir/../../scripts/print-credential-summary.sh"
    if [[ -f "$cred_summary_script" ]]; then
        source "$cred_summary_script"
        print_credential_summary "$deploy_dir" "$domain"
    elif [[ -f "$deploy_dir/scripts/print-credential-summary.sh" ]]; then
        source "$deploy_dir/scripts/print-credential-summary.sh"
        print_credential_summary "$deploy_dir" "$domain"
    fi

    print_completion "$domain" "$deploy_dir"

    log_info "Installation log saved to: $INSTALL_LOG"
}

# Run main function
main "$@"
