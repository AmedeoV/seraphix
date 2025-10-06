#!/bin/bash

# AWS Credentials Analyzer
# Verifies leaked AWS access keys and secret keys and assesses their security risk
# 
# AWS (Amazon Web Services) credentials consist of:
# - Access Key ID: Starts with "AKIA" (20 characters)
# - Secret Access Key: 40 character base64 string
#
# Active keys grant access to:
# - AWS account resources (EC2, S3, RDS, Lambda, etc.)
# - IAM permissions based on attached policies
# - Potential for privilege escalation
# - Data exfiltration from S3, databases
# - Resource manipulation and destruction
# - Cost implications (crypto mining, etc.)
#
# Verification Method: AWS STS GetCallerIdentity API
# API Reference: https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
ANALYZED_RESULTS_DIR="$ANALYZER_DIR/analyzed_results/AWS"
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

# Check and install AWS CLI if needed
ensure_aws_cli() {
    if command -v aws >/dev/null 2>&1; then
        log_info "AWS CLI is already installed: $(aws --version 2>&1 | head -1)"
        return 0
    fi
    
    log_warning "AWS CLI not found. Installing..."
    
    # Detect OS and install accordingly
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux installation
        log_info "Installing AWS CLI v2 for Linux..."
        
        # Download and install AWS CLI v2
        cd /tmp
        curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        
        if ! command -v unzip >/dev/null 2>&1; then
            log_info "Installing unzip..."
            sudo apt-get update -qq && sudo apt-get install -y -qq unzip >/dev/null 2>&1
        fi
        
        unzip -q awscliv2.zip
        sudo ./aws/install >/dev/null 2>&1
        rm -rf awscliv2.zip aws
        
        log_success "AWS CLI installed successfully"
        aws --version
        
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS installation
        log_info "Installing AWS CLI v2 for macOS..."
        
        cd /tmp
        curl -s "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
        sudo installer -pkg AWSCLIV2.pkg -target / >/dev/null 2>&1
        rm AWSCLIV2.pkg
        
        log_success "AWS CLI installed successfully"
        
    else
        log_error "Unsupported operating system: $OSTYPE"
        log_error "Please install AWS CLI manually: https://aws.amazon.com/cli/"
        return 1
    fi
    
    return 0
}

# Verify AWS credentials using AWS CLI
# Returns: JSON with status and account info, or error message
verify_aws_credentials() {
    local access_key_id="$1"
    local secret_access_key="$2"
    
    # Use STS GetCallerIdentity to verify credentials
    local result
    result=$(AWS_ACCESS_KEY_ID="$access_key_id" \
             AWS_SECRET_ACCESS_KEY="$secret_access_key" \
             aws sts get-caller-identity \
             --output json 2>&1) || true
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # Parse the response
        local user_id account arn
        user_id=$(echo "$result" | jq -r '.UserId' 2>/dev/null || echo "unknown")
        account=$(echo "$result" | jq -r '.Account' 2>/dev/null || echo "unknown")
        arn=$(echo "$result" | jq -r '.Arn' 2>/dev/null || echo "unknown")
        
        echo "ACTIVE|$user_id|$account|$arn"
    else
        # Check error message
        if echo "$result" | grep -q "InvalidClientTokenId\|SignatureDoesNotMatch\|InvalidAccessKeyId"; then
            echo "REVOKED"
        elif echo "$result" | grep -q "ExpiredToken"; then
            echo "EXPIRED"
        elif echo "$result" | grep -q "AccessDenied"; then
            # Key exists but has no permissions
            echo "ACTIVE_NO_PERMISSIONS"
        else
            log_error "Unexpected error verifying AWS key: $result" >&2
            echo "ERROR"
        fi
    fi
}

# Calculate risk score based on key status and account info
calculate_risk_score() {
    local status="$1"
    local arn="${2:-unknown}"
    
    case "$status" in
        "ACTIVE")
            # Check if it's a root account key (highest risk)
            if echo "$arn" | grep -q ":root"; then
                echo 100  # CRITICAL - Root account access
            else
                echo 95   # CRITICAL - IAM user access
            fi
            ;;
        "ACTIVE_NO_PERMISSIONS")
            echo 60  # MEDIUM - Key is valid but has no permissions
            ;;
        "EXPIRED")
            echo 20  # LOW - Expired key
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

