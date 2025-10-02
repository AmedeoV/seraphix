#!/bin/bash

# Enhanced notification system with support for immediate and completion notifications
# Load configuration
if [ -f "config/mailgun_config.sh" ]; then
    source "config/mailgun_config.sh"
fi

if [ -f "config/telegram_config.sh" ]; then
    source "config/telegram_config.sh"
fi

# Preserve environment telegram chat ID if passed
PASSED_TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
if [ -f "config/telegram_config.sh" ]; then
    source "config/telegram_config.sh"
fi
TELEGRAM_CHAT_ID="${PASSED_TELEGRAM_CHAT_ID:-$TELEGRAM_CHAT_ID}"

# Default values
DEFAULT_EMAIL="${DEFAULT_EMAIL:-security-team@company.com}"
EMAIL_FROM="secret-scanner@$(hostname -d 2>/dev/null || echo 'localhost')"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to detect notification type based on file content and arguments
detect_notification_type() {
    local secrets_file="$1"
    local count
    
    if command -v jq >/dev/null 2>&1; then
        count=$(jq length "$secrets_file" 2>/dev/null || echo "0")
    else
        count=$(grep -c '"DetectorName"' "$secrets_file" 2>/dev/null || echo "0")
    fi
    
    # If only 1 secret and filename contains "immediate", it's a first notification
    if [ "$count" = "1" ] && echo "$secrets_file" | grep -q "immediate_secret_"; then
        echo "immediate"
    else
        echo "completion"
    fi
}

# Function to extract secret types from JSON file
get_secret_types() {
    local secrets_file="$1"
    
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[].DetectorName' "$secrets_file" 2>/dev/null | sort | uniq -c | sort -nr
    else
        # Fallback for systems without jq
        grep -o '"DetectorName":"[^"]*"' "$secrets_file" 2>/dev/null | \
        cut -d'"' -f4 | sort | uniq -c | sort -nr
    fi
}

# Function to get first secret details for immediate notification
get_first_secret_details() {
    local secrets_file="$1"
    
    if command -v jq >/dev/null 2>&1; then
        local detector_name=$(jq -r '.[0].DetectorName // "Unknown"' "$secrets_file" 2>/dev/null)
        local commit_hash=$(jq -r '.[0].SourceMetadata.Data.Git.commit // "Unknown"' "$secrets_file" 2>/dev/null)
        local repo_url=$(jq -r '.[0].repository_url // "Unknown"' "$secrets_file" 2>/dev/null)
        local file_path=$(jq -r '.[0].SourceMetadata.Data.Git.file // "Unknown"' "$secrets_file" 2>/dev/null)
        
        echo "Type: $detector_name"$'\n'"Commit: $commit_hash"$'\n'"Repository: $repo_url"$'\n'"File: $file_path"
    else
        echo "Secret detected (jq not available for detailed parsing)"
    fi
}

# Send immediate notification (first secret found)
send_immediate_notification() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname=$(hostname)
    local scanner_user=$(whoami)
    local secret_details=$(get_first_secret_details "$secrets_file")
    
    # Email notification
    if [ -n "$notification_email" ] && [ -n "$MAILGUN_API_KEY" ] && [ -n "$MAILGUN_DOMAIN" ]; then
        send_immediate_email "$org" "$secrets_file" "$notification_email" "$timestamp" "$hostname" "$scanner_user" "$secret_details"
    fi
    
    # Telegram notification
    if [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        send_immediate_telegram "$org" "$secrets_file" "$timestamp" "$hostname" "$scanner_user" "$secret_details"
    fi
}

# Send completion notification (scan finished)
send_completion_notification() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname=$(hostname)
    local scanner_user=$(whoami)
    local secret_types=$(get_secret_types "$secrets_file")
    local total_count
    
    if command -v jq >/dev/null 2>&1; then
        total_count=$(jq length "$secrets_file" 2>/dev/null || echo "unknown")
    else
        total_count=$(grep -c '"DetectorName"' "$secrets_file" 2>/dev/null || echo "unknown")
    fi
    
    # Email notification
    if [ -n "$notification_email" ] && [ -n "$MAILGUN_API_KEY" ] && [ -n "$MAILGUN_DOMAIN" ]; then
        send_completion_email "$org" "$secrets_file" "$notification_email" "$timestamp" "$hostname" "$scanner_user" "$secret_types" "$total_count"
    fi
    
    # Telegram notification
    if [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        send_completion_telegram "$org" "$secrets_file" "$timestamp" "$hostname" "$scanner_user" "$secret_types" "$total_count"
    fi
}

