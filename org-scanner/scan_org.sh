#!/bin/bash
#
# Simple Organization Scanner (Bash)
# A focused version that scans organizations reliably
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
PURPLE='\033[0;35m'
NC='\033[0m'

# Configuration
CLEANUP=true
TIMEOUT=900
OUTPUT_DIR=""
TEMP_DIR=""
DEBUG=false
LOG_DIR="$SCRIPT_DIR/scan_logs"  # Local debug logs directory
MAX_WORKERS=0  # 0 = auto-detect
GITHUB_TOKEN="${GITHUB_TOKEN:-""}"  # Use environment variable if set, empty otherwise
EXCLUDE_FORKS=true
MAX_REPOS=0

# Load timeout configuration if available
if [ -f "$SCRIPT_DIR/../config/timeout_config.sh" ]; then
    log_debug "Loading timeout configuration from ../config/timeout_config.sh"
    source "$SCRIPT_DIR/../config/timeout_config.sh"
    # Use the loaded timeout values
    TIMEOUT=${TRUFFLEHOG_BASE_TIMEOUT:-900}
elif [ -f "$SCRIPT_DIR/config/timeout_config.sh" ]; then
    log_debug "Loading timeout configuration from config/timeout_config.sh"
    source "$SCRIPT_DIR/config/timeout_config.sh"
    TIMEOUT=${TRUFFLEHOG_BASE_TIMEOUT:-900}
else
    # Default timeout values
    export TRUFFLEHOG_BASE_TIMEOUT=900
    export TRUFFLEHOG_MAX_TIMEOUT=3600
    export TRUFFLEHOG_MAX_RETRIES=2
    export GIT_OPERATION_TIMEOUT=300
fi

# Notification configuration
NOTIFICATION_EMAIL=""  # Email address for notifications (empty = disabled)
NOTIFICATION_TELEGRAM_CHAT_ID=""  # Telegram chat ID for notifications (empty = disabled)
NOTIFICATION_SCRIPT="send_notifications_enhanced.sh"  # Enhanced notification system

