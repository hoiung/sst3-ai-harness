#!/usr/bin/env python3
"""
Pre-commit hook to check CLAUDE template propagation.
Prevents forgotten cross-repo updates when CLAUDE_TEMPLATE.md or CLAUDE.md changes.

BEHAVIOR:
    - Validates SST3 sections in CLAUDE.md match CLAUDE_TEMPLATE.md (blocks if mismatch)
    - Detects changes to CLAUDE_TEMPLATE.md or CLAUDE.md in staged files
    - If CLAUDE.md only: Warns that CLAUDE_TEMPLATE.md might need updating
    - If CLAUDE_TEMPLATE.md: Runs dry-run propagation and offers to propagate now
    - Validation is blocking, warnings are non-blocking

USAGE:
    Called automatically by pre-commit when template files are staged.
    Can also be run manually: python scripts/check-propagation.py
"""

import subprocess
import sys
from pathlib import Path

from sst3_utils import get_staged_files, KNOWN_REPOS, SST3UtilError, BOUNDARY_MARKER  # F2.13

# #577 K8 / fix review R49: propagate-template --all writes consumer files, so it refuses
# every tree but a clean worktree at origin's default branch; the remedy says where.
FLEET_RUN = ("python scripts/propagate-template.py --all   (in dotfiles after the Gate-2 "
             "merge, from a clean worktree at origin's default branch under .claude/worktrees/; "
             "it refuses any other tree, #577 K8)")

# Repositories to validate (relative to dotfiles parent directory).
# Sourced from sst3_utils.KNOWN_REPOS — single source of truth.
REPOS = KNOWN_REPOS


def check_template_changed():
    """
    Check if CLAUDE_TEMPLATE.md or CLAUDE.md is in staged files.

    Returns:
        Tuple of (template_changed: bool, dotfiles_claude_changed: bool)
    """
    try:
        staged = get_staged_files()
    except SST3UtilError as exc:
        print(f"[ERROR] check-propagation: {exc}", file=sys.stderr)
        sys.exit(1)
    template_changed = 'templates/CLAUDE_TEMPLATE.md' in staged
    dotfiles_claude_changed = 'CLAUDE.md' in staged
    return template_changed, dotfiles_claude_changed