# Immediate email notification
send_immediate_email() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    local timestamp="$4"
    local hostname="$5"
    local scanner_user="$6"
    local secret_details="$7"
    
    local from_address="${MAILGUN_FROM:-$EMAIL_FROM}"
    local subject="🚨 URGENT: First Secret Detected in '$org' - Scan Continuing"
    local temp_text=$(mktemp)
    local temp_html=$(mktemp)
    
    # Create text content
    cat > "$temp_text" << EOF
🚨 FIRST SECRET DETECTED - IMMEDIATE ALERT

Organization: $org
Detection Time: $timestamp
Scanner Host: $hostname
Scanner User: $scanner_user
Status: Scanning in progress - more secrets may be found

SECRET DETAILS:
$secret_details

NEXT STEPS:
- This is the first secret detected for this organization
- The scan is continuing and may find additional secrets
- You will receive a summary notification when the scan completes
- Consider immediate action on this secret while waiting for the full report

The complete JSON file with secret details is attached to this notification.

This is an automated alert from the force push secret scanner.
EOF

    # Create HTML content
    cat > "$temp_html" << EOF
<html><body>
<h2 style='color: #d73027;'>🚨 FIRST SECRET DETECTED - IMMEDIATE ALERT</h2>
<div style='background-color: #e8f4fd; border: 1px solid #bee5eb; padding: 15px; margin: 10px 0; border-radius: 5px;'>
<p style='margin: 0; font-weight: bold; color: #0c5460;'>⏳ Scan Status: IN PROGRESS - This is the first secret found, scan continuing...</p>
</div>
<table style='border-collapse: collapse; width: 100%; font-family: Arial, sans-serif; margin: 20px 0;'>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Organization:</td><td style='padding: 8px; border: 1px solid #ddd;'>$org</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Detection Time:</td><td style='padding: 8px; border: 1px solid #ddd;'>$timestamp</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner Host:</td><td style='padding: 8px; border: 1px solid #ddd;'>$hostname</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner User:</td><td style='padding: 8px; border: 1px solid #ddd;'>$scanner_user</td></tr>
</table>
<div style='background-color: #f8f9fa; border: 1px solid #dee2e6; padding: 15px; margin: 20px 0; border-radius: 5px;'>
<h3 style='color: #495057; margin-top: 0;'>🔍 Secret Details:</h3>
<pre style='background-color: #ffffff; padding: 10px; border: 1px solid #e9ecef; border-radius: 3px; overflow-x: auto;'>$secret_details</pre>
</div>
<div style='background-color: #d4edda; border: 1px solid #c3e6cb; padding: 15px; margin: 20px 0; border-radius: 5px;'>
<h3 style='color: #155724; margin-top: 0;'>📋 Next Steps:</h3>
<ul style='margin: 10px 0; padding-left: 20px;'>
<li style='margin: 5px 0;'>This is the first secret detected for this organization</li>
<li style='margin: 5px 0;'>The scan is continuing and may find additional secrets</li>
<li style='margin: 5px 0;'>You will receive a summary notification when the scan completes</li>
<li style='margin: 5px 0;'>Consider immediate action on this secret while waiting for the full report</li>
</ul>
</div>
<p style='font-size: 12px; color: #666; margin-top: 30px; border-top: 1px solid #ddd; padding-top: 10px;'>
<em>The complete JSON file with secret details is attached. This is an automated alert from the force push secret scanner.</em>
</p>
</body></html>
EOF

    # Send email with JSON attachment
    local response
    response=$(curl -s --user "api:$MAILGUN_API_KEY" \
        "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
        -F "from=$from_address" \
        -F "to=$notification_email" \
        -F "subject=$subject" \
        -F "text=<$temp_text" \
        -F "html=<$temp_html" \
        -F "attachment=@$secrets_file" \
        -F "o:tag=security-alert" \
        -F "o:tag=immediate-notification" \
        -F "o:tag=org:$org")
    
    # Clean up temp files
    rm -f "$temp_text" "$temp_html"
    
    if echo "$response" | grep -q '"message".*"Queued'; then
        echo -e "${GREEN}✉️  Immediate email notification sent to: $notification_email${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to send immediate email: $response${NC}" >&2
        return 1
    fi
}

