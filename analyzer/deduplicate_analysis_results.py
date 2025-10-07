#!/usr/bin/env python3
"""
Deduplicate Analysis Results
Removes duplicate secrets from analyzer output files based on raw secret value
This runs AFTER all analyzers complete to clean up the results
"""

import os
import json
import hashlib
from pathlib import Path
from collections import defaultdict

def hash_secret(raw_secret):
    """Generate a hash for a secret"""
    return hashlib.sha256(raw_secret.encode()).hexdigest()[:16]

def deduplicate_analysis_file(file_path):
    """Deduplicate secrets in a single analysis JSON file"""
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
        
        if 'secrets' not in data or not isinstance(data['secrets'], list):
            return 0, 0  # No secrets to deduplicate
        
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
            # Update the data
            data['secrets'] = unique_secrets
            
            # Update summary if it exists
            if 'summary' in data:
                data['summary']['total_secrets'] = len(unique_secrets)
                
                # Recalculate active/revoked counts
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
            
            # Write back
            with open(file_path, 'w') as f:
                json.dump(data, f, indent=2)
        
        return original_count, duplicates_removed
        
    except Exception as e:
        print(f"❌ Error processing {file_path}: {e}")
        return 0, 0

def main():
    """Main process"""
    print("🧹 Deduplicating analysis results...")
    print()
    
    # Find the analyzed_results directory
    script_dir = Path(__file__).parent
    results_dir = script_dir / "analyzed_results"
    
    if not results_dir.exists():
        print(f"❌ Results directory not found: {results_dir}")
        return 1
    
    # Statistics
    total_files = 0
    total_secrets_before = 0
    total_duplicates = 0
    files_with_duplicates = 0
    
    # Process each detector directory
    for detector_dir in sorted(results_dir.iterdir()):
        if not detector_dir.is_dir():
            continue
        
        # Process each analysis file in the detector directory
        for analysis_file in detector_dir.glob("*_analysis.json"):
            total_files += 1
            original, duplicates = deduplicate_analysis_file(analysis_file)
            
            total_secrets_before += original
            total_duplicates += duplicates
            
            if duplicates > 0:
                files_with_duplicates += 1
                org_name = analysis_file.stem.replace('_analysis', '')
                print(f"  🔄 {detector_dir.name}/{org_name}: Removed {duplicates} duplicate(s) from {original} secret(s)")
    
    print()
    print("=" * 70)
    print(f"📊 Deduplication Summary:")
    print(f"   Files processed: {total_files}")
    print(f"   Files with duplicates: {files_with_duplicates}")
    print(f"   Total secrets before: {total_secrets_before}")
    print(f"   Duplicates removed: {total_duplicates}")
    print(f"   Total secrets after: {total_secrets_before - total_duplicates}")
    
    if total_duplicates > 0:
        reduction = (total_duplicates * 100.0) / total_secrets_before if total_secrets_before > 0 else 0
        print(f"   Reduction: {reduction:.1f}%")
    
    print("=" * 70)
    
    if total_duplicates > 0:
        print()
        print("✅ Deduplication complete!")
        print()
        print("💡 Tip: Regenerate dashboard to see updated counts")
        print("   bash analyzer/generate_dashboard.sh all")
    else:
        print()
        print("✅ No duplicates found - all analysis files are clean!")
    
    return 0

if __name__ == "__main__":
    exit(main())
