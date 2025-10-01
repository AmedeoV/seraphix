#!/usr/bin/env python3
"""
Bug Bounty Organizations Fetcher

This script fetches GitHub organizations from the nikitastupin/orgs-data repository
which maintains a mapping from bug bounty programs to GitHub organizations.
"""

import requests
import re
import sys
import os
import json
from urllib.parse import urlparse
from typing import List, Set, Dict, Optional
import argparse
import time

class BugBountyOrgsFetcher:
    def __init__(self, github_token: Optional[str] = None):
        self.github_token = github_token
        self.session = requests.Session()
        if github_token:
            self.session.headers.update({'Authorization': f'token {github_token}'})
        
        self.base_url = "https://api.github.com/repos/nikitastupin/orgs-data"
        self.raw_base_url = "https://raw.githubusercontent.com/nikitastupin/orgs-data/main"
        
        # Rate limiting
        self.requests_made = 0
        self.start_time = time.time()
    
    def check_rate_limit(self):
        """Check and respect GitHub API rate limits"""
        if self.github_token:
            limit = 5000  # Authenticated requests
        else:
            limit = 60    # Anonymous requests
        
        elapsed = time.time() - self.start_time
        if elapsed < 3600 and self.requests_made >= limit * 0.9:  # Use 90% of limit
            wait_time = 3600 - elapsed
            print(f"⏳ Approaching rate limit. Waiting {wait_time:.0f} seconds...")
            time.sleep(wait_time)
            self.start_time = time.time()
            self.requests_made = 0
    
    def make_request(self, url: str) -> requests.Response:
        """Make a request with rate limiting"""
        self.check_rate_limit()
        response = self.session.get(url)
        self.requests_made += 1
        return response
    
    def get_directory_contents(self, path: str = "orgs-data") -> List[Dict]:
        """Get contents of orgs-data directory"""
        url = f"{self.base_url}/contents/{path}"
        
        try:
            response = self.make_request(url)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"❌ Error fetching directory contents: {e}")
            return []
    
    def fetch_tsv_file(self, file_path: str) -> str:
        """Fetch TSV file content from raw GitHub"""
        url = f"{self.raw_base_url}/{file_path}"
        
        try:
            response = requests.get(url)
            response.raise_for_status()
            return response.text
        except requests.exceptions.RequestException as e:
            print(f"❌ Error fetching {file_path}: {e}")
            return ""
    
    def extract_github_orgs_from_tsv(self, content: str) -> Set[str]:
        """Extract GitHub organization names from TSV content"""
        orgs = set()
        
        for line in content.strip().split('\n'):
            if not line.strip() or line.startswith('#'):
                continue
            
            # TSV format: URL \t GitHub_org_or_status
            parts = line.split('\t')
            if len(parts) >= 2:
                github_entry = parts[1].strip()
                
                # Skip entries that are not GitHub URLs
                if github_entry in ['?', '-'] or not github_entry:
                    continue
                
                # Extract org name from GitHub URL
                if 'github.com/' in github_entry:
                    # Extract organization name from URLs like:
                    # https://github.com/microsoft
                    # https://github.com/microsoft/repo
                    match = re.search(r'github\.com/([^/\s]+)', github_entry)
                    if match:
                        org_name = match.group(1)
                        # Skip user accounts that look like orgs but aren't real orgs
                        if org_name and org_name not in ['settings', 'notifications', 'search']:
                            orgs.add(org_name)
        
        return orgs
    
    def fetch_all_orgs(self) -> Set[str]:
        """Fetch all bug bounty GitHub organizations"""
        print("🔍 Fetching bug bounty organizations from nikitastupin/orgs-data...")
        
        all_orgs = set()
        
        # Get directory contents
        contents = self.get_directory_contents("orgs-data")
        if not contents:
            print("❌ Could not fetch directory contents")
            return all_orgs
        
        tsv_files = [item for item in contents if item['name'].endswith('.tsv')]
        
        print(f"📁 Found {len(tsv_files)} TSV files to process")
        
        for file_info in tsv_files:
            file_name = file_info['name']
            file_path = f"orgs-data/{file_name}"
            
            print(f"📄 Processing {file_name}...")
            
            content = self.fetch_tsv_file(file_path)
            if content:
                file_orgs = self.extract_github_orgs_from_tsv(content)
                print(f"   Found {len(file_orgs)} organizations")
                all_orgs.update(file_orgs)
            
            # Small delay to be respectful
            time.sleep(0.1)
        
        return all_orgs
    
    def save_orgs_to_file(self, orgs: Set[str], output_file: str):
        """Save organizations to a file"""
        with open(output_file, 'w') as f:
            for org in sorted(orgs):
                f.write(f"{org}\n")
        print(f"💾 Saved {len(orgs)} organizations to {output_file}")
    
    def save_orgs_to_json(self, orgs: Set[str], output_file: str):
        """Save organizations to a JSON file with metadata"""
        data = {
            "source": "nikitastupin/orgs-data",
            "fetched_at": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
            "total_orgs": len(orgs),
            "organizations": sorted(list(orgs))
        }
        
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"💾 Saved {len(orgs)} organizations to {output_file}")

def main():
    parser = argparse.ArgumentParser(description='Fetch bug bounty GitHub organizations')
    parser.add_argument('--output', '-o', default='bugbounty_orgs.txt',
                       help='Output file for organization list (default: bugbounty_orgs.txt)')
    parser.add_argument('--json', action='store_true',
                       help='Save as JSON with metadata instead of plain text')
    parser.add_argument('--token', help='GitHub personal access token (or set GITHUB_TOKEN env var)')
    
    args = parser.parse_args()
    
    # Get GitHub token
    github_token = args.token or os.getenv('GITHUB_TOKEN')
    
    if not github_token:
        print("⚠️  Warning: No GitHub token provided")
        print("   You'll be limited to 60 requests/hour without a token")
        print("   Set GITHUB_TOKEN environment variable or use --token")
        print()
    
    # Initialize fetcher
    fetcher = BugBountyOrgsFetcher(github_token)
    
    # Fetch organizations
    orgs = fetcher.fetch_all_orgs()
    
    if not orgs:
        print("❌ No organizations found")
        sys.exit(1)
    
    print(f"\n✅ Found {len(orgs)} unique bug bounty organizations")
    
    # Save to file
    if args.json:
        output_file = args.output.replace('.txt', '.json') if args.output.endswith('.txt') else args.output
        fetcher.save_orgs_to_json(orgs, output_file)
    else:
        fetcher.save_orgs_to_file(orgs, args.output)
    
    # Print some example organizations
    print("\n📋 Sample organizations found:")
    sample_orgs = sorted(list(orgs))[:10]
    for org in sample_orgs:
        print(f"   • {org}")
    
    if len(orgs) > 10:
        print(f"   ... and {len(orgs) - 10} more")

if __name__ == "__main__":
    main()