#!/bin/bash
# Enhanced batch scanner with parallel organization processing

DB_FILE="force_push_commits.sqlite3"
PYTHON_SCRIPT="force_push_scanner.py"
LOG_DIR="scan_logs"
NOTIFICATION_SCRIPT="send_notifications.sh"  # Add this line

# Notification configuration
NOTIFICATION_EMAIL=""  # Set your email here to enable notifications

# Create timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_BASE_DIR="leaked_secrets_results/${TIMESTAMP}"

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
ORG_ORDER="random"   # Organization processing order: 'random' or 'latest'

echo "System detected: ${CPU_CORES} cores, ${MEMORY_GB}GB RAM"
echo "Auto-configured: ${MAX_PARALLEL_ORGS} parallel orgs, ${WORKERS_PER_ORG} workers per org"

# Trap signals to properly handle interruption
cleanup() {
    echo -e "\n\n${RED}[!] Interrupt signal received. Cleaning up...${NC}"
    
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
    
    echo "${RED}[!] Cleanup completed. Exiting...${NC}"
    exit 130  # Standard exit code for Ctrl+C
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set up signal traps
trap cleanup SIGINT SIGTERM

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug) DEBUG=true; shift ;;
        --parallel-orgs) MAX_PARALLEL_ORGS="$2"; shift 2 ;;
        --workers-per-org) WORKERS_PER_ORG="$2"; shift 2 ;;
        --order) ORG_ORDER="$2"; shift 2 ;;
        --email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
        *) TEST_ORG="$1"; shift ;;
    esac
done

echo "Final configuration: ${MAX_PARALLEL_ORGS} parallel orgs, ${WORKERS_PER_ORG} workers per org"
echo "Organization order: $ORG_ORDER"
if [ -n "$NOTIFICATION_EMAIL" ]; then
    echo "Notifications enabled - Email: $NOTIFICATION_EMAIL"
else
    echo "Notifications disabled"
fi

# Create base results directory
mkdir -p "$RESULTS_BASE_DIR"
echo "Results will be saved to: $RESULTS_BASE_DIR"

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
    
    if [ "$DEBUG" = true ]; then
        LOG_FILE="$LOG_DIR/scan_${org}_$(date +%Y%m%d_%H%M%S).log"
        timeout 3600 python3 "$PYTHON_SCRIPT" --db-file "$DB_FILE" --scan \
                --max-workers "$WORKERS_PER_ORG" --results-dir "$RESULTS_BASE_DIR" "$org" 2>&1 | tee "$LOG_FILE"
    else
        timeout 3600 python3 "$PYTHON_SCRIPT" --db-file "$DB_FILE" --scan \
                --max-workers "$WORKERS_PER_ORG" --results-dir "$RESULTS_BASE_DIR" "$org"
    fi
    
    local exit_code=$?
    
    # Check if timeout occurred
    if [ $exit_code -eq 124 ]; then
        echo "⏰ [$org_num/$total] $org timed out after 1 hour"
        return 1
    fi
    
    # Handle results
    if [ $exit_code -eq 0 ]; then
        if [ -s "$RESULTS_BASE_DIR/verified_secrets_${org}.json" ]; then
            ORG_DIR="$RESULTS_BASE_DIR/$org"
            mkdir -p "$ORG_DIR"
            mv "$RESULTS_BASE_DIR/verified_secrets_${org}.json" "$ORG_DIR/"
            
            # 🚨 SEND NOTIFICATIONS HERE 🚨
            if [ -n "$NOTIFICATION_EMAIL" ] && [ -f "$NOTIFICATION_SCRIPT" ]; then
                local secrets_file="$ORG_DIR/verified_secrets_${org}.json"
                local count
                if command -v jq >/dev/null 2>&1; then
                    count=$(jq length "$secrets_file" 2>/dev/null || echo "unknown")
                else
                    count=$(grep -c "secret_type" "$secrets_file" 2>/dev/null || echo "unknown")
                fi
                
                echo "🚨 [$org_num/$total] Sending security alert for $org ($count secrets found)"
                
                # Call notification script in background so it doesn't slow down scanning
                bash "$NOTIFICATION_SCRIPT" "$org" "$secrets_file" "$NOTIFICATION_EMAIL" &
                
                # Store the PID for cleanup if needed
                local notification_pid=$!
                echo "📧 [$org_num/$total] Notification sent (PID: $notification_pid)"
            fi
            
            echo "✅ [$org_num/$total] $org completed - secrets found!"
            return 2  # Success with findings
        else
            rm -f "$RESULTS_BASE_DIR/verified_secrets_${org}.json"
            echo "✅ [$org_num/$total] $org completed - no secrets"
            return 0  # Success no findings
        fi
    else
        echo "❌ [$org_num/$total] $org failed"
        return 1  # Failed
    fi
}

# Export function and variables for parallel execution
export -f scan_organization
export DB_FILE PYTHON_SCRIPT LOG_DIR DEBUG WORKERS_PER_ORG RESULTS_BASE_DIR
export NOTIFICATION_EMAIL NOTIFICATION_SCRIPT

# Get organizations list
if [ -n "$TEST_ORG" ]; then
    ORGS="$TEST_ORG"
else
    if [ "$ORG_ORDER" = "random" ]; then
        ORGS=$(python3 -c "
import sqlite3
db = sqlite3.connect('$DB_FILE')
cur = db.cursor()
for row in cur.execute('SELECT DISTINCT repo_org FROM pushes ORDER BY RANDOM();'):
    if row[0]: print(row[0])
db.close()
")
    else
        ORGS=$(python3 -c "
import sqlite3
db = sqlite3.connect('$DB_FILE')
cur = db.cursor()
for row in cur.execute('SELECT DISTINCT repo_org FROM pushes ORDER BY timestamp desc;'):
    if row[0]: print(row[0])
db.close()
")
    fi
fi

TOTAL_ORGS=$(echo "$ORGS" | wc -l)
echo "Processing $TOTAL_ORGS organizations with max $MAX_PARALLEL_ORGS parallel jobs"
echo "Using $WORKERS_PER_ORG workers per organization"
echo "Results directory: $RESULTS_BASE_DIR"
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
    if [ -n "$NOTIFICATION_EMAIL" ]; then
        echo -e "${GREEN}📧 Security notifications sent to: $NOTIFICATION_EMAIL${NC}"
    fi
else
    echo -e "${GREEN}✅ No secrets found in any organization${NC}"
fi
echo "===================="