"""
Force-Push Secret Scanner

This module scans GitHub organizations for leaked secrets in force-pushed commits.
It is designed to be used primarily as a library by the batch scanner script.

Main function: run_scanner() - called by force_push_secret_scanner.sh

For batch processing and parallel execution, use force_push_secret_scanner.sh instead
of calling this script directly.
"""
from __future__ import annotations

import sys
import sqlite3
import json
import tempfile
from datetime import timezone
import subprocess
import datetime as _dt
from collections import defaultdict, Counter
from pathlib import Path
from typing import Dict, List, Optional
import concurrent.futures
import threading
import time

# Stdlib additions
import logging
from contextlib import suppress
import shutil
import re
import os
import csv

# Cross-platform color support (Windows, Linux, macOS)
try:
    from colorama import init as colorama_init, Fore, Style
    colorama_init()
except ImportError:
    class _Dummy:
        def __getattr__(self, _):
            return ""
    Fore = Style = _Dummy()


# Thread-safe file writing
_file_lock = threading.Lock()
_findings_count = 0


def terminate(msg: str) -> None:
    """Exit the program with an error message (in red)."""
    print(f"{Fore.RED}[✗] {msg}{Style.RESET_ALL}")
    sys.exit(1)


class RunCmdError(RuntimeError):
    """Raised when an external command returns a non-zero exit status."""


def run(cmd: List[str], cwd: Path | None = None) -> str:
    """Execute *cmd* and return its *stdout* as *str*."""
    logging.debug("Running command: %s (cwd=%s)", " ".join(cmd), cwd or ".")
    try:
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=True,
            env=env,
            timeout=300,  # 5 minute timeout for git operations
        )
        return proc.stdout
    except subprocess.CalledProcessError as err:
        raise RunCmdError(
            f"Command failed ({err.returncode}): {' '.join(cmd)}\n{err.stderr.strip()}"
        ) from err
    except subprocess.TimeoutExpired as err:
        raise RunCmdError(f"Command timed out: {' '.join(cmd)}") from err


def scan_with_trufflehog(repo_path: Path, since_commit: str, branch: str) -> List[dict]:
    """Run trufflehog in git mode, returning the parsed JSON findings."""
    try:
        stdout = run([
            "trufflehog", "git", "--branch", branch, "--since-commit", since_commit,
            "--no-update", "--json", "--only-verified", "--concurrency", "4",
            "file://" + str(repo_path.absolute()),
            ])
        findings: List[dict] = []
        for line in stdout.splitlines():
            with suppress(json.JSONDecodeError):
                findings.append(json.loads(line))
        return findings
    except RunCmdError as err:
        print(f"[!] trufflehog execution failed: {err} — skipping this repository")
        return []


def to_year(date_val) -> str:
    """Return the four-digit year (YYYY) from *date_val* which can be an int (epoch)"""
    return _dt.datetime.fromtimestamp(int(date_val), tz=timezone.utc).strftime("%Y")


_SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
_EXPECTED_FIELDS = {"repo_org", "repo_name", "before", "timestamp"}


def _validate_row(input_org: str, row: dict, idx: int) -> tuple[str, str, int | str]:
    """Validate that *row* contains the required columns and return the tuple."""
    missing = _EXPECTED_FIELDS - row.keys()
    if missing:
        raise ValueError(f"Row {idx} is missing fields: {', '.join(sorted(missing))}")

    repo_org = str(row["repo_org"]).strip()
    repo_name = str(row["repo_name"]).strip()
    before = str(row["before"]).strip()
    ts = row["timestamp"]

    if not repo_org:
        raise ValueError(f"Row {idx} – 'repo_org' is empty")
    if repo_org != input_org:
        raise ValueError(f"Row {idx} – 'repo_org' does not match 'input_org': {repo_org} != {input_org}")
    if not repo_name:
        raise ValueError(f"Row {idx} – 'repo_name' is empty")
    if not _SHA_RE.fullmatch(before):
        raise ValueError(f"Row {idx} – 'before' does not look like a commit SHA")

    try:
        ts_int: int | str = int(ts)
    except Exception as exc:
        raise ValueError(f"Row {idx} – 'timestamp' must be int, got {ts!r}") from exc

    return repo_org, repo_name, before, ts_int


