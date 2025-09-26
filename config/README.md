# Configuration Directory

This directory contains configuration files for the secret scanner notifications.

## Setup Instructions

1. **For Email Notifications (Mailgun):**
   ```bash
   cp mailgun_config.sh.example mailgun_config.sh
   # Edit mailgun_config.sh with your Mailgun credentials
   ```

2. **For Telegram Notifications:**
   ```bash
   cp telegram_config.sh.example telegram_config.sh
   # Edit telegram_config.sh with your Telegram bot credentials
   ```

## Configuration Files

- `mailgun_config.sh` - Mailgun email service configuration (not tracked in git)
- `telegram_config.sh` - Telegram bot configuration (not tracked in git)
- `*.example` files - Template configuration files (tracked in git)

## Getting Credentials

### Mailgun Setup
1. Create account at https://mailgun.com
2. Add your domain and verify it
3. Get your API key from the dashboard
4. Fill in the mailgun_config.sh file

### Telegram Bot Setup
1. Message @BotFather on Telegram
2. Create a new bot with `/newbot`
3. Get your bot token
4. Send a message to your bot
5. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` to get your chat ID
6. Fill in the telegram_config.sh file

## Security Note

The actual configuration files (without .example extension) contain sensitive credentials and are ignored by git. Never commit them to version control.