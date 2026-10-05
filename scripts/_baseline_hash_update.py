#!/usr/bin/env python3
"""Recompute SHA256 baseline for SST3 wrapper-lane test fixtures (#447 Phase 4).

Walks `dotfiles/test-fixtures/`, computes SHA256 of every fixture file
(expected.json, run.sh, and every file under input/), and writes
`_baseline-hashes.json` at the test-fixtures root.

Pair with the `sst3-test-fixtures-locked` pre-commit hook, which compares
the live tree against the baseline and BLOCKS the commit on any divergence.
This exists to enforce the "fixtures expand only — never relax" policy
documented in `test-fixtures/README.md`.

Run after every fixture change:
    python3 scripts/_baseline_hash_update.py

Skips the `_known-broken-wrappers/` subtree intentionally — those files
should drift if pre-commit fixes get applied (they're frozen-by-policy
broken variants, not active fixtures).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
)
FIXTURES_DIR = REPO_ROOT / "SST3" / "test-fixtures"
BASELINE_FILE = FIXTURES_DIR / "_baseline-hashes.json"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _walk() -> dict[str, str]:
    # The files git would commit: tracked plus new-and-not-ignored. A gitignored
    # __pycache__/ that a local test run leaves in a fixture's input/ is not part
    # of the fixture; walking the disk counted it, so --check failed on that
    # machine only and a re-run wrote it into the baseline (#577 Stage 5).
    # git runs from the top: a commit hook gets GIT_DIR exported, and with GIT_DIR
    # set git takes the cwd as the top of the work tree, so from the fixtures dir
    # the root .gitignore was never read.
    prefix = FIXTURES_DIR.relative_to(REPO_ROOT).as_posix() + "/"
    listed = subprocess.run(  # sst3-sec: justified: fixed git argv, no shell, no caller input
        ["git", "ls-files", "-z", "--full-name", "--cached", "--others", "--exclude-standard",
         "--", prefix],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout
    out: dict[str, str] = {}
    for raw in sorted({p for p in listed.split(b"\0") if p}):
        rel = os.fsdecode(raw).removeprefix(prefix)
        if "/" not in rel or rel.startswith("_"):
            continue  # root files (this baseline, the README), _known-broken-wrappers, etc.
        f = FIXTURES_DIR / rel
        if f.is_file():  # an indexed file deleted from the work tree is reported as DELETED
            out[rel] = _sha256(f)
    return out


def main(argv: list[str]) -> int:
    # argparse, not `"--check" in argv`: any other argument (--help, a typo of --check)
    # rewrote the committed baseline instead of checking it (#577 Stage 5 fix review 2).
    parser = argparse.ArgumentParser(
        description="Write the SST3 test-fixture SHA256 baseline, or --check the tree against it.")
    parser.add_argument("--check", action="store_true",
                        help="compare the fixture tree with the recorded baseline; write nothing")
    check_only = parser.parse_args(argv).check
    actual = _walk()
    if check_only:
        if not BASELINE_FILE.exists():
            print(f"ERROR: baseline {BASELINE_FILE} missing — run without --check first", file=sys.stderr)
            return 2
        recorded = json.loads(BASELINE_FILE.read_text())
        baseline_hashes = recorded.get("hashes", {})
        added = sorted(set(actual) - set(baseline_hashes))
        removed = sorted(set(baseline_hashes) - set(actual))
        changed = sorted(
            k for k in set(actual) & set(baseline_hashes)
            if actual[k] != baseline_hashes[k]
        )
        if not (added or removed or changed):
            print("baseline OK — every fixture file matches recorded hash")
            return 0
        if added:
            print(f"NEW files (un-baselined): {added}", file=sys.stderr)
        if removed:
            print(f"DELETED files (baseline stale): {removed}", file=sys.stderr)
        if changed:
            print(f"MODIFIED files: {changed}", file=sys.stderr)
        print(
            "ERROR: fixture tree diverged from baseline. Re-run "
            "`python3 scripts/_baseline_hash_update.py` after reviewing "
            "the change. Per test-fixtures/README.md, assertion REDUCTIONS "
            "require an Issue + reviewer sign-off.",
            file=sys.stderr,
        )
        return 1
    payload = {
        "policy": "fixtures expand only — never relax. See test-fixtures/README.md.",
        "issue": 447,
        "phase": 4,
        "algo": "sha256",
        "hashes": actual,
    }
    BASELINE_FILE.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"baseline written: {len(actual)} file(s) hashed → {BASELINE_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
