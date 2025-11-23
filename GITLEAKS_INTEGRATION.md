# Gitleaks Integration

Seraphix now supports **dual-scanner architecture** using both TruffleHog and Gitleaks for comprehensive secret detection.

## Why Two Scanners?

- **TruffleHog**: Focuses on verified secrets with active credential validation
- **Gitleaks**: Provides comprehensive pattern-based detection with high-entropy analysis
- **Together**: Maximizes secret detection coverage by combining verified findings with pattern matches

## Installation

Gitleaks is automatically installed when you run:

```bash
./install_requirements.sh
```

Or install Gitleaks separately:

```bash
# Via Go
go install github.com/gitleaks/gitleaks/v8@latest

# Via Homebrew (macOS)
brew install gitleaks

# Via script (Linux)
curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz | tar -xz -C /tmp
sudo mv /tmp/gitleaks /usr/local/bin/
```

## Scanner Selection

All scanners now support the `--scanner` flag to choose which tool to use:

### Organization Scanner

```bash
cd org-scanner/

# Use only Gitleaks
./scan_org.sh microsoft --scanner gitleaks --max-repos 5

# Use only TruffleHog  
./scan_org.sh microsoft --scanner trufflehog --max-repos 5

# Use both (default)
./scan_org.sh microsoft --scanner both --max-repos 5
./scan_org.sh microsoft --max-repos 5  # same as above
```

### Repository Scanner

```bash
cd repo-scanner/

# Use only Gitleaks
./scan_repo_simple.sh owner/repo --scanner gitleaks

# Use only TruffleHog
./scan_repo_simple.sh owner/repo --scanner trufflehog

# Use both (default)
./scan_repo_simple.sh owner/repo --scanner both
./scan_repo_simple.sh owner/repo  # same as above
```

### WSL Command Example

For scanning with Gitleaks only in WSL:

```bash
cd org-scanner/
./scan_org.sh microsoft --scanner gitleaks --max-repos 10 --telegram-chat-id YOUR_CHAT_ID
```

## How It Works

### Automatic Detection

All scanners automatically detect if Gitleaks is available:

1. **If both scanners are available**: Runs TruffleHog first, then Gitleaks, merging results
2. **If only TruffleHog is available**: Runs TruffleHog only with a warning message
3. **Results are deduplicated**: Identical secrets found by both scanners are merged

### Result Format

Gitleaks findings are converted to match the TruffleHog format for consistency:

```json
{
  "DetectorName": "Gitleaks:aws-access-token",
  "DecoderName": "Gitleaks",
  "Verified": false,
  "Raw": "AKIAIOSFODNN7EXAMPLE",
  "SourceMetadata": {
    "Data": {
      "Git": {
        "commit": "abc123...",
        "file": "config.py",
        "email": "user@example.com",
        "timestamp": "2024-01-15T10:30:00Z",
        "line": 42
      }
    }
  },
  "ExtraData": {
    "gitleaks_rule": "aws-access-token",
    "gitleaks_description": "AWS Access Key",
    "gitleaks_match": "AKIA...",
    "gitleaks_entropy": 4.5
  },
  "scanner": "gitleaks"
}
```

### Distinguishing Scanners

Results include a `scanner` field:
- `"scanner": "trufflehog"` - Found by TruffleHog (usually verified)
- `"scanner": "gitleaks"` - Found by Gitleaks (pattern-based)

## Scanner Modules

### Force-Push Scanner

The Python-based force-push scanner automatically uses both tools:

```python
# Scans with TruffleHog
trufflehog_findings = scan_with_trufflehog(repo_path, ...)

# Scans with Gitleaks if available
gitleaks_findings = scan_with_gitleaks(repo_path, ...)

# Merges results, removing duplicates
findings = merge_scan_results(trufflehog_findings, gitleaks_findings)
```

### Organization Scanner

The bash-based org scanner runs both scanners in parallel:

```bash
# TruffleHog scan
trufflehog git --json --only-verified --no-update "file://$(pwd)" > trufflehog.json

# Gitleaks scan (if available)
gitleaks detect --source "$(pwd)" --report-format json --report-path gitleaks.json

# Results are merged in post-processing
```

### Repository Scanner

Similar dual-scanner approach:

```bash
cd repo-scanner/
./scan_repo_simple.sh owner/repo

# Automatically uses both scanners if available
# ✅ TruffleHog scan completed
# ✅ Gitleaks scan completed
# 📊 Merged 15 secrets (10 from TruffleHog, 8 from Gitleaks, 3 duplicates removed)
```

## Performance

- **Gitleaks** is typically faster than TruffleHog (no verification overhead)
- **Adaptive timeouts**: Gitleaks gets half the timeout of TruffleHog
- **Non-blocking**: Gitleaks scan failure doesn't prevent TruffleHog results
- **Parallel processing**: Both scanners can run concurrently when possible

## Verification Status

- **TruffleHog findings**: `Verified: true` (credentials actively validated)
- **Gitleaks findings**: `Verified: false` (pattern-based detection)

Use the `Verified` field to prioritize findings during triage.

## Disabling Gitleaks

If you want to use TruffleHog only:

1. **Don't install Gitleaks** - scanners will detect its absence
2. **Or uninstall it**: `brew uninstall gitleaks` / `rm /usr/local/bin/gitleaks`

The scanners will continue working with TruffleHog alone.

## Troubleshooting

### Gitleaks not detected

```bash
# Check if Gitleaks is in PATH
which gitleaks

# Verify installation
gitleaks version

# Reinstall if needed
./install_requirements.sh --gitleaks-only
```

### Gitleaks timeout

Increase timeout in scanner scripts:

```bash
# For org-scanner
export TRUFFLEHOG_BASE_TIMEOUT=1800  # Also affects Gitleaks proportionally

# For repo-scanner
export TRUFFLEHOG_BASE_TIMEOUT=1800
```

### Too many Gitleaks findings

Gitleaks can be more sensitive than TruffleHog. Filter by:

1. **Verified status**: Focus on `Verified: true` (TruffleHog findings)
2. **Entropy**: Check `gitleaks_entropy` in `ExtraData` (higher = more likely real)
3. **Rule type**: Use `gitleaks_rule` to filter by secret type

## Contributing

Ideas for improvement:
- Custom Gitleaks rule configurations
- Configurable scanner priority
- Enhanced deduplication logic
- Scanner result analytics

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.
