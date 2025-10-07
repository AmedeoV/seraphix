#!/bin/bash
# Algolia Admin Key Analyzer
# 
# Analyzes all Algolia Admin API keys found in leaked_secrets_results
# and saves analysis to analyzed_results/algolia/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$ANALYZER_DIR")"
RESULTS_DIR="$PROJECT_ROOT/force-push-scanner/leaked_secrets_results"
OUTPUT_DIR="$ANALYZER_DIR/analyzed_results/algolia"

echo "🔍 Algolia Admin Key Analyzer"
echo "=============================="
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
echo "📂 Scanning for Algolia secrets in: $RESULTS_DIR"
echo ""

# Process each secrets file
while IFS= read -r secrets_file; do
    # Skip empty files
    if [ ! -s "$secrets_file" ]; then
        continue
    fi
    
    # Extract org name from filename
    org_name=$(basename "$secrets_file" | sed 's/verified_secrets_//' | sed 's/.json//')
    
    # Check if file has valid JSON and contains Algolia secrets
    secret_count=$(jq '[.[] | select(.DetectorName == "AlgoliaAdminKey")] | length' "$secrets_file" 2>/dev/null || echo "0")
    
    if [ "$secret_count" = "0" ] || [ -z "$secret_count" ]; then
        continue
    fi
    
    echo "📊 Analyzing $secret_count Algolia Admin Key(s) from: $org_name"
    
    # Output file
    output_file="$OUTPUT_DIR/${org_name}_analysis.json"
    
    # Initialize output file
    cat > "$output_file" <<HEADER
{
  "organization": "$org_name",
  "detector_type": "AlgoliaAdminKey",
  "analysis_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_secrets": $secret_count,
  "secrets": [
HEADER
    
    # Process secrets - extract to array to avoid subshell variable issues
    secrets_data=$(jq -c '.[] | select(.DetectorName == "AlgoliaAdminKey")' "$secrets_file" 2>/dev/null)
    secret_index=0
    
    while IFS= read -r secret; do
        if [ -z "$secret" ]; then
            continue
        fi
        
        # Extract fields - use RawV2 if available (contains appId:apiKey), fallback to Raw
        raw_v2=$(echo "$secret" | jq -r '.RawV2 // ""')
        raw_secret=$(echo "$secret" | jq -r '.Raw // ""')
        commit=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.commit // "unknown"')
        file_path=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.file // "unknown"')
        timestamp=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.timestamp // "unknown"')
        repo_url=$(echo "$secret" | jq -r '.repository_url // "unknown"')
        
        # Prefer RawV2 (has appId:apiKey format), fallback to Raw
        if [ -n "$raw_v2" ] && [ "$raw_v2" != "null" ] && [[ "$raw_v2" == *":"* ]]; then
            secret_to_parse="$raw_v2"
        elif [ -n "$raw_secret" ] && [ "$raw_secret" != "null" ]; then
            secret_to_parse="$raw_secret"
        else
            continue
        fi
        
        # Add comma if not first secret
        if [ $secret_index -gt 0 ]; then
            echo "," >> "$output_file"
        fi
        secret_index=$((secret_index + 1))
        
        # Comprehensive capability testing
        echo "  🔍 Testing key $secret_index from commit ${commit:0:7}..."
        
        # Extract App ID and API Key from the secret (format: appId:adminKey)
        if [[ "$secret_to_parse" == *":"* ]]; then
            app_id=$(echo "$secret_to_parse" | cut -d':' -f1)
            admin_key=$(echo "$secret_to_parse" | cut -d':' -f2)
        else
            # If no colon, assume it's just the API key and app_id is unknown
            app_id="unknown"
            admin_key="$secret_to_parse"
        fi
        
        # Skip if we don't have both parts
        if [ "$app_id" = "unknown" ] || [ -z "$admin_key" ]; then
            echo "       ⚠️  Skipping - invalid format (missing app_id or key)"
            secret_index=$((secret_index - 1))
            continue
        fi
        
        status="UNKNOWN"
        
        # Initialize capability tracking
        can_list_indices=false
        can_add_records=false
        can_delete_index=false
        can_get_settings=false
        can_get_logs=false
        index_count=0
        acl_permissions=()
        key_description=""
        
        # Test 1: Get API Key Info (TruffleHog's method - primary verification)
        echo "     → Verifying API key (TruffleHog method)..."
        key_info_response=$(curl -s -w "\n%{http_code}" \
            -X GET "https://${app_id}-dsn.algolia.net/1/keys/${admin_key}" \
            -H "X-Algolia-API-Key: ${admin_key}" \
            -H "X-Algolia-Application-Id: ${app_id}" \
            --max-time 10 2>/dev/null || echo -e "\n000")
        
        http_code=$(echo "$key_info_response" | tail -n1)
        key_info_body=$(echo "$key_info_response" | head -n-1)
        
        if [ "$http_code" = "200" ]; then
            status="ACTIVE"
            echo "       ✓ API Key: ACTIVE"
            active_secrets=$((active_secrets + 1))
            
            # Extract ACL permissions
            acl=$(echo "$key_info_body" | jq -r '.acl[]?' 2>/dev/null)
            if [ -n "$acl" ]; then
                acl_permissions=($(echo "$key_info_body" | jq -r '.acl[]' 2>/dev/null))
                echo "       ✓ ACL Permissions: ${acl_permissions[*]}"
                
                # Check for dangerous permissions
                for perm in "${acl_permissions[@]}"; do
                    case "$perm" in
                        "addObject") can_add_records=true ;;
                        "deleteObject") can_add_records=true ;;
                        "deleteIndex") can_delete_index=true ;;
                        "settings"|"editSettings") can_get_settings=true ;;
                        "logs") can_get_logs=true ;;
                        "listIndexes") can_list_indices=true ;;
                    esac
                done
            fi
            
            # Extract key description and other metadata
            key_description=$(echo "$key_info_body" | jq -r '.description // "No description"' 2>/dev/null)
            if [ -n "$key_description" ] && [ "$key_description" != "null" ] && [ "$key_description" != "No description" ]; then
                echo "       ℹ️  Description: $key_description"
            fi
            
            # Check indices this key can access
            key_indices=$(echo "$key_info_body" | jq -r '.indexes[]? // "*"' 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
            if [ -n "$key_indices" ]; then
                echo "       ℹ️  Accessible indices: $key_indices"
            fi
            
        elif [ "$http_code" = "403" ] || [ "$http_code" = "401" ]; then
            status="REVOKED"
            echo "       ✗ API Key: REVOKED (HTTP $http_code)"
        elif [ "$http_code" = "429" ]; then
            status="RATE_LIMITED"
            echo "       ⚠ API Key: RATE LIMITED"
        else
            echo "       ? API Key: UNKNOWN (HTTP $http_code)"
        fi
        
        # Test 2: List Indices (if key has permission)
        if [ "$status" = "ACTIVE" ]; then
            echo "     → Testing index access..."
            list_response=$(curl -s -w "\n%{http_code}" \
                -X GET "https://${app_id}-dsn.algolia.net/1/indexes" \
                -H "X-Algolia-API-Key: ${admin_key}" \
                -H "X-Algolia-Application-Id: ${app_id}" \
                --max-time 10 2>/dev/null || echo -e "\n000")
            
            list_code=$(echo "$list_response" | tail -n1)
            list_body=$(echo "$list_response" | head -n-1)
            
            if [ "$list_code" = "200" ]; then
                can_list_indices=true
                # Count indices
                index_count=$(echo "$list_body" | jq '.items | length' 2>/dev/null || echo "0")
                if [ "$index_count" -gt 0 ]; then
                    echo "       ✓ Can list indices: $index_count found"
                    # Show first few index names
                    index_names=$(echo "$list_body" | jq -r '.items[0:3] | .[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
                    if [ -n "$index_names" ]; then
                        echo "       ✓ Sample indices: $index_names"
                    fi
                else
                    echo "       ✓ Can list indices (0 found)"
                fi
            elif [ "$list_code" = "403" ]; then
                echo "       ✗ Cannot list indices (insufficient permissions)"
            fi
        fi
        
        # Test 3: Check if we can access logs (admin capability)
        if [ "$status" = "ACTIVE" ]; then
            echo "     → Testing admin-level access..."
            logs_response=$(curl -s -w "\n%{http_code}" \
                -X GET "https://${app_id}-dsn.algolia.net/1/logs?length=1" \
                -H "X-Algolia-API-Key: ${admin_key}" \
                -H "X-Algolia-Application-Id: ${app_id}" \
                --max-time 10 2>/dev/null || echo -e "\n000")
            
            logs_code=$(echo "$logs_response" | tail -n1)
            if [ "$logs_code" = "200" ]; then
                can_get_logs=true
                echo "       ⚠️  Can access logs (ADMIN access confirmed!)"
            elif [ "$logs_code" = "403" ]; then
                echo "       ✓ Cannot access logs (limited key)"
            fi
        fi
        
        # Calculate comprehensive risk score based on ACL permissions
        risk_score=0
        risk_level="LOW"
        impact_description=""
        key_type="Unknown"
        
        if [ "$status" = "ACTIVE" ]; then
            # Base score for active key
            risk_score=40
            
            # Analyze ACL permissions to determine key type and risk
            has_read_only=false
            has_write=false
            has_admin=false
            
            # Check permission patterns
            for perm in "${acl_permissions[@]}"; do
                case "$perm" in
                    "search"|"browse") has_read_only=true ;;
                    "addObject"|"deleteObject"|"editSettings"|"settings"|"deleteIndex") has_write=true ;;
                    "logs"|"analytics"|"recommendation"|"seeUnretrievableAttributes") has_admin=true ;;
                esac
            done
            
            # Determine key type and risk
            if [ "$has_admin" = true ] || [ "$can_get_logs" = true ]; then
                key_type="Admin Key"
                risk_score=85
                risk_level="CRITICAL"
                impact_description="FULL ADMIN ACCESS - Can view logs, analytics, and perform all operations"
            elif [ "$has_write" = true ]; then
                key_type="Write Key"
                risk_score=70
                risk_level="HIGH"
                impact_description="Write access - Can modify/delete records and indices"
            elif [ "$has_read_only" = true ]; then
                key_type="Search-Only Key"
                risk_score=50
                risk_level="MEDIUM"
                impact_description="Read-only access - Can search and browse records (limited risk)"
            else
                key_type="Limited Key"
                risk_score=45
                risk_level="MEDIUM"
                impact_description="Active key with limited permissions"
            fi
            
            # Add risk for specific dangerous permissions
            if [ "$can_add_records" = true ]; then
                risk_score=$((risk_score + 5))
                impact_description="${impact_description}. Can add/modify records"
            fi
            
            if [ "$can_delete_index" = true ]; then
                risk_score=$((risk_score + 10))
                impact_description="${impact_description}. Can DELETE INDICES"
            fi
            
            if [ "$can_list_indices" = true ]; then
                risk_score=$((risk_score + 5))
                impact_description="${impact_description}. Can list all indices"
            fi
            
            if [ "$index_count" -gt 0 ]; then
                risk_score=$((risk_score + 3))
            fi
            
            # Cap risk score at 100
            if [ $risk_score -gt 100 ]; then
                risk_score=100
            fi
            
            echo "     ⚠️  Key Type: $key_type"
            echo "     ⚠️  Risk Level: $risk_level (Score: $risk_score)"
        elif [ "$status" = "REVOKED" ]; then
            key_type="Revoked"
            risk_score=5
            risk_level="LOW"
            impact_description="Key has been revoked and is no longer functional"
            echo "     ✅ REVOKED - No risk"
        elif [ "$status" = "RATE_LIMITED" ]; then
            key_type="Rate Limited"
            risk_score=50
            risk_level="MEDIUM"
            impact_description="Key is rate-limited but may still be partially functional"
            echo "     ⚠️  RATE LIMITED - Moderate risk"
        else
            risk_score=30
            risk_level="LOW"
            impact_description="Unable to verify key status"
        fi
        
        # Generate hash
        secret_hash=$(echo -n "$admin_key" | sha256sum | cut -c1-16)
        
        # Build ACL JSON array
        acl_json="["
        for perm in "${acl_permissions[@]}"; do
            acl_json="${acl_json}\"$perm\","
        done
        acl_json="${acl_json%,}]"
        [ "$acl_json" = "[" ] && acl_json="[]"
        
        # Build potential abuse array
        abuse_items=""
        [ "$can_list_indices" = true ] && abuse_items="${abuse_items}\"Enumerate all search indices and data structure\","
        [ "$can_add_records" = true ] && abuse_items="${abuse_items}\"Add or modify search records (data poisoning)\","
        [ "$can_delete_index" = true ] && abuse_items="${abuse_items}\"DELETE entire indices (data destruction)\","
        [ "$can_get_settings" = true ] && abuse_items="${abuse_items}\"Access index settings and configuration\","
        [ "$can_get_logs" = true ] && abuse_items="${abuse_items}\"Access logs and query analytics\","
        abuse_items="${abuse_items}\"Scrape all searchable data\","
        abuse_items="${abuse_items}\"Flood account with API requests\","
        abuse_items="${abuse_items}\"Generate excessive billing costs\""
        
        # Append secret analysis with enhanced data
        cat >> "$output_file" <<SECRETDATA
    {
      "secret_hash": "$secret_hash",
      "app_id": "$app_id",
      "key_type": "$key_type",
      "key_description": "$key_description",
      "commit": "$commit",
      "file": "$file_path",
      "timestamp": "$timestamp",
      "repository": "$repo_url",
      "verification": {
        "status": "$status",
        "http_code": "$http_code",
        "verification_method": "TruffleHog-compatible (/1/keys endpoint)",
        "last_verified": "$(date -u +"%Y-%m-%d %H:%M:%S")"
      },
      "capabilities": {
        "list_indices": $can_list_indices,
        "add_records": $can_add_records,
        "delete_index": $can_delete_index,
        "get_settings": $can_get_settings,
        "get_logs": $can_get_logs,
        "acl_permissions": $acl_json,
        "index_count": $index_count
      },
      "risk_assessment": {
        "risk_level": "$risk_level",
        "score": $risk_score,
        "impact_description": "$impact_description"
      },
      "potential_abuse": [$abuse_items],
      "remediation": {
        "immediate": [
          "Revoke key at https://dashboard.algolia.com/account/api-keys",
          "Review logs for unauthorized access at https://dashboard.algolia.com/${app_id}/logs",
          "Check for data modifications or deletions",
          "Review billing for unusual API usage spikes"
        ],
        "preventive": [
          "Create new key with minimal required ACL permissions",
          "Set API key restrictions (IP whitelist, rate limits, index restrictions)",
          "Use secured API keys for frontend applications",
          "Implement key rotation policy (recommended: quarterly)",
          "Never hardcode admin keys in client-side code",
          "Use environment variables for API keys",
          "Monitor API usage via webhooks and alerts"
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
echo "=============================="
echo "📊 Analysis Complete"
echo "=============================="
echo "Organizations analyzed: $total_orgs"
echo "Total secrets: $total_secrets"
echo "Active secrets: $active_secrets"
echo ""
echo "📁 Results in: $OUTPUT_DIR"
echo ""

if [ $active_secrets -gt 0 ]; then
    echo "⚠️  WARNING: $active_secrets ACTIVE Algolia Admin keys found!"
    echo ""
    echo "💡 Algolia Admin Keys can:"
    echo "   - List and access all search indices"
    echo "   - Add, modify, or delete records"
    echo "   - Delete entire indices (data destruction)"
    echo "   - Access logs and analytics"
    echo "   - Generate excessive billing costs"
    echo ""
    echo "🔥 This is a CRITICAL security issue!"
fi
