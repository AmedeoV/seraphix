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

## 🎯 Bug Bounty Scripts

### Fetch Bug Bounty Organizations
```bash
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt
```

Generates a curated list of organizations with active bug bounty programs for prioritizing high-value targets.

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