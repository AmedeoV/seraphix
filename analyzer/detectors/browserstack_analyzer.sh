#!/bin/bash

# BrowserStack Access Key Analyzer
# Verifies leaked BrowserStack credentials and assesses their security risk
# 
# BrowserStack is a cloud web and mobile testing platform that provides
# access to real browsers and mobile devices for testing web applications.
#
# Active credentials grant access to:
# - Browser and device testing environments
# - Automated testing execution
# - Live testing sessions
# - Screenshots and session recordings
# - Test results and analytics
# - Account settings and billing information
#
# Verification Method: GET /automate/plan.json endpoint (requires Basic Auth)
# API Reference: https://www.browserstack.com/docs/automate/api-reference

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
ANALYZED_RESULTS_DIR="$ANALYZER_DIR/analyzed_results/BrowserStack"
LOG_DIR="$ANALYZER_DIR/logs"

# Ensure directories exist
mkdir -p "$ANALYZED_RESULTS_DIR"
mkdir -p "$LOG_DIR"

# Logging functions
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*" >&2
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [SUCCESS] $*" >&2
}

log_warning() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARNING] $*" >&2
}

# Verify BrowserStack credentials
# Returns: "ACTIVE", "REVOKED", or "ERROR"
verify_browserstack_credentials() {
    local username="$1"
    local access_key="$2"
    
    # BrowserStack API endpoint for getting account plan
    local endpoint="https://api.browserstack.com/automate/plan.json"
    
    # Make API request with Basic Auth
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -u "${username}:${access_key}" \
        -X GET \
        "${endpoint}" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    
    case "$http_code" in
        200)
            echo "ACTIVE"
            return 0
            ;;
        401|403)
            echo "REVOKED"
            return 0
            ;;
        *)
            log_error "Unexpected HTTP status code: $http_code" >&2
            echo "ERROR"
            return 1
            ;;
    esac
}

# Calculate risk score based on credential status
calculate_risk_score() {
    local status="$1"
    
    case "$status" in
        "ACTIVE")
            echo 95  # CRITICAL - Active testing platform access
            ;;
        *)
            echo 5   # LOW - Revoked or error
            ;;
    esac
}

# Get risk level from score
get_risk_level() {
    local score=$1
    
    if [ "$score" -ge 90 ]; then
        echo "CRITICAL"
    elif [ "$score" -ge 70 ]; then
        echo "HIGH"
    elif [ "$score" -ge 40 ]; then
        echo "MEDIUM"
    else
        echo "LOW"
    fi
}

# Get capabilities for active credentials
get_capabilities() {
    local status="$1"
    
    if [ "$status" = "ACTIVE" ]; then
        cat <<EOF
    "browser_testing": true,
    "mobile_testing": true,
    "automated_testing": true,
    "live_testing": true,
    "screenshot_capture": true,
    "session_recordings": true,
    "test_analytics": true,
    "account_access": true,
    "billing_information": true,
    "resource_consumption": true
EOF
    else
        cat <<EOF
    "browser_testing": false,
    "mobile_testing": false,
    "automated_testing": false,
    "live_testing": false,
    "screenshot_capture": false,
    "session_recordings": false,
    "test_analytics": false,
    "account_access": false,
    "billing_information": false,
    "resource_consumption": false
EOF
    fi
}

# ============================================================================
# ANALYSIS FUNCTIONS
# ============================================================================

