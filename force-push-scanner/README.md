# Force Push Scanner

This directory contains the database-driven scanning system for force-push secret detection.

## Overview
The Force Push scanner uses a SQLite database to track organizations and their repositories, providing efficient scanning with resume capabilities and parallel processing.

## Main Script
- `force_push_secret_scanner.sh` - Main scanning script with SQLite database integration

## Supporting Files
- `force_push_scanner.py` - Python scanner backend
- `force_push_commits.sqlite3` - SQLite database (contains org and repo data)
- `scan_state.json` - Scan state tracking for resume functionality
- `send_notifications_enhanced.sh` - Enhanced notification system

## Key Features
- **Database-driven**: Uses SQLite to manage organizations and repositories
- **Resume capability**: Can resume interrupted scans using state files
- **Parallel processing**: Supports parallel organization and repository scanning
- **Notification system**: Email and Telegram notifications for findings  
- **Star-based ordering**: Can order organizations by GitHub stars
- **Advanced timeout management**: Adaptive timeouts with retry logic and configuration support
- **Resume capability**: Can resume interrupted scans using state files

## Usage Examples

```bash
# Basic scan of all organizations in database
./force_push_secret_scanner.sh

# Scan specific organization
./force_push_secret_scanner.sh microsoft

# Parallel scanning with 4 organizations at once
./force_push_secret_scanner.sh --parallel-orgs 4

# Resume previous scan
./force_push_secret_scanner.sh --resume

# Restart from beginning
./force_push_secret_scanner.sh --restart

# Debug mode
./force_push_secret_scanner.sh --debug

# Custom database file
./force_push_secret_scanner.sh --db-file /path/to/custom.sqlite3
```

## Installation

Before using the Force Push Scanner, install the required dependencies:

```bash
# From the project root (recommended)
./install_requirements.sh

# Or install specific components
./install_requirements.sh --python-only     # Python packages only
./install_requirements.sh --trufflehog-only # TruffleHog only
./install_requirements.sh --help            # Show all options
```

## Configuration
The script reads organizations from the SQLite database and can be configured with various options for parallelization, notifications, and output directories.

## Output
Results are stored in the local `leaked_secrets_results/` directory with timestamped subdirectories and organization-specific structure.

**Output structure:**
```
force-push-scanner/
├── leaked_secrets_results/
│   └── YYYYMMDD_HHMMSS/
│       ├── ORGANIZATION1/
│       │   └── verified_secrets_ORGANIZATION1.json
│       ├── ORGANIZATION2/
│       │   └── verified_secrets_ORGANIZATION2.json
│       └── scan_state.json
├── scan_logs/              # Debug logs (when enabled)
```

- Verified secrets are saved as JSON files with naming pattern: `verified_secrets_{org}.json`
- Scan state is preserved for resume functionality