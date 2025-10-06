#!/bin/bash

################################################################################
# Alibaba Cloud API Key Analyzer
# 
# Analyzes Alibaba Cloud API keys found by TruffleHog and verifies them using
# the Alibaba Cloud ECS DescribeRegions API endpoint with HMAC-SHA1 signature.
#
# Author: Seraphix Security Scanner
# Date: 2025-10-06
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$ANALYZER_DIR/analyzed_results/Alibaba"

# Statistics
total_secrets=0
active_secrets=0
inactive_secrets=0
error_secrets=0

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Function to generate random string for nonce
generate_nonce() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c 16
}

# Function to URL encode
url_encode() {
    local string="$1"
    python3 -c "import sys, urllib.parse as ul; print(ul.quote_plus(sys.argv[1]))" "$string"
}

# Function to create HMAC-SHA1 signature
create_signature() {
    local string_to_sign="$1"
    local secret_key="$2"
    
    # Create signature using openssl
    echo -n "$string_to_sign" | openssl dgst -sha1 -hmac "$secret_key" -binary | base64
}

# Function to build string to sign for Alibaba API
build_string_to_sign() {
    local method="$1"
    local params="$2"
    
    # URL encode the parameters
    local encoded=$(python3 -c "
import sys
import urllib.parse as ul

params = sys.argv[1]
# Replace + with %20, keep ~, and ensure * is encoded as %2A
encoded = params.replace('+', '%20').replace('%7E', '~').replace('*', '%2A')
# Double encode for signature
result = ul.quote(encoded, safe='')
print(result)
" "$params")
    
    echo "${method}&%2F&${encoded}"
}

# Function to verify Alibaba Cloud API key
verify_alibaba_key() {
    local access_key_id="$1"
    local secret_key="$2"
    
    # Alibaba Cloud ECS API endpoint
    local endpoint="https://ecs.aliyuncs.com"
    
    # Generate timestamp in ISO 8601 format
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Generate random nonce
    local nonce=$(generate_nonce)
    
    # Build query parameters (must be in alphabetical order for signature)
    local -A params=(
        ["AccessKeyId"]="$access_key_id"
        ["Action"]="DescribeRegions"
        ["Format"]="JSON"
        ["SignatureMethod"]="HMAC-SHA1"
        ["SignatureNonce"]="$nonce"
        ["SignatureVersion"]="1.0"
        ["Timestamp"]="$timestamp"
        ["Version"]="2014-05-26"
    )
    
    # Build parameter string (sorted alphabetically)
    local param_string=""
    for key in $(echo "${!params[@]}" | tr ' ' '\n' | sort); do
        local value="${params[$key]}"
        local encoded_value=$(url_encode "$value")
        if [ -z "$param_string" ]; then
            param_string="${key}=${encoded_value}"
        else
            param_string="${param_string}&${key}=${encoded_value}"
        fi
    done
    
    # Build string to sign
    local string_to_sign=$(build_string_to_sign "GET" "$param_string")
    
    # Create signature (note: Alibaba requires appending "&" to secret key)
    local signature=$(create_signature "$string_to_sign" "${secret_key}&")
    
    # URL encode the signature
    local encoded_signature=$(url_encode "$signature")
    
    # Build final URL
    local url="${endpoint}?${param_string}&Signature=${encoded_signature}"
    
    # Make API request
    local response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "$url" 2>&1)
    local http_body=$(echo "$response" | sed -e 's/HTTP_STATUS\:.*//g')
    local http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
    
    # Handle curl errors
    if [ -z "$http_status" ] || [ "$http_status" = "000" ]; then
        echo "HTTP_ERROR"
        return 1
    fi
    
    # Parse response
    if [ "$http_status" = "200" ]; then
        echo "ACTIVE"
        return 0
    elif [ "$http_status" = "404" ] || [ "$http_status" = "400" ]; then
        # 404: Invalid AccessKeyId
        # 400: Invalid signature or other authentication errors
        echo "REVOKED"
        return 0
    else
        # Unexpected error
        echo "HTTP_ERROR"
        return 1
    fi
}

# Function to classify risk level based on Alibaba Cloud access
classify_alibaba_risk() {
    local status="$1"
    
    # All active Alibaba Cloud keys are CRITICAL as they provide full cloud infrastructure access
    if [ "$status" = "ACTIVE" ]; then
        echo "CRITICAL"
        echo "95"  # Risk score
    else
        echo "LOW"
        echo "5"   # Risk score for revoked keys
    fi
}

