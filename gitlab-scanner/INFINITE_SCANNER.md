# 🔄 Infinite GitLab Scanner

Continuously scan public GitLab projects for leaked secrets with automatic state management and resumption.

## 🚀 Quick Start

### Step 0: Create GitLab Token (Highly Recommended)

**Why you need a token:**
- **Without token**: 300 requests/hour → You'll hit limits after ~3 projects
- **With token**: 5,000+ requests/hour → Scan hundreds of projects

Create a token at: https://gitlab.com/-/user_settings/personal_access_tokens
- **Scopes needed**: `read_api`, `read_repository`
- **Expiration**: Set to your preference (30 days, 90 days, etc.)

```bash
export GITLAB_TOKEN="glpat-your-token-here"
```

### Step 1: Fetch Public Projects

```bash
# Fetch public projects from GitLab.com
./fetch_public_projects.sh

# Fetch with minimum star count (more popular projects)
./fetch_public_projects.sh --min-stars 10

# Fetch more pages (more projects)
./fetch_public_projects.sh --max-pages 100 --min-stars 5

# For self-hosted GitLab
./fetch_public_projects.sh --gitlab-url https://gitlab.example.com
```

This creates:
- `public_projects.txt` - List of projects to scan
- `public_groups.txt` - List of popular groups

### Step 2: Start Infinite Scanner

**⚠️ IMPORTANT: Set GitLab Token First!**

Without a token, you'll hit rate limits quickly (300 requests/hour for unauthenticated).
With a token, you get 5,000+ requests/hour.

```bash
# RECOMMENDED: Set token first to avoid rate limiting
export GITLAB_TOKEN="glpat-your-token"
./infinite_scan.sh --telegram-chat-id 123456789

# Basic scan (NOT RECOMMENDED - will hit rate limits)
./infinite_scan.sh

# With notifications and email
export GITLAB_TOKEN="glpat-your-token"
./infinite_scan.sh --telegram-chat-id 123456789 --email security@company.com

# Custom delay between scans
./infinite_scan.sh --delay 5 --telegram-chat-id 123456789
```

### Step 3: Monitor Progress

The scanner automatically:
- ✅ Saves progress after each scan
- ✅ Resumes from where it left off if interrupted
- ✅ Skips previously scanned projects
- ✅ Tracks total secrets found
- ✅ Sends real-time notifications

Press `Ctrl+C` to stop gracefully - state is saved automatically!

---

## 📊 State Management

The scanner maintains state in `scan_state.json`:

```json
{
  "last_updated": "2025-11-23T12:00:00.000Z",
  "total_scanned": 42,
  "total_skipped": 5,
  "total_secrets_found": 8,
  "scanned_projects": [...],
  "skipped_projects": [...]
}
```

### Resume After Interruption

Just run the scanner again - it automatically resumes:
```bash
./infinite_scan.sh --telegram-chat-id 123456789
```

### Start Fresh

Delete the state file to reset:
```bash
rm scan_state.json
./infinite_scan.sh
```

---

## 🎯 Advanced Usage

### Scan Only High-Value Projects

```bash
# Fetch popular projects (10+ stars)
./fetch_public_projects.sh --min-stars 10 --max-pages 50

# Start scanning
./infinite_scan.sh --telegram-chat-id 123456789
```

### Run in Background

```bash
# Start in background with nohup
nohup ./infinite_scan.sh --telegram-chat-id 123456789 > infinite_scan.log 2>&1 &

# Check progress
tail -f infinite_scan.log

# Stop scanner
pkill -f infinite_scan.sh
```

### Custom Project List

```bash
# Create your own list
cat > my_targets.txt << EOF
gitlab-org/gitlab
gitlab-org/gitlab-runner
company/project1
company/project2
EOF

# Scan custom list
./infinite_scan.sh --projects-file my_targets.txt --telegram-chat-id 123456789
```

---

## 📈 Monitoring

### Real-Time Progress

The scanner shows:
- Current project being scanned
- Total projects scanned in current cycle
- Projects skipped (already scanned)
- Total secrets found across all scans
- Progress updates every 10 projects

### Example Output