def run_dry_run_propagation():
    """
    Run propagation script in dry-run mode to preview changes.

    Returns:
        Tuple of (success: bool, output: str)
    """
    script_dir = Path(__file__).parent.resolve()
    script = script_dir / 'propagate-template.py'

    try:
        result = subprocess.run(
            [sys.executable, str(script), '--all', '--dry-run'],
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.returncode == 0, result.stdout
    except subprocess.TimeoutExpired:
        return False, "[ERROR] Dry-run propagation timed out"
    except Exception as e:
        return False, f"[ERROR] Failed to run dry-run: {e}"



def extract_sst3_section(file_path):
    """
    Extract SST3 section from a CLAUDE file (everything above boundary marker).

    Args:
        file_path: Path to CLAUDE file

    Returns:
        List of lines in SST3 section, or None if file doesn't exist or no marker found
    """
    if not file_path.exists():
        return None

    try:
        content = file_path.read_text(encoding='utf-8')
        lines = content.splitlines()

        # Find boundary marker
        boundary_line = -1
        for i, line in enumerate(lines):
            if BOUNDARY_MARKER in line:
                boundary_line = i
                break

        if boundary_line == -1:
            return None

        # Return everything up to (but not including) the boundary marker line
        return lines[:boundary_line]

    except Exception as e:
        print(f"[ERROR] Failed to read {file_path}: {e}")
        return None


def validate_sst3_sections():
    """
    Validate that SST3 sections in all repos' CLAUDE.md match CLAUDE_TEMPLATE.md.

    Returns:
        Tuple of (valid: bool, mismatches: list of repo names)
    """
    script_dir = Path(__file__).parent.resolve()
    # #500 Stage 5 worktree-CWD fix: when invoked from .claude/worktrees/<wt>/,
    # dotfiles_root.parent resolves to .claude/worktrees/ (not ~/DevProjects/),
    # causing every cross-repo CLAUDE.md lookup to silently miss. Use
    # sst3_mirror_utils.resolve_main_clone_root (the env-immune /.claude/worktrees/
    # strip propagate-template.py uses post-#488) so parent_dir is always
    # the canonical DevProjects regardless of worktree state.
    sys.path.insert(0, str(script_dir))
    import sst3_mirror_utils as _smu  # noqa: E402
    # dotfiles#552 AC 3.2 — resolve the manifest FIRST, then derive the canonical
    # root from it. The prior order hand-counted `script_dir.parent.parent` and
    # built the manifest path from that, which assumed the NESTED canonical
    # layout; the FLATTENED public mirror is one level shallower, so the walk
    # overshot the repo root. `find_manifest()` already covers every layout x
    # (main clone / linked worktree) case and raises when there is none, so
    # reuse it rather than maintaining a second walk beside it (AP #10).
    manifest_path = _smu.find_manifest(script_dir)
    dotfiles_root = _smu.resolve_dotfiles_root(manifest_path)
    parent_dir = _smu.resolve_main_clone_root(manifest_path).parent

    template_path = dotfiles_root / 'SST3' / 'templates' / 'CLAUDE_TEMPLATE.md'

    # Extract template SST3 section
    template_section = extract_sst3_section(template_path)
    if template_section is None:
        print(f"[ERROR] Cannot extract SST3 section from {template_path}")
        return False, []

    mismatches = []

    # Check each repo
    for repo in REPOS:
        # #505: worktree-aware dotfiles self-row. Mirror propagate-template.py's
        # resolve_self_row_destination so the in-flight WORKTREE CLAUDE.md (which
        # carries the staged template edit being committed) is compared — not the
        # main clone's (still on master pre-merge), which would spuriously mismatch
        # the worktree template. Sibling-fix to the self-row gap propagate-template.py
        # already closed (dotfiles#495 FRAG-1 / AP #14d sibling-fix discipline).
        if repo == 'dotfiles':
            claude_path = _smu.resolve_self_row_destination(
                manifest_path, 'dotfiles', 'CLAUDE.md'
            )
        else:
            claude_path = parent_dir / repo / 'CLAUDE.md'

        if not claude_path.exists():
            print(f"[WARNING] {claude_path} not found, skipping validation")
            continue

        repo_section = extract_sst3_section(claude_path)

        if repo_section is None:
            print(f"[ERROR] Cannot extract SST3 section from {claude_path}")
            mismatches.append(repo)
            continue

        # Compare sections
        if repo_section != template_section:
            mismatches.append(repo)

    return len(mismatches) == 0, mismatches



def main():
    """Main entry point for pre-commit hook."""
    # CRITICAL: Validate SST3 sections match across all repos FIRST
    # This catches rogue modifications to the SST3-managed section
    print("\n" + "="*60)
    print("CLAUDE Template Validation")
    print("="*60)
    print("\nValidating SST3 sections across all repositories...")

    valid, mismatches = validate_sst3_sections()

    if not valid:
        template_changed, _ = check_template_changed()
        print("\n[ERROR] SST3 section mismatch detected!")
        print("\nThe following repositories have SST3 sections that don't match CLAUDE_TEMPLATE.md:")
        for repo in mismatches:
            print(f"   - {repo}")
        if template_changed:
            # A branch that edits the template always lands here, and K8 forbids the
            # consumer write before the merge (#577 Stage 5 fix review r2: the message
            # blamed a hand edit and named a fix that cannot unblock this commit).
            print("\n[CAUSE] This commit changes CLAUDE_TEMPLATE.md; consumers take it only")
            print("        after the Gate-2 merge (#577 K8), so they differ until then.")
            print("\n[FIX] On the branch, skip this hook by id with its reason in the commit")
            print("      message: SKIP=check-claude-template-propagation (gate-2-merge.md step 6).")
            print(f"      After the merge: {FLEET_RUN}")
        else:
            print("\n[CAUSE] Someone modified the SST3-managed section (above the boundary marker)")
            print("        instead of just the project-specific section.")
            print("\n[FIX] Run propagation to sync SST3 sections:")
            print(f"      {FLEET_RUN}")
            print("\n      Then review and commit the changes in each repository.")
        print("\n" + "="*60 + "\n")
        sys.exit(1)  # BLOCK commit - this is a critical error

    print("[OK] All SST3 sections match CLAUDE_TEMPLATE.md")
    print("="*60)

    # Continue with normal propagation checks
    template_changed, claude_changed = check_template_changed()

    if not template_changed and not claude_changed:
        # No relevant files changed - validation passed, allow commit
        sys.exit(0)

    print("\n" + "="*60)
    print("CLAUDE Template Change Detected")
    print("="*60)

    # Case 1: CLAUDE.md changed but not CLAUDE_TEMPLATE.md
    if claude_changed and not template_changed:
        print("\n[WARNING] You're committing CLAUDE.md changes.")
        print("   Did you also update CLAUDE_TEMPLATE.md?")
        print("\n   REMINDER:")
        print("   - CLAUDE_TEMPLATE.md is the SST3 master template")
        print("   - CLAUDE.md is the dotfiles instance")
        print("\n   If this is a project-specific dotfiles change, ignore this warning.")
        print("   If this is an SST3 template update, update CLAUDE_TEMPLATE.md instead.")
        print("\n" + "="*60 + "\n")
        sys.exit(0)  # Don't block commit

    # Case 2: CLAUDE_TEMPLATE.md changed (may or may not include CLAUDE.md)
    if template_changed:
        print("\n[OK] CLAUDE_TEMPLATE.md changed - checking propagation...\n")

        success, output = run_dry_run_propagation()

        if not success:
            print("[ERROR] Dry-run propagation failed. Check the script.")
            print("\n" + output)
            print("\n[WARNING] Commit will proceed, but please fix propagation manually:")
            print(f"   {FLEET_RUN}")
            print("\n" + "="*60 + "\n")
            sys.exit(0)  # Don't block commit even on failure

        # Show dry-run output
        print(output)

        # K8 refuses the write from any tree but a clean origin worktree, which a commit
        # that stages the template never is: offering it only led to a refusal.
        print("\n[REMINDER] Consumers take this after the Gate-2 merge:")
        print(f"   {FLEET_RUN}")
        print("\n" + "="*60 + "\n")
        sys.exit(0)

    # Exit 0 - warnings are non-blocking (validation already passed)
    sys.exit(0)


if __name__ == '__main__':
    main()
