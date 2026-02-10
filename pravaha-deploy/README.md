# Pravaha Platform - Single Server Deployment

Deploy the complete Pravaha platform on a single server.

## Container Registry Configuration

### Default Registry: GitHub Container Registry (GHCR)
Images are pulled from GHCR (`ghcr.io/talentfino/pravaha`) by default.

**Images:**
- `ghcr.io/talentfino/pravaha/frontend:latest`
- `ghcr.io/talentfino/pravaha/backend:latest`
- `ghcr.io/talentfino/pravaha/superset:latest`
- `ghcr.io/talentfino/pravaha/ml-service:latest`

Docker Hub is also supported as an alternative registry (set `REGISTRY=karunakervgrc` and `IMAGE_PREFIX=pravaha-` in .env).

### Architecture Support
Images are multi-architecture (linux/amd64 + linux/arm64).
Docker automatically pulls the correct variant for your server - no configuration needed.

| Architecture | Use Case |
|--------------|----------|
| linux/amd64 | Standard x86_64 servers, most cloud instances |
| linux/arm64 | AWS Graviton, Apple Silicon, ARM-based servers |

## Requirements

### System Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| CPU | 8 cores | 16+ cores | Celery workers are CPU-intensive |
| RAM | 16 GB | 32+ GB | ML service + 4 Celery workers need memory |
| Storage | 50 GB SSD | 100+ GB SSD | SSD required for database performance |
| OS | Ubuntu 22.04/24.04 LTS | Ubuntu 24.04 LTS | Other Linux distros may work |

### Service Resource Allocation

Resource limits are configured in docker-compose.yml:

| Service | CPU Limit | Memory Limit | Notes |
|---------|-----------|--------------|-------|
| backend | 2 cores | 2 GB | Node.js API server |
| postgres | 2 cores | 2 GB | Primary database |
| redis | 1 core | 1 GB | Cache and message broker |
| superset | 2 cores | 2 GB | BI dashboard |
| ml-service | 4 cores | 6 GB | ML predictions API |
| celery-worker-training | 4 cores | 4 GB | CPU-intensive model training |
| celery-worker-prediction | 2 cores | 2 GB | Batch predictions |
| celery-worker-monitoring | 1 core | 1 GB | Model monitoring |
| celery-beat | 1 core | 1 GB | Task scheduler |
| frontend | 0.5 cores | 256 MB | Static SPA serving |
| nginx | 1 core | 512 MB | Reverse proxy |

### ELK Stack Requirements (Optional)

If deploying the ELK stack for centralized logging:

| Resource | Requirement |
|----------|-------------|
| Additional RAM | +8 GB minimum |
| Additional Storage | +50 GB for log retention |
| vm.max_map_count | 262144 (required for Elasticsearch) |

**Configure vm.max_map_count before starting ELK:**
```bash
# Temporary (until reboot)
sudo sysctl -w vm.max_map_count=262144

# Permanent (persists after reboot)
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### Redis Memory Optimization (Recommended)

To prevent Redis background save failures under memory pressure:

```bash
# Temporary (until reboot)
sudo sysctl -w vm.overcommit_memory=1

# Permanent (persists after reboot)
echo "vm.overcommit_memory=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

**Note:** Without this setting, Redis may log warnings about background saves failing under low memory conditions.

## Quick Start

### 1. Get Deployment Files

**Option A: Clone Repository (Recommended)**
```bash
# Clone the repository
git clone https://github.com/TalentFino/pravaha.git /tmp/pravaha

# Copy deployment files to target directory
sudo mkdir -p /opt/pravaha
sudo cp -r /tmp/pravaha/deploy/single-server/* /opt/pravaha/
sudo cp /tmp/pravaha/deploy/single-server/.env* /opt/pravaha/  # Copy hidden files
sudo chown -R $USER:$USER /opt/pravaha
cd /opt/pravaha

# Run install script
sudo ./scripts/install.sh --domain your-domain.com
```

**Option B: Download ZIP from GitHub**
```bash
# 1. On GitHub: Code → Download ZIP
# 2. Transfer ZIP to server:
scp pravaha-main.zip user@server:/opt/

# 3. SSH to server and extract:
ssh user@server
cd /opt
unzip pravaha-main.zip
mkdir -p /opt/pravaha
cp -r pravaha-main/deploy/single-server/* /opt/pravaha/
cp pravaha-main/deploy/single-server/.env* /opt/pravaha/  # Copy hidden files
cd /opt/pravaha

# 4. Run install script:
sudo ./scripts/install.sh --domain your-domain.com
```

**Option C: SCP from your workstation**
```bash
# From your local machine with repo access:
scp -r deploy/single-server/* user@server:/opt/pravaha/
scp deploy/single-server/.env* user@server:/opt/pravaha/  # Copy hidden files

# Then SSH to server and run:
ssh user@server
cd /opt/pravaha
sudo ./scripts/install.sh --domain your-domain.com
```

