#!/usr/bin/env bash
# Quick script to invalidate CDN cache for TechManager AI static site

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ID="project-techmanagerai-prod-1"
URL_MAP="lb-staticsite-techmanagerai-prod-1"
PATH_PATTERN="${1:-/*}"

echo -e "${BLUE}Invalidating CDN cache...${NC}"
echo -e "${CYAN}URL Map:${NC}      $URL_MAP"
echo -e "${CYAN}Path Pattern:${NC} $PATH_PATTERN"
echo ""

gcloud compute url-maps invalidate-cdn-cache \
  "$URL_MAP" \
  --path="$PATH_PATTERN" \
  --project="$PROJECT_ID" \
  --async

echo ""
echo -e "${GREEN}✓ Cache invalidation started!${NC}"
echo -e "${CYAN}It will take 2-3 minutes to propagate across all CDN edge locations.${NC}"
echo ""
echo "Usage examples:"
echo "  ./invalidate-cache.sh           # Invalidate everything (/*)"
echo "  ./invalidate-cache.sh /index.html"
echo "  ./invalidate-cache.sh /assets/*"
