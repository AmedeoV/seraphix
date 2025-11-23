#!/bin/bash
# Infinite Bitbucket repo scanner - fetches from API and scans continuously

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# State file to track scanned repositories
STATE_FILE="$SCRIPT_DIR/scan_state.json"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Initialize state file if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
    echo '{"scanned_repos": [], "last_api_url": "https://bitbucket.org/api/2.0/repositories/", "total_scanned": 0, "total_skipped": 0}' > "$STATE_FILE"
fi

# Load state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        SCANNED_REPOS=$(jq -r '.scanned_repos[]' "$STATE_FILE" 2>/dev/null || echo "")
        LAST_API_URL=$(jq -r '.last_api_url // "https://bitbucket.org/api/2.0/repositories/"' "$STATE_FILE" 2>/dev/null)
        TOTAL_SCANNED=$(jq -r '.total_scanned // 0' "$STATE_FILE" 2>/dev/null)
        TOTAL_SKIPPED=$(jq -r '.total_skipped // 0' "$STATE_FILE" 2>/dev/null)
    else
        SCANNED_REPOS=""
        LAST_API_URL="https://bitbucket.org/api/2.0/repositories/"
        TOTAL_SCANNED=0
        TOTAL_SKIPPED=0
    fi
}

# Check if repo was already scanned
is_scanned() {
    local repo="$1"
    echo "$SCANNED_REPOS" | grep -Fxq "$repo"
}

# Save scanned repo to state
save_scanned_repo() {
    local repo="$1"
    local next_url="$2"
    
    # Add repo to scanned list
    jq --arg repo "$repo" --arg url "$next_url" --argjson scanned "$((TOTAL_SCANNED + 1))" \
        '.scanned_repos += [$repo] | .last_api_url = $url | .total_scanned = $scanned' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    
    TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
    SCANNED_REPOS=$(echo -e "$SCANNED_REPOS\n$repo")
}

# Save skipped repo to state
save_skipped_repo() {
    local next_url="$1"
    
    jq --arg url "$next_url" --argjson skipped "$((TOTAL_SKIPPED + 1))" \
        '.last_api_url = $url | .total_skipped = $skipped' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
}

# Load initial state
load_state

echo -e "${CYAN}🔄 Starting infinite Bitbucket scanner...${NC}"
echo -e "${BLUE}ℹ️  Fetching repositories from Bitbucket API${NC}"
echo -e "${YELLOW}📊 Progress: $TOTAL_SCANNED scanned, $TOTAL_SKIPPED skipped${NC}"

if [ "$LAST_API_URL" != "https://bitbucket.org/api/2.0/repositories/" ]; then
    echo -e "${YELLOW}🔄 Resuming from: $LAST_API_URL${NC}"
fi

page_count=0

while true; do
    # Fetch repositories from Bitbucket API
    api_url="$LAST_API_URL"
    
    while [ -n "$api_url" ]; do
        ((page_count++))
        echo -e "${CYAN}📥 Fetching page $page_count from API...${NC}"
        
        # Fetch current page
        response=$(curl -s "$api_url")
        
        # Extract repository full names (workspace/repo)
        repos=$(echo "$response" | jq -r '.values[]? | .full_name' 2>/dev/null || echo "")
        
        if [ -z "$repos" ]; then
            echo -e "${BLUE}ℹ️  No more repositories on this page${NC}"
            break
        fi
        
        # Get next page URL before processing repos
        next_api_url=$(echo "$response" | jq -r '.next // empty' 2>/dev/null || echo "")
        
        # Scan each repository
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            
            # Check if already scanned
            if is_scanned "$repo"; then
                echo -e "${YELLOW}⏭️  Skipping $repo (already scanned)${NC}"
                continue
            fi
            
            echo -e "${GREEN}===== Scanning: $repo =====${NC}"
            
            # Set a timeout for the entire scan operation (30 seconds)
            # If it prompts for credentials or hangs, skip to next repo
            if timeout 30s ./scan_repo.sh "$repo" 2>/dev/null; then
                # Successfully scanned
                save_scanned_repo "$repo" "$next_api_url"
                echo -e "${GREEN}✅ Successfully scanned $repo (Total: $TOTAL_SCANNED)${NC}"
            else
                # Failed or timed out
                save_skipped_repo "$next_api_url"
                echo -e "${BLUE}ℹ️  Skipping $repo (timeout or requires authentication) (Total skipped: $TOTAL_SKIPPED)${NC}"
            fi
            
        done <<< "$repos"
        
        # Move to next page
        api_url="$next_api_url"
        LAST_API_URL="$api_url"
        
        # Small delay between pages to avoid rate limiting
        sleep 1
    done
    
    echo -e "${CYAN}===== Completed cycle, restarting from beginning... =====${NC}"
    echo -e "${YELLOW}📊 Total Progress: $TOTAL_SCANNED scanned, $TOTAL_SKIPPED skipped${NC}"
    
    # Reset to beginning for next cycle
    LAST_API_URL="https://bitbucket.org/api/2.0/repositories/"
    page_count=0
    sleep 2
done
