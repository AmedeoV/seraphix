# 🔍 Secret Analyzer

Analyze leaked secrets from scan results to determine active status, risk level, and remediation steps.

## 📁 Structure

```
analyzer/
├── detectors/                  # All analyzer scripts
│   ├── alchemy_analyzer.sh    # Alchemy blockchain API keys
│   ├── algolia_analyzer.sh    # Algolia search API keys
│   ├── alibaba_analyzer.sh    # Alibaba Cloud credentials
│   ├── artifactory_analyzer.sh # JFrog Artifactory tokens
│   ├── assemblyai_analyzer.sh  # AssemblyAI API keys
│   ├── aws_analyzer.sh         # AWS credentials
│   ├── azure_analyzer.sh       # Azure Storage account keys
│   └── browserstack_analyzer.sh # BrowserStack testing credentials
├── analyzed_results/           # Output directory (organized by detector)
│   ├── Alchemy/
│   ├── algolia/
│   ├── Alibaba/
│   ├── Artifactory/
│   ├── AssemblyAI/
│   ├── AWS/
│   ├── Azure/
│   └── BrowserStack/
├── visualizations/             # Dashboard HTML files
│   └── dashboard.html
└── generate_dashboard.sh       # Generate interactive dashboards
```

## 🚀 Quick Start

### Analyze a Specific Organization

```bash
# AssemblyAI
bash analyzer/detectors/assemblyai_analyzer.sh nwakaku

# Artifactory
bash analyzer/detectors/artifactory_analyzer.sh braintree

# AWS
bash analyzer/detectors/aws_analyzer.sh enajera

# Azure
bash analyzer/detectors/azure_analyzer.sh microsoft

# BrowserStack
bash analyzer/detectors/browserstack_analyzer.sh IronCoreLabs
```

### Analyze ALL Organizations

```bash
# AssemblyAI - analyze all organizations with AssemblyAI secrets
bash analyzer/detectors/assemblyai_analyzer.sh --all

# Artifactory - analyze all organizations with Artifactory tokens
bash analyzer/detectors/artifactory_analyzer.sh --all

# AWS - analyze all organizations with AWS credentials
bash analyzer/detectors/aws_analyzer.sh --all

# Azure - analyze all organizations with Azure Storage keys
bash analyzer/detectors/azure_analyzer.sh --all

# BrowserStack - analyze all organizations with BrowserStack credentials
bash analyzer/detectors/browserstack_analyzer.sh --all

# Alchemy - automatically processes all organizations (no flags needed)
bash analyzer/detectors/alchemy_analyzer.sh

# Algolia - automatically processes all organizations (no flags needed)
bash analyzer/detectors/algolia_analyzer.sh

# Alibaba - automatically processes all organizations (no flags needed)
bash analyzer/detectors/alibaba_analyzer.sh

# Generate dashboard for all detectors
bash analyzer/generate_dashboard.sh all
```

### Analyzer Types

**📌 Organization-specific analyzers** (support both single org and `--all` mode):
- `assemblyai_analyzer.sh` - AssemblyAI transcription API keys
- `artifactory_analyzer.sh` - JFrog Artifactory access tokens
- `aws_analyzer.sh` - AWS access keys and secret keys
- `azure_analyzer.sh` - Azure Storage account keys
- `browserstack_analyzer.sh` - BrowserStack testing credentials
- `aws_analyzer.sh` - AWS access keys and secret keys
- `azure_analyzer.sh` - Azure Storage account keys

**🔄 Auto-processing analyzers** (automatically scan all organizations):
- `alchemy_analyzer.sh` - Alchemy blockchain API keys
- `algolia_analyzer.sh` - Algolia search API admin keys
- `alibaba_analyzer.sh` - Alibaba Cloud API credentials

Each analyzer script will:
1. Find all secrets of that type in `leaked_secrets_results` (across all scanners)
2. Verify if secrets are still active
3. Assess risk level and capabilities
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

##  Automatic Deduplication

### Overview

The analyzer now includes **automatic deduplication** of secrets to eliminate duplicates within each organization's results.

### How It Works

Deduplication runs automatically after all analyzers complete:

1. **Post-Processing Script**: \deduplicate_analysis_results.py2. **Trigger**: Automatically runs when using \ash run_all_analyzers.sh3. **Scope**: Removes duplicate secrets within each organization
4. **Method**: SHA256 hash comparison of raw secret values

### When Deduplication Runs

-  **Automatically**: When running \ash run_all_analyzers.sh-  **Manually**: \python3 analyzer/deduplicate_analysis_results.py
### What Gets Deduplicated

- Duplicate secrets within the same organization's analysis
- Based on SHA256 hash of the raw secret value
- Preserves the first occurrence, removes subsequent duplicates
- Updates summary statistics (total_secrets, active_percentage, etc.)

### What Doesn't Get Deduplicated

- Cross-organization duplicates (intentional - shows credential reuse)
- Different credential formats of the same secret
- Secrets with different metadata but same raw value across organizations

### Manual Deduplication

If needed, run deduplication separately:

\\ash
cd analyzer
python3 deduplicate_analysis_results.py
\
### Integration with run_all_analyzers.sh

The main analyzer runner now includes automatic deduplication:

\\ash
bash run_all_analyzers.sh
# 1. Runs all 50+ analyzers
# 2. Automatically deduplicates results  
# 3. Shows summary statistics
# 4. Ready for dashboard generation
\
After deduplication, regenerate the dashboard to see updated counts:

\\ash
bash analyzer/generate_dashboard.sh all
\EOF
