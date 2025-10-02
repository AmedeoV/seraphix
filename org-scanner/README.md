# Organization Scanner

Scan entire GitHub organizations for secrets using TruffleHog. Queries GitHub APIs directly—no database required.

## Quick Start

```bash
# Install dependencies first
../install_requirements.sh

# Basic scan
./scan_org.sh <organization>

# Common options
./scan_org.sh microsoft --max-repos 10 --telegram-chat-id 123456789
./scan_org.sh microsoft --exclude-forks --email security@company.com
./scan_org.sh microsoft --max-workers 4 --debug
```

## Key Features
- Auto-detects system resources for optimal performance
- Adaptive timeouts based on repository size
- Real-time notifications (Email + Telegram)
- Parallel scanning with worker processes
- Automatic retry logic for failed scans

## Options
| Option | Description |
|--------|-------------|
| `--max-repos N` | Limit repositories to scan |
| `--max-workers N` | Parallel workers (default: auto) |
| `--timeout SEC` | Base timeout (default: 900s) |
| `--github-token` | GitHub API token |
| `--exclude-forks` | Skip forked repositories |
| `--email` | Email for notifications |
| `--telegram-chat-id` | Telegram chat ID |
| `--debug` | Verbose logging |

## Environment Variables
- `GITHUB_TOKEN` - GitHub API token (recommended for higher rate limits)

## Output
Results: `leaked_secrets_results/TIMESTAMP/org_leaked_secrets/scan_ORG_TIMESTAMP/`  
Debug logs: `scan_logs/org_scan_ORG_TIMESTAMP.log` (when `--debug` enabled)