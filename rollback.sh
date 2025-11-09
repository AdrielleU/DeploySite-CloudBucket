#!/usr/bin/env bash
# ============================================================================
# Rollback Frontend Deployment to Previous Release
# ============================================================================
# This script updates the load balancer to point to a previous release.
# Supports interactive mode when configuration is missing.
#
# Usage:
#   ./scripts/gcp/rollback.sh [RELEASE_VERSION] [ENV] [OPTIONS]
#
# Options:
#   --project=ID        GCP project ID
#   --bucket=NAME       GCS bucket name
#   --backend=NAME      Backend bucket name
#   --env=ENV           Environment: staging or production
#   --skip-prompts      Skip interactive prompts
#   --help              Show this help
#
# Examples:
#   ./scripts/gcp/rollback.sh                                  # Interactive mode
#   ./scripts/gcp/rollback.sh list staging                     # List available releases
#   ./scripts/gcp/rollback.sh 20251108-143022-abc123 staging  # Rollback to version
#   ./scripts/gcp/rollback.sh --bucket=my-app --env=production # With options
# ============================================================================

set -euo pipefail

# Configuration
MAX_RETRIES=3
RETRY_DELAY=5

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

# Cleanup function
cleanup() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo ""
        log_error "Rollback failed with exit code: $exit_code"
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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# Check bucket accessibility
check_bucket_access() {
    local bucket=$1

    log_step "Checking bucket access..."

    if ! retry_command $MAX_RETRIES gsutil ls -b "gs://${bucket}" >/dev/null 2>&1; then
        log_error "Cannot access bucket: gs://${bucket}"
        log_error "Please check:"
        log_error "  1. Bucket name is correct"
        log_error "  2. You have permissions to access the bucket"
        log_error "  3. The bucket exists in the specified project"
        return 1
    fi

    log_success "Bucket is accessible"
    return 0
}

# ============================================================================
# Parse Arguments
# ============================================================================

RELEASE_VERSION=""
ENVIRONMENT=""
CLI_PROJECT_ID=""
CLI_BUCKET_NAME=""
CLI_BACKEND_NAME=""
SKIP_PROMPTS=false

# Parse positional and named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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
        --env=*)
            ENVIRONMENT="${1#*=}"
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
            if [ -z "$RELEASE_VERSION" ]; then
                RELEASE_VERSION="$1"
            elif [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Default environment to staging if not specified
if [ -z "$ENVIRONMENT" ] && [ "$SKIP_PROMPTS" = false ]; then
    ENVIRONMENT="staging"
fi

# ============================================================================
# Load Configuration
# ============================================================================

# Determine environment file
if [ "$ENVIRONMENT" = "production" ]; then
    ENV_FILE="$PROJECT_ROOT/.env.production"
elif [ "$ENVIRONMENT" = "staging" ]; then
    ENV_FILE="$PROJECT_ROOT/.env.staging"
else
    ENV_FILE="$PROJECT_ROOT/.env"
fi

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
ENV_URL_MAP_NAME=$(get_env_value "DEPLOY_URL_MAP_NAME" "$ENV_FILE")
ENV_PATH_MATCHER_NAME=$(get_env_value "DEPLOY_PATH_MATCHER_NAME" "$ENV_FILE" "path-matcher-1")

# CLI overrides .env
PROJECT_ID="${CLI_PROJECT_ID:-$ENV_PROJECT_ID}"
BUCKET_NAME="${CLI_BUCKET_NAME:-$ENV_BUCKET_NAME}"
URL_MAP_NAME="${CLI_URL_MAP_NAME:-$ENV_URL_MAP_NAME}"
PATH_MATCHER_NAME="$ENV_PATH_MATCHER_NAME"

# Interactive prompts for missing config
if [ -z "$ENVIRONMENT" ]; then
    if [ "$SKIP_PROMPTS" = true ]; then
        log_error "Environment not specified and --skip-prompts enabled"
        exit 1
    fi
    echo ""
    log_prompt "Select environment:"
    echo "  1) staging"
    echo "  2) production"
    read -p "$(echo -e "${CYAN}Choice [1]:${NC} ")" env_choice
    case "${env_choice:-1}" in
        1) ENVIRONMENT="staging" ;;
        2) ENVIRONMENT="production" ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
