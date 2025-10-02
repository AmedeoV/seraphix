#!/bin/bash
# Available ARGUMENTS:
# 
# Batch Processing Options:
#   --parallel-orgs N      Maximum parallel organizations (1-32, default: auto-detected)
#   --workers-per-org N    Workers per organization (1-64, default: auto-detected)
#   --order ORDER          Organization order: 'random', 'latest', or 'stars' (default: random)
#   --email EMAIL          Email address for security notifications
#   --telegramId CHAT_ID   Telegram chat ID for security notifications
#   --debug                Enable debug/verbose logging for all operations
#
# Resume Options:
#   --resume               Resume from previous scan (uses existing state file)
#   --restart              Start over from beginning (clears previous state)
#   --state-file FILE      Custom state file path (default: scan_state.json)
#
# Scanner Options:
#   --events-file FILE     Path to CSV file containing force-push events
#   --db-file FILE         Path to SQLite database (overrides default)
#   --orgs-file FILE       Path to text file containing organizations to scan (one per line)
#   --debug                Enable debug/verbose logging for all operations
#
# Other Options:
#   --help, -h             Show help messageced batch scanner with parallel organization processing
#
# AVAILABLE ARGUMENTS:
# 
# Batch Processing Options:
#   --parallel-orgs N      Maximum parallel organizations (1-32, default: auto-detected)
#   --workers-per-org N    Workers per organization (1-64, default: auto-detected)
#   --order ORDER          Organization order: 'random' or 'latest' (default: random)
#   --email EMAIL          Email address for security notifications
#   --debug                Enable debug/verbose logging for all operations
#
# Scanner Options:
#   --events-file FILE     Path to CSV file containing force-push events
#   --db-file FILE         Path to SQLite database (overrides default)
#   --debug                Enable debug/verbose logging for all operations
#
# Other Options:
#   --help, -h             Show help message
#
# Arguments:
#   ORGANIZATION           Single organization to scan (optional)
#
# Examples:
#   ./force_push_secret_scanner.sh                                    # Scan all organizations
#   ./force_push_secret_scanner.sh microsoft                         # Scan only Microsoft
#   ./force_push_secret_scanner.sh --parallel-orgs 4 --debug        # 4 parallel with debug
#   ./force_push_secret_scanner.sh --events-file data.csv          # Use CSV data file
#   ./force_push_secret_scanner.sh --orgs-file bugbounty_orgs.txt  # Scan organizations from text file
#   ./force_push_secret_scanner.sh --resume                        # Resume previous scan
#   ./force_push_secret_scanner.sh --restart                       # Start over from beginning
#

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_FILE="force_push_commits.sqlite3"
PYTHON_SCRIPT="force_push_scanner.py"
LOG_DIR="$SCRIPT_DIR/scan_logs"
NOTIFICATION_SCRIPT="send_notifications_enhanced.sh"  # Enhanced notification system
STATE_FILE="scan_state.json"  # Default state file for tracking progress

# Notification configuration
NOTIFICATION_EMAIL=""  # Email address for notifications (empty = disabled)
NOTIFICATION_TELEGRAM_CHAT_ID=""  # Telegram chat ID for notifications (empty = disabled)

# Create timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_BASE_DIR="$SCRIPT_DIR/leaked_secrets_results/${TIMESTAMP}"

# Auto-detect system resources for optimal defaults
CPU_CORES=$(nproc 2>/dev/null || echo "4")
MEMORY_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "8")

# Calculate optimal defaults based on system resources
# Conservative approach: use 50% of cores for parallel orgs, leaving room for workers
AUTO_MAX_PARALLEL_ORGS=$((CPU_CORES / 2))
if [ $AUTO_MAX_PARALLEL_ORGS -lt 1 ]; then
    AUTO_MAX_PARALLEL_ORGS=1
elif [ $AUTO_MAX_PARALLEL_ORGS -gt 8 ]; then
    AUTO_MAX_PARALLEL_ORGS=8  # Cap at 8 to avoid overwhelming
fi

# Workers per org based on remaining cores and memory
# Aim for 2-4 workers per available core, limited by memory
AUTO_WORKERS_PER_ORG=$((CPU_CORES / AUTO_MAX_PARALLEL_ORGS))
if [ $AUTO_WORKERS_PER_ORG -lt 2 ]; then
    AUTO_WORKERS_PER_ORG=2
elif [ $AUTO_WORKERS_PER_ORG -gt 16 ]; then
    AUTO_WORKERS_PER_ORG=16  # Cap to prevent memory issues
fi

# Memory-based adjustment (reduce workers if low memory)
if [ $MEMORY_GB -lt 4 ]; then
    AUTO_WORKERS_PER_ORG=$((AUTO_WORKERS_PER_ORG / 2))
    AUTO_MAX_PARALLEL_ORGS=$((AUTO_MAX_PARALLEL_ORGS / 2))
    if [ $AUTO_WORKERS_PER_ORG -lt 1 ]; then AUTO_WORKERS_PER_ORG=1; fi
    if [ $AUTO_MAX_PARALLEL_ORGS -lt 1 ]; then AUTO_MAX_PARALLEL_ORGS=1; fi
fi

# Configuration with auto-detected defaults
MAX_PARALLEL_ORGS=$AUTO_MAX_PARALLEL_ORGS
WORKERS_PER_ORG=$AUTO_WORKERS_PER_ORG
DEBUG=false
TEST_ORG=""
ORG_ORDER="random"   # Organization processing order: 'random', 'latest', or 'stars'
RESUME_MODE=false    # Whether to resume from previous scan
RESTART_MODE=false   # Whether to start over from beginning
CUSTOM_STATE_FILE="" # Custom state file path
TELEGRAM_ID_PROVIDED=false  # Track if --telegramId was explicitly provided

# Scanner configuration arguments
VERBOSE=false
EVENTS_FILE=""
CUSTOM_DB_FILE=""  # Custom DB file override
ORGS_FILE=""       # Text file containing organizations to scan

echo "System detected: ${CPU_CORES} cores, ${MEMORY_GB}GB RAM"
echo "Auto-configured: ${MAX_PARALLEL_ORGS} parallel orgs, ${WORKERS_PER_ORG} workers per org"

