# Pravaha Platform - Database Server Setup

Self-hosted PostgreSQL configuration for two-server and three-server Pravaha deployments.

## Architecture Overview

```
┌─────────────────────────────────────┐
│ DATABASE SERVER (Native PostgreSQL) │
├─────────────────────────────────────┤
│                                     │
│  PostgreSQL 17                      │
│  ├─ autoanalytics DB (platform)     │
│  │   ├─ uuid-ossp extension         │
│  │   └─ pgcrypto extension          │
│  └─ superset DB (BI)                │
│      └─ uuid-ossp extension         │
│                                     │
│  Port: 5432                         │
│  SSL/TLS: Optional                  │
│                                     │
│  Accepts connections from:          │
│  ├─ App Server (two-server)         │
│  ├─ Web Server (three-server)       │
│  └─ ML Server (three-server)        │
│                                     │
└─────────────────────────────────────┘
```

## Prerequisites

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 2 cores | 4+ cores |
| RAM | 8 GB | 16+ GB |
| Disk | 50 GB SSD | 200 GB SSD |

### Software Requirements

- Ubuntu 22.04 LTS / 24.04 LTS / Debian 12
- Root or sudo access
- Network connectivity to app server(s)

## Quick Start

### One-Command Installation

```bash
# Basic installation
sudo ./scripts/install-postgres.sh \
    --app-server-ip 192.168.1.10 \
    --password "YourSecurePassword123!"

# With SSL enabled (recommended for production)
sudo ./scripts/install-postgres.sh \
    --app-server-ip 192.168.1.10 \
    --password "YourSecurePassword123!" \
    --enable-ssl
```

### What the Installer Does

1. Installs PostgreSQL 17 from official repository
2. Creates `pravaha` user with specified password
3. Creates `autoanalytics` and `superset` databases
4. Installs required extensions (uuid-ossp, pgcrypto)
5. Configures pg_hba.conf for remote access
6. Applies production performance settings
7. Configures firewall rules
8. Optionally generates SSL certificates

## Manual Installation

If you prefer manual setup:

### 1. Install PostgreSQL 17

```bash
# Add PostgreSQL repository
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -

# Install
sudo apt-get update
sudo apt-get install -y postgresql-17 postgresql-contrib-17
```

### 2. Create User and Databases

```bash
sudo -u postgres psql << 'EOF'
-- Create user
CREATE USER pravaha WITH PASSWORD 'YourSecurePassword' CREATEDB;

-- Create databases
CREATE DATABASE autoanalytics OWNER pravaha ENCODING 'UTF8';
CREATE DATABASE superset OWNER pravaha ENCODING 'UTF8';

-- Connect to platform database
\c autoanalytics
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
GRANT ALL ON SCHEMA public TO pravaha;

-- Connect to superset database
\c superset
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
GRANT ALL ON SCHEMA public TO pravaha;
EOF
```

### 3. Configure Remote Access

Edit `/etc/postgresql/17/main/postgresql.conf`:
```
listen_addresses = '*'
```

Edit `/etc/postgresql/17/main/pg_hba.conf`:
```
# Pravaha App Server
host    autoanalytics   pravaha   192.168.1.10/32   scram-sha-256
host    superset        pravaha   192.168.1.10/32   scram-sha-256
host    all             pravaha   192.168.1.10/32   scram-sha-256
```

Restart PostgreSQL:
```bash
sudo systemctl restart postgresql
```

### 4. Configure Firewall

```bash
sudo ufw allow from 192.168.1.10 to any port 5432 proto tcp
```

## SSL/TLS Configuration

### Generate SSL Certificates

```bash
# Run SSL setup script
sudo ./scripts/setup-ssl.sh

# Or with options
sudo ./scripts/setup-ssl.sh --cert-days 730 --regenerate
```

### Transfer Client Certificates

After SSL setup, transfer certificates to the app server:

```bash
# On database server
scp /tmp/pravaha-client-certs.tar.gz user@app-server:~/

# On app server
tar xzf pravaha-client-certs.tar.gz
mv pravaha-client-certs/* /opt/pravaha/ssl/postgres/
chmod 600 /opt/pravaha/ssl/postgres/*
```

### Update pg_hba.conf for SSL

```bash
# Use hostssl instead of host for SSL-only connections
sudo ./scripts/configure-remote-access.sh --app-server-ip 192.168.1.10 --ssl
```

