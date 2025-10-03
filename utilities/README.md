# 🛠️ Utilities

Database management and organization discovery tools for Seraphix scanners.

---

## 📊 Star Counter Scripts

Fetch and update GitHub star counts for organizations in the database.

```bash
# Single-threaded
python github_star_counter.py [--db-file PATH]

# Multi-threaded (Faster, Recommended)
python github_star_counter_parallel.py [--db-file PATH]

# Default db-file: force_push_commits.sqlite3
```

⚠️ **Rate Limit Warning:** The parallel version can consume your entire GitHub API quota (5000 requests/hour) quickly. **Run during off-hours or weekends** when you're not actively using the GitHub API for other tasks.

---

## 🎯 Bug Bounty Organizations

Fetch organizations that participate in bug bounty programs to prioritize high-value targets.

```bash
# Generate bug bounty organization list
python fetch_bugbounty_orgs.py [--output FILE] [--github-token TOKEN]
# Default output: bugbounty_orgs.txt

# Use with force-push scanner
cd ../force-push-scanner/
./force_push_secret_scanner.sh --orgs-file bugbounty_orgs.txt

# Use with org scanner
cd ../org-scanner/
./scan_org.sh --orgs-file bugbounty_orgs.txt
```

**Credit:** Data sourced from [nikitastupin/orgs-data](https://github.com/nikitastupin/orgs-data) - a curated mapping of bug bounty programs to GitHub organizations.

---