#!/usr/bin/env python3
"""
Auto-stage files in SST3-metrics, archive, and docs folders.
Ensures these files are always tracked and never left as untracked.
"""

import subprocess
import sys
from pathlib import Path

from sst3_limits import TRACKED_AUTOSTAGE_FOLDERS  # F1.14 single source of truth

# dotfiles#488 AC 3.1: the leader-feedback telemetry subtree is staged
# PER-FILE (only the discovered feedback file[s]) so a concurrent agent's
# in-flight feedback-<other>-<n>.md is NOT swept into this commit. Every
# OTHER path under SST3-metrics (notably .tier-a-auto-tick/ — the #477
# auto-tick sentinels) keeps whole-folder staging via the :(exclude)
# pathspec, which also still honours .gitignore for the now-untracked
# feedback-index.ndjson (the AC 2.2 index-not-staged invariant).
SCOPED_FEEDBACK_DIR = "SST3-metrics/leader-feedback"
# Flat telemetry files only. The strict filename/format check is the
# commit-stage feedback_parser.py hook (AC 3.2) — here a coarse glob is
# sufficient to decide ownership-scoped staging.
SCOPED_FEEDBACK_GLOB = "feedback-*.md"
# The folder whose leader-feedback subtree gets per-file scoping. The other
# TRACKED_AUTOSTAGE_FOLDERS entries (archive, docs) stay whole-folder.
SCOPED_PARENT_FOLDER = "SST3-metrics"


def _is_scoped_feedback(path: str) -> bool:
    """True iff `path` is a flat SST3-metrics/leader-feedback/feedback-*.md
    telemetry file (NOT _drafts/, NOT .sentinels/, NOT the gitignored
    index, NOT a nested path)."""
    p = path.replace("\\", "/")
    prefix = SCOPED_FEEDBACK_DIR + "/"
    if not p.startswith(prefix):
        return False
    rel = p[len(prefix):]
    return "/" not in rel and rel.startswith("feedback-") and rel.endswith(".md")


def get_untracked_and_modified_files(folders):
    """Get list of untracked and modified files in specified folders.

    Single git invocation per folder (was 2 — untracked + modified).
    """
    all_files = []

    for folder in folders:
        if not Path(folder).exists():
            continue

        try:
            # --others (untracked) + --modified in one call
            # -z (#577 Stage 5 S15): without it a name holding a quote, a backslash
            # or a non-ASCII byte came back C-quoted and `git add` was handed the
            # quoted string.
            result = subprocess.run(  # sst3-sec: justified: argv list, no shell; fixed git verb, folder from TRACKED_AUTOSTAGE_FOLDERS
                ["git", "ls-files", "-z", "--others", "--modified",
                 "--exclude-standard", "--", folder],
                capture_output=True,
                text=True,
                errors="surrogateescape",  # a raw non-UTF-8 name round-trips to `git add` (R10)
                check=True
            )
            all_files.extend(name for name in result.stdout.split('\0') if name)

        except subprocess.CalledProcessError as e:
            print(
                f"WARNING: git ls-files failed for {folder}: {e}",
                file=sys.stderr,
            )
            continue

    return list(set(all_files))  # Remove duplicates


def auto_stage_folders(folders):
    """Auto-stage files in the specified folders.

    AP #7 (dotfiles#406 F1.13): atomic-or-rollback. If any folder's
    `git add` fails partway through, reset all already-staged folders
    to avoid leaving the index in an inconsistent half-staged state.
    """
    files = get_untracked_and_modified_files(folders)

    if not files:
        return 0

    print("[pre-commit] Auto-staging files:")
    for file in sorted(files):
        # A name that is not UTF-8 holds lone surrogates (surrogateescape); printed as is it
        # raised UnicodeEncodeError on a strict stdout and nothing was staged (#577 Stage 5
        # fix review r2). The display form escapes those bytes; `git add` gets the real name.
        print("  " + file.encode("utf-8", "surrogateescape").decode("utf-8", "backslashreplace"))

    # Each appended item is the pathspec list of ONE `git add` invocation;
    # rollback (AP #7 atomic-or-rollback) resets the flattened union.
    staged: list[list[str]] = []

    def _add(pathspecs: list[str]) -> None:
        subprocess.run(
            ["git", "add", "--", *pathspecs],
            check=True,
            capture_output=True,
        )
        staged.append(pathspecs)

    for folder in folders:
        if not Path(folder).exists():
            continue
        try:
            if folder == SCOPED_PARENT_FOLDER:
                # #488 AC 3.1: whole-folder EXCEPT the leader-feedback
                # feedback-*.md files (preserves .tier-a-auto-tick/ #477
                # sentinels + honours .gitignore for the untracked index),
                # then per-file add ONLY this commit's own discovered
                # feedback file(s) — never a bystander's in-flight file.
                _add([
                    folder,
                    f":(exclude){SCOPED_FEEDBACK_DIR}/{SCOPED_FEEDBACK_GLOB}",
                ])
                owned = sorted(f for f in files if _is_scoped_feedback(f))
                if owned:
                    _add(owned)
            else:
                _add([folder])
        except subprocess.CalledProcessError as exc:
            flat = [spec for group in staged for spec in group]
            print(
                f"[ERROR] auto-stage: failed to stage {folder}: {exc}. "
                f"Rolling back {len(flat)} previously staged pathspec(s).",
                file=sys.stderr,
            )
            if flat:
                subprocess.run(
                    ["git", "reset", "HEAD", "--", *flat],
                    capture_output=True,
                )
            return 1

    return 0


def main():
    """Main entry point."""
    return auto_stage_folders(TRACKED_AUTOSTAGE_FOLDERS)


if __name__ == "__main__":
    sys.exit(main())
