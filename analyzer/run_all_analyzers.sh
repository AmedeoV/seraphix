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
    
    if bash "$script" --all > /dev/null 2>&1; then
        echo "✅ [$current/$total] $analyzer completed successfully"
        success=$((success + 1))
    else
        echo "⚠️  [$current/$total] $analyzer completed with warnings/errors"
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
