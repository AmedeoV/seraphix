#!/usr/bin/env python3
"""
Fix incomplete JSON files in the analyzed_results directory.
This script repairs JSON files that are missing closing brackets due to interruption.
"""

import json
import sys
from pathlib import Path


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
    Returns True if file was fixed, False if it was already valid or unfixable.
    """
    try:
        # First, try to parse as-is
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        try:
            json.loads(content)
            return False  # File is already valid
        except json.JSONDecodeError:
            pass  # File needs fixing
        
        # Count brackets
        open_sq, close_sq, open_cu, close_cu = count_brackets(content)
        
        # Calculate missing brackets
        missing_square = open_sq - close_sq
        missing_curly = open_cu - close_cu
        
        if missing_square <= 0 and missing_curly <= 0:
            # No missing brackets, file is corrupt in another way
            return False
        
        # Add missing brackets
        fixed_content = content.rstrip()
        
        # Add missing curly brackets first (for objects)
        fixed_content += '}' * missing_curly
        
        # Then add missing square brackets (for arrays)
        fixed_content += ']' * missing_square
        
        # Verify the fix works
        try:
            json.loads(fixed_content)
            
            # Write back the fixed content
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(fixed_content)
            
            print(f"✅ Fixed: {file_path.name} (added {missing_curly} '}}' and {missing_square} ']')")
            return True
            
        except json.JSONDecodeError as e:
            print(f"❌ Could not fix: {file_path.name} - {e}")
            return False
            
    except Exception as e:
        print(f"❌ Error processing {file_path.name}: {e}")
        return False


def main():
    """Find and fix all incomplete JSON files in analyzed_results."""
    script_dir = Path(__file__).parent
    results_dir = script_dir / 'analyzed_results'
    
    if not results_dir.exists():
        print("❌ analyzed_results directory not found")
        sys.exit(1)
    
    print("🔧 Scanning for incomplete JSON files...")
    print("")
    
    # Find all JSON files
    json_files = list(results_dir.rglob('*_analysis.json'))
    
    if not json_files:
        print("No analysis JSON files found")
        return
    
    fixed_count = 0
    error_count = 0
    total_count = len(json_files)
    
    for json_file in json_files:
        try:
            if fix_json_file(json_file):
                fixed_count += 1
        except Exception as e:
            error_count += 1
            print(f"❌ Unexpected error with {json_file.name}: {e}")
    
    print("")
    print("=" * 60)
    print(f"📊 Summary:")
    print(f"   Total files scanned: {total_count}")
    print(f"   Files fixed: {fixed_count}")
    print(f"   Errors: {error_count}")
    print(f"   Already valid: {total_count - fixed_count - error_count}")
    print("=" * 60)


if __name__ == '__main__':
    main()