def _gather_from_iter(input_org: str, rows: List[dict]) -> Dict[str, List[dict]]:
    """Convert iterable rows into the internal repos mapping."""
    repos: Dict[str, List[dict]] = defaultdict(list)
    for idx, row in enumerate(rows, 1):
        try:
            repo_org, repo_name, before, ts_int = _validate_row(input_org, row, idx)
        except ValueError as ve:
            terminate(str(ve))

        url = f"https://github.com/{repo_org}/{repo_name}"
        repos[url].append({"before": before, "date": ts_int})
    if not repos:
        terminate("No force-push events found for that user – dataset empty")
    return repos


def gather_commits(input_org: str, events_file: Optional[Path] | None = None,
                   db_file: Optional[Path] | None = None) -> Dict[str, List[dict]]:
    """Return mapping of repo URL → list[{before, pushed_at}]."""
    if events_file is not None:
        if not events_file.exists():
            terminate(f"Events file not found: {events_file}")
        rows: List[dict] = []
        try:
            with events_file.open("r", encoding="utf-8", newline="") as fh:
                reader = csv.DictReader(fh)
                rows = list(reader)
        except Exception as exc:
            terminate(f"Failed to parse events file {events_file}: {exc}")
        return _gather_from_iter(input_org, rows)

    if db_file is None:
        terminate("You must supply --db-file or --events-file.")

    if not db_file.exists():
        terminate(f"SQLite database not found: {db_file}")

    try:
        with sqlite3.connect(db_file) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT repo_org, repo_name, before, timestamp FROM pushes WHERE repo_org = ?",
                (input_org,),
            )
            rows = [dict(r) for r in cur.fetchall()]
    except Exception as exc:
        terminate(f"Failed querying SQLite DB {db_file}: {exc}")

    return _gather_from_iter(input_org, rows)


def report(input_org: str, repos: Dict[str, List[dict]]) -> None:
    repo_count = len(repos)
    total_commits = sum(len(v) for v in repos.values())

    print(f"\n{Fore.CYAN}======= Force-Push Summary for {input_org} ======={Style.RESET_ALL}")
    print(f"{Fore.GREEN}Repos impacted : {repo_count}{Style.RESET_ALL}")
    print(f"{Fore.GREEN}Total commits  : {total_commits}{Style.RESET_ALL}\n")

    for repo_url, commits in repos.items():
        print(f"{Fore.YELLOW}{repo_url}{Style.RESET_ALL}: {len(commits)} commits")
    print()

    counter = Counter(to_year(c["date"]) for commits in repos.values() for c in commits)
    if counter:
        first_year = int(min(counter))
    else:
        first_year = _dt.date.today().year

    current_year = _dt.date.today().year

    print(f"{Fore.CYAN}Histogram:{Style.RESET_ALL}")
    for year in range(first_year, current_year + 1):
        year_key = f"{year:04d}"
        count = counter.get(year_key, 0)
        bar = "▇" * min(count, 40)
        if count > 0:
            print(f" {Fore.GREEN}{year_key}{Style.RESET_ALL} | {bar} {count}")
        else:
            print(f" {year_key} | ")
    print("=================================\n")


def _print_formatted_finding(finding: dict, repo_url: str) -> None:
    """Pretty-print a single TruffleHog *finding* for humans."""
    print(f"{Fore.GREEN}")
    print(f"✅ Found verified result 🐷🔑")
    print(f"Detector Type: {finding.get('DetectorName', 'N/A')}")
    print(f"Decoder Type: {finding.get('DecoderName', 'N/A')}")

    raw_val = finding.get('Raw') or finding.get('RawV2', '')
    print(f"Raw result: {Style.RESET_ALL}{raw_val}{Fore.GREEN}")

    print(f"Repository: {repo_url}.git")
    print(f"Commit: {finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {}).get('commit')}")
    print(f"Email: {finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {}).get('email') or 'unknown'}")
    print(f"File: {finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {}).get('file')}")
    print(f"Link: {repo_url}/commit/{finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {}).get('commit')}")
    print(f"Timestamp: {finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {}).get('timestamp')}")

    extra = finding.get('ExtraData') or {}
    for k, v in extra.items():
        key_str = str(k).replace('_', ' ').title()
        print(f"{key_str}: {v}")
    print(f"{Style.RESET_ALL}")


def identify_base_commit(repo_path: Path, since_commit: str) -> str:
    """Identify the base commit for the given repository and since_commit."""
    run(["git", "fetch", "origin", since_commit], cwd=repo_path)
    output = run(["git", "rev-list", since_commit], cwd=repo_path)

    for commit in output.splitlines():
        commit = commit.strip('\n')
        if run(["git", "branch", "--contains", commit, "--all"], cwd=repo_path):
            if commit != since_commit:
                return commit
            try:
                c = run(["git", "rev-list", commit + "~1", "-n", "1"], cwd=repo_path)
                return c.strip('\n')
            except RunCmdError:
                return ""
        continue
    return ""


