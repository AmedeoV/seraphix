#!/bin/bash
#
# GitLab Group Scanner
# Scans all projects in a GitLab group for leaked secrets
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
ORGANIZED=false
OUTPUT_DIR=""
TEMP_DIR=""
DEBUG=false
LOG_DIR="$SCRIPT_DIR/scan_logs"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_INSTANCE="https://gitlab.com"
EXCLUDE_FORKS=true
EXCLUDE_ARCHIVED=true
MAX_REPOS=0
GROUPS_FILE=""
INCLUDE_SUBGROUPS=true

# Default timeout values
export TRUFFLEHOG_BASE_TIMEOUT=900
export TRUFFLEHOG_MAX_TIMEOUT=3600
export TRUFFLEHOG_MAX_RETRIES=2
export GIT_OPERATION_TIMEOUT=300

# Notification configuration
NOTIFICATION_EMAIL=""
NOTIFICATION_TELEGRAM_CHAT_ID=""
NOTIFICATION_SCRIPT="$SCRIPT_DIR/../send_notifications_enhanced.sh"

# System resource detection
detect_system_resources() {
    if command -v nproc &> /dev/null; then
        CPU_CORES=$(nproc)
    elif [ -r /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    else
        CPU_CORES=2
    fi
    
    if [ -r /proc/meminfo ]; then
        local mem_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
        MEMORY_GB=$((mem_kb / 1024 / 1024))
    else
        MEMORY_GB=4
    fi
    
    if [ -r /proc/loadavg ]; then
        LOAD_AVERAGE=$(cut -d' ' -f1 /proc/loadavg)
    else
        LOAD_AVERAGE="1.0"
    fi
    
    local mem_workers=$((MEMORY_GB / 2))
    if [ "$mem_workers" -lt 1 ]; then
        mem_workers=1
    fi
    
    local base_workers=$CPU_CORES
    if [ "$mem_workers" -lt "$base_workers" ]; then
        base_workers=$mem_workers
    fi
    
    local load_int=$(echo "$LOAD_AVERAGE" | cut -d'.' -f1)
    if [ "$load_int" -gt "$CPU_CORES" ]; then
        base_workers=$((base_workers / 2))
        if [ "$base_workers" -lt 1 ]; then
            base_workers=1
        fi
    fi
    
    if [ "$base_workers" -lt 1 ]; then
        AUTO_DETECTED_WORKERS=1
    elif [ "$base_workers" -gt 8 ]; then
        AUTO_DETECTED_WORKERS=8
    else
        AUTO_DETECTED_WORKERS=$base_workers
    fi
}

detect_system_resources

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_progress() { echo -e "${CYAN}🔄 $1${NC}"; }
log_debug() { [ "$DEBUG" = true ] && echo -e "${YELLOW}🐛 $1${NC}"; }

calculate_adaptive_timeout() {
    local repo_size_mb="$1"
    local estimated_files="$2"
    local base_timeout=${TRUFFLEHOG_BASE_TIMEOUT:-900}
    
    local calculated_timeout=$base_timeout
    
    if (( $(echo "$repo_size_mb > 500" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * 2.0" | bc -l 2>/dev/null || echo "$((calculated_timeout * 2))")
        log_debug "Large repo detected (${repo_size_mb}MB), increasing timeout" >&2
    elif (( $(echo "$repo_size_mb > 100" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * 1.5" | bc -l 2>/dev/null || echo "$((calculated_timeout * 3 / 2))")
        log_debug "Medium repo detected (${repo_size_mb}MB), moderately increasing timeout" >&2
    fi
    
    if [ "$estimated_files" -gt 1000 ]; then
        calculated_timeout=$(echo "$calculated_timeout * 1.3" | bc -l 2>/dev/null || echo "$((calculated_timeout * 13 / 10))")
        log_debug "Many files detected ($estimated_files), increasing timeout" >&2
    fi
    
    local max_timeout=${TRUFFLEHOG_MAX_TIMEOUT:-3600}
    if (( $(echo "$calculated_timeout > $max_timeout" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$max_timeout
        log_debug "Timeout capped at maximum: ${max_timeout}s" >&2
    fi
    
    printf "%.0f" "$calculated_timeout"
}

show_help() {
    cat << EOF
GitLab Group Scanner

Usage:
    $0 <group> [options]
    $0 --groups-file <file> [options]

Examples:
    $0 gitlab-org
    $0 gitlab-org --max-repos 5
    $0 mygroup --gitlab-token glpat-xxx --exclude-forks
    $0 mygroup --email security@company.com --telegram-chat-id 123456789
    $0 --groups-file groups.txt --telegram-chat-id 123456789
    $0 mygroup --gitlab-url https://gitlab.example.com
    $0 mygroup --scan-all  # Scan ALL projects including archived and forks

Options:
    --groups-file FILE    File containing list of groups (one per line)
    --max-repos N         Maximum projects to scan (default: all)
    --gitlab-url URL      GitLab instance URL (default: https://gitlab.com)
    --gitlab-token TOK    GitLab API token (overrides GITLAB_TOKEN env var)
    --include-forks       Include forked projects (default: excluded)
    --include-archived    Include archived projects (default: excluded)
    --scan-all            Scan ALL projects (includes forks and archived)
    --no-subgroups        Don't include subgroups (default: includes subgroups)
    --output-dir DIR      Custom output directory
    --email EMAIL         Email address for security notifications
    --telegram-chat-id ID Telegram chat ID for security notifications
    --debug               Debug output
    --help                Show help

Environment Variables:
    GITLAB_TOKEN          GitLab API token (can be overridden with --gitlab-token)

Project Filtering:
    By default, archived and forked projects are excluded to focus on active code.
    Use --include-forks, --include-archived, or --scan-all to customize filtering.

Dynamic Configuration:
    The script automatically detects CPU cores, memory, and system load to determine
    optimal worker count and timeout values based on repository size and complexity.

Notifications:
    Use --email and/or --telegram-chat-id to receive security notifications when
    secrets are found. Requires proper configuration of notification scripts.

EOF
}

cleanup_on_exit() {
    if [ -n "${WORKER_PIDS:-}" ]; then
        log_progress "Stopping workers..."
        for pid in ${WORKER_PIDS[@]:-}; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in ${WORKER_PIDS[@]:-}; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
    
    if [ "$ORGANIZED" = false ] && [ -n "${OUTPUT_DIR:-}" ] && [ -d "$OUTPUT_DIR" ]; then
        trap '' INT TERM
        organize_results
        trap cleanup_on_exit EXIT INT TERM
    fi
    
    if [ "$CLEANUP" = true ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_progress "Cleaning up..."
        rm -rf "$TEMP_DIR"
    fi
}

get_group_projects() {
    local group="$1"
    local projects_file="$TEMP_DIR/projects.json"
    local all_projects_file="$TEMP_DIR/all_projects.json"
    
    log_progress "Fetching projects for group: $group"
    
    if [ -z "$GITLAB_TOKEN" ]; then
        log_warning "GITLAB_TOKEN not set - only public projects will be accessible"
        log_info "For private groups, set your token: export GITLAB_TOKEN='your_token'"
    fi
    
    echo "[]" > "$all_projects_file"
    
    # URL encode the group name
    local encoded_group=$(echo "$group" | jq -sRr @uri)
    local base_url="$GITLAB_INSTANCE/api/v4/groups/$encoded_group/projects"
    local page=1
    local per_page=100
    
    # Add subgroups parameter if enabled
    local subgroups_param=""
    if [ "$INCLUDE_SUBGROUPS" = true ]; then
        subgroups_param="&include_subgroups=true"
    fi
    
    while true; do
        local api_url="${base_url}?per_page=${per_page}&page=${page}${subgroups_param}"
        
        log_debug "Fetching page $page..."
        
        if [ -n "$GITLAB_TOKEN" ]; then
            if ! curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url" > "$projects_file"; then
                log_error "Failed to fetch projects (page $page)"
                return 1
            fi
        else
            if ! curl -s "$api_url" > "$projects_file"; then
                log_error "Failed to fetch projects (page $page)"
                return 1
            fi
        fi
        
        # Check for API errors
        if jq -e '.message' "$projects_file" >/dev/null 2>&1; then
            local error_msg=$(jq -r '.message' "$projects_file")
            log_error "GitLab API error: $error_msg"
            return 1
        fi
        
        local page_count=$(jq 'length' "$projects_file")
        if [ "$page_count" -eq 0 ]; then
            log_debug "No more projects found (page $page)"
            break
        fi
        
        jq -s '.[0] + .[1]' "$all_projects_file" "$projects_file" > "$TEMP_DIR/merged.json"
        mv "$TEMP_DIR/merged.json" "$all_projects_file"
        
        log_progress "Fetched $page_count projects from page $page (total: $(jq 'length' "$all_projects_file"))"
        
        if [ "$page_count" -lt "$per_page" ]; then
            break
        fi
        
        page=$((page + 1))
    done
    
    mv "$all_projects_file" "$projects_file"
    
    local total_fetched=$(jq 'length' "$projects_file")
    log_info "Total projects fetched: $total_fetched"
    
    # Count archived and forked projects
    local archived_count=$(jq '[.[] | select(.archived == true)] | length' "$projects_file")
    local fork_count=$(jq '[.[] | select(.forked_from_project != null)] | length' "$projects_file")
    
    # Build filter
    local filter=".[]"
    local filters=()
    
    if [ "$EXCLUDE_ARCHIVED" = true ]; then
        filters+=(".archived == false")
    fi
    
    if [ "$EXCLUDE_FORKS" = true ]; then
        filters+=(".forked_from_project == null")
    fi
    
    if [ ${#filters[@]} -gt 0 ]; then
        local filter_expr=$(IFS=" and "; echo "${filters[*]}")
        filter="$filter | select($filter_expr)"
    fi
    
    jq "[$filter]" "$projects_file" > "$TEMP_DIR/filtered_projects.json"
    
    if [ "$EXCLUDE_ARCHIVED" = true ] && [ "$archived_count" -gt 0 ]; then
        log_info "Excluding $archived_count archived projects"
    fi
    if [ "$EXCLUDE_FORKS" = true ] && [ "$fork_count" -gt 0 ]; then
        log_info "Excluding $fork_count forked projects"
    fi
    
    if [ "$EXCLUDE_ARCHIVED" = false ] && [ "$EXCLUDE_FORKS" = false ]; then
        log_info "Scanning ALL projects (including archived and forks)"
    fi
    
    if [ "$MAX_REPOS" -gt 0 ]; then
        jq ".[0:$MAX_REPOS]" "$TEMP_DIR/filtered_projects.json" > "$TEMP_DIR/limited_projects.json"
        mv "$TEMP_DIR/limited_projects.json" "$TEMP_DIR/filtered_projects.json"
    fi
    
    local count=$(jq length "$TEMP_DIR/filtered_projects.json")
    log_success "Found $count projects to scan"
}

scan_project() {
    local project_info="$1"
    local worker_id="$2"
    
    local project_path=$(echo "$project_info" | jq -r '.path_with_namespace')
    local clone_url=$(echo "$project_info" | jq -r '.http_url_to_repo')
    
    # Inject token into clone URL if available
    if [ -n "$GITLAB_TOKEN" ]; then
        clone_url=$(echo "$clone_url" | sed "s|https://|https://oauth2:${GITLAB_TOKEN}@|")
    fi
    
    log_progress "[$worker_id] Scanning: $project_path"
    
    local worker_dir="$TEMP_DIR/worker_$worker_id"
    mkdir -p "$worker_dir"
    
    local repo_dir="$worker_dir/repo"
    local output_file="$OUTPUT_DIR/${project_path//\//_}.json"
    
    # Clone
    if ! git clone "$clone_url" "$repo_dir" 2>"$worker_dir/clone.log"; then
        echo '{"error": "clone_failed"}' > "$output_file"
        log_warning "[$worker_id] Clone failed: $project_path"
        return 1
    fi
    
    # Calculate adaptive timeout
    local repo_size_mb=0
    if [ -d "$repo_dir" ]; then
        local size_bytes=$(du -sb "$repo_dir" 2>/dev/null | cut -f1 || echo "0")
        repo_size_mb=$(echo "scale=2; $size_bytes / 1048576" | bc -l 2>/dev/null || echo "0")
    fi
    
    local estimated_files=0
    if [ -d "$repo_dir" ]; then
        estimated_files=$(find "$repo_dir" -type f 2>/dev/null | wc -l)
    fi
    
    local adaptive_timeout=$(calculate_adaptive_timeout "$repo_size_mb" "$estimated_files")
    log_debug "[$worker_id] Using adaptive timeout: ${adaptive_timeout}s for $project_path (${repo_size_mb}MB, $estimated_files files)"
    
    # Scan with retry logic
    if ! cd "$repo_dir"; then
        echo '{"error": "cd_failed"}' > "$output_file"
        log_error "[$worker_id] Failed to change to repo directory: $project_path"
        return 1
    fi
    
    local scan_output="$worker_dir/scan.json"
    local max_retries=${TRUFFLEHOG_MAX_RETRIES:-2}
    local scan_success=false
    
    for attempt in $(seq 1 $((max_retries + 1))); do
        local current_timeout=$adaptive_timeout
        if [ $attempt -gt 1 ]; then
            current_timeout=$((adaptive_timeout * attempt))
            log_debug "[$worker_id] Retry attempt $attempt/$((max_retries + 1)) with timeout: ${current_timeout}s"
        fi
        
        if timeout "$current_timeout" trufflehog git --json --only-verified --no-update "file://$(pwd)" > "$scan_output" 2>"$worker_dir/scan.log"; then
            log_debug "[$worker_id] Scan completed: $project_path (attempt $attempt)"
            scan_success=true
            break
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                log_warning "[$worker_id] Scan timeout ($current_timeout s) for $project_path (attempt $attempt)"
            else
                log_warning "[$worker_id] Scan failed with exit code $exit_code for $project_path (attempt $attempt)"
            fi
            
            if [ $attempt -eq $((max_retries + 1)) ]; then
                break
            fi
        fi
    done
    
    if [ "$scan_success" = false ]; then
        echo '{"error": "scan_failed", "attempts": '$((max_retries + 1))'}' > "$output_file"
        log_error "[$worker_id] All scan attempts failed for $project_path"
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
                echo "$line" | jq ". + {\"scan_timestamp\": \"$timestamp\", \"repository_name\": \"$project_path\", \"source\": \"gitlab\"}" >> "$output_file"
                ((findings++))
            fi
        fi
    done < "$scan_output"
    
    echo "]" >> "$output_file"
    
    if [ "$findings" -gt 0 ]; then
        log_success "[$worker_id] Found $findings secrets in $project_path"
        
        if [ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ] || [ -f "$SCRIPT_DIR/../config/discord_config.sh" ]; then
            send_immediate_notification "$project_path" "$output_file" "$worker_id"
        fi
    else
        log_debug "[$worker_id] No secrets in $project_path"
    fi
    
    rm -rf "$worker_dir"
}

scan_all_projects() {
    local projects_file="$TEMP_DIR/filtered_projects.json"
    local total=$(jq length "$projects_file")
    
    log_progress "Starting scan of $total projects with $MAX_WORKERS workers"
    
    local job_file="$TEMP_DIR/jobs.txt"
    for ((i=0; i<total; i++)); do
        echo "$i" >> "$job_file"
    done
    
    WORKER_PIDS=()
    for ((w=1; w<=MAX_WORKERS; w++)); do
        worker_process "$w" "$projects_file" "$job_file" &
        WORKER_PIDS+=($!)
    done
    
    log_progress "Workers started (PIDs: ${WORKER_PIDS[*]}). Waiting for completion..."
    
    for pid in "${WORKER_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    log_success "All workers completed"
}

worker_process() {
    set +e
    
    local worker_id="$1"
    local projects_file="$2"
    local job_file="$3"
    local lock_file="${job_file}.lock"
    local scanned_count=0
    
    log_progress "[$worker_id] Worker started"
    
    while true; do
        if [ ! -d "$TEMP_DIR" ]; then
            log_debug "[$worker_id] Temp directory gone, exiting gracefully"
            return 0
        fi
        
        local job_index=""
        
        {
            if ! flock -x 200; then
                log_error "[$worker_id] Failed to acquire lock"
                return 1
            fi
            
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
        
        local project_info
        project_info=$(jq ".[$job_index]" "$projects_file")
        
        if [ "$project_info" = "null" ]; then
            continue
        fi
        
        scan_project "$project_info" "$worker_id"
        ((scanned_count++))
    done
    
    log_progress "[$worker_id] Worker completed. Scanned $scanned_count projects"
}

generate_summary() {
    local total_files=$(find "$OUTPUT_DIR" -name "*.json" | wc -l)
    local total_secrets=0
    local projects_with_secrets=0
    
    log_progress "Generating summary..."
    
    echo "============================================================"
    echo "📊 SCAN SUMMARY"
    echo "============================================================"
    echo "Group: $GROUP"
    echo "Projects scanned: $total_files"
    echo ""
    
    for file in "$OUTPUT_DIR"/*.json; do
        if [ ! -f "$file" ]; then
            continue
        fi
        
        local count
        count=$(jq length "$file" 2>/dev/null || echo "0")
        
        if [ "$count" -gt 0 ]; then
            local project_name
            project_name=$(basename "$file" .json | tr '_' '/')
            echo "🔑 $project_name: $count secret(s)"
            ((total_secrets += count))
            ((projects_with_secrets++))
        fi
    done
    
    echo ""
    echo "Total secrets found: $total_secrets"
    echo "Projects with secrets: $projects_with_secrets"
    echo "============================================================"
    
    if ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ] || [ -f "$SCRIPT_DIR/../config/discord_config.sh" ]) && [ "$total_secrets" -gt 0 ]; then
        send_completion_notification "$total_secrets" "$projects_with_secrets"
    fi
    
    log_success "Results saved in: $(realpath "$OUTPUT_DIR")"
}

organize_results() {
    log_progress "Organizing results..."
    
    local secrets_dir="$OUTPUT_DIR/${GROUP}_secrets"
    local files_with_secrets=0
    local files_removed=0
    
    mkdir -p "$secrets_dir"
    
    set +e
    
    local large_files_list="$OUTPUT_DIR/.large_files.tmp"
    local small_files_list="$OUTPUT_DIR/.small_files.tmp"
    
    find "$OUTPUT_DIR" -maxdepth 1 -name "*.json" -type f -size +100c ! -name "completion_summary_*" > "$large_files_list" 2>/dev/null
    find "$OUTPUT_DIR" -maxdepth 1 -name "*.json" -type f ! -size +100c ! -name "completion_summary_*" > "$small_files_list" 2>/dev/null
    
    if [ -s "$large_files_list" ]; then
        while IFS= read -r file; do
            local count=0
            count=$(jq 'if type == "array" then length else 0 end' "$file" 2>/dev/null || echo "0")
            
            if [ -z "$count" ] || [ "$count" = "null" ]; then
                count=0
            fi
            
            if [ "$count" -gt 0 ] 2>/dev/null; then
                mv "$file" "$secrets_dir/" 2>/dev/null
                ((files_with_secrets++))
                log_debug "Moved $(basename "$file") with $count secret(s) to ${GROUP}_secrets/"
            else
                rm "$file" 2>/dev/null
                ((files_removed++))
            fi
        done < "$large_files_list"
    fi
    
    if [ -s "$small_files_list" ]; then
        local small_files_count=$(wc -l < "$small_files_list")
        while IFS= read -r file; do
            rm "$file" 2>/dev/null
        done < "$small_files_list"
        files_removed=$((files_removed + small_files_count))
        log_debug "Removed $small_files_count small/empty files"
    fi
    
    rm -f "$large_files_list" "$small_files_list"
    
    set -e
    
    if [ "$files_with_secrets" -gt 0 ]; then
        log_success "📁 Organized $files_with_secrets file(s) with secrets into: ${GROUP}_secrets/"
        log_success "🗑️  Removed $files_removed file(s) with no secrets"
        log_info "Access secrets at: $(realpath "$secrets_dir")"
    else
        log_info "No secrets found, removed $files_removed empty file(s)"
        rmdir "$secrets_dir" 2>/dev/null || true
    fi
    
    ORGANIZED=true
}

send_immediate_notification() {
    local project_name="$1"
    local secrets_file="$2"
    local worker_id="$3"
    
    local immediate_file="$TEMP_DIR/immediate_secret_${project_name//\//_}_$(date +%s).json"
    cp "$secrets_file" "$immediate_file"
    
    log_debug "[$worker_id] Sending immediate notification for $project_name"
    
    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
        export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
    fi
    
    if [ -f "$NOTIFICATION_SCRIPT" ]; then
        if [ -n "$NOTIFICATION_EMAIL" ]; then
            bash "$NOTIFICATION_SCRIPT" "$GROUP" "$immediate_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$GROUP" "$immediate_file" >/dev/null 2>&1 &
        fi
        local notification_pid=$!
        log_debug "[$worker_id] Immediate notification sent (PID: $notification_pid)"
    else
        log_warning "[$worker_id] Notification script not found: $NOTIFICATION_SCRIPT"
    fi
}

send_completion_notification() {
    local total_secrets="$1"
    local projects_with_secrets="$2"
    
    if [ "$total_secrets" -eq 0 ]; then
        log_debug "No secrets found, skipping completion notification"
        return 0
    fi
    
    local completion_file="$OUTPUT_DIR/completion_summary_${GROUP}_$(date +%s).json"
    echo "[" > "$completion_file"
    local is_first_secret=true
    
    for file in "$OUTPUT_DIR"/*.json; do
        if [ ! -f "$file" ] || [[ "$(basename "$file")" == completion_summary_* ]]; then
            continue
        fi
        
        local count=$(jq length "$file" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            while IFS= read -r secret; do
                if [ -n "$secret" ]; then
                    if [ "$is_first_secret" = false ]; then
                        echo "," >> "$completion_file"
                    fi
                    is_first_secret=false
                    echo "$secret" | jq -c ". + {\"group\": \"$GROUP\"}" >> "$completion_file"
                fi
            done < <(jq -c '.[]' "$file" 2>/dev/null)
        fi
    done
    
    echo "]" >> "$completion_file"
    
    log_progress "Sending completion notification for $total_secrets secrets"
    
    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
        export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
    fi
    
    if [ -f "$NOTIFICATION_SCRIPT" ]; then
        if [ -n "$NOTIFICATION_EMAIL" ]; then
            bash "$NOTIFICATION_SCRIPT" "$GROUP" "$completion_file" "$NOTIFICATION_EMAIL" >/dev/null 2>&1 &
        else
            bash "$NOTIFICATION_SCRIPT" "$GROUP" "$completion_file" >/dev/null 2>&1 &
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
            --gitlab-url) GITLAB_INSTANCE="$2"; shift 2 ;;
            --gitlab-token) GITLAB_TOKEN="$2"; shift 2 ;;
            --include-forks) EXCLUDE_FORKS=false; shift ;;
            --include-archived) EXCLUDE_ARCHIVED=false; shift ;;
            --scan-all) EXCLUDE_FORKS=false; EXCLUDE_ARCHIVED=false; shift ;;
            --no-subgroups) INCLUDE_SUBGROUPS=false; shift ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
            --telegram-chat-id) NOTIFICATION_TELEGRAM_CHAT_ID="$2"; shift 2 ;;
            --groups-file) GROUPS_FILE="$2"; shift 2 ;;
            --debug) DEBUG=true; shift ;;
            --no-cleanup) CLEANUP=false; shift ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) 
                if [ -z "${GROUP:-}" ]; then
                    GROUP="$1"
                else
                    log_error "Too many arguments: $1"
                    exit 1
                fi
                shift ;;
        esac
    done
    
    if [ -n "$GROUPS_FILE" ] && [ -n "${GROUP:-}" ]; then
        log_error "Cannot specify both --groups-file and group name"
        exit 1
    fi
    
    if [ -z "$GROUPS_FILE" ] && [ -z "${GROUP:-}" ]; then
        log_error "Group name or --groups-file required"
        show_help
        exit 1
    fi
    
    if [ -n "$GROUPS_FILE" ]; then
        if [ ! -f "$GROUPS_FILE" ]; then
            log_error "Groups file not found: $GROUPS_FILE"
            exit 1
        fi
    fi
    
    if [ -z "$OUTPUT_DIR" ] && [ -z "$GROUPS_FILE" ]; then
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        OUTPUT_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}/group_leaked_secrets/scan_${GROUP}_${TIMESTAMP}"
    fi
}

main() {
    parse_args "$@"
    
    MAX_WORKERS="$AUTO_DETECTED_WORKERS"
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] Auto-detected workers: $MAX_WORKERS (CPU cores: $CPU_CORES, Memory: ${MEMORY_GB}GB, Load: $LOAD_AVERAGE)"
    fi
    
    for tool in git trufflehog jq curl; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not found"
            exit 1
        fi
    done
    
    trap cleanup_on_exit EXIT INT TERM
    
    TEMP_DIR=$(mktemp -d -t gitlab_group_scan.XXXXXX)
    
    if [ -n "$GROUPS_FILE" ]; then
        log_info "Processing groups from file: $GROUPS_FILE"
        
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BATCH_OUTPUT_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}/group_leaked_secrets"
        
        while IFS= read -r group || [ -n "$group" ]; do
            [[ "$group" =~ ^#.*$ ]] && continue
            [[ -z "$group" ]] && continue
            
            group=$(echo "$group" | xargs)
            
            log_info "========================================"
            log_info "Processing group: $group"
            log_info "========================================"
            
            GROUP="$group"
            OUTPUT_DIR="$BATCH_OUTPUT_DIR/scan_${GROUP}_${TIMESTAMP}"
            mkdir -p "$OUTPUT_DIR"
            
            ORGANIZED=false
            
            if [ "$DEBUG" = true ]; then
                mkdir -p "$LOG_DIR"
                LOG_FILE="$LOG_DIR/gitlab_group_scan_${GROUP}_$(date +%Y%m%d_%H%M%S).log"
                log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
                exec > >(tee -a "$LOG_FILE") 2>&1
            fi
            
            log_info "Output directory: $(realpath "$OUTPUT_DIR")"
            
            WORKER_PIDS=()
            
            set +e
            get_group_projects "$GROUP"
            local projects_result=$?
            if [ $projects_result -eq 0 ]; then
                scan_all_projects
                generate_summary
                organize_results
            else
                log_error "Failed to fetch projects for $group, skipping..."
            fi
            set -e
            
            if [ -d "$TEMP_DIR" ]; then
                rm -f "$TEMP_DIR"/*.json "$TEMP_DIR"/*.txt "$TEMP_DIR"/*.lock 2>/dev/null || true
                rm -rf "$TEMP_DIR"/worker_* 2>/dev/null || true
            fi
            
            log_info "Completed scanning group: $group"
            log_info ""
            
        done < "$GROUPS_FILE"
        
        log_info "========================================"
        log_info "All groups processed"
        log_info "Results saved in: $BATCH_OUTPUT_DIR"
        log_info "========================================"
    else
        mkdir -p "$OUTPUT_DIR"
        
        if [ "$DEBUG" = true ]; then
            mkdir -p "$LOG_DIR"
            LOG_FILE="$LOG_DIR/gitlab_group_scan_${GROUP}_$(date +%Y%m%d_%H%M%S).log"
            log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
            exec > >(tee -a "$LOG_FILE") 2>&1
        fi
        
        log_info "Scanning group: $GROUP"
        log_info "Output directory: $(realpath "$OUTPUT_DIR")"
        log_info "Results will be saved in: leaked_secrets_results structure"
        
        get_group_projects "$GROUP"
        scan_all_projects
        generate_summary
        organize_results
    fi
}

main "$@"
