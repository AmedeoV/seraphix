# 🔥 Force Push Scanner

Hunt for secrets in dangling commits created by `git push --force` operations. Uses a pre-built SQLite database of force push events from GHArchive.

---

## 🚀 Quick Start

### 1. Download the Database

Get the Force Push Commits database via Google Form: **<https://forms.gle/344GbP6WrJ1fhW2A6>**

This database contains force push commits for all GitHub organizations, updated daily at 2 PM EST.

### 2. Install Dependencies (if not already done)

```bash
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

---

## ⚙️ Options

| Option | Description |
|--------|-------------|
| `--resume` | Resume previous scan from state file |
| `--restart` | Start fresh (ignore previous state) |
| `--order` | Order organizations: `random`, `latest` |
| `--telegram-chat-id ID` | Telegram chat ID for notifications |
| `--debug` | Enable verbose logging |
| `--db-file PATH` | Use custom database file |

---

## 📂 Output

**Directory Structure:**
```
leaked_secrets_results/
  scan_20251003_140530/          # Scan started Oct 3 at 14:05:30
    2025-10-03/                  # Secrets found on Oct 3
      organization1/
        verified_secrets_organization1.json
      organization2/
        verified_secrets_organization2.json
    2025-10-04/                  # Secrets found on Oct 4
      organization3/
        verified_secrets_organization3.json
```

Results are organized by:
- **Scan start time** (top level) - when the scan began
- **Discovery date** (subdirectories) - when secrets were actually found

This makes it easy to check what was discovered "today" even during long-running scans!

**View Today's Findings:**
```bash
./view_daily_findings.sh              # Show today's findings
./view_daily_findings.sh 2025-10-03   # Show specific date
```

**Logs:** `scan_logs/` (when `--debug` enabled)

**State File:** `scan_state.json` - Tracks progress for resume functionality