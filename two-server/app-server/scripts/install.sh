#!/bin/bash
# =============================================================================
# Pravaha Platform - Two-Server App Server Installation Script
# Ubuntu 22.04 LTS
# Enterprise-Grade Production Deployment
# =============================================================================
#
# Architecture:
#   App Server (this):   All Docker services except PostgreSQL
#   Database Server:     External PostgreSQL (self-hosted/native)
#
# Features:
#   - External PostgreSQL validation and connectivity testing
#   - Pre-flight validation (disk, memory, network, ports)
#   - Retry logic with exponential backoff
#   - Checkpoint/resume capability
#   - Rollback on failure
#   - Installation audit logging
#   - Idempotency (safe to re-run)
#
# Prerequisites:
#   - External PostgreSQL server configured and accessible
#   - Databases created: autoanalytics, superset
#   - User with full access to both databases
#   - Network access from this server (pg_hba.conf configured)
#
# =============================================================================

set -euo pipefail

# Capture original command-line arguments for audit logging
ORIGINAL_ARGS="$*"

# =============================================================================
# Global Configuration
# =============================================================================
SCRIPT_VERSION="2.0.0"
DEPLOY_DIR="/opt/pravaha"
STATE_FILE=""
INSTALL_LOG=""
CLEANUP_ON_EXIT=true
CURRENT_STEP=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

    mkdir -p "$(dirname "$STATE_FILE")"

    cat > "$STATE_FILE" << EOF
{
    "version": "$SCRIPT_VERSION",
    "step": "$step",
    "status": "$status",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "domain": "${domain:-}",
    "ssl_type": "${ssl_type:-}",
    "installer": "${SUDO_USER:-root}",
    "hostname": "$(hostname)",
    "deployment_type": "two-server-app"
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
        "external_db_validation"
        "services_start"
        "database_migrations"
        "verification"
        "complete"
    )

    [[ -z "$checkpoint" ]] && return 1
    [[ "$status" == "failed" ]] && return 1

    local checkpoint_idx=-1
    local step_idx=-1
    for i in "${!steps[@]}"; do
        [[ "${steps[$i]}" == "$checkpoint" ]] && checkpoint_idx=$i
        [[ "${steps[$i]}" == "$step" ]] && step_idx=$i
    done

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
        log_warning "  sudo $0 --domain $domain --resume"
        echo ""
        log_warning "To view installation log:"
        log_warning "  cat $INSTALL_LOG"
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

    local attempt=1
    local delay=$base_delay

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt of $max_attempts: $*"

        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Command failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
            [[ $delay -gt $max_delay ]] && delay=$max_delay
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: $*"
    return 1
}

