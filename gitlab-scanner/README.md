# 🦊 GitLab Scanner

Scan GitLab repositories and groups for leaked secrets using TruffleHog.

## 🎯 Features

- **Repository Scanning** - Scan individual GitLab projects
- **Group Scanning** - Scan all projects in a GitLab group (including subgroups)
- **🔄 Infinite Scanner** - Continuously scan public GitLab projects with automatic state management
- **Self-Hosted GitLab Support** - Works with gitlab.com and self-hosted instances
- **Multi-Worker Parallel Scanning** - Automatically optimized based on system resources
- **Smart Filtering** - Exclude archived projects and forks by default
- **Real-time Notifications** - Get instant alerts via Telegram, Discord, or email
- **Adaptive Timeouts** - Automatically adjusts scan timeouts based on repository size

---

## 🚀 Quick Start

### Prerequisites

Install dependencies if not already done:
```bash
cd ..
./install_requirements.sh
```

### Configure GitLab Token (Highly Recommended)

**⚠️ IMPORTANT for Infinite Scanner**: You NEED a token to avoid rate limiting!

**Rate Limits:**
- Without token: 300 requests/hour (too low for scanning)
- With token: 5,000+ requests/hour

For any serious scanning (especially infinite scanner), create a GitLab Personal Access Token:

1. Go to **User Settings > Access Tokens** on your GitLab instance
2. Create a token with `read_api` and `read_repository` scopes
3. Set it as an environment variable:

```bash
# Linux/macOS/WSL
export GITLAB_TOKEN="glpat-your_token_here"

# PowerShell (Windows)
$env:GITLAB_TOKEN="glpat-your_token_here"
```

Without authentication, you can only access public projects.

---

## 🔄 Infinite Scanner (NEW!)

Continuously scan public GitLab projects for leaked secrets.

### Quick Start

```bash
# 1. Fetch public projects
./fetch_public_projects.sh --min-stars 10

# 2. Start infinite scanner
./infinite_scan.sh --telegram-chat-id 123456789
```

The infinite scanner:
- ✅ Automatically fetches public GitLab projects
- ✅ Saves progress and resumes if interrupted
- ✅ Sends real-time notifications
- ✅ Skips already-scanned projects
- ✅ Tracks total secrets found

📖 **[Full Infinite Scanner Guide](INFINITE_SCANNER.md)** - Complete documentation

---

## 📝 Repository Scanner

Scan individual GitLab projects for secrets.

### Basic Usage

```bash
# Scan a project on gitlab.com
./scan_repo.sh gitlab-org/gitlab

# Scan a specific commit
./scan_repo.sh mygroup/myproject --commit abc1234

# Scan with debug output
./scan_repo.sh mygroup/myproject --debug
```

### Self-Hosted GitLab

```bash
# Scan a project on self-hosted GitLab
./scan_repo.sh mygroup/myproject \
  --gitlab-url https://gitlab.example.com \
  --gitlab-token glpat-xxx
```

### With Notifications

```bash
# Get notified when secrets are found
./scan_repo.sh mygroup/myproject \
  --email security@company.com \
  --telegram-chat-id 123456789
```

### Options

