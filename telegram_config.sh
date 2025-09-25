#!/bin/bash

# Telegram Bot Configuration
# To set up a Telegram bot for notifications:
#
# 1. Message @BotFather on Telegram
# 2. Use /newbot command to create a new bot
# 3. Copy the bot token provided by BotFather
# 4. Add your bot to a chat/channel or get your personal chat ID
# 5. To get chat ID: https://api.telegram.org/bot<YourBotToken>/getUpdates
#    Send a message to your bot first, then check the updates
#
# Configuration:

# Your Telegram Bot Token (get from @BotFather)
export TELEGRAM_BOT_TOKEN="1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"

# Chat ID where notifications should be sent
# Can be:
#   - Personal chat ID (positive number): 123456789
#   - Group chat ID (negative number): -987654321
#   - Channel username: @yourchannel
export TELEGRAM_CHAT_ID="123456789"

# Optional: Override these if you want different settings
# export TELEGRAM_PARSE_MODE="Markdown"  # or "HTML" or ""
# export TELEGRAM_DISABLE_NOTIFICATION="false"  # Set to "true" for silent notifications