```
🔄 Starting scan cycle #1
🔄 Scanning: gitlab-org/gitlab
✅ Successfully scanned gitlab-org/gitlab (Total: 1)
🔑 Found 2 secret(s) in gitlab-org/gitlab! (Total: 2)
📊 Progress: 10 scanned, 0 skipped
...
✅ Completed scan cycle #1
```

---

## 🔧 Configuration Options

### Fetch Script

| Option | Default | Description |
|--------|---------|-------------|
| `--gitlab-url` | https://gitlab.com | GitLab instance URL |
| `--max-pages` | 50 | Maximum API pages to fetch |
| `--min-stars` | 0 | Minimum star count filter |
| `--output` | public_projects.txt | Output file path |

### Infinite Scanner

| Option | Default | Description |
|--------|---------|-------------|
| `--projects-file` | public_projects.txt | Projects list file |
| `--delay` | 3 | Seconds between scans |
| `--gitlab-token` | - | API token (optional) |
| `--telegram-chat-id` | - | Telegram chat ID |
| `--email` | - | Email address |

---

## 🎪 Use Cases

### 1. Bug Bounty Hunting
```bash
# Fetch popular projects in bug bounty programs
./fetch_public_projects.sh --min-stars 20 --max-pages 100
./infinite_scan.sh --telegram-chat-id 123456789
```

### 2. Continuous Monitoring
```bash
# Set up cron job for daily updates
0 0 * * * cd /path/to/gitlab-scanner && ./fetch_public_projects.sh --min-stars 10
0 1 * * * cd /path/to/gitlab-scanner && ./infinite_scan.sh --telegram-chat-id 123456789
```

### 3. Self-Hosted GitLab Audit
```bash
# Scan internal GitLab instance
export GITLAB_TOKEN="glpat-xxx"
./fetch_public_projects.sh --gitlab-url https://gitlab.company.com
./infinite_scan.sh --telegram-chat-id 123456789
```

---

## 🛡️ Best Practices

1. **Start Small**: Test with `--max-pages 10` first
2. **Use Tokens**: Set `GITLAB_TOKEN` to avoid rate limits
3. **Enable Notifications**: Get alerts for immediate response
4. **Monitor Progress**: Check `scan_state.json` regularly
5. **Run in Background**: Use `nohup` for long-running scans
6. **Filter by Stars**: Use `--min-stars` to focus on active projects

---

## 🐛 Troubleshooting

### "Projects file not found"
Run `./fetch_public_projects.sh` first to generate the project list.

### Rate Limiting
Set `GITLAB_TOKEN` environment variable:
```bash
export GITLAB_TOKEN="glpat-your-token"
```

### Scanner Stops
Check `scan_state.json` - it saves progress automatically. Just restart.

### No Projects Found
Increase `--max-pages` or decrease `--min-stars`:
```bash
./fetch_public_projects.sh --max-pages 100 --min-stars 0
```

---

## 📂 Files Created

```
gitlab-scanner/
├── fetch_public_projects.sh    # Fetch public projects
├── infinite_scan.sh             # Infinite scanner
├── public_projects.txt          # Projects list (generated)
├── public_groups.txt            # Groups list (generated)
├── scan_state.json              # Scanner state (generated)
└── leaked_secrets_results/      # Scan results
    └── YYYYMMDD_HHMMSS/
        └── gitlab_scan_*.json
```

---

## 🚀 Full Example

```bash
# 1. Fetch popular projects
./fetch_public_projects.sh --min-stars 10 --max-pages 50

# 2. Review the list
head -20 public_projects.txt

# 3. Start scanning with notifications
export GITLAB_TOKEN="glpat-your-token"
./infinite_scan.sh --telegram-chat-id 123456789 --email security@company.com

# 4. Monitor in another terminal
watch -n 5 'tail -20 infinite_scan.log'

# 5. Check state
cat scan_state.json | jq '.total_secrets_found'
```

---

## 🔗 Related Documentation

- [Main README](README.md) - GitLab scanner overview
- [Quick Reference](QUICK_REFERENCE.md) - Command reference
- [Configuration](../config/README.md) - Notification setup

---

**Happy Hunting! 🦊**