# Get capabilities based on status
get_capabilities() {
    local status="$1"
    local arn="${2:-unknown}"
    
    if [ "$status" = "ACTIVE" ]; then
        # Check if root account
        local is_root="false"
        if echo "$arn" | grep -q ":root"; then
            is_root="true"
        fi
        
        cat <<EOF
    "ec2_access": true,
    "s3_access": true,
    "iam_access": true,
    "rds_access": true,
    "lambda_access": true,
    "cloudformation_access": true,
    "data_exfiltration": true,
    "resource_manipulation": true,
    "cost_generation": true,
    "privilege_escalation_risk": true,
    "is_root_account": $is_root
EOF
    elif [ "$status" = "ACTIVE_NO_PERMISSIONS" ]; then
        cat <<EOF
    "ec2_access": false,
    "s3_access": false,
    "iam_access": false,
    "rds_access": false,
    "lambda_access": false,
    "cloudformation_access": false,
    "data_exfiltration": false,
    "resource_manipulation": false,
    "cost_generation": false,
    "privilege_escalation_risk": false,
    "is_root_account": false
EOF
    else
        cat <<EOF
    "ec2_access": false,
    "s3_access": false,
    "iam_access": false,
    "rds_access": false,
    "lambda_access": false,
    "cloudformation_access": false,
    "data_exfiltration": false,
    "resource_manipulation": false,
    "cost_generation": false,
    "privilege_escalation_risk": false,
    "is_root_account": false
EOF
    fi
}