# =============================================================================
# External Database Validation (KEY DIFFERENCE FROM SINGLE-SERVER)
# =============================================================================
validate_external_database() {
    log_step "Validating external PostgreSQL connection..."

    # Load environment if exists
    local env_file="$DEPLOY_DIR/.env"
    if [[ -f "$env_file" ]]; then
        source "$env_file" 2>/dev/null || true
    fi

    local host="${POSTGRES_HOST:-}"
    local port="${POSTGRES_PORT:-5432}"
    local user="${POSTGRES_USER:-pravaha}"
    local password="${POSTGRES_PASSWORD:-}"
    local platform_db="${PLATFORM_DB:-autoanalytics}"
    local superset_db="${SUPERSET_DB:-superset}"
    local ssl_enabled="${POSTGRES_SSL_ENABLED:-false}"
    local ssl_mode="${POSTGRES_SSL_MODE:-prefer}"

    # Check required variables
    if [[ -z "$host" ]]; then
        log_error "POSTGRES_HOST is required for two-server deployment"
        log_error "Set POSTGRES_HOST in .env to your database server IP/hostname"
        log_info ""
        log_info "Example:"
        log_info "  POSTGRES_HOST=192.168.1.100"
        log_info "  POSTGRES_PORT=5432"
        log_info "  POSTGRES_USER=pravaha"
        log_info "  POSTGRES_PASSWORD=your_secure_password"
        return 1
    fi

    if [[ -z "$password" ]]; then
        log_error "POSTGRES_PASSWORD is required"
        log_error "Set POSTGRES_PASSWORD in .env file"
        return 1
    fi

    # TCP connectivity test
    log_info "Testing TCP connectivity to $host:$port..."
    if ! timeout 10 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        log_error "Cannot reach PostgreSQL at $host:$port"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Verify PostgreSQL is running on the database server"
        log_error "  2. Check firewall rules allow port $port from this server"
        log_error "  3. Verify postgresql.conf has listen_addresses = '*'"
        log_error "  4. Verify pg_hba.conf allows connections from this server's IP"
        log_error ""
        log_error "On the database server, run:"
        log_error "  sudo ss -tlnp | grep $port"
        log_error "  sudo ufw status | grep $port"
        return 1
    fi
    log_success "TCP connectivity to $host:$port OK"

    # PostgreSQL authentication test using docker
    log_info "Testing PostgreSQL authentication..."

    # Build connection string
    local conn_opts=""
    if [[ "$ssl_enabled" == "true" ]]; then
        conn_opts="?sslmode=$ssl_mode"
    fi

    # Test connection to platform database
    if ! docker run --rm --network host \
        -e PGPASSWORD="$password" \
        postgres:17-alpine \
        psql "postgresql://$user@$host:$port/$platform_db$conn_opts" \
        -c "SELECT 1;" > /dev/null 2>&1; then

        log_error "PostgreSQL authentication failed for database: $platform_db"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Verify username and password are correct"
        log_error "  2. Check pg_hba.conf on database server allows this connection"
        log_error "  3. Verify the database '$platform_db' exists"
        log_error ""
        log_error "On the database server, check:"
        log_error "  sudo -u postgres psql -c \"\\l\" | grep $platform_db"
        log_error "  sudo -u postgres psql -c \"\\du\" | grep $user"
        return 1
    fi
    log_success "PostgreSQL authentication OK for $platform_db"

    # Test connection to superset database
    if ! docker run --rm --network host \
        -e PGPASSWORD="$password" \
        postgres:17-alpine \
        psql "postgresql://$user@$host:$port/$superset_db$conn_opts" \
        -c "SELECT 1;" > /dev/null 2>&1; then

        log_error "PostgreSQL authentication failed for database: $superset_db"
        log_error "Verify the database '$superset_db' exists on the database server"
        return 1
    fi
    log_success "PostgreSQL authentication OK for $superset_db"

    # Verify required extensions in platform database
    log_info "Verifying PostgreSQL extensions..."
    local extensions_check=$(docker run --rm --network host \
        -e PGPASSWORD="$password" \
        postgres:17-alpine \
        psql "postgresql://$user@$host:$port/$platform_db$conn_opts" \
        -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto');" 2>/dev/null | tr -d '[:space:]')

    if [[ "$extensions_check" != "2" ]]; then
        log_warning "Required PostgreSQL extensions may be missing"
        log_info "Attempting to create extensions (may require superuser)..."

        docker run --rm --network host \
            -e PGPASSWORD="$password" \
            postgres:17-alpine \
            psql "postgresql://$user@$host:$port/$platform_db$conn_opts" \
            -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"; CREATE EXTENSION IF NOT EXISTS pgcrypto;" 2>/dev/null || true

        # Re-check
        extensions_check=$(docker run --rm --network host \
            -e PGPASSWORD="$password" \
            postgres:17-alpine \
            psql "postgresql://$user@$host:$port/$platform_db$conn_opts" \
            -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('uuid-ossp', 'pgcrypto');" 2>/dev/null | tr -d '[:space:]')

        if [[ "$extensions_check" != "2" ]]; then
            log_warning "Could not create extensions. You may need to create them manually:"
            log_warning "  sudo -u postgres psql -d $platform_db -c \"CREATE EXTENSION IF NOT EXISTS uuid-ossp;\""
            log_warning "  sudo -u postgres psql -d $platform_db -c \"CREATE EXTENSION IF NOT EXISTS pgcrypto;\""
        else
            log_success "PostgreSQL extensions created successfully"
        fi
    else
        log_success "PostgreSQL extensions verified: uuid-ossp, pgcrypto"
    fi

    # SSL verification if enabled
    if [[ "$ssl_enabled" == "true" ]]; then
        log_info "Verifying SSL connection (mode: $ssl_mode)..."

        local ssl_result=$(docker run --rm --network host \
            -e PGPASSWORD="$password" \
            postgres:17-alpine \
            psql "postgresql://$user@$host:$port/$platform_db?sslmode=$ssl_mode" \
            -t -c "SHOW ssl;" 2>/dev/null | tr -d '[:space:]')

        if [[ "$ssl_result" == "on" ]]; then
            log_success "SSL connection verified (server SSL enabled)"
        else
            log_warning "SSL connection established but server may not have SSL fully configured"
        fi
    fi

    # Test write permissions
    log_info "Verifying write permissions..."
    local write_test=$(docker run --rm --network host \
        -e PGPASSWORD="$password" \
        postgres:17-alpine \
        psql "postgresql://$user@$host:$port/$platform_db$conn_opts" \
        -t -c "CREATE TABLE IF NOT EXISTS _pravaha_install_test (id int); DROP TABLE IF EXISTS _pravaha_install_test; SELECT 'ok';" 2>/dev/null | tr -d '[:space:]')

    if [[ "$write_test" != "ok" ]]; then
        log_error "User '$user' does not have write permissions on '$platform_db'"
        log_error "Grant permissions with: GRANT ALL ON DATABASE $platform_db TO $user;"
        return 1
    fi
    log_success "Write permissions verified"

    log_success "External database validation complete"
    log_info ""
    log_info "Database Configuration Summary:"
    log_info "  Host:        $host:$port"
    log_info "  User:        $user"
    log_info "  Platform DB: $platform_db"
    log_info "  Superset DB: $superset_db"
    log_info "  SSL:         ${ssl_enabled:-false} (mode: ${ssl_mode:-prefer})"

    return 0
}

# =============================================================================
# Network Connectivity Checks
# =============================================================================
check_network_connectivity() {
    log_info "Checking network connectivity..."

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
            log_warning "Cannot reach ghcr.io directly. Checking API..."
            if ! curl -s --max-time 10 --head https://ghcr.io &>/dev/null; then
                log_error "Cannot reach GitHub Container Registry (ghcr.io)."
                log_error "Check firewall settings or use --skip-pull with pre-loaded images."
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
            log_warning "Cannot reach Docker Hub. Checking alternative..."
            if ! curl -s --max-time 10 --head https://hub.docker.com &>/dev/null; then
                log_error "Cannot reach Docker Hub. Image pull will fail."
                return 1
            fi
        fi
        log_success "Docker Hub is reachable"
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
        return 0
    fi
}

# =============================================================================
# Domain Validation
# =============================================================================
validate_domain_format() {
    local domain=$1

    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        return 1
    fi

    if [[ "$domain" == *'|'* || "$domain" == *'&'* || "$domain" == *';'* || "$domain" == *'$'* || "$domain" == *'`'* || "$domain" == *'\'* ]]; then
        log_error "Domain contains invalid characters: $domain"
        return 1
    fi

    log_success "Domain format validated: $domain"
    return 0
}

# =============================================================================
# Pre-Deployment Validation Functions
# =============================================================================
validate_disk_space() {
    local min_gb=${1:-50}
    local deploy_dir=${2:-/opt/pravaha}

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

validate_memory() {
    local min_gb=${1:-16}

    log_info "Checking available memory (minimum ${min_gb}GB required)..."

    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_gb=$((total_kb / 1024 / 1024))

    if [[ $total_gb -lt $min_gb ]]; then
        log_warning "Memory below recommended: ${total_gb}GB available, ${min_gb}GB recommended"
    else
        log_success "Memory check passed: ${total_gb}GB available"
    fi
    return 0
}

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

validate_ports() {
    # Note: Only checking ports used by this app server (no PostgreSQL 5432)
    local ports=(80 443 6379)
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
    else
        log_success "All required ports are available"
    fi
    return 0
}

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

# =============================================================================
# Wait for Healthy Container
# =============================================================================
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

        if [[ $((i % 5)) -eq 0 ]]; then
            log_info "Still waiting for $container_name... (attempt $i/$max_attempts)"
        fi

        sleep $interval
    done

    log_error "$container_name did not become healthy within timeout"
    return 1
}

# =============================================================================
# Check Prerequisites
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

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

# =============================================================================
# Install Docker
# =============================================================================
install_docker() {
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        log_info "Docker is already installed: $(docker --version)"
        if ! systemctl is-active --quiet docker; then
            log_info "Starting Docker service..."
            systemctl start docker
        fi
        return
    fi

    log_info "Installing Docker..."

    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl start docker
    systemctl enable docker

    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi

    log_success "Docker installed successfully"
}

# =============================================================================
# Install Additional Tools
# =============================================================================
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

# =============================================================================
# Setup Firewall
# =============================================================================
setup_firewall() {
    log_info "Configuring firewall..."

    apt-get install -y ufw

    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    # Note: No 5432 needed - PostgreSQL is on external server

    ufw --force enable

    log_success "Firewall configured"
}

# =============================================================================
# Setup Deployment Directory
# =============================================================================
setup_deployment_dir() {
    local deploy_dir="/opt/pravaha"
    local script_dir="$(cd "$(dirname "$0")/.." && pwd)"

    log_info "Setting up deployment directory at $deploy_dir..."

    mkdir -p "$deploy_dir"
    mkdir -p "$deploy_dir/ssl"
    mkdir -p "$deploy_dir/ssl/postgres"
    mkdir -p "$deploy_dir/backups"
    mkdir -p "$deploy_dir/logs"
    mkdir -p "$deploy_dir/notebooks"

    if [[ "$script_dir" != "$deploy_dir" ]]; then
        log_info "Copying deployment files from $script_dir to $deploy_dir..."
        cp -r "$script_dir"/* "$deploy_dir/" 2>/dev/null || true
        cp "$script_dir"/.env* "$deploy_dir/" 2>/dev/null || true
        cp "$script_dir"/.docker* "$deploy_dir/" 2>/dev/null || true
    else
        log_info "Already running from $deploy_dir, skipping file copy."
    fi

    chmod +x "$deploy_dir/scripts/"*.sh 2>/dev/null || true

    log_success "Deployment directory created at $deploy_dir"
    echo "$deploy_dir"
}

# =============================================================================
# Generate Audit Keys
# =============================================================================
generate_audit_keys() {
    local deploy_dir=$1

    log_info "Generating audit signature keys..."

    local private_key="$deploy_dir/audit-private.pem"
    local public_key="$deploy_dir/audit-public.pem"

    if [[ -f "$private_key" && -f "$public_key" ]]; then
        log_warning "Audit keys already exist. Skipping generation."
        return
    fi

    openssl genrsa -out "$private_key" 2048 2>/dev/null
    openssl rsa -in "$private_key" -outform PEM -pubout -out "$public_key" 2>/dev/null

    chown 1001:1001 "$private_key" "$public_key"
    chmod 600 "$private_key"
    chmod 644 "$public_key"

    log_success "Audit signature keys generated"
}

# =============================================================================
# Generate Secrets
# =============================================================================
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

    # Generate unique secrets
    local jwt_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local superset_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local encryption_key=$(openssl rand -hex 16)
    local admin_password=$(openssl rand -base64 16 | tr -d '\n/+=')
    local grafana_password=$(openssl rand -base64 16 | tr -d '\n/+=')
    local ml_service_api_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local ml_service_hmac_secret=$(openssl rand -hex 32)
    local csrf_secret=$(openssl rand -base64 32 | tr -d '\n/+=')
    local session_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local jupyter_token=$(openssl rand -hex 32)
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

    # ELK Stack secrets
    local elastic_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_system_password=$(openssl rand -base64 24 | tr -d '\n/+=')
    local kibana_encryption_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_reporting_key=$(openssl rand -base64 32 | tr -d '\n/+=')
    local kibana_security_key=$(openssl rand -base64 32 | tr -d '\n/+=')

    # Super Admin secrets (Section 17)
    local super_admin_jwt_secret=$(openssl rand -base64 48 | tr -d '\n/+=')
    local super_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    # Replace JWT_SECRET and SUPERSET_SECRET_KEY using line-anchored patterns
    sed -i "s|^JWT_SECRET=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|JWT_SECRET=$jwt_secret|" "$env_file"
    sed -i "s|^SUPERSET_SECRET_KEY=CHANGE_ME_GENERATE_SECURE_64_CHAR_SECRET|SUPERSET_SECRET_KEY=$superset_secret|" "$env_file"
    sed -i "s|CHANGE_ME_32_CHAR_HEX|$encryption_key|g" "$env_file"
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
    sed -i "s|^SESSION_SECRET=$|SESSION_SECRET=$session_secret|" "$env_file"
    sed -i "s|^INTERNAL_SERVICE_KEY=CHANGE_ME_GENERATE_INTERNAL_SERVICE_KEY|INTERNAL_SERVICE_KEY=$internal_service_key|" "$env_file"

    # Generate platform admin credentials
    local platform_admin_email="admin@${domain:-example.com}"
    local platform_admin_password=$(openssl rand -base64 18 | tr -d '\n/+=')

    sed -i "s|^ADMIN_EMAIL=admin@example.com|ADMIN_EMAIL=$platform_admin_email|" "$env_file"
    sed -i "s|^ADMIN_PASSWORD=CHANGE_ME_ADMIN_PASSWORD|ADMIN_PASSWORD=$platform_admin_password|" "$env_file"

    # Update SUPERSET_ADMIN_EMAIL to match platform admin (not admin@example.com)
    sed -i "s|^SUPERSET_ADMIN_EMAIL=admin@example.com|SUPERSET_ADMIN_EMAIL=$platform_admin_email|" "$env_file"

    # Replace other placeholders
    sed -i "s|CHANGE_ME_ADMIN_PASSWORD|$admin_password|g" "$env_file"
    sed -i "s|CHANGE_ME_GRAFANA_PASSWORD|$grafana_password|g" "$env_file"

    # Generate and replace GRAFANA_SECRET_KEY
    local grafana_secret_key=$(openssl rand -base64 24 | tr -d '\n/+=')
    sed -i "s|^GRAFANA_SECRET_KEY=CHANGE_ME_32_CHAR_SECRET_KEY|GRAFANA_SECRET_KEY=$grafana_secret_key|" "$env_file"

    # Store credentials for display
    echo "$platform_admin_email" > "$1/.admin_email"
    echo "$platform_admin_password" > "$1/.admin_password"
    chmod 600 "$1/.admin_email" "$1/.admin_password"

    sed -i "s|CHANGE_ME_GENERATE_SECURE_API_KEY|$ml_service_api_key|g" "$env_file"
    sed -i "s|CHANGE_ME_GENERATE_SECURE_SECRET|$csrf_secret|g" "$env_file"
    sed -i "s|CHANGE_ME_JUPYTER_TOKEN|$jupyter_token|g" "$env_file"

    # ELK Stack secrets
    sed -i "s|^ELASTIC_PASSWORD=CHANGE_ME_ELASTIC_PASSWORD|ELASTIC_PASSWORD=$elastic_password|" "$env_file"
    sed -i "s|^KIBANA_SYSTEM_PASSWORD=CHANGE_ME_KIBANA_PASSWORD|KIBANA_SYSTEM_PASSWORD=$kibana_system_password|" "$env_file"
    sed -i "s|^KIBANA_ENCRYPTION_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_ENCRYPTION|KIBANA_ENCRYPTION_KEY=$kibana_encryption_key|" "$env_file"
    sed -i "s|^KIBANA_REPORTING_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_REPORTING|KIBANA_REPORTING_KEY=$kibana_reporting_key|" "$env_file"
    sed -i "s|^KIBANA_SECURITY_KEY=CHANGE_ME_32_OR_MORE_CHARACTERS_KEY_SECURITY|KIBANA_SECURITY_KEY=$kibana_security_key|" "$env_file"

    # Super Admin secrets (Section 17)
    sed -i "s|^SUPER_ADMIN_JWT_SECRET=CHANGE_ME_GENERATE_SUPER_ADMIN_JWT_SECRET|SUPER_ADMIN_JWT_SECRET=$super_admin_jwt_secret|" "$env_file"
    sed -i "s|^SUPER_ADMIN_DEFAULT_PASSWORD=CHANGE_ME_SUPER_ADMIN_PASSWORD|SUPER_ADMIN_DEFAULT_PASSWORD=$super_admin_password|" "$env_file"

    # ML Credential Encryption Key
    sed -i "s|^ML_CREDENTIAL_ENCRYPTION_KEY=CHANGE_ME_GENERATE_FERNET_KEY|ML_CREDENTIAL_ENCRYPTION_KEY=$ml_credential_encryption_key|" "$env_file"

    # NOTE: We do NOT generate POSTGRES_PASSWORD here - it must be configured manually
    # for the external database server

    log_success "Secrets generated. Please configure POSTGRES_HOST and POSTGRES_PASSWORD in $env_file"
}

# =============================================================================
# Setup SSL
# =============================================================================
setup_letsencrypt() {
    local domain=$1
    local email=$2
    local deploy_dir=$3

    log_info "Setting up Let's Encrypt SSL for $domain..."

    docker compose -f "$deploy_dir/docker-compose.yml" stop nginx 2>/dev/null || true

    certbot certonly --standalone \
        -d "$domain" \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive

    cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$deploy_dir/ssl/"
    cp "/etc/letsencrypt/live/$domain/privkey.pem" "$deploy_dir/ssl/"

    cat > /etc/cron.d/certbot-renewal << EOF
0 0,12 * * * root certbot renew --quiet --pre-hook "docker compose -f $deploy_dir/docker-compose.yml stop nginx || true" --post-hook "cp /etc/letsencrypt/live/$domain/*.pem $deploy_dir/ssl/ && docker compose -f $deploy_dir/docker-compose.yml start nginx"
EOF

    log_success "SSL certificate obtained and auto-renewal configured"
}

setup_selfsigned_ssl() {
    local domain=$1
    local deploy_dir=$2

    log_info "Generating self-signed SSL certificate for $domain..."

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
keyUsage = digitalSignature, keyEncipherment
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

# =============================================================================
# Authenticate with Container Registry
# =============================================================================
authenticate_registry() {
    local deploy_dir=$1
    local registry=""
    local image_prefix=""

    # Source .env to get registry configuration
    if [[ -f "$deploy_dir/.env" ]]; then
        registry=$(grep "^REGISTRY=" "$deploy_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    registry="${registry:-ghcr.io/talentfino/pravaha}"

    # Read image prefix from .env
    if [[ -f "$deploy_dir/.env" ]]; then
        image_prefix=$(grep "^IMAGE_PREFIX=" "$deploy_dir/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi

    log_info "Authenticating with container registry: $registry"

    # Determine registry type and authenticate accordingly
    if [[ "$registry" == ghcr.io/* ]]; then
        # GitHub Container Registry
        if [[ -n "${GHCR_TOKEN:-}" ]] && [[ -n "${GHCR_USERNAME:-}" ]]; then
            log_info "Logging into GitHub Container Registry..."
            if echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin; then
                log_success "GHCR authentication successful"
                return 0
            else
                log_warning "GHCR login failed with provided credentials"
            fi
        fi

        # Check if already logged in by attempting a test pull
        if docker pull "${registry}/${image_prefix}frontend:latest" --quiet 2>/dev/null; then
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
        if [[ -n "${DOCKER_PASSWORD:-}" ]] && [[ -n "${DOCKER_USERNAME:-}" ]]; then
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
            log_info "  export DOCKER_USERNAME=<your-dockerhub-username>"
            log_info "  export DOCKER_PASSWORD=<your-access-token>"
        fi
    fi

    return 0  # Continue even if authentication fails (may work with public images)
}

# =============================================================================
# Pull Docker Images
# =============================================================================
pull_images() {
    local deploy_dir=$1

    log_info "Pulling Docker images..."

    cd "$deploy_dir"

    # Authenticate with the configured registry
    authenticate_registry "$deploy_dir"

    # Pull images with retry logic (network can be flaky)
    if ! retry_with_backoff 3 5 60 docker compose pull; then
        log_error "Failed to pull Docker images after multiple attempts"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Check network connectivity: curl -s https://ghcr.io/v2/"
        log_error "  2. Verify registry access: docker pull ${registry}/${image_prefix}frontend:latest"
        log_error "  3. Check GHCR authentication (private repos require a PAT with read:packages)"
        log_error "  4. Set credentials before running install.sh:"
        log_error "     export GHCR_USERNAME=<github-username>"
        log_error "     export GHCR_TOKEN=<github-pat>"
        log_error ""
        log_error "You can retry later with: cd $deploy_dir && docker compose pull"
        return 1
    fi

    log_success "Docker images pulled"
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

# =============================================================================
# Start Services
# =============================================================================
start_services() {
    local deploy_dir=$1

    log_info "Starting all services..."

    cd "$deploy_dir"
    docker compose up -d

    log_info "Waiting for services to be healthy..."

    # Wait for core services (no postgres - using external)
    local services=("pravaha-redis" "pravaha-backend" "pravaha-frontend" "pravaha-jupyter" "pravaha-nginx")
    local failed=0

    for service in "${services[@]}"; do
        # Determine timeout per service type
        local max_attempts=60
        case "$service" in
            *ml-service*) max_attempts=72 ;;
            *superset*)   max_attempts=42 ;;
            *backend*)    max_attempts=24 ;;
            *celery*)     max_attempts=18 ;;
            *jupyter*)    max_attempts=12 ;;
            *)            max_attempts=12 ;;
        esac

        if ! wait_for_healthy "$service" "$max_attempts" 5; then
            # Celery workers may not have health checks — check if at least running
            case "$service" in
                *celery*)
                    if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                        log_warning "$service is running (health check inconclusive)"
                    else
                        log_warning "$service did not become healthy"
                        failed=1
                    fi
                    ;;
                *)
                    log_warning "$service did not become healthy"
                    failed=1
                    ;;
            esac
        fi
    done

    docker compose ps

    if [[ $failed -eq 0 ]]; then
        log_success "All services started and healthy"
    else
        log_warning "Some services may need attention - check 'docker compose logs'"
    fi
}

# =============================================================================
# Run Database Migrations
# =============================================================================
run_database_migrations() {
    local deploy_dir=$1

    log_info "Running database migrations on external PostgreSQL..."

    cd "$deploy_dir"

    # Run Prisma migrations via backend container
    log_info "Running Prisma migrations..."
    if docker compose exec -T backend npx prisma migrate deploy 2>/dev/null; then
        log_success "Prisma migrations completed"
    else
        log_warning "Prisma migrations may have already been applied or encountered an issue"
    fi

    # Seed database if needed
    log_info "Checking if database seeding is needed..."
    if docker compose exec -T backend npx prisma db seed 2>/dev/null; then
        log_success "Database seeding completed"
    else
        log_warning "Database seeding may have already been applied"
    fi
}

# =============================================================================
# Generate After-Deployment Documentation
# =============================================================================
generate_after_deployment_doc() {
    local domain=$1
    local deploy_dir=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local doc_file="$deploy_dir/after-deployment.md"

    log_info "Generating after-deployment.md..."

    cat > "$doc_file" << EOF
# After Deployment Checklist - Two-Server (App Server)

**Deployment Date:** $timestamp
**Domain:** $domain
**Deployment Directory:** $deploy_dir
**Deployment Type:** Two-Server (App Server + External Database)

---

## Architecture Overview

\`\`\`
App Server (this)              Database Server (external)
+------------------+           +------------------+
| nginx            |           | PostgreSQL 17    |
| frontend         |   TCP     |   autoanalytics  |
| backend      ----+--5432---->|   superset       |
| superset         |           |                  |
| ml-service       |           +------------------+
| celery workers   |
| redis            |
+------------------+
\`\`\`

---

## Immediate Verification

Run these commands to verify all services are healthy:

\`\`\`bash
cd $deploy_dir
docker compose ps

# Test health endpoints
curl -k https://$domain/health
curl -k https://$domain/api/v1/health
curl -k https://$domain/ml/api/v1/health

# Validate external database connection
./scripts/validate-external-db.sh
\`\`\`

---

## External Database Connection

**Database Server:** Check .env for POSTGRES_HOST
**Platform Database:** autoanalytics
**Superset Database:** superset

To verify database connectivity:
\`\`\`bash
docker compose exec backend npx prisma db pull
\`\`\`

---

## Login Verification

- [ ] Access https://$domain in browser
- [ ] Login with generated admin credentials:
  - **Email:** See \`.admin_email\` file
  - **Password:** See \`.admin_password\` file
- [ ] Change admin password immediately after first login
- [ ] Delete credential files: \`rm $deploy_dir/.admin_email $deploy_dir/.admin_password\`

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

# Validate external DB
./scripts/validate-external-db.sh

# Health check
./scripts/health-check.sh
\`\`\`

---

*Generated by Pravaha Platform Two-Server App Installer*
EOF

    log_success "after-deployment.md generated at $doc_file"
}

# =============================================================================
# Print Completion Message
# =============================================================================
print_completion() {
    local domain=$1
    local deploy_dir=$2

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
    echo "Deployment Type: Two-Server (App Server)"
    echo "Access your platform at: https://$domain"
    echo ""
    echo "Platform Admin Credentials (auto-generated):"
    echo "  Email:    $admin_email"
    echo "  Password: $admin_password"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely and change the password after first login!${NC}"
    echo ""
    echo "External Database:"
    echo "  Check .env for POSTGRES_HOST and connection details"
    echo ""
    echo "Useful commands:"
    echo "  - View logs: docker compose logs -f"
    echo "  - Stop services: docker compose down"
    echo "  - Start services: docker compose up -d"
    echo "  - Check status: docker compose ps"
    echo "  - Validate DB: ./scripts/validate-external-db.sh"
    echo ""
    echo "Configuration: $deploy_dir/.env"
    echo "After deployment: $deploy_dir/after-deployment.md"
    echo ""
}

# =============================================================================
# Initialize Audit Log
# =============================================================================
init_audit_log() {
    local deploy_dir=$1

    mkdir -p "$deploy_dir/logs"
    mkdir -p "$deploy_dir/notebooks"
    INSTALL_LOG="$deploy_dir/logs/install_$(date +%Y%m%d_%H%M%S).log"
    STATE_FILE="$deploy_dir/.install_state"

    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"

    cat >> "$INSTALL_LOG" << EOF
================================================================================
PRAVAHA PLATFORM - TWO-SERVER APP INSTALLATION LOG
================================================================================
Timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
Installer:    ${SUDO_USER:-root}
Hostname:     $(hostname)
OS:           $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)
Script:       $0
Version:      $SCRIPT_VERSION
Arguments:    $ORIGINAL_ARGS
Working Dir:  $(pwd)
Deployment:   Two-Server (App Server - External PostgreSQL)
================================================================================

EOF
}

# =============================================================================
# Check Existing Installation
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
                log_info "Installation cancelled."
                exit 0
            fi
        fi
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^pravaha-"; then
        log_warning "Found existing Pravaha containers"
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
# Main Installation Function
# =============================================================================
main() {
    echo "=============================================="
    echo "Pravaha Platform - Two-Server App Installation"
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
                echo "Usage: $0 --domain <domain> [options]"
                echo ""
                echo "Two-Server Deployment: App server connects to external PostgreSQL"
                echo ""
                echo "Required:"
                echo "  --domain     Your domain name (e.g., analytics.example.com)"
                echo ""
                echo "Options:"
                echo "  --email      Email for Let's Encrypt notifications"
                echo "  --ssl        SSL type: letsencrypt (default) or selfsigned"
                echo "  --skip-ssl   Skip SSL certificate generation"
                echo "  --skip-pull  Skip docker compose pull"
                echo "  --resume     Resume a failed installation"
                echo "  --force      Force reinstallation without prompts"
                echo "  --dry-run    Preview installation steps"
                echo "  --verbose    Show detailed output"
                echo ""
                echo "Prerequisites:"
                echo "  1. External PostgreSQL server with databases: autoanalytics, superset"
                echo "  2. Configure POSTGRES_HOST and POSTGRES_PASSWORD in .env"
                echo ""
                echo "Examples:"
                echo "  $0 --domain analytics.example.com --ssl selfsigned"
                echo "  $0 --domain analytics.example.com --resume"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$domain" ]]; then
        read -p "Enter your domain (e.g., analytics.example.com): " domain
    fi

    if ! validate_domain_format "$domain"; then
        exit 1
    fi

    # Initialize audit logging
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
            exit 0
        else
            log_info "Resuming installation from checkpoint: $checkpoint"
            if [[ -f "$STATE_FILE" ]]; then
                local saved_domain=$(grep -o '"domain": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
                local saved_ssl=$(grep -o '"ssl_type": "[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
                [[ -n "$saved_domain" && -z "$domain" ]] && domain="$saved_domain"
                [[ -n "$saved_ssl" ]] && ssl_type="$saved_ssl"
            fi
        fi
    fi

    check_existing_installation "$DEPLOY_DIR" "$force"

    # SSL setup prompts
    if [[ "$skip_ssl" != "true" && "$force" != "true" ]]; then
        echo ""
        log_info "SSL Certificate Setup"
        read -p "Do you want to skip SSL certificate generation? [y/N]: " skip_ssl_input
        if [[ "$skip_ssl_input" =~ ^[Yy]$ ]]; then
            skip_ssl="true"
        fi
    fi

    if [[ "$skip_ssl" != "true" && -z "$email" && "$ssl_type" == "letsencrypt" && "$force" != "true" ]]; then
        read -p "Enter your email for SSL certificate notifications: " email
    fi

    # Display configuration summary
    echo ""
    log_info "=============================================="
    log_info "Two-Server App Installation Configuration:"
    log_info "  Domain:       $domain"
    log_info "  SSL Type:     $ssl_type"
    log_info "  Skip SSL:     $skip_ssl"
    log_info "  Skip Pull:    $skip_pull"
    log_info "  Resume:       $resume"
    log_info "  Force:        $force"
    log_info "=============================================="
    log_info ""
    log_info "NOTE: External PostgreSQL Required"
    log_info "Configure POSTGRES_HOST in .env before proceeding"
    log_info "=============================================="
    echo ""

    # =========================================================================
    # STEP 1: Pre-flight checks
    # =========================================================================
    if ! should_skip_step "preflight" || [[ "$resume" != "true" ]]; then
        log_step "Running pre-flight checks..."
        save_checkpoint "preflight" "in_progress"

        run_pre_deployment_checks "$DEPLOY_DIR"

        if [[ "$skip_pull" != "true" ]]; then
            check_network_connectivity || exit 1
        fi

        check_domain_dns "$domain"

        save_checkpoint "preflight" "completed"
        log_success "Pre-flight checks completed"
    fi

    # =========================================================================
    # STEP 2: Install Docker
    # =========================================================================
    if ! should_skip_step "docker_install" || [[ "$resume" != "true" ]]; then
        log_step "Installing Docker..."
        save_checkpoint "docker_install" "in_progress"
        install_docker
        save_checkpoint "docker_install" "completed"
    fi

    # =========================================================================
    # STEP 3: Install additional tools
    # =========================================================================
    if ! should_skip_step "tools_install" || [[ "$resume" != "true" ]]; then
        log_step "Installing additional tools..."
        save_checkpoint "tools_install" "in_progress"
        install_tools
        save_checkpoint "tools_install" "completed"
    fi

    # =========================================================================
    # STEP 4: Setup firewall
    # =========================================================================
    if ! should_skip_step "firewall_setup" || [[ "$resume" != "true" ]]; then
        log_step "Configuring firewall..."
        save_checkpoint "firewall_setup" "in_progress"
        setup_firewall
        save_checkpoint "firewall_setup" "completed"
    fi

    # =========================================================================
    # STEP 5: Setup deployment directory
    # =========================================================================
    if ! should_skip_step "directory_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up deployment directory..."
        save_checkpoint "directory_setup" "in_progress"
        deploy_dir=$(setup_deployment_dir)
        save_checkpoint "directory_setup" "completed"
    else
        deploy_dir="$DEPLOY_DIR"
    fi

    # =========================================================================
    # STEP 6: Generate NGINX configuration
    # =========================================================================
    if ! should_skip_step "nginx_config" || [[ "$resume" != "true" ]]; then
        log_step "Generating NGINX configuration..."
        save_checkpoint "nginx_config" "in_progress"

        local nginx_script="$deploy_dir/scripts/generate-nginx-config.sh"
        if [[ -f "$nginx_script" ]]; then
            chmod +x "$nginx_script"
            DOMAIN="$domain" bash "$nginx_script"
        else
            log_warning "NGINX config script not found, using template directly"
            mkdir -p "$deploy_dir/nginx/conf.d"
            if [[ -f "$deploy_dir/nginx/conf.d/pravaha.conf.template" ]]; then
                MAX_UPLOAD_SIZE_MB="${MAX_UPLOAD_SIZE_MB:-500}"
                export MAX_UPLOAD_SIZE_MB
                envsubst '${DOMAIN} ${MAX_UPLOAD_SIZE_MB}' < "$deploy_dir/nginx/conf.d/pravaha.conf.template" > "$deploy_dir/nginx/conf.d/pravaha.conf"
            fi
        fi

        save_checkpoint "nginx_config" "completed"
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

        save_checkpoint "secrets_generation" "completed"
    fi

    # =========================================================================
    # STEP 8: Generate audit keys
    # =========================================================================
    if ! should_skip_step "audit_keys" || [[ "$resume" != "true" ]]; then
        log_step "Generating audit signature keys..."
        save_checkpoint "audit_keys" "in_progress"
        generate_audit_keys "$deploy_dir"
        save_checkpoint "audit_keys" "completed"
    fi

    # =========================================================================
    # STEP 9: Setup SSL
    # =========================================================================
    if ! should_skip_step "ssl_setup" || [[ "$resume" != "true" ]]; then
        log_step "Setting up SSL certificates..."
        save_checkpoint "ssl_setup" "in_progress"

        if [[ "$skip_ssl" == "true" ]]; then
            if [[ -f "$deploy_dir/ssl/fullchain.pem" && -f "$deploy_dir/ssl/privkey.pem" ]]; then
                log_success "SSL certificates found"
            else
                log_warning "SSL certificates not found in $deploy_dir/ssl/"
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
    fi

    # =========================================================================
    # STEP 10: Pull Docker images
    # =========================================================================
    if ! should_skip_step "image_pull" || [[ "$resume" != "true" ]]; then
        log_step "Pulling Docker images..."
        save_checkpoint "image_pull" "in_progress"

        if [[ "$skip_pull" == "true" ]]; then
            log_info "Skipping docker compose pull"
        else
            pull_images "$deploy_dir" || exit 1
        fi

        save_checkpoint "image_pull" "completed"
    fi

    # =========================================================================
    # STEP 11: Validate External Database (KEY STEP FOR TWO-SERVER)
    # =========================================================================
    if ! should_skip_step "external_db_validation" || [[ "$resume" != "true" ]]; then
        log_step "Validating external PostgreSQL database..."
        save_checkpoint "external_db_validation" "in_progress"

        echo ""
        log_info "=============================================="
        log_info "IMPORTANT: External Database Configuration"
        log_info "=============================================="
        log_info ""
        log_info "Before proceeding, ensure you have configured:"
        log_info "  1. POSTGRES_HOST in .env"
        log_info "  2. POSTGRES_PASSWORD in .env"
        log_info "  3. Databases created: autoanalytics, superset"
        log_info ""

        if [[ "$force" != "true" ]]; then
            read -p "Have you configured the external database? (y/N): " db_configured
            if [[ ! "$db_configured" =~ ^[Yy]$ ]]; then
                log_info "Please configure the external database in $deploy_dir/.env"
                log_info "Then run: sudo $0 --domain $domain --resume"
                save_checkpoint "external_db_validation" "paused"
                exit 0
            fi
        fi

        if ! validate_external_database; then
            log_error "External database validation failed"
            log_error "Please fix the database configuration and run with --resume"
            exit 1
        fi

        save_checkpoint "external_db_validation" "completed"
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
    fi

    # =========================================================================
    # STEP 13: Run database migrations
    # =========================================================================
    if ! should_skip_step "database_migrations" || [[ "$resume" != "true" ]]; then
        log_step "Running database migrations..."
        save_checkpoint "database_migrations" "in_progress"
        run_database_migrations "$deploy_dir"
        save_checkpoint "database_migrations" "completed"
    fi

    # =========================================================================
    # STEP 14: Verification
    # =========================================================================
    log_step "Running post-installation verification..."
    save_checkpoint "verification" "in_progress"

    # Ensure environment is loaded (may not be if --resume skipped init_database)
    set -a
    source "$DEPLOY_DIR/.env" 2>/dev/null || true
    set +a

    local verification_failed=0

    # Check services
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
        log_success "NGINX health check passed"
    else
        log_warning "NGINX health check failed"
        verification_failed=1
    fi

    # Check Backend
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

    # Check Redis
    if docker exec pravaha-redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis health check passed"
    else
        log_warning "Redis health check failed"
        verification_failed=1
    fi

    # Check Jupyter (non-critical - platform works without it)
    local jupyter_healthy=false
    for i in {1..6}; do
        if docker exec pravaha-jupyter sh -c 'curl -sf "http://localhost:8888/api/status?token=$JUPYTER_TOKEN"' 2>/dev/null; then
            jupyter_healthy=true
            break
        fi
        log_info "Waiting for Jupyter... (attempt $i/6)"
        sleep 5
    done

    if [[ "$jupyter_healthy" == "true" ]]; then
        log_success "Jupyter Notebook health check passed"
    else
        log_warning "Jupyter Notebook health check failed (non-critical)"
    fi

    save_checkpoint "verification" "completed"

    # =========================================================================
    # COMPLETE
    # =========================================================================
    save_checkpoint "complete" "completed"

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$deploy_dir/.installed"

    generate_after_deployment_doc "$domain" "$deploy_dir"

    CLEANUP_ON_EXIT=false

    # Display comprehensive credential summary
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cred_summary_script="$script_dir/../../../scripts/print-credential-summary.sh"
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
