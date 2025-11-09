# GCP Deployment Scripts

**Framework-Agnostic** static site deployment scripts for Google Cloud Platform.

Works with **any** static site generator or framework:
- ✅ React (Vite, CRA, Next.js static export)
- ✅ Vue (Vite, Vue CLI, Nuxt static)
- ✅ Angular
- ✅ Svelte/SvelteKit
- ✅ Hugo, Jekyll, 11ty
- ✅ Plain HTML/CSS/JS
- ✅ Any framework that outputs static files

**Features:**
- 🚀 Deploy pre-built static files to versioned GCS releases
- 📦 Automatic gzip compression for optimal delivery
- 🔄 Instant zero-copy rollback between versions
- ⚡ Optional load balancer auto-update
- 🎯 Interactive prompts OR fully automated via .env
- 🛠️ CLI arguments for flexible workflows

## Quick Start

**1. Build your application:**
```bash
npm run build       # or yarn build, pnpm build, etc.
```

**2. Deploy:**
```bash
./scripts/gcp/deploy-staging.sh
```

The script will prompt for any missing configuration. That's it!

## Prerequisites

1. **Google Cloud SDK**: Install and authenticate
   ```bash
   gcloud auth login
   gcloud config set project YOUR_PROJECT_ID
   ```

2. **Build your app**: The deployment script expects pre-built static files
   ```bash
   npm run build       # For npm/yarn/pnpm projects
   hugo                # For Hugo
   jekyll build        # For Jekyll
   # etc.
   ```

3. **Environment Configuration (Optional)**:
   For automated/CI deployments, create environment files:
   ```bash
   cp .env.example .env.production
   cp .env.example .env.staging
   ```

3. **Configure Deployment Variables**:

   **In `.env.production`:**
   ```bash
   # Required
   DEPLOY_PROJECT_ID=your-gcp-project-id
   DEPLOY_BUCKET_NAME=techmanager-app-prod

   # Optional
   DEPLOY_REGION=us-central1
   DEPLOY_BUCKET_LOCATION=US
   DEPLOY_CACHE_MAX_AGE=31536000
   DEPLOY_HTML_CACHE_MAX_AGE=3600
   ```

   **In `.env.staging`:**
   ```bash
   # Required
   DEPLOY_PROJECT_ID=your-gcp-project-id-staging
   DEPLOY_BUCKET_NAME=techmanager-app-staging

   # Optional (shorter cache times for staging)
   DEPLOY_REGION=us-central1
   DEPLOY_BUCKET_LOCATION=US
   DEPLOY_CACHE_MAX_AGE=86400
   DEPLOY_HTML_CACHE_MAX_AGE=1800
   ```

## Deployment

### Deploy to Staging

```bash
# Build your app first
npm run build

# Deploy
./scripts/gcp/deploy-staging.sh
```

### Deploy to Production

```bash
npm run build

# Deploy (requires "yes" confirmation)
./scripts/gcp/deploy-production.sh
```

**Production deployment differences:**
- Longer cache times (1 year for assets, 1 hour for HTML)
- Requires explicit "yes" confirmation
- Uses `.env.production` instead of `.env.staging`

### Interactive Mode (Recommended for First Time)

When missing configuration, the scripts will interactively prompt for:
- GCP Project ID
- GCS Bucket Name
- Load Balancer Backend (optional)

### Automated Mode (with .env files)

```bash
# Configure once
cat > .env.staging <<EOF
DEPLOY_PROJECT_ID=my-gcp-project-staging
DEPLOY_BUCKET_NAME=my-app-staging
DEPLOY_BUILD_DIR=dist
EOF

# Deploy automatically (no prompts)
npm run build
./scripts/gcp/deploy-staging.sh --skip-prompts
```

### CLI Arguments

```bash
# Override specific values
./scripts/gcp/deploy-staging.sh --bucket=my-custom-bucket

# Deploy different build directory
./scripts/gcp/deploy-staging.sh --build-dir=build

# For CI/CD (skip prompts, fail if config missing)
./scripts/gcp/deploy-staging.sh --skip-prompts
./scripts/gcp/deploy-production.sh --skip-prompts
```

## Versioned Deployments

All deployments use a **versioned release structure** for easy rollbacks:

```
gs://your-bucket/releases/
├── 20251108-143022-abc123/  (newest release)
├── 20251107-120033-def456/  (previous release)
└── 20251106-094511-ghi789/  (older release)
```

Your **load balancer** is configured to serve from a specific release path (e.g., `/releases/20251108-143022-abc123/`). To rollback, simply update the load balancer to point to a different release - **instant, zero-copy rollback!**

## What the scripts do:

1. **Validates Configuration**: Checks for required environment variables
2. **Enables APIs**: Ensures Storage API is enabled
3. **Creates Bucket**: Creates GCS bucket if it doesn't exist
4. **Builds App**: Runs `npm run build` to create production bundle
5. **Compresses Files**: Gzips all static assets (js, css, html, json, svg)
6. **Uploads to Versioned Release**: Uploads to `gs://bucket/releases/TIMESTAMP-SHA/` with proper cache headers:
   - Static assets: Staging 24 hours, Production 1 year cache
   - HTML files: Staging 30 minutes, Production 1 hour cache
