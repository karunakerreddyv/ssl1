# Single-Server Deployment - Prerequisites

Complete checklist and setup commands for Ubuntu 22.04 LTS single-server deployment.

## Server Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| **CPU** | 4 cores | 8+ cores | Celery workers are CPU-intensive |
| **RAM** | 16 GB | 32+ GB | ML service + 4 Celery workers need memory |
| **Storage** | 50 GB SSD | 100+ GB SSD | SSD required for database performance |
| **OS** | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS | Other Linux distros may work |
| **Architecture** | x86_64 (amd64) | x86_64 (amd64) | ARM64 (aarch64) also supported |

### Service Resource Breakdown

| Service | CPU | Memory | Notes |
|---------|-----|--------|-------|
| ml-service | 4 cores | 4 GB | FastAPI ML predictions API |
| celery-worker-training | 4 cores | 4 GB | Model training (CPU intensive) |
| celery-worker-prediction | 2 cores | 2 GB | Batch predictions |
| celery-worker-monitoring | 1 core | 1 GB | Monitoring/alerting |
| celery-beat | 0.5 cores | 256 MB | Task scheduler |
| Other services | 4 cores | 6 GB | Backend, frontend, superset, etc. |

## Network Requirements

| Requirement | Details |
|-------------|---------|
| **Public IP** | Static IP address recommended |
| **Domain Name** | Must point to server's public IP (A record) |
| **Ports** | 80 (HTTP), 443 (HTTPS) must be open |
| **Outbound Internet** | Required for pulling Docker images |

## Pre-Deployment Checklist

### 1. Domain & DNS

- [ ] Domain name registered (e.g., `analytics.yourcompany.com`)
- [ ] DNS A record pointing to server IP
- [ ] DNS propagation complete (check: `nslookup your-domain.com`)

```bash
# Verify DNS resolution
nslookup your-domain.com
# or
dig your-domain.com +short
```

### 2. SSL Certificate

Choose one option:

#### Option A: CA-Issued Certificate (GoDaddy, DigiCert, etc.)

You need these files from your Certificate Authority:
- [ ] Domain certificate file (`.crt` or `.pem`)
- [ ] Intermediate/bundle certificate (e.g., `gd_bundle-g2-g1.crt`)
- [ ] Private key file (`.key`) - generated when you created the CSR

#### Option B: Let's Encrypt (Free)

- [ ] Domain DNS must be configured and propagated
- [ ] Port 80 must be accessible from internet
- [ ] Valid email address for certificate notifications

#### Option C: Self-Signed (Testing Only)

- [ ] No prerequisites (generated during setup)
- [ ] Browsers will show security warnings

---

## Server Preparation Commands

### Step 1: Update System

```bash
# Update package lists and upgrade existing packages
sudo apt update && sudo apt upgrade -y

# Install essential tools
sudo apt install -y curl wget git vim htop jq unzip
```

### Step 2: Install Docker

```bash
# Remove old Docker versions (if any)
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Install prerequisites
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group (avoids needing sudo)
sudo usermod -aG docker $USER

# IMPORTANT: Log out and log back in for group changes to take effect
# Or run: newgrp docker
```

### Step 3: Verify Docker Installation

```bash
# Check Docker version (should be 24+)
docker --version

# Check Docker Compose version (should be v2.x)
docker compose version

# Test Docker works without sudo
docker run hello-world
```

### Step 4: Configure Firewall

```bash
# Install UFW if not present
sudo apt install -y ufw

# Allow SSH (important - don't lock yourself out!)
sudo ufw allow 22/tcp

# Allow HTTP and HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Enable firewall
sudo ufw enable

# Verify rules
sudo ufw status
```

### Step 5: Create Deployment Directory

```bash
# Create directory structure
sudo mkdir -p /opt/pravaha
sudo chown $USER:$USER /opt/pravaha

# Navigate to directory
cd /opt/pravaha
```

---

## Generate Secure Secrets

Run these commands to generate secrets for your `.env` file:

```bash
# Generate JWT_SECRET (for API authentication)
echo "JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n/+=')"

# Generate ENCRYPTION_KEY (for data encryption)
echo "ENCRYPTION_KEY=$(openssl rand -hex 16)"

# Generate SUPERSET_SECRET_KEY (for Superset)
echo "SUPERSET_SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n/+=')"

# Generate MODEL_SIGNING_KEY (for ML model integrity verification)
echo "MODEL_SIGNING_KEY=$(openssl rand -hex 32)"

# Generate POSTGRES_PASSWORD (for database - no /+= chars to avoid breaking DATABASE_URL)
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '\n/+=')"

# Generate SUPERSET_ADMIN_PASSWORD
echo "SUPERSET_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '\n/+=')"

# Generate GRAFANA_ADMIN_PASSWORD (if using logging stack)
echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '\n/+=')"
```

Save these values - you'll need them for the `.env` file.

---

## SSL Certificate Preparation

### For GoDaddy SSL Certificates

GoDaddy's NGINX download typically includes these files:
- `domain.crt` or `yourdomain.crt` - Your domain certificate
- `domain-intermediate.pem` - Intermediate certificate
- `domain-root.pem` - Root certificate (optional)
- Your private key (`.key` file you generated when creating the CSR)

```bash
# Create ssl directory
mkdir -p /opt/pravaha/ssl

# Upload your certificate files to the server, then:

# 1. Create the certificate chain (domain cert + intermediate)
#    Order matters: your certificate FIRST, then intermediate
cat domain.crt domain-intermediate.pem > /opt/pravaha/ssl/fullchain.pem

# 2. Copy your private key (the .key file you generated with your CSR)
cp your-private-key.key /opt/pravaha/ssl/privkey.pem

# 3. Set proper permissions
chmod 644 /opt/pravaha/ssl/fullchain.pem
chmod 600 /opt/pravaha/ssl/privkey.pem

# 4. Verify certificate
openssl x509 -in /opt/pravaha/ssl/fullchain.pem -text -noout | head -20
```

> **Note:** The private key (`.key` file) is NOT included in GoDaddy's download.
> It's the file you generated when you created the CSR (Certificate Signing Request).

### For Let's Encrypt

```bash
# Install certbot
sudo apt install -y certbot

# Get certificate (server must be accessible on port 80)
sudo certbot certonly --standalone -d your-domain.com --email admin@your-domain.com --agree-tos --no-eff-email

# Copy certificates to deployment directory
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /opt/pravaha/ssl/
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem /opt/pravaha/ssl/
sudo chown $USER:$USER /opt/pravaha/ssl/*.pem
```

---

## Verification Commands

Run these to verify your server is ready:

```bash
# Check Ubuntu version
lsb_release -a

# Check available resources
echo "=== CPU ==="
nproc
echo "=== Memory ==="
free -h
echo "=== Disk ==="
df -h /

# Check Docker
docker --version
docker compose version

# Check firewall
sudo ufw status

# Check DNS resolution for your domain
nslookup your-domain.com

# Check if ports are open (from another machine)
# nc -zv your-server-ip 80
# nc -zv your-server-ip 443
```

---

## Ready to Deploy?

Once all prerequisites are met, proceed to deployment:

```bash
cd /opt/pravaha

# 1. Configure environment
cp .env.example .env
nano .env  # Add your domain, secrets, etc.

# 2. Generate NGINX config
./scripts/generate-nginx-config.sh

# 3. Start services
docker compose up -d

# 4. Verify deployment
./scripts/health-check.sh
```

---

## Troubleshooting

### Docker Permission Denied

```bash
# If you get "permission denied" errors with docker:
sudo usermod -aG docker $USER
# Then log out and log back in
```

### Port Already in Use

```bash
# Check what's using port 80 or 443
sudo lsof -i :80
sudo lsof -i :443

# Stop conflicting service (e.g., Apache)
sudo systemctl stop apache2
sudo systemctl disable apache2
```

### DNS Not Resolving

```bash
# Check DNS propagation
dig your-domain.com +short

# If empty, DNS hasn't propagated yet (can take up to 48 hours)
# Or check your DNS provider settings
```

### Low Memory Warnings

```bash
# Add swap if needed (for 8GB RAM systems)
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```