## Adding Additional App Servers

### For Three-Server Deployment

```bash
# Add web server access
sudo ./scripts/configure-remote-access.sh --app-server-ip WEB_SERVER_IP

# Add ML server access
sudo ./scripts/configure-remote-access.sh --app-server-ip ML_SERVER_IP
```

### View Current Access Rules

```bash
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE user_name = '{pravaha}';"
```

### Remove Access

```bash
sudo ./scripts/configure-remote-access.sh --app-server-ip OLD_SERVER_IP --remove
```

## Performance Tuning

The install script applies default production settings. For larger deployments, consider:

### Memory Settings (in postgresql.conf)

| Setting | Formula | Example (16GB RAM) |
|---------|---------|-------------------|
| shared_buffers | 25% of RAM | 4GB |
| effective_cache_size | 75% of RAM | 12GB |
| work_mem | RAM / max_connections / 4 | 16MB |
| maintenance_work_mem | RAM / 16 | 1GB |

### Edit Settings

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf

# Apply changes
sudo systemctl restart postgresql
```

## Backup

### Create Backup

```bash
# Backup both databases
sudo -u postgres pg_dump -Fc autoanalytics > autoanalytics_$(date +%Y%m%d).dump
sudo -u postgres pg_dump -Fc superset > superset_$(date +%Y%m%d).dump
```

### Restore Backup

```bash
# Restore database
sudo -u postgres pg_restore -d autoanalytics autoanalytics_backup.dump
```

### Automated Backups

Add to crontab:
```bash
# Daily backup at 2 AM
0 2 * * * pg_dump -U postgres -Fc autoanalytics > /backups/autoanalytics_$(date +\%Y\%m\%d).dump
```

## Monitoring

### Check Status

```bash
# Service status
sudo systemctl status postgresql

# Active connections
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE datname IN ('autoanalytics', 'superset');"

# Database sizes
sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname IN ('autoanalytics', 'superset');"
```

### Logs

```bash
# View PostgreSQL logs
sudo journalctl -u postgresql -f

# Or check log files
sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

## Troubleshooting

### Connection Refused

```bash
# Check PostgreSQL is running
sudo systemctl status postgresql

# Check listen_addresses
sudo -u postgres psql -c "SHOW listen_addresses;"

# Check port is open
sudo ss -tlnp | grep 5432
```

### Authentication Failed

```bash
# Check pg_hba.conf rules
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules;"

# Reload configuration
sudo systemctl reload postgresql
```

### Cannot Create Extensions

```bash
# Grant superuser temporarily
sudo -u postgres psql -c "ALTER USER pravaha WITH SUPERUSER;"

# Create extensions
sudo -u postgres psql -d autoanalytics -c "CREATE EXTENSION IF NOT EXISTS uuid-ossp; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Revoke superuser (recommended)
sudo -u postgres psql -c "ALTER USER pravaha WITH NOSUPERUSER;"
```

## Security Recommendations

1. **Use SSL/TLS** for all production deployments
2. **Use strong passwords** (20+ characters, mixed case, numbers, symbols)
3. **Limit IP access** in pg_hba.conf to only necessary servers
4. **Use CIDR /32** for single hosts instead of broader ranges
5. **Regular updates**: Keep PostgreSQL updated with security patches
6. **Audit logging**: Enable log_connections and log_disconnections
7. **Separate admin user**: Don't use the `pravaha` user for administrative tasks

## File Structure

```
database-server/
├── scripts/
│   ├── install-postgres.sh       # One-command installation
│   ├── configure-remote-access.sh # Add/remove app server access
│   └── setup-ssl.sh              # SSL certificate generation
├── config/
│   ├── pg_hba.conf.template      # Access control template
│   └── postgresql.conf.template  # PostgreSQL settings template
└── README.md
```

## Connection Details

After installation, use these details on the app server:

```bash
# .env configuration for app server
POSTGRES_HOST=<this-server-ip>
POSTGRES_PORT=5432
POSTGRES_USER=pravaha
POSTGRES_PASSWORD=<your-password>
PLATFORM_DB=autoanalytics
SUPERSET_DB=superset

# Connection URL
DATABASE_URL=postgresql://pravaha:<password>@<this-server-ip>:5432/autoanalytics
```

## Monitoring & Observability

### PostgreSQL Monitoring