7. **Updates Load Balancer** (optional): Updates backend bucket to serve new release
8. **Lists Available Releases**: Shows all releases for easy rollback reference

## Bucket Configuration

The script automatically:
- Creates the bucket if it doesn't exist
- Configures it for static website hosting
- Makes it publicly readable (for versioned releases)
- Organizes deployments in `releases/` folder with timestamps

## Rollback to Previous Release

### Interactive Rollback

```bash
# Interactive mode - script will guide you
./scripts/gcp/rollback.sh

# Will ask for:
# 1. Environment (staging/production)
# 2. Shows list of available releases
# 3. Prompts for version to rollback to
# 4. Confirms before rolling back
```

### Quick Rollback

```bash
# List available releases
./scripts/gcp/rollback.sh list staging

# Rollback to specific release
./scripts/gcp/rollback.sh 20251107-120033-def456 staging

# Production rollback (requires 'yes' confirmation)
./scripts/gcp/rollback.sh 20251107-120033-def456 production
```

**How it works:**
- Updates load balancer backend to point to the specified release
- Zero downtime, instant switch (no file copying!)
- All old releases remain in bucket until manually deleted

## Cache Headers

- **Static Assets** (js, css, images): 1 year cache with `immutable`
- **HTML Files**: 1 hour cache for faster updates

## Gzip Compression

Files are compressed locally before upload:
- JavaScript (`.js`)
- CSS (`.css`)
- HTML (`.html`)
- JSON (`.json`)
- SVG (`.svg`)
- Text/XML files

All uploads include `Content-Encoding: gzip` header.

## Load Balancer Configuration (URL Map with Path Rewrite)

This is the **recommended setup** for true instant rollback with zero file copying.

### How It Works

Your load balancer uses path rewrite to serve files from versioned folders:

```
User requests: https://your-app.com/app.js
  ↓
Load Balancer rewrites to: /releases/20251108-143022-abc123/app.js
  ↓
Serves from: gs://your-bucket/releases/20251108-143022-abc123/app.js
```

**Rollback = Just change the path rewrite** (instant!)

### Setup Instructions

#### 1. Create Load Balancer with Backend Bucket

```bash
# Create backend bucket
gcloud compute backend-buckets create my-app-staging-backend \
  --gcs-bucket-name=my-app-staging \
  --enable-cdn

# Create URL map with path rewrite
gcloud compute url-maps create my-app-staging-lb \
  --default-backend-bucket=my-app-staging-backend
```

#### 2. Configure Path Rewrite in GCP Console

1. Go to [Load Balancing](https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers)
2. Click your load balancer → Edit
3. Click "Host and path rules"
4. Add or edit route:
   - **Path**: `/*`
   - **Backend**: your-backend-bucket
   - **Advanced route action** → **URL rewrite**
   - **Path prefix rewrite**: `/releases/20251108-143022-abc123`
5. Save

#### 3. Configure in `.env.staging`

```bash
# Enable showing LB update instructions after deploy
DEPLOY_URL_MAP_NAME=my-app-staging-lb
DEPLOY_PATH_MATCHER_NAME=path-matcher-1
```

Now when you deploy, the script will show you the exact commands to update the path rewrite!

### Finding Your URL Map Name

```bash
# List all URL maps
gcloud compute url-maps list

# Describe to see path matchers
gcloud compute url-maps describe YOUR_LB_NAME
```

The path matcher name is usually `path-matcher-1` by default.

### Manual Update After Deploy

After each deployment, update the path rewrite:

**Option 1: GCP Console** (Easiest)
1. Load Balancing → Your LB → Edit
2. Host and path rules
3. Update path prefix to: `/releases/NEW_VERSION`

**Option 2: gcloud Command**
```bash
# Export config
gcloud compute url-maps export my-lb --destination=url-map.yaml

# Edit url-map.yaml - change pathPrefixRewrite to /releases/NEW_VERSION

# Import updated config
gcloud compute url-maps import my-lb --source=url-map.yaml
```

## CLI Reference

### Deploy Scripts

```bash
./scripts/gcp/deploy-staging.sh [OPTIONS]
./scripts/gcp/deploy-production.sh [OPTIONS]

Options:
  --build-dir=DIR       Build directory to deploy (default: dist)
  --bucket=NAME         GCS bucket name
  --project=ID          GCP project ID
  --backend=NAME        Backend bucket name (for LB update)
  --region=REGION       GCP region (default: us-central1)
  --skip-prompts        Skip interactive prompts, fail if config missing
  --help                Show help message

Examples:
  # Interactive mode
  ./scripts/gcp/deploy-staging.sh

  # Angular project
  ./scripts/gcp/deploy-staging.sh --build-dir=dist/my-app

  # CI/CD deployment
  ./scripts/gcp/deploy-production.sh --skip-prompts

  # Override bucket
  ./scripts/gcp/deploy-staging.sh --bucket=my-custom-bucket
```

### Rollback Script (rollback.sh)