# Trap signals to properly handle interruption
cleanup() {
    echo -e "\n\n${RED}[!] Interrupt signal received. Cleaning up...${NC}"
    
    # Set flag to prevent state updates during cleanup
    export CLEANUP_MODE=true
    
    # Kill all background jobs
    jobs -p | xargs -r kill 2>/dev/null
    
    # Kill any remaining Python processes from this script
    pkill -f "$PYTHON_SCRIPT" 2>/dev/null
    
    # Wait a moment for cleanup
    sleep 2
    
    # Force kill if still running
    pkill -9 -f "$PYTHON_SCRIPT" 2>/dev/null
    
    # Clean up temp files
    rm -f /tmp/orgs_numbered.txt 2>/dev/null
    rm -f /tmp/all_orgs.txt /tmp/scanned_orgs.txt 2>/dev/null
    
    # Clean up temporary repository directories
    echo "${YELLOW}[🧹] Cleaning up temporary repository directories...${NC}"
    python3 "$PYTHON_SCRIPT" --cleanup 2>/dev/null || echo "Note: Could not clean up temporary directories"
    
    echo "${RED}[!] Cleanup completed. State preserved in: $STATE_FILE${NC}"
    echo "${YELLOW}[!] Interrupted organizations will be retried on next run${NC}"
    echo "${YELLOW}[!] Use --resume to continue where you left off${NC}"
    echo "${RED}[!] Exiting...${NC}"
    exit 130  # Standard exit code for Ctrl+C
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load timeout configuration if available
if [ -f "config/timeout_config.sh" ]; then
    echo "Loading timeout configuration from config/timeout_config.sh"
    source config/timeout_config.sh
else
    # Default timeout values
    export TRUFFLEHOG_BASE_TIMEOUT=900
    export TRUFFLEHOG_MAX_TIMEOUT=3600
    export TRUFFLEHOG_MAX_RETRIES=2
    export GIT_OPERATION_TIMEOUT=300
fi

# Set up signal traps
trap cleanup SIGINT SIGTERM

# State management functions
save_state() {
    local state_file="$1"
    local scanned_orgs="$2"
    local total_orgs="$3"
    local results_dir="$4"
    local start_time="$5"
    
    cat > "$state_file" << EOF
{
  "start_time": "$start_time",
  "results_dir": "$results_dir",
  "total_orgs": $total_orgs,
  "scanned_orgs": [
$(echo "$scanned_orgs" | sed 's/.*/"&"/' | paste -sd, -)
  ],
  "configuration": {
    "max_parallel_orgs": $MAX_PARALLEL_ORGS,
    "workers_per_org": $WORKERS_PER_ORG,
    "org_order": "$ORG_ORDER",
    "db_file": "$([ -n "$CUSTOM_DB_FILE" ] && echo "$CUSTOM_DB_FILE" || echo "$DB_FILE")",
    "events_file": "${EVENTS_FILE:-}",
    "debug": $DEBUG
  }
}
EOF
}

load_state() {
    local state_file="$1"
    
    if [ ! -f "$state_file" ]; then
        return 1
    fi
    
    # Use python to parse JSON state file
    python3 -c "
import json
import sys

try:
    with open('$state_file', 'r') as f:
        state = json.load(f)
    
    print('STATE_START_TIME=' + state['start_time'])
    print('STATE_RESULTS_DIR=' + state['results_dir'])
    print('STATE_TOTAL_ORGS=' + str(state['total_orgs']))
    print('STATE_SCANNED_COUNT=' + str(len(state['scanned_orgs'])))
    
    # Export scanned orgs as a simple list
    for org in state['scanned_orgs']:
        print('SCANNED:' + org)
        
except Exception as e:
    print('ERROR:Failed to parse state file: ' + str(e), file=sys.stderr)
    sys.exit(1)
"
}

update_state_with_org() {
    local state_file="$1"
    local org="$2"
    local status="$3"  # completed, failed, secrets_found
    
    # Skip state updates during cleanup to prevent incomplete scans from being marked as complete
    if [ "$CLEANUP_MODE" = true ]; then
        echo "⚠️  Skipping state update for $org due to cleanup mode"
        return
    fi
    
    # Add organization to scanned list using Python
    python3 -c "
import json
import sys
from datetime import datetime

try:
    with open('$state_file', 'r') as f:
        state = json.load(f)
    
    # Add org to scanned list if not already there
    if '$org' not in state['scanned_orgs']:
        state['scanned_orgs'].append('$org')
        state['last_updated'] = datetime.now().isoformat()
        
        with open('$state_file', 'w') as f:
            json.dump(state, f, indent=2)
        
        print('Updated state: added $org as $status')
    else:
        print('Organization $org already in state file')
        
except Exception as e:
    print('ERROR:Failed to update state file: ' + str(e), file=sys.stderr)
    # Don't exit on state file errors during normal operation
"
}

# Help function
show_help() {
    echo "Enhanced batch scanner with parallel organization processing"
    echo ""
    echo "Usage: $0 [OPTIONS] [ORGANIZATION]"
    echo ""
    echo "Batch Processing Options:"
    echo "  --parallel-orgs N      Maximum parallel organizations (default: auto-detected)"
    echo "  --workers-per-org N    Workers per organization (default: auto-detected)"
    echo "  --order ORDER          Organization order: 'random', 'latest', or 'stars' (default: random)"
    echo "  --email EMAIL          Email address for security notifications"
    echo "  --telegramId CHAT_ID   Telegram chat ID for security notifications"
    echo "  --debug                Enable debug/verbose logging for all operations"
    echo ""
    echo "Resume Options:"
    echo "  --resume               Resume from previous scan (uses existing state file)"
    echo "  --restart              Start over from beginning (clears previous state)"
    echo "  --state-file FILE      Custom state file path (default: scan_state.json)"
    echo ""
    echo "Scanner Options:"
    echo "  --events-file FILE     Path to CSV file containing force-push events"
    echo "  --db-file FILE         Path to SQLite database (overrides default)"
    echo "  --orgs-file FILE       Path to text file containing organizations to scan (one per line)"
    echo ""
    echo "Other Options:"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Arguments:"
    echo "  ORGANIZATION           Single organization to scan (optional)"
    echo ""
    echo "Notification Setup:"
    echo "  Use --email EMAIL to enable email notifications via Mailgun"
    echo "  Use --telegramId CHAT_ID to enable Telegram notifications"
    echo "    (If --telegramId is empty/omitted, falls back to config/telegram_config.sh)"
    echo "  Configure config/mailgun_config.sh for email settings"
    echo "  Configure config/telegram_config.sh for Telegram bot token"
    echo "  Both notification methods can be used simultaneously"
    echo ""
    echo "Examples:"
    echo "  $0                                          # Scan all organizations (uses config files)"
    echo "  $0 --email security@company.com             # Scan with email notifications"
    echo "  $0 --telegramId 123456789                   # Scan with specific Telegram chat ID"
    echo "  $0 --telegramId \"\"                          # Disable Telegram (override config)"
    echo "  $0 --email sec@co.com --telegramId 123456   # Scan with both notifications"
    echo "  $0 microsoft                                # Scan only Microsoft organization"
    echo "  $0 --parallel-orgs 4 --debug                # 4 parallel orgs with debug output"
    echo "  $0 --order stars --parallel-orgs 2          # Scan orgs with most stars first"
    echo "  $0 --events-file data.csv                   # Use CSV data file instead of database"
    echo "  $0 --orgs-file bugbounty_orgs.txt          # Scan organizations from text file"
    echo "  $0 --resume                                 # Resume from where previous scan stopped"
    echo "  $0 --restart                                # Start over from beginning (clear state)"
    echo ""
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --debug) DEBUG=true; VERBOSE=true; shift ;;
        --parallel-orgs) MAX_PARALLEL_ORGS="$2"; shift 2 ;;
        --workers-per-org) WORKERS_PER_ORG="$2"; shift 2 ;;
        --order) ORG_ORDER="$2"; shift 2 ;;
        --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
        --telegramId) NOTIFICATION_TELEGRAM_CHAT_ID="$2"; TELEGRAM_ID_PROVIDED=true; shift 2 ;;
        --resume) RESUME_MODE=true; shift ;;
        --restart) RESTART_MODE=true; shift ;;
        --state-file) CUSTOM_STATE_FILE="$2"; shift 2 ;;
        --events-file) EVENTS_FILE="$2"; shift 2 ;;
        --db-file) CUSTOM_DB_FILE="$2"; shift 2 ;;
        --orgs-file) ORGS_FILE="$2"; shift 2 ;;
        *) TEST_ORG="$1"; shift ;;
    esac
