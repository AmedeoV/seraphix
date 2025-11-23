#!/bin/bash
# Cleanup empty result directories from Bitbucket scanner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/leaked_secrets_results"

if [ ! -d "$RESULTS_DIR" ]; then
    echo "No results directory found at: $RESULTS_DIR"
    exit 0
fi

echo "🔍 Scanning for empty result directories..."

removed_count=0
kept_count=0

# Find all directories in results folder
while IFS= read -r -d '' dir; do
    # Check if directory has any JSON files
    json_count=$(find "$dir" -maxdepth 1 -name "*.json" -type f | wc -l)
    
    if [ "$json_count" -eq 0 ]; then
        echo "  🗑️  Removing empty directory: $(basename "$dir")"
        rm -rf "$dir"
        ((removed_count++))
    else
        # Check if JSON files have secrets (non-empty array)
        has_secrets=false
        while IFS= read -r json_file; do
            if [ -f "$json_file" ]; then
                findings=$(jq 'length' "$json_file" 2>/dev/null || echo "0")
                if [ "$findings" -gt 0 ]; then
                    has_secrets=true
                    break
                fi
            fi
        done < <(find "$dir" -maxdepth 1 -name "*.json" -type f)
        
        if [ "$has_secrets" = false ]; then
            echo "  🗑️  Removing directory with no secrets: $(basename "$dir")"
            rm -rf "$dir"
            ((removed_count++))
        else
            ((kept_count++))
        fi
    fi
done < <(find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

echo ""
echo "✅ Cleanup complete!"
echo "   Removed: $removed_count directories"
echo "   Kept: $kept_count directories with secrets"
