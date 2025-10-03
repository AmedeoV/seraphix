# 🛠️ Utilities

Database management and organization discovery tools for Seraphix scanners.

---

## 📊 Star Counter Scripts

Fetch and update GitHub star counts for organizations in the database.

### Single-threaded
```bash
python github_star_counter.py --db-file /path/to/database.sqlite3
```

### Multi-threaded (Faster)
```bash
python github_star_counter_parallel.py --db-file /path/to/database.sqlite3 --workers 8
```

**Features:** Parallel processing, rate limiting, progress tracking, resume capability

---

## 🎯 Bug Bounty Organizations

Fetch organizations that participate in bug bounty programs to prioritize high-value targets.

```bash
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt
```

Generate a list of organizations to pass to scanners:
```bash
# Generate bug bounty organization list
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt

# Use with force-push scanner
cd ../force-push-scanner/
./force_push_secret_scanner.sh --orgs-file bugbounty_orgs.txt
```

**Credit:** Data sourced from [nikitastupin/orgs-data](https://github.com/nikitastupin/orgs-data) - a curated mapping of bug bounty programs to GitHub organizations.

---

## ⚙️ Common Options

| Option | Description |
|--------|-------------|
| `--db-file` | Path to SQLite database file |
| `--github-token` | GitHub API token (or set `GITHUB_TOKEN` env var) |
| `--output` | Output file path |
| `--verbose` | Enable debug logging |
| `--workers` | Number of parallel workers (parallel scripts) |

---

## 📦 Dependencies

```bash
pip install requests
```

---

## 🔗 Integration

- **Force Push Scanner** - Uses star counts for organization prioritization
- **Org Scanner** - References bug bounty lists for target selection
- **Database Management** - Keeps organization metadata current

---

## 💡 Performance Tips

- Use parallel version for large datasets (1000+ organizations)
- Respect GitHub API limits (5000 requests/hour authenticated)
- Run star updates weekly/monthly, not during active scans
- Update bug bounty lists quarterly or when new programs announced