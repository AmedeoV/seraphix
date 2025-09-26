#!/bin/bash

# Load Mailgun configuration
if [ -f "config/mailgun_config.sh" ]; then
    source "config/mailgun_config.sh"
fi

# Load Telegram configuration
if [ -f "config/telegram_config.sh" ]; then
    source "config/telegram_config.sh"
fi

# Email notification configuration (fallback values)
DEFAULT_EMAIL="${DEFAULT_EMAIL:-security-team@company.com}"
EMAIL_FROM="secret-scanner@$(hostname -d 2>/dev/null || echo 'localhost')"

# Telegram notification configuration (from config file or environment)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

send_mailgun_notification() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="${3:-$DEFAULT_EMAIL}"
    
    # Validate Mailgun configuration
    if [ -z "$MAILGUN_API_KEY" ] || [ -z "$MAILGUN_DOMAIN" ]; then
        echo -e "${RED}Error: Mailgun API key and domain must be configured${NC}" >&2
        return 1
    fi
    
    # Validate inputs
    if [ -z "$org" ] || [ -z "$secrets_file" ]; then
        echo -e "${RED}Error: Missing required parameters for email notification${NC}" >&2
        return 1
    fi
    
    if [ ! -f "$secrets_file" ]; then
        echo -e "${RED}Error: Secrets file not found: $secrets_file${NC}" >&2
        return 1
    fi
    
    # Count secrets
    local count
    if command -v jq >/dev/null 2>&1; then
        count=$(jq length "$secrets_file" 2>/dev/null || echo "unknown")
    else
        # Multiple fallback methods for counting JSON array elements
        if command -v grep >/dev/null 2>&1; then
            count=$(grep -c '"DetectorName"' "$secrets_file" 2>/dev/null || echo "unknown")
        elif command -v powershell.exe >/dev/null 2>&1; then
            count=$(powershell.exe -c "try { (Get-Content '$secrets_file' | ConvertFrom-Json).Count } catch { 'unknown' }" 2>/dev/null || echo "unknown")
        else
            # Last resort: count opening braces that follow array pattern
            count=$(awk '/^\s*\{/ {count++} END {print count+0}' "$secrets_file" 2>/dev/null || echo "unknown")
        fi
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname=$(hostname)
    local scanner_user=$(whoami)
    local file_size=$(du -h "$secrets_file" | cut -f1)
    
    # Set from address (use configured MAILGUN_FROM or fallback)
    local from_address="${MAILGUN_FROM:-$EMAIL_FROM}"
    
    # Create email subject
    local subject="URGENT: $count Secrets Detected in Organization '$org'"
    
    # Create temporary files for the email content
    local temp_text=$(mktemp)
    local temp_html=$(mktemp)
    
    # Write text content to temp file
    cat > "$temp_text" << EOF
SECURITY ALERT: Leaked Secrets Detected
========================================

Organization: $org
Secrets Found: $count
Detection Time: $timestamp
Scanner Host: $hostname
Scanner User: $scanner_user

Results File: $secrets_file
File Size: $file_size

IMMEDIATE ACTION REQUIRED:
- Review the detected secrets immediately
- Revoke/rotate any exposed credentials
- Investigate the source repositories
- Update security policies if needed

This is an automated alert from the force push secret scanner.
Do not reply to this email.
EOF

    # Write HTML content to temp file
    cat > "$temp_html" << EOF