# Completion email notification
send_completion_email() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    local timestamp="$4"
    local hostname="$5"
    local scanner_user="$6"
    local secret_types="$7"
    local total_count="$8"
    
    local from_address="${MAILGUN_FROM:-$EMAIL_FROM}"
    local subject="📊 SCAN COMPLETE: $total_count Secrets Found in '$org'"
    local file_size=$(du -h "$secrets_file" | cut -f1)
    local temp_text=$(mktemp)
    local temp_html=$(mktemp)
    
    # Create text content
    cat > "$temp_text" << EOF
📊 SCAN COMPLETION REPORT

Organization: $org
Total Secrets Found: $total_count
Scan Completed: $timestamp
Scanner Host: $hostname
Scanner User: $scanner_user
Results File: $secrets_file
File Size: $file_size

SECRET TYPES DETECTED:
$secret_types

This scan has completed. Review the attached results file for complete details.

This is an automated report from the force push secret scanner.
EOF

    # Create HTML content
    cat > "$temp_html" << EOF
<html><body>
<h2 style='color: #28a745;'>📊 SCAN COMPLETION REPORT</h2>
<div style='background-color: #d4edda; border: 1px solid #c3e6cb; padding: 15px; margin: 10px 0; border-radius: 5px;'>
<p style='margin: 0; font-weight: bold; color: #155724;'>✅ Scan Status: COMPLETED</p>
</div>
<table style='border-collapse: collapse; width: 100%; font-family: Arial, sans-serif; margin: 20px 0;'>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Organization:</td><td style='padding: 8px; border: 1px solid #ddd;'>$org</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Total Secrets Found:</td><td style='padding: 8px; border: 1px solid #ddd; color: #d73027; font-weight: bold; font-size: 16px;'>$total_count</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scan Completed:</td><td style='padding: 8px; border: 1px solid #ddd;'>$timestamp</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner Host:</td><td style='padding: 8px; border: 1px solid #ddd;'>$hostname</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner User:</td><td style='padding: 8px; border: 1px solid #ddd;'>$scanner_user</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Results File:</td><td style='padding: 8px; border: 1px solid #ddd;'><code style='background-color: #f0f0f0; padding: 2px 4px;'>$secrets_file</code></td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>File Size:</td><td style='padding: 8px; border: 1px solid #ddd;'>$file_size</td></tr>
</table>
<div style='background-color: #f8f9fa; border: 1px solid #dee2e6; padding: 15px; margin: 20px 0; border-radius: 5px;'>
<h3 style='color: #495057; margin-top: 0;'>🔍 Secret Types Detected:</h3>
<pre style='background-color: #ffffff; padding: 10px; border: 1px solid #e9ecef; border-radius: 3px; overflow-x: auto; font-family: monospace;'>$secret_types</pre>
</div>
<p style='font-size: 12px; color: #666; margin-top: 30px; border-top: 1px solid #ddd; padding-top: 10px;'>
<em>This scan has completed. Review the results file for complete details. This is an automated report from the force push secret scanner.</em>
</p>
</body></html>
EOF

    # Send email
    local response
    response=$(curl -s --user "api:$MAILGUN_API_KEY" \
        "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
        -F "from=$from_address" \
        -F "to=$notification_email" \
        -F "subject=$subject" \
        -F "text=<$temp_text" \
        -F "html=<$temp_html" \
        -F "o:tag=security-alert" \
        -F "o:tag=completion-notification" \
        -F "o:tag=org:$org")
    
    # Clean up temp files
    rm -f "$temp_text" "$temp_html"
    
    if echo "$response" | grep -q '"message".*"Queued'; then
        echo -e "${GREEN}✉️  Completion email notification sent to: $notification_email${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to send completion email: $response${NC}" >&2
        return 1
    fi
}

