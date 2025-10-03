<p align="center">
  <img src="seraphix-scanner-logo.jpg" alt="Seraphix Scanner Logo" height="140" />
  <h2 align="center">Seraphix</h2>
  <p align="center">Comprehensive GitHub secret scanner for security researchers.</p>
</p>

---

<div align="center">

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/AmedeoV/seraphix)

</div>

---

# 🔍 What is Seraphix?

Seraphix is a **comprehensive secret scanning toolkit** designed for security researchers and bug bounty hunters. It provides multiple scanning strategies to discover leaked credentials across GitHub:

## 🎯 Scanning Capabilities

**🔥 Force-Pushed Commits** - Hunt for secrets in dangling commits created by `git push --force` operations. When developers force push, they often overwrite history containing mistakes like hard-coded credentials. Seraphix uses [GHArchive](https://www.gharchive.org/) data to identify these hidden commits.

**🏢 Organization-Wide Scanning** - Scan entire GitHub organizations without requiring a database. Perfect for comprehensive security audits and continuous monitoring of all repositories within an organization.

**📝 Repository & Commit Scanning** - Target specific repositories or individual commits for focused analysis. Ideal for investigating particular codebases or validating security fixes.

## 💰 Proven Results

The force-push scanning technique was inspired by [Sharon Brizinov](https://github.com/SharonBrizinov)'s research. Read [Sharon's blog post](https://trufflesecurity.com/blog/guest-post-how-i-scanned-all-of-github-s-oops-commits-for-leaked-secrets) to learn how he made **$25k in bounties** using this innovative approach to discover leaked secrets!

---

# 🚀 Quick Start

## 1: Install Dependencies

```bash
./install_requirements.sh
```

## 2: Choose Your Scanner

### 🔥 [Force Push Scanner](force-push-scanner/README.md) 
**⚠️ Requires SQLite database download** - See [setup instructions](force-push-scanner/README.md)

Scan force-pushed commits using the GHArchive database.
```bash
cd force-push-scanner/
./force_push_secret_scanner.sh --order random --telegram-chat-id 123456789
```

### 🏢 [Organization Scanner](org-scanner/README.md)
No database required - uses GitHub API directly.

Scan all repositories in a GitHub organization.
```bash
cd org-scanner/
./scan_org.sh microsoft --max-repos 10 --telegram-chat-id 123456789
```

### 📝 [Repository Scanner](repo-scanner/README.md)
No database required - direct repository scanning.

Scan individual repositories.
```bash
cd repo-scanner/
./scan_repo_simple.sh owner/repository --telegram-chat-id 123456789
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

📖 **[Full Configuration Guide](config/README.md)** - Complete setup instructions and troubleshooting

---

# 🛠️ Utilities

Additional tools for database management and analysis:

- **GitHub Star Counter** - Fetch and update star counts for organizations in the database
- **Bug Bounty Org Fetcher** - Generate lists of organizations with bug bounty programs

📖 **[Utilities Documentation](utilities/README.md)** - Database tools and helper scripts

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

# 🤝 Contributing

Contributions are welcome! Areas for improvement:
- Additional secret detectors
- Performance optimizations
- Documentation improvements
- Bug fixes

Please open an issue or pull request on GitHub.

---

# 📜 License

This project is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE) for details.

**⚠️ Disclaimer:** This tool is intended exclusively for authorized defensive security operations. Always obtain explicit permission before performing any analysis. Unauthorized use is strictly prohibited and at your own risk.
