# Pravaha Single-Server Quick Setup

## Prerequisites

- Linux server (Ubuntu 20.04+ / RHEL 8+ / Debian 11+)
- SSH access to the server
- Domain pointing to your server IP
- SSL certificate files (fullchain + private key)
- Ports 80 and 443 open on the server

> Docker Engine and Docker Compose are **NOT** prerequisites — `install.sh` installs them automatically if not present.

---

## SSH Deployment (Remote Ubuntu Server)

This is the most common deployment method — you have a remote Ubuntu server accessible only via SSH.

### On Your Local Machine

```bash
# 1. Bundle the single-server deployment files into a tarball
#    Run this from the project root (where deploy/ folder is)
cd /path/to/pravaha
tar czf pravaha-deploy.tar.gz -C deploy/single-server .
```

```bash
# 2. Copy tarball to the remote server
scp pravaha-deploy.tar.gz user@your-server-ip:/tmp/
```

```bash
# 3. Copy your SSL certificate files to the remote server
scp /path/to/fullchain.pem user@your-server-ip:/tmp/fullchain.pem
scp /path/to/privkey.pem   user@your-server-ip:/tmp/privkey.pem
```

> **SSL file names:** Your public cert must include the full chain (server cert + intermediate CA).
> If you have separate files, concatenate them: `cat server.crt intermediate.crt > fullchain.pem`

```bash
# 4. (Optional) If using custom branding, copy your brand.json too
scp /path/to/brand.json user@your-server-ip:/tmp/brand.json
```

```bash
# 5. SSH into the server
ssh user@your-server-ip
```

### On the Remote Ubuntu Server

```bash
# 6. Create deployment directory and extract files
sudo mkdir -p /opt/pravaha
sudo tar xzf /tmp/pravaha-deploy.tar.gz -C /opt/pravaha
```

```bash
# 7. Verify extraction — you should see these files
ls /opt/pravaha/
# Expected output:
#   docker-compose.yml  docker-compose.build.yml  docker-compose.logging.yml
#   docker-compose.metrics.yml  docker-compose.elk.yml  docker-compose.jupyter.yml
#   .env.example  nginx/  scripts/  ssl/  monitoring/  logging/  ...
```

```bash
# 8. Place SSL certificates (file names MUST be exactly as shown)
sudo cp /tmp/fullchain.pem /opt/pravaha/ssl/fullchain.pem
sudo cp /tmp/privkey.pem   /opt/pravaha/ssl/privkey.pem
```

```bash
# 9. Create .env from template
sudo cp /opt/pravaha/.env.example /opt/pravaha/.env
```

```bash
# 10. Edit .env — set your domain (only required edit, rest is auto-generated)
sudo nano /opt/pravaha/.env
```

In the editor, find and change this line:

```
DOMAIN=your-domain.example.com
```

To your actual domain:

```
DOMAIN=analytics.acme.com
```

If using custom branding, also set:

