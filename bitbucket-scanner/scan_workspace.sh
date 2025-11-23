#!/bin/bash
#
# Bitbucket Workspace Scanner
# Scans all repositories in a Bitbucket workspace for leaked secrets
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
ORGANIZED=false  # Track if results have been organized
OUTPUT_DIR=""
TEMP_DIR=""
DEBUG=false
LOG_DIR="$SCRIPT_DIR/scan_logs"  # Local debug logs directory
BITBUCKET_USERNAME="${BITBUCKET_USERNAME:-""}"  # Username for authentication
BITBUCKET_APP_PASSWORD="${BITBUCKET_APP_PASSWORD:-""}"  # App password for authentication
EXCLUDE_PRIVATE=false
MAX_REPOS=0
WORKSPACES_FILE=""  # File containing list of workspaces to scan

# Default timeout values (adaptive timeout used dynamically during scanning)
export TRUFFLEHOG_BASE_TIMEOUT=900
export TRUFFLEHOG_MAX_TIMEOUT=3600
export TRUFFLEHOG_MAX_RETRIES=2
export GIT_OPERATION_TIMEOUT=300

# Notification configuration
NOTIFICATION_EMAIL=""  # Email address for notifications (empty = disabled)
NOTIFICATION_TELEGRAM_CHAT_ID=""  # Telegram chat ID for notifications (empty = disabled)
NOTIFICATION_SCRIPT="$SCRIPT_DIR/../send_notifications_enhanced.sh"  # Enhanced notification system

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
Bitbucket Workspace Scanner

Usage:
    $0 <workspace> [options]
    $0 --workspaces-file <file> [options]

Examples:
    $0 myworkspace
    $0 atlassian --max-repos 5
    $0 myworkspace --username myuser --app-password xxx
    $0 myworkspace --telegram-chat-id 123456789 --debug
    $0 --workspaces-file workspaces.txt --telegram-chat-id 123456789

Options:
    --workspaces-file FILE   File containing list of workspaces (one per line)
    --max-repos N            Maximum repositories to scan (default: all)
    --username USER          Bitbucket username for authentication
    --app-password PASS      Bitbucket app password for authentication
    --exclude-private        Exclude private repositories (default: included if authenticated)
    --output-dir DIR         Custom output directory
    --email EMAIL            Email address for security notifications
    --telegram-chat-id ID    Telegram chat ID for security notifications
    --debug                  Debug output
    --help                   Show help

Environment Variables:
    BITBUCKET_USERNAME       Bitbucket username (can be overridden with --username)
    BITBUCKET_APP_PASSWORD   Bitbucket app password (can be overridden with --app-password)

Authentication:
    For private repositories, create an app password at:
    https://bitbucket.org/account/settings/app-passwords/
    Required permissions: Repositories (Read)

Dynamic Configuration:
    The script automatically detects CPU cores, memory, and system load to determine
    optimal worker count and timeout values based on repository size and complexity.

Notifications:
    Use --email and/or --telegram-chat-id to receive security notifications when
    secrets are found. Requires proper configuration of notification scripts.

EOF
}