**Option D: Manual Setup (without install script)**
```bash
cd /opt/pravaha
cp .env.example .env
nano .env  # Configure your settings
./scripts/generate-nginx-config.sh
docker compose up -d
```

### 2. Install Script Usage

The install script automates Docker installation, secret generation, SSL setup, and service startup.

```bash
sudo ./scripts/install.sh [OPTIONS]
```

**Options:**
| Option | Description |
|--------|-------------|
| `--domain <domain>` | Your domain name (required) |
| `--email <email>` | Email for Let's Encrypt notifications |
| `--ssl <type>` | SSL type: `letsencrypt` (default) or `selfsigned` |
| `--skip-ssl` | Skip SSL generation (use existing certificates) |
| `--skip-pull` | Skip docker compose pull (use pre-loaded local images) |
| `--resume` | Resume a failed installation from last checkpoint |
| `--force` | Force reinstallation without prompts |
| `--dry-run` | Preview installation steps without executing |
| `--verbose` | Show detailed output during installation |
| `--help` | Show usage information |

**Examples:**
```bash
# Let's Encrypt SSL (recommended for production)
sudo ./scripts/install.sh --domain analytics.example.com --email admin@example.com

# Self-signed SSL (for testing)
sudo ./scripts/install.sh --domain analytics.example.com --ssl selfsigned

# Skip SSL - use your own certificates (GoDaddy, DigiCert, etc.)
sudo ./scripts/install.sh --domain analytics.example.com --skip-ssl

# Use pre-loaded local images with existing SSL (air-gapped/offline deployment)
sudo ./scripts/install.sh --domain analytics.example.com --skip-ssl --skip-pull

# Preview installation steps (dry run - no changes made)
sudo ./scripts/install.sh --domain analytics.example.com --dry-run

# Resume failed installation from last checkpoint
sudo ./scripts/install.sh --domain analytics.example.com --resume

# Interactive mode (prompts for domain and SSL choice)
sudo ./scripts/install.sh
```

**What the install script does:**
1. **Pre-deployment validation:**
   - Validates disk space (minimum 50GB)
   - Validates system memory (minimum 16GB recommended)
   - Validates Docker version (24.0+)
   - Checks port availability (80, 443)
   - Validates SSL certificates (if using --skip-ssl)
2. Checks if Docker is installed (skips installation if already present)
3. Installs Docker and required tools if needed
4. Configures firewall (UFW)
5. Sets up deployment directory at `/opt/pravaha`
6. Copies all files including hidden files (`.env.example`)
7. Generates secure secrets for all services
8. Generates platform admin credentials (stored securely)
9. Generates NGINX configuration
10. Sets up SSL certificates (unless `--skip-ssl` is used)
11. Pulls Docker images (unless `--skip-pull` is used)
12. Starts all services with health polling (waits for each service to be healthy)

### 3. SSL Certificates

**Option A: Use Your Own Certificates (GoDaddy, DigiCert, etc.)**

If you have SSL certificates from a Certificate Authority, use `--skip-ssl`:

```bash
# 1. Place your certificates in ssl/ directory BEFORE running install script:
mkdir -p /opt/pravaha/ssl

# 2. Create the certificate chain (domain cert + intermediate)
#    Order matters: your certificate FIRST, then intermediate
cat domain.crt domain-intermediate.pem > /opt/pravaha/ssl/fullchain.pem

# 3. Copy your private key (the .key file you generated with your CSR)
cp your-private-key.key /opt/pravaha/ssl/privkey.pem

# 4. Set proper permissions
chmod 644 /opt/pravaha/ssl/fullchain.pem
chmod 600 /opt/pravaha/ssl/privkey.pem

# 5. Run install script with --skip-ssl
sudo ./scripts/install.sh --domain your-domain.com --skip-ssl
```

**Required files in `ssl/` directory:**
| File | Description |
|------|-------------|
| `fullchain.pem` | Your certificate + intermediate chain (concatenated) |
| `privkey.pem` | Your private key (generated when creating CSR) |

> **Note:** The private key (`.key`) is NOT in GoDaddy's download - it's the file you generated when creating the CSR.

**Option B: Let's Encrypt (Production)**
```bash
sudo ./scripts/install.sh --domain your-domain.com --email admin@your-domain.com --ssl letsencrypt
```

**Option C: Self-Signed (Testing Only)**
```bash
sudo ./scripts/install.sh --domain your-domain.com --ssl selfsigned
```

### 4. Local Image Build and Transfer (Air-Gapped/Offline Deployment)

When deploying to servers without internet access or private registries, build Docker images locally and transfer them.

#### Step 1: Build Images Locally (On Development Machine)

```bash
# Navigate to the repository root directory
cd /path/to/pravaha

# Build all Docker images using the build compose file
# This creates local images with names like "single-server-frontend:latest"
docker compose -f deploy/single-server/docker-compose.yml \
               -f deploy/single-server/docker-compose.build.yml build

# Verify images were built successfully
docker images | grep single-server
```

#### Step 2: Tag Images with Expected Names

