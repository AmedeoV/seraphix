# 📊 Analyzer Visualizations

Interactive dashboards for analyzing leaked secrets scan results.

## Quick Start

### Generate Dashboard

```bash
bash analyzer/generate_dashboard.sh
```

This will:
1. Process all analysis files in `analyzer/analyzed_results/alchemy/`
2. Generate an interactive HTML dashboard
3. Save to `analyzer/visualizations/alchemy_dashboard.html`

### View Dashboard

Open the generated file in your browser:
- **Windows**: Double-click `alchemy_dashboard.html`
- **Linux/Mac**: `open analyzer/visualizations/alchemy_dashboard.html`
- **Or**: Navigate to `file:///path/to/seraphix/analyzer/visualizations/alchemy_dashboard.html`

## Dashboard Features

### 📈 Summary Cards
- Total Organizations
- Total Secrets Found
- Active Keys (still working)
- Risk Level Distribution (Critical, High, Medium, Low)

### 📊 Interactive Charts
1. **Risk Distribution** - Pie chart showing secrets by risk level
2. **Status Breakdown** - Active vs Revoked vs Rate Limited
3. **API Capabilities** - Which APIs the keys can access
4. **Top Organizations** - Organizations with most leaked secrets

### 🔍 Detailed Table
Searchable and filterable table with:
- **Search** - Filter by organization, commit, or file
- **Risk Filter** - Show only Critical/High/Medium/Low risks
- **Status Filter** - Show only Active/Revoked/Rate Limited keys

Each row shows:
- Organization name
- Git commit (first 7 chars)
- Verification status
- Risk level and score
- API capabilities (Node, NFT, Token)
- Number of blockchain networks accessible

### Current Statistics

Based on the latest analysis:

```
Organizations: 17
Total Secrets: 135
Active Keys: 127 (94%)
Revoked: 0
Rate Limited: 8

Risk Breakdown:
├─ Critical: High-value targets
├─ High: Significant capabilities
├─ Medium: Limited capabilities
└─ Low: Revoked or restricted
```

## Key Findings

### ⚠️ Critical Insights

1. **94% of keys are still ACTIVE** 🚨
   - Most organizations haven't revoked leaked keys
   - Immediate security risk

2. **Multi-Chain Access Common**
   - Many keys can access Ethereum, Polygon, Arbitrum, Optimism
   - Increases attack surface

3. **Full API Capabilities**
   - Most active keys have Node API + NFT API access
   - Can read blockchain data and query NFTs

### 🎯 Top Organizations by Secrets
- daimo-eth: 50 secrets
- iearn-finance: 18 secrets
- zeriontech: 18 secrets
- GoodDollar: 10 secrets
- cartesi: 8 secrets

## Technical Details

### Data Source
- Reads from: `analyzer/analyzed_results/alchemy/*_analysis.json`
- Each file contains analyzed secrets for one organization

### Dependencies
- **jq** - JSON processing (required for generation)
- **Chart.js** - Loaded from CDN (no installation needed)
- **Modern browser** - Chrome, Firefox, Safari, Edge

### File Structure
```
analyzer/
├── generate_dashboard.sh          # Dashboard generator
├── detectors/
│   └── alchemy_analyzer.sh        # Analysis script
├── analyzed_results/
│   └── alchemy/
│       ├── cartesi_analysis.json
│       ├── hoprnet_analysis.json
│       └── ...
└── visualizations/
    └── alchemy_dashboard.html     # Generated dashboard
```

## Workflow

### Complete Analysis + Visualization

```bash
# Step 1: Run analyzer
bash analyzer/detectors/alchemy_analyzer.sh

# Step 2: Generate dashboard
bash analyzer/generate_dashboard.sh

# Step 3: Open in browser
open analyzer/visualizations/alchemy_dashboard.html
```

### Update Existing Dashboard

Just re-run the generator after new analysis:
```bash
bash analyzer/generate_dashboard.sh
```

It will automatically:
- Find all new analysis files
- Recalculate statistics
- Generate fresh dashboard

## Sharing

The dashboard is a **single HTML file** that can be:
- ✅ Opened offline (no internet required after first load)
- ✅ Shared via email or file sharing
- ✅ Committed to git (contains no sensitive data, only hashes)
- ✅ Hosted on a web server
- ✅ Embedded in reports

**Note**: The dashboard shows secret hashes, not the actual keys, so it's safe to share.

## Customization

### Change Colors
Edit the `chartColors` object in the HTML file:
```javascript
const chartColors = {
    critical: '#e74c3c',  // Red
    high: '#f39c12',      // Orange
    // ...
};
```

### Add More Charts
The dashboard uses Chart.js. Add new charts by:
1. Adding a canvas element
2. Creating a new Chart instance
3. Providing data from `secretsData`

### Export Features
Want CSV export? Add this button to the HTML:
```javascript
function exportToCSV() {
    // Implementation available on request
}
```

## Troubleshooting

### Dashboard shows no data
- Check that analysis files exist in `analyzer/analyzed_results/alchemy/`
- Run `bash analyzer/detectors/alchemy_analyzer.sh` first

### Charts not rendering
- Check browser console for JavaScript errors
- Ensure Chart.js CDN is accessible
- Try opening in incognito mode (clears cache)

### jq command not found
```bash
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq

# Windows (WSL)
sudo apt-get install jq
```

## Next Steps

Consider adding:
- [ ] Markdown report generator
- [ ] CSV export functionality
- [ ] Timeline visualization
- [ ] Automated email reports
- [ ] Integration with notification systems
- [ ] Historical trend analysis

---

**Generated**: $(date)
**Location**: `analyzer/visualizations/`
**Format**: Self-contained HTML5