<html><body>
<h2 style='color: #d73027;'>🚨 SECURITY ALERT: Leaked Secrets Detected</h2>
<table style='border-collapse: collapse; width: 100%; font-family: Arial, sans-serif; margin: 20px 0;'>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Organization:</td><td style='padding: 8px; border: 1px solid #ddd;'>$org</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Secrets Found:</td><td style='padding: 8px; border: 1px solid #ddd; color: #d73027; font-weight: bold; font-size: 16px;'>$count</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Detection Time:</td><td style='padding: 8px; border: 1px solid #ddd;'>$timestamp</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner Host:</td><td style='padding: 8px; border: 1px solid #ddd;'>$hostname</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Scanner User:</td><td style='padding: 8px; border: 1px solid #ddd;'>$scanner_user</td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>Results File:</td><td style='padding: 8px; border: 1px solid #ddd;'><code style='background-color: #f0f0f0; padding: 2px 4px;'>$secrets_file</code></td></tr>
<tr><td style='padding: 8px; border: 1px solid #ddd; font-weight: bold; background-color: #f5f5f5;'>File Size:</td><td style='padding: 8px; border: 1px solid #ddd;'>$file_size</td></tr>
</table>
<div style='background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; margin: 20px 0; border-radius: 5px;'>
<h3 style='color: #d73027; margin-top: 0;'>⚠️ IMMEDIATE ACTION REQUIRED:</h3>
<ul style='margin: 10px 0; padding-left: 20px;'>
<li style='margin: 5px 0;'>Review the detected secrets immediately</li>
<li style='margin: 5px 0;'>Revoke/rotate any exposed credentials</li>
<li style='margin: 5px 0;'>Investigate the source repositories</li>
<li style='margin: 5px 0;'>Update security policies if needed</li>
</ul>
</div>
<p style='font-size: 12px; color: #666; margin-top: 30px; border-top: 1px solid #ddd; padding-top: 10px;'>
<em>This is an automated alert from the force push secret scanner. Do not reply to this email.</em>
</p>
</body></html>
EOF

    echo -e "${YELLOW}📮 Sending email via Mailgun...${NC}"
    echo -e "${YELLOW}   Domain: $MAILGUN_DOMAIN${NC}"
    echo -e "${YELLOW}   From: $from_address${NC}"
    echo -e "${YELLOW}   To: $notification_email${NC}"

    # Send email via Mailgun API using file uploads for content
    local response
    response=$(curl -s --user "api:$MAILGUN_API_KEY" \
        "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
        -F "from=$from_address" \
        -F "to=$notification_email" \
        -F "subject=$subject" \
        -F "text=<$temp_text" \
        -F "html=<$temp_html" \
        -F "o:tag=security-alert" \
        -F "o:tag=secret-scanner" \
        -F "o:tag=org:$org")
    
    local curl_exit_code=$?
    
    # Clean up temp files
    rm -f "$temp_text" "$temp_html"
    
    if [ $curl_exit_code -eq 0 ]; then
        # Check if Mailgun API returned success (both "Queued" and "Queued. Thank you." are success)
        if echo "$response" | grep -q '"message".*"Queued'; then
            local message_id=$(echo "$response" | grep -o '"id": "[^"]*"' | cut -d'"' -f4)
            echo -e "${GREEN}✉️  Email notification sent via Mailgun to: $notification_email${NC}"
            echo -e "${GREEN}📧 Message ID: $message_id${NC}"
            return 0
        else
            echo -e "${RED}❌ Mailgun API error: $response${NC}" >&2
            return 1
        fi
    else
        echo -e "${RED}❌ Failed to send email via Mailgun (curl exit code: $curl_exit_code)${NC}" >&2
        echo -e "${RED}Response: $response${NC}" >&2
        return 1
    fi
}

send_telegram_notification() {
    local org="$1"
    local secrets_file="$2"
    
    # Validate Telegram configuration
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}Error: Telegram bot token and chat ID must be configured${NC}" >&2
        return 1
    fi
    
    # Validate inputs
    if [ -z "$org" ] || [ -z "$secrets_file" ]; then
        echo -e "${RED}Error: Missing required parameters for Telegram notification${NC}" >&2
        return 1
    fi
    
    if [ ! -f "$secrets_file" ]; then
        echo -e "${RED}Error: Secrets file not found: $secrets_file${NC}" >&2
        return 1
    fi
    
    # Count secrets - fix the counting logic
    local count
    if command -v jq >/dev/null 2>&1; then
        count=$(jq length "$secrets_file" 2>/dev/null || echo "unknown")
    else
        # Multiple fallback methods for counting JSON array elements
        if command -v grep >/dev/null 2>&1; then
            count=$(grep -c '"DetectorName"' "$secrets_file" 2>/dev/null || echo "unknown")
        elif command -v powershell.exe >/dev/null 2>&1; then
            count=$(powershell.exe -c "try { (Get-Content '$secrets_file' | ConvertFrom-Json).Count } catch { 'unknown' }" 2>/dev/null || echo "unknown")
        else
            # Last resort: count opening braces that follow array pattern
            count=$(awk '/^\s*\{/ {count++} END {print count+0}' "$secrets_file" 2>/dev/null || echo "unknown")
        fi
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname=$(hostname)
    local scanner_user=$(whoami)
    local file_size=$(du -h "$secrets_file" | cut -f1)
    
    # Create Telegram message with Markdown formatting
    local message="🚨 *SECURITY ALERT: Leaked Secrets Detected*

