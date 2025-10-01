# Utilities

This directory contains utility scripts for database management and organization discovery.

## Star Counter Scripts

### `github_star_counter.py`
Single-threaded script for fetching GitHub star counts for organizations.

**Usage:**
```bash
python github_star_counter.py --db-file /path/to/database.sqlite3
```

### `github_star_counter_parallel.py`
Multi-threaded version for faster star count updates across large datasets.

**Usage:**
```bash
python github_star_counter_parallel.py --db-file /path/to/database.sqlite3 --workers 8
```

**Features:**
- Parallel processing with configurable worker threads
- Rate limiting to respect GitHub API limits
- Progress tracking and logging
- Resume capability for interrupted runs

## Database Update Scripts

### `update_database_stars.py`
Python script to update star counts in the SQLite database.

**Usage:**
```bash
python update_database_stars.py --db-file /path/to/database.sqlite3
```

### `update_database_stars.ps1`
PowerShell version for Windows environments.

**Usage:**
```powershell
.\update_database_stars.ps1 -DbFile "C:\path\to\database.sqlite3"
```

## Organization Discovery Scripts

### `get_orgs_with_stars.sh`
Bash script to query organizations with star counts from the database.

**Usage:**
```bash
./get_orgs_with_stars.sh --min-stars 100 --db-file /path/to/database.sqlite3
```

### `get_orgs_with_stars.ps1`
PowerShell version for Windows environments.

**Usage:**
```powershell
.\get_orgs_with_stars.ps1 -MinStars 100 -DbFile "C:\path\to\database.sqlite3"
```

## Bug Bounty Scripts

### `fetch_bugbounty_orgs.py`
Fetches a curated list of organizations that participate in bug bounty programs.

**Usage:**
```bash
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt
```

### `bugbounty_orgs.txt`
Curated list of organizations with active bug bounty programs. This file is used by scanners to prioritize high-value targets.

## Configuration

All scripts support the following common options:
- `--db-file`: Path to SQLite database file
- `--github-token`: GitHub API token (or set GITHUB_TOKEN environment variable)
- `--output`: Output file path
- `--verbose`: Enable debug logging

## Dependencies

```bash
pip install requests sqlite3 concurrent.futures argparse
```

## Integration with Main Scanners

These utilities integrate with the main scanning modules:

- **force-push-scanner**: Uses star counts for organization prioritization
- **org-scanner**: References bug bounty lists for target selection
- **Database management**: Keeps organization metadata current

## Performance Tips

1. **Star Counter**: Use the parallel version for large datasets (1000+ organizations)
2. **Rate Limiting**: Respect GitHub API limits (5000 requests/hour for authenticated users)
3. **Database Updates**: Run star updates weekly or monthly, not during active scans
4. **Bug Bounty Lists**: Update quarterly or when new programs are announced