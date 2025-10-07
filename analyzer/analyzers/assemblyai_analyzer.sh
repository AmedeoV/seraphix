#!/bin/bash

# AssemblyAI API Key Analyzer
# Verifies leaked AssemblyAI API keys and assesses their security risk
# 
# AssemblyAI is a speech-to-text transcription service that provides
# powerful AI models for audio transcription, speaker diarization, and more.
#
# Active keys grant access to:
# - Transcription services (audio/video to text)
# - Real-time streaming transcription
# - Audio intelligence features (sentiment, entity detection)
# - Account usage and billing information
# - Stored transcripts and audio files
#
# Verification Method: GET /v2/transcript endpoint
# API Reference: https://www.assemblyai.com/docs/api-reference/transcript#get-transcripts

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$(dirname "$SCRIPT_DIR")"
ANALYZED_RESULTS_DIR="$ANALYZER_DIR/analyzed_results/AssemblyAI"
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

# Verify AssemblyAI API key
# Returns: "ACTIVE", "REVOKED", or "ERROR"
verify_assemblyai_key() {
    local api_key="$1"
    
    # AssemblyAI API endpoint for listing transcripts
    local endpoint="https://api.assemblyai.com/v2/transcript"
    
    # Make API request
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: ${api_key}" \
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

# Calculate risk score based on key status
calculate_risk_score() {
    local status="$1"
    
    case "$status" in
        "ACTIVE")
            echo 95  # CRITICAL - Active transcription API access
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
    
    if [ "$status" = "ACTIVE" ]; then
        cat <<EOF
    "audio_transcription": true,
    "real_time_transcription": true,
    "speaker_diarization": true,
    "audio_intelligence": true,
    "sentiment_analysis": true,
    "entity_detection": true,
    "content_moderation": true,
    "account_access": true,
    "billing_information": true,
    "stored_transcripts_access": true
EOF
    else
        cat <<EOF
    "audio_transcription": false,
    "real_time_transcription": false,
    "speaker_diarization": false,
    "audio_intelligence": false,
    "sentiment_analysis": false,
    "entity_detection": false,
    "content_moderation": false,
    "account_access": false,
    "billing_information": false,
    "stored_transcripts_access": false
EOF
    fi
}