fi

if [ -z "$PROJECT_ID" ]; then
    if [ "$SKIP_PROMPTS" = true ]; then
        log_error "DEPLOY_PROJECT_ID not set and --skip-prompts enabled"
        exit 1
    fi
    echo ""
    log_prompt "GCP Project ID not found"
    PROJECT_ID=$(prompt_with_default "Enter GCP Project ID" "")
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
    log_prompt "GCS Bucket Name not found"
    BUCKET_NAME=$(prompt_with_default "Enter GCS bucket name" "")
    if [ -z "$BUCKET_NAME" ]; then
        log_error "Bucket name is required"
        exit 1
    fi
fi

# ============================================================================
# Pre-flight Checks
# ============================================================================

log_step "Running pre-flight checks..."
check_dependencies
check_gcloud_auth
echo ""

# Set active project
log_step "Setting active GCP project..."
if ! retry_command $MAX_RETRIES gcloud config set project "$PROJECT_ID" --quiet; then
    log_error "Failed to set active project to: $PROJECT_ID"
    log_error "Please check that the project exists and you have access"
    exit 1
fi
echo ""

# Check bucket access
if ! check_bucket_access "$BUCKET_NAME"; then
    exit 1
fi
echo ""

# ============================================================================
# List releases if requested
# ============================================================================

if [ "$RELEASE_VERSION" = "list" ] || [ -z "$RELEASE_VERSION" ]; then
    log_info "Fetching available releases from gs://${BUCKET_NAME}/releases/"
    echo ""

    # Use retry for network resilience
    if ! releases=$(retry_command $MAX_RETRIES gsutil ls "gs://${BUCKET_NAME}/releases/" 2>&1); then
        log_error "Failed to list releases from bucket"
        log_error "Please check your network connection and bucket permissions"
        exit 1
    fi

    # Filter for release folders
    releases=$(echo "$releases" | grep -E "releases/[0-9]" || echo "")

    if [ -z "$releases" ]; then
        log_warn "No releases found in bucket: gs://${BUCKET_NAME}/releases/"
        log_warn "Have you deployed any versions yet?"
        exit 0
    fi

    log_info "Available releases:"
    echo "$releases" | while read -r release_path; do
        release_name=$(basename "$release_path")
        echo "  - ${release_name}"
    done

    if [ "$RELEASE_VERSION" = "list" ]; then
        exit 0
    fi

    # Interactive selection
    if [ "$SKIP_PROMPTS" = false ]; then
        echo ""
        RELEASE_VERSION=$(prompt_with_default "Enter release version to rollback to" "")
        if [ -z "$RELEASE_VERSION" ]; then
            log_warn "No release selected"
            exit 0
        fi
    else
        log_error "No release version specified and --skip-prompts enabled"
        exit 1
    fi
fi

# ============================================================================
# Verify and Rollback
# ============================================================================

# Verify release exists
log_step "Verifying release: ${RELEASE_VERSION}"

if ! retry_command $MAX_RETRIES gsutil ls "gs://${BUCKET_NAME}/releases/${RELEASE_VERSION}/" >/dev/null 2>&1; then
    log_error "Release not found: gs://${BUCKET_NAME}/releases/${RELEASE_VERSION}/"
    log_error ""
    log_error "Run './scripts/gcp/rollback.sh list $ENVIRONMENT' to see available releases"
    exit 1
fi

# Check if release has files
if ! retry_command $MAX_RETRIES gsutil ls "gs://${BUCKET_NAME}/releases/${RELEASE_VERSION}/index.html" >/dev/null 2>&1; then
    log_warn "Release folder exists but may be incomplete (no index.html found)"
    if [ "$SKIP_PROMPTS" = false ]; then
        read -p "$(echo -e "${YELLOW}Continue anyway? (y/N):${NC} ")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Rollback cancelled"
            exit 0
        fi
    fi
fi

log_success "✓ Release verified"