# System resource detection for dynamic worker management
detect_system_resources() {
    # Detect CPU cores (logical cores including hyperthreading)
    if command -v nproc &> /dev/null; then
        CPU_CORES=$(nproc)
    elif [ -r /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    else
        CPU_CORES=2  # fallback
    fi
    
    # Detect memory in GB
    if [ -r /proc/meminfo ]; then
        local mem_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
        MEMORY_GB=$((mem_kb / 1024 / 1024))
    else
        MEMORY_GB=4  # fallback
    fi
    
    # Get current load average (1-minute)
    if [ -r /proc/loadavg ]; then
        LOAD_AVERAGE=$(cut -d' ' -f1 /proc/loadavg)
    else
        LOAD_AVERAGE="1.0"  # fallback
    fi
    
    # Calculate optimal worker count
    # Base calculation: max(1, min(CPU_cores, memory_gb/2))
    local mem_workers=$((MEMORY_GB / 2))
    if [ "$mem_workers" -lt 1 ]; then
        mem_workers=1
    fi
    
    local base_workers=$CPU_CORES
    if [ "$mem_workers" -lt "$base_workers" ]; then
        base_workers=$mem_workers
    fi
    
    # Adjust for current system load
    local load_int=$(echo "$LOAD_AVERAGE" | cut -d'.' -f1)
    if [ "$load_int" -gt "$CPU_CORES" ]; then
        # System is under high load, reduce workers
        base_workers=$((base_workers / 2))
        if [ "$base_workers" -lt 1 ]; then
            base_workers=1
        fi
    fi
    
    # Set reasonable bounds (1-8 workers)
    if [ "$base_workers" -lt 1 ]; then
        AUTO_DETECTED_WORKERS=1
    elif [ "$base_workers" -gt 8 ]; then
        AUTO_DETECTED_WORKERS=8
    else
        AUTO_DETECTED_WORKERS=$base_workers
    fi
}

# Initialize system resource detection
detect_system_resources

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_progress() { echo -e "${CYAN}🔄 $1${NC}"; }
log_debug() { [ "$DEBUG" = true ] && echo -e "${YELLOW}🐛 $1${NC}"; }

# Adaptive timeout calculation based on repository characteristics
calculate_adaptive_timeout() {
    local repo_size_mb="$1"
    local estimated_files="$2"
    local base_timeout=${TRUFFLEHOG_BASE_TIMEOUT:-900}
    
    # Start with base timeout
    local calculated_timeout=$base_timeout
    
    # Factor 1: Repository size
    if (( $(echo "$repo_size_mb > ${LARGE_REPO_THRESHOLD:-500}" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * ${COMMIT_TIMEOUT_MULTIPLIER:-2.0}" | bc -l 2>/dev/null || echo "$((calculated_timeout * 2))")
        log_debug "Large repo detected (${repo_size_mb}MB), increasing timeout" >&2
    elif (( $(echo "$repo_size_mb > ${MEDIUM_REPO_THRESHOLD:-100}" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * ${SIZE_TIMEOUT_MULTIPLIER:-1.5}" | bc -l 2>/dev/null || echo "$((calculated_timeout * 3 / 2))")
        log_debug "Medium repo detected (${repo_size_mb}MB), moderately increasing timeout" >&2
    fi
    
    # Factor 2: Estimated file count (approximation of complexity)
    if [ "$estimated_files" -gt 1000 ]; then
        calculated_timeout=$(echo "$calculated_timeout * 1.3" | bc -l 2>/dev/null || echo "$((calculated_timeout * 13 / 10))")
        log_debug "Many files detected ($estimated_files), increasing timeout" >&2
    fi
    
    # Cap at maximum timeout
    local max_timeout=${TRUFFLEHOG_MAX_TIMEOUT:-3600}
    if (( $(echo "$calculated_timeout > $max_timeout" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$max_timeout
        log_debug "Timeout capped at maximum: ${max_timeout}s" >&2
    fi
    
    # Convert to integer and return
    printf "%.0f" "$calculated_timeout"
}

show_help() {
    cat << EOF
Simple Organization Scanner

Usage:
    $0 <organization> [options]

Examples:
    $0 magicbell-io
    $0 microsoft --max-repos 5 --max-workers 4
    $0 microsoft --github-token ghp_xxx --exclude-forks
    $0 microsoft --email security@company.com --telegram-chat-id 123456789
    $0 microsoft --telegram-chat-id 123456789 --debug

Options:
    --max-repos N        Maximum repositories to scan (default: all)
    --max-workers N      Parallel workers (default: auto-detect, 0 = auto)
    --timeout SEC        Timeout per repo (default: 900)
    --github-token TOK   GitHub API token (overrides GITHUB_TOKEN env var)
    --include-forks      Include forked repositories
    --output-dir DIR     Custom output directory (default: leaked_secrets_results/TIMESTAMP/org_leaked_secrets/scan_ORG_TIMESTAMP)
    --email EMAIL        Email address for security notifications
    --telegram-chat-id ID Telegram chat ID for security notifications
    --debug              Debug output
    --help              Show help

Environment Variables:
    GITHUB_TOKEN         GitHub API token (can be overridden with --github-token)

System Auto-Detection:
    The script automatically detects CPU cores, memory, and system load
    to determine optimal worker count. Use --max-workers to override.

Notifications:
    Use --email and/or --telegram-chat-id to receive security notifications when
    secrets are found. Requires proper configuration of notification scripts.

EOF
}

cleanup_on_exit() {
    if [ "$CLEANUP" = true ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_progress "Cleaning up..."
        rm -rf "$TEMP_DIR"
    fi
}

get_org_repos() {
    local org="$1"
    local repos_file="$TEMP_DIR/repos.json"
    
    log_progress "Fetching repositories for $org..."
    
    local api_url="https://api.github.com/orgs/$org/repos?per_page=100&type=all"
    local headers=()
    
    if [ -n "$GITHUB_TOKEN" ]; then
        headers=("-H" "Authorization: token $GITHUB_TOKEN")
    fi
    
    if ! curl -s "${headers[@]}" "$api_url" > "$repos_file"; then
        log_error "Failed to fetch repositories"
        return 1
    fi
    
    if jq -e '.message' "$repos_file" >/dev/null 2>&1; then
        local error_msg=$(jq -r '.message' "$repos_file")
        log_error "GitHub API error: $error_msg"
        return 1
    fi
    
    # Filter repositories
    local filter=".[] | select(.archived == false"
    if [ "$EXCLUDE_FORKS" = true ]; then
        filter="$filter and .fork == false"
    fi
    filter="$filter)"
    
    jq "[$filter]" "$repos_file" > "$TEMP_DIR/filtered_repos.json"
    
    # Limit repos if specified
    if [ "$MAX_REPOS" -gt 0 ]; then
        jq ".[0:$MAX_REPOS]" "$TEMP_DIR/filtered_repos.json" > "$TEMP_DIR/limited_repos.json"
        mv "$TEMP_DIR/limited_repos.json" "$TEMP_DIR/filtered_repos.json"
    fi
    
    local count=$(jq length "$TEMP_DIR/filtered_repos.json")
    log_success "Found $count repositories to scan"
}

scan_repo() {
    local repo_info="$1"
    local worker_id="$2"
    
    local repo_name=$(echo "$repo_info" | jq -r '.full_name')
    local clone_url=$(echo "$repo_info" | jq -r '.clone_url')
    local size=$(echo "$repo_info" | jq -r '.size')
    
    log_progress "[$worker_id] Scanning: $repo_name (${size}KB)"
    
    local worker_dir="$TEMP_DIR/worker_$worker_id"
    mkdir -p "$worker_dir"
    
    local repo_dir="$worker_dir/repo"
    local output_file="$OUTPUT_DIR/${repo_name//\//_}.json"
    
    # Clone
    if ! git clone "$clone_url" "$repo_dir" 2>"$worker_dir/clone.log"; then
        echo '{"error": "clone_failed"}' > "$output_file"
        log_warning "[$worker_id] Clone failed: $repo_name"
        return 1
    fi
    
    # Calculate adaptive timeout based on repository characteristics
    local repo_size_mb=$(echo "scale=2; $size / 1024" | bc -l 2>/dev/null || echo "0")
    local estimated_files=0
    if [ -d "$repo_dir" ]; then
        estimated_files=$(find "$repo_dir" -type f 2>/dev/null | wc -l)
    fi
    
    local adaptive_timeout=$(calculate_adaptive_timeout "$repo_size_mb" "$estimated_files")
    log_debug "[$worker_id] Using adaptive timeout: ${adaptive_timeout}s for $repo_name (${repo_size_mb}MB, $estimated_files files)"
    
    # Scan with retry logic
    cd "$repo_dir"
    local scan_output="$worker_dir/scan.json"
    local max_retries=${TRUFFLEHOG_MAX_RETRIES:-2}
    local scan_success=false
    
    for attempt in $(seq 1 $((max_retries + 1))); do
        local current_timeout=$adaptive_timeout
        if [ $attempt -gt 1 ]; then
            # Increase timeout for retry attempts
            current_timeout=$((adaptive_timeout * attempt))
            log_debug "[$worker_id] Retry attempt $attempt/$((max_retries + 1)) with timeout: ${current_timeout}s"
        fi
        
        if timeout "$current_timeout" trufflehog git --json --only-verified --no-update "file://$(pwd)" > "$scan_output" 2>"$worker_dir/scan.log"; then
            log_debug "[$worker_id] Scan completed: $repo_name (attempt $attempt)"
            scan_success=true
            break
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                log_warning "[$worker_id] Scan timeout ($current_timeout s) for $repo_name (attempt $attempt)"
            else
                log_warning "[$worker_id] Scan failed with exit code $exit_code for $repo_name (attempt $attempt)"
            fi
            
            # If this was the last attempt, break
            if [ $attempt -eq $((max_retries + 1)) ]; then
                break
            fi
        fi
    done
    
    if [ "$scan_success" = false ]; then
        echo '{"error": "scan_failed", "attempts": '$((max_retries + 1))'}' > "$output_file"
        log_error "[$worker_id] All scan attempts failed for $repo_name"
        cd - > /dev/null
        return 1
    fi
    
    cd - > /dev/null
    
    # Process results
    local findings=0
    echo "[" > "$output_file"
    local first=true
    
    while IFS= read -r line; do
        if [ -n "$line" ] && echo "$line" | jq . >/dev/null 2>&1; then
            if echo "$line" | jq -e '.Verified == true' >/dev/null 2>&1; then
                if [ "$first" = false ]; then
                    echo "," >> "$output_file"
                fi
                first=false
                
                local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
                echo "$line" | jq ". + {\"scan_timestamp\": \"$timestamp\", \"repository_name\": \"$repo_name\"}" >> "$output_file"
                ((findings++))
            fi
        fi
    done < "$scan_output"
    
    echo "]" >> "$output_file"
    
    if [ "$findings" -gt 0 ]; then
        log_success "[$worker_id] Found $findings secrets in $repo_name"
        
        # Send immediate notification for first secret found
        if [ "$findings" -eq 1 ] && ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]); then
            send_immediate_notification "$repo_name" "$output_file" "$worker_id"
        fi
    else
        log_debug "[$worker_id] No secrets in $repo_name"
    fi
    
    rm -rf "$worker_dir"
}

scan_all_repos() {
    local repos_file="$TEMP_DIR/filtered_repos.json"
    local total=$(jq length "$repos_file")
    
    log_progress "Starting scan of $total repositories with $MAX_WORKERS workers"
    
    # Create job list
    local job_file="$TEMP_DIR/jobs.txt"
    for ((i=0; i<total; i++)); do
        echo "$i" >> "$job_file"
    done
    
    # Start workers
    local pids=()
    for ((w=1; w<=MAX_WORKERS; w++)); do
        worker_process "$w" "$repos_file" "$job_file" &
        pids+=($!)
    done
    
    # Wait for completion
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    log_success "All workers completed"
}

worker_process() {
    local worker_id="$1"
    local repos_file="$2"
    local job_file="$3"
    
    while true; do
        local job_index
        {
            job_index=$(head -n1 "$job_file" 2>/dev/null) || break
            sed -i '1d' "$job_file" 2>/dev/null || break
        }
        
        if [ -z "$job_index" ]; then
            break
        fi
        
        local repo_info
        repo_info=$(jq ".[$job_index]" "$repos_file")
        
        if [ "$repo_info" = "null" ]; then
            continue
        fi
        
        scan_repo "$repo_info" "$worker_id"
    done
}

generate_summary() {
    local total_files=$(find "$OUTPUT_DIR" -name "*.json" | wc -l)
    local total_secrets=0
    local repos_with_secrets=0
    
    log_progress "Generating summary..."
    
    echo "============================================================"
    echo "📊 SCAN SUMMARY"
    echo "============================================================"
    echo "Organization: $ORG"
    echo "Repositories scanned: $total_files"
    echo ""
    
    for file in "$OUTPUT_DIR"/*.json; do
        if [ ! -f "$file" ]; then
            continue
        fi
        
        local count
        count=$(jq length "$file" 2>/dev/null || echo "0")
        
        if [ "$count" -gt 0 ]; then
            local repo_name
            repo_name=$(basename "$file" .json | tr '_' '/')
            echo "🔑 $repo_name: $count secret(s)"
            ((total_secrets += count))
            ((repos_with_secrets++))
        fi
    done
    
    echo ""
    echo "Total secrets found: $total_secrets"
    echo "Repositories with secrets: $repos_with_secrets"
    echo "============================================================"
    
    # Send completion notification if notifications are enabled and secrets were found
    if ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]) && [ "$total_secrets" -gt 0 ]; then
        send_completion_notification "$total_secrets" "$repos_with_secrets"
    fi
    
    log_success "Results saved in: $(realpath "$OUTPUT_DIR")"
}

# Send immediate notification for first secret found in a repository
send_immediate_notification() {
    local repo_name="$1"
    local secrets_file="$2"
    local worker_id="$3"
    
    # Create immediate notification file with special naming
    local immediate_file="$TEMP_DIR/immediate_secret_${repo_name//\//_}_$(date +%s).json"
    cp "$secrets_file" "$immediate_file"
    
    log_debug "[$worker_id] Sending immediate notification for $repo_name"
    
    # Export environment variables for notification script
    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
        export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
    fi
    
    # Use enhanced notification script
    if [ -f "$NOTIFICATION_SCRIPT" ]; then
        # Send immediate notification in background
        if [ -n "$NOTIFICATION_EMAIL" ]; then
            bash "$NOTIFICATION_SCRIPT" "$ORG" "$immediate_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$ORG" "$immediate_file" >/dev/null 2>&1 &
        fi
        local notification_pid=$!
        log_debug "[$worker_id] Immediate notification sent (PID: $notification_pid)"
    else
        log_warning "[$worker_id] Notification script not found: $NOTIFICATION_SCRIPT"
    fi
}

# Send completion notification for the entire organization scan
send_completion_notification() {
    local total_secrets="$1"
    local repos_with_secrets="$2"
    
    if [ "$total_secrets" -eq 0 ]; then
        log_debug "No secrets found, skipping completion notification"
        return 0
    fi
    
    # Create consolidated results file for completion notification
    local completion_file="$OUTPUT_DIR/completion_summary_${ORG}_$(date +%s).json"
    echo "[" > "$completion_file"
    local first=true
    
    for file in "$OUTPUT_DIR"/*.json; do
        if [ ! -f "$file" ] || [[ "$(basename "$file")" == completion_summary_* ]]; then
            continue
        fi
        
        # Check if file has secrets
        local count=$(jq length "$file" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            if [ "$first" = false ]; then
                echo "," >> "$completion_file"
            fi
            first=false
            
            # Add each secret with organization context
            jq -c '.[]' "$file" | while read -r secret; do
                if [ "$first" = false ]; then
                    echo "," >> "$completion_file"
                fi
                first=false
                echo "$secret" | jq ". + {\"organization\": \"$ORG\"}" >> "$completion_file"
            done
        fi
    done
    
    echo "]" >> "$completion_file"
    
    log_progress "Sending completion notification for $total_secrets secrets"
    
    # Export environment variables for notification script
    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
        export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
    fi
    
    # Use enhanced notification script
    if [ -f "$NOTIFICATION_SCRIPT" ]; then
        # Send completion notification in background
        if [ -n "$NOTIFICATION_EMAIL" ]; then
            bash "$NOTIFICATION_SCRIPT" "$ORG" "$completion_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$ORG" "$completion_file" >/dev/null 2>&1 &
        fi
        local notification_pid=$!
        log_success "Completion notification sent (PID: $notification_pid)"
    else
        log_warning "Notification script not found: $NOTIFICATION_SCRIPT"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) show_help; exit 0 ;;
            --max-repos) MAX_REPOS="$2"; shift 2 ;;
            --max-workers) MAX_WORKERS="$2"; shift 2 ;;
            --timeout) TIMEOUT="$2"; shift 2 ;;
            --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
            --include-forks) EXCLUDE_FORKS=false; shift ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
            --telegram-chat-id) NOTIFICATION_TELEGRAM_CHAT_ID="$2"; shift 2 ;;
            --debug) DEBUG=true; shift ;;
            --no-cleanup) CLEANUP=false; shift ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) 
                if [ -z "${ORG:-}" ]; then
                    ORG="$1"
                else
                    log_error "Too many arguments: $1"
                    exit 1
                fi
                shift ;;
        esac
    done
    
    if [ -z "${ORG:-}" ]; then
        log_error "Organization name required"
        show_help
        exit 1
    fi
    
    if [ -z "$OUTPUT_DIR" ]; then
        # Create timestamped results directory structure inside org-scanner folder
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        OUTPUT_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}/org_leaked_secrets/scan_${ORG}_${TIMESTAMP}"
    fi
}

main() {
    parse_args "$@"
    
    # Apply dynamic worker detection if auto-detect mode (0)
    if [[ "$MAX_WORKERS" == "0" ]]; then
        MAX_WORKERS="$AUTO_DETECTED_WORKERS"
        if [[ "$DEBUG" == "true" ]]; then
            echo "[DEBUG] Auto-detected workers: $MAX_WORKERS (CPU cores: $CPU_CORES, Memory: ${MEMORY_GB}GB, Load: $LOAD_AVERAGE)"
        fi
    fi
    
    # Check dependencies
    for tool in git trufflehog jq curl; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not found"
            exit 1
        fi
    done
    
    trap cleanup_on_exit EXIT
    
    TEMP_DIR=$(mktemp -d -t org_scan.XXXXXX)
    mkdir -p "$OUTPUT_DIR"
    
    # Create debug log directory if debug mode is enabled
    if [ "$DEBUG" = true ]; then
        mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/org_scan_${ORG}_$(date +%Y%m%d_%H%M%S).log"
        log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
        # Start logging to file (in addition to console)
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
    
    log_info "Scanning organization: $ORG"
    log_info "Output directory: $(realpath "$OUTPUT_DIR")"
    log_info "Results will be saved in: leaked_secrets_results structure"
    
    get_org_repos "$ORG"
    scan_all_repos
    generate_summary
}

main "$@"