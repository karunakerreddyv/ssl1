# Pravaha Platform - Two-Server App Deployment

App server configuration for two-server deployment architecture where PostgreSQL runs on a dedicated external server.

## Architecture Overview

```
┌─────────────────────────────────────┐      ┌─────────────────────────┐
│ APP SERVER (Docker)                 │      │ DATABASE SERVER (Native)│
├─────────────────────────────────────┤      ├─────────────────────────┤
│  ┌─────────┐  ┌─────────┐          │      │                         │
│  │ Nginx   │  │Frontend │          │      │  PostgreSQL 17          │
│  │ :80/443 │  │  :80    │          │      │  ├─ autoanalytics DB    │
│  └────┬────┘  └─────────┘          │      │  └─ superset DB         │
│       │                             │      │                         │
│  ┌────▼────┐  ┌─────────┐          │ TCP  │  Port: 5432             │
│  │ Backend │  │Superset │          │ 5432 │  SSL: Optional          │
│  │  :3000  │  │  :8088  │◄─────────┼──────┼─►                       │
│  └─────────┘  └─────────┘          │      │                         │
│                                     │      └─────────────────────────┘
│  ┌─────────┐  ┌─────────────────┐  │
│  │ML-Service│ │ Celery Workers  │  │
│  │  :8001  │  │ Training/Pred/  │  │
│  └─────────┘  │ Monitoring/Beat │  │
│               └─────────────────┘  │
│  ┌─────────┐                       │
│  │  Redis  │ (stays in Docker)     │
│  │  :6379  │                       │
│  └─────────┘                       │
└─────────────────────────────────────┘
```

## Prerequisites

### App Server Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 16 GB | 32 GB |
| Disk | 50 GB SSD | 100 GB SSD |
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04/24.04 LTS |

### External Database Server

Before installing the app server, you must have:

1. PostgreSQL 17 installed and running on a separate server
2. Two databases created: `autoanalytics` (platform) and `superset`
3. A user with full access to both databases
4. Network access from the app server (port 5432)
5. pg_hba.conf configured to allow connections from app server IP

See `../database-server/README.md` for database server setup instructions.

## Quick Start

### Step 1: Prepare Database Server

On the database server:
```bash
# Install PostgreSQL with Pravaha configuration
cd ../database-server
sudo ./scripts/install-postgres.sh \
    --app-server-ip YOUR_APP_SERVER_IP \
    --password "YourSecurePassword123!"
```

### Step 2: Configure App Server

```bash
# Copy environment template
cp .env.example .env

# Edit .env and configure database connection
# REQUIRED settings:
#   POSTGRES_HOST=<database-server-ip>
#   POSTGRES_PASSWORD=<password-from-step-1>
#   DOMAIN=<your-domain.com>
```

### Step 3: Install

```bash
# Run automated installation
sudo ./scripts/install.sh --domain your-domain.com

# Or with self-signed SSL for testing
sudo ./scripts/install.sh --domain your-domain.com --ssl selfsigned
```

## Manual Installation

If you prefer manual setup:

### 1. Validate Database Connection

```bash
# Validate external database connectivity
./scripts/validate-external-db.sh
```

### 2. Generate Configuration

```bash
# Generate NGINX config
DOMAIN=your-domain.com ./scripts/generate-nginx-config.sh

# Generate secrets (will update .env)
# Note: POSTGRES_PASSWORD must be configured manually
```

### 3. Start Services

```bash
# Pull images
docker compose pull

# Start all services
docker compose up -d

# View logs
docker compose logs -f
```

## Configuration

### Essential .env Settings

```bash
# Domain
DOMAIN=your-domain.com

# External PostgreSQL (REQUIRED)
POSTGRES_HOST=192.168.1.100
POSTGRES_PORT=5432
POSTGRES_USER=pravaha
POSTGRES_PASSWORD=your_secure_password
DATABASE_URL=postgresql://pravaha:your_secure_password@192.168.1.100:5432/autoanalytics

# Database names
PLATFORM_DB=autoanalytics
SUPERSET_DB=superset

# SSL (optional)
POSTGRES_SSL_ENABLED=false
POSTGRES_SSL_MODE=prefer
```

