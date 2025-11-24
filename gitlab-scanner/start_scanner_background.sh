#!/bin/bash
# Start the GitLab scanner in the background with proper logging

cd "$(dirname "$0")"

if [ -z "$1" ]; then
    echo "❌ Error: GitLab token required!"
    echo "Usage: $0 <gitlab-token>"
    exit 1
fi

# Check if scanner is already running
if pgrep -f "infinite_scan.sh" > /dev/null; then
    echo "⚠️  Scanner is already running!"
    echo "PID: $(pgrep -f "infinite_scan.sh")"
    exit 1
fi

# Export the token for the child process
export GITLAB_TOKEN="$1"

# Start the scanner
nohup bash -c "./infinite_scan.sh --gitlab-token '$GITLAB_TOKEN'" > infinite_scan.log 2>&1 &
PID=$!

# Wait a moment to see if it starts
sleep 2

# Check if it's still running
if ps -p $PID > /dev/null; then
    echo "✅ Scanner started in background"
    echo "PID: $PID"
else
    echo "❌ Scanner failed to start!"
    echo "Check infinite_scan.log for errors"
    exit 1
fi

echo ""
echo "Monitor with:"
echo "  tail -f infinite_scan.log"
echo ""
echo "Check progress:"
echo "  cat scan_state.json | jq '.'"
echo ""
echo "Stop scanner:"
echo "  pkill -f infinite_scan.sh"