The docker-compose.yml expects images from GHCR (`ghcr.io/talentfino/pravaha/`). Tag your locally built images to match:

```bash
# Tag each locally built image with the expected registry name
# Format: docker tag <local-name>:latest ghcr.io/talentfino/pravaha/<service>:latest

docker tag single-server-frontend:latest ghcr.io/talentfino/pravaha/frontend:latest
docker tag single-server-backend:latest ghcr.io/talentfino/pravaha/backend:latest
docker tag single-server-ml-service:latest ghcr.io/talentfino/pravaha/ml-service:latest
docker tag single-server-superset:latest ghcr.io/talentfino/pravaha/superset:latest

# Verify tags were applied
docker images | grep ghcr.io/talentfino/pravaha
```

#### Step 3: Save Images to Compressed Archives

```bash
# Create a directory for the image archives
mkdir -p pravaha-images

# Save each image to a compressed tar.gz file
# Using gzip compression to reduce file size for transfer
docker save ghcr.io/talentfino/pravaha/frontend:latest | gzip > pravaha-images/frontend.tar.gz
docker save ghcr.io/talentfino/pravaha/backend:latest | gzip > pravaha-images/backend.tar.gz
docker save ghcr.io/talentfino/pravaha/ml-service:latest | gzip > pravaha-images/ml-service.tar.gz
docker save ghcr.io/talentfino/pravaha/superset:latest | gzip > pravaha-images/superset.tar.gz

# Check the file sizes (typically 100MB-500MB each)
ls -lh pravaha-images/
```

#### Step 4: Transfer Images and Deployment Files to Target Server

```bash
# Transfer image archives to the target server
scp -r pravaha-images/ user@server:/tmp/

# Transfer deployment files (if not already on server)
scp -r deploy/single-server/* user@server:/opt/pravaha/
scp deploy/single-server/.env* user@server:/opt/pravaha/

# Transfer SSL certificates (if you have them)
scp ssl/fullchain.pem user@server:/opt/pravaha/ssl/
scp ssl/privkey.pem user@server:/opt/pravaha/ssl/
```

#### Step 5: Load Images on Target Server

```bash
# SSH to the target server
ssh user@server

# Load each image from the compressed archives
# gunzip decompresses, docker load imports the image
gunzip -c /tmp/pravaha-images/frontend.tar.gz | docker load
gunzip -c /tmp/pravaha-images/backend.tar.gz | docker load
gunzip -c /tmp/pravaha-images/ml-service.tar.gz | docker load
gunzip -c /tmp/pravaha-images/superset.tar.gz | docker load

# Verify images are loaded with correct tags
docker images | grep ghcr.io/talentfino/pravaha

# Clean up the temporary image archives (optional)
rm -rf /tmp/pravaha-images
```

#### Step 6: Run Install Script with Skip Options

```bash
# Navigate to deployment directory
cd /opt/pravaha

# Run install script with --skip-ssl and --skip-pull flags
# --skip-ssl: Uses existing SSL certificates in ssl/ directory
# --skip-pull: Skips docker compose pull (uses pre-loaded local images)
sudo ./scripts/install.sh --domain your-domain.com --skip-ssl --skip-pull
```

#### Complete One-Liner Workflow (Advanced)

For experienced users, here's a condensed workflow:

```bash
# On development machine: Build, tag, and save all images
cd /path/to/pravaha && \
docker compose -f deploy/single-server/docker-compose.yml -f deploy/single-server/docker-compose.build.yml build && \
for svc in frontend backend ml-service superset; do \
  docker tag single-server-$svc:latest ghcr.io/talentfino/pravaha/$svc:latest && \
  docker save ghcr.io/talentfino/pravaha/$svc:latest | gzip > $svc.tar.gz; \
done

# Transfer to server
scp *.tar.gz user@server:/tmp/

# On server: Load and deploy
ssh user@server 'for f in /tmp/*.tar.gz; do gunzip -c "$f" | docker load; done && \
  cd /opt/pravaha && sudo ./scripts/install.sh --domain your-domain.com --skip-ssl --skip-pull'
```

### 5. Verify Installation

```bash
docker compose ps
./scripts/health-check.sh
```

### 6. Login to Platform

Access the platform at `https://your-domain.com` and login with the admin credentials generated during installation:

- **Email:** Check `.admin_email` file in deployment directory
- **Password:** Check `.admin_password` file in deployment directory

```bash
# View generated credentials
cat /opt/pravaha/.admin_email
cat /opt/pravaha/.admin_password
```

> **Important:**
> - Save these credentials securely
> - Change the password immediately after first login
> - Delete the credential files after saving: `rm /opt/pravaha/.admin_email /opt/pravaha/.admin_password`

See `after-deployment.md` for the complete post-deployment checklist.

---

## Deployment Checklist for DevOps

### BEFORE Deployment

