from __future__ import annotations  # Postpone annotation evaluation for Python < 3.10 support

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

# Stdlib additions
import argparse
import logging
from contextlib import suppress
import shutil
import re
import os
import csv

# Cross-platform color support (Windows, Linux, macOS)
try:
    from colorama import init as colorama_init, Fore, Style

    colorama_init()  # enables ANSI on Windows terminals
except ImportError:  # graceful degradation – no colors

    class _Dummy:
        def __getattr__(self, _):
            return ""

    Fore = Style = _Dummy()


def terminate(msg: str) -> None:
    """Exit the program with an error message (in red)."""
    print(f"{Fore.RED}[✗] {msg}{Style.RESET_ALL}")
    sys.exit(1)


class RunCmdError(RuntimeError):
    """Raised when an external command returns a non-zero exit status."""


def run(cmd: List[str], cwd: Path | None = None) -> str:
    """Execute *cmd* and return its *stdout* as *str*.

    If the command exits non-zero, a ``RunCmdError`` is raised so callers can
    decide whether to abort or ignore.
    """

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
        )
        return proc.stdout
    except subprocess.CalledProcessError as err:
        raise RunCmdError(
            f"Command failed ({err.returncode}): {' '.join(cmd)}\n{err.stderr.strip()}"
        ) from err


def scan_with_trufflehog(repo_path: Path, since_commit: str, branch: str) -> List[dict]:
    """Run trufflehog in git mode, returning the parsed JSON findings."""
    try:
        stdout = run(
            [
                "trufflehog",
                "git",
                "--branch",
                branch,
                "--since-commit",
                since_commit,
                "--no-update",
                "--json",
                "--only-verified",
                "file://" + str(repo_path.absolute()),
            ],
        )
        findings: List[dict] = []
        for line in stdout.splitlines():
            with suppress(json.JSONDecodeError):
                findings.append(json.loads(line))
        return findings
    except RunCmdError as err:
        print(f"[!] trufflehog execution failed: {err} — skipping this repository")
        return []
        

# Utility: extract year from Unix epoch INT.
def to_year(date_val) -> str:  # type: ignore[override]
    """Return the four-digit year (YYYY) from *date_val* which can be an int (epoch)"""
    return _dt.datetime.fromtimestamp(int(date_val), tz=timezone.utc).strftime("%Y")

_SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")

############################################################
# Phase 1: Gather data from SQLite3 (default) or user-supplied CSV
############################################################

# Column names expected from SQLite3 / CSV export
_EXPECTED_FIELDS = {"repo_org","repo_name", "before", "timestamp"}


def _validate_row(input_org: str, row: dict, idx: int) -> tuple[str, str, int | str]:
    """Validate that *row* contains the required columns and return the tuple.

    Raises ``ValueError`` on validation failure so callers can abort early.
    """

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

    # BigQuery exports numeric INT64 as str when using CSV, accommodate both.
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


def gather_commits(
    input_org: str,
    events_file: Optional[Path] | None = None,
    db_file: Optional[Path] | None = None,
) -> Dict[str, List[dict]]:
    """Return mapping of repo URL → list[{before, pushed_at}].

    The data can be sourced either from:
    1. A CSV export (``--events-file``)
    2. The pre-built SQLite database downloaded via the Google Form (``--db-file``)

    Both sources expose the columns: repo_org, repo_name, before, timestamp.
    """

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

    # 2. SQLite path
    if db_file is None:
        terminate("You must supply --db-file or --events-file.")

    if not db_file.exists():
        terminate(f"SQLite database not found: {db_file}")

    try:
        with sqlite3.connect(db_file) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                """
                SELECT repo_org, repo_name, before, timestamp
                FROM pushes
                WHERE repo_org = ?
                """,
                (input_org,),
            )
            rows = [dict(r) for r in cur.fetchall()]
    except Exception as exc:
        terminate(f"Failed querying SQLite DB {db_file}: {exc}")

    return _gather_from_iter(input_org, rows)


############################################################
# Phase 2: Reporting
############################################################