def write_finding_to_file(finding: dict, findings_file: Path) -> None:
    """Thread-safe write of finding to JSON file."""
    global _findings_count

    with _file_lock:
        try:
            with open(findings_file, 'a', encoding='utf-8') as file:
                if _findings_count > 0:
                    file.write(',\n')
                json.dump(finding, file, indent=2, ensure_ascii=False)
            _findings_count += 1
        except Exception as e:
            print(f"    {Fore.RED}[✗] Failed to write finding to file: {e}{Style.RESET_ALL}")


def scan_single_repo(repo_data: tuple[str, List[dict]], findings_file: Path) -> tuple[str, int, int]:
    """Scan a single repository for secrets. Returns (repo_url, commits_scanned, findings_count)."""
    repo_url, commits = repo_data

    commit_counter = 0
    repo_findings = 0
    tmp_dir = tempfile.mkdtemp(prefix="gh-repo-")

    try:
        tmp_path = Path(tmp_dir)

        # Git performance optimizations
        git_config = [
            ["git", "config", "core.preloadindex", "true"],
            ["git", "config", "core.fscache", "true"],
            ["git", "config", "gc.auto", "0"],
            ["git", "config", "fetch.parallel", "8"],
        ]

        try:
            # Clone with optimizations
            run([
                "git", "clone",
                "--filter=blob:none",
                "--no-checkout",
                "--depth=100",  # Limit depth for faster clones
                repo_url + ".git", "."
            ], cwd=tmp_path)

            # Apply git optimizations
            for config_cmd in git_config:
                try:
                    run(config_cmd, cwd=tmp_path)
                except RunCmdError:
                    pass  # Continue if config fails

        except RunCmdError as err:
            return repo_url, 0, 0

        for c in commits:
            before = c["before"]
            if not _SHA_RE.fullmatch(before):
                continue

            commit_counter += 1

            try:
                since_commit = identify_base_commit(tmp_path, before)
            except RunCmdError as err:
                if "fatal: remote error: upload-pack: not our ref" in str(err):
                    continue
                else:
                    break

            findings = scan_with_trufflehog(tmp_path, since_commit=since_commit, branch=before)

            if findings:
                for f in findings:
                    f['repository_url'] = repo_url
                    f['scanned_commit'] = before
                    f['scan_timestamp'] = _dt.datetime.now().isoformat()

                    write_finding_to_file(f, findings_file)
                    repo_findings += 1
                    _print_formatted_finding(f, repo_url)

    finally:
        try:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        except OSError:
            pass

    return repo_url, commit_counter, repo_findings


def scan_commits(repo_user: str, repos: Dict[str, List[dict]], max_workers: int = 16, results_dir: Path = None) -> None:
    """Scan commits in parallel using ThreadPoolExecutor."""
    global _findings_count
    _findings_count = 0

    # Use results directory if provided, otherwise current directory
    if results_dir:
        results_dir.mkdir(exist_ok=True)
        findings_file = results_dir / f"verified_secrets_{repo_user}.json"
    else:
        findings_file = Path(f"verified_secrets_{repo_user}.json")

    # Initialize the JSON file
    try:
        with open(findings_file, 'w', encoding='utf-8') as f:
            f.write('[\n')
    except Exception as e:
        print(f"{Fore.RED}[✗] Failed to create findings file {findings_file}: {e}{Style.RESET_ALL}")
        return

    start_time = time.time()
    print(f"\n{Fore.CYAN}[>] Starting scan for {repo_user} with {max_workers} workers{Style.RESET_ALL}")

    total_repos = len(repos)
    total_commits_scanned = 0
    completed_repos = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Submit all repository scan tasks
        future_to_repo = {
            executor.submit(scan_single_repo, (repo_url, commits), findings_file): repo_url
            for repo_url, commits in repos.items()
        }

        # Process completed tasks
        for future in concurrent.futures.as_completed(future_to_repo):
            repo_url = future_to_repo[future]
            try:
                _, commits_scanned, repo_findings = future.result()
                total_commits_scanned += commits_scanned
                completed_repos += 1

                if completed_repos % 10 == 0 or completed_repos == total_repos:
                    elapsed = time.time() - start_time
                    print(f"    {Fore.BLUE}[Progress] {completed_repos}/{total_repos} repos completed in {elapsed:.1f}s{Style.RESET_ALL}")

            except Exception as exc:
                print(f"{Fore.RED}[✗] Repository {repo_url} generated an exception: {exc}{Style.RESET_ALL}")

    # Close the JSON array
    try:
        with open(findings_file, 'a', encoding='utf-8') as f:
            f.write('\n]')
    except Exception as e:
        print(f"{Fore.RED}[✗] Failed to close JSON array in {findings_file}: {e}{Style.RESET_ALL}")

    elapsed = time.time() - start_time
    print(f"\n{Fore.GREEN}[✓] Scan for {repo_user} completed in {elapsed:.1f} seconds{Style.RESET_ALL}")
    print(f"{Fore.GREEN}[✓] {total_repos} repositories processed{Style.RESET_ALL}")
    print(f"{Fore.GREEN}[✓] {total_commits_scanned} total commits scanned{Style.RESET_ALL}")

    if _findings_count > 0:
        print(f"{Fore.GREEN}[✓] {_findings_count} verified secrets saved to {findings_file}{Style.RESET_ALL}")
    else:
        print(f"{Fore.YELLOW}[i] No verified secrets found for {repo_user}{Style.RESET_ALL}")
        try:
            findings_file.unlink()
        except Exception:
            pass