#### 1. Server Requirements
- [ ] Ubuntu 22.04 LTS (or compatible Linux)
- [ ] Minimum: 8 CPU cores, 16GB RAM, 50GB SSD
- [ ] Docker 24.0+ installed (install.sh handles this)
- [ ] Ports available: 80, 443, 5432 (if local DB), 6379 (if local Redis)
- [ ] Domain DNS configured (pointing to server IP)

#### 2. Network Connectivity
```bash
# Verify Docker Hub is reachable
curl -s --head https://registry-1.docker.io/v2/ | head -1
# Expected: HTTP/2 401 (authentication required - this is OK)

# Verify DNS resolution
nslookup your-domain.com
```

#### 3. Credentials (Optional - for private images or rate limit bypass)
```bash
# Set before running install.sh
export GHCR_USERNAME=your-github-username
export GHCR_TOKEN=<github-personal-access-token>
```

---

### DURING Deployment

#### Step-by-Step Installation
```bash
# 1. Clone/copy deployment files to server
scp -r deploy/single-server/ user@server:/opt/pravaha/

# 2. SSH into server
ssh user@server

# 3. Navigate to deployment directory
cd /opt/pravaha

# 4. Run installation (interactive mode)
sudo ./scripts/install.sh --domain your-domain.com

# 5. Monitor progress
# Install script shows progress with colored output
# Watch for any [ERROR] messages
```

#### Installation Options
```bash
# Self-signed SSL (for testing)
sudo ./scripts/install.sh --domain your-domain.com --ssl selfsigned

# Let's Encrypt SSL (for production)
sudo ./scripts/install.sh --domain your-domain.com --ssl letsencrypt --email admin@example.com

# Skip image pull (if pre-loaded)
sudo ./scripts/install.sh --domain your-domain.com --skip-pull

# Force reinstall
sudo ./scripts/install.sh --domain your-domain.com --force

# Resume failed installation
sudo ./scripts/install.sh --domain your-domain.com --resume
```

#### Monitor Container Status During Startup
```bash
# Watch container startup (in another terminal)
watch docker compose ps

# View live logs
docker compose logs -f
```

---

### AFTER Deployment

#### 1. Verify All Services Running
```bash
docker compose ps
# Expected: All services "Up" with "(healthy)" status

# Expected services:
# pravaha-nginx        - Up (healthy)
# pravaha-frontend     - Up (healthy)
# pravaha-backend      - Up (healthy)
# pravaha-superset     - Up (healthy)
# pravaha-ml-service   - Up (healthy)
# pravaha-celery-training    - Up (healthy)
# pravaha-celery-prediction  - Up (healthy)
# pravaha-celery-monitoring  - Up (healthy)
# pravaha-celery-beat        - Up (healthy)
# pravaha-postgres     - Up (healthy)
# pravaha-redis        - Up (healthy)
```

#### 2. Verify Health Endpoints
```bash
# NGINX (frontend proxy)
curl -k https://localhost/health
# Expected: {"status":"ok"}

# Backend API
curl -k https://localhost/api/v1/health
# Expected: {"status":"healthy","database":"connected","redis":"connected"}

# ML Service
curl -k https://localhost/ml/api/v1/health
# Expected: {"status":"healthy","version":"..."}

# Superset
curl -k https://localhost/insights/health
# Expected: OK
```

#### 3. Verify Image Sources
```bash
docker images | grep ghcr.io/talentfino/pravaha
# Expected: All 4 images from ghcr.io/talentfino/pravaha/*

# Verify architecture
docker inspect ghcr.io/talentfino/pravaha/frontend:latest --format='{{.Architecture}}'
# Expected: amd64 (for standard servers) or arm64 (for ARM servers)
```

#### 4. Retrieve Admin Credentials
```bash
# Auto-generated during installation
cat /opt/pravaha/.admin_email
cat /opt/pravaha/.admin_password

# IMPORTANT: Delete these files after saving credentials securely
rm /opt/pravaha/.admin_email /opt/pravaha/.admin_password
```

#### 5. Browser Access Verification
- [ ] Open `https://your-domain.com` in browser
- [ ] Accept SSL certificate (if self-signed)
- [ ] Login with admin credentials
- [ ] Verify dashboard loads without errors
- [ ] Change admin password immediately

#### 6. Functional Tests
- [ ] Create a new project
- [ ] Upload a test dataset
- [ ] Create and train an ML model
- [ ] Run a prediction
- [ ] Check Superset dashboards at `/insights/`

---

## Services

| Service | Internal Port | Description |
|---------|---------------|-------------|
| nginx | 80, 443 | Reverse proxy, SSL termination |
| frontend | 80 | React SPA |
| backend | 3000 | Node.js API |
| superset | 8088 | BI & Analytics |
| ml-service | 8001 | ML predictions API |
| celery-worker-training | - | ML model training background jobs |
| celery-worker-prediction | - | ML prediction background jobs |
| celery-worker-monitoring | - | Monitoring and alerting jobs |
| celery-beat | - | Task scheduler for periodic jobs |
| postgres | 5432 | PostgreSQL database |
| redis | 6379 | Cache, sessions & Celery broker |

### Celery Workers (ML Background Processing)

