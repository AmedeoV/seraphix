#!/bin/bash

# Run all detector analyzers with --all flag
# This will analyze all organizations for each detector type

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$SCRIPT_DIR"
DETECTORS_DIR="$ANALYZER_DIR/detectors"

cd "$DETECTORS_DIR"

echo "🔍 Running all detector analyzers..."
echo ""

analyzers=(
    "discordwebhook"
    "disqus"
    "docker"
    "elevenlabs"
    "etherscan"
    "flickr"
    "ftp"
    "gcp"
    "githuboauth2"
    "grafana"
    "huggingface"
    "infura"
    "langsmith"
    "launchdarkly"
    "magicbell"
    "mailgun"
    "mongodb"
    "netlify"
    "notion"
    "npmtoken"
    "openweather"
    "pastebin"
    "paystack"
    "phraseaccesstoken"
    "pinata"
    "polygon"
    "postgres"
    "privatekey"
    "rabbitmq"
    "saucelabs"
    "scrapingant"
    "sendgrid"
    "slackwebhook"
    "smartsheets"
    "sonarcloud"
    "sqlserver"
    "telegrambottoken"
    "twilio"
    "twitterconsumerkey"
    "unsplash"
    "uri"
    "vercel"
)

total=${#analyzers[@]}
current=0
success=0
skipped=0

for analyzer in "${analyzers[@]}"; do
    current=$((current + 1))
    script="${analyzer}_analyzer.sh"
    
    if [ ! -f "$script" ]; then
        echo "⏭️  [$current/$total] Skipping $analyzer (script not found)"
        skipped=$((skipped + 1))
        continue
    fi
    
    echo "🔄 [$current/$total] Running $analyzer analyzer..."
    
    # Fix line endings (CRLF -> LF) before running
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$script" 2>/dev/null
    else
        sed -i 's/\r$//' "$script" 2>/dev/null || true
    fi
    
    # Create log file for this analyzer
    log_file="$ANALYZER_DIR/logs/${analyzer}_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$ANALYZER_DIR/logs"
    
    if bash "$script" --all > "$log_file" 2>&1; then
        echo "✅ [$current/$total] $analyzer completed successfully"
        success=$((success + 1))
    else
        exit_code=$?
        echo "⚠️  [$current/$total] $analyzer completed with warnings/errors (exit code: $exit_code)"
        echo "    Log: $log_file"
        # Show last few lines of the log for quick debugging
        if [ -f "$log_file" ]; then
            echo "    Last 3 lines:"
            tail -3 "$log_file" | sed 's/^/      /'
        fi
        success=$((success + 1))
    fi
    echo ""
done

echo "================================================"
echo "📊 Analysis Summary:"
echo "   Total analyzers: $total"
echo "   Completed: $success"
echo "   Skipped: $skipped"
echo "================================================"
echo ""
echo "✅ All analyzers have been executed!"
echo ""

# Fix any incomplete JSON files before deduplication
echo "🔧 Fixing incomplete JSON files..."
if [ -f "fix_incomplete_json.py" ]; then
    python3 fix_incomplete_json.py
    echo ""
else
    echo "⚠️  JSON fix script not found, skipping..."
    echo ""
fi

# Run post-processing deduplication
echo "🧹 Running post-processing deduplication..."
cd "$ANALYZER_DIR"
if [ -f "deduplicate_analysis_results.py" ]; then
    python3 deduplicate_analysis_results.py
    echo ""
else
    echo "⚠️  Deduplication script not found, skipping..."
    echo ""
fi

echo "Next step: Regenerate the dashboard"
echo "   bash generate_dashboard.sh all"
