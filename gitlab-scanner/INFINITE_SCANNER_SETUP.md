# 🔄 Infinite GitLab Scanner - Setup Complete!

## ✅ What Was Created

Two new powerful scripts for continuous GitLab scanning:

### 1. **fetch_public_projects.sh**
Fetches publicly accessible GitLab projects using the GitLab API.

**Features:**
- Fetches projects sorted by star count
- Filters by minimum stars
- Supports self-hosted GitLab instances
- No authentication required for public projects
- Generates both projects and groups lists

### 2. **infinite_scan.sh**
Continuously scans projects with automatic state management.

**Features:**
- Automatic state saving and resumption
- Skips previously scanned projects
- Real-time notifications
- Tracks total secrets found
- Graceful shutdown (Ctrl+C)
- Configurable delays between scans

---

## 🚀 Quick Start Guide

### Step 0: Create GitLab Token (CRITICAL!)

**⚠️ WARNING**: Without a token, you'll be rate limited after just a few projects!

**Rate Limits:**
- **No token**: 300 requests/hour (exhausted in minutes)
- **With token**: 5,000+ requests/hour (scan hundreds of projects)

**Create your token:**
1. Go to: https://gitlab.com/-/user_settings/personal_access_tokens
2. Click "Add new token"
3. Name: "Seraphix Scanner"
4. Scopes: Check `read_api` and `read_repository`
5. Expiration: Choose your preference
6. Click "Create personal access token"
7. Copy the token (starts with `glpat-`)

```bash
# Set the token (required for infinite scanning)
export GITLAB_TOKEN="glpat-your-token-here"

# Or add to your ~/.bashrc or ~/.zshrc for persistence
echo 'export GITLAB_TOKEN="glpat-your-token-here"' >> ~/.bashrc
```

### Step 1: Fetch Public Projects

```bash
cd gitlab-scanner

# Fetch popular projects (50+ stars)
./fetch_public_projects.sh --min-stars 50 --max-pages 20

# OR fetch more projects with lower threshold
./fetch_public_projects.sh --min-stars 10 --max-pages 50
```

This creates `public_projects.txt` with a list of projects to scan.

### Step 2: Start the Infinite Scanner

**⚠️ Make sure you set GITLAB_TOKEN first (see Step 0)!**

```bash
# Verify token is set
echo $GITLAB_TOKEN
# Should show: glpat-...

# Start with notifications (RECOMMENDED)
./infinite_scan.sh --telegram-chat-id 123456789

# With email notifications too
./infinite_scan.sh --telegram-chat-id 123456789 --email security@company.com

# If you forgot to set token, you can pass it directly
./infinite_scan.sh --gitlab-token glpat-xxx --telegram-chat-id 123456789
```

### Step 3: Monitor Progress

The scanner shows real-time progress:
```
🔄 Starting scan cycle #1
🔄 Scanning: gitlab-org/gitlab
✅ Successfully scanned gitlab-org/gitlab (Total: 1)
🔑 Found 2 secret(s) in gitlab-org/gitlab! (Total: 2)
📊 Progress: 10 scanned, 0 skipped
```

Press **Ctrl+C** to stop gracefully - state is saved automatically!

---

## 📊 State Management

The scanner maintains state in `scan_state.json`:

```json
{
  "last_updated": "2025-11-23T12:00:00.000Z",
  "total_scanned": 42,
  "total_skipped": 5,
  "total_secrets_found": 8,
  "scanned_projects": ["project1", "project2", ...],
  "skipped_projects": ["failed-project", ...]
}
```

**Resume Anytime:** Just run the scanner again - it picks up where it left off!

---

## 🎯 Tested & Working

### ✅ Validation Results

- ✅ **Bash syntax check**: Passed
- ✅ **Help output**: Working perfectly
- ✅ **API fetch**: Successfully fetched 100 projects
- ✅ **File generation**: Creates properly formatted lists
- ✅ **Scripts executable**: Permissions set correctly

### ✅ Real Test Results

Fetched from GitLab.com:
- **100 popular projects** with 50+ stars
- Projects include: AuroraStore, OpenRGB, ClearURLs, LabCoat, OpenMW, Remmina, and more
- File format validated and ready for scanning

---

## 📂 Files Created

```
gitlab-scanner/
├── fetch_public_projects.sh     # NEW: Fetch public projects
├── infinite_scan.sh              # NEW: Infinite scanner
├── INFINITE_SCANNER.md           # NEW: Complete documentation
├── public_projects.txt           # Generated: Projects list
├── public_groups.txt             # Generated: Groups list
├── scan_state.json               # Generated: Scanner state
├── scan_repo.sh                  # Existing: Single repo scanner
├── scan_group.sh                 # Existing: Group scanner
└── README.md                     # Updated: Added infinite scanner section
```

---

