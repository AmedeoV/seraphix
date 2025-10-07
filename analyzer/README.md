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

## 📁 Structure

```
analyzer/
├── analyzers/              # 49+ analyzer scripts (AWS, Alchemy, MongoDB, etc.)
├── analyzed_results/       # Analysis JSON files per detector/organization
├── visualizations/         # Generated dashboard
│   └── dashboard.html
├── generate_dashboard.sh   # Dashboard generator
└── run_all_analyzers.sh    # Run all analyzers
```

## 🔧 Advanced Usage

### Run Specific Analyzers

```bash
# Single organization
bash analyzer/analyzers/aws_analyzer.sh organization-name

# All organizations for a detector
bash analyzer/analyzers/aws_analyzer.sh --all
```

### What Analyzers Do

1. Find all secrets of that type in scan results
2. Verify if secrets are still active
3. Assess risk level and capabilities
4. Save analysis to `analyzed_results/{detector}/`

## 📊 Output Format

Each analysis creates a JSON file in `analyzed_results/{DetectorName}/{org}_analysis.json` with:
- Verification status (ACTIVE/REVOKED/UNKNOWN)
- Risk assessment (CRITICAL/HIGH/MEDIUM/LOW)
- Capabilities and permissions
- Remediation steps

## ⚠️ Important Notes

- **Ethical use** - Only analyze secrets you have permission to test
- **Rate limiting** - Be careful when verifying many secrets rapidly
- **Results privacy** - Analysis files contain sensitive information (add to `.gitignore`)