The platform uses Celery for distributed ML task processing:

- **Training Worker**: Handles model training jobs (CPU intensive)
- **Prediction Worker**: Handles batch predictions and real-time inference
- **Monitoring Worker**: Handles model monitoring, alerting, and analytics
- **Beat Scheduler**: Runs scheduled tasks like model retraining and cleanup

Configure worker concurrency in `.env`:
```bash
CELERY_TRAINING_CONCURRENCY=4    # Training worker threads
CELERY_PREDICTION_CONCURRENCY=4  # Prediction worker threads
CELERY_MONITORING_CONCURRENCY=2  # Monitoring worker threads
```

## URLs

After deployment:
- **Platform**: https://your-domain.com
- **Superset**: https://your-domain.com/insights/
- **API**: https://your-domain.com/api/v1/
- **Jupyter Notebooks**: https://your-domain.com/notebooks/ (when enabled)
- **Logs Viewer**: https://your-domain.com/logs/ (when enabled)
- **Kibana**: https://your-domain.com/elk/ (when enabled)

## Optional Services

### Jupyter Notebooks

Enable Jupyter for interactive data exploration and ML development:

```bash
# Start with Jupyter enabled
docker compose -f docker-compose.yml -f docker-compose.jupyter.yml up -d

# Or add to existing deployment
docker compose -f docker-compose.yml -f docker-compose.jupyter.yml up -d jupyter
```

**Access:** `https://your-domain.com/notebooks/`

**Configuration** (in `.env`):
```bash
JUPYTER_TOKEN=your-secure-token-here
JUPYTER_IMAGE=jupyter/scipy-notebook:2024-01-15
```

### Enterprise Log Viewer

Web-based log viewing interface for all services:

```bash
# Start with logging stack
docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d
```

**Access:** `https://your-domain.com/logs/`

### ELK Stack (Elasticsearch, Logstash, Kibana)

Full-featured log aggregation, search, and visualization:

**Prerequisites:**
```bash
# Set vm.max_map_count (required for Elasticsearch)
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

**Deploy:**
```bash
# Start with ELK stack
docker compose -f docker-compose.yml -f docker-compose.elk.yml up -d
```

**Access:** `https://your-domain.com/elk/`

**Default Credentials:**
- Username: `elastic`
- Password: Check `ELASTIC_PASSWORD` in `.env`

### Combining Optional Services

You can enable multiple optional services:

```bash
# Enable Jupyter + Logging
docker compose \
  -f docker-compose.yml \
  -f docker-compose.jupyter.yml \
  -f docker-compose.logging.yml \
  up -d

# Enable all optional services
docker compose \
  -f docker-compose.yml \
  -f docker-compose.jupyter.yml \
  -f docker-compose.elk.yml \
  up -d
```

## Branding & White-Label Configuration

The platform supports enterprise white-labeling without rebuilding Docker images. Branding is applied at runtime through Docker volume mounts.

### Quick Setup

1. **Create a branding directory:**

   ```
   branding/
   └── your-brand/
       ├── brand.json      # Required - full brand configuration
       ├── logo.svg         # Optional - platform logo
       ├── favicon.svg      # Optional - browser tab icon
       └── theme.css        # Optional - CSS color overrides
   ```

2. **Set branding variables in `.env`:**

   ```bash
   BRAND=your-brand          # Folder name under branding/
   BRAND_NAME=Your Brand     # Display name for reports and emails
   BRAND_CONFIG=             # Leave empty (filesystem brand.json is used)
   ```

3. **Run `install.sh`** -- branding is mounted into containers at runtime via Docker volumes (`./branding:/app/branding:ro`).

### How It Works

- Pre-built images are pulled from the registry (no rebuild needed)
- The host `branding/` folder is mounted read-only into frontend and backend containers
- Frontend entrypoint replaces page title, logo, favicon, and theme at container startup
- Backend reads `brand.json` for API responses, emails, and system configuration
- If no custom branding folder exists, `install.sh` creates default Pravaha branding automatically

### Customizing an Existing Deployment

To change branding on a running deployment:

```bash
# 1. Create or edit your branding directory
mkdir -p /opt/pravaha/branding/your-brand
# Edit brand.json, add logo.svg, favicon.svg, theme.css as needed

# 2. Update .env
nano /opt/pravaha/.env
# Set BRAND=your-brand and BRAND_NAME=Your Brand

# 3. Restart frontend and backend to pick up changes
docker compose restart frontend backend
```

No image pull or rebuild is required.

---

## Maintenance

### Health Checks

Comprehensive health check that validates all services, databases, and system resources:

```bash
# Full health check
./scripts/health-check.sh

# Quick container status only
./scripts/health-check.sh --quick

# JSON output for monitoring integration
./scripts/health-check.sh --json

# Return exit code 1 if any check fails (for CI/CD)
./scripts/health-check.sh --exit-code
```

Exit codes:
- `0` - All checks passed
- `1` - One or more checks failed
- `2` - Critical failure (database, core services)

### Backup