### Superset Embed Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SUPERSET_EMBED_ADMIN_USERNAME` | (falls back to `SUPERSET_ADMIN_USERNAME`) | Separate Superset admin for embedded dashboard guest tokens. Prevents session conflicts. |
| `SUPERSET_EMBED_ADMIN_PASSWORD` | (falls back to `SUPERSET_ADMIN_PASSWORD`) | Password for the embed admin user |

### Application Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKFLOW_LOCK_EXPIRY_HOURS` | `24` | Auto-expiry duration for workflow locks (hours) |
| `ACCOUNT_EXPIRY_WARNING_DAYS` | `7` | Days before account expiry to send warning notifications |

### SSL/TLS for Database Connection

To enable encrypted connections to the external PostgreSQL:

```bash
# On database server, generate SSL certificates
cd ../database-server
sudo ./scripts/setup-ssl.sh

# Transfer client certificates to app server
scp /tmp/pravaha-client-certs.tar.gz user@app-server:~/
```

On the app server:
```bash
# Extract certificates
tar xzf pravaha-client-certs.tar.gz
mv pravaha-client-certs/* /opt/pravaha/ssl/postgres/
chmod 600 /opt/pravaha/ssl/postgres/*

# Update .env
POSTGRES_SSL_ENABLED=true
POSTGRES_SSL_MODE=verify-ca
```

## Branding & White-Label Configuration

The platform supports enterprise white-labeling without rebuilding Docker images. In the two-server architecture, the branding directory only needs to exist on the **app server** (where frontend and backend containers run).

### Setup

1. **Create a branding directory on the app server:**

   ```bash
   mkdir -p /opt/pravaha/branding/your-brand
   ```

2. **Add brand files:**

   ```
   branding/
   └── your-brand/
       ├── brand.json      # Required - full brand configuration
       ├── logo.svg         # Optional - platform logo
       ├── favicon.svg      # Optional - browser tab icon
       └── theme.css        # Optional - CSS color overrides
   ```

3. **Set in `.env`:**

   ```bash
   BRAND=your-brand          # Folder name under branding/
   BRAND_NAME=Your Brand     # Display name for reports and emails
   BRAND_CONFIG=             # Leave empty (filesystem brand.json is used)
   ```

4. **Run `install.sh`** -- branding is mounted into frontend and backend containers at runtime via Docker volumes (`./branding:/app/branding:ro`).

### How It Works

- Pre-built images are pulled from the registry (no rebuild needed)
- The host `branding/` folder is mounted read-only into frontend and backend containers
- Frontend entrypoint replaces page title, logo, favicon, and theme at container startup
- Backend reads `brand.json` for API responses, emails, and system configuration
- If no custom branding folder exists, `install.sh` creates default Pravaha branding automatically
- The **database server does not need branding files** -- only the app server requires them

### Updating Branding on a Running Deployment

```bash
# Edit brand files on the app server
nano /opt/pravaha/branding/your-brand/brand.json

# Restart frontend and backend (no rebuild needed)
docker compose restart frontend backend
```

---

## Health Check

```bash
# Full health check
./scripts/health-check.sh

# Quick check (containers only)
./scripts/health-check.sh --quick

# JSON output
./scripts/health-check.sh --json

# Validate database connection specifically
./scripts/validate-external-db.sh --verbose
```

## Backup

```bash
# Backup configs and volumes (no database - that's on the other server)
./scripts/backup.sh

# Include database backup (if app server has network access to DB)
./scripts/backup.sh --database
```

## Update

Updates are applied to the app-server only. The database server is updated separately and runs PostgreSQL natively (not via these scripts).

