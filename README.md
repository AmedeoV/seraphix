<p align="center">
  <img src="seraphix-scanner-logo.jpg" alt="Seraphix Scanner Logo" height="140" />
  <h2 align="center">Seraphix</h2>
  <p align="center">Find secrets in force-pushed commits.</p>
</p>

---

<div align="center">

[![License](https://img.shields.io/badge/license-MIT-blue)](/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/AmedeoV/seraphix)

</div>

---

# 🔍 What is Seraphix?

Seraphix scans for secrets in **dangling commits** created by force push events on GitHub. When developers use `git push --force`, they often overwrite history containing mistakes like hard-coded credentials. This tool helps security researchers discover these leaked secrets using archived data from [GHArchive](https://www.gharchive.org/).

This project was created in collaboration with [Sharon Brizinov](https://github.com/SharonBrizinov). Read [Sharon's blog post](https://trufflesecurity.com/blog/guest-post-how-i-scanned-all-of-github-s-oops-commits-for-leaked-secrets) to learn how he made $25k in bounties scanning force-push commits!

---

# 🚀 Quick Start

## 1: Get the Force Push Database

Download the Force Push Commits SQLite DB via Google Form: <https://forms.gle/344GbP6WrJ1fhW2A6>

This database contains force push commits for all GitHub organizations, updated daily.

## 2: Install Dependencies

```bash
./install_requirements.sh
```

## 3: Scan an Organization

```bash
python force_push_scanner.py <org> --db-file /path/to/force_push_commits.sqlite3 --scan
```

**Example output:**
```
🔍 Scanning organization: trufflesecurity
✅ Found verified secret in repo: trufflesecurity/test_keys
🔑 AWS Credential (AKIAYVP4CIPPERUVIFXG)
📍 Commit: https://github.com/trufflesecurity/test_keys/commit/fbc14303ffbf8fb1c2c1914e8dda7d0121633aca
```

---

# 📦 Scanner Modules

Seraphix includes three powerful scanning modes for different use cases:

## 🔥 [Force Push Scanner](force-push-scanner/README.md)
Database-driven scanning of force-pushed commits with resume capabilities.
```bash
cd force-push-scanner/
./force_push_secret_scanner.sh --order random --telegram-chat-id 123456789
```

## 🏢 [Organization Scanner](org-scanner/README.md)
Direct GitHub API scanning for entire organizations (no database required).
```bash
cd org-scanner/
./scan_org.sh microsoft --max-repos 10 --telegram-chat-id 123456789
```

## 📝 [Repository Scanner](repo-scanner/README.md)
Targeted scanning for individual repositories and specific commits.
```bash
cd repo-scanner/
./scan_repo_simple.sh owner/repository
```

---

# ⚙️ Configuration

### Notification Setup

Enable real-time alerts when secrets are found:

**Telegram:**
```bash
cp config/telegram_config.sh.example config/telegram_config.sh
# Edit and add your bot token and chat ID
```

**Email (Mailgun):**
```bash
cp config/mailgun_config.sh.example config/mailgun_config.sh
# Edit and add your Mailgun credentials
```

---

# 🗂️ Alternative: BigQuery

Prefer querying yourself? Use our public BigQuery table:

```sql
SELECT *
FROM `external-truffle-security-gha.force_push_commits.pushes`
WHERE repo_org = '<ORG>';
```

Export as CSV and scan:
```bash
python force_push_scanner.py <org> --events-file /path/to/export.csv --scan
```

---

# 📊 Output Structure

Each scanner organizes results in timestamped directories:

```
📁 Seraphix/
├── force-push-scanner/
│   └── leaked_secrets_results/YYYYMMDD_HHMMSS/
├── org-scanner/
│   └── leaked_secrets_results/YYYYMMDD_HHMMSS/
└── repo-scanner/
    └── leaked_secrets_results/YYYYMMDD_HHMMSS/
```

Results are saved as JSON files with verified secret details, commit links, and timestamps.

---

# ❓ FAQ

### What is a Force Push?

A force push (`git push --force`) rewrites remote branch history. Commits that were part of the old history become "dangling" but remain accessible on GitHub. Developers often force push to remove accidentally committed secrets. [Learn more](https://git-scm.com/docs/git-push#Documentation/git-push.txt---force)

### Does this contain ALL force pushes on GitHub?

No. We focus on **Zero-Commit Force Pushes**, which are highly correlated with secret removal attempts. These are push events where developers reset history without adding new commits—a strong indicator of attempting to delete sensitive data.

### What is GHArchive?

[GHArchive](https://www.gharchive.org/) is a public dataset of all GitHub activity. We've trimmed it to only force push events, making it faster and cheaper to query.

### How often is the database updated?

Daily at 2 PM EST with the previous day's force push events.

---

# 🛠️ Command-Line Options

### Main Python Scanner

```bash
python force_push_scanner.py --help
```

**Common options:**
- `--db-file` - SQLite database path (recommended)
- `--events-file` - CSV export from BigQuery
- `--scan` - Enable TruffleHog secret scanning
- `--verbose` - Debug logging

### Bash Scanners

See individual scanner README files for detailed options:
- [Force Push Scanner Options](force-push-scanner/README.md#common-options)
- [Organization Scanner Options](org-scanner/README.md#options)
- [Repository Scanner Options](repo-scanner/README.md)

---

# 🤝 Contributing

Contributions are welcome! Areas for improvement:
- Additional secret detectors
- Performance optimizations
- Documentation improvements
- Bug fixes

Please open an issue or pull request on GitHub.

---

# 📜 License

This project is provided as-is under the MIT License. See [LICENSE](LICENSE) for details.

**⚠️ Disclaimer:** This tool is intended exclusively for authorized defensive security operations. Always obtain explicit permission before performing any analysis. Unauthorized use is strictly prohibited and at your own risk.