cleanup_on_exit() {
    # Kill all child processes (workers) first
    if [ -n "${WORKER_PIDS:-}" ]; then
        log_progress "Stopping workers..."
        for pid in ${WORKER_PIDS[@]:-}; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        # Wait a bit for graceful shutdown
        sleep 1
        # Force kill any remaining
        for pid in ${WORKER_PIDS[@]:-}; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
    
    # Organize results before cleaning up temp files (only if not already done)
    # Disable interrupts during organization to ensure completion
    if [ "$ORGANIZED" = false ] && [ -n "${OUTPUT_DIR:-}" ] && [ -d "$OUTPUT_DIR" ]; then
        trap '' INT TERM  # Ignore interrupts during organization
        organize_results
        trap cleanup_on_exit EXIT INT TERM  # Re-enable trap
    fi
    
    if [ "$CLEANUP" = true ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_progress "Cleaning up..."
        rm -rf "$TEMP_DIR"
    fi
}

get_workspace_repos() {
    local workspace="$1"
    local repos_file="$TEMP_DIR/repos.json"
    local all_repos_file="$TEMP_DIR/all_repos.json"
    
    log_progress "Fetching repositories for workspace: $workspace..."
    
    # Warn if no credentials are set
    if [ -z "$BITBUCKET_USERNAME" ] || [ -z "$BITBUCKET_APP_PASSWORD" ]; then
        log_warning "No Bitbucket credentials set - only public repositories will be accessible"
        log_info "For private workspaces, set credentials: --username <user> --app-password <pass>"
    fi
    
    # Initialize empty array for collecting all repositories
    echo "[]" > "$all_repos_file"
    
    # Start with first page
    local api_url="https://api.bitbucket.org/2.0/repositories/${workspace}"
    
    # Fetch all pages
    local page=1
    while [ -n "$api_url" ]; do
        log_debug "Fetching page $page: $api_url"
        
        # Perform curl with or without authentication
        if [ -n "$BITBUCKET_USERNAME" ] && [ -n "$BITBUCKET_APP_PASSWORD" ]; then
            if ! curl -s -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" "$api_url" > "$repos_file"; then
                log_error "Failed to fetch repositories (page $page)"
                return 1
            fi
        else
            if ! curl -s "$api_url" > "$repos_file"; then
                log_error "Failed to fetch repositories (page $page)"
                return 1
            fi
        fi
        
        # Check for API errors
        if jq -e '.error' "$repos_file" >/dev/null 2>&1; then
            local error_msg=$(jq -r '.error.message' "$repos_file" 2>/dev/null || echo "Unknown error")
            log_error "Bitbucket API error: $error_msg"
            return 1
        fi
        
        # Extract repositories from this page
        local page_repos=$(jq '.values // []' "$repos_file")
        local page_count=$(echo "$page_repos" | jq 'length')
        
        if [ "$page_count" -eq 0 ]; then
            log_debug "No repositories found on page $page"
            break
        fi
        
        # Append this page's repos to the all_repos file
        jq -s '.[0] + .[1]' "$all_repos_file" <(echo "$page_repos") > "$TEMP_DIR/merged.json"
        mv "$TEMP_DIR/merged.json" "$all_repos_file"
        
        log_progress "Fetched $page_count repositories from page $page (total: $(jq 'length' "$all_repos_file"))"
        
        # Get next page URL
        api_url=$(jq -r '.next // empty' "$repos_file")
        page=$((page + 1))
    done
    
    # Use the combined results
    mv "$all_repos_file" "$repos_file"
    
    local total_fetched=$(jq 'length' "$repos_file")
    log_info "Total repositories fetched: $total_fetched"
    
    # Count private repos for reporting
    local private_count=$(jq '[.[] | select(.is_private == true)] | length' "$repos_file")
    
    # Build filter based on flags
    local filter=".[]"
    local filters=()
    
    if [ "$EXCLUDE_PRIVATE" = true ]; then
        filters+=(".is_private == false")
    fi
    
    # Apply filters if any
    if [ ${#filters[@]} -gt 0 ]; then
        local filter_expr=$(IFS=" and "; echo "${filters[*]}")
        filter="$filter | select($filter_expr)"
    fi
    
    jq "[$filter]" "$repos_file" > "$TEMP_DIR/filtered_repos.json"
    
    # Show filtering info
    if [ "$EXCLUDE_PRIVATE" = true ] && [ "$private_count" -gt 0 ]; then
        log_info "Excluding $private_count private repositories"
    fi
    
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
    local size=$(echo "$repo_info" | jq -r '.size // 0')
    
    # Get clone URL - prefer HTTPS
    local clone_url=$(echo "$repo_info" | jq -r '.links.clone[] | select(.name == "https") | .href')
    
    # If credentials are set, inject them into the clone URL for authentication
    if [ -n "$BITBUCKET_USERNAME" ] && [ -n "$BITBUCKET_APP_PASSWORD" ]; then
        clone_url=$(echo "$clone_url" | sed "s|https://|https://${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}@|")
    fi
    
    log_progress "[$worker_id] Scanning: $repo_name (${size} bytes)"
    
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
    local repo_size_mb=$(echo "scale=2; $size / 1048576" | bc -l 2>/dev/null || echo "0")
    local estimated_files=0
    if [ -d "$repo_dir" ]; then
        estimated_files=$(find "$repo_dir" -type f 2>/dev/null | wc -l)
    fi
    
    local adaptive_timeout=$(calculate_adaptive_timeout "$repo_size_mb" "$estimated_files")
    log_debug "[$worker_id] Using adaptive timeout: ${adaptive_timeout}s for $repo_name (${repo_size_mb}MB, $estimated_files files)"
    
    # Scan with retry logic
    if ! cd "$repo_dir"; then
        echo '{"error": "cd_failed"}' > "$output_file"
        log_error "[$worker_id] Failed to change to repo directory: $repo_name"
        return 1
    fi
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
        cd - > /dev/null || true
        return 1
    fi
    
    cd - > /dev/null || true
    
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
                echo "$line" | jq ". + {\"scan_timestamp\": \"$timestamp\", \"repository_name\": \"$repo_name\", \"source\": \"bitbucket\"}" >> "$output_file"
                ((findings++))
            fi
        fi
    done < "$scan_output"
    
    echo "]" >> "$output_file"
    
    if [ "$findings" -gt 0 ]; then
        log_success "[$worker_id] Found $findings secrets in $repo_name"
        
        # Send immediate notification for any secrets found
        # Check if any notification method is configured
        if [ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ] || [ -f "$SCRIPT_DIR/../config/discord_config.sh" ]; then
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
    WORKER_PIDS=()
    for ((w=1; w<=MAX_WORKERS; w++)); do
        worker_process "$w" "$repos_file" "$job_file" &
        WORKER_PIDS+=($!)
    done
    
    log_progress "Workers started (PIDs: ${WORKER_PIDS[*]}). Waiting for completion..."
    
    # Wait for completion
    for pid in "${WORKER_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    log_success "All workers completed"
}

worker_process() {
    # Disable strict error handling in workers to prevent premature exits
    set +e
    
    local worker_id="$1"
    local repos_file="$2"
    local job_file="$3"
    local lock_file="${job_file}.lock"
    local scanned_count=0
    
    log_progress "[$worker_id] Worker started"
    
    while true; do
        # Check if temp directory still exists (parent might have been interrupted)
        if [ ! -d "$TEMP_DIR" ]; then
            log_debug "[$worker_id] Temp directory gone, exiting gracefully"
            return 0
        fi
        
        local job_index=""
        
        # Use flock for atomic file operations
        # Read and delete in one atomic operation using a temp file
        {
            if ! flock -x 200; then
                log_error "[$worker_id] Failed to acquire lock"
                return 1
            fi
            
            # Check if job file still exists
            if [ ! -f "$job_file" ]; then
                return 0
            fi
            
            job_index=$(head -n1 "$job_file" 2>/dev/null)
            if [ -n "$job_index" ]; then
                tail -n +2 "$job_file" > "$job_file.tmp" 2>/dev/null
                mv "$job_file.tmp" "$job_file" 2>/dev/null
            fi
        } 200>"$lock_file" 2>/dev/null || return 0
        
        if [ -z "$job_index" ]; then
            break
        fi
        
        local repo_info
        repo_info=$(jq ".[$job_index]" "$repos_file")
        
        if [ "$repo_info" = "null" ]; then
            continue
        fi
        
        scan_repo "$repo_info" "$worker_id"
        ((scanned_count++))
    done
    
    log_progress "[$worker_id] Worker completed. Scanned $scanned_count repositories"
}

generate_summary() {
    local total_files=$(find "$OUTPUT_DIR" -name "*.json" | wc -l)
    local total_secrets=0
    local repos_with_secrets=0
    
    log_progress "Generating summary..."
    
    echo "============================================================"
    echo "📊 SCAN SUMMARY"
    echo "============================================================"
    echo "Workspace: $WORKSPACE"
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
    # Check if any notification method is configured
    if ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ] || [ -f "$SCRIPT_DIR/../config/discord_config.sh" ]) && [ "$total_secrets" -gt 0 ]; then
        send_completion_notification "$total_secrets" "$repos_with_secrets"
    fi
    
    log_success "Results saved in: $(realpath "$OUTPUT_DIR")"
}

# Organize results: move files with secrets to workspace folder, remove empty files
organize_results() {
    log_progress "Organizing results..."
    
    local secrets_dir="$OUTPUT_DIR/${WORKSPACE}_secrets"
    local files_with_secrets=0
    local files_removed=0
    
    # Create directory for files with secrets
    mkdir -p "$secrets_dir"
    
    # Temporarily disable pipefail for file processing
    set +e
    
    # Use find with size filter for performance (files with secrets are > 100 bytes)
    # Create temp file lists
    local large_files_list="$OUTPUT_DIR/.large_files.tmp"
    local small_files_list="$OUTPUT_DIR/.small_files.tmp"
    
    find "$OUTPUT_DIR" -maxdepth 1 -name "*.json" -type f -size +100c ! -name "completion_summary_*" > "$large_files_list" 2>/dev/null
    find "$OUTPUT_DIR" -maxdepth 1 -name "*.json" -type f ! -size +100c ! -name "completion_summary_*" > "$small_files_list" 2>/dev/null
    
    # Process large files (potential secrets)
    if [ -s "$large_files_list" ]; then
        while IFS= read -r file; do
            # Verify with jq that it actually has secrets
            local count=0
            count=$(jq 'if type == "array" then length else 0 end' "$file" 2>/dev/null || echo "0")
            
            if [ -z "$count" ] || [ "$count" = "null" ]; then
                count=0
            fi
            
            if [ "$count" -gt 0 ] 2>/dev/null; then
                # Move files with secrets to workspace folder
                mv "$file" "$secrets_dir/" 2>/dev/null
                ((files_with_secrets++))
                log_debug "Moved $(basename "$file") with $count secret(s) to ${WORKSPACE}_secrets/"
            else
                # False positive (large but empty), remove
                rm "$file" 2>/dev/null
                ((files_removed++))
            fi
        done < "$large_files_list"
    fi
    
    # Remove small files (definitely empty - just "[]" or similar)
    if [ -s "$small_files_list" ]; then
        local small_files_count=$(wc -l < "$small_files_list")
        while IFS= read -r file; do
            rm "$file" 2>/dev/null
        done < "$small_files_list"
        files_removed=$((files_removed + small_files_count))
        log_debug "Removed $small_files_count small/empty files"
    fi
    
    # Clean up temp files
    rm -f "$large_files_list" "$small_files_list"
    
    # Re-enable pipefail
    set -e
    
    # Log summary
    if [ "$files_with_secrets" -gt 0 ]; then
        log_success "📁 Organized $files_with_secrets file(s) with secrets into: ${WORKSPACE}_secrets/"
        log_success "🗑️  Removed $files_removed file(s) with no secrets"
        log_info "Access secrets at: $(realpath "$secrets_dir")"
    else
        log_info "No secrets found, removed $files_removed empty file(s)"
        # Remove the empty secrets directory if no files were moved
        rmdir "$secrets_dir" 2>/dev/null || true
    fi
    
    # Mark organization as complete
    ORGANIZED=true
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
            bash "$NOTIFICATION_SCRIPT" "$WORKSPACE" "$immediate_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$WORKSPACE" "$immediate_file" >/dev/null 2>&1 &
        fi
        local notification_pid=$!
        log_debug "[$worker_id] Immediate notification sent (PID: $notification_pid)"
    else
        log_warning "[$worker_id] Notification script not found: $NOTIFICATION_SCRIPT"
    fi
}

# Send completion notification for the entire workspace scan
send_completion_notification() {
    local total_secrets="$1"
    local repos_with_secrets="$2"
    
    if [ "$total_secrets" -eq 0 ]; then
        log_debug "No secrets found, skipping completion notification"
        return 0
    fi
    
    # Create consolidated results file for completion notification
    local completion_file="$OUTPUT_DIR/completion_summary_${WORKSPACE}_$(date +%s).json"
    echo "[" > "$completion_file"
    local is_first_secret=true
    
    for file in "$OUTPUT_DIR"/*.json; do
        if [ ! -f "$file" ] || [[ "$(basename "$file")" == completion_summary_* ]]; then
            continue
        fi
        
        # Check if file has secrets
        local count=$(jq length "$file" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            # Add each secret with workspace context
            while IFS= read -r secret; do
                if [ -n "$secret" ]; then
                    if [ "$is_first_secret" = false ]; then
                        echo "," >> "$completion_file"
                    fi
                    is_first_secret=false
                    echo "$secret" | jq -c ". + {\"workspace\": \"$WORKSPACE\"}" >> "$completion_file"
                fi
            done < <(jq -c '.[]' "$file" 2>/dev/null)
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
            bash "$NOTIFICATION_SCRIPT" "$WORKSPACE" "$completion_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$WORKSPACE" "$completion_file" >/dev/null 2>&1 &
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
            --username) BITBUCKET_USERNAME="$2"; shift 2 ;;
            --app-password) BITBUCKET_APP_PASSWORD="$2"; shift 2 ;;
            --exclude-private) EXCLUDE_PRIVATE=true; shift ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
            --telegram-chat-id) NOTIFICATION_TELEGRAM_CHAT_ID="$2"; shift 2 ;;
            --workspaces-file) WORKSPACES_FILE="$2"; shift 2 ;;
            --debug) DEBUG=true; shift ;;
            --no-cleanup) CLEANUP=false; shift ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) 
                if [ -z "${WORKSPACE:-}" ]; then
                    WORKSPACE="$1"
                else
                    log_error "Too many arguments: $1"
                    exit 1
                fi
                shift ;;
        esac
    done
    
    # Check for workspaces file or single workspace
    if [ -n "$WORKSPACES_FILE" ] && [ -n "${WORKSPACE:-}" ]; then
        log_error "Cannot specify both --workspaces-file and workspace name"
        exit 1
    fi
    
    if [ -z "$WORKSPACES_FILE" ] && [ -z "${WORKSPACE:-}" ]; then
        log_error "Workspace name or --workspaces-file required"
        show_help
        exit 1
    fi
    
    # Validate workspaces file if specified
    if [ -n "$WORKSPACES_FILE" ]; then
        if [ ! -f "$WORKSPACES_FILE" ]; then
            log_error "Workspaces file not found: $WORKSPACES_FILE"
            exit 1
        fi
    fi
    
    if [ -z "$OUTPUT_DIR" ] && [ -z "$WORKSPACES_FILE" ]; then
        # Create timestamped results directory structure inside bitbucket-scanner folder
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        OUTPUT_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}/workspace_leaked_secrets/scan_${WORKSPACE}_${TIMESTAMP}"
    fi
}

main() {
    parse_args "$@"
    
    # Apply dynamic worker detection (always auto-detect)
    MAX_WORKERS="$AUTO_DETECTED_WORKERS"
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] Auto-detected workers: $MAX_WORKERS (CPU cores: $CPU_CORES, Memory: ${MEMORY_GB}GB, Load: $LOAD_AVERAGE)"
    fi
    
    # Check dependencies
    for tool in git trufflehog jq curl; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not found"
            exit 1
        fi
    done
    
    trap cleanup_on_exit EXIT INT TERM
    
    TEMP_DIR=$(mktemp -d -t bitbucket_scan.XXXXXX)
    
    # If workspaces file is provided, loop through workspaces
    if [ -n "$WORKSPACES_FILE" ]; then
        log_info "Processing workspaces from file: $WORKSPACES_FILE"
        
        # Create timestamped base directory for this batch run
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BATCH_OUTPUT_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}/workspace_leaked_secrets"
        
        # Read workspaces from file
        while IFS= read -r workspace || [ -n "$workspace" ]; do
            # Skip comments and empty lines
            [[ "$workspace" =~ ^#.*$ ]] && continue
            [[ -z "$workspace" ]] && continue
            
            # Trim whitespace
            workspace=$(echo "$workspace" | xargs)
            
            log_info "========================================"
            log_info "Processing workspace: $workspace"
            log_info "========================================"
            
            # Set current workspace and output directory
            WORKSPACE="$workspace"
            OUTPUT_DIR="$BATCH_OUTPUT_DIR/scan_${WORKSPACE}_${TIMESTAMP}"
            mkdir -p "$OUTPUT_DIR"
            
            # Reset organization flag for this workspace
            ORGANIZED=false
            
            # Create debug log for this workspace if debug mode is enabled
            if [ "$DEBUG" = true ]; then
                mkdir -p "$LOG_DIR"
                LOG_FILE="$LOG_DIR/workspace_scan_${WORKSPACE}_$(date +%Y%m%d_%H%M%S).log"
                log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
                # Start logging to file (in addition to console)
                exec > >(tee -a "$LOG_FILE") 2>&1
            fi
            
            log_info "Output directory: $(realpath "$OUTPUT_DIR")"
            
            # Reset worker state for this workspace
            WORKER_PIDS=()
            
            # Scan this workspace (disable exit-on-error for individual workspace failures)
            set +e
            get_workspace_repos "$WORKSPACE"
            local repos_result=$?
            if [ $repos_result -eq 0 ]; then
                scan_all_repos
                generate_summary
                organize_results
            else
                log_error "Failed to fetch repositories for $workspace, skipping..."
            fi
            set -e
            
            # Clean up temp files for this workspace (but keep TEMP_DIR for next workspace)
            if [ -d "$TEMP_DIR" ]; then
                rm -f "$TEMP_DIR"/*.json "$TEMP_DIR"/*.txt "$TEMP_DIR"/*.lock 2>/dev/null || true
                rm -rf "$TEMP_DIR"/worker_* 2>/dev/null || true
            fi
            
            log_info "Completed scanning workspace: $workspace"
            log_info ""
            
        done < "$WORKSPACES_FILE"
        
        log_info "========================================"
        log_info "All workspaces processed"
        log_info "Results saved in: $BATCH_OUTPUT_DIR"
        log_info "========================================"
    else
        # Single workspace mode
        mkdir -p "$OUTPUT_DIR"
        
        # Create debug log directory if debug mode is enabled
        if [ "$DEBUG" = true ]; then
            mkdir -p "$LOG_DIR"
            LOG_FILE="$LOG_DIR/workspace_scan_${WORKSPACE}_$(date +%Y%m%d_%H%M%S).log"
            log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
            # Start logging to file (in addition to console)
            exec > >(tee -a "$LOG_FILE") 2>&1
        fi
        
        log_info "Scanning Bitbucket workspace: $WORKSPACE"
        log_info "Output directory: $(realpath "$OUTPUT_DIR")"
        log_info "Results will be saved in: leaked_secrets_results structure"
        
        get_workspace_repos "$WORKSPACE"
        scan_all_repos
        generate_summary
        organize_results
    fi
}

main "$@"
