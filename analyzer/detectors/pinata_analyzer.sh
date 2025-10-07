#!/bin/bash

# Pinata API Analyzer
# Analyzes leaked Pinata API secrets and assesses their security risk
# 
# Pinata provides IPFS pinning services. Keys can upload and manage content.
#
# Note: This analyzer detects secrets but may not verify them without live API testing.
# All detected secrets are marked as UNKNOWN and flagged as critical risk.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
ANALYZED_RESULTS_DIR="$ANALYZER_DIR/analyzed_results/Pinata"
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

# Verify Pinata API secret
# Returns: "UNKNOWN" (detected but not verified without live testing)
verify_secret() {
    local secret="$1"
    
    # For services without specific verification endpoints,
    # we mark as UNKNOWN (detected but not verified)
    echo "UNKNOWN"
    return 0
}

# Calculate risk score based on secret status
calculate_risk_score() {
    local status="$1"
    
    case "$status" in
        "ACTIVE")
            echo 85  # CRITICAL - Verified active secret
            ;;
        "UNKNOWN")
            echo 85  # CRITICAL - Detected secret (assume compromised)
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

# Get capabilities for detected secrets
get_capabilities() {
    local status="$1"
    
    if [ "$status" = "ACTIVE" ] || [ "$status" = "UNKNOWN" ]; then
        cat <<EOF
    "ipfs_upload": true,
    "pin_management": true,
    "content_access": true,
    "gateway_access": true
EOF
    else
        cat <<EOF
    "ipfs_upload": false,
    "pin_management": false,
    "content_access": false,
    "gateway_access": false
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
    
    log_info "Analyzing Pinata API secrets for organization: $org_name"
    
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
    
    # Extract Pinata API secrets from all files
    local detector_secrets
    detector_secrets=$(echo "$secrets_files" | while read -r file; do
        if [ -f "$file" ]; then
            # Extract secrets with DetectorName = "Pinata"
            sed -n '/\"DetectorName\": \"Pinata\"/,/^  },\{0,1\}$/p' "$file" 2>/dev/null || true
        fi
    done)
    
    if [ -z "$detector_secrets" ]; then
        log_info "No Pinata API secrets found for organization: $org_name"
        return 0
    fi
    
    # Count secrets
    local total_secrets
    total_secrets=$(echo "$detector_secrets" | grep -c '\"DetectorName\": \"Pinata\"' 2>/dev/null || echo "0")
    
    if [ "$total_secrets" -eq 0 ]; then
        log_info "No Pinata API secrets found for organization: $org_name"
        return 0
    fi
    
    log_info "Found $total_secrets Pinata API secret(s)"
    
    # Initialize output JSON
    local output_file="$ANALYZED_RESULTS_DIR/${org_name}_analysis.json"
    local temp_secrets_file=$(mktemp)
    
    # Ensure temp file is clean
    > "$temp_secrets_file"
    
    # Process each secret
    local secret_id=0
    
    echo "$detector_secrets" | grep -oP '(?<="Raw": ")[^"]+' | while read -r raw_secret; do
        secret_id=$((secret_id + 1))
        
        log_info "Analyzing secret ${secret_id}/${total_secrets}..."
        
        # Extract metadata for this secret
        local repo_url
        local commit
        local timestamp
        
        # Use grep to find the secret block
        local secret_block
        secret_block=$(echo "$detector_secrets" | grep -A 30 "\"Raw\": \"${raw_secret}\"" | head -20)
        
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
        
        # Verify the secret
        local status
        status=$(verify_secret "$raw_secret")
        
        # Calculate risk
        local risk_score
        risk_score=$(calculate_risk_score "$status")
        local risk_level
        risk_level=$(get_risk_level "$risk_score")
        
        # Get capabilities
        local capabilities
        capabilities=$(get_capabilities "$status")
        
        # Get secret prefix for display
        local secret_prefix="${raw_secret:0:12}..."
        
        log_info "Secret $secret_id: $status (Risk: $risk_level)" >&2
        
        # Build JSON for this secret
        cat >> "$temp_secrets_file" <<SECRETJSON
    {
      "secret_id": "pinata_${secret_id}",
      "raw_secret": "${raw_secret}",

      "secret_prefix": "${secret_prefix}",
      "status": "${status}",
      "risk_score": ${risk_score},
      "risk_level": "${risk_level}",
      "capabilities": {
${capabilities}
      },
      "repository_url": "${repo_url}",
      "commit": "${commit}",
      "scan_timestamp": "${timestamp}",
      "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "note": "Secret detected - full verification may require live API testing"
    },
SECRETJSON
    done
    
    # Read the counts from the temp file (since subshell doesn't persist)
    set +e  # Temporarily disable exit on error
    active_count=$(grep -c '\"status\": \"ACTIVE\"' "$temp_secrets_file" 2>/dev/null)
    active_count=${active_count//[^0-9]/}
    : ${active_count:=0}
    
    revoked_count=$(grep -c '\"status\": \"REVOKED\"' "$temp_secrets_file" 2>/dev/null)
    revoked_count=${revoked_count//[^0-9]/}
    : ${revoked_count:=0}
    
    unknown_count=$(grep -c '\"status\": \"UNKNOWN\"' "$temp_secrets_file" 2>/dev/null)
    unknown_count=${unknown_count//[^0-9]/}
    : ${unknown_count:=0}
    
    error_count=$(grep -c '\"status\": \"ERROR\"' "$temp_secrets_file" 2>/dev/null)
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
  "detector_type": "Pinata",
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
    echo "    \"unknown_keys\": $unknown_count," >> "$output_file"
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
    log_info "Total: $total_secrets | Active: $active_count | Unknown: $unknown_count | Revoked: $revoked_count | Errors: $error_count"
    
    # Return summary for dashboard (to stdout only)
    echo "Total: $total_secrets, Active: $active_count, Unknown: $unknown_count, Revoked: $revoked_count, Errors: $error_count"
}

# Analyze all organizations with Pinata API secrets
analyze_all_organizations() {
    local secrets_dir="$1"
    
    log_info "Scanning for organizations with Pinata API secrets..."
    
    # Find all unique organizations with Pinata API secrets
    local organizations
    organizations=$(find "$secrets_dir" -name "verified_secrets_*.json" -type f 2>/dev/null | while read -r file; do
        if grep -q '\"DetectorName\": \"Pinata\"' "$file" 2>/dev/null; then
            basename "$file" | sed 's/verified_secrets_//' | sed 's/.json//'
        fi
    done | sort -u)
    
    if [ -z "$organizations" ]; then
        log_error "No organizations with Pinata API secrets found!"
        return 1
    fi
    
    local org_count
    org_count=$(echo "$organizations" | wc -l)
    log_info "Found $org_count organization(s) with Pinata API secrets"
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
    log_success "Pinata API Analysis Complete!"
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
    
    log_info "Starting Pinata API analysis"
    
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
            log_success "Pinata API analysis completed successfully!"
        else
            log_error "Pinata API analysis failed with exit code: $exit_code"
        fi
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