def report(input_org: str, repos: Dict[str, List[dict]]) -> None:
    repo_count = len(repos)
    total_commits = sum(len(v) for v in repos.values())

    print(f"\n{Fore.CYAN}======= Force-Push Summary for {input_org} ======={Style.RESET_ALL}")
    print(f"{Fore.GREEN}Repos impacted : {repo_count}{Style.RESET_ALL}")
    print(f"{Fore.GREEN}Total commits  : {total_commits}{Style.RESET_ALL}\n")

    # per-repo counts
    for repo_url, commits in repos.items():
        print(f"{Fore.YELLOW}{repo_url}{Style.RESET_ALL}: {len(commits)} commits")
    print()

    # timeseries histogram (yearly) – include empty years
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


############################################################
# Phase 3: Secret scanning
############################################################

def _print_formatted_finding(finding: dict, repo_url: str) -> None:
    """Pretty-print a single TruffleHog *finding* for humans. Similar to TruffleHog's CLI output.
    """
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

    # Flatten any extra metadata returned by the detector
    extra = finding.get('ExtraData') or {}
    for k, v in extra.items():
        key_str = str(k).replace('_', ' ').title()
        print(f"{key_str}: {v}")
    print(f"{Style.RESET_ALL}")  # Blank line as separator between findings


def identify_base_commit(repo_path: Path, since_commit:str) -> str:
    """Identify the base commit for the given repository and since_commit."""    # fetch the since_commit, since our clone process likely missed it
    # note: this fetch will have no blobs, but that's fine b/c 
    # when we invoke trufflehog, it calls git log -p, which will fetch the blobs dynamically
    run(["git", "fetch", "origin", since_commit], cwd=repo_path)
    # get all commits reachable from the since_commit
    output = run(["git", "rev-list", since_commit], cwd=repo_path)
    # working backwards from the since_commit, we need to find the first commit that exists in any branch
    for commit in output.splitlines():
        #remove the newline character
        commit = commit.strip('\n')
        # Check if commit exists in any branch, if it does, we've found the base commit
        if run(["git", "branch", "--contains", commit, "--all"], cwd=repo_path):
            if commit != since_commit:
                return commit
            try:
                # if the commit is the same as the since_commit, we need to go back one commit to scan this commit
                # if there is no commit~1, then since_commit is the base commit and we need "" for trufflehog
                c = run(["git", "rev-list", commit + "~1", "-n", "1"], cwd=repo_path)
                return c.strip('\n')
            except RunCmdError as err: # need to handle 128 git errors
                return ""
        continue
    # if we get here, then the since_commit is not in any branch
    # which means it could be a force push of a whole new tree or similar
    # in this case, we need to scan the entire branch, so we return ""
    # note: The command below might be useful if we find an edge case 
    #       not covered by "" in the future.
    #       c = run(["git", "rev-list", "--max-parents=0", 
    #           since_commit, "-n", "1"], cwd=repo_path)
    #       return c.strip('\n')
    return ""


