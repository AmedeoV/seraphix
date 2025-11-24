#!/bin/bash
#
# Infinite GitLab Project Scanner
# Continuously scans public GitLab projects for leaked secrets
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
PROJECTS_FILE="$SCRIPT_DIR/public_projects.txt"
STATE_FILE="$SCRIPT_DIR/scan_state.json"
DELAY_BETWEEN_SCANS=3
MAX_FAILURES_PER_PROJECT=3

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_progress() { echo -e "${CYAN}🔄 $1${NC}"; }

show_help() {
    cat << EOF
Infinite GitLab Project Scanner

Continuously scans public GitLab projects for leaked secrets. The scanner
maintains state and resumes from where it left off if interrupted.

Usage:
    $0 [options]

Options:
    --projects-file FILE  File containing project paths (default: public_projects.txt)
    --delay N             Seconds to wait between scans (default: 3)
    --gitlab-token TOKEN  GitLab API token (optional, can also use GITLAB_TOKEN env)
    --telegram-chat-id ID Telegram notifications
    --email EMAIL         Email notifications
    --help                Show this help

Examples:
    $0
    $0 --telegram-chat-id 123456789
    $0 --delay 5 --email security@company.com

State Management:
    The scanner saves progress to scan_state.json and will resume from the
    last scanned project if interrupted.

Notes:
    - Generate projects list first: ./fetch_public_projects.sh
    - Press Ctrl+C to stop gracefully
    - State is saved after each successful scan

EOF
}

# Load or initialize state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        log_info "Loading previous scan state..."
        
        # Load arrays and filter out empty strings
        local raw_scanned=($(jq -r '.scanned_projects[]' "$STATE_FILE" 2>/dev/null || echo ""))
        SCANNED_PROJECTS=()
        for proj in "${raw_scanned[@]}"; do
            [[ -n "$proj" ]] && SCANNED_PROJECTS+=("$proj")
        done
        
        local raw_skipped=($(jq -r '.skipped_projects[]' "$STATE_FILE" 2>/dev/null || echo ""))
        SKIPPED_PROJECTS=()
        for proj in "${raw_skipped[@]}"; do
            [[ -n "$proj" ]] && SKIPPED_PROJECTS+=("$proj")
        done
        
        TOTAL_SECRETS=$(jq -r '.total_secrets_found' "$STATE_FILE" 2>/dev/null || echo "0")
        log_info "Resuming: ${#SCANNED_PROJECTS[@]} already scanned, ${#SKIPPED_PROJECTS[@]} skipped, $TOTAL_SECRETS secrets found"
    else
        SCANNED_PROJECTS=()
        SKIPPED_PROJECTS=()
        TOTAL_SECRETS=0
        log_info "Starting fresh scan"
    fi
}

