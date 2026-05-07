# Branding System

Enterprise white-labeling system for the platform. Deploy for any client with **zero references** to the default brand visible in the UI.

## Architecture

```
branding/{brand-name}/brand.json    <-- Single Source of Truth
    |
    ├── Frontend (Build-Time)
    |   Vite plugin reads brand.json → injects window.__BRAND_CONFIG__
    |   useBrand() hook / getBrandConfig() function
    |
    ├── Backend (Runtime, Cached)
    |   getBrandConfig() singleton loaded once at startup
    |   getDocsUrl() helper for documentation URLs
    |
    ├── ML Service (Environment Variable)
    |   BRAND_NAME env var for Python services
    |
    └── Deployment (.env)
        BRAND, BRAND_NAME, BRAND_DOMAIN
```

## Quick Start: Create a New Brand

### 1. Create the brand directory

```bash
mkdir -p branding/acme-corp
```

### 2. Create `brand.json`

Copy from the default and customize:

```bash
cp branding/pravaha/brand.json branding/acme-corp/brand.json
```

Edit all values:

```json
{
  "name": "ACME Analytics",
  "tagline": "Data-Driven Decision Making",
  "companyName": "ACME Corporation",
  "companyUrl": "https://acme-corp.com",
  "supportEmail": "support@acme-corp.com",
  "supportUrl": "https://help.acme-corp.com",
  "copyrightHolder": "ACME Corporation",
  "description": "Enterprise Analytics Platform",
  "colors": {
    "primary": "#0066cc",
    "secondary": "#ff6600"
  },
  "features": {
    "showLandingPage": false,
    "showPublicRegistration": false
  },
  "legal": {
    "privacyEmail": "privacy@acme-corp.com",
    "legalEmail": "legal@acme-corp.com",
    "dpoEmail": "dpo@acme-corp.com"
  },
  "emails": {
    "fromName": "ACME Analytics",
    "fromAddress": "noreply@acme-corp.com"
  },
  "docker": {
    "prefix": "acme",
    "registry": "acme-corp"
  },
  "documentation": {
    "docsUrl": "https://docs.acme-corp.com",
    "runbookUrl": "https://docs.acme-corp.com/runbooks"
  },
  "system": {
    "systemEmail": "system@acme-corp.com",
    "metricsPrefix": "acme",
    "jwtIssuer": "acme-backend",
    "jwtAudience": "acme-api"
  }
}
```

### 3. Add brand assets (optional)

```
branding/acme-corp/
├── brand.json       # Required - brand configuration
├── logo.svg         # Optional - platform logo
├── favicon.svg      # Optional - browser favicon
└── theme.css        # Optional - CSS variable overrides
```

**theme.css** example:

```css
:root {
  --color-primary: #0066cc;
  --color-secondary: #ff6600;
}
```

### 4. Configure deployment

In your `.env` file:

```bash
BRAND=acme-corp
BRAND_NAME=ACME Analytics
BRAND_DOMAIN=acme-corp.com
```

### 5. Deploy

**Option A: Docker deployment (production)**

No build is required. Pre-built images are pulled from the registry and branding is applied at runtime via volume mounts.

```bash
# Set .env variables (BRAND, BRAND_NAME)
# Then run the install script or start services
sudo ./scripts/install.sh --domain your-domain.com

# Or if already installed:
docker compose up -d
```

**Option B: Local development build**

```bash
# Frontend build picks up BRAND env var
BRAND=acme-corp npm run build

# Docker deployment uses .env values
docker compose up -d
```

## brand.json Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Platform display name (appears in page titles, headers, footer) |
| `tagline` | string | No | Short tagline displayed on landing page |
| `companyName` | string | Yes | Company name for copyright notices and legal pages |
| `companyUrl` | string (URI) | Yes | Company website URL |
| `supportEmail` | string (email) | Yes | Support contact email |
| `supportUrl` | string (URI) | Yes | Support portal URL |
| `copyrightHolder` | string | Yes | Copyright holder name for footer |
| `description` | string | Yes | Platform description |
| `colors.primary` | string (hex) | Yes | Primary brand color |
| `colors.secondary` | string (hex) | Yes | Secondary brand color |
| `features.showLandingPage` | boolean | Yes | Show public landing page |
| `features.showPublicRegistration` | boolean | Yes | Allow public user registration |
| `legal.privacyEmail` | string (email) | Yes | Privacy policy contact email |
| `legal.legalEmail` | string (email) | Yes | Legal contact email |
| `legal.dpoEmail` | string (email) | Yes | Data Protection Officer email |
| `emails.fromName` | string | Yes | Email sender display name |
| `emails.fromAddress` | string (email) | Yes | Email sender address |
| `docker.registry` | string | Yes | Docker registry organization |
| `documentation.docsUrl` | string (URI) | Yes | Documentation website URL |
| `documentation.runbookUrl` | string (URI) | No | Runbook documentation URL |
| `system.systemEmail` | string (email) | Yes | System-generated email sender |
| `system.metricsPrefix` | string | Yes | Prometheus metrics prefix |
| `system.jwtIssuer` | string | Yes | JWT token issuer identifier |
| `system.jwtAudience` | string | Yes | JWT token audience identifier |

