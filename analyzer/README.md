# 🔍 Secret Analyzer

Analyze leaked secrets from scan results to determine active status, risk level, and remediation steps.

## 🚀 Quick Start

```bash
# Run all analyzers (verifies ~50 secret types)
bash analyzer/run_all_analyzers.sh

# Generate interactive dashboard
bash analyzer/generate_dashboard.sh
```

Dashboard opens at: `analyzer/visualizations/dashboard.html`

### What You Get

- ✅ Verification status (Active/Revoked/Rate Limited)
- 🎯 Risk scores (Critical/High/Medium/Low)
- 📊 Interactive charts and statistics
- 🔍 Searchable table of all secrets
- 🛡️ API capabilities analysis