| Option | Description |
|--------|-------------|
| `--gitlab-url URL` | GitLab instance URL (default: https://gitlab.com) |
| `--gitlab-token TOKEN` | GitLab API token (or use `GITLAB_TOKEN` env var) |
| `--commit HASH` | Scan specific commit |
| `--output FILE` | Custom output file path |
| `--debug` | Enable verbose logging |
| `--email EMAIL` | Email for notifications |
| `--telegram-chat-id ID` | Telegram chat ID for notifications |
| `--no-cleanup` | Keep temporary files |

---

## 🏢 Group Scanner

Scan all projects in a GitLab group, including subgroups by default.

### Basic Usage

```bash
# Scan all projects in a group
./scan_group.sh gitlab-org

# Limit number of projects
./scan_group.sh gitlab-org --max-repos 10

# Exclude subgroups
./scan_group.sh gitlab-org --no-subgroups
```

### Advanced Filtering

```bash
# Include archived projects (excluded by default)
./scan_group.sh mygroup --include-archived

# Include forked projects (excluded by default)
./scan_group.sh mygroup --include-forks

# Scan EVERYTHING (including archived and forks)
./scan_group.sh mygroup --scan-all
```

### Self-Hosted GitLab

```bash
# Scan a group on self-hosted instance
./scan_group.sh mygroup \
  --gitlab-url https://gitlab.example.com \
  --gitlab-token glpat-xxx
```

### Batch Scanning

Scan multiple groups from a file:

```bash
# Create a file with group names (one per line)
cat > groups.txt << EOF
gitlab-org
gitlab-com
my-company-group
EOF

# Scan all groups
./scan_group.sh --groups-file groups.txt \
  --telegram-chat-id 123456789 \
  --max-repos 20
```

### With Notifications

```bash
# Get real-time alerts as secrets are found
./scan_group.sh mygroup \
  --email security@company.com \
  --telegram-chat-id 123456789 \
  --debug
```

### Options

| Option | Description |
|--------|-------------|
| `--groups-file FILE` | File containing list of groups (one per line) |
| `--max-repos N` | Maximum projects to scan (default: all) |
| `--gitlab-url URL` | GitLab instance URL (default: https://gitlab.com) |
| `--gitlab-token TOKEN` | GitLab API token (or use `GITLAB_TOKEN` env var) |
| `--include-forks` | Include forked projects (excluded by default) |
| `--include-archived` | Include archived projects (excluded by default) |
| `--scan-all` | Scan ALL projects (includes forks and archived) |
| `--no-subgroups` | Don't include subgroups (includes by default) |
| `--output-dir DIR` | Custom output directory |
| `--email EMAIL` | Email for security notifications |
| `--telegram-chat-id ID` | Telegram chat ID for notifications |
| `--debug` | Enable debug output |
| `--no-cleanup` | Keep temporary files |

---

## 📊 Output Format

Results are saved in JSON format with the following structure:

```json
[
  {
    "SourceMetadata": {
      "Data": {
        "Git": {
          "commit": "abc123...",
          "file": "config/secrets.yml",
          "repository": "https://gitlab.com/mygroup/myproject",
          "timestamp": "2023-01-15 10:30:00 +0000"
        }
      }
    },
    "DetectorName": "AWS",
    "DetectorDescription": "AWS credentials...",
    "Verified": true,
    "Raw": "AKIA...",
    "scan_timestamp": "2025-11-23T12:00:00.000Z",
    "repository_name": "mygroup/myproject",
    "source": "gitlab"
  }
]
```

### Output Directory Structure

```
leaked_secrets_results/
└── 20251123_120000/
    ├── gitlab_scan_mygroup_myproject_20251123_120000.json
    └── group_leaked_secrets/
        └── scan_gitlab-org_20251123_120000/
            ├── gitlab-org_gitlab_secrets/
            │   ├── project1.json
            │   └── project2.json
            └── completion_summary_gitlab-org_1234567890.json
```

---

## ⚙️ Configuration

### Notification Setup

Configure notifications to get instant alerts when secrets are found:

**Telegram:**
```bash
cp ../config/telegram_config.sh.example ../config/telegram_config.sh
# Edit and add your bot token and chat ID
```

**Discord:**
```bash
cp ../config/discord_config.sh.example ../config/discord_config.sh
# Edit and add your webhook URL
```

**Email (Mailgun):**
```bash
cp ../config/mailgun_config.sh.example ../config/mailgun_config.sh
# Edit and add your Mailgun credentials
```

See the [main configuration guide](../config/README.md) for detailed setup instructions.

### Dynamic Resource Management

The scanner automatically detects and optimizes based on:
- CPU cores available
- System memory
- Current system load
- Repository size and complexity

This ensures optimal performance without overloading your system.

---

## 🔍 Common Use Cases

### Scan a Single Project
```bash
./scan_repo.sh mygroup/myproject --debug
```

### Audit an Entire Group
```bash
./scan_group.sh mygroup --telegram-chat-id 123456789
```

### Scan Self-Hosted GitLab
```bash
export GITLAB_TOKEN="glpat-your-token"
./scan_group.sh internal-projects \
  --gitlab-url https://gitlab.company.com \
  --max-repos 50
```

### Continuous Security Monitoring
```bash
# Create a cron job to scan regularly
0 */6 * * * cd /path/to/seraphix/gitlab-scanner && ./scan_group.sh mygroup --telegram-chat-id 123456789
```

### Bug Bounty Hunting
```bash
# Scan multiple public groups
cat > targets.txt << EOF
gitlab-org
gitlab-com
company1-group
company2-group
EOF

./scan_group.sh --groups-file targets.txt --max-repos 20
```

---

## 🐛 Troubleshooting

### Authentication Errors

If you see "401 Unauthorized":
- Verify your GitLab token is valid
- Check token has `read_api` and `read_repository` scopes
- For self-hosted GitLab, ensure the URL is correct

### Rate Limiting

GitLab API has rate limits. If you hit them:
- Use `--max-repos` to limit projects scanned
- Add delays between batch operations
- Use a dedicated API token with higher limits

### Large Repositories

For very large repositories:
- The scanner automatically adjusts timeouts
- Use `--debug` to see timeout adjustments
- Consider scanning specific commits instead

### No Projects Found

If a group scan finds 0 projects:
- Verify the group name is correct
- Check you have access (use `--gitlab-token`)
- Try `--include-subgroups` (enabled by default)
- Use `--debug` to see API responses

---

## 📚 Related Documentation

- [Main README](../README.md) - Project overview
- [Configuration Guide](../config/README.md) - Notification setup
- [Analyzer Documentation](../analyzer/README.md) - Analyzing results

---

## 💡 Tips

1. **Start Small**: Test with `--max-repos 5` before scanning large groups
2. **Use Filters**: Exclude archived/forked projects to focus on active code
3. **Enable Notifications**: Get real-time alerts instead of checking logs
4. **Debug Mode**: Use `--debug` to understand what's happening
5. **Self-Hosted**: Works great with GitLab CE/EE instances

---

## 🤝 Contributing

Found a bug or have a feature request? Please open an issue on GitHub!

---

## 📜 License

This project is licensed under the GNU Affero General Public License v3.0 - see [LICENSE](../LICENSE) for details.