```bash
# Standard backup (database + config)
./scripts/backup.sh

# Database only (faster)
./scripts/backup.sh --db-only

# Full backup including volumes (ML models, uploads)
./scripts/backup.sh --full

# Custom retention (keep 14 days of backups)
./scripts/backup.sh --retention 14
```

Backups are stored in `/opt/pravaha/backups/`

### Verify Backups

Validate backup integrity before relying on them for disaster recovery:

```bash
# Verify latest backup
./scripts/verify-backup.sh

# Verify specific backup file
./scripts/verify-backup.sh backups/pravaha_backup_standard_20240115_120000.tar.gz

# List all backups with verification status
./scripts/verify-backup.sh --list

# Test restore capability (dry run - uses temporary container)
./scripts/verify-backup.sh --test-restore latest

# Verify all backups
./scripts/verify-backup.sh --all
```

### Restore

```bash
# Full restore from backup
./scripts/restore.sh /opt/pravaha/backups/pravaha_backup_*.tar.gz

# Restore database only
./scripts/restore.sh /opt/pravaha/backups/pravaha_backup_*.tar.gz --db-only

# Restore configuration only
./scripts/restore.sh /opt/pravaha/backups/pravaha_backup_*.tar.gz --config

# Preview restore (dry run)
./scripts/restore.sh /opt/pravaha/backups/pravaha_backup_*.tar.gz --dry-run
```

### Update with Auto-Rollback

Updates include automatic rollback on failure:

```bash
# Update to specific version (auto-rollback enabled)
./scripts/update.sh v1.2.0

# Update to latest version
./scripts/update.sh latest

# Preview what will happen (dry run)
./scripts/update.sh v1.2.0 --dry-run

# Update without auto-rollback
./scripts/update.sh v1.2.0 --no-rollback

# Update without backup (not recommended)
./scripts/update.sh v1.2.0 --skip-backup
```

**What update.sh does:**
1. Creates a checkpoint for instant rollback
2. Creates a full backup for data recovery
3. Updates the IMAGE_TAG in .env
4. Pulls new Docker images
5. Stops services gracefully (respects Celery task completion)
6. Starts services with new version
7. Waits for all health checks to pass
8. Runs database migrations if available
9. **If health checks fail**: Automatically rolls back to checkpoint

### Manual Rollback

If you need to rollback manually or to a specific checkpoint:

```bash
# Rollback to last checkpoint
./scripts/rollback.sh

# List available checkpoints
./scripts/rollback.sh --list

# Rollback to specific checkpoint
./scripts/rollback.sh --checkpoint pre_update_20240115_120000

# Verify current state vs checkpoint
./scripts/rollback.sh --verify
```

### SSL Certificate Management

Monitor and validate SSL certificates:

```bash
# Check SSL certificate status
./scripts/check-ssl-expiry.sh

# Custom warning threshold (days before expiry)
./scripts/check-ssl-expiry.sh --warn-days 30 --critical-days 7

# JSON output for monitoring
./scripts/check-ssl-expiry.sh --json

# Check and attempt renewal (for Let's Encrypt)
./scripts/check-ssl-expiry.sh --renew

# Log to file for audit trail
./scripts/check-ssl-expiry.sh --log
```

**Recommended:** Set up a cron job to check SSL certificate expiry daily:

```bash
# Add to crontab (runs daily at 8 AM)
0 8 * * * /opt/pravaha/scripts/check-ssl-expiry.sh --log >> /opt/pravaha/logs/ssl-check.log 2>&1
```

### Automated Maintenance (Cron Jobs)

Set up recommended automated maintenance tasks:

```bash
# Edit crontab
crontab -e

# Add these entries:

# Daily health check (6 AM)
0 6 * * * /opt/pravaha/scripts/health-check.sh --exit-code >> /opt/pravaha/logs/health-check.log 2>&1

# Daily backup (2 AM)
0 2 * * * /opt/pravaha/scripts/backup.sh >> /opt/pravaha/logs/backup.log 2>&1

# Weekly backup verification (Sunday 4 AM)
0 4 * * 0 /opt/pravaha/scripts/verify-backup.sh --all >> /opt/pravaha/logs/backup-verify.log 2>&1

# Daily SSL check (8 AM)
0 8 * * * /opt/pravaha/scripts/check-ssl-expiry.sh --log 2>&1

# Monthly Docker cleanup (1st of month, 3 AM)
0 3 1 * * docker system prune -f >> /opt/pravaha/logs/docker-cleanup.log 2>&1
```

### View Logs

**Option 1: Enterprise Log Viewer (Recommended)**

Enable the logging stack for web-based log viewing:

```bash
docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d
```

Then access: `https://your-domain.com/logs/`

See [../docs/LOGGING.md](../docs/LOGGING.md) for details.

**Option 2: Docker CLI**

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f backend

