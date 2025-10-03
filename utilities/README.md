# 🛠️ Utilities

Database management and organization discovery tools for Seraphix scanners.

---

## 📊 Star Counter Scripts

Fetch and update GitHub star counts for organizations in the database.

### Single-threaded
```bash
python github_star_counter.py [--db-file PATH]
```

### Multi-threaded (Faster, Recommended)
```bash
python github_star_counter_parallel.py [--db-file PATH]
```

⚠️ **Rate Limit Warning:** The parallel version can consume your entire GitHub API quota (5000 requests/hour) quickly. **Run during off-hours or weekends** when you're not actively using the GitHub API for other tasks.

**Features (Multi-threaded):** 
- Automatic parallel processing with dynamic worker calculation
- Smart rate limiting based on API quota
- Progress tracking and resume capability
- Adaptive batch sizing based on dataset
- Worker count and batch size are auto-detected based on CPU cores and API rate limits

**Options (Both versions):**
| Option | Description |
|--------|-------------|
| `--db-file PATH` | Path to SQLite database file (default: `force_push_commits.sqlite3`) |

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

**Options:**
| Option | Description |
|--------|-------------|
| `--output FILE` | Output file path (default: `bugbounty_orgs.txt`) |
| `--github-token TOKEN` | GitHub API token for higher rate limits |

**Credit:** Data sourced from [nikitastupin/orgs-data](https://github.com/nikitastupin/orgs-data) - a curated mapping of bug bounty programs to GitHub organizations.

---