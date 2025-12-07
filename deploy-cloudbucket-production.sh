#!/usr/bin/env bash
# ============================================================================
# Deploy Static Frontend to Google Cloud Storage (Production)
# ============================================================================
# Framework-agnostic deployment script for any static site generator
# (React, Vue, Angular, Svelte, Next.js, etc.)
#
# Features:
# - Deploys pre-built static files to versioned GCS releases
# - Compresses assets with gzip for optimal delivery
# - Optional load balancer backend updates
# - Instant rollback capability
# - Interactive prompts OR automated via .env
#
# Usage:
#   ./scripts/gcp/deploy-production.sh [OPTIONS]
#
# Options:
#   --version=NAME        Version name (e.g., v1.0.0, v2.0.0)
#   --release-path=PATH   Deployment folder path (default: bucket root)
#                         Examples: "releases/", "app/", "frontend/v1/"
#   --build-dir=DIR       Build directory to deploy (default: dist)
#   --bucket=NAME         GCS bucket name
#   --project=ID          GCP project ID
#   --backend=NAME        Backend bucket name (for LB update)
#   --region=REGION       GCP region (default: us-central1)
#   --skip-prompts        Skip interactive prompts, fail if config missing
#   --help                Show this help message
#
# Examples:
#   ./scripts/gcp/deploy-production.sh --version=v1.0.0
#     # Deploys to bucket root (default)
#
#   ./scripts/gcp/deploy-production.sh --version=v2.0.0 --release-path=releases/
#     # Deploys to gs://bucket/releases/
#
#   ./scripts/gcp/deploy-production.sh --version=v1.0.0 --release-path=app/
#     # Deploys to gs://bucket/app/
#
#   ./scripts/gcp/deploy-production.sh --skip-prompts  # For CI/CD
# ============================================================================

set -euo pipefail

# Configuration
ENVIRONMENT="production"
MAX_RETRIES=3
RETRY_DELAY=5
TEMP_FILES=()

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_prompt() {
    echo -e "${CYAN}[INPUT]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# Cleanup function for temp files
cleanup() {
    local exit_code=$?

    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        log_info "Cleaning up temporary files..."
        for file in "${TEMP_FILES[@]}"; do
            rm -f "$file" 2>/dev/null || true
        done
    fi

    if [ $exit_code -ne 0 ]; then
        echo ""
        log_error "Deployment failed with exit code: $exit_code"
        log_info "Check the errors above for details"
    fi

    exit $exit_code
}

# Trap errors and interrupts
trap cleanup EXIT INT TERM

# Retry function for commands
retry_command() {
    local max_attempts=$1
    shift
    local command=("$@")
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "${command[@]}"; then
            return 0
        else
            local exit_code=$?
            if [ $attempt -lt $max_attempts ]; then
                log_warn "Command failed (attempt $attempt/$max_attempts). Retrying in ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
                ((attempt++))
            else
                log_error "Command failed after $max_attempts attempts"
                return $exit_code
            fi
        fi
    done
}

show_help() {
    sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

# ============================================================================
# Validation Functions
# ============================================================================

# Check if required commands are available
check_dependencies() {
    local missing_deps=()

    if ! command -v gcloud &> /dev/null; then
        missing_deps+=("gcloud")
    fi

    if ! command -v gsutil &> /dev/null; then
        missing_deps+=("gsutil")
    fi

    if ! command -v gzip &> /dev/null; then
        missing_deps+=("gzip")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install Google Cloud SDK: https://cloud.google.com/sdk/install"
        exit 1
    fi
}

# Verify gcloud authentication
check_gcloud_auth() {
    log_step "Verifying gcloud authentication..."

    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "."; then
        log_error "Not authenticated with gcloud"
        log_error "Please run: gcloud auth login"
        exit 1
    fi

    log_success "Authenticated with gcloud"
}

# Validate build directory
validate_build_dir() {
    local build_dir=$1

    if [ ! -d "$build_dir" ]; then
        log_error "Build directory not found: ${build_dir}"
        return 1
    fi

    # Check if directory has files
    local file_count=$(find "$build_dir" -type f | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log_error "Build directory is empty: ${build_dir}"
        return 1
    fi

    # Check for index.html (common for SPAs)
    if [ ! -f "$build_dir/index.html" ]; then
        log_warn "No index.html found in build directory"
        log_warn "This might be expected for some frameworks"
    fi

    log_success "Build directory validated (${file_count} files)"
    return 0
}

# Check bucket accessibility
check_bucket_access() {
    local bucket=$1

    log_step "Checking bucket access..."

    if gsutil ls -b "gs://${bucket}" >/dev/null 2>&1; then
        # Check if we can write
        local test_file=$(mktemp)
        echo "test" > "$test_file"
        TEMP_FILES+=("$test_file")

        if gsutil cp "$test_file" "gs://${bucket}/.deployment-test" >/dev/null 2>&1; then
            gsutil rm "gs://${bucket}/.deployment-test" >/dev/null 2>&1 || true
            log_success "Bucket is accessible and writable"
            return 0
        else
            log_error "Bucket exists but is not writable"
            log_error "Check your GCS bucket permissions"
            return 1
        fi
    else
        return 1
    fi
}

# ============================================================================
# Parse Arguments
# ============================================================================

CLI_PROJECT_ID=""
CLI_BUCKET_NAME=""
CLI_BACKEND_NAME=""
CLI_BUILD_DIR=""
CLI_REGION=""
CLI_VERSION=""
CLI_RELEASE_PATH=""
SKIP_PROMPTS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version=*)
            CLI_VERSION="${1#*=}"
            shift
            ;;
        --release-path=*)
            CLI_RELEASE_PATH="${1#*=}"
            shift
            ;;
        --project=*)
            CLI_PROJECT_ID="${1#*=}"
            shift
            ;;
        --bucket=*)
            CLI_BUCKET_NAME="${1#*=}"
            shift
            ;;
        --backend=*)
            CLI_BACKEND_NAME="${1#*=}"
            shift
            ;;
        --build-dir=*)
            CLI_BUILD_DIR="${1#*=}"
            shift
            ;;
        --region=*)
            CLI_REGION="${1#*=}"
            shift
            ;;
        --skip-prompts)
            SKIP_PROMPTS=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown argument: $1"
            log_error "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# Load Configuration
