#!/bin/bash
#
# Sample Fork Scanner - Scans a few forks to verify credential exposure
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sample forks to scan (diverse selection)
SAMPLE_FORKS=(
    "weblate/appsemble"
    "maxdekrieger/appsemble"
    "MaartenJakobs/appsemble"
    "ForEvigt/appsemble"
    "Revadike/appsemble"
)

echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Scanning Sample of Appsemble Forks                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Scanning ${#SAMPLE_FORKS[@]} sample forks to verify credential exposure..."
echo ""

count=1
for fork in "${SAMPLE_FORKS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Scanning fork $count/${#SAMPLE_FORKS[@]}: $fork"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    "$SCRIPT_DIR/scan_repo.sh" "$fork"
    
    echo ""
    ((count++))
done

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Sample Fork Scan Complete                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Results saved to: $SCRIPT_DIR/leaked_secrets_results/"
echo ""
