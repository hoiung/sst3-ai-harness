#!/usr/bin/env python3
"""
Cross-Repo Path Validation Prevention for SST3 (Issue #298)

Purpose:
- Prevent SST3 markdown files from using relative paths that break cross-repo references
- Ensure all SST3 file references use ../dotfiles/SST3/ prefix for discoverability
- Catch patterns like `SST3/`, `../templates/`, `../workflow/` that should be `../dotfiles/SST3/...`

Problem Solved:
When SST3 docs reference other SST3 files using repo-relative paths (e.g., `workflow/...`),
those paths work from dotfiles repo but BREAK from other repos (<consumer-public-1>, <consumer-public-2>).
This makes SST3 features undiscoverable from other repos, violating the discoverability requirement.

Correct Pattern:
- From dotfiles repo: `workflow/WORKFLOW.md` (repo-relative)
- From other repos: `../workflow/WORKFLOW.md` (cross-repo)
- SST3 docs should use: `../workflow/WORKFLOW.md` (works everywhere)

Exceptions:
- CLAUDE_TEMPLATE.md: Intentionally uses repo-relative paths (template for other repos)
- Code blocks showing "wrong" examples (prefixed with ❌ or "DON'T:")
- Paths already using `../dotfiles/SST3/` (correct format)
- Flattened standalone public mirror (MIRROR-CONTRACT.md at the content root):
  the whole check is skipped — sibling paths like `../standards/` are correct
  there, not cross-repo violations (dotfiles#553).

Execution-context matrix (c4:T68, dotfiles#577 AC 3.8):
  Every `bash|sh|source|python[3] <path>` whose path names `scripts/` or
  the `$SST3` resolver, and every `from SST3.scripts.<mod> import` (the bare
  form spelt as a module path), is resolved in the full matrix
  {dotfiles main, dotfiles worktree, consumer main, consumer worktree}
  × {execution, public mirror}. Execution: the path, resolved from that
  context's working directory, must reach that context's canon (a dotfiles
  worktree runs its own SST3 tree; the other three run the dotfiles main
  clone's). Public mirror: the invocation after the file's drift-manifest
  transform chain for each public mirror (sst3_utils.MIRROR_CLONES; a
  `divergent` hand-maintained mirror is not derived from the line and is not
  read) must not keep the operator's filesystem layout (`~/DevProjects`,
  `/home/<user>/`).
  Files the dotfiles repo alone runs (tests, fixtures, scripts/ docs,
  archives, research, metrics) need only the two dotfiles cells. The prefix
  rule and its exceptions (including `../dotfiles/SST3/` and the
  CLAUDE_TEMPLATE.md exclusion) do not exempt a line from the matrix, and a
  wrong-example marker does. The one form that passes every cell is the
  resolver defined in Leader.md / SST3-solo.md Guardrails: `bash $SST3/<script>`.

Usage:
  python scripts/check-crossrepo-paths.py                # Check for violations
  python scripts/check-crossrepo-paths.py --fix          # Show suggested fixes (dry-run)
  python scripts/check-crossrepo-paths.py --verbose      # Verbose output
  python scripts/check-crossrepo-paths.py --matrix-only FILE...  # Matrix only (no prefix rule)

Exit codes:
  0: No violations found
  1: Violations found (BLOCKS commit), or a file / the drift manifest could not be read
  2: No scan root exists (manual run, mis-resolved layout)
"""

import argparse
import posixpath
import re
import sys
from pathlib import Path
from typing import List, Dict, Tuple, Optional


