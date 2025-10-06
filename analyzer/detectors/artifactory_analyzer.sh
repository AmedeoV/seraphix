#!/bin/bash

################################################################################
# Artifactory Access Token Analyzer
# 
# Purpose: Verify Artifactory access tokens from TruffleHog scan results and
#          assess their security risk based on token validity and capabilities.
#
# Verification Method:
#   - Endpoint: https://{domain}.jfrog.io/artifactory/api/system/ping
#   - Header: X-JFrog-Art-Api: {token}
#   - Success: HTTP 200 with body containing "OK"
#
# Token Format:
#   - Prefix: "AKC" (Artifactory Access Token)
#   - Length: 65-73 characters
#   - RawV2: {token}{jfrog_domain}
#
# Risk Classification:
#   - ACTIVE tokens: CRITICAL (score 95) - Full artifact repository access
#   - REVOKED/INVALID tokens: LOW (score 5)
#
# Usage:
#   ./artifactory_analyzer.sh <org_name>
#
# Output: JSON files in analyzed_results/Artifactory/{org_name}_analysis.json
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$ANALYZER_DIR/analyzed_results/Artifactory"
LOG_FILE="$ANALYZER_DIR/artifactory_analyzer.log"
VERIFIED_SECRETS_DIR="$ANALYZER_DIR/../force-push-scanner/leaked_secrets_results"

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

################################################################################
# Logging Functions
################################################################################

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[INFO]${NC} $1"
    echo "[$timestamp] [INFO] $1" >> "$LOG_FILE"
}

log_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "[$timestamp] [SUCCESS] $1" >> "$LOG_FILE"
}

log_warning() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[$timestamp] [WARNING] $1" >> "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$timestamp] [ERROR] $1" >> "$LOG_FILE"
}

################################################################################
# Artifactory Token Verification
################################################################################

verify_artifactory_token() {
    local token="$1"
    local domain="$2"
    local repo_url="$3"
    local file="$4"
    local commit="$5"
    
    log_info "Verifying token for domain: $domain" >&2
    
    # Build API endpoint
    local api_url="https://${domain}/artifactory/api/system/ping"
    
    # Make API request with token
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "X-JFrog-Art-Api: $token" \
        -H "Accept: text/plain" \
        --max-time 10 \
        "$api_url" 2>&1 || echo -e "\n000")
    
    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    case "$http_code" in
        200)
            # Check if response contains "OK"
            if echo "$body" | grep -q "OK"; then
                log_success "Token ACTIVE for $domain" >&2
                echo "ACTIVE"
                return 0
            else
                log_warning "Token returned 200 but invalid response for $domain" >&2
                echo "INVALID"
                return 1
            fi
            ;;
        401|403)
            log_warning "Token REVOKED or FORBIDDEN for $domain" >&2
            echo "REVOKED"
            return 1
            ;;
        404)
            log_warning "API endpoint not found for $domain (possible invalid domain)" >&2
            echo "INVALID_DOMAIN"
            return 1
            ;;
        000)
            log_error "Connection failed for $domain (timeout or network error)" >&2
            echo "CONNECTION_FAILED"
            return 1
            ;;
        *)
            log_error "Unexpected HTTP $http_code for $domain" >&2
            echo "ERROR"
            return 1
            ;;
    esac
}

################################################################################
# Risk Classification
################################################################################

classify_risk() {
    local status="$1"
    local risk_score
    local risk_level
    local capabilities=()
    
    case "$status" in
        ACTIVE)
            risk_score=95
            risk_level="CRITICAL"
            capabilities=(
                "artifact_download=true"
                "artifact_upload=true"
                "repository_access=true"
                "dependency_poisoning=true"
                "supply_chain_attack=true"
                "build_artifact_manipulation=true"
                "ci_cd_compromise=true"
            )
            ;;
        REVOKED|INVALID|INVALID_DOMAIN|CONNECTION_FAILED|ERROR)
            risk_score=5
            risk_level="LOW"
            capabilities=()
            ;;
        *)
            risk_score=0
            risk_level="UNKNOWN"
            capabilities=()
            ;;
    esac
    
    # Build capabilities JSON
    local capabilities_json="{"
    local first=true
    for cap in "${capabilities[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            capabilities_json+=","
        fi
        local key="${cap%=*}"
        local value="${cap#*=}"
        capabilities_json+="\"$key\":$value"
    done
    capabilities_json+="}"
    
    echo "$risk_score|$risk_level|$capabilities_json"
}

################################################################################
# Parse RawV2 to Extract Token and Domain
################################################################################

