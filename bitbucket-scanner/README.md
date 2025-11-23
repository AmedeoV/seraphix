# 🔷 Bitbucket Scanner

Comprehensive Bitbucket secret scanning toolkit for security researchers. Scan entire workspaces or individual repositories for leaked credentials and sensitive data.

## 📋 Features

- **Workspace-Wide Scanning** - Scan all repositories in a Bitbucket workspace
- **Individual Repository Scanning** - Target specific repositories for focused analysis
- **Private Repository Support** - Authenticate using Bitbucket app passwords
- **Multi-Worker Architecture** - Parallel scanning with automatic resource detection
- **Real-Time Notifications** - Telegram, Discord, and Email alerts when secrets are found
- **Adaptive Timeouts** - Dynamic timeout adjustment based on repository size and complexity
- **Comprehensive Results** - Organized output with timestamped scan results

## 🚀 Quick Start

### Prerequisites

Ensure you have the required dependencies installed:

```bash
# From the project root
./install_requirements.sh
```

### Authentication (Optional but Recommended)

For scanning private repositories, create a Bitbucket App Password:

1. Go to [Bitbucket Account Settings > App Passwords](https://bitbucket.org/account/settings/app-passwords/)
2. Create a new app password with **Repositories: Read** permission
3. Set environment variables or use command-line options:

```bash
# Linux/macOS/WSL
export BITBUCKET_USERNAME="your_username"
export BITBUCKET_APP_PASSWORD="your_app_password"

# PowerShell (Windows)
$env:BITBUCKET_USERNAME="your_username"
$env:BITBUCKET_APP_PASSWORD="your_app_password"
```

## 📖 Usage

### Workspace Scanner

Scan all repositories in a Bitbucket workspace:

```bash
./scan_workspace.sh <workspace> [options]
```

**Examples:**

```bash
# Scan a public workspace
./scan_workspace.sh atlassian

# Scan with authentication (for private repos)
./scan_workspace.sh myworkspace --username myuser --app-password xxx

# Limit number of repos and enable notifications
./scan_workspace.sh myworkspace --max-repos 10 --telegram-chat-id 123456789

# Scan multiple workspaces from a file
./scan_workspace.sh --workspaces-file workspaces.txt --telegram-chat-id 123456789

# Debug mode with detailed logging
./scan_workspace.sh myworkspace --debug
```

**Options:**

- `--workspaces-file FILE` - File containing list of workspaces (one per line)
- `--max-repos N` - Maximum repositories to scan (default: all)
- `--username USER` - Bitbucket username for authentication
- `--app-password PASS` - Bitbucket app password for authentication
- `--exclude-private` - Exclude private repositories
- `--output-dir DIR` - Custom output directory
- `--email EMAIL` - Email address for security notifications
- `--telegram-chat-id ID` - Telegram chat ID for notifications
- `--debug` - Enable debug output
- `--help` - Show help message

### Repository Scanner

Scan individual Bitbucket repositories:

```bash
./scan_repo.sh <workspace/repo> [options]
```

**Examples:**

```bash
# Scan a public repository
./scan_repo.sh atlassian/python-bitbucket

# Scan a specific commit
./scan_repo.sh myworkspace/myrepo --commit abc123def

# Scan a private repository with authentication
./scan_repo.sh myworkspace/privaterepo --username myuser --app-password xxx

# Enable notifications
./scan_repo.sh myworkspace/repo --telegram-chat-id 123456789 --debug
```

**Options:**

- `--commit HASH` - Scan only a specific commit hash
- `--output FILE` - Save results to specified JSON file
- `--username USER` - Bitbucket username for authentication
- `--app-password PASS` - Bitbucket app password for authentication
- `--no-cleanup` - Don't clean up temporary files
- `--debug` - Enable debug output
- `--email EMAIL` - Email address for security notifications
- `--telegram-chat-id ID` - Telegram chat ID for notifications
- `--help` - Show help message

## 📂 Output Structure

Scan results are organized in a timestamped directory structure:

```
bitbucket-scanner/
└── leaked_secrets_results/
    └── 20241122_143022/
        └── workspace_leaked_secrets/
            └── scan_myworkspace_20241122_143022/
                ├── myworkspace_secrets/      # Only repos with secrets
                │   ├── workspace_repo1.json
                │   └── workspace_repo2.json
                └── completion_summary_myworkspace_*.json
```

### Result Format

Each JSON file contains detailed information about discovered secrets:

```json
[
  {
    "DetectorName": "AWS",
    "DetectorType": 2,
    "Verified": true,
    "Raw": "AKIA...",
    "Redacted": "AKIA...",
    "SourceMetadata": {
      "Data": {
        "Git": {
          "commit": "abc123...",
          "file": "config.yml",
          "email": "user@example.com",
          "repository": "https://bitbucket.org/workspace/repo",
          "timestamp": "2024-01-15 10:30:00"
        }
      }
    },
    "scan_timestamp": "2024-11-22T14:30:45.123Z",
    "repository_name": "workspace/repo",
    "source": "bitbucket"
  }
]
```

## 🔔 Notifications

Configure real-time notifications when secrets are discovered. See the main [Configuration Guide](../config/README.md) for setup instructions.

**Supported notification channels:**
- Telegram Bot
- Discord Webhook
- Email (via Mailgun)

**Notification behavior:**
- **Immediate alerts** - Sent as soon as secrets are found in a repository
- **Summary alerts** - Sent when the entire scan completes (workspace scans only)

## 🎯 Use Cases

### Security Audits
Scan your organization's Bitbucket workspaces to identify accidentally committed secrets:

```bash
./scan_workspace.sh mycompany --telegram-chat-id 123456789
```

### Bug Bounty Hunting
Scan public Bitbucket repositories for leaked credentials:

```bash
./scan_workspace.sh --workspaces-file targets.txt --max-repos 20
```

### Continuous Monitoring
Set up scheduled scans with cron:

```bash
# Add to crontab (daily at 2 AM)
0 2 * * * cd /path/to/seraphix/bitbucket-scanner && ./scan_workspace.sh myworkspace --telegram-chat-id 123456789
```

### Incident Response
Quickly scan a specific repository after a security incident:

```bash
./scan_repo.sh workspace/compromised-repo --debug
```

## ⚙️ Configuration

### Worker Count

The scanner automatically detects optimal worker count based on:
- CPU cores
- Available memory
- Current system load

Workers are bounded between 1-8 for stability.

### Timeouts

Adaptive timeouts are calculated based on:
- Repository size (KB/MB/GB)
- File count
- Historical scan performance

Default values:
- Base timeout: 900s (workspace), 1200s (repo)
- Maximum timeout: 3600s (1 hour)
- Maximum retries: 2

### Environment Variables

```bash
# Bitbucket authentication
export BITBUCKET_USERNAME="your_username"
export BITBUCKET_APP_PASSWORD="your_app_password"

# Timeout overrides (optional)
export TRUFFLEHOG_BASE_TIMEOUT=900
export TRUFFLEHOG_MAX_TIMEOUT=3600
export TRUFFLEHOG_MAX_RETRIES=2
```

## 🐛 Troubleshooting

### Authentication Issues

**Problem:** `401 Unauthorized` or `403 Forbidden` errors

**Solution:**
1. Verify your app password has the correct permissions (Repositories: Read)
2. Check that username and password are set correctly
3. Try authenticating with command-line options instead of environment variables

### Clone Failures

**Problem:** Repository clone timeout or failure

**Solution:**
1. Check your internet connection
2. Verify the repository exists and is accessible
3. For large repos, increase the timeout: `export GIT_OPERATION_TIMEOUT=600`

### No Secrets Found

**Problem:** Scanner completes but finds no secrets

**Solution:**
- This is expected for clean repositories
- Verify TruffleHog is installed: `trufflehog --version`
- Run with `--debug` to see detailed scan information
- Check that repositories contain actual code (not just documentation)

### Memory Issues

**Problem:** System runs out of memory during scanning

**Solution:**
1. Reduce worker count by limiting system resources before running
2. Scan fewer repositories at a time: `--max-repos 5`
3. Use the single repository scanner for large repos

## 📊 Performance Tips

1. **Use authentication** - Avoid rate limiting by providing credentials
2. **Limit repository count** - Start with `--max-repos 10` for testing
3. **Monitor system resources** - Watch CPU and memory usage during scans
4. **Schedule scans** - Run during off-peak hours for better performance
5. **Use filters** - Exclude private repos if not needed: `--exclude-private`

## 🔗 Related Documentation

- [Main README](../README.md) - Project overview and GitHub scanners
- [Configuration Guide](../config/README.md) - Notification setup
- [Analyzer Documentation](../analyzer/README.md) - Results analysis and dashboard

## ⚠️ Important Notes

### Rate Limiting

Bitbucket API has the following rate limits:
- **Authenticated requests:** 1,000 requests per hour
- **Unauthenticated requests:** 60 requests per hour

Always use authentication for workspace scanning to avoid hitting rate limits.

### Repository Access

- **Public repositories:** Accessible without authentication
- **Private repositories:** Require authentication with valid app password
- **Permissions needed:** Repositories: Read

### Legal and Ethical Use

This tool is intended exclusively for:
- ✅ Authorized security assessments
- ✅ Bug bounty programs with proper scope
- ✅ Your own organization's repositories
- ✅ Compliance and audit purposes

Always obtain explicit permission before scanning repositories you don't own.

## 🤝 Contributing

Contributions are welcome! Areas for improvement:
- Additional Bitbucket API features
- Performance optimizations
- Enhanced filtering options
- Better error handling

## 📜 License

This project is licensed under the GNU Affero General Public License v3.0. See [LICENSE](../LICENSE) for details.
