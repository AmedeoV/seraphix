#!/usr/bin/env python3
"""
GitHub Organization Star Counter - Database Updater (Parallel Version)

This script queries the SQLite database for repository organizations,
fetches their GitHub star counts using parallel processing, and updates 
the database with star information.

Performance improvements:
- Concurrent API requests using ThreadPoolExecutor
- Smart rate limiting across threads
- Optimized batch database operations
- Progress tracking and error handling
"""

import sqlite3
import requests
import json
import sys
import os
import time
import threading
import logging
import signal
import argparse
from collections import defaultdict
from typing import Dict, List, Tuple, Optional, Set
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import queue
from datetime import datetime

# Configuration
DEFAULT_DB_FILE = "force_push_commits.sqlite3"
GITHUB_TOKEN = None  # Set this or use environment variable GITHUB_TOKEN
RATE_LIMIT_DELAY = 0.1  # Reduced delay for parallel processing
RATE_LIMIT_BUFFER = 50  # Keep this many requests as buffer before rate limit

# Default values (will be calculated dynamically)
DEFAULT_BATCH_SIZE = 100
DEFAULT_MAX_WORKERS = 8

# Global flag for graceful shutdown
shutdown_requested = False

def signal_handler(signum, frame):
    """Handle interrupt signals gracefully."""
    global shutdown_requested
    shutdown_requested = True
    print(f"\n🛑 Interrupt received (Ctrl+C). Gracefully shutting down...")
    print("   Please wait for current operations to complete...")
    print("   Press Ctrl+C again to force quit (may lose data)")

# Set up signal handlers
signal.signal(signal.SIGINT, signal_handler)
if hasattr(signal, 'SIGTERM'):
    signal.signal(signal.SIGTERM, signal_handler)

# Logging configuration
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'
LOG_DATE_FORMAT = '%Y-%m-%d %H:%M:%S'

