# 🔍 Secret Analyzer

Analyze leaked secrets from scan results to determine active status, risk level, and remediation steps.

## 📁 Structure

```
analyzer/
├── alchemy/                    # Alchemy analyzer
│   └── analyze.sh             # Script to analyze all Alchemy secrets
├── aws/                       # AWS analyzer (TODO)
│   └── analyze.sh
├── azure/                     # Azure analyzer (TODO)
│   └── analyze.sh
└── analyzed_results/          # Output directory (organized by detector)
    ├── alchemy/
    │   ├── yearn_analysis.json
    │   └── uniswap_analysis.json
    └── aws/
        └── org1_analysis.json
```

Each detector has its own folder with an independent `analyze.sh` script.

## 🚀 Quick Start

### Run Alchemy analyzer
```bash
cd analyzer/alchemy
./analyze.sh
```

### Run AWS analyzer
```bash
cd analyzer/aws
./analyze.sh
```

Each analyzer script will:
1. Find all secrets of that type in `force-push-scanner/leaked_secrets_results`
2. Verify if secrets are still active
3. Assess risk level
4. Save analysis to `analyzer/analyzed_results/{detector}/`

## 📊 Output Format

Each analysis creates a JSON file in `analyzed_results/{DetectorName}/{org}_analysis.json`:

```json
{
  "organization": "yearn",
  "detector_type": "Alchemy",
  "total_secrets": 17,
  "total_analyzed": 17,
  "analysis_timestamp": "2025-10-06T...",
  "summary": {
    "by_status": {
      "ACTIVE": 2,
      "REVOKED": 15,
      "UNKNOWN": 0
    },
    "by_risk": {
      "CRITICAL": 2,
      "HIGH": 10,
      "MEDIUM": 5,
      "LOW": 0
    },
    "average_risk_score": 65.4
  },
  "secrets": [
    {
      "secret_hash": "a1b2c3d4e5f6...",
      "detector_name": "Alchemy",
      "organization": "yearn",
      "repository": "https://github.com/yearn/yearn-finance",
      "commit": "9f7dc8f...",
      "file": "app/components/...",
      "timestamp": "2021-01-19 00:24:27 +0000",
      "verification": {
        "status": "ACTIVE",
        "details": {
          "network": "eth-mainnet",
          "working": true
        }
      },
      "risk_assessment": {
        "risk_level": "CRITICAL",
        "risk_factors": [
          "Key was verified as valid",
          "Can query blockchain data"
        ],
        "score": 85
      },
      "remediation_steps": [
        "1. Immediately revoke the leaked API key",
        "2. Create a new API key with restrictions",
        "..."
      ],
      "analyzed_at": "2025-10-06T..."
    }
  ]
}
```

## 🔧 Creating a New Analyzer

1. **Create a new folder** for your detector:
```bash
mkdir analyzer/aws
```

2. **Copy the template** from alchemy:
```bash
cp analyzer/alchemy/analyze.sh analyzer/aws/analyze.sh
```

3. **Edit the script**:
   - Change detector name references from "Alchemy" to your detector
   - Update the API verification logic for your service
   - Customize risk assessment
   - Update remediation steps

4. **Run it**:
```bash
cd analyzer/aws
./analyze.sh
```

## 🎯 What Each Analyzer Does

### Verification
- Tests if the leaked secret is still active
- Makes API calls to the service (if safe)
- Returns status: ACTIVE, REVOKED, or UNKNOWN

### Risk Assessment
- Calculates risk score (0-100)
- Identifies risk factors:
  - Age of leak
  - Verification status
  - Permissions level
  - Exposure time
- Assigns risk level: CRITICAL, HIGH, MEDIUM, LOW

### Remediation
- Provides step-by-step instructions
- Service-specific guidance
- Security best practices

## 📋 Priority Analyzers to Create

Based on your scan results, these are the most common detector types:

1. **AWS** - Cloud credentials (high value)
2. **GitHub** - Repository access tokens
3. **Azure** - Cloud credentials
4. **MongoDB** - Database connection strings
5. **Postgres/SQLServer** - Database credentials
6. **PrivateKey** - Generic private keys (crypto wallets, SSH, etc.)
7. **Slack/Discord/Telegram** - Webhook URLs
8. **SendGrid/Mailgun/Twilio** - Communication APIs
9. **Vercel/Netlify** - Deployment tokens
10. **Docker** - Registry credentials

## ⚠️ Important Notes

- **Never commit actual secrets** - The analyzer uses hashes to identify secrets
- **Rate limiting** - Be careful when verifying many secrets rapidly
- **API costs** - Some verification calls may incur costs (e.g., AWS)
- **Ethical use** - Only analyze secrets you have permission to test
- **Results privacy** - Analyzed results contain sensitive information

## 🔒 Security Considerations

1. Results are stored locally in `analyzed_results/`
2. Secrets are hashed in output (SHA256)
3. Add `analyzer/analyzed_results/` to `.gitignore`
4. Consider encrypting analysis results if storing long-term

## 📈 Future Enhancements

- [ ] Parallel analysis for faster processing
- [ ] HTML/PDF report generation
- [ ] Integration with notification system
- [ ] Historical tracking (is key still active over time?)
- [ ] Automated bug bounty report generation
- [ ] Dashboard for visualization
