# GitLab Scanner Quick Reference

## Setup
```bash
# Set GitLab token (REQUIRED for infinite scanner to avoid rate limits!)
export GITLAB_TOKEN="glpat-your-token-here"

# Create token at: https://gitlab.com/-/user_settings/personal_access_tokens
# Scopes needed: read_api, read_repository
# Rate limits: 300/hr without token vs 5,000+/hr with token
```

## Repository Scanner

### Basic Commands
```bash
# Scan a single project
./scan_repo.sh gitlab-org/gitlab

# Scan with debug output
./scan_repo.sh mygroup/project --debug

# Scan specific commit
./scan_repo.sh mygroup/project --commit abc1234
```

### Self-Hosted GitLab
```bash
./scan_repo.sh mygroup/project \
  --gitlab-url https://gitlab.example.com \
  --gitlab-token glpat-xxx
```

### With Notifications
```bash
./scan_repo.sh mygroup/project \
  --telegram-chat-id 123456789 \
  --email security@company.com
```

## Group Scanner

### Basic Commands
```bash
# Scan entire group
./scan_group.sh gitlab-org

# Limit to 10 projects
./scan_group.sh gitlab-org --max-repos 10

# Exclude subgroups
./scan_group.sh gitlab-org --no-subgroups
```

### Filtering
```bash
# Include archived projects
./scan_group.sh mygroup --include-archived

# Include forks
./scan_group.sh mygroup --include-forks

# Scan everything
./scan_group.sh mygroup --scan-all
```

### Batch Scanning
```bash
# Create groups file
cat > my_groups.txt << EOF
gitlab-org
my-company
another-group
EOF

# Scan all groups
./scan_group.sh --groups-file my_groups.txt \
  --max-repos 20 \
  --telegram-chat-id 123456789
```

### Self-Hosted GitLab
```bash
./scan_group.sh mygroup \
  --gitlab-url https://gitlab.example.com \
  --gitlab-token glpat-xxx \
  --max-repos 50
```

## Common Options

| Option | Description |
|--------|-------------|
| `--gitlab-url URL` | GitLab instance (default: https://gitlab.com) |
| `--gitlab-token TOKEN` | API token (or use GITLAB_TOKEN env) |
| `--max-repos N` | Limit projects scanned |
| `--debug` | Verbose output |
| `--telegram-chat-id ID` | Telegram notifications |
| `--email EMAIL` | Email notifications |
| `--no-cleanup` | Keep temporary files |

## Output Location

Results are saved in:
```
leaked_secrets_results/
└── YYYYMMDD_HHMMSS/
    ├── gitlab_scan_*.json          (single repo)
    └── group_leaked_secrets/       (group scan)
        └── scan_GROUP_*/
            └── GROUP_secrets/
```

## Tips

1. Start with `--max-repos 5` to test
2. Use `--debug` to troubleshoot
3. Enable notifications for real-time alerts
4. Exclude archived/forks to focus on active code
5. Works with self-hosted GitLab CE/EE

## Troubleshooting

### 401 Unauthorized
- Check your token is valid
- Verify token has `read_api` and `read_repository` scopes

### No projects found
- Verify group name is correct
- Use `--gitlab-token` for private groups
- Try `--include-subgroups` (default: enabled)

### Rate limiting
- Use `--max-repos` to limit requests
- Ensure you're using a token

## Full Documentation

See [README.md](README.md) for complete documentation.
