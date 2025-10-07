#!/bin/bash

# Run all detector analyzers with --all flag
# This will analyze all organizations for each detector type
# Supports parallel execution based on available CPU cores
#
# Usage:
#   bash run_all_analyzers.sh              # Parallel mode (default)
#   bash run_all_analyzers.sh --sequential # Sequential mode (slower, better for debugging)
#
# Parallel mode will automatically detect CPU cores and use 75% for processing
# Each analyzer has a 5-minute timeoutecho "================================================"
echo "📊 Analysis Summary:"
echo "   Total analyzers: $total"
echo "   Completed: $success"
echo "   Skipped: $skipped"
echo "================================================"
echo ""
echo "✅ All analyzers have been executed!"
echo ""

# Post-processing: Deduplicate analysis results
echo "🧹 Post-processing: Deduplicating analysis results..."
cd "$ANALYZER_DIR"

# Python code for deduplicating analysis results (embedded)
python3 - <<'PYTHON_POSTPROCESS'
import json
import hashlib
import sys
from pathlib import Path

def hash_secret(raw_secret):
    """Generate a hash for a secret"""
    return hashlib.sha256(raw_secret.encode()).hexdigest()[:16]

def deduplicate_analysis_file(file_path):
    """Deduplicate secrets in a single analysis JSON file"""
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
        
        if 'secrets' not in data or not isinstance(data['secrets'], list):
            return 0, 0
        
        original_count = len(data['secrets'])
        seen_hashes = set()
        unique_secrets = []
        
        for secret in data['secrets']:
            raw_secret = secret.get('raw_secret', '')
            if not raw_secret:
                unique_secrets.append(secret)
                continue
            
            secret_hash = hash_secret(raw_secret)
            
            if secret_hash not in seen_hashes:
                seen_hashes.add(secret_hash)
                unique_secrets.append(secret)
        
        duplicates_removed = original_count - len(unique_secrets)
        
        if duplicates_removed > 0:
            data['secrets'] = unique_secrets
            
            # Update summary if it exists
            if 'summary' in data:
                data['summary']['total_secrets'] = len(unique_secrets)
                
                active = sum(1 for s in unique_secrets if s.get('status') == 'ACTIVE')
                revoked = sum(1 for s in unique_secrets if s.get('status') == 'REVOKED')
                
                data['summary']['active_keys'] = active
                data['summary']['revoked_keys'] = revoked
                
                if len(unique_secrets) > 0:
                    data['summary']['active_percentage'] = round((active * 100.0) / len(unique_secrets), 1)
                else:
                    data['summary']['active_percentage'] = 0.0
            
            # Add deduplication metadata
            if 'deduplication' not in data:
                data['deduplication'] = {}
            data['deduplication']['duplicates_removed'] = duplicates_removed
            data['deduplication']['original_count'] = original_count
            data['deduplication']['unique_count'] = len(unique_secrets)
            
            with open(file_path, 'w') as f:
                json.dump(data, f, indent=2)
        
        return original_count, duplicates_removed
        
    except Exception as e:
        return 0, 0

def main():
    script_dir = Path.cwd()
    results_dir = script_dir / "analyzed_results"
    
    if not results_dir.exists():
        print("   ⚠️  analyzed_results directory not found")
        return
    
    total_files = 0
    total_secrets_before = 0
    total_duplicates = 0
    files_with_duplicates = 0
    
    for detector_dir in sorted(results_dir.iterdir()):
        if not detector_dir.is_dir():
            continue
        
        for analysis_file in detector_dir.glob("*_analysis.json"):
            total_files += 1
            original, duplicates = deduplicate_analysis_file(analysis_file)
            
            total_secrets_before += original
            total_duplicates += duplicates
            
            if duplicates > 0:
                files_with_duplicates += 1
                org_name = analysis_file.stem.replace('_analysis', '')
                print(f"   🔄 {detector_dir.name}/{org_name}: Removed {duplicates} from {original}")
    
    print("")
    print("=" * 70)
    print("📊 Deduplication Summary:")
    print(f"   Files processed: {total_files}")
    print(f"   Files with duplicates: {files_with_duplicates}")
    print(f"   Total secrets before: {total_secrets_before}")
    print(f"   Duplicates removed: {total_duplicates}")
    print(f"   Total secrets after: {total_secrets_before - total_duplicates}")
    
    if total_duplicates > 0:
        reduction = (total_duplicates * 100.0) / total_secrets_before if total_secrets_before > 0 else 0
        print(f"   Reduction: {reduction:.1f}%")
    
    print("=" * 70)
    print("")