# Display rollback info
echo ""
log_info "${YELLOW}============================================${NC}"
log_info "${YELLOW}Rollback to Previous Release${NC}"
log_info "${YELLOW}============================================${NC}"
echo ""
log_info "Configuration:"
log_info "  Environment:  ${ENVIRONMENT}"
log_info "  Project:      ${PROJECT_ID}"
log_info "  Bucket:       ${BUCKET_NAME}"
log_info "  Release:      ${RELEASE_VERSION}"
if [ -n "$URL_MAP_NAME" ]; then
    log_info "  URL Map:      ${URL_MAP_NAME}"
    log_info "  Path Matcher: ${PATH_MATCHER_NAME}"
fi
echo ""

# Confirm rollback
if [ "$SKIP_PROMPTS" = false ]; then
    if [ "$ENVIRONMENT" = "production" ]; then
        read -p "$(echo -e "${RED}Rollback PRODUCTION? Type 'yes' to confirm:${NC} ")" confirm
        if [ "$confirm" != "yes" ]; then
            log_warn "Rollback cancelled"
            exit 0
        fi
    else
        read -p "$(echo -e "${CYAN}Proceed with rollback? (Y/n):${NC} ")" confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_warn "Rollback cancelled"
            exit 0
        fi
    fi
    echo ""
fi

# Set active project
log_info "Setting active GCP project..."
gcloud config set project "$PROJECT_ID" --quiet

# Show instructions for updating load balancer
if [ -z "$URL_MAP_NAME" ]; then
    log_warn "URL Map name not set in .env file"
    log_warn "Manually update your load balancer to serve from:"
    log_warn "  gs://${BUCKET_NAME}/releases/${RELEASE_VERSION}/"
else
    echo ""
    log_info "${YELLOW}============================================${NC}"
    log_info "${YELLOW}Load Balancer Update Instructions${NC}"
    log_info "${YELLOW}============================================${NC}"
    echo ""
    log_info "To activate this rollback, update your load balancer routing:"
    echo ""
    log_info "${CYAN}Option 1: GCP Console (Easiest)${NC}"
    log_info "  1. Go to: https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=${PROJECT_ID}"
    log_info "  2. Click on your load balancer: ${BLUE}${URL_MAP_NAME}${NC}"
    log_info "  3. Click 'Edit' → 'Host and path rules'"
    log_info "  4. Update path rewrite to: ${GREEN}/releases/${RELEASE_VERSION}${NC}"
    log_info "  5. Click 'Update'"
    echo ""
    log_info "${CYAN}Option 2: gcloud Command${NC}"
    log_info "  Export current configuration:"
    echo "    ${BLUE}gcloud compute url-maps export ${URL_MAP_NAME} \\${NC}"
    echo "    ${BLUE}  --destination=url-map.yaml \\${NC}"
    echo "    ${BLUE}  --project=${PROJECT_ID}${NC}"
    echo ""
    log_info "  Edit url-map.yaml and update the path matcher '${PATH_MATCHER_NAME}':"
    log_info "  Change pathPrefixRewrite to: ${GREEN}/releases/${RELEASE_VERSION}${NC}"
    echo ""
    log_info "  Import updated configuration:"
    echo "    ${BLUE}gcloud compute url-maps import ${URL_MAP_NAME} \\${NC}"
    echo "    ${BLUE}  --source=url-map.yaml \\${NC}"
    echo "    ${BLUE}  --project=${PROJECT_ID}${NC}"
fi

echo ""
log_info "${GREEN}============================================${NC}"
log_info "${GREEN}✓ Rollback Complete!${NC}"
log_info "${GREEN}============================================${NC}"
echo ""

log_info "Rollback Details:"
log_info "  Environment:  ${ENVIRONMENT}"
log_info "  Release:      ${RELEASE_VERSION}"
log_info "  GCS Path:     gs://${BUCKET_NAME}/releases/${RELEASE_VERSION}/"
log_info "  Direct URL:   https://storage.googleapis.com/${BUCKET_NAME}/releases/${RELEASE_VERSION}/index.html"

if [ -n "$URL_MAP_NAME" ]; then
    log_info "  URL Map:      ${URL_MAP_NAME}"
fi

echo ""
log_info "Useful commands:"
log_info "  View:         https://console.cloud.google.com/storage/browser/${BUCKET_NAME}/releases/${RELEASE_VERSION}?project=${PROJECT_ID}"
log_info "  List all:     ./scripts/gcp/rollback.sh list ${ENVIRONMENT}"
echo ""