def setup_logging():
    """Set up logging to both file and console."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_filename = f"star_counter_parallel_{timestamp}.log"
    
    # Create logs directory if it doesn't exist
    os.makedirs("logs", exist_ok=True)
    log_filepath = os.path.join("logs", log_filename)
    
    # Configure root logger
    logging.basicConfig(
        level=logging.INFO,
        format=LOG_FORMAT,
        datefmt=LOG_DATE_FORMAT,
        handlers=[
            logging.FileHandler(log_filepath),
            logging.StreamHandler(sys.stdout)
        ]
    )
    
    logger = logging.getLogger(__name__)
    logger.info(f"Logging initialized. Log file: {log_filepath}")
    return logger, log_filepath

def calculate_optimal_settings(github_token: Optional[str], total_repos: int = 0) -> Tuple[int, int]:
    """
    Calculate optimal MAX_WORKERS and BATCH_SIZE based on system resources and API limits.
    
    Args:
        github_token: GitHub API token (if available)
        total_repos: Total number of repositories to process (for batch size calculation)
    
    Returns:
        Tuple of (max_workers, batch_size)
    """
    logger = logging.getLogger(__name__)
    
    # Calculate MAX_WORKERS based on CPU cores and API rate limits
    cpu_count = os.cpu_count() or 4
    
    if github_token:
        # With token: 5000 requests/hour = ~83 requests/minute
        # Conservative approach: use CPU cores but cap based on rate limit comfort
        # We want to leave headroom for rate limit management
        max_workers = min(cpu_count * 2, 16)  # Max 16 workers even on high-core systems
        
        # Check initial rate limit to adjust workers
        try:
            session = requests.Session()
            session.headers.update({
                'Authorization': f'token {github_token}',
                'Accept': 'application/vnd.github.v3+json'
            })
            response = session.get("https://api.github.com/rate_limit", timeout=10)
            if response.status_code == 200:
                rate_data = response.json()
                core = rate_data.get('resources', {}).get('core', {})
                remaining = core.get('remaining', 5000)
                limit = core.get('limit', 5000)
                
                # If we have low remaining requests, reduce workers
                if remaining < 500:
                    max_workers = min(max_workers, 4)
                    logger.info(f"Low API quota ({remaining}/{limit}), reducing workers to {max_workers}")
                elif remaining < 1000:
                    max_workers = min(max_workers, 8)
                    logger.info(f"Medium API quota ({remaining}/{limit}), limiting workers to {max_workers}")
        except Exception as e:
            logger.warning(f"Could not check rate limit for worker calculation: {e}")
    else:
        # Without token: 60 requests/hour = 1 request/minute
        # Use minimal workers to avoid hitting rate limit
        max_workers = 2
        logger.info("No GitHub token - limiting to 2 workers due to strict rate limits")
    
    # Calculate BATCH_SIZE based on total repositories and memory considerations
    if total_repos > 0:
        # For small sets, use smaller batches
        if total_repos < 100:
            batch_size = 25
        elif total_repos < 500:
            batch_size = 50
        elif total_repos < 2000:
            batch_size = 100
        else:
            # For large sets, use larger batches for efficiency
            batch_size = min(250, total_repos // 20)  # ~5% of total or 250, whichever is smaller
    else:
        # Default batch size
        batch_size = DEFAULT_BATCH_SIZE
    
    print(f"🧮 Dynamic configuration calculated:")
    print(f"   CPU cores: {cpu_count}")
    print(f"   Max workers: {max_workers} ({'token authenticated' if github_token else 'unauthenticated'})")
    print(f"   Batch size: {batch_size}")
    if total_repos > 0:
        print(f"   Total repos: {total_repos:,}")
    
    logger.info(f"Dynamic settings: CPU={cpu_count}, Workers={max_workers}, BatchSize={batch_size}, TotalRepos={total_repos}")
    
    return max_workers, batch_size

@dataclass
class RepoResult:
    """Container for repository processing results."""
    org: str
    repo: str
    stars: Optional[int]
    success: bool
    error_msg: Optional[str] = None

class RateLimitManager:
    """Thread-safe rate limit manager for GitHub API using dynamic response headers."""
    
    def __init__(self, session: requests.Session, github_token: Optional[str], star_counter=None):
        self.session = session
        self.github_token = github_token
        self.star_counter = star_counter  # Reference to main counter for triggering saves
        self.lock = threading.Lock()
        self.last_check_time = 0
        self.remaining_requests = 5000 if github_token else 60
        self.reset_time = 0
        self.rate_limit_hit = False
        
    def update_from_response_headers(self, response: requests.Response) -> bool:
        """Update rate limit status from GitHub API response headers. Returns True if rate limited."""
        with self.lock:
            # GitHub provides rate limit info in headers for every response
            remaining_header = response.headers.get('x-ratelimit-remaining')
            reset_header = response.headers.get('x-ratelimit-reset')
            limit_header = response.headers.get('x-ratelimit-limit')
            
            if remaining_header and reset_header:
                try:
                    self.remaining_requests = int(remaining_header)
                    self.reset_time = int(reset_header)
                    limit = int(limit_header) if limit_header else 5000
                    
                    current_time = int(time.time())
                    time_to_reset = self.reset_time - current_time
                    
                    # Log rate limit status updates periodically
                    if self.remaining_requests % 100 == 0 or self.remaining_requests < 50:
                        print(f"🔄 Rate limit update: {self.remaining_requests}/{limit} remaining, resets in {time_to_reset/60:.1f}min")
                    
                    # Check if we're rate limited
                    if response.status_code == 403 and 'rate limit' in response.text.lower():
                        self.rate_limit_hit = True
                        print(f"🚫 Rate limit hit! Remaining: {self.remaining_requests}, Reset: {time.ctime(self.reset_time)}")
                        
                        # Trigger database save when rate limit is hit
                        if self.star_counter:
                            print(f"💾 Rate limit triggered - saving progress to database...")
                            self.star_counter.save_progress_to_database(force=True)
                        return True
                    
                    # Reset flag if we have requests available
                    if self.remaining_requests > 0:
                        self.rate_limit_hit = False
                        
                except ValueError:
                    # Headers weren't valid integers
                    pass
            
            return False
    
    def get_wait_time_if_needed(self) -> int:
        """Get wait time if we're currently rate limited, 0 otherwise."""
        with self.lock:
            if self.rate_limit_hit or self.remaining_requests <= 0:
                current_time = int(time.time())
                wait_time = max(self.reset_time - current_time + 5, 60)  # Add 5 second buffer
                
                # Sanity check on wait time
                if wait_time > 7200:  # More than 2 hours seems wrong
                    print(f"⚠️  Calculated wait time seems too long ({wait_time}s), capping at 30 minutes")
                    wait_time = 1800  # Cap at 30 minutes
                
                return wait_time
            return 0

