#!/bin/bash

detectors=(
    "CalendlyApiKey"
    "Coinbase"
    "ContentfulPersonalAccessToken"
    "Convertkit"
    "DeepSeek"
    "DiscordWebhook"
    "Disqus"
    "Docker"
    "ElevenLabs"
    "Etherscan"
    "Flickr"
    "FTP"
    "GCP"
    "GitHubOauth2"
    "Grafana"
    "HuggingFace"
    "Infura"
    "LangSmith"
    "LaunchDarkly"
    "MagicBell"
    "Mailgun"
    "MongoDB"
    "Netlify"
    "Notion"
    "NpmToken"
    "OpenWeather"
    "Pastebin"
    "Paystack"
    "PhraseAccessToken"
    "Pinata"
    "Polygon"
    "Postgres"
    "PrivateKey"
    "RabbitMQ"
    "SauceLabs"
    "ScrapingAnt"
    "SendGrid"
    "SlackWebhook"
    "Smartsheets"
    "SonarCloud"
    "SQLServer"
    "TelegramBotToken"
    "Twilio"
    "TwitterConsumerkey"
    "Unsplash"
    "URI"
    "Vercel"
)

echo "Checking for detectors with secrets..."
echo ""

for detector in "${detectors[@]}"; do
    count=$(find ../force-push-scanner/leaked_secrets_results -name "verified_secrets_*.json" -type f -exec grep -l "\"DetectorName\": \"$detector\"" {} \; 2>/dev/null | wc -l)
    count=$(echo "$count" | tr -d ' ')
    
    if [ "$count" -gt 0 ]; then
        echo "$detector: $count files"
    fi
done