# Celery workers
docker compose logs -f celery-worker-training celery-worker-prediction
```

### Celery Worker Management

Celery workers are configured with graceful shutdown to prevent task corruption:

| Worker | Stop Grace Period | Use Case |
|--------|-------------------|----------|
| celery-training | 10 minutes | Long-running model training jobs |
| celery-prediction | 2 minutes | Batch prediction tasks |
| celery-monitoring | 1 minute | Monitoring and alerting |
| celery-beat | 15 seconds | Task scheduler (no long tasks) |

**Graceful shutdown:** When stopping/restarting services, Celery workers will finish their current task before shutting down.

```bash
# Restart all services (waits for Celery tasks to complete)
docker compose down
docker compose up -d

# Force immediate shutdown (may interrupt running tasks)
docker compose down --timeout 0
```

**Check Celery queue status:**
```bash
# View pending tasks in queue
docker exec pravaha-redis redis-cli LLEN celery

# Check worker status
docker compose logs celery-worker-training | tail -50
```

## File Structure

```
/opt/pravaha/
├── docker-compose.yml              # Main service definitions
├── docker-compose.build.yml        # Local build overrides
├── docker-compose.jupyter.yml      # Jupyter notebook service
├── docker-compose.elk.yml          # ELK stack for logging
├── docker-compose.logging.yml      # Simple log viewer
├── .env                            # Environment configuration
├── .env.example                    # Configuration template
├── nginx/
│   ├── nginx.conf                  # Main NGINX config
│   └── conf.d/
│       └── pravaha.conf            # Generated site config
├── ssl/
│   ├── fullchain.pem               # SSL certificate chain
│   └── privkey.pem                 # SSL private key
├── scripts/
│   ├── install.sh                  # Installation script
│   ├── backup.sh                   # Backup script
│   ├── restore.sh                  # Restore script
│   ├── update.sh                   # Update with auto-rollback
│   ├── rollback.sh                 # Manual rollback script
│   ├── health-check.sh             # Comprehensive health check
│   ├── check-ssl-expiry.sh         # SSL certificate monitoring
│   ├── verify-backup.sh            # Backup verification
│   ├── generate-nginx-config.sh    # NGINX config generator
│   ├── generate-self-signed-ssl.sh # Self-signed SSL generator
│   ├── setup-automated-backups.sh  # Cron job setup
│   └── init-databases.sql          # Database initialization
├── backups/                        # Backup storage
├── logs/                           # Application logs
├── .checkpoint/                    # Update checkpoints for rollback
├── .admin_email                    # Generated admin email (delete after use)
└── .admin_password                 # Generated admin password (delete after use)
```

## Monitoring & Observability

### Logging Stack (Loki + Grafana)

Enable centralized log aggregation with Loki and visualization through Grafana.

**Enable logging:**
```bash
docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d
```

**Access:**
- Grafana UI: https://your-domain.com/logs/ or http://localhost:3001
- Default credentials: admin / admin (change on first login)

**Log Query Examples (LogQL):**
```logql
# All errors across services
{job="pravaha"} |= "error"

# Backend service logs
{service="backend"}

# ML Service logs with JSON parsing
{service="ml-service"} | json | level="ERROR"

# Celery worker logs
{service=~"celery-worker.*"}

# Slow API requests (>1s)
{service="backend"} | json | duration > 1000

# Training job logs
{service="celery-worker-training"} |= "task_id"
```

**Log Retention:** Configured in `logging/loki-config.yml`. Default: 7 days.

### Metrics Stack (Prometheus + Grafana)

Enable metrics collection and alerting with Prometheus.

**Enable metrics:**
```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

**Access:**
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3002 (admin / admin)
- Alertmanager: http://localhost:9093

**Available Dashboards:**
- Platform Overview - System health at a glance
- ML Service Metrics - Model predictions, training times
- Celery Workers - Task queues, worker status
- PostgreSQL - Query performance, connections
- Redis - Memory usage, commands per second
- Infrastructure - CPU, memory, disk, network

**Key Metrics:**
```promql
# API request rate
rate(http_requests_total{service="backend"}[5m])

# ML prediction latency (P95)
histogram_quantile(0.95, rate(ml_prediction_duration_seconds_bucket[5m]))

# Celery queue depth
celery_queue_length{queue="training"}

# Database connections
pg_stat_activity_count{datname="autoanalytics"}
```

### Alerts Configuration

Customize alerts in `monitoring/alerts/pravaha.yml`. Pre-configured alerts include:

| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | Service unavailable > 1 min | critical |
| MLServiceHighLatency | P95 latency > 5s | warning |
| CeleryQueueBacklog | Queue > 100 tasks for > 5 min | warning |
| PostgresHighConnections | > 80% max connections | warning |
| RedisHighMemory | > 90% memory usage | warning |
| DiskSpaceLow | < 10% disk remaining | critical |
| SSLCertExpiringSoon | Certificate expires < 14 days | warning |
| HighErrorRate | Error rate > 5% for > 5 min | warning |