# Main analysis function
analyze_organization() {
    local org_name="$1"
    local secrets_dir="$2"
    
    log_info "Analyzing AWS credentials for organization: $org_name"
    
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
    
    # Extract AWS secrets from all files
    local aws_secrets
    aws_secrets=$(echo "$secrets_files" | while read -r file; do
        if [ -f "$file" ]; then
            # Extract secrets with DetectorName = "AWS"
            sed -n '/\"DetectorName\": \"AWS\"/,/^  },\{0,1\}$/p' "$file" 2>/dev/null || true
        fi
    done)
    
    if [ -z "$aws_secrets" ]; then
        log_info "No AWS secrets found for organization: $org_name"
        return 0
    fi
    
    # Count secrets
    local total_secrets
    total_secrets=$(echo "$aws_secrets" | grep -c '"DetectorName": "AWS"' || true)
    if [ -z "$total_secrets" ] || [ "$total_secrets" = "" ]; then
        total_secrets=0
    fi
    
    if [ "$total_secrets" -eq 0 ]; then
        log_info "No AWS secrets found for organization: $org_name"
        return 0
    fi
    
    log_info "Found $total_secrets AWS secret(s)"
    
    # Initialize output
    local output_file="$ANALYZED_RESULTS_DIR/${org_name}_analysis.json"
    local temp_secrets_file=$(mktemp)
    
    # Process each secret
    local secret_id=0
    local active_count=0
    local revoked_count=0
    local expired_count=0
    
    # Extract RawV2 values (contains both access key and secret)
    echo "$aws_secrets" | grep -oP '(?<="RawV2": ")[^"]+' | while read -r raw_v2; do
        secret_id=$((secret_id + 1))
        
        log_info "Verifying secret ${secret_id}/${total_secrets}..."
        
        # RawV2 format: <AccessKeyID>:<SecretAccessKey>
        local access_key secret_key
        if echo "$raw_v2" | grep -q ":"; then
            access_key=$(echo "$raw_v2" | cut -d':' -f1)
            secret_key=$(echo "$raw_v2" | cut -d':' -f2-)
        else
            # Fallback: old format <SecretAccessKey><AccessKeyID>
            # Access Key ID is last 20 chars, Secret Key is first 40 chars
            secret_key="${raw_v2:0:40}"
            access_key="${raw_v2:40}"
        fi
        
        # Extract metadata for this secret
        local secret_block
        secret_block=$(echo "$aws_secrets" | grep -A 30 "\"RawV2\": \"${raw_v2}\"" | head -20)
        
        local repo_url commit timestamp
        repo_url=$(echo "$secret_block" | grep -oP '(?<="repository_url": ")[^"]+' | head -1 || echo "unknown")
        commit=$(echo "$secret_block" | grep -oP '(?<="scanned_commit": ")[^"]+' | head -1 || echo "unknown")
        timestamp=$(echo "$secret_block" | grep -oP '(?<="scan_timestamp": ")[^"]+' | head -1 || echo "unknown")
        
        # Verify the credentials
        local verify_result
        verify_result=$(verify_aws_credentials "$access_key" "$secret_key")
        
        local status user_id account arn
        status=$(echo "$verify_result" | cut -d'|' -f1)
        
        if [ "$status" = "ACTIVE" ]; then
            user_id=$(echo "$verify_result" | cut -d'|' -f2)
            account=$(echo "$verify_result" | cut -d'|' -f3)
            arn=$(echo "$verify_result" | cut -d'|' -f4)
        else
            user_id="N/A"
            account="N/A"
            arn="N/A"
        fi
        
        # Calculate risk
        local risk_score
        risk_score=$(calculate_risk_score "$status" "$arn")
        local risk_level
        risk_level=$(get_risk_level "$risk_score")
        
        # Get capabilities
        local capabilities
        capabilities=$(get_capabilities "$status" "$arn")
        
        # Get key prefix for display
        local access_key_prefix="${access_key:0:8}..."
        
        log_info "Secret $secret_id: $status (Risk: $risk_level, Account: $account)" >&2
        
        # Build JSON for this secret
        cat >> "$temp_secrets_file" <<SECRETJSON
    {
      "secret_id": "aws_${secret_id}",
      "access_key_id": "${access_key_prefix}",
      "status": "${status}",
      "account_id": "${account}",
      "user_id": "${user_id}",
      "arn": "${arn}",
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
    
    # Read the counts from the temp file
    active_count=$(grep -c '"status": "ACTIVE"' "$temp_secrets_file" 2>/dev/null || true)
    if [ -z "$active_count" ] || [ "$active_count" = "" ]; then
        active_count=0
    fi
    
    revoked_count=$(grep -c '"status": "REVOKED"' "$temp_secrets_file" 2>/dev/null || true)
    if [ -z "$revoked_count" ] || [ "$revoked_count" = "" ]; then
        revoked_count=0
    fi
    
    expired_count=$(grep -c '"status": "EXPIRED"' "$temp_secrets_file" 2>/dev/null || true)
    if [ -z "$expired_count" ] || [ "$expired_count" = "" ]; then
        expired_count=0
    fi
    
    # Calculate percentage
    local active_percentage=0
    if [ "$total_secrets" -gt 0 ]; then
        active_percentage=$(awk "BEGIN {printf \"%.1f\", ($active_count * 100.0 / $total_secrets)}")
    fi
    
    # Build final JSON output
    cat > "$output_file" <<JSONSTART
{
  "organization": "${org_name}",
  "detector_type": "AWS",
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
    echo "    \"expired_keys\": $expired_count," >> "$output_file"
    echo "    \"active_percentage\": $active_percentage" >> "$output_file"
    echo "  }" >> "$output_file"
    echo "}" >> "$output_file"
    
    # Cleanup
    rm -f "$temp_secrets_file"
    
    log_success "Analysis complete for $org_name"
    log_info "Results saved to: $output_file"
    log_info "Summary: Total=$total_secrets, Active=$active_count ($active_percentage%), Revoked=$revoked_count, Expired=$expired_count"
    
    # Return summary for dashboard (to stdout only)
    echo "Total: $total_secrets, Active: $active_count ($active_percentage%), Revoked: $revoked_count, Expired: $expired_count"
}

# Analyze all organizations with AWS secrets
analyze_all_organizations() {
    local secrets_dir="$1"
    
    log_info "Scanning for organizations with AWS secrets..."
    
    # Find all unique organizations with AWS secrets
    local organizations
    organizations=$(find "$secrets_dir" -name "verified_secrets_*.json" -type f 2>/dev/null | while read -r file; do
        if grep -q '"DetectorName": "AWS"' "$file" 2>/dev/null; then
            basename "$file" | sed 's/verified_secrets_//' | sed 's/.json//'
        fi
    done | sort -u)
    
    if [ -z "$organizations" ]; then
        log_error "No organizations with AWS secrets found!"
        return 1
    fi
    
    local org_count
    org_count=$(echo "$organizations" | wc -l)
    log_info "Found $org_count organization(s) with AWS secrets"
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
    log_success "AWS Analysis Complete!"
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
    
    # Ensure AWS CLI is installed
    ensure_aws_cli || exit 1
    
    log_info "Starting AWS credentials analysis"
    
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
            log_success "AWS analysis completed successfully!"
        else
            log_error "AWS analysis failed with exit code: $exit_code"
        fi
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
