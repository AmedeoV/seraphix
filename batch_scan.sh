#!/bin/bash

# Batch scanner script to run force_push_scanner.py for all organizations in the database

DB_FILE="force_push_commits.sqlite3"
PYTHON_SCRIPT="force_push_scanner.py"
LOG_DIR="scan_logs"

# Check if database file exists
if [ ! -f "$DB_FILE" ]; then
    echo "Error: Database file $DB_FILE not found!"
    exit 1
fi

# Check if Python script exists
if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "Error: Python script $PYTHON_SCRIPT not found!"
    exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Optional argument: test a single org
TEST_ORG="$1"

if [ -n "$TEST_ORG" ]; then
    ORGS="$TEST_ORG"
    echo "Running scan for single organization: $ORGS"
else
    echo "Extracting organizations from database..."
    ORGS=$(python3 <<EOF
import sqlite3
db = sqlite3.connect("$DB_FILE")
cur = db.cursor()
for row in cur.execute("SELECT DISTINCT repo_org FROM pushes ORDER BY timestamp desc;"):
    if row[0]:
        print(row[0])
db.close()
EOF
)
fi

if [ -z "$ORGS" ]; then
    echo "No organizations found in the database!"
    exit 1
fi

# Count total organizations
TOTAL_ORGS=$(echo "$ORGS" | wc -l)
echo "Found $TOTAL_ORGS organizations to scan:"
echo "$ORGS"
echo ""

# Initialize counters
CURRENT=1
SUCCESS_COUNT=0
FAILED_COUNT=0
FOUND_COUNT=0

# Process each organization
while IFS= read -r org; do
    if [ -n "$org" ]; then
        echo "=========================================="
        echo "[$CURRENT/$TOTAL_ORGS] Scanning organization: $org"
        echo "=========================================="
        
        # Run the scanner with logging
        LOG_FILE="$LOG_DIR/scan_${org}_$(date +%Y%m%d_%H%M%S).log"
        
        if python3 "$PYTHON_SCRIPT" --db-file "$DB_FILE" --scan -v "$org" 2>&1 | tee "$LOG_FILE"; then
            echo "✅ Successfully completed scan for $org"
            
            # Only create results directory if verified_secrets.json exists and is non-empty
            if [ -s "verified_secrets.json" ]; then
                ORG_DIR="results_$org"
                mkdir -p "$ORG_DIR"
                mv "verified_secrets.json" "$ORG_DIR/verified_secrets_${org}.json"
                echo "📁 Secrets found! Results saved to $ORG_DIR/verified_secrets_${org}.json"
                FOUND_COUNT=$((FOUND_COUNT + 1))
            else
                echo "ℹ️ No secrets found for $org"
                rm -f "verified_secrets.json"
            fi
            
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "❌ Failed to scan $org (check $LOG_FILE for details)"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        
        echo ""
        CURRENT=$((CURRENT + 1))
        
        # Optional: Add a small delay between scans to be nice to GitHub
        sleep 2
    fi
done <<< "$ORGS"

echo "=========================================="
echo "BATCH SCAN COMPLETE"
echo "=========================================="
echo "Total organizations: $TOTAL_ORGS"
echo "Successful scans: $SUCCESS_COUNT"
echo "Failed scans: $FAILED_COUNT"
echo "Organizations with secrets found: $FOUND_COUNT"
echo "Logs saved in: $LOG_DIR"
echo "Results organized in: results_<org_name> directories (only if secrets were found)"
