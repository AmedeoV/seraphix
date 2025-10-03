# 🏢 Organization Scanner

Scan entire GitHub organizations for secrets using TruffleHog. Queries GitHub API directly—**no database required**.

---

## 🚀 Quick Start

### 1. Install Dependencies (if not already done)

```bash
../install_requirements.sh
```

### 2. Run the Scanner

```bash
# Single organization scan
./scan_org.sh <organization>

# Batch scan from file
./scan_org.sh --orgs-file organizations.txt

# With options
./scan_org.sh microsoft --max-repos 10 --telegram-chat-id 123456789
./scan_org.sh microsoft --exclude-forks --email security@company.com
./scan_org.sh --orgs-file bug_bounty_orgs.txt --telegram-chat-id 123456789
```

---

## ⚙️ Options

| Option | Description |
|--------|-------------|
| `--orgs-file FILE` | File with organizations list (one per line, supports # comments) |
| `--max-repos N` | Limit repositories to scan |
| `--max-workers N` | Parallel workers (default: auto-detected) |
| `--timeout SEC` | Base timeout seconds (default: 900) |
| `--github-token TOKEN` | GitHub API token for higher rate limits |
| `--exclude-forks` | Skip forked repositories |
| `--email EMAIL` | Email for notifications |
| `--telegram-chat-id ID` | Telegram chat ID for notifications |
| `--debug` | Enable verbose logging |

**Environment Variables:**
- `GITHUB_TOKEN` - GitHub API token (recommended for private repos and higher rate limits)

---

## 📝 Organizations File Format

The `--orgs-file` option accepts a text file with one organization per line:

```text
# Bug Bounty Programs
microsoft
google
github

# Security Research Targets
netflix
uber
```

- One organization name per line
- Lines starting with `#` are treated as comments
- Empty lines are ignored
- Whitespace is automatically trimmed

---

## 📂 Output

**Single Organization:** `leaked_secrets_results/TIMESTAMP/org_leaked_secrets/scan_ORG_TIMESTAMP/`  
**Batch Scan:** `leaked_secrets_results/TIMESTAMP/org_leaked_secrets/scan_ORG_TIMESTAMP/` (separate folder per org)  
**Logs:** `scan_logs/org_scan_ORG_TIMESTAMP.log` (when `--debug` enabled)