# Function to analyze secrets from a JSON file
analyze_secrets_file() {
    local json_file="$1"
    local org_name=$(basename "$json_file" | sed 's/verified_secrets_//;s/.json//')
    
    print_color "$BLUE" "\n📂 Analyzing organization: $org_name"
    
    # Count total Alibaba secrets in file
    local secret_count=$(jq '[.[] | select(.DetectorName == "Alibaba")] | length' "$json_file" 2>/dev/null || echo "0")
    
    if [ "$secret_count" = "0" ] || [ "$secret_count" = "null" ]; then
        print_color "$YELLOW" "  ⚠️  No Alibaba secrets found"
        return 0
    fi
    
    print_color "$GREEN" "  ✓ Found $secret_count Alibaba API key(s)"
    
    # Extract Alibaba secrets
    local alibaba_secrets=$(jq -c '.[] | select(.DetectorName == "Alibaba")' "$json_file" 2>/dev/null)
    
    # Create output structure
    local output_file="$RESULTS_DIR/${org_name}_analysis.json"
    local analyzed_secrets="[]"
    local org_active=0
    local org_revoked=0
    local org_errors=0
    
    # Process each secret
    while IFS= read -r secret; do
        if [ -z "$secret" ]; then
            continue
        fi
        
        total_secrets=$((total_secrets + 1))
        
        # Extract fields
        local raw=$(echo "$secret" | jq -r '.Raw // ""')
        local raw_v2=$(echo "$secret" | jq -r '.RawV2 // ""')
        local commit=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.commit // "unknown"')
        local file=$(echo "$secret" | jq -r '.SourceMetadata.Data.Git.file // "unknown"')
        local repo=$(echo "$secret" | jq -r '.repository_url // "unknown"')
        
        # Parse RawV2 to extract secret key and access key ID
        # Format: {secretKey}{accessKeyID}
        # Access Key ID starts with "LTAI" and is 17-21 characters
        local secret_key=""
        local access_key_id=""
        
        if [ -n "$raw_v2" ] && [ "$raw_v2" != "null" ]; then
            # Extract Access Key ID (LTAI followed by 17-21 alphanumeric characters)
            access_key_id=$(echo "$raw_v2" | grep -oE 'LTAI[a-zA-Z0-9]{17,21}' | head -1)
            
            if [ -n "$access_key_id" ]; then
                # Secret key is everything before the Access Key ID
                secret_key="${raw_v2%$access_key_id}"
            fi
        fi
        
        # Fallback to Raw field if parsing failed
        if [ -z "$secret_key" ]; then
            secret_key="$raw"
        fi
        
        print_color "$YELLOW" "\n  🔍 Verifying key: ${access_key_id:0:10}..."
        
        # Verify the key
        local status="UNKNOWN"
        local verification_error=""
        
        if [ -n "$access_key_id" ] && [ -n "$secret_key" ]; then
            local verify_result=$(verify_alibaba_key "$access_key_id" "$secret_key")
            
            if [ "$verify_result" = "ACTIVE" ]; then
                status="ACTIVE"
                active_secrets=$((active_secrets + 1))
                org_active=$((org_active + 1))
                print_color "$RED" "    ⚠️  Status: ACTIVE (HIGH RISK!)"
            elif [ "$verify_result" = "REVOKED" ]; then
                status="REVOKED"
                inactive_secrets=$((inactive_secrets + 1))
                org_revoked=$((org_revoked + 1))
                print_color "$GREEN" "    ✓ Status: REVOKED"
            else
                status="ERROR"
                verification_error="Failed to verify key"
                error_secrets=$((error_secrets + 1))
                org_errors=$((org_errors + 1))
                print_color "$YELLOW" "    ⚠️  Status: ERROR (verification failed)"
            fi
        else
            status="ERROR"
            verification_error="Invalid key format"
            error_secrets=$((error_secrets + 1))
            org_errors=$((org_errors + 1))
            print_color "$YELLOW" "    ⚠️  Status: ERROR (invalid format)"
        fi
        
        # Get risk classification
        local risk_data=$(classify_alibaba_risk "$status")
        local risk_level=$(echo "$risk_data" | head -1)
        local risk_score=$(echo "$risk_data" | tail -1)
        
        # Build analyzed secret object
        local analyzed_secret=$(jq -n \
            --arg commit "$commit" \
            --arg file "$file" \
            --arg repo "$repo" \
            --arg status "$status" \
            --arg risk_level "$risk_level" \
            --argjson risk_score "$risk_score" \
            --arg access_key_id "$access_key_id" \
            --arg verification_error "$verification_error" \
            '{
                commit: $commit,
                file: $file,
                repository: $repo,
                verification: {
                    status: $status,
                    verified_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                    method: "Alibaba Cloud ECS DescribeRegions API"
                },
                risk_assessment: {
                    risk_level: $risk_level,
                    score: $risk_score,
                    factors: [
                        "Full Alibaba Cloud infrastructure access",
                        "Can manage ECS instances, databases, storage",
                        "Can access sensitive cloud resources",
                        "Potential for significant financial impact"
                    ]
                },
                capabilities: {
                    cloud_platform: "Alibaba Cloud",
                    access_key_id: $access_key_id,
                    api_access: true,
                    full_infrastructure_control: ($status == "ACTIVE")
                }
            }' \
            $([ -n "$verification_error" ] && echo "--arg verification_error \"$verification_error\"" || echo ""))
        
        # Add to analyzed secrets array
        analyzed_secrets=$(echo "$analyzed_secrets" | jq --argjson secret "$analyzed_secret" '. + [$secret]')
        
    done <<< "$alibaba_secrets"
    
    # Create summary
    local summary=$(jq -n \
        --arg org "$org_name" \
        --argjson total "$secret_count" \
        --argjson active "$org_active" \
        --argjson revoked "$org_revoked" \
        --argjson errors "$org_errors" \
        '{
            organization: $org,
            total_secrets: $total,
            active_secrets: $active,
            revoked_secrets: $revoked,
            error_secrets: $errors,
            analysis_date: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            detector_type: "Alibaba"
        }')
    
    # Combine summary and secrets
    local final_output=$(jq -n \
        --argjson summary "$summary" \
        --argjson secrets "$analyzed_secrets" \
        '{
            summary: $summary,
            total_secrets: ($secrets | length),
            secrets: $secrets
        }')
    
    # Write output
    echo "$final_output" > "$output_file"
    print_color "$GREEN" "\n  ✅ Analysis complete: $output_file"
}