def scan_commits(repo_user: str, repos: Dict[str, List[dict]]) -> None:
    findings_file = Path("verified_secrets.json")
    findings_count = 0
    
    # Initialize the JSON file with an empty array
    try:
        with open(findings_file, 'w', encoding='utf-8') as f:
            f.write('[\n')
    except Exception as e:
        print(f"{Fore.RED}[✗] Failed to create findings file {findings_file}: {e}{Style.RESET_ALL}")
        return
    
    for repo_url, commits in repos.items():
        print(f"\n[>] Scanning repo: {repo_url}")

        commit_counter = 0
        skipped_repo = False

        tmp_dir = tempfile.mkdtemp(prefix="gh-repo-")
        try:
            tmp_path = Path(tmp_dir)
            try:
                # Partial clone with no blobs to save space and for speed
                run(
                    [
                        "git",
                        "clone",
                        "--filter=blob:none",
                        "--no-checkout",
                        repo_url + ".git",
                        ".",
                    ],
                    cwd=tmp_path,
                )
            except RunCmdError as err:
                print(f"[!] git clone failed: {err} — skipping this repository")
                skipped_repo = True
                continue

            for c in commits:
                before = c["before"]
                if not _SHA_RE.fullmatch(before):
                    print(f"  • Commit {before} – invalid SHA, skipping")
                    continue
                commit_counter += 1
                print(f"  • Commit {before}")
                try:
                    since_commit = identify_base_commit(tmp_path, before)
                except RunCmdError as err:
                    # If the commit was logged in GH Archive, but not longer exists in the repo network, then it was likely manually removed it.
                    # For more details, see: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository#:~:text=You%20cannot%20remove,rotating%20affected%20credentials.
                    if "fatal: remote error: upload-pack: not our ref" in str(err):
                        print("    This commit was likely manually removed from the repository network  — skipping commit")
                        continue
                    else:
                        print(f"    fetch/checkout failed: {err} — skipping entire repository")
                        skipped_repo = True
                        break  # Break out of the commit loop to skip the entire repository

                # Pass in the since_commit and branch values for trufflehog
                findings = scan_with_trufflehog(tmp_path, since_commit=since_commit, branch=before)
                
                if findings:
                    for f in findings:
                        # Add repo_url and commit info to the finding for context
                        f['repository_url'] = repo_url
                        f['scanned_commit'] = before
                        f['scan_timestamp'] = _dt.datetime.now().isoformat()
                        
                        # Write finding immediately to file
                        try:
                            with open(findings_file, 'a', encoding='utf-8') as file:
                                if findings_count > 0:
                                    file.write(',\n')
                                json.dump(f, file, indent=2, ensure_ascii=False)
                            findings_count += 1
                            print(f"    {Fore.CYAN}[>] Secret #{findings_count} written to {findings_file}{Style.RESET_ALL}")
                        except Exception as e:
                            print(f"    {Fore.RED}[✗] Failed to write finding to file: {e}{Style.RESET_ALL}")
                        
                        _print_formatted_finding(f, repo_url)
                else:
                    pass

        finally:
            # Attempt cleanup but suppress ENOTEMPTY race-condition errors
            try:
                shutil.rmtree(tmp_dir, ignore_errors=True)
            except OSError:
                print(f"    Error cleaning up temporary directory: {tmp_dir}")
                pass

        if skipped_repo:
            print("[!] Repo skipped due to errors")
        else:
            print(f"[✓] {commit_counter} commits scanned.")
    
    # Close the JSON array
    try:
        with open(findings_file, 'a', encoding='utf-8') as f:
            f.write('\n]')
    except Exception as e:
        print(f"{Fore.RED}[✗] Failed to close JSON array in {findings_file}: {e}{Style.RESET_ALL}")
    
    if findings_count > 0:
        print(f"\n{Fore.GREEN}[✓] {findings_count} verified secrets saved to {findings_file}{Style.RESET_ALL}")
    else:
        print(f"\n{Fore.YELLOW}[i] No verified secrets found to save{Style.RESET_ALL}")
        # Remove empty file if no findings
        try:
            findings_file.unlink()
        except Exception:
            pass


############################################################
# Entry point
############################################################
def main() -> None:
    args = parse_args()

    # Configure logging
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    events_path = Path(args.events_file) if args.events_file else None
    db_path = Path(args.db_file) if args.db_file else None

    repos = gather_commits(args.input_org, events_path, db_path)
    report(args.input_org, repos)
    
    if args.scan:
        scan_commits(args.input_org, repos)
    else:
        print("[✓] Exiting without scan.")


def parse_args() -> argparse.Namespace:
    """Parse and return CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Inspect force-push commit events from public GitHub orgs and optionally scan their git diff patches for secrets.",
    )
    parser.add_argument(
        "input_org",
        help="GitHub username or organization to inspect",
    )
    parser.add_argument(
        "--scan",
        action="store_true",
        help="Run a trufflehog scan on every force-pushed commit",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose / debug logging",
    )
    parser.add_argument(
        "--events-file",
        help="Path to a CSV file containing force-push events. 4 columns: repo_org, repo_name, before, timestamp",
    )
    parser.add_argument(
        "--db-file",
        help="Path to the SQLite database containing force-push events. 4 columns: repo_org, repo_name, before, timestamp",
    )
    return parser.parse_args()


if __name__ == "__main__":
    # Ensure required external tools are available early.
    for tool in ("git", "trufflehog"):
        if shutil.which(tool) is None:
            terminate(f"Required tool '{tool}' not found in PATH")
    main()