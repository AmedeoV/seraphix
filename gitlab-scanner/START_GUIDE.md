# GitLab Infinite Scanner - Quick Start

## 🚀 Starting the Scanner

Run this command in PowerShell to start the infinite scanner:

```powershell
wsl bash -c "cd /mnt/d/Projects/seraphix/gitlab-scanner && export GITLAB_TOKEN='YOUR_TOKEN_HERE' && ./start_infinite_scanner.sh"
```

**Replace `YOUR_TOKEN_HERE` with your actual GitLab token (starts with `glpat-`)**

## 📋 Features

✅ **State Persistence**: If you stop the scanner (Ctrl+C), it saves progress and resumes from where it stopped
✅ **Smart Folder Creation**: Only creates result folders when secrets are actually found
✅ **Automatic Resumption**: Re-run the same command to continue scanning

## 🛑 Stopping the Scanner

Press **Ctrl+C** in the terminal. The scanner will:
1. Save the current state to `scan_state.json`
2. Record which projects have been scanned
3. Exit gracefully

## 📊 Checking Progress

View the state file to see progress:
```powershell
wsl bash -c "cd /mnt/d/Projects/seraphix/gitlab-scanner && cat scan_state.json | jq '.'"
```

## 📁 Results Location

When secrets are found, they'll be saved to:
```
gitlab-scanner/leaked_secrets_results/YYYYMMDD_HHMMSS/
└── gitlab_scan_PROJECT_NAME_TIMESTAMP.json
```

**Note**: Folders are only created when secrets are discovered!

## 🔄 Resuming After Stop

Just run the same start command again. The scanner will:
- Load `scan_state.json`
- Skip already-scanned projects
- Continue from where it left off

## 📈 Real-Time Monitoring

Watch the scanner output to see:
- Current project being scanned
- Total projects scanned
- Number of secrets found
- Progress updates every 10 projects

## Example Output

```
🔄 Starting scan cycle #1
========================================
🔄 Scanning: gitlab-org/gitlab
✅ Successfully scanned gitlab-org/gitlab (Total: 1)
🔄 Scanning: freedesktop/mesa
✅ Successfully scanned freedesktop/mesa (Total: 2)
🔑 Found 3 secret(s) in freedesktop/mesa! (Total: 3)
```

## 💡 Tips

1. **Run in background**: Use `screen` or `tmux` in WSL for long-running scans
2. **Monitor progress**: Check `scan_state.json` periodically
3. **Stop anytime**: Ctrl+C is safe - state is always saved
4. **Resume anytime**: Just run the start command again