if __name__ == '__main__':
    main()
PYTHON_POSTPROCESS

echo "💡 Next steps:"
echo "   1. Regenerate the dashboard: bash generate_dashboard.sh all"
echo "   2. View results in: analyzer/visualizations/dashboard.html"hanging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER_DIR="$SCRIPT_DIR"
DETECTORS_DIR="$ANALYZER_DIR/detectors"

# Detect CPU cores for parallel processing
if command -v nproc >/dev/null 2>&1; then
    NUM_CORES=$(nproc)
elif [ -f /proc/cpuinfo ]; then
    NUM_CORES=$(grep -c ^processor /proc/cpuinfo)
else
    NUM_CORES=4  # Default fallback
fi

# Use 75% of cores to avoid system overload
PARALLEL_JOBS=$(( NUM_CORES * 3 / 4 ))
[ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1

# Check for parallel mode flag
PARALLEL_MODE=true
if [ "$1" = "--sequential" ]; then
    PARALLEL_MODE=false
    shift
fi

cd "$DETECTORS_DIR"

# Pre-processing: Fix incomplete JSON files and deduplicate
echo "🔧 Pre-processing: Fixing and deduplicating analysis results..."
echo ""

# Python code for fixing JSON and deduplication (embedded)
python3 - <<'PYTHON_PREPROCESS'
import json
import hashlib
import sys
from pathlib import Path

def hash_secret(raw_secret):
    """Generate hash of raw secret for deduplication."""
    return hashlib.sha256(raw_secret.encode()).hexdigest()[:16]

def count_brackets(content):
    """Count open and close brackets in content."""
    open_square = content.count('[')
    close_square = content.count(']')
    open_curly = content.count('{')
    close_curly = content.count('}')
    return open_square, close_square, open_curly, close_curly

def fix_json_file(file_path):
    """
    Attempt to fix an incomplete JSON file by adding missing closing brackets.
    Returns (was_fixed, error_message)
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Try to parse as-is
        try:
            json.loads(content)
            return False, None  # File is already valid
        except json.JSONDecodeError:
            pass  # File needs fixing
        
        # Count brackets
        open_sq, close_sq, open_cu, close_cu = count_brackets(content)
        
        # Calculate missing brackets
        missing_square = open_sq - close_sq
        missing_curly = open_cu - close_cu
        
        if missing_square <= 0 and missing_curly <= 0:
            return False, "No missing brackets found"
        
        # Add missing brackets
        fixed_content = content.rstrip()
        fixed_content += '}' * missing_curly
        fixed_content += ']' * missing_square
        
        # Verify the fix works
        try:
            json.loads(fixed_content)
            
            # Write back the fixed content
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(fixed_content)
            
            return True, f"Added {missing_curly} '}}' and {missing_square} ']'"
        except json.JSONDecodeError as e:
            return False, f"Could not fix: {str(e)}"
            
    except Exception as e:
        return False, f"Error: {str(e)}"

def deduplicate_secrets_file(file_path):
    """Deduplicate secrets in a single verified_secrets JSON file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read().strip()
        
        # Skip empty files or empty arrays
        if not content or content == '[]' or content == '[\n]':
            return 0, 0
        
        secrets = json.loads(content)
        
        if not secrets or not isinstance(secrets, list):
            return 0, 0
        
        original_count = len(secrets)
        seen_hashes = set()
        deduped_secrets = []
        
        for secret in secrets:
            if not isinstance(secret, dict):
                continue
            
            raw_secret = secret.get('Raw', '')
            if not raw_secret:
                deduped_secrets.append(secret)
                continue
            
            secret_hash = hash_secret(raw_secret)
            
            if secret_hash not in seen_hashes:
                seen_hashes.add(secret_hash)
                deduped_secrets.append(secret)
        
        duplicates_removed = original_count - len(deduped_secrets)
        
        if duplicates_removed > 0:
            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(deduped_secrets, f, indent=2, ensure_ascii=False)
            return original_count, duplicates_removed
        
        return original_count, 0
        
    except json.JSONDecodeError:
        return 0, 0
    except Exception as e:
        return 0, 0

def main():
    # Get the base project directory
    try:
        script_dir = Path.cwd()
        if script_dir.name == 'detectors':
            base_dir = script_dir.parent.parent
        elif script_dir.name == 'analyzer':
            base_dir = script_dir.parent
        else:
            base_dir = script_dir
    except:
        base_dir = Path.cwd()
    
    # Step 1: Fix incomplete JSON files in analyzed_results
    print("   🔧 Step 1: Fixing incomplete JSON files...")
    analyzed_results_dir = base_dir / 'analyzer' / 'analyzed_results'
    
    if analyzed_results_dir.exists():
        analysis_json_files = list(analyzed_results_dir.rglob('*_analysis.json'))
        fixed_count = 0
        
        for json_file in analysis_json_files:
            was_fixed, message = fix_json_file(json_file)
            if was_fixed:
                fixed_count += 1
                print(f"      ✅ Fixed: {json_file.name} ({message})")
        
        if fixed_count > 0:
            print(f"      Total analysis files fixed: {fixed_count}")
        else:
            print(f"      All {len(analysis_json_files)} analysis files are valid")
    else:
        print("      ⚠️  analyzed_results directory not found")
    
    print("")
    
    # Step 2: Deduplicate raw secrets
    print("   🧹 Step 2: Deduplicating raw secrets...")
    
    results_dirs = []
    for potential_dir in [
        base_dir / 'org-scanner' / 'leaked_secrets_results',
        base_dir / 'force-push-scanner' / 'leaked_secrets_results',
        base_dir / 'repo-scanner' / 'leaked_secrets_results',
    ]:
        if potential_dir.exists():
            results_dirs.append(potential_dir)
    
    if not results_dirs:
        print("      ⚠️  No leaked_secrets_results directories found")
        return
    
    total_files = 0
    files_with_duplicates = 0
    total_secrets_before = 0
    total_duplicates_removed = 0
    
    for results_dir in results_dirs:
        json_files = list(results_dir.rglob('verified_secrets_*.json'))
        
        for file_path in json_files:
            total_files += 1
            original_count, duplicates_removed = deduplicate_secrets_file(file_path)
            
            if original_count > 0:
                total_secrets_before += original_count
                
            if duplicates_removed > 0:
                files_with_duplicates += 1
                total_duplicates_removed += duplicates_removed
    
    total_secrets_after = total_secrets_before - total_duplicates_removed
    reduction_pct = (total_duplicates_removed / total_secrets_before * 100) if total_secrets_before > 0 else 0
    
    if total_duplicates_removed > 0:
        print(f"      ✅ Files processed: {total_files}")
        print(f"      🔄 Files with duplicates: {files_with_duplicates}")
        print(f"      📊 Secrets before: {total_secrets_before}")
        print(f"      🗑️  Duplicates removed: {total_duplicates_removed}")
        print(f"      ✨ Secrets after: {total_secrets_after}")
        print(f"      📉 Reduction: {reduction_pct:.1f}%")
        print(f"      ⚡ Time saved: ~{total_duplicates_removed * 2}s")
    else:
        print(f"      ✅ All {total_files} secret files already deduplicated")
    
    print("")

if __name__ == '__main__':
    main()
PYTHON_PREPROCESS

echo "🔍 Running all detector analyzers..."
if [ "$PARALLEL_MODE" = true ] && [ "$PARALLEL_JOBS" -gt 1 ]; then
    echo "🚀 Parallel mode: Using $PARALLEL_JOBS cores (of $NUM_CORES available)"
else
    echo "📝 Sequential mode: Running one at a time"
fi
echo ""

analyzers=(
    "discordwebhook"
    "disqus"
    "docker"
    "elevenlabs"
    "etherscan"
    "flickr"
    "ftp"
    "gcp"
    "githuboauth2"
    "grafana"
    "huggingface"
    # "infura"
    "langsmith"
    "launchdarkly"
    "magicbell"
    "mailgun"
    "mongodb"
    "netlify"
    "notion"
    "npmtoken"
    "openweather"
    "pastebin"
    "paystack"
    "phraseaccesstoken"
    "pinata"
    "polygon"
    "postgres"
    "privatekey"
    "rabbitmq"
    "saucelabs"
    "scrapingant"
    "sendgrid"
    "slackwebhook"
    "smartsheets"
    "sonarcloud"
    "sqlserver"
    "telegrambottoken"
    "twilio"
    "twitterconsumerkey"
    "unsplash"
    "uri"
    "vercel"
)

total=${#analyzers[@]}
current=0
success=0
skipped=0

# Create logs directory
mkdir -p "$ANALYZER_DIR/logs"

# Function to run a single analyzer (for parallel execution)
run_analyzer() {
    local analyzer="$1"
    local script="${analyzer}_analyzer.sh"
    local log_file="$ANALYZER_DIR/logs/${analyzer}_$(date +%Y%m%d_%H%M%S).log"
    local timeout_seconds=300  # 5 minute timeout per analyzer
    
    if [ ! -f "$script" ]; then
        echo "SKIPPED|$analyzer|Script not found" > "$log_file.status"
        return 1
    fi
    
    # Fix line endings (CRLF -> LF) before running
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$script" 2>/dev/null
    else
        sed -i 's/\r$//' "$script" 2>/dev/null || true
    fi
    
    # Run the analyzer with timeout
    if command -v timeout >/dev/null 2>&1; then
        # Use timeout command if available
        if timeout "$timeout_seconds" bash "$script" --all > "$log_file" 2>&1; then
            echo "SUCCESS|$analyzer|$log_file" > "$log_file.status"
            return 0
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                echo "TIMEOUT|$analyzer|$log_file|Exceeded ${timeout_seconds}s" > "$log_file.status"
                echo "[TIMEOUT] Analyzer exceeded ${timeout_seconds}s time limit" >> "$log_file"
            else
                echo "WARNING|$analyzer|$log_file|$exit_code" > "$log_file.status"
            fi
            return 0  # Still count as completed
        fi
    else
        # Fallback without timeout
        if bash "$script" --all > "$log_file" 2>&1; then
            echo "SUCCESS|$analyzer|$log_file" > "$log_file.status"
            return 0
        else
            local exit_code=$?
            echo "WARNING|$analyzer|$log_file|$exit_code" > "$log_file.status"
            return 0  # Still count as completed
        fi
    fi
}

export -f run_analyzer
export ANALYZER_DIR
export DETECTORS_DIR

# Run analyzers based on mode
if [ "$PARALLEL_MODE" = true ] && [ "$PARALLEL_JOBS" -gt 1 ]; then
    # Parallel execution
    echo "⏳ Starting parallel execution..."
    echo ""
    
    # Use xargs or GNU parallel for parallel execution
    if command -v parallel >/dev/null 2>&1; then
        # GNU parallel (better progress tracking)
        printf "%s\n" "${analyzers[@]}" | parallel -j "$PARALLEL_JOBS" --bar run_analyzer {}
    else
        # xargs fallback
        printf "%s\n" "${analyzers[@]}" | xargs -P "$PARALLEL_JOBS" -I {} bash -c "run_analyzer '{}'"
    fi
    
    echo ""
    echo "✅ Parallel execution completed!"
    echo ""
    
    # Process results from status files
    for analyzer in "${analyzers[@]}"; do
        current=$((current + 1))
        status_files=("$ANALYZER_DIR/logs/${analyzer}"_*.log.status)
        
        if [ ! -f "${status_files[0]}" ]; then
            echo "⏭️  [$current/$total] $analyzer - No status file found"
            skipped=$((skipped + 1))
            continue
        fi
        
        # Read the most recent status file
        status_file="${status_files[-1]}"
        IFS='|' read -r status name log_path exit_code < "$status_file"
        
        case "$status" in
            SUCCESS)
                echo "✅ [$current/$total] $analyzer completed successfully"
                success=$((success + 1))
                ;;
            TIMEOUT)
                echo "⏱️  [$current/$total] $analyzer TIMEOUT: $exit_code"
                echo "    Log: $log_path"
                if [ -f "$log_path" ]; then
                    echo "    Last 5 lines:"
                    tail -5 "$log_path" | sed 's/^/      /'
                fi
                success=$((success + 1))
                ;;
            WARNING)
                echo "⚠️  [$current/$total] $analyzer completed with warnings/errors (exit code: $exit_code)"
                echo "    Log: $log_path"
                if [ -f "$log_path" ]; then
                    echo "    Last 3 lines:"
                    tail -3 "$log_path" | sed 's/^/      /'
                fi
                success=$((success + 1))
                ;;
            SKIPPED)
                echo "⏭️  [$current/$total] $analyzer - $log_path"
                skipped=$((skipped + 1))
                ;;
        esac
        
        # Clean up status file
        rm -f "$status_file"
    done
    