## Where Brand Values Are Used

### Frontend
- **Page titles**: `document.title` on all pages
- **Login/Magic link**: Brand name and logo
- **Footer**: Copyright holder, brand name
- **Legal pages**: Privacy policy, Terms of Service (all emails dynamic)
- **Landing page**: Brand name, tagline, description
- **i18n**: `window.__BRAND_CONFIG__` provides `brandName` token
- **Favicon & Logo**: Copied from brand directory at build time
- **Theme CSS**: Injected into `<head>` at build time

### Backend
- **API headers**: `X-API-Name`, `X-API-Description`, `X-API-Support`
- **PDF/Excel export**: Creator metadata in generated documents
- **Structured logger**: Service name prefix
- **System emails**: Quality incidents, lineage events
- **Prometheus metrics**: Metric name prefix (e.g., `{metricsPrefix}_backend_http_requests_total`)
- **JWT tokens**: Issuer and audience claims
- **OpenLineage**: Job/dataset namespaces
- **Message Queue**: Kafka client ID and consumer group prefix
- **Documentation URLs**: All 30+ workflow node `documentationUrl` fields
- **Seed data**: Admin/demo user email domains

### Deployment
- **Superset**: `APP_NAME` and `LOGO_TOOLTIP`
- **Credential summary**: Terminal output and `CREDENTIALS.md`
- **Install scripts**: Brand name in output messages

## Deployment Workflow

### How Branding Works in Docker Deployments

In production Docker deployments, branding is delivered at runtime through volume mounts -- no image rebuild is needed.

**Docker Compose volume mount (used in all deployment types):**

```yaml
# docker-compose.yml (frontend and backend services)
volumes:
  - ./branding:/app/branding:ro
```

This means the host `branding/` directory is mounted read-only into the container at `/app/branding/`. At container startup:

- **Frontend**: The entrypoint script reads `brand.json` and replaces the page title, injects the logo, favicon, and theme CSS into the served HTML
- **Backend**: Reads `brand.json` once at startup and uses the values for API response headers, PDF/Excel export metadata, system emails, JWT configuration, and Prometheus metric prefixes

### Step-by-Step Deployment

1. **Set environment variables** in `.env`:

   ```bash
   BRAND=your-brand          # Must match the folder name under branding/
   BRAND_NAME=Your Brand     # Display name used in Superset, emails, reports
   BRAND_CONFIG=             # Leave empty (filesystem brand.json is used)
   ```

2. **Create the branding folder** with at minimum a `brand.json`:

   ```bash
   mkdir -p branding/your-brand
   # Copy from default and customize:
   cp branding/pravaha/brand.json branding/your-brand/brand.json
   ```

3. **Run `install.sh`** (or `docker compose up -d` for an existing installation):

   ```bash
   sudo ./scripts/install.sh --domain your-domain.com
   ```

   If no branding folder exists for the configured `BRAND` value, `install.sh` automatically creates the default `branding/pravaha/brand.json` so the platform always has valid branding.

4. **Verify** by opening the platform in a browser. Page titles, footer, login page, and legal pages should all reflect your brand.

### Updating Branding on a Running Deployment

To change branding without downtime:

```bash
# Edit brand.json, swap logo.svg, etc. on the host filesystem
nano branding/your-brand/brand.json

# Restart only the affected containers
docker compose restart frontend backend
```

No image pull or rebuild is required.

### Multi-Server Deployments

Place the `branding/` folder on servers that run frontend or backend containers:

| Deployment Type | Where Branding Is Needed |
|----------------|--------------------------|
| Single-server | The one server |
| Two-server | App server only (database server does not need branding) |
| Three-server | Web server only (ML server does not need branding) |
| Scaled | All replicas (branding folder is on the host; each replica mounts it) |
| Windows | `C:\pravaha\branding\` on the Docker Desktop host |

Set the same `BRAND` and `BRAND_NAME` values in `.env` on each server to ensure consistency across the deployment.

## Schema Validation

Validate your `brand.json` against the JSON schema:

```bash
npx ajv validate -s branding/schema.json -d branding/acme-corp/brand.json
```

## Verification Checklist

After creating a new brand, verify:

1. **Build succeeds**: `BRAND=acme-corp npm run build` (frontend + backend)
2. **No default brand visible**: Check page titles, footer, login page, legal pages
3. **Emails correct**: Check Terms of Service, Privacy Policy for correct contact emails
4. **PDF/Excel metadata**: Export a document and check the creator field
5. **Prometheus metrics**: Check `/metrics` endpoint for correct prefix
6. **Seed users**: Verify `admin@{domain}` and `demo@{domain}` in database
