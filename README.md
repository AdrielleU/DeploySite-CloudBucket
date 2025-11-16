# GCP Static Site Deployment Toolkit

**Simple, lightweight deployment scripts for static web apps on Google Cloud Storage.**

## Purpose

This toolkit is designed for **manual deployments** and **early-stage projects** before setting up full CI/CD pipelines. It's perfect for:
- Quick deployments during development
- Testing production configurations before automating
- Small teams that don't need complex CI/CD yet
- Learning GCP deployment patterns before enterprise setup

**Zero overhead** - just bash scripts that upload your static files to GCS with versioning. No Docker, no build servers, no complicated setup.

## What It Does

1. Takes your **pre-built static files** (HTML, CSS, JS, images)
2. Compresses them with gzip
3. Uploads to **Google Cloud Storage** (bucket root by default, or custom folders)
4. You manually update load balancer to point to new version (if using custom paths)
5. Instant rollback available with versioned deployments

**Works with any framework** that outputs static files:
- React, Vue, Angular, Svelte
- Next.js (static export), Nuxt (static)
- Hugo, Jekyll, 11ty
- Plain HTML/CSS/JS

## How Versioned Deployments Work

### Deployment Options

**Option 1: Bucket Root (Default - Simplest)**

Files deploy directly to bucket root. Perfect for single-app deployments:
```
gs://your-bucket/
├── index.html
├── assets/
├── js/
└── css/
```

**Option 2: Custom Folder Paths (Versioned)**

Deploy to specific folders for multiple versions or apps:

```
gs://your-bucket/releases/
├── v1.0.0/           ← Current production
├── v1.0.1/           ← Newer version
├── v0.9.5/           ← Old version (kept for rollback)
└── v2.0.0-rc1/       ← Staging version
```

Each version is a complete, independent copy of your app.

### Load Balancer Routing (For Custom Paths)

> **Note:** This section applies to deployments using custom folder paths. If deploying to bucket root, you can skip the path rewrite configuration.

When using custom paths, your **Google Cloud Load Balancer** uses **path rewrite** to route traffic to the correct version:

```
┌─────────────────────────────────────────────────────────┐
│  User Request                                           │
│  https://yourapp.com/index.html                         │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Google External Load Balancer                          │
│  - Backend: GCS Bucket                                  │
│  - Path Rewrite: /releases/v1.0.0                       │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Actual File Served                                     │
│  gs://your-bucket/releases/v1.0.0/index.html            │
└─────────────────────────────────────────────────────────┘
```

**Deployment flow:**
1. Deploy new version → Script creates `v1.0.1/` folder in bucket
2. **Manually** update load balancer path rewrite in GCP Console → Change `/releases/v1.0.0` to `/releases/v1.0.1`
3. Traffic now serves from new version instantly

**Rollback flow:**
1. **Manually** change load balancer path rewrite back in GCP Console → `/releases/v1.0.0`
2. Done! No file copying needed, old files are still in bucket.

## Quick Start

### 1. Install Prerequisites

```bash
# Install Google Cloud SDK
# https://cloud.google.com/sdk/docs/install

# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### 2. Setup Environment Files

```bash
# Copy example files
cp .env.example .env.staging
cp .env.example .env.production

# Edit with your settings
nano .env.production
```

**Required settings in `.env.production`:**
```bash
DEPLOY_PROJECT_ID=your-gcp-project-id
DEPLOY_BUCKET_NAME=your-app-production
DEPLOY_VERSION=v1.0.0       # REQUIRED - see versioning below
```

### 3. Deploy

```bash
# Build your app first
npm run build

# Deploy to staging
./deploy-staging.sh

# Deploy to production
./deploy-production.sh
```

## Versioning (REQUIRED)

**You MUST specify a version** for every deployment. No auto-generated timestamps.

### Option 1: Manual Version (Recommended)

Set in your `.env` file:
```bash
DEPLOY_VERSION=v1.0.0
DEPLOY_VERSION=v2.1.3
DEPLOY_VERSION=v1-0-0-staging
```

### Option 2: CLI Override

```bash
./deploy-staging.sh --version=v2.0.0
./deploy-production.sh --version=v1.5.2
```

### Option 3: Git Tag Auto-Detection

```bash
# Create git tag
git tag v1.0.0

# Set in .env file
DEPLOY_VERSION=auto

# Deploy - will use v1.0.0-{git-sha}
./deploy-production.sh
```

### Version Conflict Protection

If a version already exists, deployment will fail:

```
[ERROR] Version v1.0.0 already exists in bucket!

