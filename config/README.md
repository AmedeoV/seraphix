# ⚙️ Configuration

Configuration files for notification services (Telegram, Discord & Email).

---

## 🚀 Quick Setup

### Telegram Notifications

```bash
cp telegram_config.sh.example telegram_config.sh
# Edit telegram_config.sh with your bot token and chat ID
```

### Discord Webhook Notifications

```bash
cp discord_config.sh.example discord_config.sh
# Edit discord_config.sh with your webhook URL
```

### Email Notifications (Mailgun)

```bash
cp mailgun_config.sh.example mailgun_config.sh
# Edit mailgun_config.sh with your Mailgun credentials
```

---

## 🔑 Getting Credentials

### Telegram Bot

1. Message [@BotFather](https://t.me/botfather) on Telegram
2. Create a new bot with `/newbot`
3. Copy your bot token
4. Send a message to your bot
5. Get your chat ID: `https://api.telegram.org/bot<TOKEN>/getUpdates`

### Discord Webhook

1. Open your Discord server
2. Go to **Server Settings** → **Integrations** → **Webhooks**
3. Click **New Webhook** or edit an existing one
4. Customize the name and channel
5. Click **Copy Webhook URL**
6. Paste the URL into `discord_config.sh`

### Mailgun

1. Create account at [mailgun.com](https://mailgun.com)
2. Add and verify your domain
3. Get your API key from the dashboard
4. Configure sender email and recipients

---

## 🔒 Security Note

Configuration files (without `.example` extension) are **git-ignored** and contain sensitive credentials. Never commit them to version control.