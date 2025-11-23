#!/bin/bash
#
# Fetch Public GitLab Projects
# Discovers publicly accessible GitLab projects for scanning
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

# Configuration
GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
OUTPUT_FILE="$SCRIPT_DIR/public_projects.txt"
MAX_PAGES=50
PER_PAGE=100

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_progress() { echo -e "${CYAN}🔄 $1${NC}"; }

show_help() {
    cat << EOF
Fetch Public GitLab Projects

This script fetches publicly accessible GitLab projects and saves them to a file
for use with the infinite scanner.

Usage:
    $0 [options]

Options:
    --gitlab-url URL    GitLab instance URL (default: https://gitlab.com)
    --max-pages N       Maximum pages to fetch (default: 50)
    --output FILE       Output file (default: public_projects.txt)
    --min-stars N       Minimum star count (default: 0)
    --help              Show this help

Examples:
    $0
    $0 --max-pages 100 --min-stars 10
    $0 --gitlab-url https://gitlab.example.com

The output file will contain project paths in the format:
    namespace/project-name

EOF
}

parse_args() {
    MIN_STARS=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) show_help; exit 0 ;;
            --gitlab-url) GITLAB_URL="$2"; shift 2 ;;
            --max-pages) MAX_PAGES="$2"; shift 2 ;;
            --output) OUTPUT_FILE="$2"; shift 2 ;;
            --min-stars) MIN_STARS="$2"; shift 2 ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) log_error "Unexpected argument: $1"; exit 1 ;;
        esac
    done
}

fetch_public_projects() {
    log_info "Fetching public projects from: $GITLAB_URL"
    log_info "Maximum pages: $MAX_PAGES"
    
    # Create temporary file
    local temp_file=$(mktemp)
    local all_projects_file=$(mktemp)
    
    # Add header to output file
    cat > "$OUTPUT_FILE" << EOF
# Public GitLab Projects
# Generated: $(date)
# Source: $GITLAB_URL
# Min Stars: $MIN_STARS
#
# Format: namespace/project-name
# Lines starting with # are comments

EOF
    
    local total_found=0
    local page=1
    
    log_progress "Fetching projects..."
    
    while [ $page -le $MAX_PAGES ]; do
        local api_url="${GITLAB_URL}/api/v4/projects?visibility=public&per_page=${PER_PAGE}&page=${page}&order_by=star_count&sort=desc"
        
        log_progress "Fetching page $page/$MAX_PAGES..."
        
        # Fetch projects (no auth needed for public projects)
        if ! curl -s "$api_url" > "$temp_file"; then
            log_error "Failed to fetch projects (page $page)"
            rm -f "$temp_file" "$all_projects_file"
            return 1
        fi
        
        # Check for errors
        if jq -e '.message' "$temp_file" >/dev/null 2>&1; then
            local error_msg=$(jq -r '.message' "$temp_file")
            log_error "GitLab API error: $error_msg"
            rm -f "$temp_file" "$all_projects_file"
            return 1
        fi
        
        # Check if we got any projects
        local page_count=$(jq 'length' "$temp_file" 2>/dev/null || echo "0")
        
        if [ "$page_count" -eq 0 ]; then
            log_info "No more projects found (page $page)"
            break
        fi
        
        # Filter and extract project paths
        jq -r --arg min_stars "$MIN_STARS" '.[] | select(.star_count >= ($min_stars | tonumber)) | .path_with_namespace' "$temp_file" 2>/dev/null >> "$all_projects_file" || true
        
        local filtered_count=$(wc -l < "$all_projects_file" 2>/dev/null || echo "0")
        log_progress "Found $filtered_count projects so far (page $page: $page_count projects)"
        
        # If we got fewer than per_page results, we're done
        if [ "$page_count" -lt "$PER_PAGE" ]; then
            log_info "Reached last page (page $page)"
            break
        fi
        
        page=$((page + 1))
        
        # Small delay to be nice to the API
        sleep 0.5
    done
    
    # Remove duplicates and sort
    if [ -f "$all_projects_file" ]; then
        sort -u "$all_projects_file" >> "$OUTPUT_FILE"
        total_found=$(wc -l < "$all_projects_file")
    fi
    
    # Cleanup
    rm -f "$temp_file" "$all_projects_file"
    
    log_success "Found $total_found unique public projects"
    log_success "Saved to: $OUTPUT_FILE"
    
    # Show sample
    if [ "$total_found" -gt 0 ]; then
        echo ""
        log_info "Sample projects (first 10):"
        head -20 "$OUTPUT_FILE" | grep -v "^#" | head -10 || true
    fi
}

fetch_popular_groups() {
    log_info "Fetching popular public groups..."
    
    local groups_file="$SCRIPT_DIR/public_groups.txt"
    local temp_file=$(mktemp)
    
    cat > "$groups_file" << EOF
# Popular Public GitLab Groups
# Generated: $(date)
# Source: $GITLAB_URL
#
# Format: group-name
# Lines starting with # are comments

EOF
    
    local api_url="${GITLAB_URL}/api/v4/groups?per_page=50&order_by=projects_count&sort=desc"
    
    if curl -s "$api_url" > "$temp_file"; then
        jq -r '.[] | .full_path' "$temp_file" 2>/dev/null >> "$groups_file" || true
        local count=$(grep -v "^#" "$groups_file" | grep -v "^$" | wc -l)
        log_success "Found $count popular groups"
        log_info "Saved to: $groups_file"
    fi
    
    rm -f "$temp_file"
}

main() {
    parse_args "$@"
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Install with: sudo apt-get install jq"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl not found. Install with: sudo apt-get install curl"
        exit 1
    fi
    
    fetch_public_projects
    echo ""
    fetch_popular_groups
    
    echo ""
    log_success "Ready to scan!"
    log_info "Start infinite scanner with: ./infinite_scan.sh"
}

main "$@"