# Save state
save_state() {
    log_progress "Saving state..."
    
    # Filter out empty strings from arrays
    local filtered_scanned=()
    for proj in "${SCANNED_PROJECTS[@]}"; do
        [[ -n "$proj" ]] && filtered_scanned+=("$proj")
    done
    
    local filtered_skipped=()
    for proj in "${SKIPPED_PROJECTS[@]}"; do
        [[ -n "$proj" ]] && filtered_skipped+=("$proj")
    done
    
    # Build JSON arrays
    local scanned_json=""
    if [ ${#filtered_scanned[@]} -gt 0 ]; then
        scanned_json=$(printf '    "%s",\n' "${filtered_scanned[@]}" | sed '$ s/,$//')
    fi
    
    local skipped_json=""
    if [ ${#filtered_skipped[@]} -gt 0 ]; then
        skipped_json=$(printf '    "%s",\n' "${filtered_skipped[@]}" | sed '$ s/,$//')
    fi
    
    cat > "$STATE_FILE" << EOF
{
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")",
  "total_scanned": ${#filtered_scanned[@]},
  "total_skipped": ${#filtered_skipped[@]},
  "total_secrets_found": $TOTAL_SECRETS,
  "scanned_projects": [
$scanned_json
  ],
  "skipped_projects": [
$skipped_json
  ]
}
EOF
}

# Check if project was already scanned
is_already_scanned() {
    local project="$1"
    for scanned in "${SCANNED_PROJECTS[@]}"; do
        if [ "$scanned" = "$project" ]; then
            return 0
        fi
    done
    return 1
}

# Check if project should be skipped
is_skipped() {
    local project="$1"
    for skipped in "${SKIPPED_PROJECTS[@]}"; do
        if [ "$skipped" = "$project" ]; then
            return 0
        fi
    done
    return 1
}

# Scan a single project
scan_project() {
    local project="$1"
    
    log_progress "Scanning: $project"
    
    # Build scan command
    local scan_cmd="./scan_repo.sh \"$project\""
    
    if [ -n "${GITLAB_TOKEN:-}" ]; then
        scan_cmd="$scan_cmd --gitlab-token \"$GITLAB_TOKEN\""
    fi
    
    if [ -n "${NOTIFICATION_EMAIL:-}" ]; then
        scan_cmd="$scan_cmd --email \"$NOTIFICATION_EMAIL\""
    fi
    
    if [ -n "${NOTIFICATION_TELEGRAM_CHAT_ID:-}" ]; then
        scan_cmd="$scan_cmd --telegram-chat-id \"$NOTIFICATION_TELEGRAM_CHAT_ID\""
    fi
    
    # Execute scan
    if eval "$scan_cmd" 2>&1; then
        SCANNED_PROJECTS+=("$project")
        log_success "Successfully scanned $project (Total: ${#SCANNED_PROJECTS[@]})"
        
        # Count secrets found - look for JSON file specific to this project
        # Convert project name to safe filename format: namespace/project -> namespace_project
        local safe_project_name=$(echo "$project" | tr '/' '_')
        local latest_result=$(find "$SCRIPT_DIR/leaked_secrets_results" -name "gitlab_scan_${safe_project_name}_*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [ -n "$latest_result" ] && [ -f "$latest_result" ]; then
            local secrets_count=$(jq 'length' "$latest_result" 2>/dev/null || echo "0")
            if [ "$secrets_count" -gt 0 ]; then
                TOTAL_SECRETS=$((TOTAL_SECRETS + secrets_count))
                log_success "🔑 Found $secrets_count secret(s) in $project! (Total: $TOTAL_SECRETS)"
            fi
        fi
        
        save_state
        return 0
    else
        log_error "Failed to scan $project"
        return 1
    fi
}

# Main scanning loop
scan_loop() {
    if [ ! -f "$PROJECTS_FILE" ]; then
        log_error "Projects file not found: $PROJECTS_FILE"
        log_info "Run ./fetch_public_projects.sh to generate the list"
        exit 1
    fi
    
    local cycle=1
    
    while true; do
        log_info "========================================"
        log_info "Starting scan cycle #$cycle"
        log_info "========================================"
        
        local scanned_this_cycle=0
        local skipped_this_cycle=0
        
        while IFS= read -r project || [ -n "$project" ]; do
            # Skip comments and empty lines
            [[ "$project" =~ ^#.*$ ]] && continue
            [[ -z "$project" ]] && continue
            
            # Trim whitespace
            project=$(echo "$project" | xargs)
            
            # Skip if already scanned
            if is_already_scanned "$project"; then
                ((skipped_this_cycle++)) || true
                continue
            fi
            
            # Skip if in skip list
            if is_skipped "$project"; then
                ((skipped_this_cycle++)) || true
                continue
            fi
            
            # Scan the project
            if ! scan_project "$project"; then
                log_warning "Adding $project to skip list after failure"
                SKIPPED_PROJECTS+=("$project")
                save_state
            fi
            
            ((scanned_this_cycle++)) || true
            
            # Progress update
            if [ $((scanned_this_cycle % 10)) -eq 0 ]; then
                log_info "📊 Progress: $scanned_this_cycle scanned, $skipped_this_cycle skipped"
            fi
            
            # Delay between scans
            sleep "$DELAY_BETWEEN_SCANS"
            
        done < "$PROJECTS_FILE"
        
        log_info "========================================"
        log_success "Completed scan cycle #$cycle"
        log_info "Scanned: $scanned_this_cycle projects"
        log_info "Skipped: $skipped_this_cycle projects"
        log_info "Total secrets found: $TOTAL_SECRETS"
        log_info "========================================"
        
        # If we scanned nothing new, we've completed all projects
        if [ $scanned_this_cycle -eq 0 ]; then
            log_success "🎉 All projects scanned!"
            log_info "Total scanned: ${#SCANNED_PROJECTS[@]}"
            log_info "Total skipped: ${#SKIPPED_PROJECTS[@]}"
            log_info "Total secrets: $TOTAL_SECRETS"
            
            # Reset for next cycle
            log_info "Resetting state for next cycle in 60 seconds..."
            sleep 60
            
            SCANNED_PROJECTS=()
            SKIPPED_PROJECTS=()
            save_state
            
            cycle=$((cycle + 1))
        else
            cycle=$((cycle + 1))
            sleep 5
        fi
    done
}

# Cleanup on exit
cleanup() {
    log_warning "Scan interrupted by user (Ctrl+C)"
    log_info "Saving state before exit..."
    save_state
    log_success "State saved. Run again to resume."
    exit 0
}

parse_args() {
    GITLAB_TOKEN="${GITLAB_TOKEN:-}"
    NOTIFICATION_EMAIL=""
    NOTIFICATION_TELEGRAM_CHAT_ID=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) show_help; exit 0 ;;
            --projects-file) PROJECTS_FILE="$2"; shift 2 ;;
            --delay) DELAY_BETWEEN_SCANS="$2"; shift 2 ;;
            --gitlab-token) GITLAB_TOKEN="$2"; shift 2 ;;
            --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
            --telegram-chat-id) NOTIFICATION_TELEGRAM_CHAT_ID="$2"; shift 2 ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) log_error "Unexpected argument: $1"; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"
    
    # Check dependencies
    for tool in jq curl; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not found"
            exit 1
        fi
    done
    
    # Set up signal handler
    trap cleanup SIGINT SIGTERM
    
    log_info "🦊 Starting infinite GitLab scanner..."
    log_info "Projects file: $PROJECTS_FILE"
    log_info "Delay between scans: ${DELAY_BETWEEN_SCANS}s"
    log_info "Press Ctrl+C to stop gracefully"
    echo ""
    
    # Load previous state
    load_state
    
    # Start scanning
    scan_loop
}

main "$@"