parse_rawv2() {
    local rawv2="$1"
    
    # RawV2 format: {token}{domain}
    # Token starts with "AKC" and is 65-73 characters, contains mixed case
    # Domain is lowercase-only subdomain like "cardinalcommerceprod.jfrog.io"
    
    if ! echo "$rawv2" | grep -q "\.jfrog\.io"; then
        log_error "No .jfrog.io domain found in RawV2"
        return 1
    fi
    
    # Find where .jfrog.io starts
    local jfrog_part=$(echo "$rawv2" | grep -oE '\.jfrog\.io$')
    local before_jfrog="${rawv2%.jfrog.io}"
    
    # Now extract the subdomain (everything after the last non-lowercase character)
    # Walk backwards from end to find where lowercase-only section starts
    local subdomain=""
    local temp="$before_jfrog"
    
    # Remove one character at a time from start until we have only lowercase/digits/hyphens
    while [ -n "$temp" ]; do
        if echo "$temp" | grep -qE '^[a-z0-9\-]+$'; then
            subdomain="$temp"
            break
        fi
        # Remove first character
        temp="${temp:1}"
    done
    
    if [ -z "$subdomain" ]; then
        log_error "Failed to extract subdomain from RawV2"
        return 1
    fi
    
    local domain="${subdomain}.jfrog.io"
    
    # Additional cleanup: if domain starts with "pp" followed by more text, remove the "pp"
    # This handles tokens ending with lowercase letters like "...usJpp"
    if [[ "$domain" =~ ^pp[a-z] ]]; then
        domain="${domain:2}"  # Remove first 2 characters
    fi
    
    if [ -z "$domain" ]; then
        log_error "Failed to extract domain from RawV2"
        return 1
    fi
    
    # Extract token (everything before the domain)
    local token="${rawv2%$domain}"
    
    if [ -z "$token" ]; then
        log_error "Failed to extract token from RawV2"
        return 1
    fi
    
    # Validate token format (should start with AKC)
    if ! echo "$token" | grep -qE '^AKC'; then
        log_warning "Token does not start with 'AKC' prefix: ${token:0:10}..."
        # Still proceed as some tokens might be valid
    fi
    
    echo "$token|$domain"
}

################################################################################
# Process Artifactory Secrets for Organization
################################################################################

