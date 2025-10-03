#!/usr/bin/env python3
"""
GitHub Organization Star Counter - Database Updater

This script queries the SQLite database for repository organizations,
fetches their GitHub star counts, and updates the database with star information.
"""

import sqlite3
import requests
import json
import sys
import os
import time
import argparse
from collections import defaultdict
from typing import Dict, List, Tuple, Optional

# Configuration
DEFAULT_DB_FILE = "force_push_commits.sqlite3"
GITHUB_TOKEN = None  # Set this or use environment variable GITHUB_TOKEN
RATE_LIMIT_DELAY = 1  # Seconds between API calls
BATCH_SIZE = 50  # Number of repos to process before committing to database

class GitHubStarCounter:
    def __init__(self, github_token: Optional[str] = None, db_file: str = DEFAULT_DB_FILE):
        self.github_token = github_token or os.environ.get('GITHUB_TOKEN')
        self.db_file = db_file
        self.session = requests.Session()
        if self.github_token:
            self.session.headers.update({
                'Authorization': f'token {self.github_token}',
                'Accept': 'application/vnd.github.v3+json'
            })
        
        self.repo_cache = {}  # Cache for individual repo data
        self.processed_count = 0
        self.error_count = 0
        
        # Check initial rate limit status
        self.check_initial_rate_limit()
    
    def check_initial_rate_limit(self):
        """Check and display current rate limit status."""
        try:
            if self.github_token:
                response = self.session.get("https://api.github.com/rate_limit")
                if response.status_code == 200:
                    rate_data = response.json()
                    core = rate_data.get('resources', {}).get('core', {})
                    limit = core.get('limit', 0)
                    remaining = core.get('remaining', 0)
                    reset_time = core.get('reset', 0)
                    
                    print(f"🔍 Current GitHub API rate limit status:")
                    print(f"   Limit: {limit} requests/hour")
                    print(f"   Remaining: {remaining} requests")
                    print(f"   Resets at: {time.ctime(reset_time)}")
                    
                    if remaining < 10:
                        print(f"⚠️  Warning: Very few requests remaining ({remaining})")
                        
                else:
                    print(f"⚠️  Could not check rate limit status: HTTP {response.status_code}")
            else:
                print("⚠️  No GitHub token - using unauthenticated requests (60/hour limit)")
                
        except Exception as e:
            print(f"⚠️  Could not check initial rate limit: {e}")
        
        print()  # Add blank line for readability
    
    def setup_database(self):
        """Add the stars column to the database if it doesn't exist."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            # Check if stars column exists
            cur.execute("PRAGMA table_info(pushes)")
            columns = [row[1] for row in cur.fetchall()]
            
            if 'stars' not in columns:
                print("Adding 'stars' column to database...")
                cur.execute("ALTER TABLE pushes ADD COLUMN stars INTEGER DEFAULT NULL")
                db.commit()
                print("✓ Stars column added successfully")
            else:
                print("✓ Stars column already exists")
            
            # Create index for better query performance
            try:
                cur.execute("CREATE INDEX IF NOT EXISTS idx_stars ON pushes(stars)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_repo_org_name ON pushes(repo_org, repo_name)")
                db.commit()
                print("✓ Database indexes created")
            except sqlite3.Error as e:
                print(f"Note: Index creation warning: {e}")
            
            db.close()
            
        except sqlite3.Error as e:
            print(f"❌ Database setup error: {e}")
            sys.exit(1)
    
    def get_repo_stars(self, org_name: str, repo_name: str) -> Optional[int]:
        """Get star count for a specific repository."""
        repo_key = f"{org_name}/{repo_name}"
        
        if repo_key in self.repo_cache:
            return self.repo_cache[repo_key]
        
        url = f"https://api.github.com/repos/{org_name}/{repo_name}"
        
        try:
            # Check current rate limit status first
            if self.github_token:
                rate_limit_url = "https://api.github.com/rate_limit"
                rate_check = self.session.get(rate_limit_url)
                if rate_check.status_code == 200:
                    rate_data = rate_check.json()
                    core_limit = rate_data.get('resources', {}).get('core', {})
                    remaining = core_limit.get('remaining', 0)
                    reset_time = core_limit.get('reset', 0)
                    
                    if remaining <= 1:
                        current_time = int(time.time())
                        sleep_time = max(reset_time - current_time + 5, 60)
                        print(f"⏳ Preemptive rate limit wait. Sleeping for {sleep_time} seconds...")
                        print(f"   Rate limit resets at: {time.ctime(reset_time)}")
                        time.sleep(sleep_time)
            
            # Make the actual API request
            response = self.session.get(url)
            
            # Debug: Show response headers for troubleshooting
            if response.status_code == 403:
                print(f"🐛 Debug - 403 response for {repo_key}:")
                print(f"   X-RateLimit-Remaining: {response.headers.get('x-ratelimit-remaining', 'Not set')}")
                print(f"   X-RateLimit-Reset: {response.headers.get('x-ratelimit-reset', 'Not set')}")
                print(f"   X-RateLimit-Limit: {response.headers.get('x-ratelimit-limit', 'Not set')}")
                print(f"   Response: {response.text[:200]}...")
                
                # Check if it's actually a rate limit or different 403 error
                if 'rate limit' in response.text.lower() or response.headers.get('x-ratelimit-remaining') == '0':
                    # Rate limit hit
                    reset_time_header = response.headers.get('x-ratelimit-reset')
                    if reset_time_header and reset_time_header.isdigit():
                        reset_time = int(reset_time_header)
                        current_time = int(time.time())
                        sleep_time = max(reset_time - current_time + 5, 60)
                        print(f"⏳ Rate limit hit. Sleeping for {sleep_time} seconds...")
                        print(f"   Current time: {time.ctime(current_time)}")
                        print(f"   Reset time: {time.ctime(reset_time)}")
                        time.sleep(sleep_time)
                        # Retry the request
                        response = self.session.get(url)
                    else:
                        print("⚠️  Rate limit detected but no valid reset time in headers")
                        print("   Sleeping for 60 seconds as fallback...")
                        time.sleep(60)
                        response = self.session.get(url)
                else:
                    # Different kind of 403 error (e.g., private repo, insufficient permissions)
                    print(f"  ❌ 403 Forbidden (not rate limit) for {repo_key}")
                    self.repo_cache[repo_key] = 0
                    return 0
            
            if response.status_code == 404:
                # Repository not found or private
                self.repo_cache[repo_key] = 0
                return 0
            elif response.status_code != 200:
                print(f"  ❌ Error fetching {repo_key}: HTTP {response.status_code}")
                self.error_count += 1
                return None
            
            data = response.json()
            stars = data.get('stargazers_count', 0)
            self.repo_cache[repo_key] = stars
            
            # Be nice to GitHub's API
            time.sleep(RATE_LIMIT_DELAY)
            
            return stars
            
        except requests.RequestException as e:
            print(f"  ❌ Request error for {repo_key}: {e}")
            self.error_count += 1
            return None
    
    def update_repo_stars_batch(self, repo_updates: List[Tuple[str, str, int]]):
        """Update star counts for multiple repositories in a single transaction."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            total_rows_updated = 0
            for org_name, repo_name, stars in repo_updates:
                cur.execute("""
                    UPDATE pushes 
                    SET stars = ? 
                    WHERE repo_org = ? AND repo_name = ?
                """, (stars, org_name, repo_name))
                total_rows_updated += cur.rowcount
            
            db.commit()
            db.close()
            
            return total_rows_updated
            
        except sqlite3.Error as e:
            print(f"  ❌ Database batch update error: {e}")
            return 0
    
    def update_repo_stars_in_db(self, org_name: str, repo_name: str, stars: int):
        """Update the star count for all matching records in the database (single repo)."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            # Update all records for this org/repo combination
            cur.execute("""
                UPDATE pushes 
                SET stars = ? 
                WHERE repo_org = ? AND repo_name = ?
            """, (stars, org_name, repo_name))
            
            rows_updated = cur.rowcount
            db.commit()
            db.close()
            
            return rows_updated
            
        except sqlite3.Error as e:
            print(f"  ❌ Database error updating {org_name}/{repo_name}: {e}")
            return 0
    
    def get_repos_to_update(self) -> List[Tuple[str, str]]:
        """Get list of unique repo_org/repo_name pairs that need star count updates."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            # Get unique repos that have NULL stars (need updating)
            print("📊 Checking which repositories need star count updates...")
            
            cur.execute("""
                SELECT DISTINCT repo_org, repo_name 
                FROM pushes 
                WHERE repo_org IS NOT NULL 
                  AND repo_name IS NOT NULL 
                  AND stars IS NULL
                LIMIT 5
            """)
            sample_repos = cur.fetchall()
            
            if sample_repos:
                print(f"   Found repositories needing updates. Sample: {sample_repos[:3]}")
                
                # Get the full list
                cur.execute("""
                    SELECT DISTINCT repo_org, repo_name 
                    FROM pushes 
                    WHERE repo_org IS NOT NULL 
                      AND repo_name IS NOT NULL 
                      AND stars IS NULL
                    ORDER BY repo_org, repo_name
                """)
                repos = cur.fetchall()
                print(f"   Total repositories to update: {len(repos)}")
            else:
                # Check if ALL repositories need updates (stars column is completely empty)
                cur.execute("SELECT COUNT(*) FROM pushes WHERE stars IS NOT NULL AND stars >= 0")
                repos_with_data = cur.fetchone()[0]
                
                if repos_with_data == 0:
                    print("   Stars column appears to be completely empty - will update ALL repositories")
                    cur.execute("""
                        SELECT DISTINCT repo_org, repo_name 
                        FROM pushes 
                        WHERE repo_org IS NOT NULL 
                          AND repo_name IS NOT NULL
                        ORDER BY repo_org, repo_name
                    """)
                    repos = cur.fetchall()
                    print(f"   Total repositories to update: {len(repos)}")
                else:
                    print("   All repositories already have star data")
                    repos = []
            
            db.close()
            return repos
            
        except sqlite3.Error as e:
            print(f"❌ Error querying database: {e}")
            return []

