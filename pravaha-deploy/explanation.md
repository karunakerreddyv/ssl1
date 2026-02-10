# Single-Server Deployment - Complete Guide

This document explains every aspect of deploying the Pravaha Platform on a single server. It is written for someone new to deployments and covers everything from basic concepts to advanced troubleshooting.

---

## Table of Contents

1. [What is Single-Server Deployment?](#1-what-is-single-server-deployment)
2. [Prerequisites](#2-prerequisites)
3. [Architecture Overview](#3-architecture-overview)
4. [Directory Structure](#4-directory-structure)
5. [File-by-File Explanation](#5-file-by-file-explanation)
6. [The Installation Script (install.sh)](#6-the-installation-script-installsh)
7. [SSL Certificate Options](#7-ssl-certificate-options)
8. [Docker Compose Services](#8-docker-compose-services)
9. [Environment Variables](#9-environment-variables)
10. [NGINX Configuration](#10-nginx-configuration)
11. [Health Checks](#11-health-checks)
12. [CI/CD Pipeline](#12-cicd-pipeline)
13. [Running the Deployment](#13-running-the-deployment)
14. [Post-Deployment Steps](#14-post-deployment-steps)
15. [Backup and Restore](#15-backup-and-restore)
16. [Updates and Rollback](#16-updates-and-rollback)
17. [Troubleshooting](#17-troubleshooting)
18. [Common Commands Reference](#18-common-commands-reference)

---

## 1. What is Single-Server Deployment?

Single-server deployment means running all components of the Pravaha Platform on one physical or virtual machine. This includes:

- **Frontend**: The web interface users interact with (React application)
- **Backend**: The API server that handles business logic (Node.js/TypeScript)
- **Database**: Where all data is stored (PostgreSQL)
- **Cache**: For fast data access and session storage (Redis)
- **ML Service**: Machine learning model training and predictions (Python/FastAPI)
- **Task Queue**: Background job processing (Celery workers)
- **BI Tool**: Business intelligence dashboards (Apache Superset)
- **Reverse Proxy**: Routes traffic and handles SSL (NGINX)

### When to Use Single-Server Deployment

| Scenario | Recommended? |
|----------|--------------|
| Development/Testing | Yes |
| Small teams (< 50 users) | Yes |
| Proof of Concept | Yes |
| Medium teams (50-200 users) | Maybe (monitor resources) |
| Large enterprises (200+ users) | No (use scaled deployment) |
| High availability required | No (use scaled deployment) |

### Advantages

- Simple to set up and maintain
- Lower infrastructure cost
- Easier troubleshooting (everything in one place)
- Good for getting started quickly

### Disadvantages

- Single point of failure
- Limited scalability
- Resource contention between services
- No high availability

---

## 2. Prerequisites

### Hardware Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| CPU | 8 cores | 16 cores | ML training is CPU-intensive |
| RAM | 16 GB | 32 GB | Each service needs memory |
| Disk | 50 GB SSD | 100+ GB SSD | SSD required for database performance |
| Network | 100 Mbps | 1 Gbps | For image pulls and user traffic |

### Software Requirements

| Software | Version | Notes |
|----------|---------|-------|
| Operating System | Ubuntu 22.04 LTS | Other Linux distros may work but are untested |
| Docker | 24.0+ | Will be installed by the script if missing |
| Docker Compose | v2.0+ | Comes with Docker Desktop or docker-compose-plugin |

### Network Requirements

| Port | Protocol | Purpose | Required? |
|------|----------|---------|-----------|
| 22 | TCP | SSH access for administration | Yes |
| 80 | TCP | HTTP (redirects to HTTPS) | Yes |
| 443 | TCP | HTTPS (main application) | Yes |
| 5432 | TCP | PostgreSQL (internal only) | No (not exposed) |
| 6379 | TCP | Redis (internal only) | No (not exposed) |

### Domain and DNS

You need a domain name pointing to your server's IP address. For example:
- Domain: `pravaha.yourcompany.com`
- DNS A Record: `pravaha.yourcompany.com` → `203.0.113.50` (your server IP)

To verify DNS is set up correctly:
```bash
# Check if domain resolves to your server
nslookup pravaha.yourcompany.com

# Or using dig
dig pravaha.yourcompany.com +short
```

---

## 3. Architecture Overview

### Visual Diagram

```
                                 INTERNET
                                     │
                                     │ HTTPS (:443)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              NGINX (Reverse Proxy)                          │
│  • SSL/TLS termination          • Rate limiting                             │
│  • Request routing              • Security headers                          │
│  • Static file caching          • WebSocket support                         │
└─────────────────────────────────────────────────────────────────────────────┘
         │              │              │              │              │
         ▼              ▼              ▼              ▼              ▼
    ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
    │Frontend │   │ Backend  │   │ Superset │   │ML Service│   │ Grafana  │
    │  :80    │   │  :3000   │   │  :8088   │   │  :8001   │   │  :3000   │
    │ (React) │   │ (Node.js)│   │ (Python) │   │(FastAPI) │   │(optional)│
    └─────────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘   └──────────┘
                       │              │              │
                       └──────────────┼──────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
              ┌──────────┐      ┌──────────┐     ┌─────────────────┐
              │PostgreSQL│      │  Redis   │     │  Celery Workers │
              │  :5432   │      │  :6379   │     │ (3 task queues) │
              │(Database)│      │ (Cache)  │     │  - training     │
              └──────────┘      └──────────┘     │  - prediction   │
                                                 │  - monitoring   │
                                                 └─────────────────┘
```

### Data Flow

1. **User Request**: User opens `https://pravaha.yourcompany.com` in browser
2. **NGINX**: Receives request, terminates SSL, routes to appropriate service
3. **Frontend**: Serves the React application (HTML, CSS, JavaScript)
4. **API Call**: Frontend makes API call to `/api/*`
5. **NGINX**: Routes `/api/*` requests to Backend service
6. **Backend**: Processes request, queries database, returns response
7. **Database**: PostgreSQL stores and retrieves data
8. **Cache**: Redis caches frequently accessed data for speed
9. **ML Service**: Handles model training and predictions when requested
10. **Celery**: Processes long-running tasks in background

---

## 4. Directory Structure

When deployed, the following structure is created at `/opt/pravaha/`:

```
/opt/pravaha/
│
├── docker-compose.yml              # Main file defining all services
├── docker-compose.build.yml        # For building images locally (optional)
├── docker-compose.jupyter.yml      # Jupyter notebook service (optional)
├── docker-compose.elk.yml          # ELK logging stack (optional)
├── docker-compose.logging.yml      # Grafana/Loki logging (optional)
│
├── .env                            # Runtime configuration (auto-generated)
├── .env.example                    # Template with all available options
│
├── .installed                      # Marker file indicating successful install
├── .admin_email                    # Temporary file with admin email
├── .admin_password                 # Temporary file with admin password
│
├── audit-private.pem               # RSA private key for audit signatures
├── audit-public.pem                # RSA public key for audit verification
│
├── nginx/
│   ├── nginx.conf                  # Main NGINX configuration
│   └── conf.d/
│       ├── pravaha.conf.template   # Site config template (with ${DOMAIN})
│       └── pravaha.conf            # Generated site config (actual domain)
│
├── ssl/
│   ├── fullchain.pem               # SSL certificate + intermediate chain
│   └── privkey.pem                 # SSL private key
│
├── scripts/
│   ├── install.sh                  # Main installation script
│   ├── health-check.sh             # Verify all services are running
│   ├── backup.sh                   # Create database and config backups
│   ├── restore.sh                  # Restore from a backup
│   ├── update.sh                   # Update to a new version
│   ├── rollback.sh                 # Revert to previous version
│   ├── generate-nginx-config.sh    # Regenerate NGINX config
│   ├── generate-self-signed-ssl.sh # Generate self-signed certificate
│   ├── check-ssl-expiry.sh         # Check SSL certificate expiration
│   ├── verify-backup.sh            # Validate backup integrity
│   ├── setup-automated-backups.sh  # Configure automatic daily backups
│   └── init-databases.sql          # SQL to create databases on first run
│
├── elk/                            # ELK stack configuration (optional)
│   ├── elasticsearch.yml
│   ├── logstash.conf
│   └── kibana.yml
│
├── logging/                        # Grafana/Loki configuration (optional)
│   ├── grafana/
│   └── loki/
│
├── backups/                        # Backup storage directory
│   └── backup_2024-01-15_020000.tar.gz
│
├── logs/                           # Application logs
│   └── install_2024-01-15_100000.log
│
└── .checkpoint/                    # Installation state for resume capability
    └── state.json
```

---

## 5. File-by-File Explanation

### Core Files

#### `docker-compose.yml`

This is the heart of the deployment. It defines:
- What containers (services) to run
- How they connect to each other
- Resource limits (CPU, memory)
- Health checks
- Volume mounts (persistent storage)
- Environment variables

Example service definition:
```yaml
backend:
  image: ${REGISTRY:-ghcr.io/talentfino/pravaha}/${IMAGE_PREFIX:-}backend:${IMAGE_TAG:-latest}
  container_name: pravaha-backend
  restart: unless-stopped
  depends_on:
    postgres:
      condition: service_healthy    # Wait for database to be ready
    redis:
      condition: service_healthy    # Wait for cache to be ready
  environment:
    - DATABASE_URL=${DATABASE_URL}
    - REDIS_URL=${REDIS_URL}
    - JWT_SECRET=${JWT_SECRET}
  healthcheck:
    test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000/health/live"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 30s
  deploy:
    resources:
      limits:
        cpus: '2'
        memory: 2G
```

#### `.env.example` and `.env`

`.env.example` is a template containing all possible configuration options with placeholder values. During installation, it's copied to `.env` and the placeholders are replaced with actual values.

Key sections:
- **Deployment Config**: Domain, URLs, admin credentials
- **Database Config**: PostgreSQL connection details
- **Redis Config**: Cache connection details
- **Security Secrets**: JWT keys, encryption keys
- **Service Config**: Ports, worker counts, timeouts

#### `nginx/nginx.conf`

Main NGINX configuration defining:
- Worker processes and connections
- Logging format
- Compression settings
- Rate limiting zones
- Upstream server definitions
- Proxy cache settings

#### `nginx/conf.d/pravaha.conf.template`

Site-specific configuration template. The `${DOMAIN}` placeholder is replaced with your actual domain during installation.

Defines:
- HTTP to HTTPS redirect
- SSL certificate paths
- Security headers
- Route mappings (which URL goes to which service)
- WebSocket configuration
- Caching rules

### Scripts

#### `scripts/install.sh`

The main installation orchestrator. See [Section 6](#6-the-installation-script-installsh) for detailed explanation.

#### `scripts/health-check.sh`

Verifies all services are running correctly:
```bash
# Quick check
./scripts/health-check.sh --quick

# Full check with details
./scripts/health-check.sh

# JSON output for automation
./scripts/health-check.sh --json
```

#### `scripts/backup.sh`

Creates backups of the database and configuration:
```bash
# Standard backup (database + .env)
./scripts/backup.sh

# Database only
./scripts/backup.sh --db-only

# Full backup (includes volumes like uploads, models)
./scripts/backup.sh --full
```

#### `scripts/restore.sh`

Restores from a backup:
```bash
# List available backups
./scripts/restore.sh --list

# Restore specific backup
./scripts/restore.sh backup_2024-01-15_020000.tar.gz
```

#### `scripts/update.sh`

Updates to a new version with automatic rollback on failure:
```bash
./scripts/update.sh v1.2.0
```

#### `scripts/rollback.sh`

Manually revert to a previous version:
```bash
# List available checkpoints
./scripts/rollback.sh --list

# Rollback to specific checkpoint
./scripts/rollback.sh checkpoint_2024-01-14_150000
```

---

## 6. The Installation Script (install.sh)

The installation script is a comprehensive, enterprise-grade deployment tool. Here's how it works:

### Command-Line Options

```bash
./scripts/install.sh [OPTIONS]

Required:
  --domain <domain>       Your domain name (e.g., pravaha.yourcompany.com)

Optional:
  --email <email>         Email for Let's Encrypt notifications
  --ssl <type>            SSL type: letsencrypt (default) or selfsigned
  --skip-ssl              Use your own SSL certificates (GoDaddy, DigiCert, etc.)
  --skip-pull             Skip Docker image pull (use local images)
  --resume                Resume from last failed step
  --force                 Skip all confirmation prompts
  --dry-run               Show what would be done without doing it
  --verbose               Show detailed output
  --help                  Show usage information
```

### Installation Steps

The script executes 14 steps in order:

#### Step 1: Pre-Flight Checks

Validates system requirements before starting:

```
✓ Checking disk space...
  - Required: 50 GB
  - Available: 120 GB
  - Status: PASS

✓ Checking memory...
  - Required: 16 GB (recommended)
  - Available: 32 GB
  - Status: PASS

✓ Checking Docker...
  - Required: 24.0+
  - Installed: 24.0.7
  - Status: PASS

✓ Checking port availability...
  - Port 80: Available
  - Port 443: Available
  - Port 5432: Available
  - Port 6379: Available
  - Status: PASS

✓ Checking network connectivity...
  - DNS resolution: OK
  - Docker Hub access: OK
  - Status: PASS
```

If any check fails, the script stops and tells you how to fix it.

#### Step 2: Install Docker

If Docker is not installed or is outdated:
1. Removes old Docker versions
2. Adds Docker's official GPG key
3. Adds Docker repository
4. Installs Docker CE, CLI, and Compose plugin
5. Starts Docker service
6. Adds current user to docker group

#### Step 3: Install Required Tools

Installs system utilities:
- `git` - Version control
- `curl` - HTTP client
- `wget` - File downloader
- `htop` - System monitor
- `vim` - Text editor
- `jq` - JSON processor
- `certbot` - Let's Encrypt client

#### Step 4: Configure Firewall

Sets up UFW (Uncomplicated Firewall):
```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw enable
```

#### Step 5: Create Directory Structure

Creates the deployment directory:
```bash
mkdir -p /opt/pravaha/{ssl,backups,logs,nginx/conf.d}
```

Copies all deployment files to `/opt/pravaha/`.

#### Step 6: Generate NGINX Configuration

Takes the template file and replaces `${DOMAIN}` with your actual domain:

```bash
# Template has:
server_name ${DOMAIN};

# After generation:
server_name pravaha.yourcompany.com;
```

#### Step 7: Generate Secrets

Creates cryptographically secure random values for:

| Secret | Purpose | Format |
|--------|---------|--------|
| JWT_SECRET | User authentication tokens | Base64 (48 chars) |
| ENCRYPTION_KEY | General encryption | Hex (32 chars) |
| CREDENTIAL_MASTER_KEY | Credential vault | Hex (64 chars) |
| POSTGRES_PASSWORD | Database password | Base64 (24 chars) |
| ADMIN_PASSWORD | Initial admin password | Base64 (16 chars) |
| SESSION_SECRET | Session management | Base64 (48 chars) |
| CSRF_SECRET | CSRF protection | Base64 (32 chars) |
| And 10+ more... | Various security features | Various |

All secrets are written to `.env` with proper permissions (600 = owner read/write only).

#### Step 8: Generate Audit Keys

Creates RSA key pair for audit log signatures:
```bash
openssl genrsa -out audit-private.pem 2048
openssl rsa -in audit-private.pem -pubout -out audit-public.pem
```

These keys ensure audit logs cannot be tampered with.

#### Step 9: Setup SSL Certificates

See [Section 7](#7-ssl-certificate-options) for detailed SSL options.

#### Step 10: Pull Docker Images

Downloads container images with retry logic:
```bash
# Images pulled:
- ghcr.io/talentfino/pravaha/frontend:latest
- ghcr.io/talentfino/pravaha/backend:latest
- ghcr.io/talentfino/pravaha/superset:latest
- ghcr.io/talentfino/pravaha/ml-service:latest
- postgres:17-alpine
- redis:7-alpine
- nginx:1.25-alpine
```

Uses exponential backoff (2s → 4s → 8s → 16s → 32s) on failure.

#### Step 11: Initialize Database

Starts PostgreSQL and creates required databases:
```sql
-- Creates two databases:
CREATE DATABASE autoanalytics;     -- Main platform database
CREATE DATABASE superset;          -- Superset metadata database

-- Creates extensions:
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
```

#### Step 12: Start Services

Starts all containers in dependency order:
```bash
docker compose up -d
```

Docker Compose handles the order based on `depends_on` configuration.

#### Step 13: Verify Health

Polls each service until healthy:
```
Waiting for services to be healthy...
  [1/7] PostgreSQL: Healthy ✓
  [2/7] Redis: Healthy ✓
  [3/7] Backend: Healthy ✓
  [4/7] ML Service: Healthy ✓
  [5/7] Superset: Healthy ✓
  [6/7] Frontend: Healthy ✓
  [7/7] NGINX: Healthy ✓

All services are running!
```

#### Step 14: Complete Installation

- Creates `.installed` marker file
- Saves admin credentials to temporary files
- Prints completion summary with next steps

### Checkpoint and Resume

If installation fails at any step, you can resume:

```bash
# Installation fails at step 10 (image pull)
# Fix the issue (e.g., network problem)
# Then resume:
sudo ./scripts/install.sh --domain pravaha.yourcompany.com --resume
```

The script tracks progress in `.checkpoint/state.json`:
```json
{
  "domain": "pravaha.yourcompany.com",
  "ssl_type": "letsencrypt",
  "steps": {
    "preflight": "completed",
    "docker_install": "completed",
    "tools_install": "completed",
    "firewall_setup": "completed",
    "directory_setup": "completed",
    "nginx_config": "completed",
    "secrets_generation": "completed",
    "audit_keys": "completed",
    "ssl_setup": "completed",
    "image_pull": "in_progress"
  }
}
```

---

## 7. SSL Certificate Options

### Option 1: Let's Encrypt (Recommended for Production)

**What it is**: Free, automated SSL certificates from a trusted Certificate Authority.

**Requirements**:
- Domain must be publicly accessible
- Port 80 must be open (for verification)
- Valid email address (for expiry notifications)

**How to use**:
```bash
sudo ./scripts/install.sh \
  --domain pravaha.yourcompany.com \
  --email admin@yourcompany.com \
  --ssl letsencrypt
```

**What happens**:
1. Script stops any service using port 80
2. Runs `certbot` in standalone mode
3. Let's Encrypt verifies you own the domain
4. Certificate is issued and saved to `ssl/` folder
5. Auto-renewal cron job is created

**Auto-renewal**: Certificates are valid for 90 days. A cron job runs twice daily to check and renew if needed:
```
0 0,12 * * * certbot renew --quiet ...
```

### Option 2: Self-Signed (For Testing Only)

**What it is**: A certificate you create yourself. Browsers will show a security warning.

**When to use**:
- Local development
- Testing deployments
- Internal networks without public DNS

**How to use**:
```bash
sudo ./scripts/install.sh \
  --domain test.pravaha.local \
  --ssl selfsigned
```

**What happens**:
1. Creates a 2048-bit RSA key
2. Generates a self-signed certificate valid for 365 days
3. Includes Subject Alternative Name (SAN) for browser compatibility

**Warning**: Browsers will show "Your connection is not private". You must click through the warning.

### Option 3: Commercial Certificate (GoDaddy, DigiCert, etc.)

**What it is**: Certificates purchased from commercial Certificate Authorities.

**When to use**:
- Enterprise environments
- When Let's Encrypt is not possible
- Extended Validation (EV) certificates needed
- Wildcard certificates

**How to use**:

#### Step 1: Purchase and Download Certificate

From your CA (GoDaddy, DigiCert, Comodo, etc.), you'll receive:
- Certificate file (e.g., `yourdomain.crt`)
- Intermediate/chain certificates (e.g., `intermediate.crt` or `ca-bundle.crt`)
- Private key (you generated this when creating the CSR)

#### Step 2: Create the Certificate Chain

Combine your certificate with the intermediate certificates:
```bash
# Order matters: your cert first, then intermediates
cat yourdomain.crt intermediate.crt > fullchain.pem

# Or if you have a CA bundle:
cat yourdomain.crt ca-bundle.crt > fullchain.pem
```

#### Step 3: Prepare the Private Key

Ensure your private key is in PEM format:
```bash
# If already PEM format, just rename:
cp yourdomain.key privkey.pem

# If in different format, convert:
openssl rsa -in yourdomain.key -out privkey.pem
```

#### Step 4: Place Certificates

```bash
# Create ssl directory
mkdir -p /opt/pravaha/ssl

# Copy your files
cp fullchain.pem /opt/pravaha/ssl/
cp privkey.pem /opt/pravaha/ssl/

# Set proper permissions
chmod 644 /opt/pravaha/ssl/fullchain.pem
chmod 600 /opt/pravaha/ssl/privkey.pem
```

#### Step 5: Run Installation

```bash
sudo ./scripts/install.sh \
  --domain pravaha.yourcompany.com \
  --skip-ssl
```

The `--skip-ssl` flag tells the script to use existing certificates instead of generating new ones.

#### Verifying Your Certificate

After installation, verify the certificate is working:
```bash
# Check certificate details
openssl x509 -in /opt/pravaha/ssl/fullchain.pem -text -noout

# Verify certificate chain
openssl verify -CAfile /opt/pravaha/ssl/fullchain.pem /opt/pravaha/ssl/fullchain.pem

# Test HTTPS connection
curl -I https://pravaha.yourcompany.com/health

# Check certificate from outside
echo | openssl s_client -connect pravaha.yourcompany.com:443 2>/dev/null | openssl x509 -noout -dates
```

### Certificate File Requirements

| File | Content | Permissions |
|------|---------|-------------|
| `ssl/fullchain.pem` | Your certificate + intermediate chain | 644 (readable) |
| `ssl/privkey.pem` | Private key | 600 (owner only) |

**Important**: The private key must be unencrypted (no passphrase). NGINX cannot prompt for passwords.

---

## 8. Docker Compose Services

### Service Overview

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| nginx | nginx:1.25-alpine | 80, 443 | Reverse proxy, SSL |
| frontend | pravaha-frontend | 80 (internal) | Web UI |
| backend | pravaha-backend | 3000 | API server |
| postgres | postgres:17-alpine | 5432 (internal) | Database |
| redis | redis:7-alpine | 6379 (internal) | Cache |
| ml-service | pravaha-ml-service | 8001 | ML operations |
| superset | pravaha-superset | 8088 | BI dashboards |
| celery-worker-training | pravaha-ml-service | - | Training jobs |
| celery-worker-prediction | pravaha-ml-service | - | Prediction jobs |
| celery-worker-monitoring | pravaha-ml-service | - | Monitoring jobs |
| celery-beat | pravaha-ml-service | - | Job scheduler |

### Service Dependencies

```
                    nginx
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
    frontend       backend       superset
                      │             │
                      ▼             ▼
                 ┌────┴────┐   ┌────┴────┐
                 ▼         ▼   ▼         ▼
              postgres   redis         postgres
                 ▲                        ▲
                 │                        │
            ml-service              celery workers
```

### Resource Allocation

| Service | CPU Limit | Memory Limit | Notes |
|---------|-----------|--------------|-------|
| nginx | 1 | 512 MB | Low resource, high throughput |
| frontend | 0.5 | 256 MB | Static file serving |
| backend | 2 | 2 GB | API processing |
| postgres | 2 | 2 GB | Database operations |
| redis | 1 | 1 GB | In-memory cache |
| ml-service | 4 | 6 GB | Model inference |
| superset | 2 | 2 GB | Dashboard rendering |
| celery-training | 4 | 4 GB | CPU-intensive training |
| celery-prediction | 2 | 2 GB | Batch predictions |
| celery-monitoring | 1 | 1 GB | Background tasks |
| celery-beat | 1 | 1 GB | Scheduler only |

**Total**: ~20 CPU cores, ~19 GB RAM (with overhead, recommend 32 GB)

### Volumes (Persistent Storage)

| Volume | Purpose | Backup Priority |
|--------|---------|-----------------|
| postgres_data | Database files | Critical |
| redis_data | Cache persistence | Low |
| ml_models | Trained ML models | High |
| training_data | Training datasets | High |
| uploads | User file uploads | High |
| app_logs | Application logs | Medium |
| superset_home | Superset config | Medium |

---

## 9. Environment Variables

The `.env` file contains all configuration. Here are the key sections:

### Deployment Settings

```bash
# Domain and URLs
DOMAIN=pravaha.yourcompany.com
FRONTEND_URL=https://pravaha.yourcompany.com
API_BASE_URL=https://pravaha.yourcompany.com/api

# Docker Registry
REGISTRY=ghcr.io/talentfino/pravaha
IMAGE_TAG=latest

# Admin Account (auto-generated, change after first login)
ADMIN_EMAIL=admin@yourcompany.com
ADMIN_PASSWORD=<auto-generated>
```

### Database Configuration

```bash
# PostgreSQL
POSTGRES_USER=pravaha
POSTGRES_PASSWORD=<auto-generated>
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
PLATFORM_DB=autoanalytics
SUPERSET_DB=superset

# Connection URL (used by backend)
DATABASE_URL=postgresql://pravaha:<password>@postgres:5432/autoanalytics
```

### Redis Configuration

```bash
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=<optional>
REDIS_URL=redis://redis:6379/0
```

### Security Secrets

```bash
# Authentication
JWT_SECRET=<auto-generated>
JWT_EXPIRES_IN=24h

# Encryption
ENCRYPTION_KEY=<auto-generated>
CREDENTIAL_MASTER_KEY=<auto-generated>
DATA_ENCRYPTION_KEY=<auto-generated>

# Session
SESSION_SECRET=<auto-generated>
CSRF_SECRET=<auto-generated>
```

### Service URLs (Internal)

```bash
# How services find each other (using Docker DNS)
ML_SERVICE_URL=http://ml-service:8001
SUPERSET_URL=http://superset:8088
REDIS_URL=redis://redis:6379/0
```

---

## 10. NGINX Configuration

### Request Routing

| URL Pattern | Destination | Description |
|-------------|-------------|-------------|
| `/` | frontend:80 | Web application |
| `/api/*` | backend:3000 | REST API |
| `/ws` | backend:3000 | WebSocket |
| `/insights/*` | superset:8088 | BI dashboards |
| `/ml/*` | ml-service:8001 | ML API |
| `/health` | Direct response | Load balancer health |

### Rate Limiting

```nginx
# API endpoints: 10 requests/second per IP
limit_req zone=api_limit burst=20 nodelay;

# Login endpoint: 5 requests/minute per IP (brute force protection)
limit_req zone=login_limit burst=5 nodelay;

# Connection limit: 10 concurrent connections per IP
limit_conn conn_limit 10;
```

### Security Headers

```nginx
# Prevent clickjacking
add_header X-Frame-Options "SAMEORIGIN" always;

# Prevent MIME sniffing
add_header X-Content-Type-Options "nosniff" always;

# XSS protection
add_header X-XSS-Protection "1; mode=block" always;

# HTTPS enforcement (1 year)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

# Referrer policy
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

### SSL Configuration

```nginx
# Modern TLS only
ssl_protocols TLSv1.2 TLSv1.3;

# Strong ciphers
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...;

# Prefer server ciphers
ssl_prefer_server_ciphers off;

# Session caching for performance
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
```

---

## 11. Health Checks

### Health Check Endpoints

| Service | Endpoint | Expected Response |
|---------|----------|-------------------|
| NGINX | `GET /health` | 200 OK |
| Frontend | `GET /health` | 200 OK |
| Backend | `GET /health/live` | 200 OK (liveness) |
| Backend | `GET /api/v1/health` | JSON with details |
| ML Service | `GET /api/v1/health` | 200 OK |
| Superset | `GET /health` | 200 OK |
| PostgreSQL | `pg_isready` | Exit code 0 |
| Redis | `redis-cli ping` | PONG |

### Docker Health Check Configuration

Each service defines its health check in docker-compose.yml:

```yaml
healthcheck:
  test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000/health/live"]
  interval: 30s      # Check every 30 seconds
  timeout: 10s       # Timeout after 10 seconds
  retries: 3         # Mark unhealthy after 3 failures
  start_period: 30s  # Wait 30s before first check
```

### Health Check Script

Run the health check script to verify all services:

```bash
# Quick check (just pass/fail)
./scripts/health-check.sh --quick

# Detailed check
./scripts/health-check.sh

# JSON output (for monitoring systems)
./scripts/health-check.sh --json
```

Output example:
```
╔════════════════════════════════════════════════════════════╗
║                 PRAVAHA PLATFORM HEALTH CHECK              ║
╠════════════════════════════════════════════════════════════╣
║ Service          │ Status  │ Response Time │ Details       ║
╠══════════════════╪═════════╪═══════════════╪═══════════════╣
║ PostgreSQL       │ ✓ UP    │ 2ms           │ Accepting     ║
║ Redis            │ ✓ UP    │ 1ms           │ PONG          ║
║ Backend          │ ✓ UP    │ 45ms          │ HTTP 200      ║
║ Frontend         │ ✓ UP    │ 12ms          │ HTTP 200      ║
║ ML Service       │ ✓ UP    │ 89ms          │ HTTP 200      ║
║ Superset         │ ✓ UP    │ 234ms         │ HTTP 200      ║
║ NGINX            │ ✓ UP    │ 5ms           │ HTTP 200      ║
╠══════════════════╧═════════╧═══════════════╧═══════════════╣
║ Overall Status: HEALTHY (7/7 services operational)         ║
╚════════════════════════════════════════════════════════════╝
```

---

## 12. CI/CD Pipeline

### GitHub Actions Workflow

The deployment is tested automatically via `.github/workflows/test-deployment-single-server.yml`.

### Pipeline Stages

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DEPLOYMENT PIPELINE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   Validate  │───▶│  Dry Run    │───▶│   Deploy    │───▶│   Report    │  │
│  │   Scripts   │    │   Test      │    │   Test      │    │   Results   │  │
│  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘  │
│                                                                             │
│  • Syntax check     • Simulates       • Full deploy     • Success/fail    │
│  • YAML validation    installation    • Health checks   • Logs artifact   │
│  • NGINX config     • No changes      • API tests       • Notifications   │
│                       made            • Cleanup                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Triggers

The pipeline runs when:
- Push to `main`, `v2`, or `release/*` branches
- Changes to `deploy/single-server/**` files
- Manual trigger via GitHub UI

### What Gets Tested

1. **Script Syntax**: All `.sh` files are checked with `bash -n`
2. **Docker Compose**: Validates `docker-compose.yml` configuration
3. **NGINX Config**: Tests NGINX configuration syntax
4. **Dry Run**: Simulates installation without making changes
5. **Full Deployment**: Actually deploys and tests all services
6. **Health Checks**: Verifies all endpoints respond correctly
7. **Cleanup**: Removes test deployment

---

## 13. Running the Deployment

### Pre-Deployment Checklist

- [ ] Server meets hardware requirements (16 CPU, 32GB RAM, 50GB SSD)
- [ ] Ubuntu 22.04 LTS installed
- [ ] SSH access configured
- [ ] Domain DNS pointing to server IP
- [ ] Ports 80, 443 open in cloud firewall (if applicable)
- [ ] SSL certificate ready (if using commercial cert)

### Step-by-Step Deployment

#### 1. Connect to Your Server

```bash
ssh root@your-server-ip
# Or
ssh ubuntu@your-server-ip
```

#### 2. Download Deployment Files

```bash
# Option A: Clone the repository
git clone https://github.com/your-org/pravaha.git
cd pravaha/deploy/single-server

# Option B: Download release
wget https://github.com/your-org/pravaha/releases/download/v1.0.0/single-server-deploy.tar.gz
tar -xzf single-server-deploy.tar.gz
cd single-server
```

#### 3. (Optional) Place Commercial SSL Certificates

If using GoDaddy/DigiCert/etc:
```bash
mkdir -p ssl
cp /path/to/fullchain.pem ssl/
cp /path/to/privkey.pem ssl/
chmod 644 ssl/fullchain.pem
chmod 600 ssl/privkey.pem
```

#### 4. Run Installation

```bash
# With Let's Encrypt (recommended)
sudo ./scripts/install.sh \
  --domain pravaha.yourcompany.com \
  --email admin@yourcompany.com

# With commercial certificate
sudo ./scripts/install.sh \
  --domain pravaha.yourcompany.com \
  --skip-ssl

# With self-signed (testing only)
sudo ./scripts/install.sh \
  --domain test.pravaha.local \
  --ssl selfsigned
```

#### 5. Wait for Installation

The script will show progress:
```
╔════════════════════════════════════════════════════════════╗
║           PRAVAHA PLATFORM INSTALLATION                    ║
║           Domain: pravaha.yourcompany.com                  ║
╚════════════════════════════════════════════════════════════╝

[Step  1/14] Running pre-flight checks...
[Step  2/14] Installing Docker...
[Step  3/14] Installing required tools...
...
[Step 14/14] Verifying installation...

╔════════════════════════════════════════════════════════════╗
║           INSTALLATION COMPLETE!                           ║
╠════════════════════════════════════════════════════════════╣
║                                                            ║
║  Access your platform at:                                  ║
║  https://pravaha.yourcompany.com                           ║
║                                                            ║
║  Admin credentials saved to:                               ║
║  - Email: /opt/pravaha/.admin_email                        ║
║  - Password: /opt/pravaha/.admin_password                  ║
║                                                            ║
║  IMPORTANT: Delete these files after first login!          ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
```

#### 6. Verify Installation

```bash
# Check all services
./scripts/health-check.sh

# Check specific service logs
docker compose logs backend
docker compose logs frontend

# Test HTTPS access
curl -I https://pravaha.yourcompany.com/health
```

---

## 14. Post-Deployment Steps

### Immediate Actions (Do These First!)

#### 1. Get Admin Credentials

```bash
cat /opt/pravaha/.admin_email
cat /opt/pravaha/.admin_password
```

#### 2. Login and Change Password

1. Open `https://pravaha.yourcompany.com` in browser
2. Login with the admin credentials
3. Go to Settings → Account → Change Password
4. Set a strong password

#### 3. Delete Credential Files

```bash
rm /opt/pravaha/.admin_email
rm /opt/pravaha/.admin_password
```

#### 4. Verify All Features

- [ ] Can create new projects
- [ ] Can create workflows
- [ ] Can access Superset dashboards at `/insights/`
- [ ] ML features work (if applicable)

### Branding & White-Label Setup

The platform supports full white-labeling without rebuilding Docker images.

#### Default Behavior

`install.sh` automatically creates a default `branding/pravaha/` folder with `brand.json` if one does not already exist. This means out-of-the-box deployments use the default Pravaha branding with no extra steps required.

#### Custom Branding

To deploy with your own brand identity:

```bash
# 1. Create your brand directory before running install.sh
mkdir -p /opt/pravaha/branding/your-brand

# 2. Create brand.json (copy from default and customize)
cp /opt/pravaha/branding/pravaha/brand.json /opt/pravaha/branding/your-brand/brand.json
# Edit brand.json: name, companyName, colors, emails, etc.

# 3. Optionally add logo.svg, favicon.svg, and theme.css
# These replace the default logo, browser icon, and CSS variables

# 4. Set in .env before starting services:
#    BRAND=your-brand
#    BRAND_NAME=Your Brand
#    BRAND_CONFIG=
```

#### How Branding Is Mounted

Docker Compose maps the host `branding/` directory into the frontend and backend containers as a read-only volume:

```yaml
volumes:
  - ./branding:/app/branding:ro
```

At container startup:
- The **frontend entrypoint** reads `brand.json` and replaces the page title, injects the logo, favicon, and theme CSS into the served HTML
- The **backend** reads `brand.json` at startup and uses it for API responses, PDF/Excel metadata, emails, and JWT configuration

Because branding is a volume mount (not baked into the image), you can change brands by editing the files on the host and restarting the containers. No image rebuild or pull is needed.

### Recommended Configuration

#### Setup Automated Backups

```bash
./scripts/setup-automated-backups.sh

# This creates a cron job for daily backups at 2 AM
# Backups are stored in /opt/pravaha/backups/
```

#### Configure Email (Optional)

Edit `.env` and add SMTP settings:
```bash
SMTP_HOST=smtp.yourcompany.com
SMTP_PORT=587
SMTP_USER=notifications@yourcompany.com
SMTP_PASSWORD=your-smtp-password
SMTP_FROM=noreply@yourcompany.com
```

Then restart the backend:
```bash
docker compose restart backend
```

#### Monitor SSL Expiry

```bash
# Check certificate expiry
./scripts/check-ssl-expiry.sh

# Add to crontab for weekly checks
0 9 * * 1 /opt/pravaha/scripts/check-ssl-expiry.sh | mail -s "SSL Check" admin@yourcompany.com
```

---

## 15. Backup and Restore

### Creating Backups

#### Standard Backup (Database + Config)

```bash
./scripts/backup.sh
```

Creates: `backups/backup_2024-01-15_020000.tar.gz`

Contents:
- PostgreSQL database dump
- `.env` configuration
- Audit keys

#### Full Backup (Everything)

```bash
./scripts/backup.sh --full
```

Additional contents:
- Uploaded files
- Trained ML models
- Superset dashboards

### Backup Storage

Backups are stored in `/opt/pravaha/backups/`. For production:

1. **Copy to remote storage**:
   ```bash
   # S3
   aws s3 cp backups/backup_*.tar.gz s3://your-bucket/pravaha-backups/

   # Another server
   scp backups/backup_*.tar.gz backup-server:/backups/pravaha/
   ```

2. **Set up automated offsite backup**:
   ```bash
   # Add to crontab after daily backup
   30 2 * * * aws s3 sync /opt/pravaha/backups/ s3://your-bucket/pravaha-backups/
   ```

### Restoring from Backup

```bash
# List available backups
./scripts/restore.sh --list

# Restore specific backup
./scripts/restore.sh backup_2024-01-15_020000.tar.gz
```

**Warning**: Restore will:
1. Stop all services
2. Drop existing database
3. Restore database from backup
4. Restore configuration
5. Restart services

---

## 16. Updates and Rollback

### Updating to a New Version

```bash
./scripts/update.sh v1.2.0
```

The update script:
1. Creates a checkpoint (for rollback)
2. Creates a full backup
3. Updates IMAGE_TAG in `.env`
4. Pulls new Docker images
5. Stops services gracefully
6. Starts with new images
7. Runs health checks
8. Auto-rollback if health checks fail

### Manual Rollback

If something goes wrong after update:

```bash
# List available checkpoints
./scripts/rollback.sh --list

# Rollback to specific checkpoint
./scripts/rollback.sh checkpoint_2024-01-14_150000
```

### Checking Current Version

```bash
# Check running image versions
docker compose images

# Check version from API
curl -s https://pravaha.yourcompany.com/api/v1/health | jq '.version'
```

---

## 17. Troubleshooting

### Common Issues and Solutions

#### Service Won't Start

```bash
# Check container status
docker compose ps

# Check logs for specific service
docker compose logs backend

# Check resource usage
docker stats

# Restart specific service
docker compose restart backend
```

#### Database Connection Issues

```bash
# Check if PostgreSQL is running
docker compose ps postgres

# Check PostgreSQL logs
docker compose logs postgres

# Test database connection
docker compose exec postgres pg_isready -U pravaha -d autoanalytics

# Connect to database directly
docker compose exec postgres psql -U pravaha -d autoanalytics
```

#### Redis Connection Issues

```bash
# Check Redis status
docker compose exec redis redis-cli ping
# Should return: PONG

# Check Redis memory
docker compose exec redis redis-cli info memory
```

#### NGINX Issues

```bash
# Test NGINX configuration
docker compose exec nginx nginx -t

# Check NGINX logs
docker compose logs nginx

# Reload NGINX configuration
docker compose exec nginx nginx -s reload
```

#### SSL Certificate Issues

```bash
# Check certificate expiry
openssl x509 -in /opt/pravaha/ssl/fullchain.pem -noout -dates

# Verify certificate chain
openssl verify -CAfile /opt/pravaha/ssl/fullchain.pem /opt/pravaha/ssl/fullchain.pem

# Test SSL connection
echo | openssl s_client -connect pravaha.yourcompany.com:443 2>/dev/null | openssl x509 -noout -text
```

#### Out of Disk Space

```bash
# Check disk usage
df -h

# Check Docker disk usage
docker system df

# Clean unused Docker resources
docker system prune -a

# Clean old backups
find /opt/pravaha/backups -mtime +30 -delete
```

#### Out of Memory

```bash
# Check memory usage
free -h

# Check container memory usage
docker stats --no-stream

# Reduce container memory limits in docker-compose.yml
# Then restart:
docker compose up -d
```

### Getting Help

If you can't resolve an issue:

1. **Collect logs**:
   ```bash
   docker compose logs > /tmp/pravaha-logs.txt 2>&1
   ```

2. **Check system status**:
   ```bash
   ./scripts/health-check.sh --json > /tmp/health-status.json
   ```

3. **Contact support** with:
   - Log file
   - Health status
   - Steps to reproduce the issue

---

## 18. Common Commands Reference

### Service Management

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# Restart all services
docker compose restart

# Restart specific service
docker compose restart backend

# View running containers
docker compose ps

# View all containers (including stopped)
docker compose ps -a
```

### Logs

```bash
# View all logs
docker compose logs

# Follow logs in real-time
docker compose logs -f

# View logs for specific service
docker compose logs backend

# View last 100 lines
docker compose logs --tail=100 backend

# View logs since timestamp
docker compose logs --since="2024-01-15T10:00:00" backend
```

### Database

```bash
# Connect to PostgreSQL
docker compose exec postgres psql -U pravaha -d autoanalytics

# Run SQL query
docker compose exec postgres psql -U pravaha -d autoanalytics -c "SELECT count(*) FROM users;"

# Export database
docker compose exec postgres pg_dump -U pravaha autoanalytics > backup.sql

# Import database
docker compose exec -T postgres psql -U pravaha autoanalytics < backup.sql
```

### Redis

```bash
# Connect to Redis CLI
docker compose exec redis redis-cli

# Check Redis info
docker compose exec redis redis-cli info

# Flush cache (use carefully!)
docker compose exec redis redis-cli FLUSHALL
```

### System

```bash
# Check disk usage
df -h

# Check memory usage
free -h

# Check CPU usage
top

# Check container resource usage
docker stats

# Check Docker disk usage
docker system df

# Clean unused Docker resources
docker system prune
```

### Deployment

```bash
# Full installation
sudo ./scripts/install.sh --domain pravaha.yourcompany.com --email admin@yourcompany.com

# Resume failed installation
sudo ./scripts/install.sh --domain pravaha.yourcompany.com --resume

# Health check
./scripts/health-check.sh

# Create backup
./scripts/backup.sh

# Restore backup
./scripts/restore.sh backup_2024-01-15_020000.tar.gz

# Update version
./scripts/update.sh v1.2.0

# Rollback
./scripts/rollback.sh
```

---

## Summary

Single-server deployment provides a complete Pravaha Platform installation on one machine:

| Component | Technology | Purpose |
|-----------|------------|---------|
| Reverse Proxy | NGINX | SSL, routing, security |
| Frontend | React | User interface |
| Backend | Node.js | API server |
| Database | PostgreSQL | Data storage |
| Cache | Redis | Performance |
| ML Service | FastAPI | Machine learning |
| Task Queue | Celery | Background jobs |
| BI Tool | Superset | Dashboards |

**Key Points**:
- Use `install.sh` for automated deployment
- SSL options: Let's Encrypt, self-signed, or commercial (GoDaddy, etc.)
- All services are containerized with Docker
- Health checks ensure reliability
- Backup scripts protect your data
- Update scripts enable safe upgrades

For questions or issues, refer to the troubleshooting section or contact support.

---

*Document Version: 1.0.0*
*Last Updated: January 2025*
