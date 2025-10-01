#!/usr/bin/env python3
"""
Database Star Count Updater

This script adds a 'stars' column to the SQLite database and populates it
with GitHub star counts for each repository. This allows for faster queries
without needing to hit the GitHub API repeatedly.

Usage:
    python update_database_stars.py

Environment Variables:
    GITHUB_TOKEN - Your GitHub personal access token (recommended)
    BATCH_SIZE - Number of repos to process in each batch (default: 100)
    RATE_LIMIT_DELAY - Seconds between API calls (default: 1)
"""

import sqlite3
import requests
import os
import time
import sys
from typing import Optional, Tuple

# Configuration
DB_FILE = "force_push_commits.sqlite3"
BATCH_SIZE = int(os.environ.get('BATCH_SIZE', 100))
RATE_LIMIT_DELAY = float(os.environ.get('RATE_LIMIT_DELAY', 1.0))

class DatabaseStarUpdater:
    def __init__(self, db_file: str, github_token: Optional[str] = None):
        self.db_file = db_file
        self.github_token = github_token
        self.session = requests.Session()
        
        if self.github_token:
            self.session.headers.update({
                'Authorization': f'token {self.github_token}',
                'Accept': 'application/vnd.github.v3+json'
            })
    
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
    
    def get_repo_star_count(self, org_name: str, repo_name: str) -> Tuple[int, str]:
        """
        Get star count for a specific repository.
        Returns: (star_count, status)
        """
        url = f"https://api.github.com/repos/{org_name}/{repo_name}"
        
        try:
            response = self.session.get(url)
            
            if response.status_code == 200:
                data = response.json()
                stars = data.get('stargazers_count', 0)
                return stars, 'success'
            elif response.status_code == 404:
                return 0, 'not_found'
            elif response.status_code == 403:
                # Rate limit or access forbidden
                if 'x-ratelimit-remaining' in response.headers:
                    remaining = int(response.headers['x-ratelimit-remaining'])
                    if remaining == 0:
                        reset_time = int(response.headers.get('x-ratelimit-reset', 0))
                        current_time = int(time.time())
                        sleep_time = max(reset_time - current_time + 1, 60)
                        print(f"\n⏳ Rate limit reached. Sleeping for {sleep_time} seconds...")
                        time.sleep(sleep_time)
                        return self.get_repo_star_count(org_name, repo_name)  # Retry
                return 0, 'forbidden'
            else:
                return 0, f'error_{response.status_code}'
                
        except requests.RequestException as e:
            print(f"Request error for {org_name}/{repo_name}: {e}")
            return 0, 'request_error'
    
    def get_repos_to_update(self) -> list:
        """Get list of unique repo_org/repo_name pairs that need star count updates."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            # Get unique repos that either have NULL stars or haven't been updated recently
            query = """
            SELECT DISTINCT repo_org, repo_name 
            FROM pushes 
            WHERE repo_org IS NOT NULL 
              AND repo_name IS NOT NULL 
              AND (stars IS NULL OR stars = -1)
            ORDER BY repo_org, repo_name
            """
            
            repos = cur.fetchall()
            db.close()
            
            return repos
            
        except sqlite3.Error as e:
            print(f"❌ Error querying database: {e}")
            return []
    
    def update_repo_stars(self, org_name: str, repo_name: str, stars: int, status: str):
        """Update the star count for all matching records in the database."""
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
            print(f"❌ Error updating database for {org_name}/{repo_name}: {e}")
            return 0
    
    def get_update_progress(self) -> Tuple[int, int]:
        """Get progress of star count updates."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            # Count total unique repos
            cur.execute("""
                SELECT COUNT(DISTINCT repo_org || '/' || repo_name) 
                FROM pushes 
                WHERE repo_org IS NOT NULL AND repo_name IS NOT NULL
            """)
            total_repos = cur.fetchone()[0]
            
            # Count repos with star data
            cur.execute("""
                SELECT COUNT(DISTINCT repo_org || '/' || repo_name) 
                FROM pushes 
                WHERE repo_org IS NOT NULL 
                  AND repo_name IS NOT NULL 
                  AND stars IS NOT NULL 
                  AND stars >= 0
            """)
            updated_repos = cur.fetchone()[0]
            
            db.close()
            return updated_repos, total_repos
            
        except sqlite3.Error as e:
            print(f"❌ Error checking progress: {e}")
            return 0, 0
    
    def run_update(self):
        """Main method to update star counts for all repositories."""
        print("Database Star Count Updater")
        print("=" * 50)
        print(f"Database: {self.db_file}")
        print(f"GitHub Token: {'✓ Set' if self.github_token else '✗ Not set (rate limited)'}")
        print(f"Batch Size: {BATCH_SIZE}")
        print(f"Rate Limit Delay: {RATE_LIMIT_DELAY}s")
        print()
        
        # Setup database
        self.setup_database()
        
        # Get initial progress
        updated, total = self.get_update_progress()
        print(f"Progress: {updated}/{total} repositories have star data")
        
        if updated == total:
            print("✅ All repositories already have star data!")
            return
        
        # Get repositories that need updates
        repos_to_update = self.get_repos_to_update()
        print(f"Found {len(repos_to_update)} repositories to update\n")
        
        if not repos_to_update:
            print("✅ No repositories need updating!")
            return
        
        # Update star counts
        success_count = 0
        error_count = 0
        not_found_count = 0
        
        for i, (org, repo) in enumerate(repos_to_update, 1):
            try:
                print(f"[{i:4d}/{len(repos_to_update)}] {org}/{repo}", end="")
                
                # Get star count from GitHub
                stars, status = self.get_repo_star_count(org, repo)
                
                # Update database
                rows_updated = self.update_repo_stars(org, repo, stars, status)
                
                if status == 'success':
                    print(f" → {stars:,} stars ({rows_updated} records updated)")
                    success_count += 1
                elif status == 'not_found':
                    print(f" → Not found/private ({rows_updated} records updated)")
                    not_found_count += 1
                else:
                    print(f" → Error: {status} ({rows_updated} records updated)")
                    error_count += 1
                
                # Rate limiting
                if i % 10 == 0:  # Show progress every 10 repos
                    updated_now, _ = self.get_update_progress()
                    print(f"   Progress: {updated_now}/{total} repositories completed")
                
                time.sleep(RATE_LIMIT_DELAY)
                
            except KeyboardInterrupt:
                print("\n\n⚠️  Update interrupted by user")
                break
            except Exception as e:
                print(f" → Unexpected error: {e}")
                error_count += 1
        
        # Final summary
        print(f"\n{'='*50}")
        print("Update Summary:")
        print(f"✅ Success: {success_count}")
        print(f"❌ Not found/private: {not_found_count}")
        print(f"⚠️  Errors: {error_count}")
        
        updated_final, total_final = self.get_update_progress()
        print(f"📊 Final progress: {updated_final}/{total_final} repositories have star data")
        
        if updated_final == total_final:
            print("\n🎉 All repositories now have star data!")
        else:
            print(f"\n📝 {total_final - updated_final} repositories still need updates")

def main():
    """Main entry point."""
    # Check if database exists
    if not os.path.exists(DB_FILE):
        print(f"❌ Database file '{DB_FILE}' not found!")
        print("Make sure you're running this script in the correct directory.")
        sys.exit(1)
    
    # Get GitHub token
    github_token = os.environ.get('GITHUB_TOKEN')
    if not github_token:
        print("⚠️  Warning: GITHUB_TOKEN not set!")
        print("   Without a token, you'll be limited to 60 requests/hour.")
        print("   With a token, you get 5000 requests/hour.")
        print("   Set it with: $env:GITHUB_TOKEN='your_token_here'")
        print()
        
        response = input("Continue without token? (y/N): ")
        if response.lower() != 'y':
            print("Aborted.")
            sys.exit(0)
    
    # Create updater and run
    updater = DatabaseStarUpdater(DB_FILE, github_token)
    updater.run_update()

if __name__ == "__main__":
    main()