**Configure alert notifications** in `monitoring/alertmanager/alertmanager.yml`:
```yaml
receivers:
  - name: 'email-notifications'
    email_configs:
      - to: 'ops-team@example.com'
        from: 'pravaha-alerts@example.com'
        smarthost: 'smtp.example.com:587'
  - name: 'slack-notifications'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/xxx/yyy/zzz'
        channel: '#alerts'
```

### Combined Observability Stack

Enable both logging and metrics together:
```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.logging.yml \
  -f docker-compose.metrics.yml \
  up -d
```

### Troubleshooting Monitoring

**Loki not receiving logs:**
```bash
# Check Promtail is running
docker compose logs promtail

# Verify Promtail can reach Loki
docker compose exec promtail wget -qO- http://loki:3100/ready

# Check Promtail targets
curl http://localhost:9080/targets
```

**Prometheus not scraping:**
```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets

# Verify service discovery
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

**Grafana dashboard issues:**
```bash
# Reset Grafana admin password
docker compose exec grafana grafana-cli admin reset-admin-password newpassword

# Check datasource connectivity
docker compose exec grafana curl -s http://loki:3100/ready
docker compose exec grafana curl -s http://prometheus:9090/-/ready
```

---

## Troubleshooting

### Services won't start

```bash
# Check Docker status
systemctl status docker

# Check container logs
docker compose logs

# Verify .env file
cat .env | grep -v "^#" | grep -v "^$"
```

### Database connection issues

```bash
# Check PostgreSQL is running
docker compose ps postgres

# Connect to database
docker compose exec postgres psql -U postgres -d autoanalytics
```

### SSL certificate issues

```bash
# Verify certificates exist
ls -la ssl/

# Test NGINX config
docker compose exec nginx nginx -t
```

### Memory issues

```bash
# Check memory usage
docker stats

# Reduce Redis memory limit in docker-compose.yml if needed
```

### Celery worker issues

**Workers not processing tasks:**
```bash
# Check if workers are running
docker compose ps | grep celery

# Check worker logs
docker compose logs celery-worker-training --tail=100
docker compose logs celery-worker-prediction --tail=100
docker compose logs celery-worker-monitoring --tail=100

# Check Redis queue depth
docker exec pravaha-redis redis-cli LLEN celery

# Check worker status via celery inspect
docker compose exec celery-worker-training celery -A src.celery_app:celery_app inspect active
docker compose exec celery-worker-training celery -A src.celery_app:celery_app inspect stats
```

**Tasks stuck in queue:**
```bash
# View pending tasks
docker compose exec celery-worker-training celery -A src.celery_app:celery_app inspect scheduled

# Purge all pending tasks (DESTRUCTIVE - use with caution)
docker compose exec celery-worker-training celery -A src.celery_app:celery_app purge
```

**Worker crash/restart loop:**
```bash
# Check worker logs for errors
docker compose logs celery-worker-training 2>&1 | grep -i "error\|exception\|traceback"

# Check if Redis is accessible from worker
docker compose exec celery-worker-training redis-cli -h redis ping

# Restart workers
docker compose restart celery-worker-training celery-worker-prediction celery-worker-monitoring celery-beat
```

**Training jobs timing out:**
```bash
# Check training timeout settings in .env
grep -E "TRAINING_TIMEOUT|CELERY_TASK_TIME_LIMIT" .env

# Default: TRAINING_TIMEOUT_SECONDS=14400 (4 hours)
# Default: CELERY_TASK_TIME_LIMIT=7200 (2 hours)
```

### Installation issues

**Install script failed mid-way:**
```bash
# View installation log
cat /opt/pravaha/logs/install_*.log

# Resume from last checkpoint
sudo ./scripts/install.sh --domain your-domain.com --resume

# View checkpoint state
cat /opt/pravaha/.install_state
```

**Docker images not pulling:**
```bash
# Check network connectivity
curl -I https://registry-1.docker.io/v2/

# Check Docker Hub login (if using private images or rate limited)
docker login

# Try pulling manually with explicit registry
docker pull ghcr.io/talentfino/pravaha/frontend:latest
docker pull ghcr.io/talentfino/pravaha/backend:latest

# Check Docker Hub rate limit status
curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token | \
  xargs -I {} curl -s -H "Authorization: Bearer {}" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest -D - -o /dev/null 2>&1 | \
  grep -i ratelimit

# Authenticate to bypass rate limits (100 pulls/6hr for anonymous)
export GHCR_USERNAME=your-github-username
export GHCR_TOKEN=<your-github-personal-access-token>
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin

# For air-gapped deployments, use local images
sudo ./scripts/install.sh --domain your-domain.com --skip-pull
```

### Health check failures

**Services showing unhealthy:**
```bash
# Run detailed health check
./scripts/health-check.sh

# Check specific service health
docker inspect --format='{{.State.Health.Status}}' pravaha-backend

# View health check logs
docker inspect --format='{{json .State.Health}}' pravaha-backend | jq .

# Check if service can reach dependencies
docker compose exec backend wget -q -O - http://postgres:5432 2>&1
docker compose exec backend wget -q -O - http://redis:6379 2>&1
```
