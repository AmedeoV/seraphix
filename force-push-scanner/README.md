# Force Push Scanner

Database-driven scanner for detecting secrets in force-pushed commits. Uses SQLite to track organizations and repositories with resume capabilities.

## Quick Start

### 1. Get the Force Push Database

Download the Force Push Commits SQLite DB via Google Form: <https://forms.gle/344GbP6WrJ1fhW2A6>

This database contains force push commits for all GitHub organizations, updated daily at 2 PM EST.

**Alternative:** Use the BigQuery public table if you prefer querying yourself (see main README).

### 2. Install Dependencies

```bash
# From the force-push-scanner directory
../install_requirements.sh
```

### 3. Run the Scanner

```bash
# Scan all organizations in database
./force_push_secret_scanner.sh

# Scan specific organization
./force_push_secret_scanner.sh microsoft --telegram-chat-id 123456789

# Resume previous scan
./force_push_secret_scanner.sh --resume
```

## Key Features
- SQLite database for organization/repository management
- Resume interrupted scans with state tracking
- Parallel organization and repository processing
- Real-time notifications (Email + Telegram)
- Adaptive timeouts with retry logic

## Common Options
| Option | Description |
|--------|-------------|
| `--resume` | Resume previous scan from state file |
| `--restart` | Start fresh (ignore previous state) |
| `--order` | Order organizations: 'random', 'latest' |
| `--telegram-chat-id ID` | Telegram chat ID for notifications |
| `--debug` | Enable verbose logging |
| `--db-file PATH` | Use custom database file |

## Database
- `force_push_commits.sqlite3` - Contains organizations and repositories
- `scan_state.json` - Tracks scan progress for resume functionality

## Output
Results: `leaked_secrets_results/TIMESTAMP/ORGANIZATION/verified_secrets_ORG.json`  
Debug logs: `scan_logs/` (when debug enabled)