done

# Validate arguments
if [ -n "$EVENTS_FILE" ] && [ -n "$CUSTOM_DB_FILE" ]; then
    echo -e "${RED}[!] Error: --events-file and --db-file cannot be used together${NC}"
    echo "Use --events-file for CSV data or --db-file for SQLite database, but not both."
    exit 1
fi

if [ -n "$ORGS_FILE" ] && [ -n "$TEST_ORG" ]; then
    echo -e "${RED}[!] Error: --orgs-file and single organization argument cannot be used together${NC}"
    echo "Use --orgs-file for multiple organizations or specify a single organization, but not both."
    exit 1
fi

if [ "$RESUME_MODE" = true ] && [ "$RESTART_MODE" = true ]; then
    echo -e "${RED}[!] Error: --resume and --restart cannot be used together${NC}"
    echo "Use --resume to continue or --restart to start over, but not both."
    exit 1
fi

# Set state file path
if [ -n "$CUSTOM_STATE_FILE" ]; then
    STATE_FILE="$CUSTOM_STATE_FILE"
fi

if [ -n "$EVENTS_FILE" ] && [ ! -f "$EVENTS_FILE" ]; then
    echo -e "${RED}[!] Error: Events file not found: $EVENTS_FILE${NC}"
    exit 1
fi

if [ -n "$CUSTOM_DB_FILE" ] && [ ! -f "$CUSTOM_DB_FILE" ]; then
    echo -e "${RED}[!] Error: Database file not found: $CUSTOM_DB_FILE${NC}"
    exit 1
fi

if [ -n "$ORGS_FILE" ] && [ ! -f "$ORGS_FILE" ]; then
    echo -e "${RED}[!] Error: Organizations file not found: $ORGS_FILE${NC}"
    exit 1
fi

# Validate numeric arguments
if ! [[ "$MAX_PARALLEL_ORGS" =~ ^[0-9]+$ ]] || [ "$MAX_PARALLEL_ORGS" -lt 1 ] || [ "$MAX_PARALLEL_ORGS" -gt 32 ]; then
    echo -e "${RED}[!] Error: --parallel-orgs must be a number between 1 and 32${NC}"
    exit 1
fi

if ! [[ "$WORKERS_PER_ORG" =~ ^[0-9]+$ ]] || [ "$WORKERS_PER_ORG" -lt 1 ] || [ "$WORKERS_PER_ORG" -gt 64 ]; then
    echo -e "${RED}[!] Error: --workers-per-org must be a number between 1 and 64${NC}"
    exit 1
fi

if [ "$ORG_ORDER" != "random" ] && [ "$ORG_ORDER" != "latest" ] && [ "$ORG_ORDER" != "stars" ]; then
    echo -e "${RED}[!] Error: --order must be 'random', 'latest', or 'stars'${NC}"
    exit 1
fi

echo "Final configuration: ${MAX_PARALLEL_ORGS} parallel orgs, ${WORKERS_PER_ORG} workers per org"
echo "Organization order: $ORG_ORDER"
if [ "$DEBUG" = true ]; then
    echo "Debug mode: enabled (includes verbose logging)"
else
    echo "Debug mode: disabled"
fi
if [ -n "$EVENTS_FILE" ]; then
    echo "Using events file: $EVENTS_FILE"
fi
if [ -n "$CUSTOM_DB_FILE" ]; then
    echo "Using custom DB file: $CUSTOM_DB_FILE"
fi
if [ -n "$ORGS_FILE" ]; then
    echo "Using organizations file: $ORGS_FILE"
fi

# Handle Telegram Chat ID fallback: use config file value if --telegramId was not provided
if [ "$TELEGRAM_ID_PROVIDED" = false ]; then
    # --telegramId was not provided at all, try to load from config file
    if [ -f "config/telegram_config.sh" ]; then
        # Source the config file in a subshell to get the TELEGRAM_CHAT_ID value
        CONFIG_TELEGRAM_CHAT_ID=$(bash -c 'source config/telegram_config.sh 2>/dev/null && echo "$TELEGRAM_CHAT_ID"')
        if [ -n "$CONFIG_TELEGRAM_CHAT_ID" ]; then
            NOTIFICATION_TELEGRAM_CHAT_ID="$CONFIG_TELEGRAM_CHAT_ID"
            echo "📱 Using Telegram Chat ID from config file: $NOTIFICATION_TELEGRAM_CHAT_ID"
        fi
    fi
