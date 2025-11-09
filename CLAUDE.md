# GCP Static Site Deployment Toolkit

## Project Overview

This is a **framework-agnostic** static site deployment toolkit for Google Cloud Platform (GCP). It provides robust bash scripts to deploy any static website or application to Google Cloud Storage with versioned releases, instant rollback capabilities, and load balancer integration.

## Architecture

The toolkit consists of three main scripts:

1. **deploy-staging.sh** - Deploys to staging environment with shorter cache times
2. **deploy-production.sh** - Deploys to production with longer cache times and safety confirmations
3. **rollback.sh** - Instant zero-copy rollback between versions

### Key Features

- Versioned releases stored in `gs://bucket/releases/YYYYMMDD-HHMMSS-SHA/`
- Automatic gzip compression for optimal delivery
- Configurable cache headers (different for staging vs production)
- Load balancer path rewrite integration for instant rollbacks
- Interactive mode with prompts OR fully automated mode for CI/CD
- Retry logic and error handling
- Pre-flight validation checks

## Environment Configuration

The scripts support two configuration methods:

1. **Interactive Mode**: Prompts for missing values
2. **Automated Mode**: Uses environment files (`.env.staging`, `.env.production`)

### Example Environment Files

#### `.env.staging` (Staging Environment)

```bash
# ============================================================================
# GCP Deployment Configuration - STAGING
# ============================================================================

# Required: GCP Project Configuration
DEPLOY_PROJECT_ID=my-gcp-project-staging
DEPLOY_BUCKET_NAME=my-app-staging

# Required: Build Configuration
DEPLOY_BUILD_DIR=dist                    # Output directory from your build (dist, build, out, public, etc.)

# Optional: GCP Regional Settings
DEPLOY_REGION=us-central1                # GCP region for deployment
DEPLOY_BUCKET_LOCATION=US                # Multi-region: US, EU, ASIA, or single region

# Optional: Cache Configuration (Staging - shorter cache times)
DEPLOY_CACHE_MAX_AGE=86400               # Static assets cache: 24 hours (86400 seconds)
DEPLOY_HTML_CACHE_MAX_AGE=1800           # HTML files cache: 30 minutes (1800 seconds)

# Optional: Compression Settings
DEPLOY_GZIP_EXTENSIONS=js,css,html,json,svg,txt,xml

# Optional: Load Balancer Configuration (for automatic update instructions)
DEPLOY_URL_MAP_NAME=my-app-staging-lb    # Your load balancer URL map name
DEPLOY_PATH_MATCHER_NAME=path-matcher-1  # Path matcher name (usually path-matcher-1)
DEPLOY_BACKEND_BUCKET_NAME=              # Leave empty for manual LB updates
DEPLOY_ENABLE_LB_UPDATE=false            # Set to true for automatic LB update (not recommended)
```

#### `.env.production` (Production Environment)

```bash
# ============================================================================
# GCP Deployment Configuration - PRODUCTION
# ============================================================================

# Required: GCP Project Configuration
DEPLOY_PROJECT_ID=my-gcp-project-prod
DEPLOY_BUCKET_NAME=my-app-production

# Required: Build Configuration
DEPLOY_BUILD_DIR=dist

# Optional: GCP Regional Settings
DEPLOY_REGION=us-central1
DEPLOY_BUCKET_LOCATION=US

# Optional: Cache Configuration (Production - longer cache times)
DEPLOY_CACHE_MAX_AGE=31536000            # Static assets cache: 1 year (31536000 seconds)
DEPLOY_HTML_CACHE_MAX_AGE=3600           # HTML files cache: 1 hour (3600 seconds)

# Optional: Compression Settings
DEPLOY_GZIP_EXTENSIONS=js,css,html,json,svg,txt,xml

# Optional: Load Balancer Configuration
DEPLOY_URL_MAP_NAME=my-app-production-lb
DEPLOY_PATH_MATCHER_NAME=path-matcher-1
DEPLOY_BACKEND_BUCKET_NAME=
DEPLOY_ENABLE_LB_UPDATE=false
```

### Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DEPLOY_PROJECT_ID` | Yes | - | GCP Project ID |
| `DEPLOY_BUCKET_NAME` | Yes | - | GCS bucket name for deployments |
| `DEPLOY_BUILD_DIR` | No | `dist` | Build output directory (dist, build, out, public) |
| `DEPLOY_REGION` | No | `us-central1` | GCP region |
| `DEPLOY_BUCKET_LOCATION` | No | `US` | Bucket location (US, EU, ASIA, or specific region) |
| `DEPLOY_CACHE_MAX_AGE` | No | Staging: `86400`<br>Prod: `31536000` | Cache time for static assets (seconds) |
| `DEPLOY_HTML_CACHE_MAX_AGE` | No | Staging: `1800`<br>Prod: `3600` | Cache time for HTML files (seconds) |
| `DEPLOY_GZIP_EXTENSIONS` | No | `js,css,html,json,svg,txt,xml` | File extensions to compress |
| `DEPLOY_URL_MAP_NAME` | No | - | Load balancer URL map name |
| `DEPLOY_PATH_MATCHER_NAME` | No | `path-matcher-1` | Path matcher in URL map |
| `DEPLOY_BACKEND_BUCKET_NAME` | No | - | Backend bucket name (deprecated) |
| `DEPLOY_ENABLE_LB_UPDATE` | No | `false` | Enable automatic LB updates (not recommended) |

