#!/bin/bash

# Azure Storage Account Key Analyzer
# Verifies leaked Azure credentials and assesses their security risk
# 
# Azure provides various types of credentials:
# - Storage Account Keys: Full access to blob, file, queue, and table storage
# - Client Secrets: Service principal credentials for Azure AD authentication
# - Access Keys: Various other Azure service keys
#
# Active keys grant access to:
# - Blob storage (files, images, backups)
# - File shares (SMB file shares in the cloud)
# - Queue storage (message queuing)
# - Table storage (NoSQL data)
# - Azure resources and services
# - Account configuration and management
#
# Note: This analyzer currently detects Azure secrets but full verification
# requires additional context (tenant ID, client ID, storage account name, etc.)
# API Reference: https://learn.microsoft.com/en-us/rest/api/storageservices/

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
ANALYZED_RESULTS_DIR="$ANALYZER_DIR/analyzed_results/Azure"
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

# Get Azure access token using Service Principal credentials
get_azure_access_token() {
    local client_id="$1"
    local client_secret="$2"
    local tenant_id="$3"
    
    local response
    response=$(curl -s -X POST \
        "https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${client_id}" \
        -d "client_secret=${client_secret}" \
        -d "scope=https://management.azure.com/.default" \
        -d "grant_type=client_credentials" 2>&1)
    
    # Check if we got an access token
    local access_token
    access_token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
    
    if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
        echo "$access_token"
        return 0
    else
        return 1
    fi
}

# Check Azure Service Principal permissions and accessible resources
check_azure_permissions() {
    local access_token="$1"
    local permissions_file="$2"
    
    # Initialize permissions structure
    cat > "$permissions_file" <<EOF
{
  "authentication": "SUCCESS",
  "subscriptions": [],
  "resource_groups": [],
  "role_assignments": [],
  "accessible_resources": {
    "virtual_machines": [],
    "storage_accounts": [],
    "key_vaults": [],
    "databases": [],
    "app_services": []
  },
  "permissions_summary": {
    "can_list_subscriptions": false,
    "can_list_resource_groups": false,
    "can_list_vms": false,
    "can_list_storage": false,
    "can_list_key_vaults": false,
    "can_list_databases": false,
    "subscription_count": 0,
    "resource_group_count": 0,
    "total_resources_found": 0
  }
}
EOF
    
    # 1. Try to list subscriptions
    log_info "  → Testing subscription access..."
    local subscriptions
    subscriptions=$(curl -s -X GET \
        "https://management.azure.com/subscriptions?api-version=2020-01-01" \
        -H "Authorization: Bearer ${access_token}" 2>/dev/null)
    
    local sub_count=0
    if echo "$subscriptions" | jq -e '.value[]?' >/dev/null 2>&1; then
        sub_count=$(echo "$subscriptions" | jq '.value | length' 2>/dev/null || echo "0")
        log_success "  ✓ Can list subscriptions ($sub_count found)"
        jq --argjson subs "$(echo "$subscriptions" | jq '.value // []')" \
           '.subscriptions = $subs | .permissions_summary.can_list_subscriptions = true | .permissions_summary.subscription_count = ($subs | length)' \
           "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
    else
        log_warning "  ✗ Cannot list subscriptions"
    fi
    
    # 2. For each subscription, try to list resource groups and resources
    if [ "$sub_count" -gt 0 ]; then
        echo "$subscriptions" | jq -r '.value[]?.subscriptionId // empty' 2>/dev/null | while read -r sub_id; do
            [ -z "$sub_id" ] && continue
            
            log_info "  → Checking subscription: $sub_id"
            
            # List resource groups
            local rgs
            rgs=$(curl -s -X GET \
                "https://management.azure.com/subscriptions/${sub_id}/resourcegroups?api-version=2021-04-01" \
                -H "Authorization: Bearer ${access_token}" 2>/dev/null)
            
            if echo "$rgs" | jq -e '.value[]?' >/dev/null 2>&1; then
                local rg_count
                rg_count=$(echo "$rgs" | jq '.value | length' 2>/dev/null || echo "0")
                log_success "    ✓ Can list resource groups ($rg_count found)"
                jq --argjson newrgs "$(echo "$rgs" | jq '.value // []')" \
                   '.resource_groups += $newrgs | .permissions_summary.can_list_resource_groups = true | .permissions_summary.resource_group_count += ($newrgs | length)' \
                   "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
                
                # Try to list VMs
                local vms
                vms=$(curl -s -X GET \
                    "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Compute/virtualMachines?api-version=2021-03-01" \
                    -H "Authorization: Bearer ${access_token}" 2>/dev/null)
                
                if echo "$vms" | jq -e '.value[]?' >/dev/null 2>&1; then
                    local vm_count
                    vm_count=$(echo "$vms" | jq '.value | length' 2>/dev/null || echo "0")
                    log_success "    ✓ Can list VMs ($vm_count found)"
                    jq --argjson newvms "$(echo "$vms" | jq '.value // []')" \
                       '.accessible_resources.virtual_machines += $newvms | .permissions_summary.can_list_vms = true | .permissions_summary.total_resources_found += ($newvms | length)' \
                       "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
                fi
                
                # Try to list Storage Accounts
                local storage
                storage=$(curl -s -X GET \
                    "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Storage/storageAccounts?api-version=2021-04-01" \
                    -H "Authorization: Bearer ${access_token}" 2>/dev/null)
                
                if echo "$storage" | jq -e '.value[]?' >/dev/null 2>&1; then
                    local storage_count
                    storage_count=$(echo "$storage" | jq '.value | length' 2>/dev/null || echo "0")
                    log_success "    ✓ Can list Storage Accounts ($storage_count found)"
                    jq --argjson newstorage "$(echo "$storage" | jq '.value // []')" \
                       '.accessible_resources.storage_accounts += $newstorage | .permissions_summary.can_list_storage = true | .permissions_summary.total_resources_found += ($newstorage | length)' \
                       "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
                fi
                
                # Try to list Key Vaults
                local keyvaults
                keyvaults=$(curl -s -X GET \
                    "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.KeyVault/vaults?api-version=2021-06-01-preview" \
                    -H "Authorization: Bearer ${access_token}" 2>/dev/null)
                
                if echo "$keyvaults" | jq -e '.value[]?' >/dev/null 2>&1; then
                    local kv_count
                    kv_count=$(echo "$keyvaults" | jq '.value | length' 2>/dev/null || echo "0")
                    log_success "    ✓ Can list Key Vaults ($kv_count found)"
                    jq --argjson newkv "$(echo "$keyvaults" | jq '.value // []')" \
                       '.accessible_resources.key_vaults += $newkv | .permissions_summary.can_list_key_vaults = true | .permissions_summary.total_resources_found += ($newkv | length)' \
                       "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
                fi
                
                # Try to list SQL Databases
                local databases
                databases=$(curl -s -X GET \
                    "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Sql/servers?api-version=2021-02-01-preview" \
                    -H "Authorization: Bearer ${access_token}" 2>/dev/null)
                
                if echo "$databases" | jq -e '.value[]?' >/dev/null 2>&1; then
                    local db_count
                    db_count=$(echo "$databases" | jq '.value | length' 2>/dev/null || echo "0")
                    log_success "    ✓ Can list SQL Servers ($db_count found)"
                    jq --argjson newdb "$(echo "$databases" | jq '.value // []')" \
                       '.accessible_resources.databases += $newdb | .permissions_summary.can_list_databases = true | .permissions_summary.total_resources_found += ($newdb | length)' \
                       "$permissions_file" > "${permissions_file}.tmp" && mv "${permissions_file}.tmp" "$permissions_file"
                fi
            fi
        done
    fi
}

