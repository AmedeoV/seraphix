#!/bin/bash
#
# GitLab Repository + Forks Scanner
# Scans a GitLab repository and all its forks for leaked secrets
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
GITLAB_INSTANCE="https://gitlab.com"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
DEBUG=false
PARALLEL_SCANS=3

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_progress() {
    echo -e "${CYAN}🔄 $1${NC}"
}

show_help() {
    cat << EOF
GitLab Repository + Forks Scanner

Usage:
    $0 <repo_name> [options]

Arguments:
    repo_name     GitLab repository in format "owner/repo" or "group/project"

Options:
    --gitlab-url URL     GitLab instance URL (default: https://gitlab.com)
    --gitlab-token TOK   GitLab API token (or use GITLAB_TOKEN env var)
    --parallel N         Number of parallel scans (default: 3)
    --debug              Enable debug output
    --help               Show this help message

Examples:
    $0 appsemble/appsemble
    $0 appsemble/appsemble --gitlab-token glpat-xxx
    $0 mygroup/myproject --parallel 5 --debug

Environment Variables:
    GITLAB_TOKEN         GitLab API token (required for private repos and forks list)

EOF
}

get_project_id() {
    local repo_name="$1"
    local gitlab_url="$2"
    local token="$3"
    
    # URL encode the project path
    local encoded_path=$(echo "$repo_name" | sed 's/\//%2F/g')
    
    log_progress "Getting project ID for $repo_name..."
    
    local api_url="${gitlab_url}/api/v4/projects/${encoded_path}"
    
    if [ -n "$token" ]; then
        local project_id=$(curl -s -H "PRIVATE-TOKEN: $token" "$api_url" | jq -r '.id // empty')
    else
        local project_id=$(curl -s "$api_url" | jq -r '.id // empty')
    fi
    
    if [ -z "$project_id" ]; then
        log_error "Could not get project ID for $repo_name"
        return 1
    fi
    
    echo "$project_id"
}

get_forks() {
    local project_id="$1"
    local gitlab_url="$2"
    local token="$3"
    
    log_progress "Fetching forks list..." >&2
    
    local api_url="${gitlab_url}/api/v4/projects/${project_id}/forks?per_page=100"
    
    local forks_json
    if [ -n "$token" ]; then
        forks_json=$(curl -s -H "PRIVATE-TOKEN: $token" "$api_url")
    else
        forks_json=$(curl -s "$api_url")
    fi
    
    local fork_count=$(echo "$forks_json" | jq 'length' 2>/dev/null || echo "0")
    
    if [ "$fork_count" -eq 0 ] || [ -z "$fork_count" ]; then
        log_info "No forks found" >&2
        return 0
    fi
    
    log_success "Found $fork_count fork(s)" >&2
    
    # Extract fork paths
    echo "$forks_json" | jq -r '.[].path_with_namespace'
}

scan_repository() {
    local repo_name="$1"
    local label="$2"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_progress "Scanning $label: $repo_name"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local scan_cmd="$SCRIPT_DIR/scan_repo.sh $repo_name"
    
    if [ "$DEBUG" = true ]; then
        scan_cmd="$scan_cmd --debug"
    fi
    
    if [ -n "$GITLAB_TOKEN" ]; then
        scan_cmd="$scan_cmd --gitlab-token $GITLAB_TOKEN"
    fi
    
    if [ -n "$GITLAB_INSTANCE" ] && [ "$GITLAB_INSTANCE" != "https://gitlab.com" ]; then
        scan_cmd="$scan_cmd --gitlab-url $GITLAB_INSTANCE"
    fi
    
    bash -c "$scan_cmd"
    
    echo ""
}

parse_arguments() {
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --gitlab-url)
                GITLAB_INSTANCE="$2"
                shift 2
                ;;
            --gitlab-token)
                GITLAB_TOKEN="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL_SCANS="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ -z "${REPO_NAME:-}" ]; then
                    REPO_NAME="$1"
                else
                    log_error "Too many arguments: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "${REPO_NAME:-}" ]; then
        log_error "Missing repository name"
        exit 1
    fi
}

main() {
    parse_arguments "$@"
    
    # Check dependencies
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Install with: sudo apt-get install jq"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl not found. Install with: sudo apt-get install curl"
        exit 1
    fi
    
    if [ ! -f "$SCRIPT_DIR/scan_repo.sh" ]; then
        log_error "scan_repo.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║   GitLab Repository + Forks Security Scanner              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Target repository: $REPO_NAME"
    log_info "GitLab instance: $GITLAB_INSTANCE"
    echo ""
    
    # Get project ID
    local project_id
    if ! project_id=$(get_project_id "$REPO_NAME" "$GITLAB_INSTANCE" "$GITLAB_TOKEN"); then
        exit 1
    fi
    
    log_success "Project ID: $project_id"
    echo ""
    
    # Scan main repository
    scan_repository "$REPO_NAME" "MAIN REPOSITORY"
    
    # Get and scan forks
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_progress "Checking for forks..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local forks
    forks=$(get_forks "$project_id" "$GITLAB_INSTANCE" "$GITLAB_TOKEN")
    
    if [ -z "$forks" ]; then
        log_info "No forks to scan"
    else
        local fork_array=()
        while IFS= read -r fork; do
            fork_array+=("$fork")
        done <<< "$forks"
        
        log_info "Found ${#fork_array[@]} fork(s) to scan"
        echo ""
        
        # Scan each fork
        local count=1
        for fork in "${fork_array[@]}"; do
            scan_repository "$fork" "FORK $count/${#fork_array[@]}"
            ((count++))
        done
    fi
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║   Scan Complete                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "All scans completed!"
    log_info "Check results in: $SCRIPT_DIR/leaked_secrets_results/"
    echo ""
}

main "$@"