# Immediate Telegram notification
send_immediate_telegram() {
    local org="$1"
    local secrets_file="$2"
    local timestamp="$3"
    local hostname="$4"
    local scanner_user="$5"
    local secret_details="$6"
    
    local message="🚨 *FIRST SECRET DETECTED - IMMEDIATE ALERT*

⏳ *Status:* Scan IN PROGRESS - more secrets may be found

📊 *Organization:* \`$org\`
⏰ *Detection Time:* $timestamp
🖥️ *Scanner Host:* \`$hostname\`
👤 *Scanner User:* \`$scanner_user\`

🔍 *Secret Details:*
\`\`\`
$secret_details
\`\`\`

📋 *Next Steps:*
• This is the first secret detected for this organization
• The scan is continuing and may find additional secrets
• You will receive a summary notification when scan completes
• Consider immediate action on this secret while waiting for full report

_This is an automated alert from the force push secret scanner._"

    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": \"$message\",
            \"parse_mode\": \"Markdown\",
            \"disable_web_page_preview\": true
        }")
    
    if echo "$response" | grep -q '"ok":true'; then
        echo -e "${GREEN}📲 Immediate Telegram notification sent${NC}"
        
        # Also send the JSON file as document
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
            -F "chat_id=$TELEGRAM_CHAT_ID" \
            -F "document=@$secrets_file" \
            -F "caption=🔍 Complete secret details (JSON format)" > /dev/null
        
        return 0
    else
        echo -e "${RED}❌ Failed to send immediate Telegram notification: $response${NC}" >&2
        return 1
    fi
}

# Completion Telegram notification
send_completion_telegram() {
    local org="$1"
    local secrets_file="$2"
    local timestamp="$3"
    local hostname="$4"
    local scanner_user="$5"
    local secret_types="$6"
    local total_count="$7"
    
    local file_size=$(du -h "$secrets_file" | cut -f1)
    
    local message="📊 *SCAN COMPLETION REPORT*

✅ *Status:* Scan COMPLETED

📊 *Organization:* \`$org\`
🔍 *Total Secrets Found:* *$total_count*
⏰ *Scan Completed:* $timestamp
🖥️ *Scanner Host:* \`$hostname\`
👤 *Scanner User:* \`$scanner_user\`
📁 *Results File:* \`$secrets_file\`
💾 *File Size:* $file_size

🔍 *Secret Types Detected:*
\`\`\`
$secret_types
\`\`\`

✅ *This scan has completed.* Review the results file for complete details.

_This is an automated report from the force push secret scanner._"

    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": \"$message\",
            \"parse_mode\": \"Markdown\",
            \"disable_web_page_preview\": true
        }")
    
    if echo "$response" | grep -q '"ok":true'; then
        echo -e "${GREEN}📲 Completion Telegram notification sent${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to send completion Telegram notification: $response${NC}" >&2
        return 1
    fi
}

# Main function - auto-detect notification type and send appropriate notification
send_smart_notification() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    
    if [ ! -f "$secrets_file" ]; then
        echo -e "${RED}Error: Secrets file not found: $secrets_file${NC}" >&2
        return 1
    fi
    
    local notification_type=$(detect_notification_type "$secrets_file")
    
    echo -e "${YELLOW}📢 Sending $notification_type notification for: $org${NC}"
    
    if [ "$notification_type" = "immediate" ]; then
        send_immediate_notification "$org" "$secrets_file" "$notification_email"
    else
        send_completion_notification "$org" "$secrets_file" "$notification_email"
    fi
}

# Allow script to be called directly or sourced
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <organization> <secrets_file> [email]"
        echo "Example: $0 myorg /path/to/secrets.json security@company.com"
        echo ""
        echo "The script will automatically detect if this is an immediate or completion notification"
        exit 1
    fi
    
    send_smart_notification "$1" "$2" "$3"
fi