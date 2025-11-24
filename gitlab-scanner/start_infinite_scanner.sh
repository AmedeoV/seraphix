#!/bin/bash
#
# Start GitLab Infinite Scanner
# This script helps you start the infinite scanner with proper token setup
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "============================================================"
echo "🦊 GitLab Infinite Scanner Starter"
echo "============================================================"
echo ""

# Check if token is set
if [ -z "${GITLAB_TOKEN:-}" ]; then
    log_error "GITLAB_TOKEN not set!"
    echo ""
    echo "Please set your GitLab token first:"
    echo ""
    echo "  export GITLAB_TOKEN='glpat-xxxxxxxxxxxxxxxxxxxx'"
    echo ""
    echo "Get your token at: https://gitlab.com/-/user_settings/personal_access_tokens"
    echo "Required scopes: read_api, read_repository"
    echo ""
    exit 1
fi

log_success "GitLab token is set"

# Check if public_projects.txt exists
if [ ! -f "$SCRIPT_DIR/public_projects.txt" ]; then
    log_warning "public_projects.txt not found"
    log_info "Fetching public projects first..."
    "$SCRIPT_DIR/fetch_public_projects.sh" --min-stars 50 --max-pages 10
    echo ""
fi

# Check project count
PROJECT_COUNT=$(grep -v '^#' "$SCRIPT_DIR/public_projects.txt" | grep -v '^$' | wc -l)
log_info "Found $PROJECT_COUNT projects to scan"
echo ""

# Check if scan_state.json exists
if [ -f "$SCRIPT_DIR/scan_state.json" ]; then
    ALREADY_SCANNED=$(jq -r '.total_scanned' "$SCRIPT_DIR/scan_state.json" 2>/dev/null || echo "0")
    log_info "Resuming from previous scan ($ALREADY_SCANNED projects already scanned)"
else
    log_info "Starting fresh scan"
fi

echo ""
log_info "Starting infinite scanner..."
log_info "Press Ctrl+C to stop (state will be saved)"
echo ""
echo "============================================================"
echo ""

# Start the scanner with a small delay
sleep 2

# Forward all additional arguments to infinite_scan.sh
exec "$SCRIPT_DIR/infinite_scan.sh" "$@"
