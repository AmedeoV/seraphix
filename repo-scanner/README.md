# Repository Scanner

Tools for scanning individual GitHub repositories for secrets and sensitive data.

## Scripts
- `scan_repo_simple.sh` - Recommended scanner with adaptive timeouts and retry logic
- `scan_repo.sh` - Full-featured scanner with advanced options

## Installation

```bash
# From project root
./install_requirements.sh
```

## Quick Start

```bash
# Basic scan
./scan_repo_simple.sh owner/repository

# With notifications
./scan_repo_simple.sh --email security@company.com --telegram-id 123456789 owner/repo

# Debug mode
./scan_repo_simple.sh --debug owner/repository
```

## Options

**scan_repo_simple.sh:**
- `--output FILE` - Custom output file
- `--commit HASH` - Scan specific commit
- `--timeout N` - Base timeout in seconds
- `--debug` - Enable debug logging
- `--email EMAIL` - Email notifications (requires `config/mailgun_config.sh`)
- `--telegram-id ID` - Telegram notifications (requires `config/telegram_config.sh`)
- `--no-cleanup` - Keep temporary files

**scan_repo.sh:**
- `--branch NAME` - Scan specific branch
- `--temp-dir DIR` - Custom temporary directory
- Additional options similar to scan_repo_simple.sh

## Output

Results saved to `leaked_secrets_results/YYYYMMDD_HHMMSS/`
Debug logs saved to `scan_logs/` (when `--debug` enabled)