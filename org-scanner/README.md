# 🏢 Organization Scanner

Scan entire GitHub organizations for secrets using TruffleHog. Queries GitHub API directly—**no database required**.

---

## 🚀 Quick Start

```bash
# Install dependencies (if not already done)
../install_requirements.sh

# Basic scan
./scan_org.sh <organization>

# With options
./scan_org.sh microsoft --max-repos 10 --telegram-chat-id 123456789
./scan_org.sh microsoft --exclude-forks --email security@company.com
```

---

## ⚙️ Options

| Option | Description |
|--------|-------------|
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

## 📂 Output

**Results:** `leaked_secrets_results/TIMESTAMP/org_leaked_secrets/scan_ORG_TIMESTAMP/`  
**Logs:** `scan_logs/org_scan_ORG_TIMESTAMP.log` (when `--debug` enabled)