```bash
# Update to specific version (auto-rollback enabled)
./scripts/update.sh v1.2.0

# Update to latest version
./scripts/update.sh latest

# Preview what would happen (dry run)
./scripts/update.sh v1.2.0 --dry-run

# Update without auto-rollback
./scripts/update.sh v1.2.0 --no-rollback

# Update without backup (not recommended)
./scripts/update.sh v1.2.0 --skip-backup

# Update with extended health-check timeout (default 300s)
./scripts/update.sh v1.2.0 --timeout 600

# Update from a pre-staged release directory
./scripts/update.sh v1.2.0 --release-dir /tmp/pravaha-v1.2.0

# Restart with new env values only (skip docker-compose/scripts/nginx file updates)
./scripts/update.sh v1.2.0 --skip-file-update
```

**Supported flags:**

- `--skip-backup` — Skip backup creation (not recommended for production)
- `--no-rollback` — Disable automatic rollback on health-check failure
- `--dry-run` — Show what would happen without executing
- `--timeout <sec>` — Health check timeout in seconds (default: 300)
- `--release-dir <path>` — Directory containing new release files
- `--skip-file-update` — Skip docker-compose/scripts/nginx file updates (env-only restart)

**What update.sh does:**

1. Validates external database is reachable (`validate-external-db.sh`)
2. Creates a checkpoint (`pre_update_<timestamp>`) for instant rollback
3. Backs up app-server volumes + configs (DB backup must run on the database server separately)
4. Updates the IMAGE_TAG in `.env`
5. Pulls new Docker images (with logging/llm overlays if `ENABLE_LOGGING`/`OLLAMA_ENABLED`=true)
6. Stops services gracefully (respects Celery task completion)
7. Starts services with new version
8. Runs Prisma migrations against the external DB
9. Waits for all health checks to pass
10. **If health checks fail and `--no-rollback` is NOT set**: Automatically rolls back to checkpoint

**Two-server-specific notes:**

- The app-server `update.sh` does NOT touch the database. Schema migrations run against the external DB but no DB-level upgrades are performed here.
- If a major version bump requires PostgreSQL itself to be upgraded, follow the database-server upgrade procedure (see `deploy/two-server/database-server/README.md`) on that host first.
- DB password / SSL cert rotation: edit `.env` on app-server with the new credentials, then run `docker compose down && docker compose up -d` (no image pull needed). For a controlled restart with health verification, use `./scripts/update.sh <current-version> --skip-file-update`.

## Rollback

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

**What rollback.sh does:**

1. Stops current services
2. Restores `.env`, `docker-compose*.yml`, `nginx/`, `scripts/`, `monitoring/`, `logging/` from the chosen checkpoint
3. Restarts services with the prior IMAGE_TAG
4. Re-runs `validate-external-db.sh` to confirm DB connectivity is intact
5. Runs `health-check.sh --quick` to verify all 11 services are healthy

**Important:** Rollback restores **only the app-server**. If the failed update applied database migrations that the rolled-back app code can't read, you'll need to roll back the DB schema separately on the database server (using its own backup taken pre-update).

## Services

| Service | Port | Description |
|---------|------|-------------|
| nginx | 80, 443 | Reverse proxy, SSL termination |
| frontend | 80 (internal) | React SPA |
| backend | 3000 (internal) | Node.js API |
| superset | 8088 (internal) | Apache Superset BI |
| ml-service | 8001 (internal) | Python ML API |
| celery-training | - | ML training jobs |
| celery-prediction | - | ML prediction jobs |
| celery-monitoring | - | Monitoring/alerting |
| celery-beat | - | Task scheduler |
| redis | 6379 (internal) | Cache and job queue |

## Troubleshooting

### Cannot Connect to External Database

```bash
# Test TCP connectivity
nc -zv DB_SERVER_IP 5432

# Test with psql
PGPASSWORD=password psql -h DB_SERVER_IP -U pravaha -d autoanalytics -c "SELECT 1;"

# Check pg_hba.conf on database server
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules;"
```

### Services Not Starting

```bash
# Check container logs
docker compose logs backend
docker compose logs ml-service

# Check if database is reachable from container
docker exec pravaha-backend wget -qO- --timeout=5 http://DB_SERVER_IP:5432 || echo "Cannot reach DB"
```

### SSL Certificate Issues

```bash
# Verify SSL certificates exist
ls -la ssl/postgres/

# Test SSL connection
PGSSLMODE=verify-ca PGSSLROOTCERT=ssl/postgres/ca.crt \
  psql -h DB_SERVER_IP -U pravaha -d autoanalytics
```