Choose a different version name:
  ./deploy-production.sh --version=v1.0.1
```

This prevents accidental overwrites and maintains your rollback history.

## Deployment Path Options

**By default, files are deployed to the bucket root** for simplicity. You can customize the deployment path if needed.

### Default: Bucket Root

```bash
# Default behavior - deploys to gs://bucket/
./deploy-production.sh --version=v1.0.0

# Explicit bucket root in .env
DEPLOY_RELEASE_PATH=
# or
DEPLOY_RELEASE_PATH=.
```

**⚠️ IMPORTANT: rsync -d behavior**

When deploying to bucket root, the scripts use `gsutil rsync -d` which **deletes files from the bucket that are not in your build directory**. This ensures your deployment exactly matches your build output.

- ✅ Keeps deployment clean and consistent
- ⚠️ Removes any extra files not in your build
- ⚠️ Not suitable if you have other files/folders in the bucket

### Custom Folder Paths

Deploy to a specific folder within your bucket:

```bash
# Deploy to gs://bucket/releases/
./deploy-production.sh --version=v1.0.0 --release-path=releases/

# Deploy to gs://bucket/app/
./deploy-production.sh --version=v1.0.0 --release-path=app/

# Set in .env file
DEPLOY_RELEASE_PATH=frontend/v1/
```

**Benefits of custom paths:**
- Keep multiple versions in the same bucket
- Store other files/folders alongside deployments
- Organize deployments by environment or version
- No accidental deletion of other bucket contents

**When deploying to custom paths:**
- Version conflict checking is enabled (prevents overwriting)
- Other files in bucket are preserved
- You can have multiple deployment paths in one bucket

### Choosing the Right Option

| Scenario | Recommended Path |
|----------|------------------|
| Single app, simple deployment | Bucket root (default) |
| Multiple versions for rollback | Custom path: `releases/` |
| Multiple apps in one bucket | Custom paths: `app1/`, `app2/` |
| Staging + production in same bucket | Custom paths: `staging/`, `production/` |
| Want to keep other files in bucket | Custom path |

## Deployment Safety Checks

Both scripts have **multiple confirmation gates**:

1. ✅ **Version exists check** - Prevents overwriting existing versions
2. ✅ **Initial confirmation** - Type `yes` to start deployment
3. ✅ **Pre-upload summary** - Shows:
   - GCP account being used
   - Project ID
   - Bucket name
   - Version being deployed
   - Number of files
   - Total size
4. ✅ **Final confirmation** - Type `DEPLOY` to upload

**Example pre-upload summary:**
```
============================================
PRODUCTION DEPLOYMENT - FINAL CHECK
============================================

GCP Account & Project:
  Account:       you@example.com
  Project ID:    my-gcp-project
  Environment:   PRODUCTION

Deployment Target:
  Bucket:        gs://my-app-production
  Release Path:  gs://my-app-production/releases/v1.0.0/
  Version:       v1.0.0

Source Files:
  Directory:     /home/user/myapp/dist
  Files:         247
  Total Size:    3.2M

Type 'DEPLOY' to confirm upload:
```

## Load Balancer Setup

### 1. Create Backend Bucket

```bash
gcloud compute backend-buckets create my-app-backend \
  --gcs-bucket-name=my-app-production \
  --enable-cdn