elif [ -z "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
    # --telegramId was provided but empty - this explicitly disables Telegram
    echo "📱 Telegram notifications explicitly disabled via --telegramId \"\""
fi

# Display notification configuration
echo "Notification configuration:"
if [ -n "$NOTIFICATION_EMAIL" ]; then
    echo "  📧 Email: $NOTIFICATION_EMAIL"
else
    echo "  📧 Email: Disabled (use --email to enable)"
fi

if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
    echo "  📱 Telegram: Chat ID $NOTIFICATION_TELEGRAM_CHAT_ID"
else
    echo "  📱 Telegram: Disabled (use --telegramId to enable)"
fi

if [ -z "$NOTIFICATION_EMAIL" ] && [ -z "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
    echo "  ⚠️  No notifications enabled - secrets will only be saved to files"
    echo "     Use --email EMAIL and/or --telegramId CHAT_ID to enable notifications"
fi

# Create base results directory
mkdir -p "$RESULTS_BASE_DIR"
echo "Results will be saved to: $RESULTS_BASE_DIR"

# Initial cleanup of temporary directories from previous runs
echo -e "${CYAN}[🧹] Initial cleanup of temporary directories...${NC}"
python3 "$PYTHON_SCRIPT" --cleanup 2>/dev/null || echo "Note: Could not clean up temporary directories"

# Handle state management
SCANNED_ORGS=""
SCAN_START_TIME=$(date -Iseconds)

if [ "$RESTART_MODE" = true ]; then
    echo "🔄 Restart mode: Clearing previous state"
    rm -f "$STATE_FILE"
elif [ "$RESUME_MODE" = true ] || [ -f "$STATE_FILE" ]; then
    if [ -f "$STATE_FILE" ]; then
        echo "📋 Loading previous scan state from: $STATE_FILE"
        
        # Load state and parse it
        STATE_OUTPUT=$(load_state "$STATE_FILE")
        if [ $? -eq 0 ]; then
            # Parse state variables (only STATE_ prefixed variables)
            eval "$(echo "$STATE_OUTPUT" | grep -E '^STATE_')"
            
            # Extract scanned organizations
            SCANNED_ORGS=$(echo "$STATE_OUTPUT" | grep '^SCANNED:' | cut -d: -f2-)
            
            echo "📊 Previous scan status:"
            echo "   Start time: $STATE_START_TIME"
            echo "   Results directory: $STATE_RESULTS_DIR"
            echo "   Total organizations: $STATE_TOTAL_ORGS"
            echo "   Previously scanned: $STATE_SCANNED_COUNT organizations"
            echo ""
            
            if [ "$STATE_SCANNED_COUNT" -gt 0 ]; then
                if [ "$RESUME_MODE" = true ]; then
                    echo "✅ Resuming from where previous scan stopped"
                    # Use the previous results directory to maintain continuity
                    RESULTS_BASE_DIR="$STATE_RESULTS_DIR"
                    SCAN_START_TIME="$STATE_START_TIME"  # Keep original start time
                else
                    echo -e "${YELLOW}⚠️  Found previous scan state. Options:${NC}"
                    echo "   - Use --resume to continue from where it stopped"
                    echo "   - Use --restart to start over from beginning"
                    echo "   - Press Ctrl+C to abort and decide later"
                    echo ""
                    while true; do
                        read -p "What would you like to do? [r]esume, [s]tart over, or [a]bort: " -n 1 -r
                        echo
                        case $REPLY in
                            [Rr])
                                echo "✅ Resuming from where previous scan stopped"
                                RESUME_MODE=true
                                # Use the previous results directory to maintain continuity
                                RESULTS_BASE_DIR="$STATE_RESULTS_DIR"
                                SCAN_START_TIME="$STATE_START_TIME"  # Keep original start time
                                break
                                ;;
                            [Ss])
                                echo "🔄 Starting over from beginning"
                                # Clear state for new scan
                                rm -f "$STATE_FILE"
                                SCANNED_ORGS=""
                                break
                                ;;
                            [Aa])
                                echo "Aborted. Use --resume or --restart for explicit behavior."
                                exit 0
                                ;;
                            *)
                                echo "Invalid option. Please enter 'r' for resume, 's' for start over, or 'a' for abort."
                                ;;
                        esac
                    done
                fi
            else
                echo "Previous scan had no completed organizations - starting fresh"
                rm -f "$STATE_FILE"
                SCANNED_ORGS=""
            fi
        else
            echo "❌ Failed to load state file. Starting fresh scan."
            rm -f "$STATE_FILE"
            SCANNED_ORGS=""
        fi
    else
        echo "❌ Resume requested but no state file found: $STATE_FILE"
        echo "Starting fresh scan instead."
    fi
fi

# Create log directory if debug mode is enabled
if [ "$DEBUG" = true ]; then
    mkdir -p "$LOG_DIR"
    echo "Debug mode enabled - logs will be saved to: $LOG_DIR"
fi