## Network Requirements

### Firewall Rules (App Server)

| Direction | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| Inbound | 80 | TCP | HTTP |
| Inbound | 443 | TCP | HTTPS |
| Outbound | 5432 | TCP | PostgreSQL to DB server |

### Firewall Rules (Database Server)

| Direction | Port | Protocol | Source | Purpose |
|-----------|------|----------|--------|---------|
| Inbound | 5432 | TCP | App Server IP | PostgreSQL |

## Updating

```bash
# Pull latest images
docker compose pull

# Restart services
docker compose up -d

# Run migrations (connects to external DB)
docker compose exec backend npx prisma migrate deploy
```

## File Structure

```
app-server/
├── docker-compose.yml          # Main compose file (no postgres service)
├── .env.example                 # Environment template
├── nginx/
│   ├── nginx.conf              # Main NGINX config
│   └── conf.d/
│       └── pravaha.conf.template
├── scripts/
│   ├── install.sh              # Automated installation
│   ├── validate-external-db.sh # Database connectivity check
│   ├── health-check.sh         # Service health check
│   ├── backup.sh               # Backup script
│   └── generate-nginx-config.sh
├── ssl/
│   └── postgres/               # Client certs for PostgreSQL SSL
└── README.md
```

## Monitoring & Observability

### Logging Stack (Loki + Grafana)

Enable centralized log aggregation for the app server. Logs are collected locally and can be viewed via Grafana.

**Enable logging:**
```bash
docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d
```

**Access:**
- Grafana UI: https://your-domain.com/logs/ or http://localhost:3001
- Default credentials: admin / admin (change on first login)

**Log Query Examples (LogQL):**
```logql
# All errors on app server
{job="pravaha"} |= "error"

# Backend service logs
{service="backend"}

# Celery worker logs
{service=~"celery-worker.*"}

# Redis operations
{service="redis"}

# Database connection issues (check backend logs)
{service="backend"} |= "POSTGRES" |= "error"
```

### Metrics Stack (Prometheus + Grafana)

Enable metrics collection for app server services.

**Enable metrics:**
```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

**Access:**
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3002 (admin / admin)
- Alertmanager: http://localhost:9093

**Available Dashboards:**
- App Server Overview - Backend, Redis, Celery status
- Backend API Metrics - Request rates, latencies
- Celery Workers - Task queues, worker status
- Redis - Memory usage, commands per second
- External Database - Connection pool, query latencies

### Cross-Server Log Aggregation

For centralized logging across app and database servers:

1. **On App Server** - Configure Promtail to also scrape remote database logs:
   ```yaml
   # logging/promtail-config.yml
   scrape_configs:
     - job_name: database-server
       static_configs:
         - targets:
             - localhost
           labels:
             job: pravaha-database
             __path__: /var/log/postgresql/*.log
   ```

2. **Alternative**: Ship database server logs to app server's Loki endpoint.

### Alerts Configuration

Alerts for two-server deployment in `monitoring/alerts/pravaha.yml`:

| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | Service unavailable > 1 min | critical |
| ExternalDatabaseUnreachable | Cannot connect to DB server | critical |
| MLServiceHighLatency | P95 latency > 5s | warning |
| CeleryQueueBacklog | Queue > 100 tasks for > 5 min | warning |
| RedisHighMemory | > 90% memory usage | warning |
| DiskSpaceLow | < 10% disk remaining | critical |
| DatabaseConnectionPoolExhausted | > 90% connections used | critical |

### Troubleshooting Monitoring

**Check external database connectivity from metrics:**
```bash
# Verify database exporter is running
docker compose logs postgres-exporter

# Check database metrics in Prometheus
curl "http://localhost:9090/api/v1/query?query=pg_up"
```

**Verify log collection:**
```bash
docker compose logs promtail
```

---

## See Also

- [Database Server Setup](../database-server/README.md)
- [Single Server Deployment](../../single-server/README.md)
- [Three-Server Deployment](../../three-server/README.md)