# Main analysis function
analyze_organization() {
    local org_name="$1"
    local secrets_dir="$2"
    
    log_info "Analyzing AssemblyAI keys for organization: $org_name"
    
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
    
    # Extract AssemblyAI secrets from all files
    local assemblyai_secrets
    assemblyai_secrets=$(echo "$secrets_files" | while read -r file; do
        if [ -f "$file" ]; then
            # Extract secrets with DetectorName = "AssemblyAI"
            # Use sed to extract the relevant JSON blocks
            sed -n '/\"DetectorName\": \"AssemblyAI\"/,/^  },\{0,1\}$/p' "$file" 2>/dev/null || true
        fi
    done)
    
    if [ -z "$assemblyai_secrets" ]; then
        log_info "No AssemblyAI secrets found for organization: $org_name"
        return 0
    fi
    
    # Count secrets
    local total_secrets
    total_secrets=$(echo "$assemblyai_secrets" | grep -c '"DetectorName": "AssemblyAI"' || echo "0")
    
    if [ "$total_secrets" -eq 0 ]; then
        log_info "No AssemblyAI secrets found for organization: $org_name"
        return 0
    fi
    
    log_info "Found $total_secrets AssemblyAI secret(s)"
    
    # Initialize output JSON
    local output_file="$ANALYZED_RESULTS_DIR/${org_name}_analysis.json"
    local temp_secrets_file=$(mktemp)
    
    # Process each secret
    local secret_id=0
    local active_count=0
    local revoked_count=0
    
    echo "$assemblyai_secrets" | grep -oP '(?<="Raw": ")[^"]+' | while read -r api_key; do
        secret_id=$((secret_id + 1))
        
        log_info "Verifying secret ${secret_id}/${total_secrets}..."
        
        # Extract metadata for this secret
        local repo_url
        local commit
        local timestamp
        
        # Use grep to find the secret block
        local secret_block
        secret_block=$(echo "$assemblyai_secrets" | grep -A 30 "\"Raw\": \"${api_key}\"" | head -20)
        
        repo_url=$(echo "$secret_block" | grep -oP '(?<="repository_url": ")[^"]+' | head -1 || echo "unknown")
        commit=$(echo "$secret_block" | grep -oP '(?<="scanned_commit": ")[^"]+' | head -1 || echo "unknown")
        timestamp=$(echo "$secret_block" | grep -oP '(?<="scan_timestamp": ")[^"]+' | head -1 || echo "unknown")
        
        # Verify the key
        local status
        status=$(verify_assemblyai_key "$api_key")
        
        # Calculate risk
        local risk_score
        risk_score=$(calculate_risk_score "$status")
        local risk_level
        risk_level=$(get_risk_level "$risk_score")
        
        # Get capabilities
        local capabilities
        capabilities=$(get_capabilities "$status")
        
        # Track counts
        if [ "$status" = "ACTIVE" ]; then
            active_count=$((active_count + 1))
        elif [ "$status" = "REVOKED" ]; then
            revoked_count=$((revoked_count + 1))
        fi
        
        # Get first 8 chars as prefix
        local key_prefix="${api_key:0:8}..."
        
        log_info "Secret $secret_id: $status (Risk: $risk_level)" >&2
        
        # Build JSON for this secret
        cat >> "$temp_secrets_file" <<SECRETJSON
    {
      "secret_id": "assemblyai_${secret_id}",
      "api_key_prefix": "${key_prefix}",
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
    active_count=$(grep -c '"status": "ACTIVE"' "$temp_secrets_file" 2>/dev/null || true)
    if [ -z "$active_count" ] || [ "$active_count" = "" ]; then
        active_count=0
    fi
    
    revoked_count=$(grep -c '"status": "REVOKED"' "$temp_secrets_file" 2>/dev/null || true)
    if [ -z "$revoked_count" ] || [ "$revoked_count" = "" ]; then
        revoked_count=0
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
  "detector_type": "AssemblyAI",
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
    echo "    \"active_percentage\": $active_percentage" >> "$output_file"
    echo "  }" >> "$output_file"
    echo "}" >> "$output_file"
    
    # Cleanup
    rm -f "$temp_secrets_file"
    
    log_success "Analysis complete for $org_name"
    log_info "Results saved to: $output_file"
    log_info "Summary: Total=$total_secrets, Active=$active_count ($active_percentage%), Revoked=$revoked_count"
    
    # Return summary for dashboard (to stdout only)
    echo "Total: $total_secrets, Active: $active_count ($active_percentage%), Revoked: $revoked_count"
}

# Analyze all organizations with AssemblyAI secrets
analyze_all_organizations() {
    local secrets_dir="$1"
    
    log_info "Scanning for organizations with AssemblyAI secrets..."
    
    # Find all unique organizations with AssemblyAI secrets
    local organizations
    organizations=$(find "$secrets_dir" -name "verified_secrets_*.json" -type f 2>/dev/null | while read -r file; do
        if grep -q '"DetectorName": "AssemblyAI"' "$file" 2>/dev/null; then
            basename "$file" | sed 's/verified_secrets_//' | sed 's/.json//'
        fi
    done | sort -u)
    
    if [ -z "$organizations" ]; then
        log_error "No organizations with AssemblyAI secrets found!"
        return 1
    fi
    
    local org_count
    org_count=$(echo "$organizations" | wc -l)
    log_info "Found $org_count organization(s) with AssemblyAI secrets"
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
    log_success "AssemblyAI Analysis Complete!"
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
    
    log_info "Starting AssemblyAI key analysis"
    
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
            log_success "AssemblyAI analysis completed successfully!"
        else
            log_error "AssemblyAI analysis failed with exit code: $exit_code"
        fi
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
