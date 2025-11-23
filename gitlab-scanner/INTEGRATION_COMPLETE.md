# 🦊 GitLab Integration - Setup Complete!

## What Was Added

The GitLab scanner has been successfully integrated into Seraphix! Here's what you now have:

### 📁 New Directory Structure
```
gitlab-scanner/
├── scan_repo.sh              # Scan individual GitLab projects
├── scan_group.sh             # Scan entire GitLab groups
├── README.md                 # Full documentation
├── QUICK_REFERENCE.md        # Quick command reference
├── groups.txt.example        # Example groups file
├── leaked_secrets_results/   # Scan results directory
└── scan_logs/                # Debug logs directory
```

## 🎯 Features

### Repository Scanner (`scan_repo.sh`)
- Scan individual GitLab projects
- Support for self-hosted GitLab instances
- Specific commit scanning
- Real-time notifications
- Adaptive timeouts based on repo size

### Group Scanner (`scan_group.sh`)
- Scan all projects in a GitLab group
- Automatic subgroup inclusion
- Multi-worker parallel scanning
- Smart filtering (exclude archived/forks)
- Batch scanning from files
- Auto-optimized based on system resources

## 🚀 Quick Start

### 1. Set Up Token (Optional for Public Repos)
```bash
export GITLAB_TOKEN="glpat-your-token-here"
```

### 2. Scan a Repository
```bash
cd gitlab-scanner
./scan_repo.sh gitlab-org/gitlab
```

### 3. Scan a Group
```bash
./scan_group.sh gitlab-org --max-repos 10
```

### 4. With Notifications
```bash
./scan_group.sh mygroup --telegram-chat-id 123456789 --email security@company.com
```

## 🆚 Comparison with GitHub Scanner

| Feature | GitHub | GitLab |
|---------|--------|--------|
| Repository Scanning | ✅ | ✅ |
| Organization/Group Scanning | ✅ | ✅ |
| Force-Push History | ✅ | ❌ |
| Subgroup Support | N/A | ✅ |
| Self-Hosted Support | ❌ | ✅ |
| Fork Detection | ✅ | ✅ |
| Archived Project Filtering | ✅ | ✅ |
| Parallel Workers | ✅ | ✅ |
| Notifications | ✅ | ✅ |

## 📋 What's Different from GitHub

1. **GitLab Groups** instead of Organizations
2. **Subgroups** are included by default (can be disabled with `--no-subgroups`)
3. **Self-hosted GitLab** support with `--gitlab-url`
4. **OAuth2 token authentication** (format: `glpat-xxx`)
5. **Nested project paths** (e.g., `group/subgroup/project`)

## 🔑 GitLab API Token Setup

### For gitlab.com:
1. Go to https://gitlab.com/-/user_settings/personal_access_tokens
2. Create new token with:
   - Name: "Seraphix Scanner"
   - Scopes: `read_api`, `read_repository`
3. Copy token and set: `export GITLAB_TOKEN="glpat-xxx"`

### For self-hosted GitLab:
1. Go to your GitLab instance: `https://gitlab.example.com/-/user_settings/personal_access_tokens`
2. Create token with same scopes
3. Use with `--gitlab-url` flag

## 📊 Output Format

Results include a `"source": "gitlab"` field to distinguish from GitHub results:

```json
{
  "DetectorName": "AWS",
  "Verified": true,
  "Raw": "AKIA...",
  "repository_name": "mygroup/myproject",
  "source": "gitlab",
  "scan_timestamp": "2025-11-23T12:00:00.000Z"
}
```

## 🛠️ Advanced Usage

### Scan Self-Hosted GitLab
```bash
./scan_group.sh internal-projects \
  --gitlab-url https://gitlab.company.com \
  --gitlab-token glpat-xxx \
  --max-repos 50
```

### Batch Scan Multiple Groups
```bash
cat > production_groups.txt << EOF
backend-services
frontend-apps
infrastructure
EOF

./scan_group.sh --groups-file production_groups.txt \
  --telegram-chat-id 123456789
```

### Include Everything (Archived + Forks)
```bash
./scan_group.sh mygroup --scan-all --max-repos 100
```

## 📚 Documentation

- **Full README**: [gitlab-scanner/README.md](gitlab-scanner/README.md)
- **Quick Reference**: [gitlab-scanner/QUICK_REFERENCE.md](gitlab-scanner/QUICK_REFERENCE.md)
- **Main README**: [README.md](README.md) (updated with GitLab info)

## ✅ Testing

Both scripts have been validated:
- ✅ Bash syntax check passed
- ✅ File permissions set correctly
- ✅ Directory structure created
- ✅ Documentation complete

## 🎉 Next Steps

1. Set your GitLab token: `export GITLAB_TOKEN="glpat-xxx"`
2. Try scanning a public project: `cd gitlab-scanner && ./scan_repo.sh gitlab-org/gitlab`
3. Set up notifications (optional): See [config/README.md](config/README.md)
4. Scan your own groups!

## 🤝 Integration with Existing Tools

The GitLab scanner integrates seamlessly with:
- ✅ Existing notification system (Telegram, Discord, Email)
- ✅ Analyzer tools (can analyze GitLab results)
- ✅ Same output format as GitHub scanners
- ✅ Same configuration files

## 💡 Use Cases

1. **Security Audits**: Scan all projects in your GitLab groups
2. **Bug Bounty**: Scan public GitLab groups of target companies
3. **Compliance**: Regular automated scans of internal projects
4. **Self-Hosted**: Monitor your private GitLab instance
5. **Multi-Platform**: Combine with GitHub scans for complete coverage

---

**Happy Scanning! 🚀**

For questions or issues, check the documentation or open an issue on GitHub.