def get_unique_repos_from_db(db_file: str = DEFAULT_DB_FILE) -> List[Tuple[str, str]]:
    """Get distinct repo_org/repo_name pairs from the SQLite database."""
    try:
        db = sqlite3.connect(db_file)
        cur = db.cursor()
        
        repos = []
        for row in cur.execute('SELECT DISTINCT repo_org, repo_name FROM pushes WHERE repo_org IS NOT NULL AND repo_name IS NOT NULL ORDER BY repo_org, repo_name;'):
            if row[0] and row[1]:
                repos.append((row[0], row[1]))
        
        db.close()
        return repos
    except Exception as e:
        print(f"Error reading database: {e}")
        return []

def main():
    """Main function to update the database with star counts."""
    import os
    
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description='Update GitHub repository star counts in the database.')
    parser.add_argument('--db-file', type=str, default=DEFAULT_DB_FILE,
                        help=f'Path to the SQLite database file (default: {DEFAULT_DB_FILE})')
    args = parser.parse_args()
    
    DB_FILE = args.db_file
    
    print("GitHub Repository Star Count Database Updater")
    print("=" * 50)
    print(f"Database: {DB_FILE}")
    print()
    
    # Check for GitHub token
    github_token = os.environ.get('GITHUB_TOKEN')
    if not github_token:
        print("⚠️  Warning: No GITHUB_TOKEN environment variable set.")
        print("   You may hit rate limits quickly (60 requests/hour vs 5000 requests/hour with token)")
        print("   Set your token with: $env:GITHUB_TOKEN='your_token_here'")
        print()
        
        response = input("Continue without token? (y/N): ")
        if response.lower() != 'y':
            print("Aborted.")
            sys.exit(0)
    else:
        print("✓ GitHub token found")
    
    # Initialize star counter
    star_counter = GitHubStarCounter(github_token, DB_FILE)
    
    # Test API access with a simple request
    print("Testing GitHub API access...")
    test_stars = star_counter.get_repo_stars("octocat", "Hello-World")
    if test_stars is not None:
        print(f"✓ API test successful! octocat/Hello-World has {test_stars:,} stars")
    else:
        print("❌ API test failed - there may be an issue with your token or network")
        response = input("Continue anyway? (y/N): ")
        if response.lower() != 'y':
            print("Aborted.")
            sys.exit(1)
    print()
    
    # Setup database (add stars column if needed)
    star_counter.setup_database()
    
    # Get repositories that need updating
    print("\nFinding repositories that need star count updates...")
    repos_to_update = star_counter.get_repos_to_update()
    
    if not repos_to_update:
        print("✅ All repositories already have star counts!")
        
        # Show some statistics
        all_repos = get_unique_repos_from_db(DB_FILE)
        print(f"📊 Total unique repositories in database: {len(all_repos)}")
        
        # Show a few examples with their star counts
        try:
            db = sqlite3.connect(DB_FILE)
            cur = db.cursor()
            
            print("\nSample repositories with star counts:")
            for row in cur.execute('SELECT DISTINCT repo_org, repo_name, stars FROM pushes WHERE stars IS NOT NULL ORDER BY stars DESC LIMIT 10;'):
                org, repo, stars = row
                print(f"  {org}/{repo}: {stars:,} stars")
            
            db.close()
        except Exception as e:
            print(f"Error showing examples: {e}")
        
        return
    
    print(f"Found {len(repos_to_update)} repositories to update")
    print(f"Processing in batches of {BATCH_SIZE}")
    print()
    
    # Update star counts in batches
    success_count = 0
    error_count = 0
    not_found_count = 0
    total_processed = 0
    
    print("Starting star count updates...")
    print("-" * 40)
    
    batch_updates = []  # Store pending updates for batch processing
    
    for i, (org, repo) in enumerate(repos_to_update, 1):
        try:
            print(f"[{i:4d}/{len(repos_to_update)}] {org}/{repo}", end="")
            
            # Get star count from GitHub
            stars = star_counter.get_repo_stars(org, repo)
            
            if stars is not None:
                # Add to batch
                batch_updates.append((org, repo, stars))
                
                if stars == 0:
                    print(f" → 0 stars (queued for batch update)")
                    not_found_count += 1
                else:
                    print(f" → {stars:,} stars (queued for batch update)")
                    success_count += 1
                
                # Process batch when it reaches the batch size or at the end
                if len(batch_updates) >= BATCH_SIZE or i == len(repos_to_update):
                    print(f"\n   💾 Committing batch of {len(batch_updates)} repositories to database...")
                    
                    rows_updated = star_counter.update_repo_stars_batch(batch_updates)
                    print(f"   ✅ Updated {rows_updated} database records")
                    
                    # Clear the batch
                    batch_updates = []
                    print()
            else:
                print(f" → Error occurred")
                error_count += 1
            
            total_processed += 1
            
            # Show progress every 25 repositories (but not when we just showed batch commit)
            if i % 25 == 0 and len(batch_updates) < BATCH_SIZE:
                print(f"   📊 Progress: {i}/{len(repos_to_update)} repositories processed")
                print(f"   📈 Stats so far: {success_count} success, {not_found_count} not found, {error_count} errors")
                print()
                
        except KeyboardInterrupt:
            print("\n\n⚠️  Update interrupted by user")
            
            # Process any remaining batch updates before exiting
            if batch_updates:
                print(f"💾 Committing final batch of {len(batch_updates)} repositories...")
                rows_updated = star_counter.update_repo_stars_batch(batch_updates)
                print(f"✅ Updated {rows_updated} database records")
            
            break
        except Exception as e:
            print(f" → Unexpected error: {e}")
            error_count += 1
    
    # Process any remaining batch updates
    if batch_updates:
        print(f"💾 Committing final batch of {len(batch_updates)} repositories...")
        rows_updated = star_counter.update_repo_stars_batch(batch_updates)
        print(f"✅ Updated {rows_updated} database records")
        print()
    
    # Final summary
    print(f"\n{'='*50}")
    print("Update Summary:")
    print(f"✅ Repositories with stars: {success_count:,}")
    print(f"❌ Repositories not found/private: {not_found_count:,}")
    print(f"⚠️  Errors: {error_count:,}")
    print(f"📊 Total processed: {total_processed:,}")
    print(f"⏱️  Total API errors: {star_counter.error_count}")
    
    if total_processed > 0:
        print(f"\n🎉 Database update completed!")
        print("You can now query organizations by star count quickly using the database.")
        
        # Show some quick stats
        try:
            db = sqlite3.connect(DB_FILE)
            cur = db.cursor()
            
            # Total stars in database
            cur.execute("SELECT SUM(DISTINCT stars) FROM pushes WHERE stars > 0")
            total_stars = cur.fetchone()[0] or 0
            
            # Top 5 most starred repos
            print(f"\nTop 5 most starred repositories:")
            for row in cur.execute('SELECT DISTINCT repo_org, repo_name, stars FROM pushes WHERE stars > 0 ORDER BY stars DESC LIMIT 5;'):
                org, repo, stars = row
                print(f"  {org}/{repo}: {stars:,} stars")
            
            db.close()
        except Exception as e:
            print(f"Error showing final stats: {e}")

if __name__ == "__main__":
    main()