## 🆚 Comparison: Manual vs Infinite

### Manual Scanning
```bash
# Scan individual projects
./scan_repo.sh gitlab-org/gitlab
./scan_repo.sh another-org/project
# ... manually repeat for each project
```

### Infinite Scanning
```bash
# Fetch projects once
./fetch_public_projects.sh --min-stars 10

# Start scanning - it handles everything
./infinite_scan.sh --telegram-chat-id 123456789

# State is saved automatically
# Resume anytime with the same command
```

---

## 🎪 Use Cases

### 1. Bug Bounty Hunting
```bash
# Focus on popular, actively maintained projects
./fetch_public_projects.sh --min-stars 20 --max-pages 100
./infinite_scan.sh --telegram-chat-id 123456789
```

### 2. Security Research
```bash
# Scan a wide range of projects
./fetch_public_projects.sh --min-stars 5 --max-pages 200
./infinite_scan.sh --email security@company.com
```

### 3. Continuous Monitoring
```bash
# Run in background with nohup
nohup ./infinite_scan.sh --telegram-chat-id 123456789 > scanner.log 2>&1 &

# Monitor progress
tail -f scanner.log
```

### 4. Self-Hosted GitLab
```bash
# Scan your company's GitLab instance
export GITLAB_TOKEN="glpat-xxx"
./fetch_public_projects.sh --gitlab-url https://gitlab.company.com
./infinite_scan.sh --telegram-chat-id 123456789
```

---

## 🔧 Configuration Options

### Fetch Script Options

| Option | Default | Description |
|--------|---------|-------------|
| `--gitlab-url` | https://gitlab.com | GitLab instance URL |
| `--max-pages` | 50 | API pages to fetch (100 projects/page) |
| `--min-stars` | 0 | Minimum star count filter |
| `--output` | public_projects.txt | Output file path |

### Scanner Options

| Option | Default | Description |
|--------|---------|-------------|
| `--projects-file` | public_projects.txt | Projects list file |
| `--delay` | 3 | Seconds between scans |
| `--gitlab-token` | - | API token (or use env var) |
| `--telegram-chat-id` | - | Telegram notifications |
| `--email` | - | Email notifications |

---

## 💡 Pro Tips

1. **Start Small**: Test with `--max-pages 5` first
2. **Filter by Stars**: Use `--min-stars 10` for quality projects
3. **Use Authentication**: Set `GITLAB_TOKEN` to avoid rate limits
4. **Enable Notifications**: Get instant alerts for secrets
5. **Run in Background**: Use `nohup` for long-running scans
6. **Monitor State**: Check `scan_state.json` for progress
7. **Resume Anytime**: Just restart - state is preserved

---

## 📖 Documentation

- **[INFINITE_SCANNER.md](INFINITE_SCANNER.md)** - Complete guide
- **[README.md](README.md)** - GitLab scanner overview
- **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Command reference

---

## 🎉 Example Session

```bash
# Terminal 1: Fetch projects
cd gitlab-scanner
./fetch_public_projects.sh --min-stars 20 --max-pages 50

# Output:
# ✅ Found 100 unique public projects
# ✅ Saved to: public_projects.txt

# Terminal 1: Start scanner
export GITLAB_TOKEN="glpat-xxx"
./infinite_scan.sh --telegram-chat-id 123456789

# Output:
# 🦊 Starting infinite GitLab scanner...
# 🔄 Starting scan cycle #1
# 🔄 Scanning: AuroraOSS/AuroraStore
# ✅ Successfully scanned AuroraOSS/AuroraStore (Total: 1)
# 🔑 Found 1 secret(s) in AuroraOSS/AuroraStore! (Total: 1)
# ...

# Terminal 2: Monitor progress
tail -f scan_state.json
watch -n 5 'cat scan_state.json | jq ".total_secrets_found"'

# Stop gracefully (Ctrl+C in Terminal 1):
# Scan interrupted by user (Ctrl+C)
# 💾 Saving state before exit...
# ✅ State saved. Run again to resume.

# Resume later:
./infinite_scan.sh --telegram-chat-id 123456789
# ℹ️  Loading previous scan state...
# ℹ️  Resuming: 42 already scanned, 3 skipped, 8 secrets found
```

---

## 🚀 Next Steps

1. **Test the Fetcher**:
   ```bash
   ./fetch_public_projects.sh --max-pages 5 --min-stars 50
   ```

2. **Review the List**:
   ```bash
   head -30 public_projects.txt
   ```

3. **Start Scanning**:
   ```bash
   ./infinite_scan.sh --telegram-chat-id YOUR_CHAT_ID
   ```

4. **Monitor Results**:
   ```bash
   watch -n 5 'tail -10 scan_state.json'
   ```

---

**The infinite GitLab scanner is ready to use! 🦊🔄**

Happy hunting! 🚀
