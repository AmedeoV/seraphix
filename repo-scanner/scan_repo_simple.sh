#!/bin/bash
#
# Simple Repository Scanner (Bash)
# A simplified version with better error handling and compatibility
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

# Default configuration
CLEANUP=true
TIMEOUT=1200
OUTPUT_FILE=""
TEMP_DIR=""
COMMIT_HASH=""
DEBUG=false
LOG_DIR="$SCRIPT_DIR/scan_logs"  # Local debug logs directory

# Notification configuration
NOTIFICATION_EMAIL=""  # Email address for notifications (empty = disabled)
NOTIFICATION_TELEGRAM_CHAT_ID=""  # Telegram chat ID for notifications (empty = disabled)
NOTIFICATION_SCRIPT="$SCRIPT_DIR/../send_notifications_enhanced.sh"  # Enhanced notification system

# Load timeout configuration if available
if [ -f "$SCRIPT_DIR/../config/timeout_config.sh" ]; then
    source "$SCRIPT_DIR/../config/timeout_config.sh"
    TIMEOUT=${TRUFFLEHOG_BASE_TIMEOUT:-1200}
elif [ -f "$SCRIPT_DIR/config/timeout_config.sh" ]; then
    source "$SCRIPT_DIR/config/timeout_config.sh"
    TIMEOUT=${TRUFFLEHOG_BASE_TIMEOUT:-1200}
else
    # Default timeout values
    export TRUFFLEHOG_BASE_TIMEOUT=1200
    export TRUFFLEHOG_MAX_TIMEOUT=3600
    export TRUFFLEHOG_MAX_RETRIES=2
    export GIT_OPERATION_TIMEOUT=300
fi

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

log_debug() {
    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}🐛 DEBUG: $1${NC}"
    fi
}

# Notification functions
send_immediate_notification() {
    local repo_name="$1"
    local output_file="$2"
    
    if [ ! -f "$NOTIFICATION_SCRIPT" ]; then
        log_debug "Notification script not found: $NOTIFICATION_SCRIPT"
        return 1
    fi
    
    local findings_count=$(jq length "$output_file" 2>/dev/null || echo "0")
    
    if [ "$findings_count" -gt 0 ]; then
        log_debug "Sending immediate notification for $findings_count secret(s) in $repo_name"
        
        # Set environment variable for telegram if provided
        if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
            export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
        fi
        
        # Call notification script with positional arguments
        # Arguments: <organization> <secrets_file> [email]
        "$NOTIFICATION_SCRIPT" "$repo_name" "$output_file" "$NOTIFICATION_EMAIL"
    fi
}