Monitor database health, performance, and connections directly on the database server.

**Option 1: PostgreSQL Exporter (Recommended)**

Install postgres_exporter for Prometheus metrics:

```bash
# Install postgres_exporter
sudo ./scripts/install-postgres-exporter.sh

# Or manual installation
wget https://github.com/prometheus-community/postgres_exporter/releases/download/v0.15.0/postgres_exporter-0.15.0.linux-amd64.tar.gz
tar xzf postgres_exporter-0.15.0.linux-amd64.tar.gz
sudo mv postgres_exporter-0.15.0.linux-amd64/postgres_exporter /usr/local/bin/

# Configure and start
export DATA_SOURCE_NAME="postgresql://postgres:password@localhost:5432/postgres?sslmode=disable"
postgres_exporter &
```

**Metrics endpoint:** http://localhost:9187/metrics

**Key PostgreSQL Metrics:**
```promql
# Active connections
pg_stat_activity_count{datname="autoanalytics"}

# Database size
pg_database_size_bytes{datname="autoanalytics"}

# Transaction rates
rate(pg_stat_database_xact_commit{datname="autoanalytics"}[5m])

# Slow queries (requires pg_stat_statements)
pg_stat_statements_seconds_total
```

**Option 2: pgAdmin Monitoring**

For GUI-based monitoring:

```bash
# Install pgAdmin
sudo apt install pgadmin4-web

# Access via browser
# http://database-server-ip/pgadmin4
```

### Log Monitoring

**Enable PostgreSQL logging:**

Edit `/etc/postgresql/17/main/postgresql.conf`:
```ini
# Logging configuration
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB

# What to log
log_min_duration_statement = 1000  # Log queries > 1 second
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
```

**View logs:**
```bash
sudo tail -f /var/log/postgresql/postgresql-17-main.log
# Or
sudo tail -f /var/lib/postgresql/17/main/pg_log/*.log
```

### Health Check Script

Use the provided health check script for monitoring:

```bash
# Run health check
./scripts/health-check.sh

# JSON output for monitoring systems
./scripts/health-check.sh --json

# Exit codes for automation
./scripts/health-check.sh --exit-code
# 0 = healthy, 1 = warning, 2 = critical
```

**Health check verifies:**
- PostgreSQL service running
- Databases accessible
- Connection count within limits
- Replication status (if configured)
- Disk space for data directory
- Recent checkpoint activity

### Alerts Configuration

Configure monitoring alerts on the app server's Alertmanager:

| Alert | Condition | Severity |
|-------|-----------|----------|
| PostgresDown | Database unreachable | critical |
| PostgresHighConnections | > 80% max_connections | warning |
| PostgresReplicationLag | Replication lag > 30s | warning |
| PostgresDiskSpaceLow | Data directory < 20% free | warning |
| PostgresLongRunningQueries | Query running > 5 min | warning |
| PostgresDeadlocks | Deadlocks detected | warning |

### Remote Monitoring from App Server

Configure the app server to monitor this database server:

1. **Allow metrics scraping** (on database server):
   ```bash
   # Allow Prometheus from app server IP
   sudo ufw allow from APP_SERVER_IP to any port 9187 proto tcp
   ```

2. **Add to Prometheus config** (on app server):
   ```yaml
   # monitoring/prometheus/prometheus.yml
   scrape_configs:
     - job_name: 'postgres-external'
       static_configs:
         - targets: ['DATABASE_SERVER_IP:9187']
   ```

### Troubleshooting Monitoring

**postgres_exporter not working:**
```bash
# Check connectivity
curl http://localhost:9187/metrics

# Verify DATA_SOURCE_NAME
psql "$DATA_SOURCE_NAME" -c "SELECT 1"

# Check logs
journalctl -u postgres_exporter -f
```

**High connection count:**
```bash
# View active connections
sudo -u postgres psql -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;"

# View connection details
sudo -u postgres psql -c "SELECT pid, usename, datname, state, query_start FROM pg_stat_activity WHERE datname IN ('autoanalytics', 'superset');"

# Terminate idle connections
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'autoanalytics' AND state = 'idle' AND query_start < now() - interval '1 hour';"
```

---

## See Also

- [App Server Setup](../app-server/README.md)
- [Three-Server Web Server](../../three-server/web-server/README.md)
- [Three-Server ML Server](../../three-server/ml-server/README.md)
