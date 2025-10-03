# 🛠️ Utilities

Database management and organization discovery tools for Seraphix scanners.

---

## 📊 Star Counter Scripts

Fetch and update GitHub star counts for organizations in the database.

### Single-threaded
```bash
python github_star_counter.py
```

### Multi-threaded (Faster, Recommended)
```bash
python github_star_counter_parallel.py
```

**Features:** 
- Automatic parallel processing with dynamic worker calculation
- Smart rate limiting based on API quota
- Progress tracking and resume capability
- Adaptive batch sizing based on dataset

---

## 🎯 Bug Bounty Organizations

Fetch organizations that participate in bug bounty programs to prioritize high-value targets.

```bash
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt
```

Generate a list of organizations to pass to **both scanners**:

```bash
# Generate bug bounty organization list
python fetch_bugbounty_orgs.py --output bugbounty_orgs.txt

# Use with force-push scanner
cd ../force-push-scanner/
./force_push_secret_scanner.sh --orgs-file bugbounty_orgs.txt

# Use with org scanner
cd ../org-scanner/
./scan_org.sh --orgs-file bugbounty_orgs.txt
```

**File Format:** One organization per line, supports `#` comments

**Credit:** Data sourced from [nikitastupin/orgs-data](https://github.com/nikitastupin/orgs-data) - a curated mapping of bug bounty programs to GitHub organizations.

---

## ⚙️ Common Options

| Option | Description |
|--------|-------------|
| `--github-token` | GitHub API token (or set `GITHUB_TOKEN` env var) |
| `--output` | Output file path |
| `--verbose` | Enable debug logging |

**Note:** Database file path and worker count are now auto-detected. The scripts automatically use `force_push_commits.sqlite3` in the current directory and calculate optimal worker count based on CPU cores and API rate limits.

---

## 💡 Performance Tips

- **Use parallel version** for large datasets (1000+ organizations) - it automatically optimizes worker count
- **Set GITHUB_TOKEN** environment variable to get 5000 requests/hour (vs 60 unauthenticated)
- **System resources** are auto-detected (CPU cores, memory, API quota) for optimal performance
- Run star updates **weekly/monthly**, not during active scans
- Update bug bounty lists **quarterly** or when new programs announced
- The parallel script will automatically:
  - Use 2-16 workers based on your CPU
  - Reduce workers if API quota is low
  - Adjust batch size based on dataset size