## Common Framework Build Directories

When setting `DEPLOY_BUILD_DIR`, use the appropriate value for your framework:

- **React (Vite)**: `dist`
- **React (CRA)**: `build`
- **Next.js (static)**: `out`
- **Angular**: `dist/project-name`
- **Vue**: `dist`
- **Svelte/SvelteKit**: `build`
- **Hugo**: `public`
- **Jekyll**: `_site`
- **11ty**: `_site`

## Usage Examples

### First Time Setup

1. Create environment files:
```bash
cp .env.staging.example .env.staging
cp .env.production.example .env.production
```

2. Edit the files with your GCP project details

3. Authenticate with GCP:
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Deploy to Staging

```bash
# Build your application first
npm run build

# Deploy with interactive prompts
./deploy-staging.sh

# Deploy with all config from .env.staging (CI/CD mode)
./deploy-staging.sh --skip-prompts

# Override build directory
./deploy-staging.sh --build-dir=build
```

### Deploy to Production

```bash
# Build production bundle
npm run build

# Deploy (requires typing "yes" to confirm)
./deploy-production.sh

# CI/CD mode
./deploy-production.sh --skip-prompts
```

### Rollback to Previous Version

```bash
# Interactive rollback
./rollback.sh

# List available releases
./rollback.sh list staging
./rollback.sh list production

# Rollback to specific version
./rollback.sh 20251108-143022-abc123 staging
./rollback.sh 20251108-143022-abc123 production
```

## Load Balancer Setup

For instant rollbacks, configure your load balancer with path rewriting:

1. Create backend bucket:
```bash
gcloud compute backend-buckets create my-app-staging-backend \
  --gcs-bucket-name=my-app-staging \
  --enable-cdn
```

2. Create URL map:
```bash
gcloud compute url-maps create my-app-staging-lb \
  --default-backend-bucket=my-app-staging-backend
```

3. Configure path rewrite in GCP Console:
   - Go to Load Balancing → Your LB → Edit
   - Add route with path rewrite: `/releases/YYYYMMDD-HHMMSS-SHA`

4. Update `.env.staging` with your load balancer name:
```bash
DEPLOY_URL_MAP_NAME=my-app-staging-lb
DEPLOY_PATH_MATCHER_NAME=path-matcher-1
```

## File Structure

```
deploysite-cloudbucket/
├── deploy-production.sh      # Production deployment script
├── deploy-staging.sh          # Staging deployment script
├── rollback.sh                # Rollback utility
├── README.md                  # User documentation
├── CLAUDE.md                  # This file (Claude Code reference)
├── .gitignore                 # Git ignore rules
├── .env.staging               # Staging config (gitignored)
├── .env.production            # Production config (gitignored)
└── .env.example               # Example configuration template
```

## Security Notes

- Environment files (`.env.staging`, `.env.production`) are automatically gitignored
- Never commit environment files containing project IDs or bucket names
- Buckets are configured as publicly readable for static website hosting
- Use Cloud CDN with HTTPS for production deployments
- Consider Identity-Aware Proxy (IAP) for internal applications

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Deploy to Staging

on:
  push:
    branches: [develop]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '20'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v1
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Deploy to GCS
        run: ./deploy-staging.sh --skip-prompts
        env:
          DEPLOY_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
          DEPLOY_BUCKET_NAME: ${{ secrets.GCS_BUCKET_STAGING }}
```

## Troubleshooting

### Build directory not found
- Ensure you've run your build command first: `npm run build`
- Check that `DEPLOY_BUILD_DIR` matches your framework's output directory
- Use `--build-dir=DIR` to override

### Authentication errors
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Permission errors
- Ensure your GCP account has Storage Admin role
- Check that the Storage API is enabled
- Verify bucket permissions with: `gsutil iam get gs://BUCKET_NAME`

### Upload failures
- Check network connectivity
- Verify bucket exists and is writable
- Review logs at `/tmp/gsutil-upload.log`

## Best Practices

1. **Always build before deploying**: Run `npm run build` or equivalent first
2. **Test in staging**: Deploy to staging before production
3. **Keep old releases**: Don't delete old releases immediately (enables instant rollback)
4. **Use CI/CD**: Automate deployments with `--skip-prompts` flag
5. **Monitor cache times**: Staging has shorter cache times for faster testing
6. **Load balancer path rewrite**: Use path rewrite for true zero-downtime rollbacks
7. **Review before production**: Production deployment requires typing "yes" to confirm

## Useful Commands

```bash
# List all releases in a bucket
gsutil ls gs://BUCKET_NAME/releases/

# View release details
gsutil ls -lh gs://BUCKET_NAME/releases/YYYYMMDD-HHMMSS-SHA/

# Test specific release directly
curl https://storage.googleapis.com/BUCKET_NAME/releases/VERSION/index.html

# Download a release for backup
gsutil -m cp -r gs://BUCKET_NAME/releases/VERSION/ ./backup/

# Delete old release
gsutil -m rm -r gs://BUCKET_NAME/releases/OLD_VERSION/

# View bucket in console
https://console.cloud.google.com/storage/browser/BUCKET_NAME
```

## Support

For issues or questions:
- Review the README.md for detailed documentation
- Check script help: `./deploy-staging.sh --help`
- Verify GCP authentication and permissions
- Test with interactive mode first before using `--skip-prompts`