```
BRAND=acme
BRAND_NAME="Acme Analytics"
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

```bash
# 11. (Optional) Setup custom branding
#     Skip this step to use default "Pravaha" branding (install.sh creates it automatically)
sudo mkdir -p /opt/pravaha/branding/acme
sudo cp /tmp/brand.json /opt/pravaha/branding/acme/brand.json
```

```bash
# 12. Make install script executable and run it
sudo chmod +x /opt/pravaha/scripts/*.sh
sudo /opt/pravaha/scripts/install.sh --domain analytics.acme.com --skip-ssl
```

> **`--skip-ssl`** tells the script to use your existing certs from `/opt/pravaha/ssl/`
> instead of generating new ones. It still validates that your cert and key match
> and aren't expired.

```bash
# 13. Clean up temp files
rm -f /tmp/pravaha-deploy.tar.gz /tmp/fullchain.pem /tmp/privkey.pem /tmp/brand.json
```

### What install.sh Does Automatically

1. Installs Docker Engine + Docker Compose (if not present)
2. Copies deployment files to `/opt/pravaha`
3. Auto-generates ALL secrets (JWT, encryption keys, passwords, API keys)
4. Updates DOMAIN, FRONTEND_URL, API_BASE_URL in `.env`
5. Generates NGINX config for your domain
6. Generates RSA audit key pair (for HIPAA/SOC2/SOX compliance)
7. Validates your SSL certificates (expiry + key match)
8. Creates default branding if custom branding not provided
9. Pulls Docker images from registry
10. Initializes PostgreSQL database + extensions
11. Starts all services (11 containers)
12. Runs health checks on every service
13. Prints credentials summary (admin email, password, URLs)

---

## Alternative: Local/Direct Deployment

If you're already on the server or have the files locally:

```bash
# 1. Create deployment directory
sudo mkdir -p /opt/pravaha

# 2. Copy deployment files directly
sudo cp -r deploy/single-server/* /opt/pravaha/
sudo cp deploy/single-server/.env* /opt/pravaha/

# 3. Place SSL certificates
sudo cp /path/to/fullchain.pem /opt/pravaha/ssl/fullchain.pem
sudo cp /path/to/privkey.pem   /opt/pravaha/ssl/privkey.pem

# 4. Create and edit .env
sudo cp /opt/pravaha/.env.example /opt/pravaha/.env
sudo nano /opt/pravaha/.env
# → Set DOMAIN=yourdomain.com

# 5. Run install
sudo /opt/pravaha/scripts/install.sh --domain yourdomain.com --skip-ssl
```

---

## .env Quoting Rules

Docker Compose `.env` files require quoting for values that contain spaces, special characters, or JSON.

```bash
# No quotes needed — simple values without spaces or special characters
DOMAIN=analytics.acme.com
BRAND=pravaha
POSTGRES_USER=pravaha
IMAGE_TAG=latest

# MUST quote — values with spaces
BRAND_NAME="Acme Analytics"
ADMIN_DISPLAY_NAME="Platform Admin"
SMTP_FROM_NAME="Acme Analytics Platform"
ORGANIZATION_NAME="Acme Corporation"

# MUST quote — JSON values (use single quotes to preserve inner double quotes)
BRAND_CONFIG='{"name":"Acme","companyName":"Acme Corp","tagline":"Data Analytics"}'

# MUST quote — values with special characters ( $ ` ! # & | ; )
# Use single quotes to prevent shell interpolation
SOME_PASSWORD='p@$$w0rd!#complex'

# URLs without spaces do NOT need quotes
FRONTEND_URL=https://analytics.acme.com
API_BASE_URL=https://analytics.acme.com/api
DATABASE_URL=postgresql://pravaha:mypassword@postgres:5432/autoanalytics
```

> **Rule of thumb:** If the value contains spaces, curly braces `{}`, or special
> characters (`$`, `` ` ``, `!`, `#`, `&`, `|`, `;`) — wrap it in quotes.
> Simple alphanumeric values, URLs, and paths without spaces don't need quotes.

---

## Custom Branding (Optional)

Skip this section entirely to use the default "Pravaha" branding. The `install.sh`
script creates default branding automatically if none is provided.

For custom branding:

```bash
# Create brand directory (name must match BRAND value in .env)
sudo mkdir -p /opt/pravaha/branding/acme

# Create brand.json (see branding/README.md for full schema)
sudo nano /opt/pravaha/branding/acme/brand.json
```

Set in `.env`:

```bash
BRAND=acme
BRAND_NAME="Acme Analytics"
```

Optional files alongside brand.json:

| File | Purpose |
|------|---------|
| `logo.svg` | Replaces platform logo in header and login page |
| `favicon.svg` | Replaces browser tab icon |
| `theme.css` | Custom CSS overrides (colors, fonts, etc.) |

---

## Other Install Options

```bash
# Let's Encrypt SSL (auto-generates cert, needs port 80 open to internet)
sudo /opt/pravaha/scripts/install.sh --domain analytics.acme.com --email admin@acme.com

# Self-signed SSL (for internal networks / testing)
sudo /opt/pravaha/scripts/install.sh --domain analytics.acme.com --ssl selfsigned

# Air-gapped / no internet (images pre-loaded via docker load)
sudo /opt/pravaha/scripts/install.sh --domain analytics.acme.com --skip-ssl --skip-pull

# Force reinstall (non-interactive, overwrite existing)
sudo /opt/pravaha/scripts/install.sh --domain analytics.acme.com --skip-ssl --force
```

---

## Verify Deployment

After install completes, it prints a credentials summary with admin login details.

```bash
# Check all services are healthy (comprehensive health check)
sudo /opt/pravaha/scripts/health-check.sh
```

```bash
# Check individual container status
cd /opt/pravaha && docker compose ps
```

```bash
# Expected: all 11 services should show "healthy" or "running"
#   pravaha-nginx          running (healthy)
#   pravaha-frontend       running (healthy)
#   pravaha-backend        running (healthy)
#   pravaha-postgres       running (healthy)
#   pravaha-redis          running (healthy)
#   pravaha-superset       running (healthy)
#   pravaha-ml-service     running (healthy)
#   pravaha-celery-training    running
#   pravaha-celery-prediction  running
#   pravaha-celery-beat        running
#   pravaha-celery-monitoring   running
```

```bash
# View logs if any service is unhealthy
cd /opt/pravaha && docker compose logs -f --tail=50

# View logs for a specific service
cd /opt/pravaha && docker compose logs -f --tail=50 backend
cd /opt/pravaha && docker compose logs -f --tail=50 nginx
```

Access the platform at: `https://your-domain.com`

---

## Post-Install: Folder Structure

```
/opt/pravaha/
├── .env                          ← auto-generated secrets from .env.example
├── docker-compose.yml            ← main compose file (11 services)
├── docker-compose.build.yml      ← for building images locally (optional)
├── docker-compose.logging.yml    ← Loki + Promtail log aggregation (optional)
├── docker-compose.metrics.yml    ← Prometheus + Grafana metrics (optional)
├── docker-compose.elk.yml        ← ELK stack alternative (optional)
├── docker-compose.jupyter.yml    ← JupyterHub notebooks (optional)
├── branding/
│   └── pravaha/                  ← (or your custom brand folder)
│       └── brand.json
├── ssl/
│   ├── fullchain.pem             ← your SSL certificate + chain
│   └── privkey.pem               ← your SSL private key
├── audit-private.pem             ← auto-generated RSA key (compliance)
├── audit-public.pem              ← auto-generated RSA key (compliance)
├── nginx/
│   ├── nginx.conf                ← main NGINX config
│   └── conf.d/
│       └── pravaha.conf.template ← domain-specific config (templated)
├── scripts/
│   ├── install.sh                ← initial deployment
│   ├── health-check.sh           ← service health verification
│   ├── backup.sh                 ← database + config backup
│   ├── restore.sh                ← restore from backup
│   ├── rollback.sh               ← rollback to previous version
│   ├── update.sh                 ← upgrade to new version
│   ├── check-ssl-expiry.sh       ← SSL certificate monitoring
│   ├── verify-backup.sh          ← backup integrity check
│   └── setup-automated-backups.sh ← cron-based auto backups
├── monitoring/                   ← Prometheus + Alertmanager configs
│   ├── prometheus.yml
│   ├── alertmanager.yml
│   └── alerts/
├── logging/                      ← Loki + Promtail configs
│   ├── loki-config.yml
│   └── promtail-config.yml
├── backups/                      ← created by backup.sh
└── logs/                         ← application logs
```

---

## Day-2 Operations

### Backup

```bash
# Manual backup (database + configs + uploads)
sudo /opt/pravaha/scripts/backup.sh

# Setup automated daily backups via cron
sudo /opt/pravaha/scripts/setup-automated-backups.sh

# Verify a backup file is valid
sudo /opt/pravaha/scripts/verify-backup.sh /opt/pravaha/backups/latest.tar.gz
```

### Update / Upgrade

```bash
# Update to a specific version
sudo /opt/pravaha/scripts/update.sh --version v2.1.0

# Rollback if the update causes issues
sudo /opt/pravaha/scripts/rollback.sh
```

### Monitoring

```bash
# Check SSL certificate expiry
sudo /opt/pravaha/scripts/check-ssl-expiry.sh

# Run comprehensive health check
sudo /opt/pravaha/scripts/health-check.sh

# Enable Prometheus + Grafana monitoring stack (optional)
cd /opt/pravaha && docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d

# Enable centralized logging with Loki (optional)
cd /opt/pravaha && docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d
```

### Troubleshooting

```bash
# View all service logs
cd /opt/pravaha && docker compose logs -f --tail=100

# Restart a specific service
cd /opt/pravaha && docker compose restart backend

# Restart all services
cd /opt/pravaha && docker compose restart

# Full stop and start (preserves data)
cd /opt/pravaha && docker compose down && docker compose up -d

# Check disk space (Docker images + volumes)
docker system df
```
