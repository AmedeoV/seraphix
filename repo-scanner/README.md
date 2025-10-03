# 📝 Repository Scanner

Scan individual GitHub repositories or specific commits for secrets. Perfect for targeted analysis—**no database required**.

---

## 🚀 Quick Start

### 1. Install Dependencies (if not already done)

```bash
../install_requirements.sh
```

### 2. Run the Scanner

```bash
# Basic scan
./scan_repo_simple.sh owner/repository

# With notifications
./scan_repo_simple.sh owner/repo --telegram-id 123456789 --email security@company.com

# Scan specific commit
./scan_repo_simple.sh owner/repo --commit abc1234
```

---

## ⚙️ Options

| Option | Description |
|--------|-------------|
| `--output FILE` | Custom output file path |
| `--commit HASH` | Scan specific commit |
| `--debug` | Enable verbose logging |
| `--email EMAIL` | Email for notifications |
| `--telegram-id ID` | Telegram chat ID for notifications |
| `--no-cleanup` | Keep temporary files |

**Dynamic Configuration:**
- Timeout values are automatically calculated based on repository size and complexity

---

## 📂 Output

**Results:** `leaked_secrets_results/YYYYMMDD_HHMMSS/`  
**Logs:** `scan_logs/` (when `--debug` enabled)