```

### 2. Create Load Balancer with Path Rewrite

**Option A: GCP Console (Easiest)**

1. Go to: [Load Balancing](https://console.cloud.google.com/net-services/loadbalancing)
2. Create HTTP(S) Load Balancer
3. Add Backend → Select your backend bucket
4. Configure routing:
   - Path: `/*`
   - Backend: `my-app-backend`
   - **Advanced route action → URL rewrite**
   - **Path prefix rewrite**: `/releases/v1.0.0`
5. Configure frontend (domain, SSL certificate)
6. Create

**Option B: gcloud Command**

```bash
# Create URL map
gcloud compute url-maps create my-app-lb \
  --default-backend-bucket=my-app-backend

# You'll need to configure path rewrite via console or YAML
```

### 3. Activate New Version (After Each Deployment)

**The deployment script uploads files but doesn't activate them.** After deployment finishes, manually update the load balancer to activate the new version:

**GCP Console:**
1. Load Balancing → Your LB → Edit
2. Host and path rules
3. Update **Path prefix rewrite** to: `/releases/v1.0.1`
4. Save

The deployment script shows you these exact instructions with your version number after each deploy.

## Rollback to Previous Version

Rollback is **manual** via the Load Balancer UI. All versions are kept in the bucket, so you can instantly switch between them.

### How to Rollback

1. **View available versions:**
   ```bash
   gsutil ls gs://BUCKET_NAME/releases/
   ```

2. **Update Load Balancer path rewrite:**
   - Go to: [Load Balancing](https://console.cloud.google.com/net-services/loadbalancing)
   - Click your load balancer → Edit
   - Host and path rules
   - Update **Path prefix rewrite** to: `/releases/v1.0.0` (your old version)
   - Save

Rollback is **instant** - just changes routing, no file copying needed. The old version files are already in the bucket.

## CLI Options

```bash
./deploy-staging.sh [OPTIONS]
./deploy-production.sh [OPTIONS]

Options:
  --version=NAME        Version name (e.g., v1.0.0, v2.1.3)
  --release-path=PATH   Deployment folder path (default: bucket root)
                        Examples: "releases/", "app/", "frontend/v1/"
  --build-dir=DIR       Build directory (default: dist)
  --bucket=NAME         GCS bucket name
  --project=ID          GCP project ID
  --skip-prompts        No interactive prompts (for CI/CD)

Examples:
  ./deploy-staging.sh --version=v2.0.0
  ./deploy-production.sh --version=v1.5.0 --build-dir=build
  ./deploy-production.sh --version=v1.0.0 --release-path=releases/
  ./deploy-staging.sh --skip-prompts  # For automation
```

## Framework Examples

### React (Vite)
```bash
npm run build                    # → dist/
./deploy-staging.sh --version=v1.0.0
```

### Angular
```bash
ng build --configuration production   # → dist/project-name/
./deploy-production.sh --version=v1.0.0 --build-dir=dist/my-app
```

### Next.js (Static Export)
```bash
next build && next export        # → out/
./deploy-staging.sh --version=v1.0.0 --build-dir=out
```

### Hugo
```bash
hugo                             # → public/
./deploy-staging.sh --version=v1.0.0 --build-dir=public
```

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DEPLOY_VERSION` | **Yes** | - | Version name (v1.0.0) or "auto" for git tag |
| `DEPLOY_RELEASE_PATH` | No | `` (bucket root) | Deployment folder path (e.g., "releases/", "app/") |
| `DEPLOY_PROJECT_ID` | **Yes** | - | GCP Project ID |
| `DEPLOY_BUCKET_NAME` | **Yes** | - | GCS bucket name |
| `DEPLOY_BUILD_DIR` | No | `dist` | Build output directory |
| `DEPLOY_REGION` | No | `us-central1` | GCP region |
| `DEPLOY_BUCKET_LOCATION` | No | `US` | Multi-region (US, EU, ASIA) |
| `DEPLOY_CACHE_MAX_AGE` | No | Staging: 86400<br>Prod: 31536000 | Static asset cache (seconds) |
| `DEPLOY_HTML_CACHE_MAX_AGE` | No | Staging: 1800<br>Prod: 3600 | HTML cache (seconds) |
| `DEPLOY_GZIP_EXTENSIONS` | No | `js,css,html,json,svg,txt,xml` | Files to compress |
| `DEPLOY_URL_MAP_NAME` | No | - | Load balancer URL map (for instructions) |

## Git Tag Workflow

If you use git tags for versioning:

```bash
# Create a release tag
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# Deploy using auto-detect
# Set in .env: DEPLOY_VERSION=auto
./deploy-production.sh

# Result: Deploys to releases/v1.0.0-abc123/
```

Common git tag commands:
```bash
git tag v1.0.0              # Create tag
git tag -l                  # List tags
git push origin v1.0.0      # Push tag to remote
git tag -d v1.0.0           # Delete local tag
```

## CI/CD Integration (Later)

Once you're ready to automate, use `--skip-prompts`:

```yaml
# GitHub Actions example
- name: Deploy to Production
  run: ./deploy-production.sh --skip-prompts
  env:
    DEPLOY_VERSION: v${{ github.run_number }}
    DEPLOY_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
    DEPLOY_BUCKET_NAME: ${{ secrets.GCS_BUCKET }}
```

## Troubleshooting

**Error: Version not specified**
- Add `DEPLOY_VERSION=v1.0.0` to your `.env` file
- Or use `--version=v1.0.0` flag

**Error: Version already exists**
- Increment your version: `v1.0.1`
- Or delete old version: `gsutil -m rm -r gs://bucket/releases/v1.0.0/`

**Error: Build directory not found**
- Build your app first: `npm run build`
- Check `DEPLOY_BUILD_DIR` matches your framework's output directory

**Error: Not authenticated with gcloud**
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

**Error: Permission denied**
- Check bucket permissions: `gsutil iam get gs://BUCKET_NAME`
- Ensure Storage API is enabled

## Useful Commands

```bash
# List all versions in bucket
gsutil ls gs://BUCKET_NAME/releases/

# View version details
gsutil ls -lh gs://BUCKET_NAME/releases/v1.0.0/

# Test a specific version directly
curl https://storage.googleapis.com/BUCKET_NAME/releases/v1.0.0/index.html

# Download version for backup
gsutil -m cp -r gs://BUCKET_NAME/releases/v1.0.0/ ./backup/

# Delete old version
gsutil -m rm -r gs://BUCKET_NAME/releases/v0.9.0/

# View in GCP Console
https://console.cloud.google.com/storage/browser/BUCKET_NAME
```

## Secret Management

The toolkit includes `sync-secrets.sh` for managing environment variables in Google Cloud Secret Manager.

### Compare Environment Files

Compare two local `.env` files to see configuration differences:

```bash
# Compare staging vs production configs
./sync-secrets.sh compare .env.staging .env.production

# Output shows:
# - Variables only in file 1 (red)
# - Variables only in file 2 (green)
# - Variables with different values (yellow)
```

### Sync to GCP Secret Manager

Upload environment variables to Google Cloud Secret Manager (with confirmation prompts):

```bash
# Sync staging environment
./sync-secrets.sh sync .env.staging my-gcp-project-staging

# Sync production environment
./sync-secrets.sh sync .env.production my-gcp-project-prod
```

**What it does:**
1. Reads your `.env` file
2. Fetches existing secrets from GCP
3. Shows what will be created/updated
4. **Prompts for confirmation** before making changes
5. Creates new secrets or updates existing ones

**Example output:**
```
Sync Plan:
  Secrets to create: 3
  Secrets to update: 2
  Unchanged secrets: 5

Secrets to CREATE:
+ NEW_API_KEY
+ NEW_FEATURE_FLAG
+ DATABASE_URL

Secrets to UPDATE:
~ DEPLOY_BUCKET_NAME (value changed)
~ DEPLOY_VERSION (value changed)

This will modify secrets in GCP project: my-gcp-project-staging
Do you want to continue? (yes/no):
```

### List Secrets

View all secrets stored in GCP Secret Manager:

```bash
./sync-secrets.sh list my-gcp-project-staging

# Output shows masked values:
# DEPLOY_PROJECT_ID = my-gcp-pro...
# DEPLOY_BUCKET_NAME = my-app-st...
# API_KEY = sk-1234567...
```

### Secret Management Best Practices

1. **Use Secret Manager for CI/CD**: Instead of committing `.env` files, store secrets in GCP and fetch during deployment
2. **Compare before syncing**: Always run `compare` first to understand differences
3. **Never auto-update production**: The script always prompts to prevent accidents
4. **Keep .env files in .gitignore**: Never commit environment files to version control

### Accessing Secrets in CI/CD

```bash
# GitHub Actions example
- name: Load secrets from GCP
  run: |
    gcloud secrets versions access latest --secret="DEPLOY_BUCKET_NAME" > /tmp/.env
    gcloud secrets versions access latest --secret="DEPLOY_PROJECT_ID" >> /tmp/.env
    source /tmp/.env
```

### Required Permissions

To use secret management features, your GCP account needs:
- `secretmanager.secrets.create` - Create new secrets
- `secretmanager.secrets.update` - Update existing secrets
- `secretmanager.versions.add` - Add new secret versions
- `secretmanager.versions.access` - Read secret values

Or use the predefined role: `roles/secretmanager.admin`

## Security Notes

- `.env.production` and `.env.staging` should be in `.gitignore`
- Buckets are configured as publicly readable (for static hosting)
- Use HTTPS with valid SSL certificate via Load Balancer
- Enable Cloud CDN for better performance and DDoS protection
- Consider Cloud Armor for additional security rules

## When to Move to Full CI/CD

Consider setting up proper CI/CD when you:
- Deploy multiple times per day
- Have multiple team members deploying
- Need automated testing before deployment
- Want automated rollback on errors
- Need deployment approvals and audit logs

Good next steps:
- **Cloud Build** - Native GCP build automation
- **GitHub Actions / GitLab CI** - Repository-integrated pipelines
- **Terraform** - Infrastructure as Code for load balancer config
- **Cloud Deploy** - GCP's deployment automation service

This toolkit helps you **learn the patterns** before automating them!