# Adaptive timeout calculation based on repository characteristics
calculate_adaptive_timeout() {
    local repo_path="$1"
    local base_timeout=${TRUFFLEHOG_BASE_TIMEOUT:-1200}
    
    # Start with base timeout
    local calculated_timeout=$base_timeout
    
    # Calculate repository size in MB
    local repo_size_mb=0
    if [ -d "$repo_path" ]; then
        local size_bytes=$(du -sb "$repo_path" 2>/dev/null | cut -f1 || echo "0")
        repo_size_mb=$(echo "scale=2; $size_bytes / 1048576" | bc -l 2>/dev/null || echo "0")
    fi
    
    # Count files for complexity estimation
    local file_count=0
    if [ -d "$repo_path" ]; then
        file_count=$(find "$repo_path" -type f 2>/dev/null | wc -l)
    fi
    
    # Factor 1: Repository size
    if (( $(echo "$repo_size_mb > ${LARGE_REPO_THRESHOLD:-500}" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * ${COMMIT_TIMEOUT_MULTIPLIER:-2.0}" | bc -l 2>/dev/null || echo "$((calculated_timeout * 2))")
        log_debug "Large repo detected (${repo_size_mb}MB), increasing timeout" >&2
    elif (( $(echo "$repo_size_mb > ${MEDIUM_REPO_THRESHOLD:-100}" | bc -l 2>/dev/null || echo "0") )); then
        calculated_timeout=$(echo "$calculated_timeout * ${SIZE_TIMEOUT_MULTIPLIER:-1.5}" | bc -l 2>/dev/null || echo "$((calculated_timeout * 3 / 2))")
        log_debug "Medium repo detected (${repo_size_mb}MB), moderately increasing timeout" >&2
    fi
    
    # Factor 2: File count (approximation of complexity)
    if [ "$file_count" -gt 1000 ]; then
        calculated_timeout=$(echo "$calculated_timeout * 1.3" | bc -l 2>/dev/null || echo "$((calculated_timeout * 13 / 10))")
        log_debug "Many files detected ($file_count), increasing timeout" >&2
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
Simple Repository Scanner

Usage:
    $0 <repo_name> [options]

Arguments:
    repo_name     GitHub repository in format "owner/repo"

Options:
    --commit HASH        Scan only a specific commit hash
    --output FILE        Save results to specified JSON file
    --no-cleanup         Don't clean up temporary files
    --timeout SEC        Timeout in seconds (default: 1200)
    --debug              Enable debug output
    --email EMAIL        Email address for security notifications
    --telegram-chat-id ID Telegram chat ID for security notifications
    --help               Show this help message

Examples:
    $0 microsoft/AzureDevOpsDemoGenerator
    $0 microsoft/AzureDevOpsDemoGenerator --commit 71ec71f3f2c63c3c88ad6fb4c776f811587aaa01
    $0 magicbell-io/darkmagic --debug
    $0 myorg/repo --email security@company.com --telegram-chat-id 123456789

Notifications:
    Use --email and/or --telegram-chat-id to receive security notifications when
    secrets are found. Requires proper configuration of notification scripts.

EOF
}

cleanup_on_exit() {
    if [ "$CLEANUP" = true ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_progress "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}

handle_interrupt() {
    log_warning "Scan interrupted by user (Ctrl+C)"
    cleanup_on_exit
    exit 130
}

validate_repo_name() {
    local repo_name="$1"
    if [[ ! "$repo_name" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid repository name: $repo_name"
        return 1
    fi
    return 0
}

clone_repository() {
    local repo_name="$1"
    local repo_path="$2"
    local repo_url="https://github.com/$repo_name"
    
    log_progress "Cloning repository: $repo_url"
    
    if ! git clone "$repo_url" "$repo_path" 2>"$TEMP_DIR/clone_error.log"; then
        log_error "Failed to clone repository: $repo_url"
        if [ -f "$TEMP_DIR/clone_error.log" ]; then
            echo "Error details:"
            cat "$TEMP_DIR/clone_error.log"
        fi
        return 1
    fi
    
    log_success "Repository cloned successfully"
}

checkout_commit() {
    local repo_path="$1"
    local commit_hash="$2"
    
    log_progress "Checking out commit: $commit_hash"
    
    cd "$repo_path"
    
    if git checkout "$commit_hash" 2>"$TEMP_DIR/checkout_error.log"; then
        log_success "Commit checked out successfully"
        cd - > /dev/null
        return 0
    fi
    
    log_error "Failed to checkout commit: $commit_hash"
    if [ -f "$TEMP_DIR/checkout_error.log" ]; then
        echo "Error details:"
        cat "$TEMP_DIR/checkout_error.log"
    fi
    
    cd - > /dev/null
    return 1
}

scan_with_trufflehog() {
    local repo_path="$1"
    local repo_name="$2"
    local output_file="$3"
    
    log_progress "Scanning with TruffleHog..."
    
    # Calculate adaptive timeout based on repository characteristics
    local adaptive_timeout=$(calculate_adaptive_timeout "$repo_path")
    log_debug "Using adaptive timeout: ${adaptive_timeout}s for $repo_name"
    
    cd "$repo_path"
    
    # Try different TruffleHog command variations in order of preference
    local commands=(
        "trufflehog git --json --only-verified --no-update file://$(pwd)"
        "trufflehog git --json --no-update file://$(pwd)"
        "trufflehog git --no-update file://$(pwd)"
    )
    
    local temp_results="$TEMP_DIR/trufflehog_raw.json"
    local temp_errors="$TEMP_DIR/trufflehog_errors.log"
    local success=false
    local max_retries=${TRUFFLEHOG_MAX_RETRIES:-2}
    
    # Try each command with retry logic
    for cmd in "${commands[@]}"; do
        log_debug "Trying command: $cmd"
        
        # Retry logic for each command
        for attempt in $(seq 1 $((max_retries + 1))); do
            local current_timeout=$adaptive_timeout
            if [ $attempt -gt 1 ]; then
                # Increase timeout for retry attempts
                current_timeout=$((adaptive_timeout * attempt))
                log_debug "Retry attempt $attempt/$((max_retries + 1)) with timeout: ${current_timeout}s"
            fi
            
            if timeout "$current_timeout" bash -c "$cmd" > "$temp_results" 2>"$temp_errors"; then
                log_success "TruffleHog scan completed with: $cmd (attempt $attempt)"
                success=true
                break 2  # Break out of both loops
            else
                local exit_code=$?
                log_debug "Command failed with exit code: $exit_code (attempt $attempt)"
                if [ $exit_code -eq 124 ]; then
                    log_warning "Command timed out ($current_timeout s): $cmd (attempt $attempt)"
                else
                    log_debug "Command failed: $cmd (attempt $attempt)"
                    if [ -f "$temp_errors" ]; then
                        log_debug "Error output: $(head -3 "$temp_errors" | tr '\n' ' ')"
                    fi
                    # For non-timeout errors, try the next command rather than retrying
                    break
                fi
            fi
        done
        
        # If we had success, break out of command loop
        if [ "$success" = true ]; then
            break
        fi
    done
    
    cd - > /dev/null
    
    if [ "$success" = false ]; then
        log_error "All TruffleHog commands failed"
        if [ -f "$temp_errors" ]; then
            echo "Last error output:"
            cat "$temp_errors" | tail -10
        fi
        return 1
    fi
    
    # Process results
    process_results "$temp_results" "$repo_name" "$output_file"
}

process_results() {
    local raw_file="$1"
    local repo_name="$2"
    local output_file="$3"
    
    log_progress "Processing scan results..."
    
    if [ ! -s "$raw_file" ]; then
        log_info "No results found"
        echo "[]" > "$output_file"
        return 0
    fi
    
    # Process results - handle both JSON and text output
    local findings=0
    echo "[" > "$output_file"
    local first_entry=true
    
    # Check if file contains JSON lines
    if head -1 "$raw_file" | jq . >/dev/null 2>&1; then
        # Process JSON output
        while IFS= read -r line; do
            if [ -n "$line" ] && echo "$line" | jq . >/dev/null 2>&1; then
                # Check if verified (if field exists)
                local is_verified=true
                if echo "$line" | jq -e '.Verified' >/dev/null 2>&1; then
                    if ! echo "$line" | jq -e '.Verified == true' >/dev/null 2>&1; then
                        is_verified=false
                    fi
                fi
                
                if [ "$is_verified" = true ]; then
                    if [ "$first_entry" = false ]; then
                        echo "," >> "$output_file"
                    fi
                    first_entry=false
                    
                    # Add metadata
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
                    local metadata="{\"scan_timestamp\": \"$timestamp\", \"repository_name\": \"$repo_name\"}"
                    
                    echo "$line" | jq ". + $metadata" >> "$output_file"
                    ((findings++))
                fi
            fi
        done < "$raw_file"
    else
        # Handle text output (convert to basic JSON)
        log_warning "TruffleHog produced text output instead of JSON"
        if grep -q "Found.*secret" "$raw_file" 2>/dev/null; then
            log_info "Text output detected potential secrets, but JSON processing not possible"
            echo "Raw output saved for manual review:"
            cp "$raw_file" "${output_file%.json}_raw.txt"
        fi
    fi
    
    echo "]" >> "$output_file"
    
    log_success "Found $findings verified secret(s)"
    
    # Send notification if secrets were found and notifications are enabled
    if [ "$findings" -gt 0 ] && ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]); then
        send_immediate_notification "$repo_name" "$output_file"
    fi
}

print_summary() {
    local output_file="$1"
    local repo_name="$2"
    
    if [ ! -f "$output_file" ]; then
        log_error "Output file not found: $output_file"
        return 1
    fi
    
    local findings_count
    findings_count=$(jq length "$output_file" 2>/dev/null || echo "0")
    
    echo ""
    echo "============================================================"
    echo "📊 SCAN SUMMARY"
    echo "============================================================"
    echo "Repository: $repo_name"
    echo "Verified secrets found: $findings_count"
    echo ""
    
    if [ "$findings_count" -gt 0 ]; then
        echo "🔑 DETECTED SECRETS:"
        jq -r '.[] | "  • \(.DetectorName // "Unknown"): \(.Raw // .RawV2 // "N/A" | .[0:20])..."' "$output_file" 2>/dev/null || echo "Could not parse findings"
        echo ""
        log_success "SUCCESS: Found $findings_count verified secret(s)"
    else
        log_info "No verified secrets found"
    fi
    
    echo "============================================================"
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
            --commit)
                COMMIT_HASH="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --email)
                NOTIFICATION_EMAIL="$2"
                shift 2
                ;;
            --telegram-chat-id)
                NOTIFICATION_TELEGRAM_CHAT_ID="$2"
                shift 2
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
    
    if ! validate_repo_name "$REPO_NAME"; then
        exit 1
    fi
    
    if [ -z "$OUTPUT_FILE" ]; then
        local clean_name=$(echo "$REPO_NAME" | tr '/' '_')
        local timestamp=$(date +%Y%m%d_%H%M%S)
        
        # Create timestamped results directory inside repo-scanner folder
        local results_dir="$SCRIPT_DIR/leaked_secrets_results/${timestamp}"
        mkdir -p "$results_dir"
        
        OUTPUT_FILE="${results_dir}/simple_scan_${clean_name}_${timestamp}.json"
    fi
}

main() {
    parse_arguments "$@"
    
    # Check dependencies
    if ! command -v trufflehog &> /dev/null; then
        log_error "TruffleHog not found. Install with:"
        echo "curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Install with: sudo apt-get install jq"
        exit 1
    fi
    
    trap cleanup_on_exit EXIT
    trap handle_interrupt SIGINT SIGTERM
    
    # Create debug log directory and file if debug mode is enabled
    if [ "$DEBUG" = true ]; then
        mkdir -p "$LOG_DIR"
        local clean_name=$(echo "$REPO_NAME" | tr '/' '_')
        LOG_FILE="$LOG_DIR/simple_scan_${clean_name}_$(date +%Y%m%d_%H%M%S).log"
        log_debug "Debug mode enabled - logs will be saved to: $LOG_FILE"
        # Start logging to file (in addition to console)
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
    
    TEMP_DIR=$(mktemp -d -t simple_scan.XXXXXX)
    log_debug "Working directory: $TEMP_DIR"
    
    local repo_path="$TEMP_DIR/repo"
    
    if ! clone_repository "$REPO_NAME" "$repo_path"; then
        exit 1
    fi
    
    if [ -n "$COMMIT_HASH" ]; then
        if ! checkout_commit "$repo_path" "$COMMIT_HASH"; then
            exit 1
        fi
    fi
    
    if ! scan_with_trufflehog "$repo_path" "$REPO_NAME" "$OUTPUT_FILE"; then
        exit 1
    fi
    
    print_summary "$OUTPUT_FILE" "$REPO_NAME"
    
    log_success "Results saved to: $(realpath "$OUTPUT_FILE")"
    
    if [ "$CLEANUP" = false ]; then
        log_info "Temporary files preserved at: $TEMP_DIR"
    fi
}

main "$@"