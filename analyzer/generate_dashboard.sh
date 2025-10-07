#!/bin/bash
# Generate HTML Dashboard from Analysis Results
# 
# Reads all *_analysis.json files from multiple detector types and creates an interactive dashboard

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZED_RESULTS_DIR="$SCRIPT_DIR/analyzed_results"
OUTPUT_DIR="$SCRIPT_DIR/visualizations"

# Parse command line arguments
DETECTOR_TYPE="${1:-all}"

if [ "$DETECTOR_TYPE" = "all" ]; then
    echo "📊 Generating Multi-Detector Secrets Dashboard..."
    OUTPUT_FILE="$OUTPUT_DIR/dashboard.html"
else
    echo "📊 Generating ${DETECTOR_TYPE} Secrets Dashboard..."
    OUTPUT_FILE="$OUTPUT_DIR/${DETECTOR_TYPE}_dashboard.html"
fi
echo ""

# Create visualizations directory
mkdir -p "$SCRIPT_DIR/visualizations"

# Clean up any temporary files from previous runs
rm -f "$OUTPUT_DIR"/*.tmp

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

# Detector-specific counters
declare -A detector_counts
declare -A detector_active_counts

# Dynamic capability counters
declare -A capability_counts

# Determine which detectors to process
if [ "$DETECTOR_TYPE" = "all" ]; then
    echo "📂 Processing all detector results from: $ANALYZED_RESULTS_DIR"
    DETECTOR_DIRS=$(find "$ANALYZED_RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || echo "")
else
    echo "📂 Processing ${DETECTOR_TYPE} results from: $ANALYZED_RESULTS_DIR/${DETECTOR_TYPE}"
    if [ ! -d "$ANALYZED_RESULTS_DIR/$DETECTOR_TYPE" ]; then
        echo "❌ Error: Detector directory not found: $ANALYZED_RESULTS_DIR/$DETECTOR_TYPE"
        exit 1
    fi
    DETECTOR_DIRS="$ANALYZED_RESULTS_DIR/$DETECTOR_TYPE"
fi

if [ -z "$DETECTOR_DIRS" ]; then
    echo "❌ Error: No detector directories found"
    exit 1
fi

echo ""

# Process each detector directory
for detector_dir in $DETECTOR_DIRS; do
    if [ ! -d "$detector_dir" ]; then
        continue
    fi
    
    detector_name=$(basename "$detector_dir")
    echo "🔍 Processing detector: $detector_name"
    
    # Process all analysis files in this detector
    for analysis_file in "$detector_dir"/*_analysis.json; do
        if [ ! -f "$analysis_file" ]; then
            continue
        fi
        
        org_name=$(basename "$analysis_file" | sed 's/_analysis.json//')
        # Try both .total_secrets (Alchemy/Algolia/Alibaba) and .summary.total_secrets (Artifactory)
        secrets_in_file=$(jq '.total_secrets // .summary.total_secrets' "$analysis_file" 2>/dev/null || echo "0")
        
        if [ "$secrets_in_file" = "0" ] || [ "$secrets_in_file" = "null" ]; then
            continue
        fi
        
        echo "  Processing: $org_name ($secrets_in_file secrets)"
        
        org_count=$((org_count + 1))
        total_secrets=$((total_secrets + secrets_in_file))
        
        # Track per-detector counts
        detector_counts[$detector_name]=$((${detector_counts[$detector_name]:-0} + secrets_in_file))
        
        # Count by status - handle both formats
        # Alchemy/Algolia/Alibaba: .secrets[].verification.status
        # Artifactory: .secrets[].status
        active=$(jq '[.secrets[] | select((.verification.status // .status) == "ACTIVE")] | length' "$analysis_file" 2>/dev/null || echo "0")
        revoked=$(jq '[.secrets[] | select((.verification.status // .status) == "REVOKED")] | length' "$analysis_file" 2>/dev/null || echo "0")
        rate_limited=$(jq '[.secrets[] | select((.verification.status // .status) == "RATE_LIMITED")] | length' "$analysis_file" 2>/dev/null || echo "0")
        
        active_secrets=$((active_secrets + active))
        revoked_secrets=$((revoked_secrets + revoked))
        rate_limited_secrets=$((rate_limited_secrets + rate_limited))
        
        detector_active_counts[$detector_name]=$((${detector_active_counts[$detector_name]:-0} + active))
        
        # Count by risk level - handle both formats
        # Alchemy/Algolia/Alibaba: .secrets[].risk_assessment.risk_level
        # Artifactory: .secrets[].risk_level
        critical=$(jq '[.secrets[] | select((.risk_assessment.risk_level // .risk_level) == "CRITICAL")] | length' "$analysis_file" 2>/dev/null || echo "0")
        high=$(jq '[.secrets[] | select((.risk_assessment.risk_level // .risk_level) == "HIGH")] | length' "$analysis_file" 2>/dev/null || echo "0")
        medium=$(jq '[.secrets[] | select((.risk_assessment.risk_level // .risk_level) == "MEDIUM")] | length' "$analysis_file" 2>/dev/null || echo "0")
        low=$(jq '[.secrets[] | select((.risk_assessment.risk_level // .risk_level) == "LOW")] | length' "$analysis_file" 2>/dev/null || echo "0")
        
        critical_count=$((critical_count + critical))
        high_count=$((high_count + high))
        medium_count=$((medium_count + medium))
        low_count=$((low_count + low))
        
        echo "    Risk: C=$critical H=$high M=$medium L=$low"
        
        # Count capabilities dynamically (extract all boolean capabilities from first secret)
        if [ "$active" -gt 0 ]; then
            # Handle both .secrets[].verification.status and .secrets[].status formats
            capabilities=$(jq -r '.secrets[] | select((.verification.status // .status) == "ACTIVE") | .capabilities | keys[] | select(. != "supported_chains" and . != "acl_permissions")' "$analysis_file" 2>/dev/null | sort -u)
            for cap in $capabilities; do
                # Check if it's a boolean capability
                is_bool=$(jq -r ".secrets[0].capabilities.${cap} | type" "$analysis_file" 2>/dev/null)
                if [ "$is_bool" = "boolean" ]; then
                    cap_count=$(jq "[.secrets[] | select(.capabilities.${cap} == true)] | length" "$analysis_file" 2>/dev/null || echo "0")
                    capability_counts[$cap]=$((${capability_counts[$cap]:-0} + cap_count))
                fi
            done
        fi
    done
done

unknown_secrets=$((total_secrets - active_secrets - revoked_secrets - rate_limited_secrets))

echo ""
echo "📊 Statistics:"
echo "  Detectors: ${#detector_counts[@]}"
for detector in "${!detector_counts[@]}"; do
    echo "    - $detector: ${detector_counts[$detector]} secrets (${detector_active_counts[$detector]:-0} active)"
done
echo "  Organizations: $org_count"
echo "  Total Secrets: $total_secrets"
echo "  Active: $active_secrets"
echo "  Revoked: $revoked_secrets"
echo "  Rate Limited: $rate_limited_secrets"
echo ""

# Prepare detector chart data
DETECTOR_LABELS=""
DETECTOR_DATA=""
first_detector=true

for detector in "${!detector_counts[@]}"; do
    # Format detector name (capitalize)
    detector_label=$(echo "$detector" | sed 's/\b\w/\U&/g')
    
    if [ "$first_detector" = true ]; then
        DETECTOR_LABELS="'$detector_label'"
        DETECTOR_DATA="${detector_counts[$detector]}"
        first_detector=false
    else
        DETECTOR_LABELS="$DETECTOR_LABELS, '$detector_label'"
        DETECTOR_DATA="$DETECTOR_DATA, ${detector_counts[$detector]}"
    fi
done

# If no detectors, show placeholder
if [ "$first_detector" = true ]; then
    DETECTOR_LABELS="'No Detectors'"
    DETECTOR_DATA="0"
fi

# Determine dashboard title
if [ "$DETECTOR_TYPE" = "all" ]; then
    DASHBOARD_TITLE="Multi-Detector Secrets Analysis Dashboard"
else
    # Capitalize first letter
    detector_cap=$(echo "$DETECTOR_TYPE" | sed 's/\b\w/\U&/g')
    DASHBOARD_TITLE="$detector_cap Secrets Analysis Dashboard"
fi

# Generate HTML Dashboard
cat > "$OUTPUT_FILE" <<'HTML_START'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
HTML_START

echo "    <title>$DASHBOARD_TITLE</title>" >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" <<'HTML_START'
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
        
        .badge.detector { background: #e3f2fd; color: #1976d2; }
        
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
HTML_START

echo "            <h1>🔐 $DASHBOARD_TITLE</h1>" >> "$OUTPUT_FILE"

if [ "$DETECTOR_TYPE" = "all" ]; then
    echo "            <p>Comprehensive analysis of leaked secrets across multiple detector types</p>" >> "$OUTPUT_FILE"
else
    detector_cap=$(echo "$DETECTOR_TYPE" | sed 's/\b\w/\U&/g')
    echo "            <p>Comprehensive analysis of leaked $detector_cap secrets</p>" >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" <<'HTML_START'
        </div>
        
        <div style="text-align: center; margin: 20px 0;">
            <label for="masterDetectorFilter" style="font-size: 1.1em; margin-right: 10px; font-weight: bold;">🔍 View Detector:</label>
            <select id="masterDetectorFilter" style="padding: 8px 15px; font-size: 1em; border-radius: 6px; border: 2px solid #667eea; background: white; cursor: pointer;">
                <option value="">All Detectors</option>
            </select>
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
                <h2>🔍 Detector Types</h2>
                <canvas id="detectorChart"></canvas>
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
                <select id="detectorFilter">
                    <option value="">All Detectors</option>
                </select>
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
                        <th>Detector</th>
                        <th>Organization</th>
                        <th>Secret</th>
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
STATS_CARDS

# Continue with JavaScript
cat >> "$OUTPUT_FILE" <<HTML_START
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
        
        // Store chart instances globally
        let riskChartInstance, statusChartInstance, detectorChartInstance, capabilitiesChartInstance, orgsChartInstance;
        
        // Store original data for filtering
        const allSecretsData = [];
        
        // Risk Distribution Pie Chart
        riskChartInstance = new Chart(document.getElementById('riskChart'), {
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
        statusChartInstance = new Chart(document.getElementById('statusChart'), {
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
        
        // Detector Types Pie Chart
        detectorChartInstance = new Chart(document.getElementById('detectorChart'), {
            type: 'doughnut',
            data: {
                labels: [${DETECTOR_LABELS}],
                datasets: [{
                    data: [${DETECTOR_DATA}],
                    backgroundColor: [
                        '#3498db',
                        '#9b59b6',
                        '#e67e22',
                        '#1abc9c',
                        '#e74c3c',
                        '#f39c12',
                        '#2ecc71',
                        '#34495e'
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
        capabilitiesChartInstance = new Chart(document.getElementById('capabilitiesChart'), {
HTML_START

# Build capability labels and data dynamically
cap_labels=""
cap_data=""
first_cap=true

for cap in "${!capability_counts[@]}"; do
    # Format capability name (replace underscores with spaces, capitalize)
    cap_label=$(echo "$cap" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
    
    if [ "$first_cap" = true ]; then
        cap_labels="'$cap_label'"
        cap_data="${capability_counts[$cap]}"
        first_cap=false
    else
        cap_labels="$cap_labels, '$cap_label'"
        cap_data="$cap_data, ${capability_counts[$cap]}"
    fi
done

# If no capabilities, show placeholder
if [ "$first_cap" = true ]; then
    cap_labels="'No Capabilities'"
    cap_data="0"
fi

cat >> "$OUTPUT_FILE" <<CAP_CHART
            type: 'bar',
            data: {
                labels: [$cap_labels],
                datasets: [{
                    label: 'Keys with Capability',
                    data: [$cap_data],
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
CAP_CHART

# Generate JavaScript data for table
# We need to track if we've added the first entry across ALL files
first_secret_added=false

# Process each detector directory again for table data
for detector_dir in $DETECTOR_DIRS; do
    if [ ! -d "$detector_dir" ]; then
        continue
    fi
    
    detector_name=$(basename "$detector_dir")
    
    for analysis_file in "$detector_dir"/*_analysis.json; do
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
            # Handle both formats: .verification.status and .status
            status=$(echo "$secret" | jq -r '.verification.status // .status')
            # Handle both formats: .risk_assessment.risk_level and .risk_level
            risk_level=$(echo "$secret" | jq -r '.risk_assessment.risk_level // .risk_level')
            # Handle both formats: .risk_assessment.score and .risk_score
            risk_score=$(echo "$secret" | jq -r '.risk_assessment.score // .risk_score')
            # Extract secret value from various possible field names
            # raw_secret (new analyzers), secret_prefix (truncated), secret_hash (hashed),
            # access_key_id (AWS), token_prefix (Artifactory), api_key, token, key, etc.
            raw_secret=$(echo "$secret" | jq -r '.raw_secret // .secret_prefix // .secret_hash // .access_key_id // .token_prefix // .api_key // .token // .key // "N/A"')
            # Sanitize for JSON (escape quotes and backslashes)
            raw_secret=$(echo "$raw_secret" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
            
            # Build capabilities string dynamically
            capabilities=""
            cap_keys=$(echo "$secret" | jq -r '.capabilities | keys[]' 2>/dev/null)
            for cap_key in $cap_keys; do
                # Skip non-boolean capabilities
                if [[ "$cap_key" =~ (supported_chains|acl_permissions) ]]; then
                    continue
                fi
                
                cap_value=$(echo "$secret" | jq -r ".capabilities.${cap_key}" 2>/dev/null)
                if [ "$cap_value" = "true" ]; then
                    cap_display=$(echo "$cap_key" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
                    if [ -z "$capabilities" ]; then
                        capabilities="$cap_display"
                    else
                        capabilities="$capabilities, $cap_display"
                    fi
                fi
            done
            
            # Get chain count if exists
            chains=$(echo "$secret" | jq -r '.capabilities.supported_chains | length' 2>/dev/null || echo "0")
            if [ "$chains" = "null" ]; then
                chains="0"
            fi
            
            # Add comma before this entry if it's not the very first one
            if [ -f "$OUTPUT_FILE.tmp" ]; then
                echo "," >> "$OUTPUT_FILE"
            else
                touch "$OUTPUT_FILE.tmp"
            fi
            
            # Write JSON object for this secret
            echo "            {" >> "$OUTPUT_FILE"
            echo "                \"detector\": \"$detector_name\"," >> "$OUTPUT_FILE"
            echo "                \"organization\": \"$org_name\"," >> "$OUTPUT_FILE"
            echo "                \"secret\": \"$raw_secret\"," >> "$OUTPUT_FILE"
            echo "                \"commit\": \"$commit\"," >> "$OUTPUT_FILE"
            echo "                \"status\": \"$status\"," >> "$OUTPUT_FILE"
            echo "                \"riskLevel\": \"$risk_level\"," >> "$OUTPUT_FILE"
            echo "                \"riskScore\": $risk_score," >> "$OUTPUT_FILE"
            echo "                \"capabilities\": \"$capabilities\"," >> "$OUTPUT_FILE"
            echo "                \"chains\": $chains" >> "$OUTPUT_FILE"
            echo "            }" >> "$OUTPUT_FILE"
        done
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
        orgsChartInstance = new Chart(document.getElementById('orgsChart'), {
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
                
                // Format capabilities - already a string from bash
                const capabilitiesHtml = secret.capabilities 
                    ? secret.capabilities.split(', ').map(c => `<span class="capability-badge">${c}</span>`).join('')
                    : '<span class="capability-badge">None</span>';
                
                row.innerHTML = `
                    <td><span class="badge detector">${secret.detector}</span></td>
                    <td><strong>${secret.organization}</strong></td>
                    <td><code style="font-size: 0.85em; word-break: break-all;">${secret.secret}</code></td>
                    <td><code>${secret.commit}</code></td>
                    <td><span class="badge ${secret.status.toLowerCase().replace('_', '-')}">${secret.status}</span></td>
                    <td><span class="badge ${secret.riskLevel.toLowerCase()}">${secret.riskLevel}</span></td>
                    <td><span class="score">${secret.riskScore}</span></td>
                    <td>
                        <div class="capability-badges">
                            ${capabilitiesHtml}
                        </div>
                    </td>
                    <td>${secret.chains} chain${secret.chains !== 1 ? 's' : ''}</td>
                `;
                
                tbody.appendChild(row);
            });
        }
        
        // Initial table population
        populateTable(secretsData);
        
        // Store all secrets data for master filtering
        secretsData.forEach(s => allSecretsData.push(s));
        
        // Populate detector filter dropdowns dynamically
        const detectorSet = new Set(secretsData.map(s => s.detector));
        const detectorFilter = document.getElementById('detectorFilter');
        const masterDetectorFilter = document.getElementById('masterDetectorFilter');
        
        detectorSet.forEach(detector => {
            // Table filter dropdown
            const option = document.createElement('option');
            option.value = detector;
            option.textContent = detector.charAt(0).toUpperCase() + detector.slice(1);
            detectorFilter.appendChild(option);
            
            // Master filter dropdown
            const masterOption = document.createElement('option');
            masterOption.value = detector;
            masterOption.textContent = detector.charAt(0).toUpperCase() + detector.slice(1);
            masterDetectorFilter.appendChild(masterOption);
        });
        
        // Function to update all charts based on filtered data
        function updateCharts(filteredData) {
            // Calculate statistics from filtered data
            const criticalCount = filteredData.filter(s => s.riskLevel === 'CRITICAL').length;
            const highCount = filteredData.filter(s => s.riskLevel === 'HIGH').length;
            const mediumCount = filteredData.filter(s => s.riskLevel === 'MEDIUM').length;
            const lowCount = filteredData.filter(s => s.riskLevel === 'LOW').length;
            
            const activeCount = filteredData.filter(s => s.status === 'ACTIVE').length;
            const revokedCount = filteredData.filter(s => s.status === 'REVOKED').length;
            const rateLimitedCount = filteredData.filter(s => s.status === 'RATE_LIMITED').length;
            
            // Update Risk Chart
            riskChartInstance.data.datasets[0].data = [criticalCount, highCount, mediumCount, lowCount];
            riskChartInstance.update();
            
            // Update Status Chart
            statusChartInstance.data.datasets[0].data = [activeCount, revokedCount, rateLimitedCount];
            statusChartInstance.update();
            
            // Update Detector Chart
            const detectorCounts = {};
            filteredData.forEach(s => {
                detectorCounts[s.detector] = (detectorCounts[s.detector] || 0) + 1;
            });
            const detectorLabels = Object.keys(detectorCounts).map(d => d.charAt(0).toUpperCase() + d.slice(1));
            const detectorData = Object.values(detectorCounts);
            
            detectorChartInstance.data.labels = detectorLabels.length > 0 ? detectorLabels : ['No Data'];
            detectorChartInstance.data.datasets[0].data = detectorData.length > 0 ? detectorData : [0];
            detectorChartInstance.update();
            
            // Update Capabilities Chart
            const capabilityCounts = {};
            filteredData.forEach(s => {
                if (s.capabilities) {
                    s.capabilities.split(', ').forEach(cap => {
                        if (cap && cap !== 'None') {
                            capabilityCounts[cap] = (capabilityCounts[cap] || 0) + 1;
                        }
                    });
                }
            });
            const capLabels = Object.keys(capabilityCounts);
            const capData = Object.values(capabilityCounts);
            
            capabilitiesChartInstance.data.labels = capLabels.length > 0 ? capLabels : ['No Capabilities'];
            capabilitiesChartInstance.data.datasets[0].data = capData.length > 0 ? capData : [0];
            capabilitiesChartInstance.update();
            
            // Update Organizations Chart
            const orgCounts = {};
            filteredData.forEach(s => {
                orgCounts[s.organization] = (orgCounts[s.organization] || 0) + 1;
            });
            const topOrgs = Object.entries(orgCounts)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 10);
            
            orgsChartInstance.data.labels = topOrgs.map(o => o[0]);
            orgsChartInstance.data.datasets[0].data = topOrgs.map(o => o[1]);
            orgsChartInstance.update();
            
            // Update stats cards
            document.querySelector('.stat-card:nth-child(2) .value').textContent = filteredData.length;
            document.querySelector('.stat-card:nth-child(3) .value').textContent = activeCount;
            document.querySelector('.stat-card:nth-child(4) .value').textContent = criticalCount;
        }
        
        // Master detector filter handler
        masterDetectorFilter.addEventListener('change', function() {
            const selectedDetector = this.value;
            
            // Filter the data
            const filteredData = selectedDetector 
                ? allSecretsData.filter(s => s.detector === selectedDetector)
                : allSecretsData;
            
            // Update all charts
            updateCharts(filteredData);
            
            // Update table with filtered data
            populateTable(filteredData);
            
            // Reset table filters when master filter changes
            document.getElementById('searchInput').value = '';
            document.getElementById('detectorFilter').value = '';
            document.getElementById('riskFilter').value = '';
            document.getElementById('statusFilter').value = '';
        });
        
        // Filtering logic for table filters (works on currently displayed data)
        function applyFilters() {
            const searchTerm = document.getElementById('searchInput').value.toLowerCase();
            const detectorFilterValue = document.getElementById('detectorFilter').value;
            const riskFilter = document.getElementById('riskFilter').value;
            const statusFilter = document.getElementById('statusFilter').value;
            const masterDetectorValue = document.getElementById('masterDetectorFilter').value;
            
            // Start with data based on master filter
            let baseData = masterDetectorValue 
                ? allSecretsData.filter(s => s.detector === masterDetectorValue)
                : allSecretsData;
            
            // Apply table filters
            const filtered = baseData.filter(secret => {
                const matchesSearch = !searchTerm || 
                    secret.organization.toLowerCase().includes(searchTerm) ||
                    secret.commit.toLowerCase().includes(searchTerm);
                
                const matchesDetector = !detectorFilterValue || secret.detector === detectorFilterValue;
                const matchesRisk = !riskFilter || secret.riskLevel === riskFilter;
                const matchesStatus = !statusFilter || secret.status === statusFilter;
                
                return matchesSearch && matchesDetector && matchesRisk && matchesStatus;
            });
            
            populateTable(filtered);
        }
        
        document.getElementById('searchInput').addEventListener('input', applyFilters);
        document.getElementById('detectorFilter').addEventListener('change', applyFilters);
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