# Verify Azure credential
# Returns: "ACTIVE", "REVOKED", "UNKNOWN", or "ERROR"
verify_azure_credential() {
    local raw_secret="$1"
    local rawv2="$2"
    local permissions_output_file="$3"
    
    if [ -z "$raw_secret" ]; then
        echo "ERROR"
        return 1
    fi
    
    # Check if we have RawV2 with full context (client ID, tenant ID, secret)
    if [ -n "$rawv2" ] && echo "$rawv2" | jq -e '.clientId and .tenantId and .clientSecret' >/dev/null 2>&1; then
        log_info "  → Found Service Principal credentials, attempting authentication..."
        
        local client_id
        local client_secret
        local tenant_id
        
        client_id=$(echo "$rawv2" | jq -r '.clientId')
        client_secret=$(echo "$rawv2" | jq -r '.clientSecret')
        tenant_id=$(echo "$rawv2" | jq -r '.tenantId')
        
        # Try to get an access token
        local access_token
        access_token=$(get_azure_access_token "$client_id" "$client_secret" "$tenant_id")
        
        if [ -n "$access_token" ]; then
            log_success "  ✓ Authentication successful!"
            
            # Check permissions if output file provided
            if [ -n "$permissions_output_file" ]; then
                log_info "  → Enumerating permissions and accessible resources..."
                check_azure_permissions "$access_token" "$permissions_output_file"
            fi
            
            echo "ACTIVE"
            return 0
        else
            log_warning "  ✗ Authentication failed (revoked or invalid)"
            echo "REVOKED"
            return 0
        fi
    else
        # No full context - check format only
        local secret_len=${#raw_secret}
        
        if [[ "$raw_secret" =~ ^sv= ]] || [[ "$raw_secret" =~ sig= ]]; then
            echo "UNKNOWN"
            return 0
        elif [[ "$raw_secret" =~ ^[A-Za-z0-9+/]{86}==$ ]]; then
            echo "UNKNOWN"
            return 0
        elif [[ "$secret_len" -ge 20 ]] && [[ "$raw_secret" =~ [A-Za-z0-9~_.-] ]]; then
            echo "UNKNOWN"
            return 0
        else
            echo "ERROR"
            return 1
        fi
    fi
}

# Calculate risk score based on key status
calculate_risk_score() {
    local status="$1"
    
    case "$status" in
        "ACTIVE"|"UNKNOWN")
            echo 95  # CRITICAL - Potential full Azure access
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

# Get capabilities for active keys
get_capabilities() {
    local status="$1"
    local permissions_file="$2"
    
    if [ "$status" = "ACTIVE" ] && [ -f "$permissions_file" ]; then
        # Read actual permissions from the file
        local can_list_subs=$(jq -r '.permissions_summary.can_list_subscriptions // false' "$permissions_file")
        local can_list_rgs=$(jq -r '.permissions_summary.can_list_resource_groups // false' "$permissions_file")
        local can_list_vms=$(jq -r '.permissions_summary.can_list_vms // false' "$permissions_file")
        local can_list_storage=$(jq -r '.permissions_summary.can_list_storage // false' "$permissions_file")
        local can_list_kv=$(jq -r '.permissions_summary.can_list_key_vaults // false' "$permissions_file")
        local can_list_db=$(jq -r '.permissions_summary.can_list_databases // false' "$permissions_file")
        local sub_count=$(jq -r '.permissions_summary.subscription_count // 0' "$permissions_file")
        local rg_count=$(jq -r '.permissions_summary.resource_group_count // 0' "$permissions_file")
        local total_resources=$(jq -r '.permissions_summary.total_resources_found // 0' "$permissions_file")
        
        cat <<EOF
    "verified_access": true,
    "can_list_subscriptions": $can_list_subs,
    "can_list_resource_groups": $can_list_rgs,
    "can_list_virtual_machines": $can_list_vms,
    "can_list_storage_accounts": $can_list_storage,
    "can_list_key_vaults": $can_list_kv,
    "can_list_databases": $can_list_db,
    "subscriptions_found": $sub_count,
    "resource_groups_found": $rg_count,
    "total_resources_found": $total_resources,
    "data_access_risk": true,
    "configuration_risk": true
EOF
    elif [ "$status" = "ACTIVE" ] || [ "$status" = "UNKNOWN" ]; then
        cat <<EOF
    "potential_blob_storage_access": true,
    "potential_file_storage_access": true,
    "potential_queue_storage_access": true,
    "potential_table_storage_access": true,
    "potential_service_access": true,
    "data_access_risk": true,
    "configuration_risk": true,
    "requires_verification": true
EOF
    else
        cat <<EOF
    "potential_service_access": false,
    "data_access_risk": false,
    "configuration_risk": false,
    "requires_verification": false
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
    
    log_info "Analyzing Azure Storage keys for organization: $org_name"
    
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
    
    # Process files and extract Azure secrets using jq
    local azure_secrets_json=$(mktemp)
    echo "$secrets_files" | while read -r file; do
        if [ -f "$file" ]; then
            jq '[.[] | select(.DetectorName == "Azure")]' "$file" 2>/dev/null || echo "[]"
        fi
    done | jq -s 'add' > "$azure_secrets_json"
    
    # Count secrets
    local total_secrets
    total_secrets=$(jq 'length' "$azure_secrets_json" 2>/dev/null || echo "0")
    
    if [ "$total_secrets" -eq 0 ]; then
        log_info "No Azure secrets found for organization: $org_name"
        rm -f "$azure_secrets_json"
        return 0
    fi
    
    log_info "Found $total_secrets Azure secret(s)"
    
    # Initialize output JSON
    local output_file="$ANALYZED_RESULTS_DIR/${org_name}_analysis.json"
    local temp_secrets_file=$(mktemp)
    
    # Ensure temp file is clean
    > "$temp_secrets_file"
    
    # Process each secret
    local secret_id=0
    local active_count=0
    local revoked_count=0
    local error_count=0
    
    # Process each secret using jq
    local secret_id=0
    for secret_idx in $(seq 0 $((total_secrets - 1))); do
        secret_id=$((secret_id + 1))
        
        log_info "Verifying secret ${secret_id}/${total_secrets}..."
        
        # Extract all data for this secret using jq
        local secret_json
        secret_json=$(jq ".[$secret_idx]" "$azure_secrets_json")
        
        local raw_secret=$(echo "$secret_json" | jq -r '.Raw // ""')
        local rawv2=$(echo "$secret_json" | jq -r '.RawV2 // ""')
        local repo_url=$(echo "$secret_json" | jq -r '.repository_url // .SourceMetadata.Data.Git.repository // "unknown"')
        local commit=$(echo "$secret_json" | jq -r '.scanned_commit // .SourceMetadata.Data.Git.commit // "unknown"')
        local timestamp=$(echo "$secret_json" | jq -r '.scan_timestamp // .SourceMetadata.Data.Git.timestamp // "unknown"')
        local client_id=$(echo "$secret_json" | jq -r '.ExtraData.client // ""')
        local tenant_id=$(echo "$secret_json" | jq -r '.ExtraData.tenant // ""')
        local application=$(echo "$secret_json" | jq -r '.ExtraData.application // ""')
        
        # Create temporary permissions file for this secret
        local permissions_file=$(mktemp)
        
        # Verify the credential
        local status
        status=$(verify_azure_credential "$raw_secret" "$rawv2" "$permissions_file")
        
        # Calculate risk
        local risk_score
        risk_score=$(calculate_risk_score "$status")
        local risk_level
        risk_level=$(get_risk_level "$risk_score")
        
        # Get capabilities
        local capabilities
        capabilities=$(get_capabilities "$status" "$permissions_file")
        
        # Get secret prefix for display
        local secret_prefix="${raw_secret:0:12}..."
        
        log_info "Secret $secret_id: $status (Risk: $risk_level)" >&2
        
        # Build JSON for this secret
        cat >> "$temp_secrets_file" <<SECRETJSON
    {
      "secret_id": "azure_${secret_id}",
      "raw_secret": "${raw_secret}",
      "secret_prefix": "${secret_prefix}",
      "status": "${status}",
      "risk_score": ${risk_score},
      "risk_level": "${risk_level}",
      "azure_metadata": {
        "client_id": "${client_id}",
        "tenant_id": "${tenant_id}",
        "application": "${application}"
      },
      "capabilities": {
${capabilities}
      },
SECRETJSON

        # Add detailed permissions if we have them
        if [ "$status" = "ACTIVE" ] && [ -f "$permissions_file" ]; then
            echo '      "detailed_permissions": ' >> "$temp_secrets_file"
            cat "$permissions_file" >> "$temp_secrets_file"
            echo ',' >> "$temp_secrets_file"
        fi
        
        cat >> "$temp_secrets_file" <<SECRETJSON2
      "repository_url": "${repo_url}",
      "commit": "${commit}",
      "scan_timestamp": "${timestamp}",
      "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    },
SECRETJSON2
        
        # Cleanup temp permissions file
        rm -f "$permissions_file"
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
    
    unknown_count=$(grep -c '"status": "UNKNOWN"' "$temp_secrets_file" 2>/dev/null)
    unknown_count=${unknown_count//[^0-9]/}
    : ${unknown_count:=0}
    
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
  "detector_type": "Azure",
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
    
    # Print summary
    log_success "Analysis complete for ${org_name}"
    log_info "Results saved to: $output_file"
    log_info "Total: $total_secrets | Active: $active_count (${active_percentage}%) | Unknown: $unknown_count | Revoked: $revoked_count | Errors: $error_count"

    
    # Cleanup
    rm -f "$temp_secrets_file"
    rm -f "$azure_secrets_json"
    
    log_success "Analysis complete for $org_name"
    log_info "Results saved to: $output_file"
    log_info "Summary: Total=$total_secrets, Active=$active_count ($active_percentage%), Revoked=$revoked_count, Errors=$error_count"
    
    # Return summary for dashboard (to stdout only)
    echo "Total: $total_secrets, Active: $active_count ($active_percentage%), Revoked: $revoked_count, Errors: $error_count"
}

# Analyze all organizations with Azure secrets
analyze_all_organizations() {
    local secrets_dir="$1"
    
    log_info "Scanning for organizations with Azure secrets..."
    
    # Find all unique organizations with Azure secrets
    local organizations
    organizations=$(find "$secrets_dir" -name "verified_secrets_*.json" -type f 2>/dev/null | while read -r file; do
        if grep -q '"DetectorName": "Azure"' "$file" 2>/dev/null; then
            basename "$file" | sed 's/verified_secrets_//' | sed 's/.json//'
        fi
    done | sort -u)
    
    if [ -z "$organizations" ]; then
        log_error "No organizations with Azure secrets found!"
        return 1
    fi
    
    local org_count
    org_count=$(echo "$organizations" | wc -l)
    log_info "Found $org_count organization(s) with Azure secrets"
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
    log_success "Azure Analysis Complete!"
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
    
    log_info "Starting Azure Storage key analysis"
    
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
            log_success "Azure analysis completed successfully!"
        else
            log_error "Azure analysis failed with exit code: $exit_code"
        fi
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