# Function to scan a single organization
scan_organization() {
    local org="$1"
    local org_num="$2"
    local total="$3"
    
    echo "[$org_num/$total] Starting scan for organization: $org"
    
    # Set environment variables for immediate notifications in Python
    export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
    export NOTIFICATION_EMAIL="$NOTIFICATION_EMAIL"
    export NOTIFICATION_SCRIPT="$NOTIFICATION_SCRIPT"
    
    # Determine which DB file to use
    local db_file_arg="--db-file"
    local db_file_value
    if [ -n "$CUSTOM_DB_FILE" ]; then
        db_file_value="$CUSTOM_DB_FILE"
    else
        db_file_value="$DB_FILE"
    fi
    
    # Build Python command arguments
    local python_args=()
    python_args+=("$org")
    python_args+=("--scan")
    
    if [ "$VERBOSE" = true ]; then
        python_args+=("--verbose")
    fi
    
    if [ -n "$EVENTS_FILE" ]; then
        python_args+=("--events-file" "$EVENTS_FILE")
    else
        python_args+=("--db-file" "$db_file_value")
    fi
    
    python_args+=("--max-workers" "$WORKERS_PER_ORG")
    python_args+=("--results-dir" "$RESULTS_BASE_DIR")
    
    if [ "$DEBUG" = true ]; then
        LOG_FILE="$LOG_DIR/scan_${org}_$(date +%Y%m%d_%H%M%S).log"
        timeout 3600 python3 "$PYTHON_SCRIPT" "${python_args[@]}" 2>&1 | tee "$LOG_FILE"
    else
        timeout 3600 python3 "$PYTHON_SCRIPT" "${python_args[@]}"
    fi
    
    local exit_code=$?
    
    # Check if timeout occurred
    if [ $exit_code -eq 124 ]; then
        echo "⏰ [$org_num/$total] $org timed out after 1 hour"
        return 1
    fi
    
    # Handle results
    if [ $exit_code -eq 0 ]; then
        # Check for secrets file
        if [ -s "$RESULTS_BASE_DIR/verified_secrets_${org}.json" ]; then
            # 🚨 IMMEDIATE NOTIFICATION - SECRETS FOUND! 🚨
            echo "🚨 [$org_num/$total] SECURITY ALERT: Secrets found in $org!"
            
            # Count secrets immediately for notification
            local secrets_file="$RESULTS_BASE_DIR/verified_secrets_${org}.json"
            local count
            if command -v jq >/dev/null 2>&1; then
                count=$(jq length "$secrets_file" 2>/dev/null || echo "unknown")
            else
                # Multiple fallback methods for counting JSON array elements
                if command -v grep >/dev/null 2>&1; then
                    count=$(grep -c '"DetectorName"' "$secrets_file" 2>/dev/null || echo "unknown")
                elif command -v powershell.exe >/dev/null 2>&1; then
                    count=$(powershell.exe -c "try { (Get-Content '$secrets_file' | ConvertFrom-Json).Count } catch { 'unknown' }" 2>/dev/null || echo "unknown")
                else
                    # Last resort: count opening braces that follow array pattern
                    count=$(awk '/^\s*\{/ {count++} END {print count+0}' "$secrets_file" 2>/dev/null || echo "unknown")
                fi
            fi
            
            echo "🔑 [$org_num/$total] Found $count verified secrets in $org"
            
            # Send completion notifications immediately (before file organization)
            if ([ -n "$NOTIFICATION_EMAIL" ] || [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]); then
                echo "📊 [$org_num/$total] Sending completion summary for $org..."
                
                # Set environment variables for the notification script
                if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
                    export TELEGRAM_CHAT_ID="$NOTIFICATION_TELEGRAM_CHAT_ID"
                fi
                
                # Use enhanced notification script with completion notification
                ENHANCED_NOTIFICATION_SCRIPT="send_notifications_enhanced.sh"
                if [ -f "$ENHANCED_NOTIFICATION_SCRIPT" ]; then
                    # Use enhanced notification script
                    if [ -n "$NOTIFICATION_EMAIL" ]; then
                        bash "$ENHANCED_NOTIFICATION_SCRIPT" "$org" "$secrets_file" "$NOTIFICATION_EMAIL" &
                    else
                        bash "$ENHANCED_NOTIFICATION_SCRIPT" "$org" "$secrets_file" &
                    fi
                    local notification_pid=$!
                    echo "📧 [$org_num/$total] Completion notification sent (PID: $notification_pid)"
                elif [ -f "$NOTIFICATION_SCRIPT" ]; then
                    # Fallback to original notification script
                    if [ -n "$NOTIFICATION_EMAIL" ]; then
                        bash "$NOTIFICATION_SCRIPT" "$org" "$secrets_file" "$NOTIFICATION_EMAIL" &
                    else
                        bash "$NOTIFICATION_SCRIPT" "$org" "$secrets_file" &
                    fi
                    local notification_pid=$!
                    echo "📧 [$org_num/$total] Legacy notification sent (PID: $notification_pid)"
                else
                    # Fallback: basic notification without external script
                    echo "⚠️  [$org_num/$total] Notification script not found, but secrets detected!"
                    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
                        echo "📱 Telegram Chat ID configured: $NOTIFICATION_TELEGRAM_CHAT_ID"
                    fi
                    if [ -n "$NOTIFICATION_EMAIL" ]; then
                        echo "📧 Email configured: $NOTIFICATION_EMAIL"
                    fi
                fi
            else
                echo "⚠️  [$org_num/$total] No notification methods configured (use --email or --telegramId)"
            fi
            
            # Now organize the file
            ORG_DIR="$RESULTS_BASE_DIR/$org"
            mkdir -p "$ORG_DIR"
            mv "$RESULTS_BASE_DIR/verified_secrets_${org}.json" "$ORG_DIR/"
            
            # Only update state file after successful completion
            update_state_with_org "$STATE_FILE" "$org" "secrets_found"
            
            echo "✅ [$org_num/$total] $org completed - secrets found! First alert + final summary sent!"
            return 2  # Success with findings
        else
            rm -f "$RESULTS_BASE_DIR/verified_secrets_${org}.json"
            
            # Only update state file after successful completion
            update_state_with_org "$STATE_FILE" "$org" "completed"
            
            echo "✅ [$org_num/$total] $org completed - no secrets"
            return 0  # Success no findings
        fi
    else
        # Don't update state file for failed/interrupted scans
        # This allows them to be retried on the next run
        echo "❌ [$org_num/$total] $org failed (exit code: $exit_code) - will retry on next run"
        return 1  # Failed
    fi
}

# Export function and variables for parallel execution
export -f scan_organization update_state_with_org
export DB_FILE PYTHON_SCRIPT LOG_DIR DEBUG WORKERS_PER_ORG RESULTS_BASE_DIR
export NOTIFICATION_EMAIL NOTIFICATION_TELEGRAM_CHAT_ID NOTIFICATION_SCRIPT STATE_FILE
export VERBOSE EVENTS_FILE CUSTOM_DB_FILE ORGS_FILE

# Get organizations list
if [ -n "$TEST_ORG" ]; then
    ORGS="$TEST_ORG"