# Main execution
main() {
    print_color "$BLUE" "🔍 Alibaba Cloud API Key Analyzer"
    print_color "$BLUE" "=================================="
    echo ""
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Find all verified secrets files
    local secrets_dir="$ANALYZER_DIR/../force-push-scanner/leaked_secrets_results"
    
    if [ ! -d "$secrets_dir" ]; then
        print_color "$RED" "❌ Error: Secrets directory not found: $secrets_dir"
        exit 1
    fi
    
    print_color "$BLUE" "📂 Searching for Alibaba secrets in: $secrets_dir"
    
    # Find all verified_secrets JSON files containing Alibaba credentials
    local files_with_alibaba=$(find "$secrets_dir" -name "verified_secrets_*.json" -exec grep -l '"DetectorName": "Alibaba"' {} \; 2>/dev/null)
    
    if [ -z "$files_with_alibaba" ]; then
        print_color "$YELLOW" "⚠️  No Alibaba secrets found in any scanned repositories"
        exit 0
    fi
    
    local file_count=$(echo "$files_with_alibaba" | wc -l)
    print_color "$GREEN" "✓ Found Alibaba secrets in $file_count file(s)"
    
    # Process each file
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            analyze_secrets_file "$file"
        fi
    done <<< "$files_with_alibaba"
    
    # Print final statistics
    print_color "$BLUE" "\n📊 Analysis Summary"
    print_color "$BLUE" "==================="
    echo ""
    print_color "$GREEN" "Total Alibaba Keys Analyzed: $total_secrets"
    print_color "$RED" "Active Keys (CRITICAL): $active_secrets"
    print_color "$GREEN" "Revoked Keys: $inactive_secrets"
    print_color "$YELLOW" "Verification Errors: $error_secrets"
    echo ""
    
    if [ $active_secrets -gt 0 ]; then
        print_color "$RED" "⚠️  WARNING: $active_secrets active Alibaba Cloud API key(s) detected!"
        print_color "$RED" "   These keys provide full access to Alibaba Cloud infrastructure!"
        print_color "$RED" "   Immediate action required: Rotate these keys immediately!"
    fi
    
    print_color "$BLUE" "\n📁 Results saved to: $RESULTS_DIR"
}

# Run main function
main "$@"