```bash
./scripts/gcp/rollback.sh [RELEASE_VERSION] [ENV] [OPTIONS]

Options:
  --project=ID        GCP project ID
  --bucket=NAME       GCS bucket name
  --backend=NAME      Backend bucket name
  --env=ENV           Environment: staging or production
  --skip-prompts      Skip interactive prompts
  --help              Show help

Examples:
  # Interactive mode
  ./scripts/gcp/rollback.sh

  # List releases
  ./scripts/gcp/rollback.sh list staging

  # Rollback to specific version
  ./scripts/gcp/rollback.sh 20251107-120033-def456 staging

  # With CLI options
  ./scripts/gcp/rollback.sh --bucket=my-app --env=production
```

## Framework-Specific Examples

### React (Vite)

```bash
# Build
npm run build              # Outputs to dist/

# Deploy
./scripts/gcp/deploy-staging.sh
```

### Angular

```bash
# Build
ng build --configuration production   # Outputs to dist/project-name/

# Deploy
./scripts/gcp/deploy-production.sh --build-dir=dist/my-app
```

### Vue (Vite)

```bash
# Build
npm run build             # Outputs to dist/

# Deploy
./scripts/gcp/deploy-staging.sh
```

### Next.js (Static Export)

```bash
# Build
npm run build && npm run export   # Outputs to out/

# Deploy
./scripts/gcp/deploy-staging.sh --build-dir=out
```

### Svelte/SvelteKit

```bash
# Build
npm run build             # Outputs to build/

# Deploy
./scripts/gcp/deploy-staging.sh --build-dir=build
```

### Hugo

```bash
# Build
hugo                      # Outputs to public/

# Deploy
./scripts/gcp/deploy-staging.sh --build-dir=public
```

## CI/CD Integration

### GitHub Actions

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
          node-version: '18'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v1
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Deploy to GCS
        run: ./scripts/gcp/deploy-staging.sh --skip-prompts
        env:
          DEPLOY_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
          DEPLOY_BUCKET_NAME: ${{ secrets.GCS_BUCKET_STAGING }}
```

### GitLab CI

```yaml
deploy:staging:
  stage: deploy
  image: google/cloud-sdk:alpine
  script:
    - npm ci
    - npm run build
    - ./scripts/gcp/deploy-staging.sh --skip-prompts
  environment:
    name: staging
  only:
    - develop

deploy:production:
  stage: deploy
  image: google/cloud-sdk:alpine
  script:
    - npm ci
    - npm run build
    - ./scripts/gcp/deploy-production.sh --skip-prompts
  environment:
    name: production
  only:
    - main
  when: manual
```

## Custom Domain Setup

To use a custom domain with your GCS bucket:

1. **Create Load Balancer** in GCP Console
2. **Add Backend Bucket** pointing to your GCS bucket
3. **Enable Cloud CDN** on the backend bucket
4. **Configure DNS** to point to the load balancer IP
5. **Set up SSL certificate** for HTTPS

## Troubleshooting

### Build fails
- Check that `npm install` has been run
- Verify `package.json` has build script
- Check build output directory matches `DEPLOY_BUILD_DIR`

### Upload fails
- Verify GCP authentication: `gcloud auth list`
- Check bucket permissions: `gsutil iam get gs://BUCKET_NAME`
- Ensure Storage API is enabled

### CDN invalidation fails
- Verify load balancer name is correct
- Check that you have permissions for CDN operations
- CDN invalidation is non-fatal and won't block deployment

## Security Notes

- `.env.production` should NOT be committed to git (add to `.gitignore`)
- The bucket is configured as publicly readable for static hosting
- Use Cloud CDN with HTTPS for production
- Consider using Identity-Aware Proxy (IAP) for internal apps

## Useful Commands

```bash
# List all releases
gsutil ls gs://BUCKET_NAME/releases/

# List files in specific release
gsutil ls -lh gs://BUCKET_NAME/releases/20251108-143022-abc123/

# View bucket in console
https://console.cloud.google.com/storage/browser/BUCKET_NAME

# Download specific release
gsutil -m cp -r gs://BUCKET_NAME/releases/20251108-143022-abc123/ ./backup

# Delete old release
gsutil -m rm -r gs://BUCKET_NAME/releases/20251106-094511-ghi789/

# Test specific release directly
curl https://storage.googleapis.com/BUCKET_NAME/releases/VERSION/index.html

# Set CORS policy (if needed for APIs)
gsutil cors set cors.json gs://BUCKET_NAME
```

## Release Management

### Viewing Releases

Each deployment creates a timestamped release folder. To see what's deployed:

```bash
# List all releases with sizes
gsutil du -sh gs://BUCKET_NAME/releases/*

# See release details
gsutil ls -lh gs://BUCKET_NAME/releases/20251108-143022-abc123/
```

### Cleaning Up Old Releases

Releases are kept indefinitely for easy rollback. Clean up manually when needed:

```bash
# Delete releases older than 30 days (adjust as needed)
gsutil ls gs://BUCKET_NAME/releases/ | head -n -5 | xargs -I {} gsutil -m rm -r {}

# Or delete specific release
gsutil -m rm -r gs://BUCKET_NAME/releases/20251106-094511-ghi789/
```
