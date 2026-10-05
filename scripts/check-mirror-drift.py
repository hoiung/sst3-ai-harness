#!/usr/bin/env python3
"""Mirror-side drift check for vendored SST3 files (Issue #418).

Runs as a pre-commit hook in SST3-AI-Harness, hoiboy-uk, ebay-seller-tool.
For each manifest-listed file:
  - deterministic mode: verify `transform(canonical) == mirror`
  - divergent mode: verify `sha256(mirror) == recorded_hash`

Graceful skip: if `../dotfiles/` not present (mirror cloned standalone),
print SKIP to stderr and exit 0. Matches existing secret-rules-drift /
voice-rules-drift pattern.

Byte-identical across canonical (dotfiles/SST3/scripts/) and every mirror
row this file carries in SST3/drift-manifest.json — the row set is the
authority; a hand-pinned count here rots on the next consumer onboard
(this line pinned the mirror count at 3 against a measured 20, #567).
A `cmp -s` self-drift hook in each mirror enforces byte-identity.

Staged-aware gate (Issue #492): a drifted mirror only BLOCKS a commit when
that mirror file is actually in the staged set. Drift on a file the commit
does not touch is surfaced as a WARNING (visibility kept) and the commit
proceeds — an unrelated content commit is no longer frozen by mid-migration
plumbing. `--strict` forces the legacy block-all behaviour and is used at
push / CI time so the repo-wide invariant is still enforced where it belongs.

Exit codes:
  0 — clean, gracefully skipped, or only non-staged drift (warned)
  1 — drift detected in a STAGED mirror file (or any drift under --strict)
  2 — manifest / config error
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Import the CANONICAL scrubber that carries the real private-term table (#507
# Stage-5 gap-fix for the #501 mechanism). `_private_term_table.py` is
# canonical-only by design (#501 — the 62 private-term pairs never ship inside a
# public mirror), so the vendored `sst3_mirror_utils.py` in a mirror clone loads
# an EMPTY table and its `transform()` silently SKIPS `private_term_scrub`. That
# made `transform(canonical)` here diverge from what propagate-mirrors actually
# wrote (which DID scrub), so every private-term-bearing mirror file was flagged
# as false "drift" and blocked the commit. This script already requires the
# sibling `../dotfiles` canonical clone to read canonical content, so sourcing
# the table from the first scripts dir that actually has it is consistent and
# reproduces the exact transform the writer applied. Standalone mirror clones
# with no sibling dotfiles find no table and gracefully SKIP below as before.
# The second candidate below is CWD-RELATIVE, which is the bug #552 Ralph round 10
# surfaced: run the FLAT self-row copy (scripts/check-mirror-drift.py) from a linked
# worktree — the context CLAUDE.md mandates for all Stage-4 work — and neither
# candidate resolves. `Path(__file__).parent` is `<root>/scripts`, which never holds
# the canonical-only table, and `cwd/../dotfiles/SST3/scripts` points outside the
# worktree at a path that does not exist. The table is then silently absent,
# `private_term_scrub` degrades to a no-op, and every private-term-bearing file is
# reported as false drift — including by the `--repo <mirror> --strict` command this
# script now prints as its remediation hint. Measured: 6 false positives from the
# worktree, 0 from the canonical clone, for identical canonical text and transforms.
# The middle candidate fixes it by walking from THIS FILE to its sibling canonical
# tree, so resolution no longer depends on where the process was launched.
#
# dotfiles#577 Stage 5 (D1). Two more defects in the same lookup. (1) The consumer
# candidate was still cwd-relative, so from a consumer's linked worktree it named
# <repo>/.claude/worktrees/dotfiles and the table went missing the same way; it now
# walks from the MAIN clone (the same .git-file read as
# sst3_mirror_utils._main_clone_root, inlined because it must run before that
# module is imported). (2) The directory was INSERTED at sys.path[0], so a consumer
# imported the SIBLING CLONE's sst3_mirror_utils, not its own vendored copy: with
# that clone on a stale branch the consumer ran stale logic, and the stale-canon
# refusal below could never fire. It is now APPENDED, so this repo's own modules
# win and only the canonical-only table comes from the sibling.
_here = Path(__file__).resolve().parent


def _main_clone_root(start: Path) -> Path:
    for cur in (start, *start.parents):
        dotgit = cur / ".git"
        if dotgit.is_dir():
            return cur
        if dotgit.is_file():
            try:
                txt = dotgit.read_text(encoding="utf-8").strip()
            except (OSError, UnicodeDecodeError):
                return cur
            gd = Path(txt.split(":", 1)[1].strip()) if txt.startswith("gitdir:") else None
            if gd is not None and not gd.is_absolute():
                gd = (cur / gd).resolve()
            if gd is not None and gd.parent.name == "worktrees" and gd.parent.parent.name == ".git":
                return gd.parent.parent.parent
            return cur
    return start


for _cand in (
    _here,
    _here.parent / "SST3" / "scripts",
    _main_clone_root(_here).parent / "dotfiles" / "SST3" / "scripts",
):
    if (_cand / "_private_term_table.py").exists():
        if str(_cand.resolve()) not in sys.path:
            sys.path.append(str(_cand.resolve()))
        break

try:
    import sst3_mirror_utils as smu
    from sst3_block_utils import (
        duplicate_hook_ids_problem, extract_managed_block, find_boundary_lines, strip_marker_lines,
    )
except ImportError as exc:  # pragma: no cover — only hits if script is run standalone
    print(
        f"ERROR: cannot import sst3_mirror_utils / sst3_block_utils "
        f"(must be in same dir): {exc}",
        file=sys.stderr,
    )
    sys.exit(2)


def _staged_paths() -> set[str] | None:
    """Return repo-root-relative paths staged in the index.

    Scopes the drift gate (#492): a drifted mirror only blocks the commit
    when it is itself staged. Returns None if the staged set cannot be
    determined (no git / not a work tree) — the caller then fails safe to
    the strict block-all behaviour rather than silently weakening the gate.
    """
    try:
        # -z (#577 Stage 5 R62, the S15 class): git C-quotes a name holding a quote,
        # a backslash or a non-ASCII byte without it, and the quoted string never
        # matched the manifest path, so a staged drifted mirror only warned.
        out = subprocess.run(  # sst3-sec: justified: fixed git argv, no shell, no caller input
            ["git", "diff", "--cached", "--name-only", "-z"],
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return {os.fsdecode(name) for name in out.stdout.split(b"\0") if name}


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check vendored SST3 files for drift vs canonical dotfiles.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Override manifest path (default: auto-discover).",
    )
    parser.add_argument(
        "--repo",
        type=str,
        default=None,
        help="Scope check to one mirror repo (e.g. SST3-AI-Harness).",
    )
    parser.add_argument(
        "--file",
        type=str,
        default=None,
        help="Scope check to one canonical file path.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print per-file status to stderr.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress success output (errors still printed).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help=(
            "Block on ANY drift regardless of staged set (legacy behaviour). "
            "Use at push / CI time for repo-wide enforcement."
        ),
    )
    parser.add_argument(
        "--require-checked",
        action="store_true",
        help=(
            "Fail (exit 1) if ZERO file-mirror pairs were checked. Without this, "
            "a --repo whose clone is absent -- CI, a fresh machine, a typo -- "
            "prints 'OK: 0 ... file(s) checked' and exits 0, so wiring this "
            "script as a gate for a repo that is not present yields a guard "
            "that silently passes forever (dotfiles#552). Use it wherever the "
            "exit code is load-bearing."
        ),
    )
    parser.add_argument(
        "--managed-blocks",
        action="store_true",
        help=(
            "Check `managed_blocks[]` (paired-marker pre-commit blocks) "
            "instead of `vendored_files[]`. Issue #493 AC 1.7. Same "
            "staged-aware gate (#492) — drift on a non-staged target is a "
            "warning, drift on a staged target blocks (unless --strict)."
        ),
    )
    parser.add_argument(
        "--canon-current",
        action="store_true",
        help=(
            "Only check that the sibling ../dotfiles clone is on origin's "
            "default branch, neither behind nor ahead of it, with no uncommitted "
            "tracked changes (dotfiles#577 D1, R44); exit 0 and "
            "print the clone path on stdout if it is, 2 with the reason if not. "
            "Consumer hooks that execute dotfiles scripts run this first, from "
            "their own vendored copy, and run the scripts from the printed path."
        ),
    )
    return parser.parse_args(argv)


def _check_managed_block_drift(
    manifest_path: Path,
    entry: dict,
    mirror: dict,
    canonical_text: str,
) -> tuple[bool, str]:
    """Return (has_drift, detail) for one managed_blocks entry × mirror.

    Drift = the bytes BETWEEN the marker lines in the target file do not
    match the transformed canonical (after substitute_repo_slug etc.) with
    the canonical's own marker lines stripped. Missing markers = drift
    (first-apply needed). Exactly-one-marker = drift (corruption signal).
    Issue #493 AC 1.7.
    """
    marker_start: str = entry["marker_start"]
    marker_end: str = entry["marker_end"]
    target_path = smu.resolve_self_row_destination(manifest_path, mirror["repo"], mirror["path"])
    if not target_path.is_file():
        return True, f"{mirror['repo']}/{mirror['path']}: target file missing"

    target_text = target_path.read_text(encoding="utf-8")
    ctx = {
        "repo": mirror["repo"],
        "canonical": entry["canonical"],
        "path": mirror["path"],
    }
    transformed = smu.apply_transforms(
        canonical_text, mirror.get("transforms", []), ctx
    )
    # Strip the canonical template's own marker lines so we compare body-to-body.
    # Stage 5 DEDUP-1 (L1-F): uses public strip_marker_lines helper now (was
    # duplicated inline here + in propagate-block.py:79-92 pre-fix).
    expected_body = strip_marker_lines(transformed, marker_start, marker_end)
    expected_body_normalised = expected_body.strip("\n")

    try:
        start, end = find_boundary_lines(target_text, marker_start, marker_end)
    except ValueError as exc:
        return True, f"{mirror['repo']}/{mirror['path']}: marker error: {exc}"
    if start == -1 and end == -1:
        return True, (
            f"{mirror['repo']}/{mirror['path']}: managed-block markers absent "
            f"(first-apply needed — {smu.fleet_apply_hint('propagate-block.py')})"
        )
    if start == -1 or end == -1:
        return True, (
            f"{mirror['repo']}/{mirror['path']}: corrupted file — found one "
            f"marker but not both (start={start} end={end})"
        )

    # #577 Stage 5 R45/R53: the body can match while a hand-written copy of one of its
    # hooks still runs beside it; nothing reported that.
    dup = duplicate_hook_ids_problem(target_text, marker_start, marker_end)
    if dup:
        return True, f"{mirror['repo']}/{mirror['path']}: {dup}"

    actual_body = extract_managed_block(target_text, marker_start, marker_end) or ""
    actual_body_normalised = actual_body.strip("\n")
    if actual_body_normalised != expected_body_normalised:
        return True, (
            f"{mirror['repo']}/{mirror['path']}: managed-block content drifts "
            f"from canonical ({smu.fleet_apply_hint('propagate-block.py')})"
        )
    return False, ""


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    # Locate manifest. Graceful skip if dotfiles not present.
    try:
        manifest_path = args.manifest if args.manifest else smu.find_manifest()
    except smu.ManifestError as exc:
        if args.canon_current:
            print(f"ERROR: dotfiles not found, canon not checked ({exc})", file=sys.stderr)
            return smu.EXIT_CONFIG
        print(
            f"SKIP: dotfiles not found — drift check skipped ({exc})",
            file=sys.stderr,
        )
        return smu.EXIT_OK

    # dotfiles#577 D1: a stale sibling dotfiles clone is not the canon. Refuse
    # loudly instead of reporting false drift with a remedy that reverts canon.
    problem = smu.sibling_canon_problem(manifest_path)
    if problem:
        print(f"ERROR: {problem}", file=sys.stderr)
        return smu.EXIT_CONFIG
    if args.canon_current:
        # stdout carries the clone path alone, so a hook can run its scripts from it.
        root = smu.resolve_dotfiles_root(manifest_path)
        print(root)
        if not args.quiet:
            print(f"OK: canon current ({root})", file=sys.stderr)
        return smu.EXIT_OK

    try:
        manifest = smu.load_manifest(manifest_path)
    except smu.ManifestError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return smu.EXIT_CONFIG

    # Staged-aware gate (#492). When not --strict, a drifted mirror only
    # blocks the commit if its path is in the staged set. None == cannot
    # determine staged set -> fail safe to block-all (do not weaken the gate).
    staged = None if args.strict else _staged_paths()

    checked = 0
    drifted: list[tuple[str, str]] = []  # (mirror_path, detail)
    canonical_cache: dict[str, str] = {}

    # --managed-blocks: iterate managed_blocks[] instead of vendored_files[].
    # Issue #493 AC 1.7 — same staged-aware semantics as vendored mode.
    if args.managed_blocks:
        for entry, mirror in smu.iter_managed_block_entries(
            manifest, repo_filter=args.repo, file_filter=args.file
        ):
            checked += 1
            canonical_rel = entry["canonical"]
            canonical_text = canonical_cache.get(canonical_rel)
            if canonical_text is None:
                canonical_path = smu.resolve_canonical(manifest_path, canonical_rel)
                if not canonical_path.is_file():
                    print(
                        f"ERROR: canonical block template missing: {canonical_path}",
                        file=sys.stderr,
                    )
                    return smu.EXIT_CONFIG
                canonical_text = canonical_path.read_text(encoding="utf-8")
                canonical_cache[canonical_rel] = canonical_text
            try:
                has_drift, detail = _check_managed_block_drift(
                    manifest_path, entry, mirror, canonical_text
                )
            except smu.ManifestError as exc:
                print(f"ERROR: {exc}", file=sys.stderr)
                return smu.EXIT_CONFIG
            if has_drift:
                drifted.append((mirror["path"], detail))
            elif args.verbose:
                print(f"OK: {mirror['repo']}/{mirror['path']}", file=sys.stderr)

        # Reuse the existing emit-and-exit block below.
        return _emit_and_exit(drifted, checked, staged, args)

    for entry, mirror in smu.iter_mirror_entries(
        manifest, repo_filter=args.repo, file_filter=args.file
    ):
        try:
            text = canonical_cache.get(entry["canonical"])
            if text is None and not mirror.get("divergent"):
                canonical_path = smu.resolve_canonical(manifest_path, entry["canonical"])
                if canonical_path.is_file():
                    text = canonical_path.read_text(encoding="utf-8")
                    canonical_cache[entry["canonical"]] = text
            has_drift, detail = smu.check_mirror_drift(
                manifest_path, entry, mirror, canonical_text=text
            )
        except smu.ManifestError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return smu.EXIT_CONFIG
        checked += 1
        if has_drift:
            drifted.append((mirror["path"], detail))
        elif args.verbose:
            print(f"OK: {mirror['repo']}/{mirror['path']}", file=sys.stderr)

    return _emit_and_exit(drifted, checked, staged, args)


def _emit_and_exit(
    drifted: list[tuple[str, str]],
    checked: int,
    staged: set[str] | None,
    args,
) -> int:
    """Shared staged-aware emit-and-exit logic for both vendored_files
    and managed_blocks modes (AC 1.7 — preserves #492 staged gate)."""
    if drifted:
        if args.strict or staged is None:
            blocking = drifted
            unstaged: list[tuple[str, str]] = []
        else:
            blocking = [(p, d) for (p, d) in drifted if p in staged]
            unstaged = [(p, d) for (p, d) in drifted if p not in staged]

        for _, detail in unstaged:
            print(f"WARNING: {detail}", file=sys.stderr)
        for _, detail in blocking:
            print(f"ERROR: {detail}", file=sys.stderr)

        if blocking:
            why = "(--strict block-all)" if args.strict else "and STAGED"
            # #577 R49: say WHERE the sync runs; the consumer writers refuse any tree
            # but a clean origin worktree, the dotfiles self-row writes this checkout.
            if args.repo == "dotfiles" and not args.managed_blocks:
                sync_hint = smu.SELF_ROW_APPLY_HINT[0].upper() + smu.SELF_ROW_APPLY_HINT[1:] + "."
            else:
                tool = "propagate-block.py" if args.managed_blocks else "propagate-mirrors.py"
                hint = smu.fleet_apply_hint(tool)
                sync_hint = hint[0].upper() + hint[1:] + "."
            print(
                f"\n{len(blocking)} mirrored file(s) drifted {why} out of "
                f"{checked} checked. {sync_hint}",
                file=sys.stderr,
            )
            return smu.EXIT_DRIFT

        # Scope this hint to what is ACTUALLY wired. It previously read "push/CI
        # --strict still enforces repo-wide", which named a safety net that does
        # not exist: every wired invocation passes --repo dotfiles
        # (.pre-commit-config.yaml:454,461,469,476) and no GitHub workflow
        # references a mirror repo at all, so nothing downstream re-checks the
        # repo this run just skipped. Telling an operator a later gate will catch
        # something it never sees is the same defect class as a remediation hint
        # naming a file that does not exist (#552 Ralph round 8) — the message is
        # trusted precisely because nobody re-runs it. State the command that does
        # enforce it, so the claim is executable rather than reassuring.
        # Print the command that ACTUALLY enforces. When --repo was passed, scope
        # to it; otherwise omit the filter entirely — `--strict` with no --repo
        # checks every mirror (the default). An earlier version printed
        # `--all-repos` here, a flag this script's argparse does not define, so
        # following the hint literally exited 2 "unrecognized argument" — the exact
        # remediation-hint-names-a-thing-that-does-not-exist defect the block above
        # warns against, committed one line down (#552 Stage 5).
        enforce_scope = f"--repo {args.repo} " if args.repo else ""
        tool = "propagate-block.py" if args.managed_blocks else "propagate-mirrors.py"
        sync = (f"run in this dotfiles checkout: python SST3/scripts/{tool} --apply --repo dotfiles"
                if args.repo == "dotfiles" else smu.fleet_apply_hint(tool))
        print(
            f"\n{len(unstaged)} mirrored file(s) drifted but NOT staged "
            f"(out of {checked} checked) — surfaced as warnings, commit "
            f"allowed. To sync: {sync}. "
            f"NOTE: no push/CI gate re-checks this; to enforce it now run "
            f"`python3 {Path(smu.propagate_tool_path()).parent / 'check-mirror-drift.py'} "
            f"{enforce_scope}--strict`, which exits non-zero on any drifted or "
            f"MISSING mirror file, staged or not.",
            file=sys.stderr,
        )
        return smu.EXIT_OK

    scope = f"repo={args.repo}" if args.repo else "all mirrors"
    mode = "managed-blocks" if args.managed_blocks else "vendored"
    if checked == 0 and getattr(args, "require_checked", False):
        print(
            f"ERROR: 0 {mode} file(s) checked ({scope}) — nothing was verified. "
            f"The mirror clone is most likely absent, or --repo does not match "
            f"any manifest entry. Exiting non-zero because --require-checked was "
            f"passed: a gate that checks nothing must not report success.",
            file=sys.stderr,
        )
        return smu.EXIT_DRIFT
    if not args.quiet:
        print(
            f"OK: {checked} {mode} file(s) checked ({scope}), no drift.",
            file=sys.stderr,
        )
    return smu.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