elif [ -n "$ORGS_FILE" ]; then
    # Read organizations from text file
    echo "📋 Reading organizations from: $ORGS_FILE"
    FILE_ORGS=$(cat "$ORGS_FILE" | grep -v '^#' | grep -v '^[[:space:]]*$' | uniq)
    if [ -z "$FILE_ORGS" ]; then
        echo -e "${RED}[!] Error: No organizations found in file: $ORGS_FILE${NC}"
        echo "Make sure the file contains organization names (one per line)"
        exit 1
    fi
    ORG_COUNT=$(echo "$FILE_ORGS" | wc -l)
    echo "📊 Loaded $ORG_COUNT organizations from file"
    
    # Validate organizations against database to ensure they have data
    echo "🔍 Validating organizations against database..."
    
    # Determine which DB file to use for validation
    db_file_for_validation=""
    if [ -n "$CUSTOM_DB_FILE" ]; then
        db_file_for_validation="$CUSTOM_DB_FILE"
    else
        db_file_for_validation="$DB_FILE"
    fi
    
    # Check which organizations from the file actually exist in the database
    # Write organizations to temp file to avoid bash variable substitution issues
    echo "$FILE_ORGS" > /tmp/file_orgs.txt
    
    ALL_ORGS=$(python3 -c "
import sqlite3
import sys

# Read organizations from temp file
with open('/tmp/file_orgs.txt', 'r') as f:
    file_orgs = [line.strip() for line in f if line.strip()]

try:
    db = sqlite3.connect('$db_file_for_validation')
    db.execute('PRAGMA journal_mode=WAL')  # Enable WAL mode for better performance
    db.execute('PRAGMA synchronous=NORMAL')  # Reduce sync for better performance
    cur = db.cursor()
    
    # Use a more efficient query - check each org individually with LIMIT 1
    valid_orgs = []
    invalid_orgs = []
    
    for org in file_orgs:
        cur.execute('SELECT repo_org FROM pushes WHERE repo_org = ? LIMIT 1;', (org,))
        result = cur.fetchone()
        if result:
            valid_orgs.append(org)
        else:
            invalid_orgs.append(org)
    
    # Print valid organizations to stdout
    for org in valid_orgs:
        print(org)
    
    # Report invalid organizations to stderr
    if invalid_orgs:
        print('Warning: The following organizations from file are not found in database:', file=sys.stderr)
        for org in invalid_orgs:
            print('  - ' + org, file=sys.stderr)
        print('', file=sys.stderr)
    
    db.close()
    
except Exception as e:
    print('Error validating organizations against database: ' + str(e), file=sys.stderr)
    # Fallback: use file organizations as-is
    for org in file_orgs:
        print(org)
")
    
    # Clean up temp file
    rm -f /tmp/file_orgs.txt
    
    if [ -z "$ALL_ORGS" ]; then
        echo -e "${RED}[!] Error: None of the organizations in $ORGS_FILE exist in the database${NC}"
        echo "Make sure the organizations have data in the database and the database path is correct."
        exit 1
    fi
    
    VALID_COUNT=$(echo "$ALL_ORGS" | wc -l)
    echo "✅ $VALID_COUNT organizations from file found in database"
    
    # Apply ordering to file organizations based on --order parameter
    if [ "$ORG_ORDER" = "random" ]; then
        echo "🎲 Shuffling organizations randomly..."
        ORGS=$(echo "$ALL_ORGS" | shuf)
    elif [ "$ORG_ORDER" = "latest" ]; then
        echo "⏰ Ordering organizations by latest activity..."
        # Write organizations to temp file for Python processing
        echo "$ALL_ORGS" > /tmp/file_orgs_to_order.txt
        ORGS=$(python3 -c "
import sqlite3
import sys

# Read organizations from temp file
with open('/tmp/file_orgs_to_order.txt', 'r') as f:
    file_orgs = [line.strip() for line in f if line.strip()]

try:
    db = sqlite3.connect('$db_file_for_validation')
    cur = db.cursor()
    
    # Order by latest push timestamp
    ordered_orgs = []
    for org in file_orgs:
        cur.execute('SELECT MAX(push_timestamp) FROM pushes WHERE repo_org = ?;', (org,))
        result = cur.fetchone()
        latest_time = result[0] if result and result[0] else '1970-01-01'
        ordered_orgs.append((latest_time, org))
    
    # Sort by timestamp descending (latest first)
    ordered_orgs.sort(reverse=True)
    
    # Print organizations in order
    for timestamp, org in ordered_orgs:
        print(org)
    
    db.close()
    
except Exception as e:
    print('Error ordering organizations by latest activity: ' + str(e), file=sys.stderr)
    # Fallback: use original order
    for org in file_orgs:
        print(org)
")
        # Clean up temp file
        rm -f /tmp/file_orgs_to_order.txt
    elif [ "$ORG_ORDER" = "stars" ]; then
        echo "⭐ Ordering organizations by star count..."
        # Write organizations to temp file for Python processing
        echo "$ALL_ORGS" > /tmp/file_orgs_to_order.txt
        ORGS=$(python3 -c "
import sqlite3
import sys

# Read organizations from temp file
with open('/tmp/file_orgs_to_order.txt', 'r') as f:
    file_orgs = [line.strip() for line in f if line.strip()]

try:
    db = sqlite3.connect('$db_file_for_validation')
    cur = db.cursor()
    
    # Check if stars column exists
    cur.execute(\"PRAGMA table_info(pushes)\")
    columns = [col[1] for col in cur.fetchall()]
    
    if 'stars' in columns:
        # Order by star count
        ordered_orgs = []
        for org in file_orgs:
            cur.execute('SELECT MAX(CAST(stars AS INTEGER)) FROM pushes WHERE repo_org = ? AND stars IS NOT NULL AND stars != \"\";', (org,))
            result = cur.fetchone()
            star_count = result[0] if result and result[0] is not None else 0
            ordered_orgs.append((star_count, org))
        
        # Sort by star count descending (most stars first)
        ordered_orgs.sort(reverse=True)
        
        # Print organizations in order
        for star_count, org in ordered_orgs:
            print(org)
    else:
        print('Warning: stars column not found in database, falling back to random order', file=sys.stderr)
        # Fallback to shuffled order
        import random
        random.shuffle(file_orgs)
        for org in file_orgs:
            print(org)
    
    db.close()
    
except Exception as e:
    print('Error ordering organizations by stars: ' + str(e), file=sys.stderr)
    # Fallback: use random order
    import random
    random.shuffle(file_orgs)
    for org in file_orgs:
        print(org)
")
        # Clean up temp file
        rm -f /tmp/file_orgs_to_order.txt
    else
        # Default: keep original order from file
        ORGS="$ALL_ORGS"
    fi
else
    if [ "$ORG_ORDER" = "random" ]; then
        ALL_ORGS=$(python3 -c "
import sqlite3
db = sqlite3.connect('$DB_FILE')
cur = db.cursor()
for row in cur.execute('SELECT DISTINCT repo_org FROM pushes ORDER BY RANDOM();'):
    if row[0]: print(row[0])
db.close()
")
    elif [ "$ORG_ORDER" = "stars" ]; then
        ALL_ORGS=$(python3 -c "
import sqlite3
import sys
import os

# Check database file
db_file = '$DB_FILE'
if not os.path.exists(db_file):
    print('Error: Database file not found: ' + db_file, file=sys.stderr)
    sys.exit(1)

# Check file permissions and size
try:
    stat = os.stat(db_file)
    print('Database file size: ' + str(stat.st_size) + ' bytes', file=sys.stderr)
    if stat.st_size == 0:
        print('Error: Database file is empty', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('Error checking database file: ' + str(e), file=sys.stderr)
    sys.exit(1)

try:
    db = sqlite3.connect(db_file)
    db.execute('PRAGMA journal_mode=WAL')  # Enable WAL mode for better concurrent access
    db.execute('PRAGMA synchronous=NORMAL')  # Reduce sync for better performance
    cur = db.cursor()
    
    # Test basic connectivity
    cur.execute('SELECT COUNT(*) FROM pushes')
    count = cur.fetchone()[0]
    print('Total records in pushes table: ' + str(count), file=sys.stderr)
    
except (sqlite3.OperationalError, sqlite3.Error) as e:
    print('Error connecting to database: ' + str(e), file=sys.stderr)
    print('Database may be corrupted, locked, or on a read-only filesystem', file=sys.stderr)
    sys.exit(1)

# Check if stars column exists
try:
    cur.execute('PRAGMA table_info(pushes)')
    columns = [row[1] for row in cur.fetchall()]
    has_stars_column = 'stars' in columns
    if has_stars_column:
        # Double-check by trying to access the column
        cur.execute('SELECT stars FROM pushes LIMIT 1')
        cur.fetchone()
except (sqlite3.OperationalError, sqlite3.Error) as e:
    print('Error checking stars column: ' + str(e), file=sys.stderr)
    has_stars_column = False

if has_stars_column:
    print('Using stars column for ordering organizations by repository stars...', file=sys.stderr)
    
    # Since stars are consistent per repo, we can order by stars directly and get distinct orgs
    # This is much more efficient than GROUP BY with aggregation
    try:
        results = []
        seen_orgs = set()
        
        # Execute query with better error handling
        query = '''
            SELECT DISTINCT repo_org, stars
            FROM pushes 
            WHERE repo_org IS NOT NULL AND repo_org != '' AND stars IS NOT NULL
            ORDER BY stars DESC, repo_org ASC
        '''
        
        for row in cur.execute(query):
            org = row[0]
            stars = row[1]
            if org and org not in seen_orgs:
                results.append(org)
                seen_orgs.add(org)
                # Limit to prevent excessive processing
                if len(results) >= 10000:
                    break
        
        # If we got results, use them
        if results:
            print('Successfully ordered ' + str(len(results)) + ' organizations by repository stars', file=sys.stderr)
            for org in results:
                print(org)
        else:
            raise Exception('No results from stars query - no organizations with star data found')
            
    except (sqlite3.OperationalError, sqlite3.Error) as e:
        # Fallback: If the optimized query fails or returns no results, use simple approach
        print('Stars query failed with database error: ' + str(e), file=sys.stderr)
        print('Falling back to simple alphabetical order...', file=sys.stderr)
        try:
            for row in cur.execute('SELECT DISTINCT repo_org FROM pushes WHERE repo_org IS NOT NULL AND repo_org != \"\" ORDER BY repo_org;'):
                if row[0]: 
                    print(row[0])
        except (sqlite3.OperationalError, sqlite3.Error) as fallback_e:
            print('Fallback query also failed: ' + str(fallback_e), file=sys.stderr)
            print('Database may be corrupted or inaccessible', file=sys.stderr)
else:
    print('Warning: stars column not found in database, falling back to random order', file=sys.stderr)
    try:
        for row in cur.execute('SELECT DISTINCT repo_org FROM pushes WHERE repo_org IS NOT NULL AND repo_org != \"\" ORDER BY RANDOM();'):
            if row[0]: 
                print(row[0])
    except (sqlite3.OperationalError, sqlite3.Error) as e:
        print('Random order query failed: ' + str(e), file=sys.stderr)
        print('Database may be corrupted or inaccessible', file=sys.stderr)

db.close()
")
    else
        ALL_ORGS=$(python3 -c "
import sqlite3
db = sqlite3.connect('$DB_FILE')
cur = db.cursor()
for row in cur.execute('SELECT DISTINCT repo_org FROM pushes ORDER BY timestamp desc;'):
    if row[0]: print(row[0])
db.close()
")
    fi
    
    # Filter out already scanned organizations if resuming
    if [ -n "$SCANNED_ORGS" ]; then
        echo "🔍 Filtering out previously scanned organizations..."
        
        # Create temporary files for filtering
        echo "$ALL_ORGS" > /tmp/all_orgs.txt
        echo "$SCANNED_ORGS" > /tmp/scanned_orgs.txt
        
        # Use grep to filter out scanned organizations
        ORGS=$(grep -vFxf /tmp/scanned_orgs.txt /tmp/all_orgs.txt || echo "")
        
        # Cleanup temp files
        rm -f /tmp/all_orgs.txt /tmp/scanned_orgs.txt
        
        TOTAL_ALL_ORGS=$(echo "$ALL_ORGS" | wc -l)
        TOTAL_REMAINING_ORGS=$(echo "$ORGS" | wc -l)
        TOTAL_SCANNED=$(echo "$SCANNED_ORGS" | wc -l)
        
        echo "📊 Resume statistics:"
        echo "   Total organizations in database: $TOTAL_ALL_ORGS"
        echo "   Previously scanned: $TOTAL_SCANNED"
        echo "   Remaining to scan: $TOTAL_REMAINING_ORGS"
        
        if [ -z "$ORGS" ] || [ "$TOTAL_REMAINING_ORGS" -eq 0 ]; then
            echo "✅ All organizations have been scanned!"
            echo "Use --restart to scan all organizations again."
            exit 0
        fi
    else
        ORGS="$ALL_ORGS"
    fi
fi

TOTAL_ORGS=$(echo "$ORGS" | wc -l)

# Initialize state file for new scans
if [ ! -f "$STATE_FILE" ] && [ "$TOTAL_ORGS" -gt 0 ]; then
    echo "📝 Initializing scan state file: $STATE_FILE"
    save_state "$STATE_FILE" "" "$TOTAL_ORGS" "$RESULTS_BASE_DIR" "$SCAN_START_TIME"
fi
echo "Processing $TOTAL_ORGS organizations with max $MAX_PARALLEL_ORGS parallel jobs"
echo "Using $WORKERS_PER_ORG workers per organization"
echo "Results directory: $RESULTS_BASE_DIR"

# Debug: Show first few organizations in processing order
if [ "$DEBUG" = true ]; then
    echo "🐛 DEBUG: Organization processing order:"
    echo "$ORGS" | head -10 | while read -r org; do
        echo "   - $org"
    done
    if [ "$TOTAL_ORGS" -gt 10 ]; then
        echo "   ... and $((TOTAL_ORGS - 10)) more organizations"
    fi
fi

echo -e "${YELLOW}Press Ctrl+C to interrupt and cleanup gracefully${NC}"

# Create numbered org list for parallel processing
echo "$ORGS" | nl -w1 -s: > /tmp/orgs_numbered.txt

# Use GNU parallel or xargs for parallel execution
if command -v parallel >/dev/null 2>&1; then
    echo "Using GNU parallel for organization processing"
    parallel -j "$MAX_PARALLEL_ORGS" --colsep ':' --halt soon,fail=1 \
        scan_organization {2} {1} "$TOTAL_ORGS" :::: /tmp/orgs_numbered.txt
else
    echo "Using xargs for parallel processing (install GNU parallel for better control)"
    cat /tmp/orgs_numbered.txt | xargs -n 1 -P "$MAX_PARALLEL_ORGS" -I {} bash -c '
        IFS=: read num org <<< "{}"
        scan_organization "$org" "$num" "'"$TOTAL_ORGS"'"
    '
fi

# Check if we were interrupted
if [ $? -ne 0 ]; then
    echo -e "\n${RED}[!] Processing was interrupted or failed${NC}"
fi

# Wait for any remaining notification processes to complete
echo "Waiting for notification emails to complete..."
wait

# Cleanup
rm -f /tmp/orgs_numbered.txt

echo "Batch scan completed!"
echo "Results saved to: $RESULTS_BASE_DIR"
if [ "$DEBUG" = true ]; then
    echo "Debug logs saved to: $LOG_DIR"
fi

# Summary of organizations with secrets found
echo ""
echo "=== SCAN SUMMARY ==="
ORGS_WITH_SECRETS=$(find "$RESULTS_BASE_DIR" -name "verified_secrets_*.json" -type f | wc -l)
if [ $ORGS_WITH_SECRETS -gt 0 ]; then
    echo -e "${RED}🚨 SECURITY ALERT: $ORGS_WITH_SECRETS organizations have leaked secrets!${NC}"
    echo "Organizations with secrets:"
    find "$RESULTS_BASE_DIR" -name "verified_secrets_*.json" -type f -exec basename {} \; | sed 's/verified_secrets_\(.*\)\.json/  - \1/' | sort
    
    # Check which notification methods were used
    local notifications_sent=""
    if [ -n "$NOTIFICATION_EMAIL" ]; then
        notifications_sent="📧 Email ($NOTIFICATION_EMAIL)"
    fi
    
    if [ -n "$NOTIFICATION_TELEGRAM_CHAT_ID" ]; then
        if [ -n "$notifications_sent" ]; then
            notifications_sent="$notifications_sent, 📱 Telegram (Chat: $NOTIFICATION_TELEGRAM_CHAT_ID)"
        else
            notifications_sent="📱 Telegram (Chat: $NOTIFICATION_TELEGRAM_CHAT_ID)"
        fi
    fi
    
    if [ -n "$notifications_sent" ]; then
        echo -e "${GREEN}📤 Immediate notifications were sent via: $notifications_sent${NC}"
        echo "    (Notifications sent as soon as secrets were discovered)"
    else
        echo -e "${YELLOW}⚠️  No notifications sent - use --email and/or --telegramId to enable alerts${NC}"
    fi
else
    echo -e "${GREEN}✅ No secrets found in any organization${NC}"
fi

# Show scan progress
if [ -f "$STATE_FILE" ]; then
    STATE_INFO=$(load_state "$STATE_FILE" 2>/dev/null)
    if [ $? -eq 0 ]; then
        CURRENT_SCANNED=$(echo "$STATE_INFO" | grep '^STATE_SCANNED_COUNT=' | cut -d= -f2)
        STATE_TOTAL=$(echo "$STATE_INFO" | grep '^STATE_TOTAL_ORGS=' | cut -d= -f2)
        
        if [ -n "$CURRENT_SCANNED" ] && [ -n "$STATE_TOTAL" ]; then
            PROGRESS_PERCENT=$((CURRENT_SCANNED * 100 / STATE_TOTAL))
            echo ""
            echo "📊 Scan Progress: $CURRENT_SCANNED/$STATE_TOTAL organizations ($PROGRESS_PERCENT%)"
            
            if [ $CURRENT_SCANNED -lt $STATE_TOTAL ]; then
                REMAINING=$((STATE_TOTAL - CURRENT_SCANNED))
                echo "   $REMAINING organizations remaining"
                echo -e "${YELLOW}💡 Use './force_push_secret_scanner.sh --resume' to continue${NC}"
            else
                echo "🎉 All organizations completed!"
                echo -e "${GREEN}💡 Use './force_push_secret_scanner.sh --restart' to scan again${NC}"
            fi
        fi
    fi
fi

echo "State file: $STATE_FILE"
echo "===================="