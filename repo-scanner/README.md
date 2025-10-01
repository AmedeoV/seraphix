# Repository Scanner

This directory contains tools for scanning individual GitHub repositories and specific commits.

## Overview
The repository scanner provides focused scanning capabilities for individual repositories, specific commits, or branches. This is perfect for targeted analysis and verification of specific findings.

## Main Scripts
- `scan_repo_simple.sh` - Simplified repository scanner with better error handling
- `scan_repo.sh` - Full-featured repository scanner

## Key Features
- **Repository-specific**: Focus on individual repositories
- **Commit-level scanning**: Scan specific commits or commit ranges
- **Branch support**: Scan specific branches
- **Fast execution**: Lightweight with minimal dependencies

## Installation

Before using the Repository Scanner, install the required dependencies:

```bash
# From the project root (recommended)
./install_requirements.sh

# Or install specific components
./install_requirements.sh --python-only     # Python packages only
./install_requirements.sh --trufflehog-only # TruffleHog only
./install_requirements.sh --help            # Show all options
```

## Usage Examples

### Basic Repository Scanning
```bash
# Scan a repository
./scan_repo_simple.sh owner/repository

# Scan with custom output file
./scan_repo_simple.sh --output results.json owner/repository

# Scan with debug output
./scan_repo_simple.sh --debug owner/repository

# Scan with custom timeout
./scan_repo_simple.sh --timeout 1800 owner/repository

# Scan with notifications
./scan_repo_simple.sh --email security@company.com --telegram-id 123456789 owner/repository
```

### Advanced Repository Scanning
```bash
# Full-featured scanning
./scan_repo.sh --branch main --since commit_hash owner/repository

# Scan with custom temp directory
./scan_repo.sh --temp-dir /tmp/scan_temp owner/repository
```

## Configuration Options

### scan_repo_simple.sh
- `--output FILE`: Output file path
- `--temp-dir DIR`: Temporary directory for cloning
- `--commit HASH`: Specific commit to scan
- `--timeout N`: Base timeout in seconds (adaptive timeout used)
- `--debug`: Enable debug output (saves to scan_logs/) with timeout details
- `--no-cleanup`: Keep temporary files
- `--email EMAIL`: Email address for security notifications
- `--telegram-id ID`: Telegram chat ID for security notifications

### scan_repo.sh
- `--output FILE`: Output file path
- `--commit HASH`: Specific commit to scan
- `--timeout N`: Timeout in seconds (uses config/timeout_config.sh)
- `--no-cleanup`: Keep temporary files

## Advanced Features
- **Adaptive Timeouts** (scan_repo_simple.sh): Automatically adjusts scan timeouts based on repository size and file count
- **Retry Logic** (scan_repo_simple.sh): Failed scans are retried with progressively longer timeouts
- **Configuration**: All scripts support `config/timeout_config.sh` for customizable timeout settings
- **Real-time Notifications**: Immediate email/Telegram alerts when secrets are discovered

## Notifications
The `scan_repo_simple.sh` script supports real-time notifications when secrets are found:

```bash
# Email notifications
./scan_repo_simple.sh --email security@company.com owner/repo

# Telegram notifications
./scan_repo_simple.sh --telegram-id 123456789 owner/repo

# Both email and Telegram
./scan_repo_simple.sh --email security@company.com --telegram-id 123456789 owner/repo
```

**Setup Requirements:**
- Email: Configure `config/mailgun_config.sh` with Mailgun API credentials
- Telegram: Configure `config/telegram_config.sh` with bot token and default chat ID
- The notification script `send_notifications_enhanced.sh` handles both channels

## Output
Results are saved in the local `leaked_secrets_results/` directory with timestamped subdirectories. Each scan creates JSON files containing detailed information about any secrets or sensitive data found in the scanned repositories.

**Output structure:**
```
repo-scanner/
├── leaked_secrets_results/
│   └── YYYYMMDD_HHMMSS/
│       ├── simple_scan_owner_repo_timestamp.json
│       └── scan_owner_repo_full_timestamp.json
└── scan_logs/              # Debug logs (when --debug enabled)
    ├── simple_scan_owner_repo_TIMESTAMP.log
    └── [other scan log files]
```