# ============================================================================

# Use production environment file
ENV_FILE="$PROJECT_ROOT/.env.production"

# Fall back to .env if .env.production doesn't exist
if [ ! -f "$ENV_FILE" ] && [ -f "$PROJECT_ROOT/.env" ]; then
    ENV_FILE="$PROJECT_ROOT/.env"
fi

ENV_FILE_EXISTS=false
if [ -f "$ENV_FILE" ]; then
    ENV_FILE_EXISTS=true
    log_info "Loading configuration from: ${ENV_FILE}"
fi

# Helper function to read env values
get_env_value() {
    local key=$1
    local file=$2
    local default=${3:-""}

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    local value=$(grep "^${key}=" "$file" 2>/dev/null | head -1 | sed -E 's/^[^=]+=//; s/[[:space:]]+#.*$//')
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Interactive prompt helper
prompt_with_default() {
    local prompt=$1
    local default=$2

    if [ -n "$default" ]; then
        read -p "$(echo -e "${CYAN}${prompt} [${default}]:${NC} ")" value
        echo "${value:-$default}"
    else
        read -p "$(echo -e "${CYAN}${prompt}:${NC} ")" value
        echo "$value"
    fi
}

# Load from .env
ENV_PROJECT_ID=$(get_env_value "DEPLOY_PROJECT_ID" "$ENV_FILE")
ENV_BUCKET_NAME=$(get_env_value "DEPLOY_BUCKET_NAME" "$ENV_FILE")
ENV_REGION=$(get_env_value "DEPLOY_REGION" "$ENV_FILE" "us-central1")
ENV_BUCKET_LOCATION=$(get_env_value "DEPLOY_BUCKET_LOCATION" "$ENV_FILE" "US")
ENV_BUILD_DIR=$(get_env_value "DEPLOY_BUILD_DIR" "$ENV_FILE" "dist")
ENV_VERSION=$(get_env_value "DEPLOY_VERSION" "$ENV_FILE")
ENV_RELEASE_PATH=$(get_env_value "DEPLOY_RELEASE_PATH" "$ENV_FILE")
ENV_BACKEND_BUCKET_NAME=$(get_env_value "DEPLOY_BACKEND_BUCKET_NAME" "$ENV_FILE")
ENV_ENABLE_LB_UPDATE=$(get_env_value "DEPLOY_ENABLE_LB_UPDATE" "$ENV_FILE" "false")
ENV_URL_MAP_NAME=$(get_env_value "DEPLOY_URL_MAP_NAME" "$ENV_FILE")
ENV_PATH_MATCHER_NAME=$(get_env_value "DEPLOY_PATH_MATCHER_NAME" "$ENV_FILE" "path-matcher-1")

# Production-specific cache settings
ENV_CACHE_MAX_AGE=$(get_env_value "DEPLOY_CACHE_MAX_AGE" "$ENV_FILE" "31536000")
ENV_HTML_CACHE_MAX_AGE=$(get_env_value "DEPLOY_HTML_CACHE_MAX_AGE" "$ENV_FILE" "3600")
ENV_GZIP_EXTENSIONS=$(get_env_value "DEPLOY_GZIP_EXTENSIONS" "$ENV_FILE" "js,css,html,json,svg,txt,xml")

# CLI overrides .env
PROJECT_ID="${CLI_PROJECT_ID:-$ENV_PROJECT_ID}"
BUCKET_NAME="${CLI_BUCKET_NAME:-$ENV_BUCKET_NAME}"
REGION="${CLI_REGION:-$ENV_REGION}"
BUILD_DIR="${CLI_BUILD_DIR:-$ENV_BUILD_DIR}"
DEPLOY_VERSION="${CLI_VERSION:-$ENV_VERSION}"
DEPLOY_RELEASE_PATH="${CLI_RELEASE_PATH:-$ENV_RELEASE_PATH}"
BACKEND_BUCKET_NAME="${CLI_BACKEND_NAME:-$ENV_BACKEND_BUCKET_NAME}"
BUCKET_LOCATION="$ENV_BUCKET_LOCATION"
CACHE_MAX_AGE="$ENV_CACHE_MAX_AGE"
HTML_CACHE_MAX_AGE="$ENV_HTML_CACHE_MAX_AGE"
GZIP_EXTENSIONS="$ENV_GZIP_EXTENSIONS"
ENABLE_LB_UPDATE="$ENV_ENABLE_LB_UPDATE"
URL_MAP_NAME="$ENV_URL_MAP_NAME"
PATH_MATCHER_NAME="$ENV_PATH_MATCHER_NAME"

# Interactive prompts for missing config
if [ -z "$PROJECT_ID" ]; then
    if [ "$SKIP_PROMPTS" = true ]; then
        log_error "DEPLOY_PROJECT_ID not set and --skip-prompts enabled"
        exit 1
    fi
    echo ""
    log_prompt "GCP Project ID not found in $ENV_FILE"

    # Try to get default from gcloud config
    DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")

    PROJECT_ID=$(prompt_with_default "Enter GCP Project ID" "$DEFAULT_PROJECT")
    if [ -z "$PROJECT_ID" ]; then
        log_error "Project ID is required"
        exit 1
    fi
fi

if [ -z "$BUCKET_NAME" ]; then
    if [ "$SKIP_PROMPTS" = true ]; then
        log_error "DEPLOY_BUCKET_NAME not set and --skip-prompts enabled"
        exit 1
    fi
    echo ""
    log_prompt "GCS Bucket Name not found in $ENV_FILE"

    # Suggest a bucket name based on project ID + environment
    if [ -n "$PROJECT_ID" ]; then
        SUGGESTED_BUCKET="${PROJECT_ID}-production"
    else
        SUGGESTED_BUCKET="my-app-production"
    fi

    BUCKET_NAME=$(prompt_with_default "Enter GCS bucket name" "$SUGGESTED_BUCKET")
    if [ -z "$BUCKET_NAME" ]; then
        log_error "Bucket name is required"
        exit 1
    fi
fi

# Optional interactive prompts
if [ "$SKIP_PROMPTS" = false ] && [ -z "$BACKEND_BUCKET_NAME" ] && [ "$ENV_FILE_EXISTS" = false ]; then
    echo ""
    log_prompt "Load Balancer Backend Bucket (optional for auto-update)"
    BACKEND_BUCKET_NAME=$(prompt_with_default "Enter backend bucket name (or press Enter to skip)" "")
fi

# Auto-disable LB update if no backend name
if [ -z "$BACKEND_BUCKET_NAME" ]; then
    ENABLE_LB_UPDATE="false"
fi

# Resolve build directory path
# Expand tilde if present
BUILD_DIR="${BUILD_DIR/#\~/$HOME}"

if [[ "$BUILD_DIR" = /* ]]; then
    BUILD_DIR_PATH="$BUILD_DIR"
else
    BUILD_DIR_PATH="$PROJECT_ROOT/$BUILD_DIR"
fi

# Validate build directory exists
if [ ! -d "$BUILD_DIR_PATH" ]; then
    log_error "Build directory not found: ${BUILD_DIR_PATH}"

    if [ "$SKIP_PROMPTS" = false ]; then
        log_info ""
        log_info "Please enter the path to your build directory:"
        read -p "$(echo -e "${CYAN}Build directory path:${NC} ")" custom_build_dir

        if [ -z "$custom_build_dir" ]; then
            log_error "No build directory specified"
            exit 1
        fi

        # Resolve custom build directory path
        # Strip any leading/trailing whitespace
        custom_build_dir=$(echo "$custom_build_dir" | xargs)

        # Expand tilde and resolve path
        custom_build_dir="${custom_build_dir/#\~/$HOME}"

        # Check if absolute path (starts with /)
        if [[ "$custom_build_dir" == /* ]]; then
            BUILD_DIR_PATH="$custom_build_dir"
        else
            BUILD_DIR_PATH="$PROJECT_ROOT/$custom_build_dir"
        fi

        # Validate the new path
        if [ ! -d "$BUILD_DIR_PATH" ]; then
            log_error "Build directory still not found: ${BUILD_DIR_PATH}"
            exit 1
        fi
    else
        log_error ""
        log_error "Please build your application first:"
        log_error "  npm run build        (for npm)"
        log_error "  yarn build           (for yarn)"
        log_error "  pnpm build           (for pnpm)"
        log_error ""
        log_error "Or specify correct build directory with --build-dir=DIR"
        exit 1
    fi
fi

# Build configuration - Version naming
# Version is REQUIRED - no fallback versioning
if [ -z "$DEPLOY_VERSION" ]; then
    echo ""
    log_error "Version not specified!"
    echo ""
    log_info "You must specify a version using one of these methods:"
    echo ""
    log_info "1. Use --version flag:"
    log_info "   ${CYAN}./deploy-production.sh --version=v1.0.0${NC}"
    echo ""
    log_info "2. Set DEPLOY_VERSION in .env.production:"
    log_info "   ${CYAN}DEPLOY_VERSION=v1.0.0${NC}"
    echo ""
    log_info "3. Create a git tag and set DEPLOY_VERSION=auto:"
    log_info "   ${CYAN}git tag v1.0.0${NC}"
    log_info "   ${CYAN}DEPLOY_VERSION=auto${NC}"
    echo ""
    log_info "Version format examples:"
    log_info "   v1.0.0, v2.1.3, v1-0-0, v2-5-1"
    echo ""
    exit 1
fi

# Handle special "auto" value - use git tag
if [ "$DEPLOY_VERSION" = "auto" ]; then
    SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
    GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

    if [ -z "$GIT_TAG" ]; then
        log_error "DEPLOY_VERSION=auto but no git tags found"
        log_error "Create a git tag first: git tag v1.0.0"
        exit 1
    fi

    BUILD_TAG="${GIT_TAG}-${SHORT_SHA}"
    log_info "Using auto-detected version from git tag: ${BUILD_TAG}"
else
    # Use manually specified version
    BUILD_TAG="$DEPLOY_VERSION"
fi

# ============================================================================
# Determine Release Path
# ============================================================================

# Construct the full release path based on configuration
if [ -z "$DEPLOY_RELEASE_PATH" ]; then
    # Default: bucket root (no subfolder)
    RELEASE_FULL_PATH=""
elif [ "$DEPLOY_RELEASE_PATH" = "." ] || [ "$DEPLOY_RELEASE_PATH" = "/" ] || [ "$DEPLOY_RELEASE_PATH" = "root" ]; then
    # Explicitly deploy to bucket root
    RELEASE_FULL_PATH=""
else
    # Custom path - ensure it ends with /
    RELEASE_FULL_PATH="${DEPLOY_RELEASE_PATH%/}/"
fi

# ============================================================================
# Check if version already exists
# ============================================================================

check_version_exists() {
    local bucket=$1
    local release_path=$2

    # Skip check if deploying to bucket root (would check entire bucket)
    if [ -z "$release_path" ]; then
        log_warn "Deploying to bucket root - skipping version exists check"
        return 0
    fi

    # Check if this release path already exists in GCS
    if gsutil ls "gs://${bucket}/${release_path}" >/dev/null 2>&1; then
        echo ""
        log_error "Release path '${release_path}' already exists in bucket!"
        echo ""
        log_warn "This path has already been deployed. You cannot overwrite existing releases."
        echo ""
        log_info "Existing files at this path:"
        gsutil ls "gs://${bucket}/${release_path}" | head -10
        echo ""
        log_info "Choose a different option:"
        log_info "  Option 1: Change version"
        log_info "    ${CYAN}./deploy-production.sh --version=v0.5.6${NC}"
        echo ""
        log_info "  Option 2: Change release path"
        log_info "    ${CYAN}./deploy-production.sh --release-path=app/v2/${NC}"
        echo ""
        log_info "  Option 3: Update in .env.production"
        log_info "    ${CYAN}DEPLOY_VERSION=v0.5.6${NC} or ${CYAN}DEPLOY_RELEASE_PATH=custom/path/${NC}"
        echo ""
        log_info "  Option 4: Delete old release first (dangerous!)"
        log_info "    ${CYAN}gsutil -m rm -r gs://${bucket}/${release_path}${NC}"
        echo ""
        return 1
    fi
    return 0
}

# Only check if bucket name is set (it might not be if prompts are needed)
if [ -n "$BUCKET_NAME" ]; then
    log_step "Checking if release path already exists..."
    if ! check_version_exists "$BUCKET_NAME" "$RELEASE_FULL_PATH"; then
        exit 1
    fi
    if [ -z "$RELEASE_FULL_PATH" ]; then
        log_success "Deploying to bucket root"
    else
        log_success "Release path '${RELEASE_FULL_PATH}' is available"
    fi
    echo ""
fi

# ============================================================================
# Helper Functions
# ============================================================================

# Create bucket if it doesn't exist
ensure_bucket_exists() {
    local bucket=$1

    if gsutil ls -b "gs://${bucket}" >/dev/null 2>&1; then
        log_info "✓ Bucket exists: ${bucket}"
        return 0
    fi

    log_warn "Bucket does not exist: ${bucket}"

    if [ "$SKIP_PROMPTS" = false ]; then
        read -p "$(echo -e "${CYAN}Create bucket? (y/N):${NC} ")" create_bucket
        if [[ ! "$create_bucket" =~ ^[Yy]$ ]]; then
            log_error "Deployment cancelled"
            exit 1
        fi
    fi

    log_info "Creating bucket: ${bucket}"
    gsutil mb -p "${PROJECT_ID}" -l "${BUCKET_LOCATION}" -b on "gs://${bucket}"

    if [ $? -eq 0 ]; then
        log_info "✓ Bucket created: ${bucket}"

        # Configure bucket for website hosting
        log_info "Configuring bucket for static website hosting..."
        gsutil web set -m index.html -e index.html "gs://${bucket}"

        # Make bucket public
        log_info "Making bucket publicly readable..."
        gsutil iam ch allUsers:objectViewer "gs://${bucket}"

        return 0
    else
        log_error "Failed to create bucket: ${bucket}"
        return 1
    fi
}

# Gzip files based on extensions
gzip_files() {
    local dist_dir=$1
    local extensions=$2

    log_info "Compressing files with gzip..."

    # Check available disk space
    local available_space=$(df "$dist_dir" | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 100000 ]; then
        log_warn "Low disk space available (less than 100MB)"
    fi

    IFS=',' read -ra EXT_ARRAY <<< "$extensions"

    local count=0
    local failed=0
    for ext in "${EXT_ARRAY[@]}"; do
        ext="${ext// /}"

        while IFS= read -r -d '' file; do
            if gzip -9 -k -f "$file" 2>/dev/null; then
                count=$((count + 1))
            else
                log_warn "Failed to compress: $file"
                failed=$((failed + 1))
            fi
        done < <(find "$dist_dir" -type f -name "*.${ext}" ! -name "*.gz" -print0)
    done

    if [ $count -gt 0 ]; then
        log_success "✓ Compressed ${count} files"
    else
        log_warn "No files compressed (may already be compressed)"
    fi

    if [ $failed -gt 0 ]; then
        log_warn "Failed to compress ${failed} files (continuing anyway)"
    fi

    return 0
}

# Upload files to GCS with proper headers (versioned releases)
upload_to_gcs() {
    local dist_dir=$1
    local bucket=$2
    local release_path=$3

    if [ -z "$release_path" ]; then
        log_info "Uploading files to bucket root"
    else
        log_info "Uploading files to: ${release_path}"
    fi

    # Count files to upload (exclude .gz files)
    local total_files=$(find "$dist_dir" -type f ! -name "*.gz" | wc -l)
    log_info "  Found ${total_files} files to upload"

    cd "$dist_dir" || {
        log_error "Failed to change to build directory: $dist_dir"
        return 1
    }

    # Upload all non-.gz files except HTML (HTML handled separately for proper caching)
    log_info "  Uploading uncompressed assets..."
    if ! retry_command $MAX_RETRIES gsutil -m rsync -r -d \
        -x ".*\.html$|.*\.gz$" \
        . "gs://${bucket}/${release_path}" 2>&1 | tee /tmp/gsutil-upload.log; then
        log_error "Failed to upload files after $MAX_RETRIES attempts"
        log_error "Check /tmp/gsutil-upload.log for details"
        cd "$PROJECT_ROOT"
        return 1
    fi

    # Set cache metadata for uploaded assets (non-HTML, non-gzip)
    log_info "  Setting cache headers for assets..."
    local asset_count=0
    while IFS= read -r file; do
        remote_path="${file#./}"
        if gsutil -h "Cache-Control:public, max-age=${CACHE_MAX_AGE}" \
                   setmeta "gs://${bucket}/${release_path}${remote_path}" >/dev/null 2>&1; then
            asset_count=$((asset_count + 1))
        fi
    done < <(find . -type f ! -name "*.html" ! -name "*.gz")

    if [ $asset_count -gt 0 ]; then
        log_success "✓ Set cache headers for ${asset_count} assets"
    fi

    # Upload gzipped files with Content-Encoding header
    log_info "  Uploading compressed assets..."
    local gzip_count=0
    local gzip_failed=0
    while IFS= read -r file; do
        # Remove .gz extension for remote path (browsers will see original filename)
        local remote_path="${file#./}"
        local original_name="${remote_path%.gz}"

        # Determine content type based on original extension
        local content_type="application/octet-stream"
        case "$original_name" in
            *.js) content_type="application/javascript" ;;
            *.css) content_type="text/css" ;;
            *.json) content_type="application/json" ;;
            *.svg) content_type="image/svg+xml" ;;
            *.txt) content_type="text/plain" ;;
            *.xml) content_type="application/xml" ;;
        esac

        # Upload with proper headers
        if gsutil -h "Content-Encoding:gzip" \
                   -h "Content-Type:${content_type}" \
                   -h "Cache-Control:public, max-age=${CACHE_MAX_AGE}" \
                   cp "$file" "gs://${bucket}/${release_path}${original_name}" >/dev/null 2>&1; then
            gzip_count=$((gzip_count + 1))
        else
            gzip_failed=$((gzip_failed + 1))
            log_warn "Failed to upload compressed: $file"
        fi
    done < <(find . -name "*.gz" -type f ! -name "*.html.gz")

    if [ $gzip_count -gt 0 ]; then
        log_success "✓ Uploaded ${gzip_count} compressed assets"
    fi

    if [ $gzip_failed -gt 0 ]; then
        log_error "Failed to upload $gzip_failed compressed files"
        cd "$PROJECT_ROOT"
        return 1
    fi

    # Upload HTML files with shorter cache
    log_info "  Uploading HTML files..."
    local html_count=0
    local html_failed=0
    while IFS= read -r file; do
        remote_path="${file#./}"

        if gsutil -h "Content-Type:text/html" \
                   -h "Cache-Control:public, max-age=${HTML_CACHE_MAX_AGE}" \
                   cp "$file" "gs://${bucket}/${release_path}${remote_path}" >/dev/null 2>&1; then
            html_count=$((html_count + 1))
        else
            html_failed=$((html_failed + 1))
            log_warn "Failed to upload: $file"
        fi
    done < <(find . -name "*.html" -type f)

    if [ $html_count -eq 0 ]; then
        log_warn "No HTML files uploaded"
    else
        log_success "✓ Uploaded $html_count HTML files"
    fi

    if [ $html_failed -gt 0 ]; then
        log_error "Failed to upload $html_failed HTML files"
        cd "$PROJECT_ROOT"
        return 1
    fi

    # Upload compressed HTML files
    log_info "  Uploading compressed HTML files..."
    local html_gz_count=0
    while IFS= read -r file; do
        # Remove .gz extension for remote path
        local remote_path="${file#./}"
        local original_name="${remote_path%.gz}"

        if gsutil -h "Content-Encoding:gzip" \
                   -h "Content-Type:text/html" \
                   -h "Cache-Control:public, max-age=${HTML_CACHE_MAX_AGE}" \
                   cp "$file" "gs://${bucket}/${release_path}${original_name}" >/dev/null 2>&1; then
            html_gz_count=$((html_gz_count + 1))
        fi
    done < <(find . -name "*.html.gz" -type f)

    if [ $html_gz_count -gt 0 ]; then
        log_success "✓ Uploaded ${html_gz_count} compressed HTML files"
    fi

    # Clean up .gz files from build directory
    log_info "  Cleaning up temporary gzip files..."
    find . -name "*.gz" -type f -delete 2>/dev/null || true
    log_success "✓ Cleaned up gzip files"

    cd "$PROJECT_ROOT"

    # Verify upload
    log_step "Verifying upload..."
    if retry_command $MAX_RETRIES gsutil ls "gs://${bucket}/${release_path}index.html" >/dev/null 2>&1 || \
       retry_command $MAX_RETRIES gsutil ls "gs://${bucket}/${release_path}" | grep -q "."; then
        log_success "Upload complete to gs://${bucket}/${release_path}"
        return 0
    else
        log_error "Upload verification failed - no files found in release"
        log_error "Check network connectivity and bucket permissions"
        return 1
    fi
}

# Show instructions for updating Load Balancer URL Map
update_load_balancer() {
    local url_map=$1
    local path_matcher=$2
    local version=$3

    if [ -z "$url_map" ]; then
        log_info "Load balancer update instructions not shown (DEPLOY_URL_MAP_NAME not set)"
        return 0
    fi

    echo ""
    log_info "${YELLOW}============================================${NC}"
    log_info "${YELLOW}Load Balancer Update Required${NC}"
    log_info "${YELLOW}============================================${NC}"
    echo ""
    log_info "To activate this release, update your load balancer routing:"
    echo ""
    log_info "${CYAN}Option 1: GCP Console (Easiest)${NC}"
    log_info "  1. Go to: https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=${PROJECT_ID}"
    log_info "  2. Click on your load balancer: ${BLUE}${url_map}${NC}"
    log_info "  3. Click 'Edit' → 'Host and path rules'"
    log_info "  4. Update path rewrite to: ${GREEN}/releases/${version}${NC}"
    log_info "  5. Click 'Update'"
    echo ""
    log_info "${CYAN}Option 2: gcloud Command${NC}"
    log_info "  Export current configuration:"
    echo "    ${BLUE}gcloud compute url-maps export ${url_map} \\${NC}"
    echo "    ${BLUE}  --destination=url-map.yaml \\${NC}"
    echo "    ${BLUE}  --project=${PROJECT_ID}${NC}"
    echo ""
    log_info "  Edit url-map.yaml and update the path matcher '${path_matcher}':"
    log_info "  Change pathPrefixRewrite to: ${GREEN}/releases/${version}${NC}"
    echo ""
    log_info "  Import updated configuration:"
    echo "    ${BLUE}gcloud compute url-maps import ${url_map} \\${NC}"
    echo "    ${BLUE}  --source=url-map.yaml \\${NC}"
    echo "    ${BLUE}  --project=${PROJECT_ID}${NC}"
    echo ""
    log_info "After updating, your site will serve the new release instantly!"
}

# List available releases for rollback
list_releases() {
    local bucket=$1

    log_info "Available releases:"
    gsutil ls "gs://${bucket}/releases/" 2>/dev/null | grep -E "releases/[0-9]" | while read -r release_path; do
        local release_name=$(basename "$release_path")
        echo "  - ${release_name}"
    done || log_warn "No previous releases found"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

log_step "Running pre-flight checks..."
check_dependencies
check_gcloud_auth
echo ""

# ============================================================================
# Start Deployment
# ============================================================================

log_info "${BLUE}============================================${NC}"
log_info "${BLUE}Frontend Deployment - PRODUCTION${NC}"
log_info "${BLUE}============================================${NC}"
echo ""
log_info "Configuration:"
log_info "  Environment:  production"
log_info "  Project:      ${PROJECT_ID}"
log_info "  Region:       ${REGION}"
log_info "  Bucket:       gs://${BUCKET_NAME}"
log_info "  Build Dir:    ${BUILD_DIR_PATH}"
log_info "  Release:      ${BUILD_TAG}"
if [ -n "$URL_MAP_NAME" ]; then
    log_info "  URL Map:      ${URL_MAP_NAME}"
    log_info "  Path Matcher: ${PATH_MATCHER_NAME}"
fi
echo ""

# Confirm deployment in interactive mode
if [ "$SKIP_PROMPTS" = false ]; then
    read -p "$(echo -e "${CYAN}Type 'yes' to proceed with deployment:${NC} ")" confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Deployment cancelled"
        exit 0
    fi
    echo ""
fi

# Step 1: Validate build directory
log_step "Validating build directory..."
if ! validate_build_dir "$BUILD_DIR_PATH"; then
    exit 1
fi
echo ""

# Step 2: Set active project
log_step "Setting active GCP project..."
gcloud config set project "$PROJECT_ID" --quiet
echo ""

# Step 3: Enable required APIs
log_step "Ensuring required APIs are enabled..."
retry_command $MAX_RETRIES gcloud services enable storage-api.googleapis.com --quiet
echo ""

# Step 4: Ensure bucket exists
log_step "Checking GCS bucket..."
ensure_bucket_exists "$BUCKET_NAME"
echo ""

# Step 5: Check bucket access
if ! check_bucket_access "$BUCKET_NAME"; then
    log_error "Cannot access bucket: ${BUCKET_NAME}"
    exit 1
fi
echo ""

# Step 6: Gzip files for optimal delivery
log_step "Compressing files..."
gzip_files "$BUILD_DIR_PATH" "$GZIP_EXTENSIONS"
echo ""

# Step 6.5: Pre-upload Summary and Confirmation
log_step "Final pre-upload verification..."
echo ""

# Get current GCP account
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "unknown")

# Count files and get size
FILE_COUNT=$(find "$BUILD_DIR_PATH" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$BUILD_DIR_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")

log_info "${YELLOW}============================================${NC}"
log_info "${YELLOW}DEPLOYMENT SUMMARY - FINAL CHECK${NC}"
log_info "${YELLOW}============================================${NC}"
echo ""
log_info "${CYAN}GCP Account & Project:${NC}"
log_info "  Account:       ${CURRENT_ACCOUNT}"
log_info "  Project ID:    ${PROJECT_ID}"
log_info "  Environment:   production"
echo ""
log_info "${CYAN}Deployment Target:${NC}"
log_info "  Bucket:        gs://${BUCKET_NAME}"
if [ -z "$RELEASE_FULL_PATH" ]; then
    log_info "  Release Path:  gs://${BUCKET_NAME}/ (bucket root)"
else
    log_info "  Release Path:  gs://${BUCKET_NAME}/${RELEASE_FULL_PATH}"
fi
log_info "  Version:       ${BUILD_TAG}"
echo ""
log_info "${CYAN}Source Files:${NC}"
log_info "  Directory:     ${BUILD_DIR_PATH}"
log_info "  Files:         ${FILE_COUNT}"
log_info "  Total Size:    ${TOTAL_SIZE}"
echo ""
log_warn "About to upload ${FILE_COUNT} files to GCS bucket: ${BUCKET_NAME}"
echo ""

# Confirmation prompt (unless --skip-prompts)
if [ "$SKIP_PROMPTS" = false ]; then
    read -p "$(echo -e "${YELLOW}Type 'DEPLOY' to confirm upload:${NC} ")" confirm_upload
    if [ "$confirm_upload" != "DEPLOY" ]; then
        log_warn "Upload cancelled - you must type exactly: DEPLOY"
        exit 0
    fi
    echo ""
fi

# Step 7: Upload to GCS
if ! upload_to_gcs "$BUILD_DIR_PATH" "$BUCKET_NAME" "$RELEASE_FULL_PATH"; then
    log_error "Upload failed"
    exit 1
fi
echo ""

# Step 8: Update Load Balancer URL Map (optional)
update_load_balancer "$URL_MAP_NAME" "$PATH_MATCHER_NAME" "$BUILD_TAG"
echo ""

# Step 9: List available releases
list_releases "$BUCKET_NAME"
echo ""

log_info "${GREEN}============================================${NC}"
log_info "${GREEN}✓ Deployment Successful!${NC}"
log_info "${GREEN}============================================${NC}"
echo ""

# Show deployment details
log_info "Deployment Details:"
log_info "  Environment:  production"
log_info "  Version:      ${BUILD_TAG}"
if [ -z "$RELEASE_FULL_PATH" ]; then
    log_info "  GCS Path:     gs://${BUCKET_NAME}/ (bucket root)"
    log_info "  Direct URL:   https://storage.googleapis.com/${BUCKET_NAME}/index.html"
else
    log_info "  GCS Path:     gs://${BUCKET_NAME}/${RELEASE_FULL_PATH}"
    log_info "  Direct URL:   https://storage.googleapis.com/${BUCKET_NAME}/${RELEASE_FULL_PATH}index.html"
fi

if [ -n "$URL_MAP_NAME" ]; then
    log_info "  URL Map:      ${URL_MAP_NAME}"
fi

echo ""
log_info "Next Steps:"
if [ -z "$RELEASE_FULL_PATH" ]; then
    log_info "  List files:     gsutil ls gs://${BUCKET_NAME}/"
    log_info "  View in console: https://console.cloud.google.com/storage/browser/${BUCKET_NAME}?project=${PROJECT_ID}"
else
    log_info "  List files:     gsutil ls gs://${BUCKET_NAME}/${RELEASE_FULL_PATH}"
    log_info "  View in console: https://console.cloud.google.com/storage/browser/${BUCKET_NAME}/${RELEASE_FULL_PATH%/}?project=${PROJECT_ID}"
fi
log_info "  Update LB: Manually update load balancer path rewrite in GCP Console"
echo ""
