# Organization Scanner

This directory contains tools for scanning entire GitHub organizations without requiring a database.

## Overview
The organization scanner directly queries GitHub APIs to discover and scan repositories within specified organizations. This is ideal for ad-hoc scanning and exploration.

## Main Script
- `scan_org.sh` - Main organization scanning script

## Supporting Files
- `send_notifications_enhanced.sh` - Enhanced notification system for sending alerts

## Key Features
- **No database required**: Directly queries GitHub APIs
- **Dynamic discovery**: Automatically discovers all repositories in an organization
- **Resource-aware**: Automatically detects system resources for optimal performance
- **Flexible filtering**: Can exclude forks and limit repository count
- **Real-time notifications**: Supports email and Telegram notifications

## Installation

Before using the Organization Scanner, install the required dependencies:

```bash
# From the project root (recommended)
./install_requirements.sh

# Or install specific components
./install_requirements.sh --python-only     # Python packages only
./install_requirements.sh --trufflehog-only # TruffleHog only
./install_requirements.sh --help            # Show all options
```

## Usage Examples

```bash
# Scan a specific organization
./scan_org.sh microsoft

# Scan with debug output
./scan_org.sh --debug microsoft

# Scan with custom worker count
./scan_org.sh --workers 8 microsoft

# Scan excluding forks
./scan_org.sh --exclude-forks microsoft

# Scan with custom output directory
./scan_org.sh --output-dir /tmp/scan_results microsoft

# Limit number of repositories
./scan_org.sh --max-repos 50 microsoft

# Enable email notifications
./scan_org.sh --email user@example.com microsoft

# Enable Telegram notifications
./scan_org.sh --telegram-id 123456789 microsoft
```

## Configuration Options
- `--workers N`: Number of parallel workers (default: auto-detected)
- `--timeout N`: Base timeout in seconds (default: 900, adaptive timeout used)
- `--exclude-forks`: Skip forked repositories
- `--max-repos N`: Limit number of repositories to scan
- `--output-dir DIR`: Custom output directory
- `--github-token TOKEN`: GitHub API token (overrides GITHUB_TOKEN environment variable)
- `--email EMAIL`: Email address for notifications
- `--telegram-id ID`: Telegram chat ID for notifications
- `--debug`: Enable verbose logging with adaptive timeout details

## Environment Variables
- `GITHUB_TOKEN`: GitHub Personal Access Token for API access (recommended for higher rate limits)

## Advanced Features
- **Adaptive Timeouts**: Automatically adjusts scan timeouts based on repository size and complexity
- **Retry Logic**: Failed scans are retried with progressively longer timeouts
- **Configuration**: Uses `config/timeout_config.sh` for customizable timeout settings

## Output
Results are stored in the local `leaked_secrets_results/` directory with timestamped subdirectories and organization-specific structure.

**Output structure:**
```
org-scanner/
├── leaked_secrets_results/
│   └── YYYYMMDD_HHMMSS/
│       └── org_leaked_secrets/
│           └── scan_ORGANIZATION_TIMESTAMP/
│               ├── verified_secrets_ORGANIZATION.json
│               └── individual repository results
└── scan_logs/              # Debug logs (when --debug enabled)
    └── org_scan_ORGANIZATION_TIMESTAMP.log
```