class ParallelGitHubStarCounter:
    def __init__(self, github_token: Optional[str], max_workers: int, batch_size: int, db_file: str = DEFAULT_DB_FILE):
        """
        Initialize the parallel GitHub star counter.
        
        Args:
            github_token: GitHub API token for authentication
            max_workers: Number of parallel worker threads
            batch_size: Size of batches for database operations
            db_file: Path to SQLite database file
        """
        self.github_token = github_token or os.environ.get('GITHUB_TOKEN')
        self.max_workers = max_workers
        self.batch_size = batch_size
        self.db_file = db_file
        self.session = requests.Session()
        self.logger = logging.getLogger(__name__)
        
        if self.github_token:
            self.session.headers.update({
                'Authorization': f'token {self.github_token}',
                'Accept': 'application/vnd.github.v3+json'
            })
        
        self.repo_cache = {}  # Cache for individual repo data
        self.rate_limiter = RateLimitManager(self.session, self.github_token, self)
        self.processed_count = 0
        self.error_count = 0
        self.cache_lock = threading.Lock()
        
        # Performance tracking
        self.start_time = None
        self.api_call_times = []
        
        # Detailed logging counters
        self.success_repos = []
        self.not_found_repos = []
        self.error_repos = []
        
        # Progress saving for periodic database updates
        self.pending_updates = []  # Store results waiting to be written to DB
        self.last_db_update_time = time.time()
        self.db_update_interval = 1800  # 30 minutes in seconds
        self.updates_lock = threading.Lock()
        
        print(f"🚀 Initialized parallel processor with {max_workers} workers and batch size {batch_size}")
        print(f"💾 Periodic database saves: Every {self.db_update_interval/60:.0f} minutes or when rate limited")
        self.logger.info(f"Initialized parallel processor with {max_workers} workers and batch size {batch_size}")
        self.logger.info(f"Periodic database saves enabled: Every {self.db_update_interval/60:.0f} minutes or when rate limited")
        self.check_initial_rate_limit()
    
    def check_initial_rate_limit(self):
        """Check and display current rate limit status, wait if rate limited."""
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
                    self.logger.info(f"GitHub API rate limit - Limit: {limit}, Remaining: {remaining}, Resets: {time.ctime(reset_time)}")
                    
                    # Check if we're rate limited or very close
                    if remaining == 0:
                        current_time = int(time.time())
                        wait_time = reset_time - current_time + 5  # Add 5 second buffer
                        
                        print(f"🚫 RATE LIMITED! Need to wait {wait_time}s ({wait_time/60:.1f} minutes)")
                        print(f"   Rate limit resets at: {time.ctime(reset_time)}")
                        print(f"   Starting countdown wait...")
                        self.logger.warning(f"Rate limited - waiting {wait_time}s until {time.ctime(reset_time)}")
                        
                        # Wait with countdown
                        self._wait_for_rate_limit_reset(wait_time, reset_time)
                        
                        # Check again after wait
                        print(f"⏰ Wait complete! Checking rate limit status again...")
                        response = self.session.get("https://api.github.com/rate_limit")
                        if response.status_code == 200:
                            rate_data = response.json()
                            core = rate_data.get('resources', {}).get('core', {})
                            new_remaining = core.get('remaining', 0)
                            print(f"✅ Rate limit reset! Now have {new_remaining} requests available")
                            self.logger.info(f"Rate limit reset completed - {new_remaining} requests now available")
                            remaining = new_remaining
                        else:
                            print(f"⚠️  Could not verify rate limit reset: HTTP {response.status_code}")
                    
                    elif remaining < 100:
                        print(f"⚠️  Warning: Low requests remaining ({remaining})")
                        self.logger.warning(f"Low API requests remaining: {remaining}")
                    
                    # Update rate limiter with current status
                    self.rate_limiter.remaining_requests = remaining
                    self.rate_limiter.reset_time = reset_time
                        
                else:
                    print(f"⚠️  Could not check rate limit status: HTTP {response.status_code}")
                    self.logger.warning(f"Could not check rate limit status: HTTP {response.status_code}")
            else:
                print("⚠️  No GitHub token - using unauthenticated requests")
                print("   This will be VERY slow (60 requests/hour limit)")
                print("   Consider setting GITHUB_TOKEN for 5000 requests/hour")
                self.logger.warning("No GitHub token - using unauthenticated requests (60 requests/hour limit)")
                
        except Exception as e:
            print(f"⚠️  Could not check initial rate limit: {e}")
            self.logger.error(f"Could not check initial rate limit: {e}")
        
        print()  # Add blank line for readability
    
    def _wait_for_rate_limit_reset(self, wait_time: int, reset_time: int):
        """Wait for rate limit reset with countdown display."""
        global shutdown_requested
        
        remaining_wait = wait_time
        last_update = 0
        
        while remaining_wait > 0 and not shutdown_requested:
            # Show countdown every 30 seconds for long waits, every 5 seconds for short waits
            update_interval = 30 if wait_time > 300 else 5
            
            if remaining_wait == wait_time or remaining_wait % update_interval == 0 or remaining_wait <= 10:
                minutes_left = remaining_wait / 60
                if minutes_left >= 1:
                    print(f"   ⏳ Waiting... {remaining_wait}s remaining ({minutes_left:.1f} minutes)")
                else:
                    print(f"   ⏳ Waiting... {remaining_wait}s remaining")
                
                # Show estimated completion time
                if remaining_wait > 60:
                    completion_time = time.time() + remaining_wait
                    print(f"   🕐 Will resume at: {time.ctime(completion_time)}")
            
            # Wait in 1-second chunks so we can respond to shutdown requests
            time.sleep(1)
            remaining_wait -= 1
            
            if shutdown_requested:
                print(f"\n🛑 Shutdown requested during rate limit wait")
                return
    
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
    
    def get_repo_stars_worker(self, org_name: str, repo_name: str) -> RepoResult:
        """Worker function to get star count for a specific repository (thread-safe)."""
        global shutdown_requested
        
        # Check for shutdown request before processing
        if shutdown_requested:
            return RepoResult(org_name, repo_name, None, False, "Shutdown requested")
        
        repo_key = f"{org_name}/{repo_name}"
        
        # Check cache first (thread-safe)
        with self.cache_lock:
            if repo_key in self.repo_cache:
                cached_stars = self.repo_cache[repo_key]
                return RepoResult(org_name, repo_name, cached_stars, True)
        
        # Check if we need to wait due to previous rate limit
        wait_time = self.rate_limiter.get_wait_time_if_needed()
        if wait_time > 0:
            print(f"⏳ Rate limit active - waiting {wait_time}s ({wait_time/60:.1f} min) before retry...")
            
            # Wait in small chunks so we can respond to shutdown requests
            remaining_wait = wait_time
            while remaining_wait > 0 and not shutdown_requested:
                chunk_wait = min(5, remaining_wait)  # Wait in 5-second chunks
                time.sleep(chunk_wait)
                remaining_wait -= chunk_wait
                
                # Show countdown for long waits
                if wait_time > 60 and remaining_wait % 30 == 0 and remaining_wait > 0:
                    print(f"   ⏳ Still waiting... {remaining_wait}s remaining ({remaining_wait/60:.1f} min)")
                
                if shutdown_requested:
                    return RepoResult(org_name, repo_name, None, False, "Shutdown requested during rate limit wait")
        
        # Check for shutdown request again after wait
        if shutdown_requested:
            return RepoResult(org_name, repo_name, None, False, "Shutdown requested")
        
        url = f"https://api.github.com/repos/{org_name}/{repo_name}"
        api_start_time = time.time()
        
        try:
            # Make the API request
            response = self.session.get(url, timeout=15)
            api_duration = time.time() - api_start_time
            self.api_call_times.append(api_duration)
            
            # Update rate limit status from response headers
            is_rate_limited = self.rate_limiter.update_from_response_headers(response)
            
            if response.status_code == 404:
                # Repository not found or private
                with self.cache_lock:
                    self.repo_cache[repo_key] = 0
                self.logger.info(f"Repository {repo_key}: Not found/private (0 stars)")
                return RepoResult(org_name, repo_name, 0, True)
            
            elif response.status_code == 403:
                if is_rate_limited:
                    # This request hit the rate limit - the rate limiter is now updated
                    # Return an error so this can be retried later
                    error_msg = "Rate limit hit - will retry after wait"
                    self.logger.warning(f"Repository {repo_key}: {error_msg}")
                    return RepoResult(org_name, repo_name, None, False, error_msg)
                else:
                    # Different 403 error (private repo, insufficient permissions, etc.)
                    with self.cache_lock:
                        self.repo_cache[repo_key] = 0
                    self.logger.info(f"Repository {repo_key}: Access forbidden (0 stars)")
                    return RepoResult(org_name, repo_name, 0, True)
            
            elif response.status_code == 200:
                # Success!
                data = response.json()
                stars = data.get('stargazers_count', 0)
                
                # Cache the result (thread-safe)
                with self.cache_lock:
                    self.repo_cache[repo_key] = stars
                
                # Log successful fetch with star count
                if stars > 0:
                    self.logger.info(f"Repository {repo_key}: {stars:,} stars")
                else:
                    self.logger.info(f"Repository {repo_key}: 0 stars")
                
                # Small delay to be nice to the API (with shutdown check)
                if not shutdown_requested:
                    time.sleep(RATE_LIMIT_DELAY)
                
                return RepoResult(org_name, repo_name, stars, True)
            
            else:
                # Other HTTP error
                error_msg = f"HTTP {response.status_code}"
                self.logger.error(f"Repository {repo_key}: API error - {error_msg}")
                return RepoResult(org_name, repo_name, None, False, error_msg)
            
        except requests.RequestException as e:
            error_msg = str(e)
            self.logger.error(f"Repository {repo_key}: Request error - {error_msg}")
            return RepoResult(org_name, repo_name, None, False, error_msg)
        except Exception as e:
            error_msg = f"Unexpected error: {e}"
            self.logger.error(f"Repository {repo_key}: {error_msg}")
            return RepoResult(org_name, repo_name, None, False, error_msg)
    
    def process_repos_parallel(self, repos_to_process: List[Tuple[str, str]]) -> List[RepoResult]:
        """Process multiple repositories in parallel using ThreadPoolExecutor with dynamic rate limiting."""
        global shutdown_requested
        
        print(f"🔄 Processing {len(repos_to_process)} repositories with {self.max_workers} workers...")
        print(f"💡 Using dynamic rate limit detection from API response headers")
        self.logger.info(f"Starting parallel processing of {len(repos_to_process)} repositories with {self.max_workers} workers")
        
        results = []
        self.start_time = time.time()
        retry_queue = []  # Queue for rate-limited requests to retry
        
        try:
            with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
                # Submit all tasks
                future_to_repo = {
                    executor.submit(self.get_repo_stars_worker, org, repo): (org, repo)
                    for org, repo in repos_to_process
                }
                
                # Process completed tasks
                completed_count = 0
                last_progress_log = 0
                
                for future in as_completed(future_to_repo):
                    # Check for shutdown request
                    if shutdown_requested:
                        print(f"\n🛑 Shutdown requested. Cancelling remaining tasks...")
                        self.logger.warning("Shutdown requested during parallel processing")
                        
                        # Cancel pending futures
                        for pending_future in future_to_repo:
                            if not pending_future.done():
                                pending_future.cancel()
                        break
                    
                    org, repo = future_to_repo[future]
                    
                    try:
                        # Reduced timeout for better responsiveness
                        result = future.result(timeout=20)
                        
                        # Check if this was a rate limit error that should be retried
                        if (not result.success and result.error_msg and 
                            "rate limit" in result.error_msg.lower()):
                            # Add to retry queue instead of treating as final error
                            retry_queue.append((org, repo))
                            print(f"  ⏸️  {org}/{repo}: Rate limited, queued for retry")
                            continue
                        
                        results.append(result)
                        
                        # Add successful results to pending updates for periodic saves
                        self.add_result_to_pending(result)
                        
                        # Track results for detailed logging
                        if result.success:
                            if result.stars and result.stars > 0:
                                self.success_repos.append((f"{org}/{repo}", result.stars))
                            else:
                                self.not_found_repos.append(f"{org}/{repo}")
                        else:
                            self.error_repos.append((f"{org}/{repo}", result.error_msg))
                        
                        completed_count += 1
                        
                        # Check for periodic database save (every 30 minutes)
                        if self.should_update_database():
                            self.save_progress_to_database()
                        
                        # Progress reporting (console and log) - more frequent during shutdown
                        progress_interval = 25 if not shutdown_requested else 5
                        if (completed_count % progress_interval == 0 or completed_count <= 10 or 
                            completed_count - last_progress_log >= 50):
                            elapsed = time.time() - self.start_time
                            rate = completed_count / elapsed if elapsed > 0 else 0
                            remaining_work = len(repos_to_process) - completed_count - len(retry_queue)
                            eta = remaining_work / rate if rate > 0 else 0
                            
                            status_msg = "🛑 SHUTTING DOWN" if shutdown_requested else "📊"
                            progress_msg = (f"{status_msg} Progress: {completed_count}/{len(repos_to_process)} "
                                          f"({completed_count/len(repos_to_process)*100:.1f}%) "
                                          f"Rate: {rate:.1f}/sec ETA: {eta/60:.1f}min")
                            if retry_queue:
                                progress_msg += f" | {len(retry_queue)} queued for retry"
                            print(progress_msg)
                            self.logger.info(progress_msg.replace("📊 ", "").replace("🛑 SHUTTING DOWN ", ""))
                            last_progress_log = completed_count
                        
                        # Show individual results for first few and any interesting ones
                        if completed_count <= 20 or (result.success and result.stars and result.stars > 1000):
                            if result.success:
                                if result.stars and result.stars > 0:
                                    print(f"  ✅ {org}/{repo}: {result.stars:,} stars")
                                else:
                                    print(f"  ⭕ {org}/{repo}: Not found/private")
                            else:
                                print(f"  ❌ {org}/{repo}: {result.error_msg}")
                        
                        if not result.success:
                            self.error_count += 1
                            
                    except Exception as e:
                        self.error_count += 1
                        error_result = RepoResult(org, repo, None, False, f"Future error: {e}")
                        results.append(error_result)
                        self.error_repos.append((f"{org}/{repo}", f"Future error: {e}"))
                        self.logger.error(f"Repository {org}/{repo}: Future error: {e}")
                        if completed_count <= 10:
                            print(f"  ❌ Future error for {org}/{repo}: {e}")
                
                # Handle retry queue if we have rate-limited requests
                if retry_queue and not shutdown_requested:
                    print(f"\n🔄 Processing {len(retry_queue)} rate-limited repositories after wait...")
                    self.logger.info(f"Processing {len(retry_queue)} repositories from retry queue")
                    
                    # Submit retry tasks
                    retry_futures = {
                        executor.submit(self.get_repo_stars_worker, org, repo): (org, repo)
                        for org, repo in retry_queue
                    }
                    
                    for future in as_completed(retry_futures):
                        if shutdown_requested:
                            break
                            
                        org, repo = retry_futures[future]
                        try:
                            result = future.result(timeout=20)
                            results.append(result)
                            completed_count += 1
                            
                            # Add successful retry results to pending updates
                            self.add_result_to_pending(result)
                            
                            if result.success:
                                if result.stars and result.stars > 0:
                                    self.success_repos.append((f"{org}/{repo}", result.stars))
                                    print(f"  ✅ Retry {org}/{repo}: {result.stars:,} stars")
                                else:
                                    self.not_found_repos.append(f"{org}/{repo}")
                                    print(f"  ⭕ Retry {org}/{repo}: Not found/private")
                            else:
                                self.error_repos.append((f"{org}/{repo}", result.error_msg))
                                print(f"  ❌ Retry {org}/{repo}: {result.error_msg}")
                                
                        except Exception as e:
                            error_result = RepoResult(org, repo, None, False, f"Retry error: {e}")
                            results.append(error_result)
                            self.error_repos.append((f"{org}/{repo}", f"Retry error: {e}"))
                            print(f"  ❌ Retry error for {org}/{repo}: {e}")
                
                # If shutdown was requested, wait a bit for remaining tasks to complete
                if shutdown_requested:
                    print("⏳ Waiting for active tasks to complete (max 5 seconds)...")
                    remaining_futures = [f for f in future_to_repo if not f.done()]
                    if remaining_futures:
                        # Wait for remaining futures with timeout
                        for future in remaining_futures:
                            try:
                                result = future.result(timeout=1)  # Short timeout
                                results.append(result)
                                completed_count += 1
                            except Exception:
                                # Cancel if it takes too long
                                future.cancel()
                    
                    print(f"✅ Graceful shutdown completed. Processed {completed_count}/{len(repos_to_process)} repositories.")
                    self.logger.info(f"Graceful shutdown completed. Processed {completed_count}/{len(repos_to_process)} repositories.")
        
        except KeyboardInterrupt:
            # This should be rare now due to signal handling, but just in case
            print(f"\n🛑 Force interrupt detected. Stopping immediately...")
            self.logger.error("Force interrupt detected during parallel processing")
            shutdown_requested = True
        
        # Performance summary
        elapsed_time = time.time() - self.start_time
        avg_api_time = sum(self.api_call_times) / len(self.api_call_times) if self.api_call_times else 0
        
        print(f"\n⚡ Parallel processing completed!")
        print(f"   Total time: {elapsed_time:.1f}s")
        print(f"   Processing rate: {len(repos_to_process)/elapsed_time:.1f} repos/sec")
        print(f"   Average API call time: {avg_api_time:.2f}s")
        print(f"   Speedup vs sequential: ~{self.max_workers*0.7:.1f}x estimated")
        
        # Log performance summary
        self.logger.info(f"Parallel processing completed in {elapsed_time:.1f}s")
        self.logger.info(f"Processing rate: {len(repos_to_process)/elapsed_time:.1f} repos/sec")
        self.logger.info(f"Average API call time: {avg_api_time:.2f}s")
        
        # Log detailed results summary
        self.logger.info(f"Results summary:")
        self.logger.info(f"  Repositories with stars: {len(self.success_repos)}")
        self.logger.info(f"  Repositories not found/private: {len(self.not_found_repos)}")
        self.logger.info(f"  Repositories with errors: {len(self.error_repos)}")
        
        # Log top starred repositories found
        if self.success_repos:
            top_starred = sorted(self.success_repos, key=lambda x: x[1], reverse=True)[:10]
            self.logger.info("Top 10 most starred repositories processed:")
            for repo, stars in top_starred:
                self.logger.info(f"  {repo}: {stars:,} stars")
        
        return results
    
    def update_repo_stars_batch(self, repo_updates: List[Tuple[str, str, int]]):
        """Update star counts for multiple repositories in a single transaction."""
        try:
            db = sqlite3.connect(self.db_file)
            cur = db.cursor()
            
            total_rows_updated = 0
            batch_details = []
            
            for org_name, repo_name, stars in repo_updates:
                cur.execute("""
                    UPDATE pushes 
                    SET stars = ? 
                    WHERE repo_org = ? AND repo_name = ?
                """, (stars, org_name, repo_name))
                rows_updated = cur.rowcount
                total_rows_updated += rows_updated
                batch_details.append((f"{org_name}/{repo_name}", stars, rows_updated))
            
            db.commit()
            db.close()
            
            # Log batch update details
            self.logger.info(f"Database batch update completed: {len(repo_updates)} repositories, {total_rows_updated} rows updated")
            for repo, stars, rows in batch_details:
                self.logger.debug(f"  {repo}: {stars} stars → {rows} database rows updated")
            
            return total_rows_updated
            
        except sqlite3.Error as e:
            error_msg = f"Database batch update error: {e}"
            print(f"  ❌ {error_msg}")
            self.logger.error(error_msg)
            return 0
    
    def should_update_database(self, force: bool = False) -> bool:
        """Check if database should be updated based on time interval or force flag."""
        if force:
            return True
        
        current_time = time.time()
        time_since_last_update = current_time - self.last_db_update_time
        return time_since_last_update >= self.db_update_interval
    
    def save_progress_to_database(self, force: bool = False) -> int:
        """Save current progress to database and return number of records updated."""
        with self.updates_lock:
            if not self.pending_updates and not force:
                return 0
            
            if not self.should_update_database(force):
                return 0
            
            updates_to_save = list(self.pending_updates)  # Copy the list
            
            if not updates_to_save:
                return 0
            
            print(f"💾 Periodic database save: {len(updates_to_save)} repositories...")
            self.logger.info(f"Periodic database save initiated with {len(updates_to_save)} repositories")
            
            # Update database in batches
            total_rows_updated = 0
            for i in range(0, len(updates_to_save), self.batch_size):
                batch = updates_to_save[i:i + self.batch_size]
                rows_updated = self.update_repo_stars_batch(batch)
                total_rows_updated += rows_updated
                
                if len(updates_to_save) > self.batch_size:
                    batch_msg = f"Save batch {i//self.batch_size + 1}: Updated {rows_updated} database records"
                    print(f"   {batch_msg}")
                    self.logger.info(batch_msg)
            
            # Clear the pending updates and update timestamp
            self.pending_updates.clear()
            self.last_db_update_time = time.time()
            
            print(f"✅ Progress saved! Updated {total_rows_updated} database records")
            self.logger.info(f"Periodic database save completed: {total_rows_updated} records updated")
            
            return total_rows_updated
    
    def add_result_to_pending(self, result: RepoResult):
        """Add a successful result to pending database updates."""
        if result.success and result.stars is not None:
            with self.updates_lock:
                self.pending_updates.append((result.org, result.repo, result.stars))
    
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