else
    # Sequential execution (original behavior)
    for analyzer in "${analyzers[@]}"; do
        current=$((current + 1))
        script="${analyzer}_analyzer.sh"
        
        if [ ! -f "$script" ]; then
            echo "⏭️  [$current/$total] Skipping $analyzer (script not found)"
            skipped=$((skipped + 1))
            continue
        fi
        
        echo "🔄 [$current/$total] Running $analyzer analyzer..."
        
        # Fix line endings (CRLF -> LF) before running
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix "$script" 2>/dev/null
        else
            sed -i 's/\r$//' "$script" 2>/dev/null || true
        fi
        
        # Create log file for this analyzer
        log_file="$ANALYZER_DIR/logs/${analyzer}_$(date +%Y%m%d_%H%M%S).log"
        
        if bash "$script" --all > "$log_file" 2>&1; then
            echo "✅ [$current/$total] $analyzer completed successfully"
            success=$((success + 1))
        else
            exit_code=$?
            echo "⚠️  [$current/$total] $analyzer completed with warnings/errors (exit code: $exit_code)"
            echo "    Log: $log_file"
            # Show last few lines of the log for quick debugging
            if [ -f "$log_file" ]; then
                echo "    Last 3 lines:"
                tail -3 "$log_file" | sed 's/^/      /'
            fi
            success=$((success + 1))
        fi
        echo ""
    done
fi

echo "================================================"
echo "📊 Analysis Summary:"
echo "   Total analyzers: $total"
echo "   Completed: $success"
echo "   Skipped: $skipped"
echo "================================================"
echo ""
echo "✅ All analyzers have been executed!"
echo ""
echo "� Next steps:"
echo "   1. Regenerate the dashboard: bash generate_dashboard.sh all"
echo "   2. View results in: analyzer/visualizations/dashboard.html"