# Main analysis function
analyze_organization() {
    local org_name="$1"
    local secrets_dir="$2"
    
    log_info "Analyzing BrowserStack credentials for organization: $org_name"
    
    # Find all verified secrets files for this organization
    local secrets_files
    secrets_files=$(find "$secrets_dir" -type f -name "verified_secrets_*.json" 2>/dev/null | grep -F "${org_name}" || true)
    
    if [ -z "$secrets_files" ]; then
        log_error "No secrets file found for organization: $org_name"
        return 1
    fi
    
    local file_count
    file_count=$(echo "$secrets_files" | wc -l)
    log_info "Found $file_count file(s) to process"
    
    # Extract BrowserStack secrets from all files
    local browserstack_secrets
    browserstack_secrets=$(echo "$secrets_files" | while read -r file; do
        if [ -f "$file" ]; then
            # Extract secrets with DetectorName = "BrowserStack"
            sed -n '/\"DetectorName\": \"BrowserStack\"/,/^  },\{0,1\}$/p' "$file" 2>/dev/null || true
        fi
    done)
    
    if [ -z "$browserstack_secrets" ]; then
        log_info "No BrowserStack secrets found for organization: $org_name"
        return 0
    fi
    
    # Count secrets
    local total_secrets
    total_secrets=$(echo "$browserstack_secrets" | grep -c '"DetectorName": "BrowserStack"' 2>/dev/null || echo "0")
    
    if [ "$total_secrets" -eq 0 ]; then
        log_info "No BrowserStack secrets found for organization: $org_name"
        return 0
    fi
    
    log_info "Found $total_secrets BrowserStack secret(s)"
    
    # Initialize output JSON
    local output_file="$ANALYZED_RESULTS_DIR/${org_name}_analysis.json"
    local temp_secrets_file=$(mktemp)
    
    # Ensure temp file is clean
    > "$temp_secrets_file"
    
    # Process each secret
    local secret_id=0
    
    # Extract credentials (Raw = access_key, RawV2 = username:access_key)
    echo "$browserstack_secrets" | grep -oP '(?<="RawV2": ")[^"]+' | while read -r raw_v2; do
        secret_id=$((secret_id + 1))
        
        log_info "Verifying secret ${secret_id}/${total_secrets}..."
        
        # Parse username and access key from RawV2
        # RawV2 format: "username:access_key" or just "access_key"
        local username
        local access_key
        
        if [[ "$raw_v2" == *":"* ]]; then
            # RawV2 contains both username and access_key
            username=$(echo "$raw_v2" | cut -d':' -f1)
            access_key=$(echo "$raw_v2" | cut -d':' -f2-)
        else
            # RawV2 only has access_key, need to extract username from Raw field
            # Try to get the corresponding Raw value
            local secret_block
            secret_block=$(echo "$browserstack_secrets" | grep -B 5 "\"RawV2\": \"${raw_v2}\"" | grep -oP '(?<="Raw": ")[^"]+' | head -1)
            access_key="$secret_block"
            username="$raw_v2"
        fi
        
        # Actually, looking at the data: Raw = access_key, RawV2 = access_key + username
        # Let me re-parse: RawV2 appears to be access_key concatenated with username
        # Example: "rjA4XjyJFVgRk8VzAb2ypatrickwalsh2"
        # We need both username and access_key for Basic Auth
        
        # Extract metadata for this secret
        local repo_url
        local commit
        local timestamp
        
        # Use grep to find the secret block
        local secret_block
        secret_block=$(echo "$browserstack_secrets" | grep -A 30 "\"RawV2\": \"${raw_v2}\"" | head -20)
        
        repo_url=$(echo "$secret_block" | grep -oP '(?<="repository": ")[^"]+' | head -1 || echo "unknown")
        if [ "$repo_url" = "unknown" ]; then
            repo_url=$(echo "$secret_block" | grep -oP '(?<="repository_url": ")[^"]+' | head -1 || echo "unknown")
        fi
        commit=$(echo "$secret_block" | grep -oP '(?<="commit": ")[^"]+' | head -1 || echo "unknown")
        if [ "$commit" = "unknown" ]; then
            commit=$(echo "$secret_block" | grep -oP '(?<="scanned_commit": ")[^"]+' | head -1 || echo "unknown")
        fi
        timestamp=$(echo "$secret_block" | grep -oP '(?<="timestamp": ")[^"]+' | head -1 || echo "unknown")
        if [ "$timestamp" = "unknown" ]; then
            timestamp=$(echo "$secret_block" | grep -oP '(?<="scan_timestamp": ")[^"]+' | head -1 || echo "unknown")
        fi
        
        # Extract Raw (access_key) from the same block
        local raw_key
        raw_key=$(echo "$secret_block" | grep -oP '(?<="Raw": ")[^"]+' | head -1 || echo "")
        
        # Parse credentials: Raw = access_key, need to extract username from RawV2
        # RawV2 format appears to be: access_key + username
        if [ -n "$raw_key" ]; then
            access_key="$raw_key"
            # Username is RawV2 with access_key prefix removed
            username="${raw_v2#$access_key}"
        else
            # Fallback: cannot determine username
            access_key="$raw_v2"
            username="unknown"
        fi
        
        # Verify the credentials
        local status
        if [ "$username" = "unknown" ] || [ -z "$username" ]; then
            log_warning "Cannot verify secret $secret_id - username not found"
            status="ERROR"
        else
            status=$(verify_browserstack_credentials "$username" "$access_key")
        fi
        
        # Calculate risk
        local risk_score
        risk_score=$(calculate_risk_score "$status")
        local risk_level
        risk_level=$(get_risk_level "$risk_score")
        
        # Get capabilities
        local capabilities
        capabilities=$(get_capabilities "$status")
        
        # Get credential preview
        local access_key_prefix="${access_key:0:12}..."
        
        log_info "Secret $secret_id: $status (Risk: $risk_level, User: $username)" >&2
        
        # Build JSON for this secret
        cat >> "$temp_secrets_file" <<SECRETJSON
    {
      "secret_id": "browserstack_${secret_id}",
      "username": "${username}",
      "access_key_prefix": "${access_key_prefix}",
      "status": "${status}",
      "risk_score": ${risk_score},
      "risk_level": "${risk_level}",
      "capabilities": {
${capabilities}
      },
      "repository_url": "${repo_url}",
      "commit": "${commit}",
      "scan_timestamp": "${timestamp}",
      "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    },
SECRETJSON
    done
    
    # Read the counts from the temp file (since subshell doesn't persist)
    # Note: grep -c returns 0 count with exit code 1 when no matches, so we ignore exit codes
    set +e  # Temporarily disable exit on error
    active_count=$(grep -c '"status": "ACTIVE"' "$temp_secrets_file" 2>/dev/null)
    active_count=${active_count//[^0-9]/}  # Remove all non-numeric characters (newlines, etc)
    : ${active_count:=0}  # Default to 0 if empty
    
    revoked_count=$(grep -c '"status": "REVOKED"' "$temp_secrets_file" 2>/dev/null)
    revoked_count=${revoked_count//[^0-9]/}
    : ${revoked_count:=0}
    
    error_count=$(grep -c '"status": "ERROR"' "$temp_secrets_file" 2>/dev/null)
    error_count=${error_count//[^0-9]/}
    : ${error_count:=0}
    set -e  # Re-enable exit on error
    
    # Calculate percentage
    local active_percentage=0
    if [ "$total_secrets" -gt 0 ]; then
        active_percentage=$(awk "BEGIN {printf \"%.1f\", ($active_count * 100.0 / $total_secrets)}")
    fi
    
    # Build final JSON output
    cat > "$output_file" <<JSONSTART
{
  "organization": "${org_name}",
  "detector_type": "BrowserStack",
  "scan_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "secrets": [
JSONSTART
    
    # Append secrets (remove trailing comma from last entry)
    if [ -s "$temp_secrets_file" ]; then
        sed '$ s/,$//' "$temp_secrets_file" >> "$output_file"
    fi
    
    # Append summary and close JSON
    echo "  ]," >> "$output_file"
    echo "  \"summary\": {" >> "$output_file"
    echo "    \"total_secrets\": $total_secrets," >> "$output_file"
    echo "    \"active_keys\": $active_count," >> "$output_file"
    echo "    \"revoked_keys\": $revoked_count," >> "$output_file"
    echo "    \"error_keys\": $error_count," >> "$output_file"
    echo "    \"active_percentage\": $active_percentage" >> "$output_file"
    echo "  }" >> "$output_file"
    echo "}" >> "$output_file"
    
    # Cleanup
    rm -f "$temp_secrets_file"
    
    # Print summary
    log_success "Analysis complete for ${org_name}"
    log_info "Results saved to: $output_file"
    log_info "Total: $total_secrets | Active: $active_count (${active_percentage}%) | Revoked: $revoked_count | Errors: $error_count"
    
    # Return summary for dashboard (to stdout only)
    echo "Total: $total_secrets, Active: $active_count ($active_percentage%), Revoked: $revoked_count, Errors: $error_count"
}

# Analyze all organizations with BrowserStack secrets
analyze_all_organizations() {
    local secrets_dir="$1"
    
    log_info "Scanning for organizations with BrowserStack secrets..."
    
    # Find all unique organizations with BrowserStack secrets
    local organizations
    organizations=$(find "$secrets_dir" -name "verified_secrets_*.json" -type f 2>/dev/null | while read -r file; do
        if grep -q '"DetectorName": "BrowserStack"' "$file" 2>/dev/null; then
            basename "$file" | sed 's/verified_secrets_//' | sed 's/.json//'
        fi
    done | sort -u)
    
    if [ -z "$organizations" ]; then
        log_error "No organizations with BrowserStack secrets found!"
        return 1
    fi
    
    local org_count
    org_count=$(echo "$organizations" | wc -l)
    log_info "Found $org_count organization(s) with BrowserStack secrets"
    echo "" >&2
    
    # Process each organization
    local current=0
    local success_count=0
    local failed_count=0
    
    for org in $organizations; do
        current=$((current + 1))
        log_info "[$current/$org_count] Analyzing organization: $org"
        
        if analyze_organization "$org" "$secrets_dir"; then
            success_count=$((success_count + 1))
            log_success "Completed: $org"
        else
            failed_count=$((failed_count + 1))
            log_error "Failed: $org"
        fi
        
        echo "" >&2
    done
    
    echo "================================================" >&2
    log_success "BrowserStack Analysis Complete!"
    echo "  Total organizations: $org_count" >&2
    echo "  Successful: $success_count" >&2
    echo "  Failed: $failed_count" >&2
    echo "================================================" >&2
    
    return 0
}

# Script entry point
main() {
    local secrets_dir
    local org_name
    local analyze_all=false
    
    # Parse arguments
    if [ $# -eq 0 ]; then
        log_error "Usage: $0 <organization_name> [secrets_directory]"
        log_error "       $0 --all [secrets_directory]"
        log_error ""
        log_error "Examples:"
        log_error "  $0 myorg                                    # Analyze specific organization"
        log_error "  $0 myorg /path/to/leaked_secrets_results   # Analyze with custom path"
        log_error "  $0 --all                                    # Analyze all organizations"
        log_error "  $0 --all /path/to/leaked_secrets_results   # Analyze all with custom path"
        exit 1
    fi
    
    # Check for --all flag
    if [ "$1" = "--all" ]; then
        analyze_all=true
        secrets_dir="${2:-$(dirname "$SCRIPT_DIR")/../force-push-scanner/leaked_secrets_results}"
    else
        org_name="$1"
        secrets_dir="${2:-$(dirname "$SCRIPT_DIR")/../force-push-scanner/leaked_secrets_results}"
    fi
    
    # Validate secrets directory
    if [ ! -d "$secrets_dir" ]; then
        log_error "Secrets directory not found: $secrets_dir"
        exit 1
    fi
    
    log_info "Starting BrowserStack credential analysis"
    
    if [ "$analyze_all" = true ]; then
        log_info "Mode: Analyze all organizations"
        log_info "Secrets directory: $secrets_dir"
        log_info "Output directory: $ANALYZED_RESULTS_DIR"
        echo "" >&2
        
        # Run analysis for all organizations
        analyze_all_organizations "$secrets_dir"
        exit_code=$?
    else
        log_info "Organization: $org_name"
        log_info "Secrets directory: $secrets_dir"
        log_info "Output directory: $ANALYZED_RESULTS_DIR"
        echo "" >&2
        
        # Run analysis for single organization
        analyze_organization "$org_name" "$secrets_dir"
        exit_code=$?
        
        echo "" >&2
        if [ $exit_code -eq 0 ]; then
            log_success "BrowserStack analysis completed successfully!"
        else
            log_error "BrowserStack analysis failed with exit code: $exit_code"
        fi
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