def get_unique_repos_from_db(db_file: str) -> List[Tuple[str, str]]:
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
    """Main function to update the database with star counts using parallel processing."""
    global MAX_WORKERS, BATCH_SIZE
    
    # Parse command-line arguments
    parser = argparse.ArgumentParser(
        description='GitHub Repository Star Count Database Updater (Parallel Version)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  python %(prog)s
  python %(prog)s --db-file /path/to/custom.sqlite3
  
Environment Variables:
  GITHUB_TOKEN    GitHub API token for authentication (5000 requests/hour vs 60 unauthenticated)
        '''
    )
    parser.add_argument(
        '--db-file',
        default=DEFAULT_DB_FILE,
        help=f'Path to SQLite database file (default: {DEFAULT_DB_FILE})'
    )
    
    args = parser.parse_args()
    DB_FILE = args.db_file
    
    print("GitHub Repository Star Count Database Updater (Parallel Version)")
    print("=" * 65)
    print(f"Database: {DB_FILE}")
    print()
    
    # Initialize logging
    logger, log_filepath = setup_logging()
    logger.info("Starting GitHub Star Counter (Parallel Version)")
    logger.info(f"Configuration: Database={DB_FILE}")
    
    print(f"📝 Detailed logging enabled: {log_filepath}")
    print()
    
    # Check for GitHub token
    github_token = os.environ.get('GITHUB_TOKEN')
    if not github_token:
        warning_msg = "No GITHUB_TOKEN environment variable set. Parallel processing will be very slow without a token!"
        print(f"⚠️  Warning: {warning_msg}")
        print("   You may hit rate limits quickly (60 requests/hour vs 5000 requests/hour with token)")
        print("   Set your token with: $env:GITHUB_TOKEN='your_token_here'")
        print()
        logger.warning(warning_msg)
        
        response = input("Continue without token? This will be VERY slow! (y/N): ")
        if response.lower() != 'y':
            logger.info("User aborted due to no GitHub token")
            print("Aborted. Please set your GitHub token for optimal performance.")
            sys.exit(0)
    else:
        print("✓ GitHub token found - ready for high-speed parallel processing!")
        logger.info("GitHub token found and ready for high-speed processing")
    
    print()
    
    # Get repository count for optimal settings calculation
    print("Analyzing repository data...")
    repos_to_update = []
    try:
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        cursor.execute("""
            SELECT DISTINCT repo_org, repo_name 
            FROM force_push_commits 
            WHERE stars IS NULL OR stars = 0
        """)
        repos_to_update = cursor.fetchall()
        conn.close()
    except Exception as e:
        print(f"⚠️  Could not get repo count: {e}")
        logger.warning(f"Could not get repo count for optimization: {e}")
    
    # Calculate optimal settings based on system resources and repo count
    MAX_WORKERS, BATCH_SIZE = calculate_optimal_settings(github_token, len(repos_to_update))
    print()
    
    # Initialize parallel star counter with calculated settings
    star_counter = ParallelGitHubStarCounter(github_token, MAX_WORKERS, BATCH_SIZE, DB_FILE)
    
    # Test API access with a simple request
    print("Testing GitHub API access...")
    logger.info("Testing GitHub API access with octocat/Hello-World")
    test_result = star_counter.get_repo_stars_worker("octocat", "Hello-World")
    if test_result.success and test_result.stars is not None:
        print(f"✓ API test successful! octocat/Hello-World has {test_result.stars:,} stars")
        logger.info(f"API test successful! octocat/Hello-World has {test_result.stars:,} stars")
    else:
        error_msg = f"API test failed: {test_result.error_msg}"
        print(f"❌ {error_msg}")
        logger.error(error_msg)
        response = input("Continue anyway? (y/N): ")
        if response.lower() != 'y':
            logger.info("User aborted due to API test failure")
            print("Aborted.")
            sys.exit(1)
    print()
    
    # Setup database (add stars column if needed)
    star_counter.setup_database()
    
    # Get repositories that need updating
    print("\nFinding repositories that need star count updates...")
    logger.info("Querying database for repositories needing star count updates")
    repos_to_update = star_counter.get_repos_to_update()
    
    if not repos_to_update:
        print("✅ All repositories already have star counts!")
        logger.info("All repositories already have star counts - no work needed")
        
        # Show some statistics
        all_repos = get_unique_repos_from_db(DB_FILE)
        print(f"📊 Total unique repositories in database: {len(all_repos)}")
        logger.info(f"Total unique repositories in database: {len(all_repos)}")
        
        # Show a few examples with their star counts
        try:
            db = sqlite3.connect(DB_FILE)
            cur = db.cursor()
            
            print("\nTop 10 repositories by star count:")
            logger.info("Top 10 repositories by star count:")
            for row in cur.execute('SELECT DISTINCT repo_org, repo_name, stars FROM pushes WHERE stars IS NOT NULL ORDER BY stars DESC LIMIT 10;'):
                org, repo, stars = row
                repo_info = f"  {org}/{repo}: {stars:,} stars"
                print(repo_info)
                logger.info(repo_info.strip())
            
            db.close()
        except Exception as e:
            error_msg = f"Error showing examples: {e}"
            print(error_msg)
            logger.error(error_msg)
        
        return
    
    print(f"Found {len(repos_to_update)} repositories to update")
    print(f"Processing with {MAX_WORKERS} parallel workers")
    logger.info(f"Found {len(repos_to_update)} repositories to update with {MAX_WORKERS} workers")
    print()
    
    # Process repositories in parallel
    print("🚀 Starting parallel star count updates...")
    print("💡 Tip: Press Ctrl+C once for graceful shutdown, twice to force quit")
    print("-" * 50)
    
    try:
        results = star_counter.process_repos_parallel(repos_to_update)
        
        # Process results in batches
        print(f"\n💾 Updating database with {len(results)} results...")
        logger.info(f"Processing {len(results)} results for database update")
        
        # First, save any remaining pending updates from periodic saves
        remaining_pending = star_counter.save_progress_to_database(force=True)
        if remaining_pending > 0:
            print(f"📋 Also saved {remaining_pending} previously pending updates")
        
        batch_updates = []
        success_count = 0
        not_found_count = 0
        error_count = 0
        
        for result in results:
            if result.success and result.stars is not None:
                batch_updates.append((result.org, result.repo, result.stars))
                if result.stars == 0:
                    not_found_count += 1
                else:
                    success_count += 1
            else:
                error_count += 1
        
        # Update database in batches
        total_rows_updated = 0
        for i in range(0, len(batch_updates), BATCH_SIZE):
            batch = batch_updates[i:i + BATCH_SIZE]
            rows_updated = star_counter.update_repo_stars_batch(batch)
            total_rows_updated += rows_updated
            
            if len(batch_updates) > BATCH_SIZE:
                batch_msg = f"Batch {i//BATCH_SIZE + 1}: Updated {rows_updated} database records"
                print(f"   {batch_msg}")
                logger.info(batch_msg)
        
        print(f"✅ Database update completed! Updated {total_rows_updated} total records")
        logger.info(f"Database update completed: {total_rows_updated} total records updated")
        
    except KeyboardInterrupt:
        interrupt_msg = "Force interrupt detected (Ctrl+C pressed twice)"
        print(f"\n\n🛑 {interrupt_msg}")
        logger.error(interrupt_msg)
        
        # Try to get partial results if available
        try:
            success_count = sum(1 for r in results if r.success and r.stars and r.stars > 0)
            not_found_count = sum(1 for r in results if r.success and r.stars == 0)
            error_count = len(results) - success_count - not_found_count
        except:
            success_count = not_found_count = error_count = 0
            results = []
    
    except Exception as e:
        error_msg = f"Unexpected error during processing: {e}"
        print(f"\n❌ {error_msg}")
        logger.error(error_msg)
        results = []
        success_count = not_found_count = error_count = 0
    
    # Final summary
    print(f"\n{'='*65}")
    print("Final Summary:")
    print(f"✅ Repositories with stars: {success_count:,}")
    print(f"❌ Repositories not found/private: {not_found_count:,}")
    print(f"⚠️  Errors: {error_count:,}")
    print(f"📊 Total processed: {len(results):,}")
    
    # Log final summary
    logger.info("Final Summary:")
    logger.info(f"  Repositories with stars: {success_count:,}")
    logger.info(f"  Repositories not found/private: {not_found_count:,}")
    logger.info(f"  Errors: {error_count:,}")
    logger.info(f"  Total processed: {len(results):,}")
    
    if len(results) > 0:
        print(f"\n🎉 Parallel database update completed!")
        print("You can now query organizations by star count quickly using the database.")
        logger.info("Parallel database update completed successfully")
        
        # Show and log some quick stats
        try:
            db = sqlite3.connect(DB_FILE)
            cur = db.cursor()
            
            # Top 5 most starred repos
            print(f"\nTop 5 most starred repositories:")
            logger.info("Top 5 most starred repositories:")
            for row in cur.execute('SELECT DISTINCT repo_org, repo_name, stars FROM pushes WHERE stars > 0 ORDER BY stars DESC LIMIT 5;'):
                org, repo, stars = row
                repo_info = f"  {org}/{repo}: {stars:,} stars"
                print(repo_info)
                logger.info(repo_info.strip())
            
            db.close()
        except Exception as e:
            error_msg = f"Error showing final stats: {e}"
            print(error_msg)
            logger.error(error_msg)
    
    logger.info("GitHub Star Counter (Parallel Version) completed")
    print(f"\n📝 Detailed logs saved to: {log_filepath}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n🛑 Final interrupt - shutting down immediately")
        sys.exit(130)  # Standard exit code for Ctrl+C
    except Exception as e:
        print(f"\n💥 Unexpected error: {e}")
        sys.exit(1)
