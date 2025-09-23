#!/bin/bash
# Enhanced batch scanner with parallel organization processing

DB_FILE="force_push_commits.sqlite3"
PYTHON_SCRIPT="force_push_scanner.py"
LOG_DIR="scan_logs"
RESULTS_BASE_DIR="leaked_secrets_results"

# Configuration
MAX_PARALLEL_ORGS=4  # Number of organizations to scan simultaneously
WORKERS_PER_ORG=8    # Workers per organization (reduced to balance resources)
DEBUG=false
TEST_ORG=""

# Parse arguments (same as before)
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug) DEBUG=true; shift ;;
        --parallel-orgs) MAX_PARALLEL_ORGS="$2"; shift 2 ;;
        --workers-per-org) WORKERS_PER_ORG="$2"; shift 2 ;;
        *) TEST_ORG="$1"; shift ;;
    esac
done

# Create base results directory
mkdir -p "$RESULTS_BASE_DIR"

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
        python3 "$PYTHON_SCRIPT" --db-file "$DB_FILE" --scan \
                --max-workers "$WORKERS_PER_ORG" --results-dir "$RESULTS_BASE_DIR" "$org" 2>&1 | tee "$LOG_FILE"
    else
        python3 "$PYTHON_SCRIPT" --db-file "$DB_FILE" --scan \
                --max-workers "$WORKERS_PER_ORG" --results-dir "$RESULTS_BASE_DIR" "$org"
    fi
    
    local exit_code=$?
    
    # Handle results
    if [ $exit_code -eq 0 ]; then
        if [ -s "$RESULTS_BASE_DIR/verified_secrets_${org}.json" ]; then
            ORG_DIR="$RESULTS_BASE_DIR/$org"
            mkdir -p "$ORG_DIR"
            mv "$RESULTS_BASE_DIR/verified_secrets_${org}.json" "$ORG_DIR/"
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

# Export function for parallel execution
export -f scan_organization
export DB_FILE PYTHON_SCRIPT LOG_DIR DEBUG WORKERS_PER_ORG RESULTS_BASE_DIR

# Get organizations list (same as before)
if [ -n "$TEST_ORG" ]; then
    ORGS="$TEST_ORG"
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

TOTAL_ORGS=$(echo "$ORGS" | wc -l)
echo "Processing $TOTAL_ORGS organizations with max $MAX_PARALLEL_ORGS parallel jobs"
echo "Using $WORKERS_PER_ORG workers per organization"

# Create numbered org list for parallel processing
echo "$ORGS" | nl -w1 -s: > /tmp/orgs_numbered.txt

# Use GNU parallel or xargs for parallel execution
if command -v parallel >/dev/null 2>&1; then
    echo "Using GNU parallel for organization processing"
    parallel -j "$MAX_PARALLEL_ORGS" --colsep ':' \
        scan_organization {2} {1} "$TOTAL_ORGS" :::: /tmp/orgs_numbered.txt
else
    echo "Using xargs for parallel processing (install GNU parallel for better control)"
    cat /tmp/orgs_numbered.txt | xargs -n 1 -P "$MAX_PARALLEL_ORGS" -I {} bash -c '
        IFS=: read num org <<< "{}"
        scan_organization "$org" "$num" "'"$TOTAL_ORGS"'"
    '
fi

# Cleanup
rm -f /tmp/orgs_numbered.txt

echo "Batch scan completed!"
echo "Results saved to: $RESULTS_BASE_DIR"
if [ "$DEBUG" = true ]; then
    echo "Debug logs saved to: $LOG_DIR"
fi