process_org_secrets() {
    local org_name="$1"
    local output_file="$RESULTS_DIR/${org_name}_analysis.json"
    
    log_info "Processing Artifactory secrets for organization: $org_name"
    
    # Find ALL verified secrets files across all scanners (force-push, org-scanner, repo-scanner)
    # This ensures we capture secrets from all sources
    local secrets_files=$(find "$VERIFIED_SECRETS_DIR" -type f -name "verified_secrets_${org_name}.json" 2>/dev/null || true)
    
    if [ -z "$secrets_files" ]; then
        log_warning "No verified secrets file found for $org_name"
        return 1
    fi
    
    log_info "Found $(echo "$secrets_files" | wc -l) file(s) for $org_name"
    
    # Extract all Artifactory secrets
    local secrets_count=0
    local active_count=0
    local revoked_count=0
    
    # Start building JSON output
    local json_output='{'
    json_output+="\"organization\":\"$org_name\","
    json_output+="\"detector_type\":\"Artifactory\","
    json_output+="\"scan_timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    json_output+="\"secrets\":["
    
    local first_secret=true
    
    # Process each secrets file
    while IFS= read -r secrets_file; do
        log_info "Processing file: $(basename "$secrets_file")"
        
        # Check if jq is available for proper JSON parsing
        if ! command -v jq &> /dev/null; then
            log_error "jq is required for parsing JSON files. Please install jq."
            return 1
        fi
        
        # Extract Artifactory secrets using grep with context
        local artifactory_count=$(grep -c '"DetectorName".*"ArtifactoryAccessToken"' "$secrets_file" || echo "0")
        
        if [ "$artifactory_count" -eq 0 ]; then
            log_info "No Artifactory secrets found in $(basename "$secrets_file")"
            continue
        fi
        
        log_info "Found $artifactory_count Artifactory secret(s) in file"
        
        # Extract each Artifactory secret block  
        local line_nums=$(grep -n '"DetectorName".*"ArtifactoryAccessToken"' "$secrets_file" | cut -d: -f1)
        
        while IFS= read -r line_num; do
            if [ -z "$line_num" ]; then
                continue
            fi
            
            secrets_count=$((secrets_count + 1))
            
            log_info "Processing Artifactory secret #$secrets_count"
            
            # Extract a window of lines around this secret (30 lines should be enough for one secret)
            local secret_block=$(sed -n "$((line_num-5)),$((line_num+25))p" "$secrets_file")
            
            # Extract fields using grep -oP (Perl regex)
            local rawv2=$(echo "$secret_block" | grep -oP '"RawV2"\s*:\s*"\K[^"]+' | head -n1)
            local raw=$(echo "$secret_block" | grep -oP '"Raw"\s*:\s*"\K[^"]+' | head -n1)
            local repo_url=$(echo "$secret_block" | grep -oP '"repository_url"\s*:\s*"\K[^"]+' | head -n1)
            local file=$(echo "$secret_block" | grep -oP '"file"\s*:\s*"\K[^"]+' | head -n1)
            local commit=$(echo "$secret_block" | grep -oP '"commit"\s*:\s*"\K[^"]+' | head -n1)
            
            if [ -z "$rawv2" ]; then
                log_warning "RawV2 field missing for secret #$secrets_count, skipping"
                continue
            fi
            
            # Parse RawV2 to extract token and domain
            local parse_result=$(parse_rawv2 "$rawv2")
            
            if [ $? -eq 0 ]; then
                local token="${parse_result%|*}"
                local domain="${parse_result#*|}"
                
                log_info "  Domain: $domain"
                log_info "  Token: ${token:0:15}...${token: -5}"
                
                # Verify the token
                local status=$(verify_artifactory_token "$token" "$domain" "$repo_url" "$file" "$commit")
                
                # Classify risk
                local risk_data=$(classify_risk "$status")
                local risk_score="${risk_data%%|*}"
                risk_data="${risk_data#*|}"
                local risk_level="${risk_data%%|*}"
                local capabilities="${risk_data#*|}"
                
                # Update counters
                if [ "$status" = "ACTIVE" ]; then
                    active_count=$((active_count + 1))
                else
                    revoked_count=$((revoked_count + 1))
                fi
                
                # Add to JSON output
                if [ "$first_secret" = false ]; then
                    json_output+=","
                fi
                first_secret=false
                
                json_output+='{'
                json_output+="\"secret_id\":\"artifactory_${secrets_count}\","
                json_output+="\"domain\":\"$domain\","
                json_output+="\"token_prefix\":\"${token:0:15}...\","
                json_output+="\"status\":\"$status\","
                json_output+="\"risk_score\":$risk_score,"
                json_output+="\"risk_level\":\"$risk_level\","
                json_output+="\"capabilities\":$capabilities,"
                json_output+="\"repository_url\":\"$repo_url\","
                json_output+="\"file\":\"$file\","
                json_output+="\"commit\":\"$commit\","
                json_output+="\"verified_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
                json_output+='}'
                
                log_success "Token ${token:0:10}...: $status (Risk: $risk_level)"
            else
                log_error "Failed to parse RawV2 for secret #$secrets_count"
            fi
            
        done <<< "$line_nums"
        
    done <<< "$secrets_files"
    
    # Complete JSON output
    json_output+="],"
    json_output+="\"summary\":{"
    json_output+="\"total_secrets\":$secrets_count,"
    json_output+="\"active_tokens\":$active_count,"
    json_output+="\"revoked_tokens\":$revoked_count,"
    
    if [ $secrets_count -gt 0 ]; then
        local active_percentage=$((active_count * 100 / secrets_count))
        json_output+="\"active_percentage\":$active_percentage"
    else
        json_output+="\"active_percentage\":0"
    fi
    
    json_output+="}}"
    
    # Save to file
    echo "$json_output" | jq '.' > "$output_file" 2>/dev/null || echo "$json_output" > "$output_file"
    
    log_success "Analysis complete for $org_name"
    log_info "Results saved to: $output_file"
    log_info "Total secrets: $secrets_count"
    log_info "Active: $active_count (${GREEN}$([ $secrets_count -gt 0 ] && echo $((active_count * 100 / secrets_count)) || echo 0)%${NC})"
    log_info "Revoked: $revoked_count"
    
    return 0
}

################################################################################
# Main Execution
################################################################################

main() {
    echo -e "${BOLD}${MAGENTA}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║        Artifactory Access Token Security Analyzer             ║"
    echo "║                    Powered by TruffleHog                       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check arguments
    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 <org_name>${NC}"
        echo ""
        echo "Example: $0 braintree"
        exit 1
    fi
    
    local org_name="$1"
    
    log_info "Starting Artifactory token analysis"
    log_info "Organization: $org_name"
    log_info "Timestamp: $(date)"
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        log_warning "jq not installed. JSON output will not be formatted."
    fi
    
    # Process organization secrets
    if process_org_secrets "$org_name"; then
        echo ""
        echo -e "${GREEN}${BOLD}✓ Analysis completed successfully${NC}"
        echo ""
        
        # Display summary from JSON file
        local output_file="$RESULTS_DIR/${org_name}_analysis.json"
        if [ -f "$output_file" ]; then
            echo -e "${CYAN}Summary for $org_name:${NC}"
            
            if command -v jq &> /dev/null; then
                local total=$(jq -r '.summary.total_secrets' "$output_file")
                local active=$(jq -r '.summary.active_tokens' "$output_file")
                local revoked=$(jq -r '.summary.revoked_tokens' "$output_file")
                local percentage=$(jq -r '.summary.active_percentage' "$output_file")
                
                echo -e "  ${BOLD}Total Tokens:${NC} $total"
                echo -e "  ${GREEN}Active:${NC} $active ($percentage%)"
                echo -e "  ${YELLOW}Revoked:${NC} $revoked"
            fi
        fi
        
        exit 0
    else
        echo ""
        echo -e "${RED}${BOLD}✗ Analysis failed${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
