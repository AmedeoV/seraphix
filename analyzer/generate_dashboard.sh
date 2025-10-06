#!/bin/bash
# Generate HTML Dashboard from Alchemy Analysis Results
# 
# Reads all *_analysis.json files and creates an interactive dashboard

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/analyzed_results/alchemy"
OUTPUT_FILE="$SCRIPT_DIR/visualizations/alchemy_dashboard.html"

echo "📊 Generating Alchemy Secrets Dashboard..."
echo ""

# Create visualizations directory
mkdir -p "$SCRIPT_DIR/visualizations"

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Error: jq is required but not installed"
    exit 1
fi

# Collect statistics
total_secrets=0
active_secrets=0
revoked_secrets=0
rate_limited_secrets=0
unknown_secrets=0

critical_count=0
high_count=0
medium_count=0
low_count=0

org_count=0

# Count capabilities
node_api_count=0
nft_api_count=0
token_api_count=0
multichain_count=0

# Process all analysis files
echo "📂 Processing analysis files from: $RESULTS_DIR"

for analysis_file in "$RESULTS_DIR"/*_analysis.json; do
    if [ ! -f "$analysis_file" ]; then
        continue
    fi
    
    org_name=$(basename "$analysis_file" | sed 's/_analysis.json//')
    secrets_in_file=$(jq '.total_secrets' "$analysis_file" 2>/dev/null || echo "0")
    
    if [ "$secrets_in_file" = "0" ] || [ "$secrets_in_file" = "null" ]; then
        continue
    fi
    
    echo "  Processing: $org_name ($secrets_in_file secrets)"
    
    org_count=$((org_count + 1))
    total_secrets=$((total_secrets + secrets_in_file))
    
    # Count by status
    active=$(jq '[.secrets[] | select(.verification.status == "ACTIVE")] | length' "$analysis_file" 2>/dev/null || echo "0")
    revoked=$(jq '[.secrets[] | select(.verification.status == "REVOKED")] | length' "$analysis_file" 2>/dev/null || echo "0")
    rate_limited=$(jq '[.secrets[] | select(.verification.status == "RATE_LIMITED")] | length' "$analysis_file" 2>/dev/null || echo "0")
    
    active_secrets=$((active_secrets + active))
    revoked_secrets=$((revoked_secrets + revoked))
    rate_limited_secrets=$((rate_limited_secrets + rate_limited))
    
    # Count by risk level
    critical=$(jq '[.secrets[] | select(.risk_assessment.risk_level == "CRITICAL")] | length' "$analysis_file" 2>/dev/null || echo "0")
    high=$(jq '[.secrets[] | select(.risk_assessment.risk_level == "HIGH")] | length' "$analysis_file" 2>/dev/null || echo "0")
    medium=$(jq '[.secrets[] | select(.risk_assessment.risk_level == "MEDIUM")] | length' "$analysis_file" 2>/dev/null || echo "0")
    low=$(jq '[.secrets[] | select(.risk_assessment.risk_level == "LOW")] | length' "$analysis_file" 2>/dev/null || echo "0")
    
    critical_count=$((critical_count + critical))
    high_count=$((high_count + high))
    medium_count=$((medium_count + medium))
    low_count=$((low_count + low))
    
    echo "    Risk: C=$critical H=$high M=$medium L=$low"
    
    # Count capabilities
    node_api=$(jq '[.secrets[] | select(.capabilities.node_api == true)] | length' "$analysis_file" 2>/dev/null || echo "0")
    nft_api=$(jq '[.secrets[] | select(.capabilities.nft_api == true)] | length' "$analysis_file" 2>/dev/null || echo "0")
    token_api=$(jq '[.secrets[] | select(.capabilities.token_api == true)] | length' "$analysis_file" 2>/dev/null || echo "0")
    multichain=$(jq '[.secrets[] | select(.capabilities.multi_chain_enabled == true)] | length' "$analysis_file" 2>/dev/null || echo "0")
    
    node_api_count=$((node_api_count + node_api))
    nft_api_count=$((nft_api_count + nft_api))
    token_api_count=$((token_api_count + token_api))
    multichain_count=$((multichain_count + multichain))
done

unknown_secrets=$((total_secrets - active_secrets - revoked_secrets - rate_limited_secrets))

echo ""
echo "📊 Statistics:"
echo "  Organizations: $org_count"
echo "  Total Secrets: $total_secrets"
echo "  Active: $active_secrets"
echo "  Revoked: $revoked_secrets"
echo "  Rate Limited: $rate_limited_secrets"
echo ""

# Generate HTML Dashboard
cat > "$OUTPUT_FILE" <<'HTML_START'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Alchemy Secrets Analysis Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
        }
        
        .header {
            text-align: center;
            color: white;
            margin-bottom: 30px;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .stat-card {
            background: white;
            border-radius: 12px;
            padding: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.2s;
        }
        
        .stat-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 6px 12px rgba(0,0,0,0.15);
        }
        
        .stat-card h3 {
            font-size: 0.9em;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .stat-card .value {
            font-size: 2.5em;
            font-weight: bold;
            color: #333;
        }
        
        .stat-card .subtext {
            font-size: 0.85em;
            color: #999;
            margin-top: 5px;
        }
        
        .stat-card.critical { border-left: 4px solid #e74c3c; }
        .stat-card.high { border-left: 4px solid #f39c12; }
        .stat-card.medium { border-left: 4px solid #f1c40f; }
        .stat-card.low { border-left: 4px solid #95a5a6; }
        .stat-card.success { border-left: 4px solid #27ae60; }
        .stat-card.info { border-left: 4px solid #3498db; }
        
        .charts-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .chart-card {
            background: white;
            border-radius: 12px;
            padding: 25px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        
        .chart-card h2 {
            font-size: 1.2em;
            color: #333;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #f0f0f0;
        }
        
        .table-card {
            background: white;
            border-radius: 12px;
            padding: 25px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            overflow-x: auto;
        }
        
        .controls {
            margin-bottom: 20px;
            display: flex;
            gap: 15px;
            flex-wrap: wrap;
        }
        
        .controls input,
        .controls select {
            padding: 10px 15px;
            border: 1px solid #ddd;
            border-radius: 6px;
            font-size: 14px;
            flex: 1;
            min-width: 200px;
        }
        
        .controls input:focus,
        .controls select:focus {
            outline: none;
            border-color: #667eea;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
        }
        
        thead {
            background: #f8f9fa;
        }
        
        th {
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: #333;
            border-bottom: 2px solid #dee2e6;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #f0f0f0;
        }
        
        tbody tr:hover {
            background: #f8f9fa;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: 600;
            text-transform: uppercase;
        }
        
        .badge.critical { background: #fee; color: #e74c3c; }
        .badge.high { background: #fef5e7; color: #f39c12; }
        .badge.medium { background: #fef9e7; color: #f1c40f; }
        .badge.low { background: #ecf0f1; color: #95a5a6; }
        
        .badge.active { background: #d4edda; color: #28a745; }
        .badge.revoked { background: #f8d7da; color: #dc3545; }
        .badge.rate-limited { background: #fff3cd; color: #856404; }
        
        .capability-badges {
            display: flex;
            gap: 5px;
            flex-wrap: wrap;
        }
        
        .capability-badge {
            background: #e3f2fd;
            color: #1976d2;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 0.75em;
            font-weight: 500;
        }
        
        .score {
            font-weight: bold;
            font-size: 1.1em;
        }
        
        @media (max-width: 768px) {
            .stats-grid {
                grid-template-columns: repeat(2, 1fr);
            }
            
            .charts-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔐 Alchemy Secrets Analysis Dashboard</h1>
            <p>Comprehensive analysis of leaked Alchemy API keys</p>
        </div>
        
        <div class="stats-grid">
HTML_START

# Add stat cards with actual data
cat >> "$OUTPUT_FILE" <<STATS_CARDS
            <div class="stat-card info">
                <h3>Total Organizations</h3>
                <div class="value">$org_count</div>
                <div class="subtext">Analyzed</div>
            </div>
            
            <div class="stat-card">
                <h3>Total Secrets</h3>
                <div class="value">$total_secrets</div>
                <div class="subtext">API Keys Found</div>
            </div>
            
            <div class="stat-card success">
                <h3>Active Keys</h3>
                <div class="value">$active_secrets</div>
                <div class="subtext">$([ $total_secrets -gt 0 ] && echo "scale=1; $active_secrets * 100 / $total_secrets" | bc || echo "0")% Still Working</div>
            </div>
            
            <div class="stat-card critical">
                <h3>Critical Risk</h3>
                <div class="value">$critical_count</div>
                <div class="subtext">Immediate Action Required</div>
            </div>
            
            <div class="stat-card high">
                <h3>High Risk</h3>
                <div class="value">$high_count</div>
                <div class="subtext">Priority Remediation</div>
            </div>
            
            <div class="stat-card medium">
                <h3>Medium Risk</h3>
                <div class="value">$medium_count</div>
                <div class="subtext">Monitor Closely</div>
            </div>
        </div>
        
        <div class="charts-grid">
            <div class="chart-card">
                <h2>📊 Risk Distribution</h2>
                <canvas id="riskChart"></canvas>
            </div>
            
            <div class="chart-card">
                <h2>🔄 Status Breakdown</h2>
                <canvas id="statusChart"></canvas>
            </div>
            
            <div class="chart-card">
                <h2>🛠️ API Capabilities</h2>
                <canvas id="capabilitiesChart"></canvas>
            </div>
            
            <div class="chart-card">
                <h2>🏢 Top Organizations by Secrets</h2>
                <canvas id="orgsChart"></canvas>
            </div>
        </div>
        
        <div class="table-card">
            <h2>🔍 Detailed Findings</h2>
            <div class="controls">
                <input type="text" id="searchInput" placeholder="🔎 Search organization, commit, file...">
                <select id="riskFilter">
                    <option value="">All Risk Levels</option>
                    <option value="CRITICAL">Critical</option>
                    <option value="HIGH">High</option>
                    <option value="MEDIUM">Medium</option>
                    <option value="LOW">Low</option>
                </select>
                <select id="statusFilter">
                    <option value="">All Statuses</option>
                    <option value="ACTIVE">Active</option>
                    <option value="REVOKED">Revoked</option>
                    <option value="RATE_LIMITED">Rate Limited</option>
                </select>
            </div>
            <table id="secretsTable">
                <thead>
                    <tr>
                        <th>Organization</th>
                        <th>Commit</th>
                        <th>Status</th>
                        <th>Risk</th>
                        <th>Score</th>
                        <th>Capabilities</th>
                        <th>Chains</th>
                    </tr>
                </thead>
                <tbody id="tableBody">
                </tbody>
            </table>
        </div>
    </div>
    
    <script>
        // Chart.js configurations
        const chartColors = {
            critical: '#e74c3c',
            high: '#f39c12',
            medium: '#f1c40f',
            low: '#95a5a6',
            active: '#27ae60',
            revoked: '#e74c3c',
            rateLimited: '#f39c12'
        };
        
        // Risk Distribution Pie Chart
        new Chart(document.getElementById('riskChart'), {
            type: 'doughnut',
            data: {
                labels: ['Critical', 'High', 'Medium', 'Low'],
                datasets: [{
                    data: [$critical_count, $high_count, $medium_count, $low_count],
                    backgroundColor: [
                        chartColors.critical,
                        chartColors.high,
                        chartColors.medium,
                        chartColors.low
                    ]
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        position: 'bottom'
                    }
                }
            }
        });
        
        // Status Breakdown Pie Chart
        new Chart(document.getElementById('statusChart'), {
            type: 'pie',
            data: {
                labels: ['Active', 'Revoked', 'Rate Limited'],
                datasets: [{
                    data: [$active_secrets, $revoked_secrets, $rate_limited_secrets],
                    backgroundColor: [
                        chartColors.active,
                        chartColors.revoked,
                        chartColors.rateLimited
                    ]
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        position: 'bottom'
                    }
                }
            }
        });
        
        // Capabilities Bar Chart
        new Chart(document.getElementById('capabilitiesChart'), {
            type: 'bar',
            data: {
                labels: ['Node API', 'NFT API', 'Token API', 'Multi-Chain'],
                datasets: [{
                    label: 'Keys with Capability',
                    data: [$node_api_count, $nft_api_count, $token_api_count, $multichain_count],
                    backgroundColor: '#667eea'
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        display: false
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true
                    }
                }
            }
        });
        
        // Load secrets data
        const secretsData = [
STATS_CARDS

# Generate JavaScript data for table
# We need to track if we've added the first entry across ALL files
first_secret_added=false

for analysis_file in "$RESULTS_DIR"/*_analysis.json; do
    if [ ! -f "$analysis_file" ]; then
        continue
    fi
    
    org_name=$(basename "$analysis_file" | sed 's/_analysis.json//')
    
    # Extract secrets and format as JavaScript objects
    jq -c '.secrets[]' "$analysis_file" 2>/dev/null | while IFS= read -r secret; do
        if [ -z "$secret" ]; then
            continue
        fi
        
        commit=$(echo "$secret" | jq -r '.commit[0:7]')
        status=$(echo "$secret" | jq -r '.verification.status')
        risk_level=$(echo "$secret" | jq -r '.risk_assessment.risk_level')
        risk_score=$(echo "$secret" | jq -r '.risk_assessment.score')
        node_api=$(echo "$secret" | jq -r '.capabilities.node_api')
        nft_api=$(echo "$secret" | jq -r '.capabilities.nft_api')
        token_api=$(echo "$secret" | jq -r '.capabilities.token_api')
        chains=$(echo "$secret" | jq -r '.capabilities.supported_chains | length')
        
        # Add comma before this entry if it's not the very first one
        if [ -f "$OUTPUT_FILE.tmp" ]; then
            echo "," >> "$OUTPUT_FILE"
        else
            touch "$OUTPUT_FILE.tmp"
        fi
        
        cat >> "$OUTPUT_FILE" <<SECRET_ENTRY
            {
                organization: "$org_name",
                commit: "$commit",
                status: "$status",
                riskLevel: "$risk_level",
                riskScore: $risk_score,
                nodeApi: $node_api,
                nftApi: $nft_api,
                tokenApi: $token_api,
                chains: $chains
            }
SECRET_ENTRY
    done
done

# Clean up temp file
rm -f "$OUTPUT_FILE.tmp"

# Complete the JavaScript and HTML
cat >> "$OUTPUT_FILE" <<'HTML_END'
        ];
        
        // Count secrets per org for chart
        const orgCounts = {};
        secretsData.forEach(s => {
            orgCounts[s.organization] = (orgCounts[s.organization] || 0) + 1;
        });
        
        const topOrgs = Object.entries(orgCounts)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 10);
        
        // Organizations Bar Chart
        new Chart(document.getElementById('orgsChart'), {
            type: 'bar',
            data: {
                labels: topOrgs.map(o => o[0]),
                datasets: [{
                    label: 'Secrets Found',
                    data: topOrgs.map(o => o[1]),
                    backgroundColor: '#764ba2'
                }]
            },
            options: {
                indexAxis: 'y',
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        display: false
                    }
                },
                scales: {
                    x: {
                        beginAtZero: true
                    }
                }
            }
        });
        
        // Populate table
        function populateTable(data) {
            const tbody = document.getElementById('tableBody');
            tbody.innerHTML = '';
            
            data.forEach(secret => {
                const row = document.createElement('tr');
                
                const capabilities = [];
                if (secret.nodeApi) capabilities.push('Node');
                if (secret.nftApi) capabilities.push('NFT');
                if (secret.tokenApi) capabilities.push('Token');
                
                row.innerHTML = `
                    <td><strong>${secret.organization}</strong></td>
                    <td><code>${secret.commit}</code></td>
                    <td><span class="badge ${secret.status.toLowerCase().replace('_', '-')}">${secret.status}</span></td>
                    <td><span class="badge ${secret.riskLevel.toLowerCase()}">${secret.riskLevel}</span></td>
                    <td><span class="score">${secret.riskScore}</span></td>
                    <td>
                        <div class="capability-badges">
                            ${capabilities.map(c => `<span class="capability-badge">${c}</span>`).join('')}
                        </div>
                    </td>
                    <td>${secret.chains} chain${secret.chains !== 1 ? 's' : ''}</td>
                `;
                
                tbody.appendChild(row);
            });
        }
        
        // Initial table population
        populateTable(secretsData);
        
        // Filtering logic
        function applyFilters() {
            const searchTerm = document.getElementById('searchInput').value.toLowerCase();
            const riskFilter = document.getElementById('riskFilter').value;
            const statusFilter = document.getElementById('statusFilter').value;
            
            const filtered = secretsData.filter(secret => {
                const matchesSearch = !searchTerm || 
                    secret.organization.toLowerCase().includes(searchTerm) ||
                    secret.commit.toLowerCase().includes(searchTerm);
                    
                const matchesRisk = !riskFilter || secret.riskLevel === riskFilter;
                const matchesStatus = !statusFilter || secret.status === statusFilter;
                
                return matchesSearch && matchesRisk && matchesStatus;
            });
            
            populateTable(filtered);
        }
        
        document.getElementById('searchInput').addEventListener('input', applyFilters);
        document.getElementById('riskFilter').addEventListener('change', applyFilters);
        document.getElementById('statusFilter').addEventListener('change', applyFilters);
    </script>
</body>
</html>
HTML_END

echo ""
echo "✅ Dashboard generated successfully!"
echo "📁 Location: $OUTPUT_FILE"
echo ""
echo "🌐 Open in browser:"
echo "   file://$(cd "$(dirname "$OUTPUT_FILE")" && pwd)/$(basename "$OUTPUT_FILE")"
echo ""