📊 *Organization:* \`$org\`
🔍 *Secrets Found:* *$count*
⏰ *Detection Time:* $timestamp
🖥️ *Scanner Host:* \`$hostname\`
👤 *Scanner User:* \`$scanner_user\`
📁 *Results File:* \`$secrets_file\`
💾 *File Size:* $file_size

⚠️ *IMMEDIATE ACTION REQUIRED:*
• Review the detected secrets immediately
• Revoke/rotate any exposed credentials  
• Investigate the source repositories
• Update security policies if needed

_This is an automated alert from the force push secret scanner._"

    echo -e "${YELLOW}📱 Sending Telegram notification...${NC}"
    echo -e "${YELLOW}   Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}...${NC}"
    echo -e "${YELLOW}   Chat ID: $TELEGRAM_CHAT_ID${NC}"

    # Send message via Telegram Bot API
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": \"$message\",
            \"parse_mode\": \"Markdown\",
            \"disable_web_page_preview\": true
        }")
    
    local curl_exit_code=$?
    
    if [ $curl_exit_code -eq 0 ]; then
        # Check if Telegram API returned success
        if echo "$response" | grep -q '"ok":true'; then
            local message_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | cut -d':' -f2)
            echo -e "${GREEN}📲 Telegram notification sent successfully${NC}"
            echo -e "${GREEN}📧 Message ID: $message_id${NC}"
            return 0
        else
            local error_description=$(echo "$response" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
            echo -e "${RED}❌ Telegram API error: ${error_description:-$response}${NC}" >&2
            return 1
        fi
    else
        echo -e "${RED}❌ Failed to send Telegram notification (curl exit code: $curl_exit_code)${NC}" >&2
        echo -e "${RED}Response: $response${NC}" >&2
        return 1
    fi
}

send_email_notification() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"
    
    # Don't attempt email if no email address provided
    if [ -z "$notification_email" ]; then
        echo -e "${RED}Error: No email address provided for email notification${NC}" >&2
        return 1
    fi
    
    # Try Mailgun first if configured, fallback to system mail
    if [ -n "$MAILGUN_API_KEY" ] && [ -n "$MAILGUN_DOMAIN" ]; then
        echo -e "${YELLOW}📮 Using Mailgun for email delivery${NC}"
        send_mailgun_notification "$org" "$secrets_file" "$notification_email"
        return $?
    fi
    
    echo -e "${YELLOW}📮 Using system mail for email delivery${NC}"
    echo -e "${RED}❌ Mailgun not configured - fallback to system mail not implemented${NC}" >&2
    return 1
}

# Function to send all configured notifications
send_all_notifications() {
    local org="$1"
    local secrets_file="$2"
    local notification_email="$3"  # Remove default value here
    
    echo -e "${YELLOW}📢 Sending security notifications for organization: $org${NC}"
    
    local success_count=0
    local total_count=0
    
    # Send email notification if email address is provided AND Mailgun is configured
    if [ -n "$notification_email" ] && [ -n "$MAILGUN_API_KEY" ] && [ -n "$MAILGUN_DOMAIN" ]; then
        echo -e "${YELLOW}📧 Attempting email notification...${NC}"
        ((total_count++))
        if send_email_notification "$org" "$secrets_file" "$notification_email"; then
            ((success_count++))
        fi
    elif [ -n "$notification_email" ]; then
        echo -e "${YELLOW}⚠️  Email requested but Mailgun not configured${NC}"
    fi
    
    # Send Telegram notification if chat ID is provided AND bot token is configured
    if [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "${YELLOW}📱 Attempting Telegram notification...${NC}"
        ((total_count++))
        if send_telegram_notification "$org" "$secrets_file"; then
            ((success_count++))
        fi
    elif [ -n "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${YELLOW}⚠️  Telegram requested but bot token not configured${NC}"
    fi
    
    # Summary
    if [ $total_count -eq 0 ]; then
        echo -e "${RED}❌ No notification methods configured${NC}" >&2
        return 1
    elif [ $success_count -eq $total_count ]; then
        echo -e "${GREEN}✅ All notifications sent successfully ($success_count/$total_count)${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  Partial success: $success_count/$total_count notifications sent${NC}"
        return 1
    fi
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    # Script is being executed directly
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <organization> <secrets_file> [email]"
        echo "Example: $0 myorg /path/to/secrets.json security@company.com"
        echo ""
        echo "Configuration loaded from config/mailgun_config.sh:"
        echo "  Mailgun Domain: ${MAILGUN_DOMAIN:-'Not configured'}"
        echo "  Mailgun From: ${MAILGUN_FROM:-'Not configured'}"
        echo "  Default Email: ${DEFAULT_EMAIL:-'Not configured'}"
        echo ""
        echo "Configuration loaded from config/telegram_config.sh:"
        echo "  Bot Token: ${TELEGRAM_BOT_TOKEN:+Configured}${TELEGRAM_BOT_TOKEN:-'Not configured'}"
        echo "  Chat ID: ${TELEGRAM_CHAT_ID:-'Not configured'}"
        exit 1
    fi
    
    send_all_notifications "$1" "$2" "$3"
fi