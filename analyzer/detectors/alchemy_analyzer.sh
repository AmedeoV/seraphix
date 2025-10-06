#!/bin/bash
# Alchemy Secret Analyzer (Simplified Version)
# 
# Analyzes all Alchemy API keys found in leaked_secrets_results
# and saves analysis to analyzed_results/alchemy/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$ANALYZER_DIR")"
RESULTS_DIR="$PROJECT_ROOT/force-push-scanner/leaked_secrets_results"
OUTPUT_DIR="$ANALYZER_DIR/analyzed_results/alchemy"

echo "🔍 Alchemy Secret Analyzer"
echo "=========================="
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Error: jq is required but not installed"
    echo "   Install with: sudo apt-get install jq (Linux) or brew install jq (Mac)"
    exit 1
fi

# Counter
total_orgs=0
total_secrets=0
active_secrets=0

# Find all verified_secrets files
echo "📂 Scanning for Alchemy secrets in: $RESULTS_DIR"
echo ""

# Process each secrets file
while IFS= read -r secrets_file; do
    # Skip empty files
    if [ ! -s "$secrets_file" ]; then
        continue
    fi
    
    # Extract org name from filename
    org_name=$(basename "$secrets_file" | sed 's/verified_secrets_//' | sed 's/.json//')
    
    # Check if file has valid JSON and contains Alchemy secrets
    secret_count=$(jq '[.[] | select(.DetectorName == "Alchemy")] | length' "$secrets_file" 2>/dev/null || echo "0")
    
    if [ "$secret_count" = "0" ] || [ -z "$secret_count" ]; then
        continue
    fi
    
    echo "📊 Analyzing $secret_count Alchemy secret(s) from: $org_name"
    
    # Output file
    output_file="$OUTPUT_DIR/${org_name}_analysis.json"
    
    # Initialize output file
    cat > "$output_file" <<HEADER
{
  "organization": "$org_name",
  "detector_type": "Alchemy",
  "analysis_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_secrets": $secret_count,
  "secrets": [
HEADER
    
    # Process secrets - extract to array to avoid subshell variable issues
    secrets_data=$(jq -c '.[] | select(.DetectorName == "Alchemy")' "$secrets_file" 2>/dev/null)
    secret_index=0
    
    while IFS= read -r secret; do
        if [ -z "$secret" ]; then
            continue
        fi
        
        # Extract fields
        raw_secret=$(echo "$secret" | jq -r '.Raw // ""')
        commit=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.commit // "unknown"')
        file_path=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.file // "unknown"')
        timestamp=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.timestamp // "unknown"')
        repo_url=$(echo "$secret" | jq -r '.repository_url // "unknown"')
        
        if [ -z "$raw_secret" ] || [ "$raw_secret" = "null" ]; then
            continue
        fi
        
        # Add comma if not first secret
        if [ $secret_index -gt 0 ]; then
            echo "," >> "$output_file"
        fi
        secret_index=$((secret_index + 1))
        
        # Comprehensive capability testing
        echo "  🔍 Testing key $secret_index from commit ${commit:0:7}..."
        
        status="UNKNOWN"
        base_url="https://eth-mainnet.g.alchemy.com/v2/${raw_secret}"
        
        # Initialize capability tracking
        can_node_api=false
        can_nft_api=false
        can_token_api=false
        supported_chains=()
        
        # Test 1: Basic Node API (eth_blockNumber)
        echo "     → Testing Node API access..."
        node_response=$(curl -s -w "\n%{http_code}" -X POST "$base_url" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            --max-time 10 2>/dev/null || echo -e "\n000")
        
        http_code=$(echo "$node_response" | tail -n1)
        node_body=$(echo "$node_response" | head -n-1)
        
        if [ "$http_code" = "200" ]; then
            can_node_api=true
            status="ACTIVE"
            echo "       ✓ Node API: ACCESSIBLE"
            active_secrets=$((active_secrets + 1))
            
            # Extract block number
            block_number=$(echo "$node_body" | jq -r '.result // empty' 2>/dev/null)
            if [ -n "$block_number" ]; then
                echo "       ✓ Current block: $block_number"
            fi
        elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            status="REVOKED"
            echo "       ✗ Node API: REVOKED (HTTP $http_code)"
        elif [ "$http_code" = "429" ]; then
            status="RATE_LIMITED"
            echo "       ⚠ Node API: RATE LIMITED"
        else
            echo "       ? Node API: UNKNOWN (HTTP $http_code)"
        fi
        
        # Test 2: NFT API (if Node API works)
        if [ "$can_node_api" = true ]; then
            echo "     → Testing NFT API access..."
            nft_url="https://eth-mainnet.g.alchemy.com/nft/v3/${raw_secret}/getNFTsForOwner"
            nft_response=$(curl -s -w "\n%{http_code}" -X GET \
                "${nft_url}?owner=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045&pageSize=1" \
                --max-time 10 2>/dev/null || echo -e "\n000")
            
            nft_code=$(echo "$nft_response" | tail -n1)
            if [ "$nft_code" = "200" ]; then
                can_nft_api=true
                echo "       ✓ NFT API: ACCESSIBLE"
            elif [ "$nft_code" = "403" ] || [ "$nft_code" = "401" ]; then
                echo "       ✗ NFT API: RESTRICTED"
            else
                echo "       ? NFT API: UNKNOWN (HTTP $nft_code)"
            fi
        fi
        
        # Test 3: Token API (getTokenBalances)
        if [ "$can_node_api" = true ]; then
            echo "     → Testing Token API access..."
            token_response=$(curl -s -w "\n%{http_code}" -X POST "$base_url" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"alchemy_getTokenBalances","params":["0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",[]],"id":1}' \
                --max-time 10 2>/dev/null || echo -e "\n000")
            
            token_code=$(echo "$token_response" | tail -n1)
            if [ "$token_code" = "200" ]; then
                can_token_api=true
                echo "       ✓ Token API: ACCESSIBLE"
            else
                echo "       ? Token API: Limited"
            fi
        fi
        
        # Test 4: Multi-chain support
        if [ "$can_node_api" = true ]; then
            echo "     → Testing multi-chain access..."
            for chain in "polygon-mainnet" "arb-mainnet" "opt-mainnet"; do
                chain_url="https://${chain}.g.alchemy.com/v2/${raw_secret}"
                chain_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$chain_url" \
                    -H "Content-Type: application/json" \
                    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                    --max-time 5 2>/dev/null || echo "000")
                
                if [ "$chain_code" = "200" ]; then
                    supported_chains+=("$chain")
                fi
            done
            
            if [ ${#supported_chains[@]} -gt 0 ]; then
                echo "       ✓ Supported chains: ${supported_chains[*]}"
            fi
        fi
        
        # Calculate comprehensive risk score
        risk_score=0
        risk_level="LOW"
        impact_description=""
        
        if [ "$status" = "ACTIVE" ]; then
            risk_score=70
            impact_description="API key is active and functional"
            
            # Increase risk based on capabilities
            if [ "$can_node_api" = true ]; then
                risk_score=$((risk_score + 10))
                impact_description="${impact_description}. Can read blockchain data"
            fi
            
            if [ "$can_nft_api" = true ]; then
                risk_score=$((risk_score + 5))
                impact_description="${impact_description}, query NFTs"
            fi
            
            if [ "$can_token_api" = true ]; then
                risk_score=$((risk_score + 5))
                impact_description="${impact_description}, access token balances"
            fi
            
            if [ ${#supported_chains[@]} -gt 0 ]; then
                risk_score=$((risk_score + 5))
                impact_description="${impact_description}. Multi-chain access enabled"
            fi
            
            # Determine risk level
            if [ $risk_score -ge 90 ]; then
                risk_level="CRITICAL"
            elif [ $risk_score -ge 70 ]; then
                risk_level="HIGH"
            elif [ $risk_score -ge 50 ]; then
                risk_level="MEDIUM"
            fi
            
            echo "     ⚠️  Risk Level: $risk_level (Score: $risk_score)"
        elif [ "$status" = "REVOKED" ]; then
            risk_score=10
            risk_level="LOW"
            impact_description="Key has been revoked and is no longer functional"
            echo "     ✅ REVOKED - No risk"
        elif [ "$status" = "RATE_LIMITED" ]; then
            risk_score=60
            risk_level="MEDIUM"
            impact_description="Key is rate-limited but may still be partially functional"
            echo "     ⚠️  RATE LIMITED - Moderate risk"
        else
            risk_score=30
            risk_level="LOW"
            impact_description="Unable to verify key status"
        fi
        
        # Generate hash
        secret_hash=$(echo -n "$raw_secret" | sha256sum | cut -c1-16)
        
        # Build capabilities JSON array
        capabilities_json="["
        [ "$can_node_api" = true ] && capabilities_json="${capabilities_json}\"node_api\","
        [ "$can_nft_api" = true ] && capabilities_json="${capabilities_json}\"nft_api\","
        [ "$can_token_api" = true ] && capabilities_json="${capabilities_json}\"token_api\","
        capabilities_json="${capabilities_json%,}]"
        
        # Build chains JSON array
        chains_json="["
        for chain in "${supported_chains[@]}"; do
            chains_json="${chains_json}\"$chain\","
        done
        chains_json="${chains_json%,}]"
        [ "$chains_json" = "[" ] && chains_json="[]"
        
        # Build potential abuse array
        abuse_items=""
        [ "$can_node_api" = true ] && abuse_items="${abuse_items}\"Read blockchain data and transaction history\","
        [ "$can_nft_api" = true ] && abuse_items="${abuse_items}\"Query NFT ownership and metadata\","
        [ "$can_token_api" = true ] && abuse_items="${abuse_items}\"Access wallet token balances\","
        [ ${#supported_chains[@]} -gt 0 ] && abuse_items="${abuse_items}\"Access multiple blockchain networks\","
        abuse_items="${abuse_items}\"Drain compute credits and generate costs\","
        abuse_items="${abuse_items}\"Intelligence gathering on wallet activities\","
        abuse_items="${abuse_items}\"Rate limit exhaustion (DoS)\""
        
        # Append secret analysis with enhanced data
        cat >> "$output_file" <<SECRETDATA
    {
      "secret_hash": "$secret_hash",
      "commit": "$commit",
      "file": "$file_path",
      "timestamp": "$timestamp",
      "repository": "$repo_url",
      "verification": {
        "status": "$status",
        "http_code": "$http_code",
        "last_verified": "$(date -u +"%Y-%m-%d %H:%M:%S")"
      },
      "capabilities": {
        "node_api": $can_node_api,
        "nft_api": $can_nft_api,
        "token_api": $can_token_api,
        "supported_chains": $chains_json,
        "multi_chain_enabled": $([ ${#supported_chains[@]} -gt 0 ] && echo "true" || echo "false")
      },
      "risk_assessment": {
        "risk_level": "$risk_level",
        "score": $risk_score,
        "impact_description": "$impact_description"
      },
      "potential_abuse": [$abuse_items],
      "remediation": {
        "immediate": [
          "Revoke key at https://dashboard.alchemy.com",
          "Review access logs for unauthorized usage",
          "Check billing for unusual activity spikes"
        ],
        "preventive": [
          "Create new key with IP restrictions",
          "Enable rate limiting per key",
          "Use separate keys per environment",
          "Implement key rotation policy",
          "Monitor usage via webhooks"
        ]
      }
    }
SECRETDATA
        
        echo ""
    done <<< "$secrets_data"
    
    # Close JSON
    cat >> "$output_file" <<FOOTER
  ]
}
FOOTER
    
    echo "  ✅ Saved to: ${org_name}_analysis.json"
    total_orgs=$((total_orgs + 1))
    total_secrets=$((total_secrets + secret_count))
    echo ""
done < <(find "$RESULTS_DIR" -name "verified_secrets_*.json" -type f 2>/dev/null)

# Summary
echo "=========================="
echo "📊 Analysis Complete"
echo "=========================="
echo "Organizations analyzed: $total_orgs"
echo "Total secrets: $total_secrets"
echo "Active secrets: $active_secrets"
echo ""
echo "📁 Results in: $OUTPUT_DIR"
echo ""

if [ $active_secrets -gt 0 ]; then
    echo "⚠️  WARNING: $active_secrets ACTIVE keys found!"
fi
