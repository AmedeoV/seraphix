# Repository Scanner

Tools for scanning individual GitHub repositories for secrets and sensitive data.

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

- `--output FILE` - Custom output file
- `--commit HASH` - Scan specific commit
- `--timeout N` - Base timeout in seconds
- `--debug` - Enable debug logging
- `--email EMAIL` - Email notifications (requires `config/mailgun_config.sh`)
- `--telegram-id ID` - Telegram notifications (requires `config/telegram_config.sh`)
- `--no-cleanup` - Keep temporary files

## Output

Results saved to `leaked_secrets_results/YYYYMMDD_HHMMSS/`
Debug logs saved to `scan_logs/` (when `--debug` enabled)