# c4:T68 (dotfiles#577 AC 3.8) — the execution-context matrix.
#
# Issue #7 shipped five successive forms of one SST3 script invocation, each
# validated in the single context that motivated it: a bare `scripts/`
# path exits 127 in a consumer repo, `../dotfiles/SST3/` exits 127 from any
# worktree, a `$HOME`-anchored path resolves everywhere but reads the MAIN
# clone from a dotfiles worktree, and its `~/DevProjects` spelling survives the
# public-mirror transforms verbatim. The prefix rule in this file could see
# none of them; it treats `../dotfiles/SST3/` as the correct form. The matrix
# below resolves each invocation by path arithmetic over a modelled layout, so
# the verdict is computed rather than asserted per form.
_M_HOME = "/h"
_M_DOTFILES = "/h/DevProjects/dotfiles"
_M_CONSUMER = "/h/DevProjects/consumer"
_M_WORKTREE = ".claude/worktrees/wt"
# (context, working directory, the canon that context must run)
MATRIX_CONTEXTS: Tuple[Tuple[str, str, str], ...] = (
    ("dotfiles main", _M_DOTFILES, _M_DOTFILES),
    ("dotfiles worktree", f"{_M_DOTFILES}/{_M_WORKTREE}", f"{_M_DOTFILES}/{_M_WORKTREE}"),
    ("consumer main", _M_CONSUMER, _M_DOTFILES),
    ("consumer worktree", f"{_M_CONSUMER}/{_M_WORKTREE}", _M_DOTFILES),
)
MATRIX_ROWS = ("execution", "public mirror")
# The directories that hold an SST3 tree in the model.
_M_CANON_ROOTS = frozenset({_M_DOTFILES, f"{_M_DOTFILES}/{_M_WORKTREE}"})
# Files only the dotfiles repo runs need only its two cells.
DOTFILES_ONLY_PREFIXES = (
    "test-fixtures/", "tests/", "scripts/", "archive/",
    "SST3-metrics/", "docs/research/", "tests/",
)
DOTFILES_ONLY_CELLS = ("dotfiles main", "dotfiles worktree")

_INVOCATION_RE = re.compile(
    r"\b(?:bash|sh|source|python3?)\s+[\"']?"
    r"((?:\$\{?SST3\}?/|[^\s`'\"()|;&<>]*scripts/)[^\s`'\"()|;&<>]*)"
)
# `python3 -c "from SST3.scripts.<mod> import ..."` is the bare form spelt as
# a module path: it imports only where the working directory holds SST3/.
_MODULE_IMPORT_RE = re.compile(r"\bfrom\s+SST3\.scripts\.(\w+)\s+import\b")
_RESOLVER_RE = re.compile(r"\$\{?SST3\}?/+")
_HOME_RE = re.compile(r"(?:~|\$\{?HOME\}?)/")
# The operator's filesystem layout, which a public mirror must not carry.
_PRIVATE_LAYOUT_RE = re.compile(r"(?:~|\$\{?HOME\}?)/DevProjects\b|/home/[^/\s]+/")


def resolve_invocation(token: str, cwd: str) -> str:
    """Where `token` points when it runs from `cwd` in the modelled layout."""
    m = _RESOLVER_RE.match(token)
    if m:
        # The Leader.md / SST3-solo.md resolver: the local canon when the
        # working directory holds one, else the dotfiles clone under $HOME.
        base = f"{cwd}/SST3/scripts" if cwd in _M_CANON_ROOTS else f"{_M_DOTFILES}/SST3/scripts"
        return posixpath.normpath(f"{base}/{token[m.end():]}")
    m = _HOME_RE.match(token)
    if m:
        return posixpath.normpath(f"{_M_HOME}/{token[m.end():]}")
    if token.startswith("/"):
        return posixpath.normpath(token)
    return posixpath.normpath(f"{cwd}/{token}")


def execution_cell(token: str, cwd: str, canon: str) -> str:
    """`ok` when the invocation reaches `canon`, `wrong-canon` when it reaches
    another clone's SST3 tree, `missing` when it reaches nothing (exit 127)."""
    # A token that stops at the directory (`bash $SST3/<script>.sh`, where the
    # `<` ends the token) is a placeholder: judge the directory it names.
    target = resolve_invocation(token + "_" if token.endswith("/") else token, cwd)
    if target.startswith(f"{canon}/scripts/"):
        return "ok"
    if any(target.startswith(f"{root}/scripts/") for root in _M_CANON_ROOTS):
        return "wrong-canon"
    return "missing"