def run_scanner(input_org: str, db_file: Optional[Path] = None, events_file: Optional[Path] = None,
                verbose: bool = False, max_workers: int = 16,
                results_dir: Optional[Path] = None) -> None:
    """Main scanner function called by the batch script.
    
    Args:
        input_org: GitHub username or organization to inspect
        db_file: Path to the SQLite database containing force-push events
        events_file: Path to a CSV file containing force-push events
        verbose: Enable verbose/debug logging
        max_workers: Maximum number of parallel workers for scanning
        results_dir: Directory to save results in
    """
    # Configure logging
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.WARNING,
        format="%(message)s",
    )
    
    # Gather commits from data source
    repos = gather_commits(input_org, events_file, db_file)
    report(input_org, repos)
    
    # Always scan for secrets
    scan_commits(input_org, repos, max_workers=max_workers, results_dir=results_dir)


def main() -> None:
    """Main function - now primarily used as a library by the batch scanner.
    
    Direct command-line usage is deprecated. Use force_push_secret_scanner.sh instead.
    Note: Scanning is always enabled - this tool always scans for secrets.
    """
    # Simple argument handling for backward compatibility
    if len(sys.argv) < 2:
        print("ERROR: This script is now designed to be called by force_push_secret_scanner.sh")
        print("Usage: bash force_push_secret_scanner.sh --help")
        sys.exit(1)
    
    # Extract organization from command line for basic compatibility
    input_org = sys.argv[1]
    
    # Check for basic flags
    verbose = "--verbose" in sys.argv or "-v" in sys.argv
    
    # Look for db-file argument
    db_file = None
    if "--db-file" in sys.argv:
        try:
            idx = sys.argv.index("--db-file")
            if idx + 1 < len(sys.argv):
                db_file = Path(sys.argv[idx + 1])
        except (ValueError, IndexError):
            pass
    
    # Look for events-file argument
    events_file = None
    if "--events-file" in sys.argv:
        try:
            idx = sys.argv.index("--events-file")
            if idx + 1 < len(sys.argv):
                events_file = Path(sys.argv[idx + 1])
        except (ValueError, IndexError):
            pass
    
    # Look for max-workers argument
    max_workers = 16
    if "--max-workers" in sys.argv:
        try:
            idx = sys.argv.index("--max-workers")
            if idx + 1 < len(sys.argv):
                max_workers = int(sys.argv[idx + 1])
        except (ValueError, IndexError):
            pass
    
    # Look for results-dir argument
    results_dir = None
    if "--results-dir" in sys.argv:
        try:
            idx = sys.argv.index("--results-dir")
            if idx + 1 < len(sys.argv):
                results_dir = Path(sys.argv[idx + 1])
        except (ValueError, IndexError):
            pass
    
    # Run the scanner
    run_scanner(
        input_org=input_org,
        db_file=db_file,
        events_file=events_file,
        verbose=verbose,
        max_workers=max_workers,
        results_dir=results_dir
    )


if __name__ == "__main__":
    for tool in ("git", "trufflehog"):
        if shutil.which(tool) is None:
            terminate(f"Required tool '{tool}' not found in PATH")
    main()