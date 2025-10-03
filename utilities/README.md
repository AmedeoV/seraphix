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

⚠️ **Rate Limit Warning:** The parallel version can consume your entire GitHub API quota (5000 requests/hour) quickly. **Run during off-hours or weekends** when you're not actively using the GitHub API for other tasks.

**Features:** 
- Automatic parallel processing with dynamic worker calculation
- Smart rate limiting based on API quota
- Progress tracking and resume capability
- Adaptive batch sizing based on dataset

---

## 🎯 Bug Bounty Organizations

Fetch organizations that participate in bug bounty programs to prioritize high-value targets.

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

**Credit:** Data sourced from [nikitastupin/orgs-data](https://github.com/nikitastupin/orgs-data) - a curated mapping of bug bounty programs to GitHub organizations.

---

## ⚙️ Script Options

### Star Counter Scripts
| Option | Description |
|--------|-------------|
| `--github-token TOKEN` | GitHub API token (or set `GITHUB_TOKEN` env var) |

**Note:** Database file (`force_push_commits.sqlite3`) and worker count are auto-detected based on CPU cores and API rate limits.

### Bug Bounty Fetcher
| Option | Description |
|--------|-------------|
| `--output FILE` | Output file path (default: `bugbounty_orgs.txt`) |
| `--github-token TOKEN` | GitHub API token for higher rate limits |

---

## 💡 Performance Tips

- **Use parallel version** for large datasets (1000+ organizations) - it automatically optimizes worker count
- **⚠️ Schedule wisely:** Run parallel star updates during **off-hours, evenings, or weekends** to avoid exhausting your GitHub API quota during active development
- **Set GITHUB_TOKEN** environment variable to get 5000 requests/hour (vs 60 unauthenticated)
- **System resources** are auto-detected (CPU cores, memory, API quota) for optimal performance
- Run star updates **weekly/monthly**, not during active scans
- Update bug bounty lists **quarterly** or when new programs announced
- The parallel script will automatically:
  - Use 2-16 workers based on your CPU
  - Reduce workers if API quota is low
  - Adjust batch size based on dataset size
  - Wait and resume if rate limit is hit