class CrossRepoPathChecker:
    """Validates cross-repo path format in SST3 markdown files."""

    def __init__(self, verbose: bool = False, matrix_only: bool = False):
        """
        Initialize path checker.

        Args:
            verbose: Enable verbose output
            matrix_only: Run only the execution-context matrix (c4:T68), not
                the `../dotfiles/SST3/` prefix rule — for files outside SST3/
                (`.claude/commands/`, `docs/guides/`, CLAUDE.md), where
                repo-relative doc references are the house style.
        """
        self.verbose = verbose
        self.matrix_only = matrix_only
        # Public-mirror transform chains per canonical path, loaded from the
        # drift manifest on the first invocation that needs one (c4:T68).
        self._mirror_chains: Optional[Dict[str, List[Tuple[str, List[str]]]]] = None
        # Layout-invariant root resolution (dotfiles#552 AC 3.2).
        #
        # `scripts/` sits directly under the SST3 content root in BOTH layouts:
        # the NESTED canonical one, where that root is the SST3 directory inside
        # the dotfiles repo, and the FLATTENED public mirror, where it is the
        # repository root itself. Either way the content root is this file's
        # grandparent -- an invariant, not a directory count.
        # (Deliberately phrased without a literal nested path: `path_scrub`
        # rewrites that token on the way into the mirror, which would collapse
        # the two sides of this comparison into the same string.)
        #
        # The prior `parents[2] / "SST3"` form counted levels instead. In the
        # mirror (one level shallower) that resolved to `<DevProjects>/SST3`,
        # which does not exist, so all four scan roots below silently vanished.
        # Combined with `pass_filenames: false` in the mirror's own
        # .pre-commit-config.yaml, the hook scanned ZERO files and exited 0 --
        # a fail-open gate, the exact class Phase 0 of this issue closes.
        _scripts_dir = Path(__file__).resolve().parent
        self.sst3_root = _scripts_dir.parent
        # Repo root, used only for display-relative paths. Probe for the `.git`
        # marker (a DIR in a main clone, a FILE in a linked worktree) rather than
        # counting parents, so the layout depth difference cannot reintroduce
        # the same off-by-one here.
        self.dotfiles_root = next(
            (p for p in _scripts_dir.parents if (p / ".git").exists()),
            self.sst3_root,
        )

        # Layout-aware guard (dotfiles#553). The flattened standalone public
        # mirror (SST3-AI-Harness) carries a MIRROR-CONTRACT.md at its root --
        # which is exactly the directory this checker resolves as `sst3_root`
        # there (the file's grandparent). Canonical/consumer repos NEVER carry
        # that marker. In the flattened mirror a sibling reference like
        # `../standards/` or `../workflow/` from a `reference/` file IS the
        # correct layout, not the `../dotfiles/SST3/`-prefix violation this
        # checker enforces -- the whole consumer-prefix contract is inapplicable
        # there. Detect the mirror and skip cleanly (see validate()) rather than
        # flagging dozens of correct, already-published sibling paths -- the
        # exact false positive that forced a SKIP= to publish the #552 mirror.
        self.is_flattened_mirror = (self.sst3_root / "MIRROR-CONTRACT.md").is_file()

        # Track violations
        self.violations: List[Dict] = []

        # dotfiles#565 AC 5.2. A file this gate could not READ used to return
        # zero violations, indistinguishable from a file it read and found
        # clean. Unreadable files are collected here and reported as their own
        # could-not-look channel, and they fail the run.
        self.probe_failures: List[str] = []

        # Patterns to catch (backticked paths referencing SST3 files)
        # Match backticked paths like `SST3/...`, `../templates/...`, etc.
        # Extended 2026-04-19 (#420 Phase 2 item 17) to cover blind spots:
        # - `../SST3/...` (leading `../` but missing `dotfiles/` prefix)
        # - `dotfiles/SST3/...` (dotfiles prefix but missing leading `../`)
        # Both slipped through the original bare-SST3 / ../<subdir> patterns.
        self.violation_patterns = [
            r'`SST3/(workflow|templates|reference|standards|scripts)/',
            r'`\.\./workflow/',
            r'`\.\./templates/',
            r'`\.\./reference/',
            r'`\.\./standards/',
            r'`\.\./scripts/',
            r'`\.\./SST3/',
            r'`dotfiles/SST3/',
        ]

        # Exception patterns (paths that are correct)
        self.exception_patterns = [
            r'`\.\./dotfiles/SST3/',  # Already correct format
            r'`SST3-metrics/',        # SST3-metrics folder (not SST3)
            r'`\.\./DevProjects/',    # DevProjects references
        ]

        # Files to exclude from validation
        self.excluded_files = {
            'CLAUDE_TEMPLATE.md',  # Template uses repo-relative paths intentionally
        }

    def log(self, message: str):
        """Log verbose output."""
        if self.verbose:
            print(f"  [DEBUG] {message}")

    def is_in_wrong_example_block(self, lines: List[str], line_idx: int) -> bool:
        """
        Check if the line is in a "wrong example" code block.

        Args:
            lines: All lines in the file
            line_idx: Current line index (0-based)

        Returns:
            True if line is in a wrong example block, False otherwise
        """
        # Look backwards for context markers (❌, "DON'T:", "BAD:", etc.)
        context_window = 5  # Lines to check before current line
        start_idx = max(0, line_idx - context_window)

        for i in range(start_idx, line_idx + 1):
            line = lines[i]
            # Check for wrong example markers
            if any(marker in line for marker in ['❌', '✗', "DON'T:", "BAD:", "WRONG:"]):
                self.log(f"Line {line_idx + 1} is in wrong example block (marker at line {i + 1})")
                return True

        return False

    def _public_mirror_chains(self) -> Optional[Dict[str, List[Tuple[str, str, List[str]]]]]:
        """(repo, path, transforms) of every public mirror, keyed by canonical
        path. None when the drift manifest could not be read: that is recorded
        as a probe failure, so the run fails instead of passing the mirror row
        it never looked at."""
        if self._mirror_chains is None:
            try:
                scripts_dir = Path(__file__).resolve().parent
                if str(scripts_dir) not in sys.path:
                    sys.path.insert(0, str(scripts_dir))
                import sst3_mirror_utils
                from sst3_utils import MIRROR_CLONES
                manifest = sst3_mirror_utils.load_manifest(
                    sst3_mirror_utils.find_manifest(scripts_dir)
                )
                chains: Dict[str, List[Tuple[str, str, List[str]]]] = {}
                for entry, mirror in sst3_mirror_utils.iter_mirror_entries(manifest):
                    # A `divergent` mirror is hand-maintained and pinned by
                    # sha256, so its text is not derived from this line; the
                    # mirror repo's own privacy gate reads it.
                    if mirror["repo"] in MIRROR_CLONES and not mirror.get("divergent"):
                        chains.setdefault(entry["canonical"], []).append(
                            (mirror["repo"], mirror["path"], mirror.get("transforms") or [])
                        )
                self._apply_transforms = sst3_mirror_utils.apply_transforms
                self._mirror_chains = chains
            except Exception as e:  # any failure = could not look at the mirror row
                self._mirror_chains = {}
                self._mirror_error = f"drift manifest unreadable for the public-mirror row: {e}"
                self.probe_failures.append(self._mirror_error)
                print(f"SST3_PROBE_FAILED: check-crossrepo-paths — could not look: "
                      f"{self._mirror_error}", file=sys.stderr)
        return None if getattr(self, "_mirror_error", None) else self._mirror_chains

    def mirror_cell(self, invocation: str, rel: str) -> str:
        """`leak` when a public mirror's transform chain keeps the operator's
        filesystem layout in the invocation, `ok` when none does, `n/a` when
        the file has no public mirror, `unknown` when the manifest is unreadable."""
        chains = self._public_mirror_chains()
        if chains is None:
            return "unknown"
        mirrors = chains.get(rel, [])
        if not mirrors:
            return "n/a"
        for repo, path, transforms in mirrors:
            published = self._apply_transforms(
                invocation, transforms, {"repo": repo, "canonical": rel, "path": path}
            )
            if _PRIVATE_LAYOUT_RE.search(published):
                return "leak"
        return "ok"

    def invocation_matrix(self, token: str, invocation: str, rel: str) -> Dict[Tuple[str, str], str]:
        """Every cell of {context} × {execution, public mirror} for one invocation."""
        mirror = self.mirror_cell(invocation, rel)
        cells: Dict[Tuple[str, str], str] = {}
        for name, cwd, canon in MATRIX_CONTEXTS:
            cells[("execution", name)] = execution_cell(token, cwd, canon)
            # One published text serves every context that reads the mirror.
            cells[("public mirror", name)] = mirror
        return cells

    def matrix_violations(self, line: str, line_num: int, rel: str) -> List[Dict]:
        """c4:T68 — one violation per invocation that fails a cell its file needs."""
        required = (DOTFILES_ONLY_CELLS if rel.startswith(DOTFILES_ONLY_PREFIXES)
                    else tuple(name for name, _, _ in MATRIX_CONTEXTS))
        found = []
        calls = [(m.group(1), m.group(0)) for m in _INVOCATION_RE.finditer(line)]
        calls += [(f"scripts/{m.group(1)}.py", m.group(0)) for m in _MODULE_IMPORT_RE.finditer(line)]
        for token, invocation in calls:
            cells = self.invocation_matrix(token, invocation, rel)
            failing = [f"{row}: {ctx} ({v})" for (row, ctx), v in cells.items()
                       if (row == "execution" and ctx in required and v != "ok")
                       or (row == "public mirror" and v == "leak")]
            if not failing:
                continue
            passing = [f"{row}: {ctx}" for (row, ctx), v in cells.items() if v == "ok"]
            tail = (token.split("scripts/", 1)[1] if "scripts/" in token
                    else _RESOLVER_RE.sub("", token, count=1))
            found.append({
                'file': rel,
                'line': line_num,
                'wrong_path': token,
                'correct_path': f"$SST3/{tail}",
                'line_content': line.strip(),
                'kind': 'matrix',
                'failing': failing,
                'passing': passing,
            })
        return found

    def check_file(self, file_path: Path) -> List[Dict]:
        """
        Check a single markdown file for cross-repo path violations.

        Args:
            file_path: Path to markdown file

        Returns:
            List of violations found
        """
        # The prefix-rule exclusion. The matrix (c4:T68) still runs on these
        # files: a template that propagates to every consumer is exactly where
        # an invocation must resolve in every cell.
        prefix_rule = not self.matrix_only and file_path.name not in self.excluded_files
        if not prefix_rule:
            self.log(f"Matrix only for {file_path.name}")

        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
                lines = content.split('\n')
        except Exception as e:
            # dotfiles#565 AC 5.2: record the could-not-look rather than
            # returning a clean-looking empty list.
            self.probe_failures.append(f"{file_path}: {e}")
            print(
                f"SST3_PROBE_FAILED: check-crossrepo-paths — could not look: "
                f"unreadable file {file_path}: {e}",
                file=sys.stderr,
            )
            return []

        violations = []
        # #406 Phase 9: pre-commit passes RELATIVE paths (e.g. SST3/foo.md);
        # `Path('SST3/foo.md').relative_to('/home/.../dotfiles')` raises
        # ValueError. Resolve to absolute first.
        relative_path = file_path.resolve().relative_to(self.dotfiles_root)

        for line_num, line in enumerate(lines, 1):
            # Skip if in wrong example block
            if self.is_in_wrong_example_block(lines, line_num - 1):
                continue

            # c4:T68 — before the prefix rule's exceptions, which accept
            # `../dotfiles/SST3/`, the form that exits 127 from any worktree.
            violations.extend(self.matrix_violations(line, line_num, relative_path.as_posix()))
            if not prefix_rule:
                continue

            # Check for exception patterns first (correct format)
            is_exception = False
            for exception_pattern in self.exception_patterns:
                if re.search(exception_pattern, line):
                    is_exception = True
                    break

            if is_exception:
                continue

            # Check for violation patterns
            for violation_pattern in self.violation_patterns:
                matches = re.finditer(violation_pattern, line)
                for match in matches:
                    # Extract the full path (until closing backtick)
                    # Pattern includes opening backtick, so match.start() is where backtick is
                    backtick_start = match.start()
                    backtick_end = line.find('`', match.end())

                    if backtick_end == -1:
                        continue

                    wrong_path = line[backtick_start + 1:backtick_end]

                    # Skip if already has ../dotfiles/ prefix
                    if wrong_path.startswith('../dotfiles/'):
                        continue

                    # Generate correct path
                    if wrong_path.startswith('SST3/'):
                        correct_path = f"../dotfiles/{wrong_path}"
                    elif wrong_path.startswith('../'):
                        # Paths like ../workflow/ should be ../workflow/
                        relative_part = wrong_path[3:]  # Remove ../
                        correct_path = f"../dotfiles/SST3/{relative_part}"
                    else:
                        correct_path = f"../dotfiles/SST3/{wrong_path}"

                    violations.append({
                        'file': str(relative_path),
                        'line': line_num,
                        'wrong_path': wrong_path,
                        'correct_path': correct_path,
                        'line_content': line.strip()
                    })

        return violations

    def check_all_files(self, files: Optional[List[Path]] = None) -> List[Dict]:
        """
        Check markdown files for cross-repo path violations.

        Args:
            files: Optional explicit file list (from pre-commit pass_filenames).
                   If None or empty, scans all SST3 doc directories (manual run).
                   dotfiles#406 F1.16: honor pre-commit pass_filenames instead
                   of always rescanning all 4 directories.

        Returns:
            List of all violations found
        """
        all_violations = []

        if files:
            self.log(f"Scanning {len(files)} file(s) from argv")
            for md_file in files:
                if not md_file.exists() or md_file.suffix != '.md':
                    continue
                self.log(f"Checking {md_file}")
                all_violations.extend(self.check_file(md_file))
            return all_violations

        self.log("Scanning all SST3 markdown directories (manual run)...")
        directories = [
            self.sst3_root / 'workflow',
            self.sst3_root / 'templates',
            self.sst3_root / 'reference',
            self.sst3_root / 'standards',
        ]

        # Fail-open guard (dotfiles#552 AC 3.2). If NONE of the scan roots exist
        # the loop below finds nothing and the check returns clean -- reporting
        # "no violations" for a tree it never read. A gate that cannot find its
        # own inputs must fail loudly, not silently pass.
        if not any(d.exists() for d in directories):
            print(
                "check-crossrepo-paths: none of the scan roots exist under "
                f"{self.sst3_root} ({', '.join(d.name for d in directories)}) -- "
                "refusing to report a vacuous PASS. This usually means the SST3 "
                "content root was mis-resolved for this repository layout.",
                file=sys.stderr,
            )
            sys.exit(2)

        for directory in directories:
            if not directory.exists():
                self.log(f"Directory not found: {directory}")
                continue

            for md_file in directory.glob('*.md'):
                self.log(f"Checking {md_file.relative_to(self.dotfiles_root)}")
                violations = self.check_file(md_file)
                all_violations.extend(violations)

        return all_violations

    def print_violations(self, violations: List[Dict], show_fixes: bool = False):
        """
        Print violations in a readable format.

        Args:
            violations: List of violations to print
            show_fixes: If True, show suggested fixes
        """
        if not violations:
            print("[OK] No cross-repo path violations found")
            return

        print(f"[FAIL] Found {len(violations)} cross-repo path violation(s):")
        print()

        # Group violations by file
        by_file = {}
        for v in violations:
            file = v['file']
            if file not in by_file:
                by_file[file] = []
            by_file[file].append(v)

        for file, file_violations in sorted(by_file.items()):
            print(f"File: {file}")
            for v in file_violations:
                print(f"  Line {v['line']}: `{v['wrong_path']}`")
                if v.get('kind') == 'matrix':
                    # c4:T68 — the matrix verdict is always shown: which cells fail is the finding.
                    print(f"    matrix FAILS: {'; '.join(v['failing'])}")
                    print(f"    matrix passes: {'; '.join(v['passing']) or 'none'}")
                if show_fixes:
                    print(f"    Should be: `{v['correct_path']}`")
                    print(f"    Context: {v['line_content'][:80]}...")
            print()

        if show_fixes:
            print("Suggested Fixes:")
            print("-" * 50)
            for file, file_violations in sorted(by_file.items()):
                print(f"\n{file}:")
                for v in file_violations:
                    print(f"  Line {v['line']}: Replace `{v['wrong_path']}` with `{v['correct_path']}`")
        else:
            print("Run with --fix to see suggested corrections")

    def validate(self, show_fixes: bool = False, files: Optional[List[Path]] = None) -> bool:
        """
        Run validation and report results.

        Args:
            show_fixes: If True, show suggested fixes
            files: Optional explicit file list from argv (pre-commit pass_filenames)

        Returns:
            True if no violations found, False otherwise
        """
        print("Cross-Repo Path Validation Check")
        print("=" * 50)
        print()

        if self.is_flattened_mirror:
            print(
                "[SKIP] MIRROR-CONTRACT.md present at the SST3 content root -- this "
                "is the flattened standalone public mirror, where sibling paths "
                "like `../standards/` and `../workflow/` ARE the correct layout, "
                "not a cross-repo violation. The ../dotfiles/SST3/ prefix contract "
                "applies only to canonical/consumer repos. Skipping."
            )
            self.violations = []
            return True

        violations = self.check_all_files(files=files)
        self.violations = violations

        self.print_violations(violations, show_fixes)

        # dotfiles#565 AC 5.2: a scan that could not read part of its input is
        # not a scan that found nothing there. Reported in its OWN labelled
        # block so it is never confused with a violation count.
        if self.probe_failures:
            print()
            print("PROBE FAILURES (could not look — this run is NOT clean):")
            for pf in self.probe_failures:
                print(f"  - {pf}")
            return False

        return len(violations) == 0


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Cross-Repo Path Validation Prevention for SST3',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python scripts/check-crossrepo-paths.py           # Check for violations
  python scripts/check-crossrepo-paths.py --fix     # Show suggested fixes
  python scripts/check-crossrepo-paths.py -v        # Verbose output
  python scripts/check-crossrepo-paths.py --matrix-only .claude/commands/Leader.md

Every SST3 script invocation is also checked in the matrix {dotfiles main,
dotfiles worktree, consumer main, consumer worktree} x {execution, public
mirror}; the form that passes every cell is `bash $SST3/<script>` (c4:T68).

Exit Codes:
  0: No violations found
  1: Violations found (blocks commit), or a file / the drift manifest could not be read
  2: No scan root exists (manual run)
        """
    )
    parser.add_argument(
        '--fix',
        action='store_true',
        help='Show suggested fixes for violations (dry-run, does not modify files)'
    )
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Enable verbose output'
    )
    parser.add_argument(
        '--matrix-only',
        action='store_true',
        help='Run only the execution-context matrix (c4:T68), not the '
             '../dotfiles/SST3/ prefix rule — for files outside SST3/'
    )
    parser.add_argument(
        'files', nargs='*',
        help='Optional file list (from pre-commit pass_filenames). '
             'If empty, scans all SST3 doc directories.'
    )

    args = parser.parse_args()

    file_list = [Path(f) for f in args.files] if args.files else None

    checker = CrossRepoPathChecker(verbose=args.verbose, matrix_only=args.matrix_only)
    success = checker.validate(show_fixes=args.fix, files=file_list)

    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
