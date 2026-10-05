#!/usr/bin/env python3
"""Shared utilities for SST3 mirror drift detection and propagation (Issue #418).

Byte-identical across:
  - dotfiles/SST3/scripts/sst3_mirror_utils.py (canonical)
  - SST3-AI-Harness/scripts/sst3_mirror_utils.py (vendored)
  - hoiboy-uk/scripts/sst3_mirror_utils.py (vendored)
  - ebay-seller-tool/scripts/sst3_mirror_utils.py (vendored)

A `cmp -s` self-drift hook in each mirror enforces byte-identity.

Consumed by:
  - SST3/scripts/check-mirror-drift.py (mirror-side pre-commit hook)
  - SST3/scripts/propagate-mirrors.py (canonical-side validator + propagator)

Design notes:
  - Two drift modes per manifest entry:
      (1) `transforms: [...]` — deterministic. apply(canonical) == mirror.
      (2) `divergent: true` + `mirror_sha256: "..."` — hash-pinned. Mirror
          content is hand-authored; drift-check verifies the mirror hash
          only. Used for structural rewrites that cannot round-trip from
          canonical (e.g. evidence scrub, voice rule rewrite).
  - Transforms are pure `(text: str, ctx: dict) -> str`, idempotent.
  - Registry is a module-level dict — no factories, no classes.
  - Python 3.10+, stdlib only. No pyyaml (mirror repos may lack it).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable, Iterable

TransformFn = Callable[[str, dict], str]

MANIFEST_VERSION = 1
MANIFEST_FILENAME = "drift-manifest.json"
EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_CONFIG = 2


# -----------------------------------------------------------------------------
# Transform implementations (pure, idempotent)
# -----------------------------------------------------------------------------

# dotfiles#552 AC 3.3 — the REQUIRED TRAILING SLASH in both patterns below is
# INTENTIONAL and must not be widened. It was raised as a possible gap (a bare
# `SST3/<subdir>` with no trailing slash is not rewritten); measuring it showed
# widening would corrupt more than it fixes.
#
# Measured across every canonical file carrying `path_scrub` (199 mirror entries
# on SST3-AI-Harness + 2 on sst3-skills -- note path_scrub runs on TWO lanes, not
# on all 26 mirror targets):
#
#   _SST3_SELF_RE   68 bare matches, of which 49 are `$SST3/...` -- the SHELL
#                   VARIABLE form of the resolver, which every skill and command
#                   uses to invoke SST3 scripts portably. Rewriting those mangles
#                   a variable reference into a broken literal, and Phase 4 of
#                   this same issue converts ~22 MORE call sites INTO that form.
#                   Of the remaining 19, `SST3/drift-manifest.json` must also stay
#                   verbatim: the manifest is deliberately never published to the
#                   mirror, so scrubbing the prefix would assert a file exists at
#                   the mirror root when it does not.
#
#   _PATH_SCRUB_RE  exactly 1 bare match, `../dotfiles/SST3/drift-manifest.json`,
#                   which is CORRECT as written -- it points at the sibling
#                   dotfiles clone, the documented way a consumer or mirror reads
#                   the canonical manifest. Widening would break the one reference
#                   it would touch.
#
# So the trailing slash is what distinguishes a real path PREFIX (safe to rewrite)
# from a variable reference or a deliberate cross-repo pointer (must not be).
# Re-derive the counts before revisiting; a `(?!/)` lookahead alone gives a false
# 413 because the greedy `+` backtracks to satisfy it.
_PATH_SCRUB_RE = re.compile(r"\.\./dotfiles/SST3/([a-zA-Z0-9_\-]+)/")
_SST3_SELF_RE = re.compile(r"\bSST3/([a-zA-Z0-9_\-]+)/")
_ISSUE_URL_LINKED = re.compile(
    r"\[Issue #(\d+)\]\(https://github\.com/hoiung/dotfiles/issues/\d+\)"
)
_ISSUE_URL_PAREN = re.compile(
    r"\(\[Issue #(\d+)\]\(https://github\.com/hoiung/dotfiles/issues/\d+\)\)"
)
_ISSUE_URL_BARE = re.compile(r"https://github\.com/hoiung/dotfiles/issues/(\d+)")
_REPO_REF_RE = re.compile(r"\bhoiung/(dotfiles|hoiboy-uk|ebay-seller-tool|SST3-AI-Harness)\b")
_AUTO_PB_RE = re.compile(r"\bauto_pb_swing_trader\b")
_TRADEBOOK_RE = re.compile(r"\btradebook_GAS\b")
_USER_QUOTE_RE = re.compile(r"^User quote:\s*\*\".*?\"\*\s*$", re.MULTILINE)
_TRADING_TERM_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bpipeline\s*/\s*backtest\s*/\s*SL1\s*/\s*SL2\s*/"), "pipeline / data-processing /"),
    (re.compile(r"\bSL1\s*/\s*SL2\s*/\s*backtest\b"), "data-processing"),
    (re.compile(r"\bbacktest\s*/\s*SL1\s*/\s*SL2\b"), "data-processing"),
]
_PRIVATE_PATH_RE = re.compile(r"logs/sample_\d+_validation\.log")
# #501 AC 1.1: private term mapping table extracted to canonical-only module so
# the literal regex + pair table no longer ship in vendored mirrors. On mirror
# clones the import fails and the scrubber falls through to identity (never-match
# regex + empty pairs) — mirrors don't need the table because their content has
# already been scrubbed at canonical→mirror propagation time. Self-bootstrap the
# script directory onto sys.path so any caller (pytest, propagate-mirrors, ad-hoc
# import) reaches the table without needing site-specific sys.path setup.
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
try:
    from _private_term_table import (  # type: ignore[import-not-found]
        _PRIVATE_REPO_ISSUE_RE,
        _PRIVATE_TERM_PAIRS,
        _WORD_BOUNDED_TERM_PAIRS,
    )
except ImportError:
    _PRIVATE_REPO_ISSUE_RE = re.compile(r"(?!x)x")  # never matches
    _PRIVATE_TERM_PAIRS = []  # type: ignore[var-annotated]
    _WORD_BOUNDED_TERM_PAIRS = ()  # type: ignore[var-annotated]

# Defensive runtime assertion: if we're loaded from a canonical-layout path
# (`<repo>/SST3/scripts/`) but `_private_term_table.py` is missing AND no
# operator override, refuse to run scrubber with identity table — otherwise the
# next `propagate-mirrors.py --apply` would ship UNSCRUBBED canonical text to
# every consumer mirror. Set `SST3_ALLOW_IDENTITY_SCRUB=1` for the rare case of
# testing a mirror-clone shape against the canonical scrubber.
_THIS_FILE = Path(__file__).resolve()
_CANONICAL_MODE = (
    _THIS_FILE.parent.parent.name == "SST3"
    and not (_THIS_FILE.parent / "_private_term_table.py").exists()
    and os.environ.get("SST3_ALLOW_IDENTITY_SCRUB") != "1"
)
if _CANONICAL_MODE and not _PRIVATE_TERM_PAIRS:
    raise RuntimeError(
        "sst3_mirror_utils.py: canonical-layout import detected but "
        "_private_term_table.py is missing — refusing to run scrubber with "
        "identity-fallback table (would ship unscrubbed text to mirrors on "
        "next propagate-mirrors --apply). Set SST3_ALLOW_IDENTITY_SCRUB=1 if "
        "this is an intentional mirror-clone shape test."
    )

# Strict start-of-line match — only lines of the form `# [identifier]` (optional trailing whitespace).
# Data lines containing `[` (e.g. `ERROR_[42]`) do NOT match and are preserved as data. (#441 Phase 2 defensive regex.)
_BLOCKLIST_SECTION_HEADER_RE = re.compile(r"^# \[([a-zA-Z0-9_-]+)\]\s*$")


def path_scrub(text: str, ctx: dict) -> str:
    """Rewrite `../dotfiles/SST3/<subdir>/` cross-repo refs for mirror context.

    For depth-1 mirror sources (e.g. `standards/STANDARDS.md`):
    `../dotfiles/SST3/ralph/foo.md` → `../ralph/foo.md` (resolves to mirror `ralph/foo.md`).
    `SST3/<subdir>/` (in-repo refs in dotfiles) → `<subdir>/` in mirrors.
    """
    out = _PATH_SCRUB_RE.sub(r"../\1/", text)
    out = _SST3_SELF_RE.sub(r"\1/", out)
    return out


def path_scrub_depth2(text: str, ctx: dict) -> str:
    """Variant of path_scrub for depth-2 mirror sources (#498 Ralph T3).

    For depth-2 mirror sources (e.g. `standards/stage-4/foo.md`):
    `../dotfiles/SST3/ralph/x.md` → `../../ralph/x.md` (resolves to mirror `ralph/x.md`).

    `path_scrub` would emit `../ralph/x.md` which resolves to mirror
    `standards/ralph/x.md` (broken — `ralph/` is at mirror root, not nested under
    `standards/`). One extra `../` segment is required for depth-2 sources.
    """
    out = _PATH_SCRUB_RE.sub(r"../../\1/", text)
    out = _SST3_SELF_RE.sub(r"\1/", out)
    return out


def plugin_path_scrub(text: str, ctx: dict) -> str:
    """Normalise dotfiles-canonical design-fidelity paths to the sst3-skills plugin layout.

    The design-fidelity skill content (SKILL.md + helper scripts + the two mechanics
    guides) is authored against the dotfiles repo layout: guides live at repo-root
    `docs/guides/`, helpers/tests at `.claude/skills/design-fidelity/{scripts,tests}/`.
    Those paths are CORRECT in dotfiles but do not exist in the standalone marketplace
    plugin, where the publish pipeline relocates the guides under `references/` (sibling
    to SKILL.md) and the helpers/tests under `scripts/`/`tests/`. This is the same
    layout-normalisation role as `path_scrub` (which rewrites `SST3/<sub>/`→`<sub>/`); the
    canonical source is left untouched so the dotfiles-local skill keeps working.

    The rewritten pointers are backtick prose / code-comment references (skill-root
    relative), not clickable markdown links, so reader-relative depth does not 404. The
    one genuinely-clickable pointer — the `mcp-configuration.md` guide, which is
    dotfiles-internal and NOT vendored — is de-linked to the official public Claude Code
    MCP docs so a marketplace consumer never hits a dead link.
    """
    # De-link the dead mcp-configuration.md pointer (that guide is dotfiles-internal,
    # not part of the published plugin) -> official public docs.
    text = re.sub(
        r"\[MCP Configuration Guide\]\(mcp-configuration\.md\)",
        "[Claude Code MCP setup](https://code.claude.com/docs/en/mcp)",
        text,
    )
    # Guides relocate to references/ (sibling to SKILL.md in the plugin).
    text = text.replace("docs/guides/playwright-fallback.md", "references/playwright-fallback.md")
    text = text.replace("docs/guides/chrome-devtools-mcp.md", "references/chrome-devtools-mcp.md")
    # Helpers/tests are plugin-relative (skills/design-fidelity/{scripts,tests}/).
    text = text.replace(".claude/skills/design-fidelity/scripts/", "scripts/")
    text = text.replace(".claude/skills/design-fidelity/tests/", "tests/")
    text = text.replace(".claude/skills/design-fidelity/SKILL.md", "SKILL.md")
    return text


def issue_url_scrub(text: str, ctx: dict) -> str:
    """Strip full GitHub URLs to private dotfiles issues; keep issue number."""
    out = _ISSUE_URL_PAREN.sub(r"(Issue #\1)", text)
    out = _ISSUE_URL_LINKED.sub(r"Issue #\1", out)
    out = _ISSUE_URL_BARE.sub(r"Issue #\1", out)
    return out


# FP-by-design (#520 item-1): no positive expected-output tuple in
# test_mirror_drift.py's IDEMPOTENCY_CASES — a positive case would require
# embedding a real private repo literal in that byte-identical-mirrored test
# file (a privacy leak). Covered by test_transform_no_op_on_clean_text (loops
# all TRANSFORMS) + the early-return no-op on mirror clones. Do NOT re-flag.
def private_repo_issue_scrub(text: str, ctx: dict) -> str:
    """Replace `<private-repo>#<num>` shorthand with `Issue #<num>` (#497 A.5.1).

    Mirrors should not enumerate private consumer repo names via cross-repo
    issue references like `<private-repo>#<N>` (concrete examples elided to
    avoid leaking the literal names through this byte-identical-mirrored
    scrubber file). The
    operator-acknowledged-public project names (`auto_pb_swing_trader`,
    `tradebook_GAS`) are NOT scrubbed by this transform — `project_name_scrub`
    handles bare name occurrences, and URL-form references still block via
    .secret-blocklist defence-in-depth.

    Idempotent: applying twice yields the same output (the substitution
    deletes the `<repo>#` prefix, so the second pass finds no further matches).

    On mirror clones where `_private_term_table.py` is absent, the identity
    fallback regex `(?!x)x` has zero capture groups. Python's `re.sub` validates
    the replacement template's group references at call time (BEFORE attempting
    any match), so `r"Issue #\2"` against a zero-group pattern raises
    `re.error: invalid group reference 2`. Early-return when the pattern has no
    groups — the identity fallback is by design a no-op on mirror clones (the
    text has already been scrubbed at canonical→mirror propagation time).
    """
    if _PRIVATE_REPO_ISSUE_RE.groups == 0:
        return text
    return _PRIVATE_REPO_ISSUE_RE.sub(r"Issue #\2", text)


def repo_ref_scrub(text: str, ctx: dict) -> str:
    """Strip `hoiung/` org prefix from repo refs (e.g. `hoiung/dotfiles` → `dotfiles`)."""
    return _REPO_REF_RE.sub(r"\1", text)


# FP-by-design (#520 item-1): no positive expected-output tuple in
# test_mirror_drift.py's IDEMPOTENCY_CASES — a positive case would require a real
# operator-identity / private literal in that byte-identical-mirrored test file (a
# privacy leak). Covered by test_transform_no_op_on_clean_text + the identity
# fallback no-op on mirror clones (empty pairs). Do NOT re-flag.
def private_term_scrub(text: str, ctx: dict) -> str:
    """Replace operator-identity + private-repo-name literals (#497 Phase E).

    Mirrors `.filter-repo-replacements.txt` used by Phase D's history rewrite,
    so canonical→mirror runtime propagation produces the same output as the
    filter-repo history rewrite. Pure substring replacement (matches the
    filter-repo `--replace-text` semantics byte-for-byte).

    Idempotent: each replacement consumes its input substring; second pass is
    a no-op because no replacement output equals any other pair's input key.

    **Mapping table location (#501 AC 1.1)**: `_PRIVATE_TERM_PAIRS` and
    `_WORD_BOUNDED_TERM_PAIRS` live in `_private_term_table.py` — a canonical-
    only module declared in `drift-manifest.json:unmirrored_canonical_files`.
    The mirror copy of this file imports the table inside a try/except and
    falls through to identity-fallback (empty pairs + never-match regex) when
    the file is absent, which is the expected state on every public mirror
    clone. The earlier inline-table posture leaked the OLD→NEW mapping into
    every vendored mirror (a bounded deanonymization oracle); extraction
    closes that surface.
    """
    out = text
    for old, new in _PRIVATE_TERM_PAIRS:
        out = out.replace(old, new)
    for pat, repl in _WORD_BOUNDED_TERM_PAIRS:
        out = pat.sub(repl, out)
    return out


def project_name_scrub(text: str, ctx: dict) -> str:
    """Replace private project names with generic placeholders."""
    out = _AUTO_PB_RE.sub("project-a", text)
    out = _TRADEBOOK_RE.sub("project-b", out)
    return out


def trading_term_scrub(text: str, ctx: dict) -> str:
    """Genericize trading-pipeline terminology."""
    out = text
    for pat, repl in _TRADING_TERM_PATTERNS:
        out = pat.sub(repl, out)
    return out


def private_path_scrub(text: str, ctx: dict) -> str:
    """Genericize log paths and private filesystem refs.

    Conservative: only scrubs obviously-private log path patterns observed in
    canonical content. Not a general sanitizer.
    """
    return _PRIVATE_PATH_RE.sub("log file path", text)


def user_quote_scrub(text: str, ctx: dict) -> str:
    """Remove `User quote: *"..."*` inline attribution blocks."""
    return _USER_QUOTE_RE.sub("", text)


def substitute_repo_slug(text: str, ctx: dict) -> str:
    """Replace the literal `<REPO_SLUG>` token with `ctx['repo']`.

    Used by managed-block propagation (Issue #493 AC 1.5): the canonical
    pre-commit block carries `--repo <REPO_SLUG>` in its hook entries; at
    propagate-time each mirror entry substitutes its own repo slug. The
    ctx['repo'] value is the same mirror['repo'] field that `iter_mirror_entries`
    yields, so reuses the existing transform contract.

    Idempotent: applying twice yields the same result (since `<REPO_SLUG>`
    is gone after the first pass, the second pass is a no-op).
    """
    target = ctx.get("repo", "")
    if not target:
        return text
    return text.replace("<REPO_SLUG>", target)


# #501 AC 1.2 — extended path-namespace scrub for residual dotfiles refs that
# `path_scrub` doesn't cover (which only handles `../dotfiles/SST3/<subdir>/`).
# These patterns + the operator-only DOTFILES_READ_TOKEN block target the F5
# leaks documented at /tmp/research_sst3-harness-sync_2026-05-24.md.
_DOTFILES_CLAUDE_RE = re.compile(r"\.\.?/dotfiles/\.claude/")
_DOTFILES_DOCS_RE = re.compile(r"\.\.?/dotfiles/docs/")
_DOTFILES_MCP_RE = re.compile(r"\.\.?/dotfiles/mcp-servers/")
_DOTFILES_SST3_METRICS_RE = re.compile(r"\bdotfiles/SST3-metrics/")
_DOTFILES_GH_RE = re.compile(r"\.\.?/dotfiles/\.github/")
# #501 Stage 5 — operator filesystem-layout leak. `$HOME/DevProjects/dotfiles`
# is the operator's local clone path; surfaces in STANDARDS.md (DOTFILES_ROOT
# env-var documentation) + claude/hooks/sst3-issue-body-privacy-gate.sh
# (operator-side runbook hook). Public mirror should not enumerate operator
# filesystem layout. Rewrite to a public-friendly placeholder; adopters set
# DOTFILES_ROOT to their own clone path. Defence-in-depth alongside
# .secret-blocklist. Matches both `$HOME/DevProjects/dotfiles/...` (subpaths)
# and bare `$HOME/DevProjects/dotfiles` (env-var default form).
_DOTFILES_HOME_PATH_RE = re.compile(r"\$HOME/DevProjects/dotfiles\b")
_MEMORY_REF_RE = re.compile(r"`memory/[a-z0-9_]+\.md`")
# dotfiles#523 AC 2.1 — load-stage-rules.sh is now MIRRORED (vendored_files), so
# the #501 AC 3.1 `_LOAD_STAGE_RULES_RE` rewrite (which turned its invocations
# into a "[canonical-only — read … directly]" note) was REMOVED: adopters now
# have scripts/load-stage-rules.sh and can run `bash scripts/load-stage-rules.sh
# <N>` directly, exactly as the post-path_scrub mirror form already reads.
# dotfiles#552 AC 1.4 — that claim was FALSE from #523 until now. The shell
# script shipped but its execution substrate did not: `_load_stage_rules.py` and
# `sst3_stage_tag_parser.py` sat in `unmirrored_canonical_files`, whose reasons
# asserted the opposite of this comment ("no consumer hosts the stage-tag
# substrate"). Every mirrored stage therefore exited 1 with "canon file
# missing". Both helpers are now vendored to SST3-AI-Harness and those two
# unmirrored entries are removed, so exactly one claim survives and it is true.
# Drops the entire `### Stage 5 Layer-B Failsafe — DOTFILES_READ_TOKEN` block in
# WORKFLOW.md (operator GitHub-secret rotation procedure not applicable to
# public consumers). DOTALL so `.` spans newlines. Lazy `.*?` stops at the next
# `### ` or `## ` heading. Multi-line MUST come BEFORE per-line patterns.
# dotfiles#552 Phase 2 — the lookahead MUST also stop at a `<!-- stages: N -->`
# tag comment. Without it the lazy match ran past the block's own end and
# swallowed the tag comment belonging to the NEXT heading (WORKFLOW.md:143,
# `<!-- stages: 4 -->`). That section then lost its stage-4 tag in the mirror
# only, fell through to tag inheritance, and surfaced at stage 5 instead --
# so the public mirror emitted `## Verification Loop`, `### Stage 3 — Triple-
# Check` and `### Stage 5 — Post-Implementation Review` at the WRONG stage while
# stage 4 silently lost them. Measured: mirror WORKFLOW.md contributed 23,628 B
# to stage 5 against canonical's 11,730 B, and only 14,897 B to stage 4 against
# canonical's 29,490 B. A scrub chain that only removes text cannot inflate a
# stage, which is what made this visible. Found by the AC 2.6 retention table;
# a byte-count check alone would have reported "mirror is smaller, fine".
_DOTFILES_READ_TOKEN_BLOCK_RE = re.compile(
    r"### Stage 5 Layer-B Failsafe — DOTFILES_READ_TOKEN.*?(?=^### |^## |^<!-- stages:)",
    re.DOTALL | re.MULTILINE,
)
# #501 Stage 5 — canonical-only scripts referenced in vendored prose. After
# path_scrub strips `SST3/`, the mirror reads `bash scripts/<name>.sh` /
# `python3 scripts/<name>.py` but these scripts live in
# `unmirrored_canonical_files` (operator-only). Adopters following the
# unmodified invocation hit ENOENT. The known canonical-only set is hard-coded
# here because the manifest does NOT enumerate this category by name; it just
# lists `unmirrored_canonical_files` (whose entries change as canonical evolves).
# Hard-coded set matches the names that appear in vendored WORKFLOW.md /
# Leader.md / STANDARDS.md mirror content. Matches POST-path_scrub form.
# Each match rewrites to a `<your-dotfiles-clone>/SST3/scripts/<name>` prefix
# so adopters with a canonical clone can invoke directly; adopters without a
# canonical clone see the placeholder + know to consult MIRROR-CONTRACT.md.
# dotfiles#523 Ralph Tier-2 F2: the set is GENUINELY-ABSENT canonical-only scripts
# only. propagate-template.py / sst3-check.sh / sst3-self-test.sh were removed
# because they ARE present in the public mirror (wrapper-lane + propagation
# infra) — de-referencing a present script mis-told adopters it was operator-only
# (pre-existing mis-de-ref this Issue's de-ref work surfaced; fixed here since the
# util already propagates to all mirrors). Their `bash scripts/<name>` refs now
# stay runnable mirror-local. Keep ONLY scripts absent from the mirror.
_CANONICAL_ONLY_SCRIPT_RE = re.compile(
    r"\b(bash|python3?)\s+scripts/("
    r"propagate-mirrors\.py"
    r"|leader-stage5-completeness-check\.sh"
    r"|leader-stage5-drain-check\.sh"
    r"|leader-feedback-aggregate\.sh"
    r"|sweep-parked-feedback\.sh"
    r"|feedback_parser\.py"
    r")\b"
)
# dotfiles#523 AC 2.1 — install.sh is operator-side (dotfiles repo-ROOT scripts/,
# NOT shipped in the public mirror); after path_scrub the mirror reads a bare
# mirror-local install.sh path that adopters cannot resolve. Rewrite to the
# operator-clone form so it reads as "operator-side, not in this mirror". The
# negative lookbehind `(?<![/\w-])` skips paths that already carry a directory
# segment (`../dotfiles/scripts/install.sh`, and the rewritten
# `<your-dotfiles-clone>/scripts/install.sh`) — making the substitution idempotent.
_INSTALL_SH_REF_RE = re.compile(r"(?<![/\w-])scripts/install\.sh")
# dotfiles#523 AC 2.3 — unmirrored-by-design feedback template (schema is inline).
_FEEDBACK_TEMPLATE_REF_RE = re.compile(
    r"(?<![\w/>-])(?:\.\./)+templates/leader-feedback-template\.md"
)
# dotfiles#523 AC 2.1 — PROSE references (not `bash|python`-prefixed runnable
# invocations, which `_CANONICAL_ONLY_SCRIPT_RE` already handles) to genuinely
# canonical-ONLY scripts (absent from the public mirror). After path_scrub these
# read as a bare/`../`-relative mirror-local `scripts/<name>` an adopter cannot
# resolve. Rewrite to the operator-clone form. NAMES here MUST be the absent set
# only — present-in-mirror scripts (load-stage-rules.sh, check-stage1-research-
# fields.py, sst3-check.sh, sst3-self-test.sh, propagate-template.py) are
# deliberately EXCLUDED so their refs stay runnable mirror-local. Lookbehind
# `(?<![\w/>-])` makes it idempotent (the rewritten `…/SST3/scripts/<name>` and
# the `bash <clone>/SST3/scripts/<name>` form both have `/` before `scripts/`).
_CANONICAL_ONLY_PROSE_RE = re.compile(
    r"(?<![\w/>-])(?:\.\./)*scripts/("
    r"propagate-mirrors\.py|leader-stage5-completeness-check\.sh|"
    r"leader-stage5-drain-check\.sh|leader-feedback-aggregate\.sh|"
    r"sweep-parked-feedback\.sh|mark-improvements-applied\.sh|"
    r"sst3-tier-a-auto-tick\.py|feedback_parser\.py)"
)


def dotfiles_reference_scrub(text: str, ctx: dict) -> str:
    """Scrub residual `dotfiles/...` namespace refs not covered by path_scrub.

    `path_scrub` rewrites `../dotfiles/SST3/<subdir>/` only. Mirrored canonicals
    also reference five other namespaces that leak through unchanged:

      - `../dotfiles/.claude/` → `../claude/` (mirror has `claude/` at root).
      - `../dotfiles/.github/` → `../.github/` (mirror has its own `.github/`).
      - `../dotfiles/docs/` → `../docs/` (mirror has `docs/`).
      - `../dotfiles/mcp-servers/` → `<MCP servers — operator-only>` (mirror
        lacks this dir; replace with inline tag so consumers don't see a
        broken path. Idempotent because the tag itself does not match the
        original regex.).
      - `dotfiles/SST3-metrics/` → `SST3-metrics/` (per-stage feedback dir;
        adopters write to a relative `SST3-metrics/` path of their own).

    Plus drops the entire `### Stage 5 Layer-B Failsafe — DOTFILES_READ_TOKEN`
    section from WORKFLOW.md (operator PAT rotation runbook — operator-only).

    Plus drops backtick-wrapped `memory/<file>.md` references (Claude Code
    auto-memory; not adopter-relevant).

    Idempotent: each replacement consumes its input substring; second pass
    finds no further matches.
    """
    out = _DOTFILES_READ_TOKEN_BLOCK_RE.sub("", text)
    out = _DOTFILES_CLAUDE_RE.sub("../claude/", out)
    out = _DOTFILES_GH_RE.sub("../.github/", out)
    out = _DOTFILES_DOCS_RE.sub("../docs/", out)
    out = _DOTFILES_MCP_RE.sub("<MCP servers — operator-only>/", out)
    out = _DOTFILES_SST3_METRICS_RE.sub("SST3-metrics/", out)
    out = _DOTFILES_HOME_PATH_RE.sub("<your-dotfiles-clone>", out)
    out = _MEMORY_REF_RE.sub("`<auto-memory ref>`", out)
    out = _INSTALL_SH_REF_RE.sub("<your-dotfiles-clone>/scripts/install.sh", out)
    # dotfiles#523 AC 2.3 — leader-feedback-template.md is unmirrored-by-design
    # (the per-stage feedback schema is described inline in the prose that cites
    # it). After path_scrub the mirror reads a bare `(../)+templates/…` an adopter
    # cannot resolve; rewrite to the operator-clone form. Idempotent via the same
    # `/`-before lookbehind class as the script de-refs.
    out = _FEEDBACK_TEMPLATE_REF_RE.sub(
        "<your-dotfiles-clone>/SST3/templates/leader-feedback-template.md", out
    )
    out = _CANONICAL_ONLY_SCRIPT_RE.sub(
        lambda mt: (
            f"{mt.group(1)} <your-dotfiles-clone>/SST3/scripts/{mt.group(2)}"
        ),
        out,
    )
    # PROSE refs run AFTER the bash/python form so already-rewritten runnable
    # invocations (now `… /SST3/scripts/<name>`) are not re-matched.
    out = _CANONICAL_ONLY_PROSE_RE.sub(
        lambda mt: f"<your-dotfiles-clone>/SST3/scripts/{mt.group(1)}", out
    )
    return out


def blocklist_subset(text: str, ctx: dict) -> str:
    """Filter canonical blocklist to repo-specific subset via ctx['repo'].

    Canonical file uses section headers `# [<tag>]` on their own line to mark
    per-repo sections. Two relevant tags:
      - `[shared]` — emitted to every mirror
      - `[<ctx['repo']>]` — emitted to that repo only

    Lines BEFORE any section header (preamble: GENERATED header, comments) are
    passed through to every mirror. Lines inside a non-matching section are
    dropped.

    Section-header detection uses strict regex `^# \\[([a-zA-Z0-9_-]+)\\]\\s*$`.
    Data lines that happen to contain `[` (e.g. `ERROR_[42]`) do NOT match and
    are preserved as data.

    ctx['repo'] is guaranteed non-empty by _validate_mirror (see the non-empty-string
    check for the 'repo' key in that function).

    Pure filter. Idempotent: applying twice yields the same result.
    """
    target = ctx.get("repo", "")
    out_lines: list[str] = []
    current_section: str | None = None  # None = preamble

    for line in text.splitlines(keepends=False):
        m = _BLOCKLIST_SECTION_HEADER_RE.match(line)
        if m:
            current_section = m.group(1)
            if current_section in ("shared", target):
                out_lines.append(line)
            continue
        if current_section is None or current_section in ("shared", target):
            out_lines.append(line)

    result = "\n".join(out_lines)
    if text.endswith("\n") and not result.endswith("\n"):
        result += "\n"
    return result


TRANSFORMS: dict[str, TransformFn] = {
    "blocklist_subset": blocklist_subset,
    "dotfiles_reference_scrub": dotfiles_reference_scrub,
    "issue_url_scrub": issue_url_scrub,
    "path_scrub": path_scrub,
    "path_scrub_depth2": path_scrub_depth2,
    "plugin_path_scrub": plugin_path_scrub,
    "private_path_scrub": private_path_scrub,
    "private_repo_issue_scrub": private_repo_issue_scrub,
    "private_term_scrub": private_term_scrub,
    "project_name_scrub": project_name_scrub,
    "repo_ref_scrub": repo_ref_scrub,
    "substitute_repo_slug": substitute_repo_slug,
    "trading_term_scrub": trading_term_scrub,
    "user_quote_scrub": user_quote_scrub,
}


def apply_transforms(text: str, transform_names: list[str], ctx: dict) -> str:
    """Apply named transforms to `text` left-to-right.

    Raises ManifestError on unknown transform name.
    """
    out = text
    for name in transform_names:
        fn = TRANSFORMS.get(name)
        if fn is None:
            raise ManifestError(
                f"unknown transform '{name}'. Registry: {sorted(TRANSFORMS.keys())}"
            )
        out = fn(out, ctx)
    return out


# -----------------------------------------------------------------------------
# Manifest schema + loader
# -----------------------------------------------------------------------------


class ManifestError(RuntimeError):
    """Raised on manifest schema / loader failures. Caller exits with EXIT_CONFIG."""


def _main_clone_root(start: Path) -> Path | None:
    """Resolve the MAIN clone root by walking up to the repo's `.git`.

    Pure file I/O (no subprocess / no git binary). A linked git worktree has a
    `.git` *file* of the form `gitdir: <main>/.git/worktrees/<name>`; reading it
    yields the MAIN clone even from inside a worktree (whose own toplevel lacks
    the sibling layout). A main clone has a `.git` *directory*. Returns None if no
    repo root is found within a bounded walk.

    Only that exact worktree shape resolves to another directory. Any other
    pointer resolves to the directory holding it: a submodule's
    `gitdir: <super>/.git/modules/<name>`, a separate git dir, and an empty or
    unreadable (including non-UTF-8) `.git` file. A submodule is its own
    repository, so walking up to the superproject would name the wrong one.
    extract-chat-agreements relies on that: it checks session ownership
    against this root, and a wider root would accept another repo's sessions.
    """
    cur = start
    for _ in range(40):  # bounded — never an unbounded walk to /
        dotgit = cur / ".git"
        if dotgit.is_dir():
            return cur  # main clone root
        if dotgit.is_file():
            try:
                txt = dotgit.read_text(encoding="utf-8").strip()
            except (OSError, UnicodeDecodeError):
                return cur
            if txt.startswith("gitdir:"):
                gd = Path(txt.split(":", 1)[1].strip())
                if not gd.is_absolute():
                    gd = (cur / gd).resolve()
                # gd = <main>/.git/worktrees/<name>; <main> is the main clone root.
                if gd.parent.name == "worktrees" and gd.parent.parent.name == ".git":
                    return gd.parent.parent.parent
            return cur  # not a linked-worktree pointer — the dir holding it is the root
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def find_manifest(start: Path | None = None) -> Path:
    """Locate the canonical `drift-manifest.json` from any invocation site.

    The manifest lives ONLY in the dotfiles repo (canonical
    `dotfiles/SST3/drift-manifest.json`); consumers + public mirrors read the
    sibling dotfiles copy. This resolver handles every clone shape × (main clone
    / linked git worktree):
      - dotfiles canonical:  `<root>/SST3/scripts/` -> `<root>/SST3/drift-manifest.json`
      - dotfiles self-row:   `<root>/scripts/`      -> `<root>/SST3/drift-manifest.json`
      - consumer / mirror:   `<repo>/scripts/`      -> `<DevProjects>/dotfiles/SST3/drift-manifest.json`

    Worktree-safe (dotfiles#512): a linked worktree's own toplevel lacks the
    sibling layout, so we resolve the MAIN clone root via `_main_clone_root`
    (reads the worktree's `.git`-file `gitdir:` pointer — pure file I/O, no
    subprocess). Without this the pre-commit drift gate silently SKIPped (exit 0)
    inside every Stage-4 worktree across the whole fleet — the AP #12 fail-fast
    hole that bypassed on #509's own worktree commits.

    Raises ManifestError if not found in any candidate location.
    """
    start = (start or Path(__file__).resolve().parent)
    candidates = [
        start.parent / MANIFEST_FILENAME,             # SST3/scripts/ -> SST3/ (main or worktree)
        start.parent / "SST3" / MANIFEST_FILENAME,    # repo-root/scripts/ -> repo-root/SST3/ (dotfiles self-row, worktree-safe)
    ]
    # Worktree/consumer resolution via the MAIN clone root (worktree-safe).
    main_root = _main_clone_root(start)
    if main_root is not None:
        candidates += [
            main_root / "SST3" / MANIFEST_FILENAME,                      # dotfiles main clone (from a dotfiles worktree)
            main_root.parent / "dotfiles" / "SST3" / MANIFEST_FILENAME,  # consumer/mirror sibling dotfiles (from main OR worktree)
        ]
    # Legacy fallback (pre-#512): mirror script's parent.parent sibling.
    candidates.append(start.parent.parent / "dotfiles" / "SST3" / MANIFEST_FILENAME)

    seen: set[str] = set()
    ordered: list[Path] = []
    for p in candidates:
        s = str(p)
        if s not in seen:
            seen.add(s)
            ordered.append(p)
    for p in ordered:
        if p.is_file():
            return p
    raise ManifestError(
        f"{MANIFEST_FILENAME} not found near {start}. Searched: {[str(c) for c in ordered]}"
    )


def load_manifest(path: Path) -> dict[str, Any]:
    """Read + validate manifest JSON. Returns parsed dict.

    Raises ManifestError on JSON parse failure or schema violation.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ManifestError(f"cannot read manifest {path}: {exc}") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestError(f"manifest JSON parse failed ({path}): {exc}") from exc
    validate_manifest(data)
    return data


def validate_manifest(data: Any) -> None:
    """Validate manifest schema. Raises ManifestError with field-level detail on failure."""
    if not isinstance(data, dict):
        raise ManifestError(f"manifest root must be object, got {type(data).__name__}")
    version = data.get("version")
    if version != MANIFEST_VERSION:
        raise ManifestError(
            f"unsupported manifest version {version!r} (expected {MANIFEST_VERSION})"
        )
    for key in ("canonical_root", "vendored_files"):
        if key not in data:
            raise ManifestError(f"manifest missing required field '{key}'")
    if not isinstance(data["canonical_root"], str):
        raise ManifestError("canonical_root must be string")
    if not isinstance(data["vendored_files"], list):
        raise ManifestError("vendored_files must be list")
    seen_canonicals: set[str] = set()
    for i, entry in enumerate(data["vendored_files"]):
        _validate_entry(entry, i, seen_canonicals)
    unmirrored = data.get("unmirrored_canonical_files", [])
    if not isinstance(unmirrored, list):
        raise ManifestError("unmirrored_canonical_files must be list")
    for i, entry in enumerate(unmirrored):
        _validate_unmirrored_entry(entry, i)

    # Issue #493 AC 1.6 — managed_blocks: boundary-marker propagation (paired-
    # marker YAML blocks). Optional top-level array; each entry pairs one
    # canonical block template with N mirror targets that get per-repo
    # transforms applied at propagate-time. Without this validator extension,
    # the new array would be silently ignored (unknown-key tolerance).
    managed_blocks = data.get("managed_blocks", [])
    if not isinstance(managed_blocks, list):
        raise ManifestError("managed_blocks must be list")
    seen_canonical_blocks: set[str] = set()
    for i, entry in enumerate(managed_blocks):
        _validate_managed_block_entry(entry, i, seen_canonical_blocks)

    # #501 AC 3.3 Half A — harness_only_files: declares files that exist ONLY
    # in the SST3-AI-Harness public mirror with no canonical sibling (community-
    # authored adopter content). Optional top-level array, audit-trail metadata.
    harness_only = data.get("harness_only_files", [])
    if not isinstance(harness_only, list):
        raise ManifestError("harness_only_files must be list")
    seen_harness_paths: set[str] = set()
    for i, entry in enumerate(harness_only):
        _validate_harness_only_entry(entry, i, seen_harness_paths)


def _validate_harness_only_entry(entry: Any, index: int, seen: set[str]) -> None:
    """Enforce `harness_only_files` entry schema (#501 AC 3.3 Half A).

    Each entry must be a `{path: non-empty str, reason: non-empty str}` object
    documenting an intentional harness-only file (no canonical sibling).
    Duplicate paths within `harness_only_files` are an error.
    """
    prefix = f"harness_only_files[{index}]"
    if not isinstance(entry, dict):
        raise ManifestError(
            f"{prefix} must be object with 'path' + 'reason' keys; "
            f"got {type(entry).__name__}"
        )
    path = entry.get("path")
    if not isinstance(path, str) or not path:
        raise ManifestError(f"{prefix}.path must be non-empty string")
    if path in seen:
        raise ManifestError(f"{prefix}.path duplicate: {path}")
    seen.add(path)
    reason = entry.get("reason")
    if not isinstance(reason, str) or not reason:
        raise ManifestError(f"{prefix}.reason must be non-empty string")


def _validate_managed_block_entry(
    entry: Any, index: int, seen: set[str]
) -> None:
    """Enforce `managed_blocks[i]` entry schema (Issue #493 AC 1.6).

    Each entry maps one canonical block template (e.g. the SST3 pre-commit
    block YAML at SST3/templates/pre-commit-managed-block.yaml) onto N
    consumer mirror targets. Required fields:

    * ``canonical``     — non-empty repo-rel path to the canonical block template.
    * ``target_file``   — non-empty repo-rel filename inside each mirror
                          that carries the boundary-marked block (e.g.
                          ``.pre-commit-config.yaml``).
    * ``marker_start``  — non-empty start-marker line content (line-anchored).
    * ``marker_end``    — non-empty end-marker line content (line-anchored).
    * ``mirrors``       — non-empty list of ``{repo, path, transforms?}`` entries
                          (same shape as ``vendored_files[*].mirrors[*]``).
    """
    prefix = f"managed_blocks[{index}]"
    if not isinstance(entry, dict):
        raise ManifestError(f"{prefix} must be object")
    canonical = entry.get("canonical")
    if not isinstance(canonical, str) or not canonical:
        raise ManifestError(f"{prefix}.canonical must be non-empty string")
    if canonical in seen:
        raise ManifestError(f"{prefix}.canonical duplicate: {canonical}")
    seen.add(canonical)
    for key in ("target_file", "marker_start", "marker_end"):
        val = entry.get(key)
        if not isinstance(val, str) or not val:
            raise ManifestError(f"{prefix}.{key} must be non-empty string")
    if entry["marker_start"] == entry["marker_end"]:
        raise ManifestError(
            f"{prefix}.marker_start and marker_end must differ (paired-marker contract)"
        )
    mirrors = entry.get("mirrors")
    if not isinstance(mirrors, list) or not mirrors:
        raise ManifestError(f"{prefix}.mirrors must be non-empty list")
    for j, mirror in enumerate(mirrors):
        _validate_managed_block_mirror(mirror, f"{prefix}.mirrors[{j}]")


def _validate_managed_block_mirror(mirror: Any, prefix: str) -> None:
    """Validate a single managed-block mirror entry.

    Same shape as ``vendored_files`` mirrors for ``repo`` + ``path``, but
    here ``path`` is the same as the parent entry's ``target_file`` in
    every case — kept as a separate field for parallelism with
    ``vendored_files[*].mirrors[*].path`` and to allow future divergence.
    """
    if not isinstance(mirror, dict):
        raise ManifestError(f"{prefix} must be object")
    for key in ("repo", "path"):
        val = mirror.get(key)
        if not isinstance(val, str) or not val:
            raise ManifestError(f"{prefix}.{key} must be non-empty string")
    transforms = mirror.get("transforms", [])
    if not isinstance(transforms, list):
        raise ManifestError(f"{prefix}.transforms must be list")
    for k, name in enumerate(transforms):
        if not isinstance(name, str) or not name:
            raise ManifestError(
                f"{prefix}.transforms[{k}] must be non-empty string"
            )
        if name not in TRANSFORMS:
            raise ManifestError(
                f"{prefix}.transforms[{k}] unknown transform '{name}'. "
                f"Registry: {sorted(TRANSFORMS.keys())}"
            )


def _validate_unmirrored_entry(entry: Any, index: int) -> None:
    """Enforce `unmirrored_canonical_files` entry schema.

    Accepts plain strings (canonical-path back-compat) OR objects
    `{path: non-empty str, reason: non-empty str}` documenting intentional
    per-repo divergence (#442 GAP 3.1 / 3.4a). Anything else raises.
    """
    prefix = f"unmirrored_canonical_files[{index}]"
    if isinstance(entry, str):
        if not entry:
            raise ManifestError(f"{prefix} string entry must be non-empty")
        return
    if not isinstance(entry, dict):
        raise ManifestError(
            f"{prefix} must be a string path or object with 'path' + 'reason' keys; "
            f"got {type(entry).__name__}"
        )
    path = entry.get("path")
    if not isinstance(path, str) or not path:
        raise ManifestError(f"{prefix}.path must be non-empty string")
    reason = entry.get("reason")
    if not isinstance(reason, str) or not reason:
        raise ManifestError(
            f"{prefix}.reason must be non-empty string "
            f"(documents why {path} is intentionally not mirrored)"
        )


def _validate_entry(entry: Any, index: int, seen: set[str]) -> None:
    prefix = f"vendored_files[{index}]"
    if not isinstance(entry, dict):
        raise ManifestError(f"{prefix} must be object")
    canonical = entry.get("canonical")
    if not isinstance(canonical, str) or not canonical:
        raise ManifestError(f"{prefix}.canonical must be non-empty string")
    if canonical in seen:
        raise ManifestError(f"{prefix}.canonical duplicate: {canonical}")
    seen.add(canonical)
    mirrors = entry.get("mirrors")
    if not isinstance(mirrors, list) or not mirrors:
        raise ManifestError(f"{prefix}.mirrors must be non-empty list")
    for j, mirror in enumerate(mirrors):
        _validate_mirror(mirror, f"{prefix}.mirrors[{j}]")


def _validate_mirror(mirror: Any, prefix: str) -> None:
    if not isinstance(mirror, dict):
        raise ManifestError(f"{prefix} must be object")
    for key in ("repo", "path"):
        val = mirror.get(key)
        if not isinstance(val, str) or not val:
            raise ManifestError(f"{prefix}.{key} must be non-empty string")
    divergent = mirror.get("divergent", False)
    if divergent:
        sha = mirror.get("mirror_sha256")
        if (
            not isinstance(sha, str)
            or len(sha) != 64
            or not all(c in "0123456789abcdef" for c in sha)
        ):
            raise ManifestError(
                f"{prefix} has divergent=true but mirror_sha256 missing or malformed "
                f"(expected 64-char lowercase hex sha256)"
            )
        # Transforms on a divergent entry are INERT, and inert config that reads
        # as protection is worse than no config (dotfiles#552, Ralph Tier 2
        # round 3). `do_apply` in propagate-mirrors.py checks divergence FIRST,
        # updates only mirror_sha256, and `continue`s -- it never reaches
        # `apply_transforms`. So a scrub chain declared here never runs.
        #
        # This was not hypothetical: seven divergent entries had been given the
        # full seven-transform scrub chain, and those seven were EXACTLY the
        # files carrying blocklisted private terms. The manifest asserted a
        # scrub on precisely the files that were not being scrubbed, and a
        # commit message attested to it. Rejecting the shape is what makes the
        # inertness impossible to declare rather than merely documented.
        #
        # A divergent mirror is protected by its hash pin plus whatever
        # hand-scrub produced it -- not by this list.
        transforms = mirror.get("transforms")
        if transforms:
            raise ManifestError(
                f"{prefix} has divergent=true AND a non-empty transforms list "
                f"{transforms}. Transforms are never applied to a divergent "
                f"mirror (propagate-mirrors.do_apply skips it before "
                f"apply_transforms), so declaring them asserts a scrub that "
                f"does not run. Remove the transforms, or clear divergent=true "
                f"if the mirror really should be regenerated from canonical."
            )
    else:
        transforms = mirror.get("transforms")
        if not isinstance(transforms, list):
            raise ManifestError(f"{prefix}.transforms must be list (use [] for byte-identical)")
        for name in transforms:
            if name not in TRANSFORMS:
                raise ManifestError(
                    f"{prefix}.transforms references unknown transform '{name}'. "
                    f"Registry: {sorted(TRANSFORMS.keys())}"
                )


# -----------------------------------------------------------------------------
# Path resolution
# -----------------------------------------------------------------------------


_WORKTREE_SEG = "/.claude/worktrees/"


def resolve_dotfiles_root(manifest_path: Path) -> Path:
    """Return the CANONICAL root — the working tree that actually contains
    this manifest (and therefore the canonical files to read/validate).

    #488 Fix-A correction (Option A). The manifest is ALWAYS at
    `<root>/SST3/drift-manifest.json`, and `find_manifest()` resolves it
    relative to `__file__`, so when invoked from inside an `EnterWorktree`
    worktree this deterministically returns the WORKTREE root — exactly
    where the in-flight #488 canonical edits live. The prior P1 attempt used
    `git --git-common-dir` to return the MAIN clone instead; that was both
    (a) env-fragile — it silently fell back inside the pre-commit hook
    sandbox, yielding the bogus `<wt>/.claude/worktrees/SST3-AI-Harness`
    mirror path that hard-blocked every worktree vendored commit — and
    (b) conceptually wrong: reading canonical from main-clone@master means a
    worktree branch's edits are never the bytes validated/propagated. Pure
    deterministic path math here: no git subprocess, no environment
    sensitivity. The MAIN clone (for sibling mirror/consumer resolution) is
    a SEPARATE concern — see `resolve_main_clone_root`.
    """
    return manifest_path.resolve().parent.parent


def resolve_main_clone_root(manifest_path: Path) -> Path:
    """Return the MAIN clone root (the sibling-resolution base under
    `DevProjects/`), env-immune.

    Mirror repos (`SST3-AI-Harness`) and KNOWN_REPOS consumers live as
    siblings of the MAIN `dotfiles/` clone, NOT of a linked worktree. A
    linked worktree's manifest path contains the `/.claude/worktrees/<name>/`
    segment; the MAIN clone is the prefix before that segment. In the main
    clone itself there is no such segment and the canonical root already IS
    the main clone. Derived purely from path structure (no git subprocess —
    immune to the pre-commit-sandbox env quirk that broke the P1 attempt);
    a loud sanity check rejects an implausible result rather than silently
    returning a bogus path (Fail-Fast — the failure mode #488 forbids).
    """
    resolved = manifest_path.resolve()
    s = str(resolved)
    if _WORKTREE_SEG in s:
        main = Path(s.split(_WORKTREE_SEG, 1)[0])
    else:
        main = resolved.parent.parent
        # A linked worktree made outside .claude/worktrees/ (`git worktree add
        # ../dotfiles-x`) has no segment to strip; its own `.git` file names the main
        # clone (file I/O only). Without this its self-row resolved to the shared main
        # clone, and the "run in this checkout" remedy wrote the runtime canon
        # (#577 Stage 5 fix review r2).
        if (main / ".git").is_file():
            main = _main_clone_root(main) or main
    if not (main / "SST3" / MANIFEST_FILENAME).is_file():
        raise ManifestError(
            f"resolve_main_clone_root: derived main clone {main} has no "
            f"SST3/{MANIFEST_FILENAME} (manifest={resolved}). Refusing to "
            f"return an unverified sibling-resolution base."
        )
    return main


def in_linked_worktree(manifest_path: Path) -> bool:
    """True iff invoked from an `EnterWorktree` linked worktree (canonical
    root differs from the main clone root)."""
    return (
        resolve_dotfiles_root(manifest_path).resolve()
        != resolve_main_clone_root(manifest_path).resolve()
    )


def _git(root: Path, *args: str) -> tuple[int, str]:
    """Run git in <root> with every GIT_* variable removed (AP #31: a commit or
    push hook exports GIT_DIR / GIT_INDEX_FILE, which would point the probe at
    the CALLING repo instead of <root>)."""
    import subprocess

    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        cp = subprocess.run(  # sst3-sec: justified: argv list, no shell; git verbs fixed in this module
            ["git", "-C", str(root), *args],
            capture_output=True, text=True, env=env, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)
    return cp.returncode, cp.stdout.strip()


def _origin_default(root: Path) -> str | None:
    rc, out = _git(root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    return out.split("/", 1)[1] if rc == 0 and "/" in out else None


def sibling_canon_problem(manifest_path: Path, caller: Path | None = None) -> str | None:
    """dotfiles#577 D1 (operator ruling 11): refuse to read canon from a STALE
    sibling dotfiles clone.

    A consumer's gates read canonical bytes from the sibling `../dotfiles` MAIN
    clone's working tree. When that clone sits on another branch, or behind
    origin's default branch, every comparison against it is wrong: measured
    2026-10-04, it was 372 commits behind on another session's branch, the
    strict drift gate failed in 20/20 consumers, and the printed remedy
    (propagate --apply) would have copied the stale bytes back over the
    consumers. Returns the refusal text, or None when reading is safe:
      - the canonical tree is a linked worktree (in-flight edits are deliberate);
      - the caller IS the dotfiles clone (self-row reads its own tree);
      - the canonical tree is not a git main clone (a fixture or export).
    Unresolvable git state is a refusal, never a pass. On the default branch the
    clone must also hold no uncommitted tracked change and no unpushed commit: either
    one is bytes origin does not have, so a gate reading it ran unreviewed code (#577
    Stage 5 fix review R44). Limit: "behind" is measured against the last fetch; a
    push made since is invisible without the network, which a commit hook does not use.
    """
    root = resolve_dotfiles_root(manifest_path).resolve()
    if _WORKTREE_SEG in str(root) + "/" or not (root / ".git").is_dir():
        return None
    caller_root = _main_clone_root((caller or Path.cwd()).resolve())
    if caller_root is not None and caller_root.resolve() == root:
        return None
    default = _origin_default(root)
    if default is None:
        return (
            f"shared dotfiles {root}: cannot resolve origin's default branch "
            f"(refs/remotes/origin/HEAD), so it cannot tell whether the canonical "
            f"files there are current. This check did not run. Fix: "
            f"git -C {root} remote set-head origin --auto"
        )
    rc_b, branch = _git(root, "branch", "--show-current")
    rc_n, behind = _git(root, "rev-list", "--count", f"HEAD..origin/{default}")
    rc_a, ahead = _git(root, "rev-list", "--count", f"origin/{default}..HEAD")
    rc_s, dirty = _git(root, "status", "--porcelain", "--untracked-files=no")
    if rc_b or rc_n or rc_a or rc_s or not (behind.isdigit() and ahead.isdigit()):
        return (
            f"shared dotfiles {root}: git could not read its branch, its distance "
            f"from origin/{default} or its status, so this check did not run."
        )
    if branch == default and behind == "0" and ahead == "0" and not dirty:
        return None
    if branch == default and behind == "0":
        what = "; ".join(x for x in (
            f"{ahead} commit(s) not on origin/{default}" if ahead != "0" else "",
            f"{len(dirty.splitlines())} uncommitted tracked change(s)" if dirty else "",
        ) if x)
        return (
            f"shared dotfiles {root} is on {default} but holds {what}. Those bytes are "
            f"not the canon, so this check did not run. This is NOT drift in this repo. "
            f"Move that work onto a branch in a worktree (or push it through Gate 2), "
            f"leaving the clone at origin/{default}: git -C {root} status"
        )
    return (
        f"shared dotfiles is on branch {branch or '<detached HEAD>'}, {behind} behind "
        f"origin/{default} ({root}). The canonical files there are not the canon, so "
        f"this check did not run. This is NOT drift in this repo: do not run "
        f"propagate-mirrors to clear it, that would copy the stale files over this "
        f"repo. Return that clone to {default} first (save any uncommitted work "
        f"there), e.g. git -C {root} checkout {default} && "
        f"git -C {root} merge --ff-only origin/{default}"
    )


def propagation_source_problem(manifest_path: Path) -> str | None:
    """dotfiles#577 Stage 5 (K8): consumer propagation writes only MERGED canon.

    Writing consumer mirrors / blocks / CLAUDE.md sections is allowed only from a
    clean linked worktree checked out at origin's default branch. From the main
    clone the self-row is the shared runtime canon (another session's branch and
    uncommitted files measured there 2026-10-04); from a solo branch or a dirty
    tree the consumers get bytes master does not hold, which the next drift gate
    then reports against master. Returns the refusal text, or None. Self-row-only
    writes are the caller's exemption (they land in this tree), and a canonical
    tree that is not a git checkout (a test fixture) is not a propagation source.
    """
    root = resolve_dotfiles_root(manifest_path).resolve()
    if not (root / ".git").exists():
        return None
    main = resolve_main_clone_root(manifest_path).resolve()
    where = f"a clean worktree under {main}/.claude/worktrees/ at origin's default branch"
    if _WORKTREE_SEG not in str(root) + "/":
        if root != main:
            return (
                f"consumer propagation must run from {where}, not from {root}, a worktree "
                f"outside .claude/worktrees/. Create one: git -C {main} worktree add "
                f"--detach {main}/.claude/worktrees/propagate origin/master"
            )
        return (
            f"consumer propagation must run from {where}, not from {root}: the main "
            f"clone is the runtime canon other sessions share, so its branch and "
            f"uncommitted files are not the merged canon. Create one: git -C {main} "
            f"worktree add --detach {main}/.claude/worktrees/propagate origin/master"
        )
    default = _origin_default(root)
    if default is None:
        return f"{root}: cannot resolve origin's default branch (refs/remotes/origin/HEAD); propagation refused."
    rc_h, head = _git(root, "rev-parse", "HEAD")
    rc_t, tip = _git(root, "rev-parse", f"origin/{default}")
    rc_d, dirty = _git(root, "status", "--porcelain", "--untracked-files=no")
    if rc_h or rc_t or rc_d:
        return f"{root}: git could not read HEAD, origin/{default} or the tree status; propagation refused."
    if head != tip:
        return (
            f"{root} is at {head[:8]}, not origin/{default} ({tip[:8]}): consumers get "
            f"merged canon only. Merge first (Gate 2), fetch, then propagate from {where}."
        )
    if dirty:
        return f"{root} has uncommitted tracked changes; consumers get committed canon only:\n{dirty[:600]}"
    return None


def propagation_scope(manifest_path: Path) -> tuple[bool, bool, str | None]:
    """Where `propagate-mirrors.py --apply` may write from this tree (#577 Stage 5 R12/R55).

    Returns (this_tree, consumers, problem). `this_tree` covers the writes that
    land in this checkout: the dotfiles self-row copies and the divergent-mirror
    hashes in this manifest. `consumers` covers mirror files in consumer repos.
    K8 refused the whole --apply from a solo branch, so the self-row sync the
    branch needs and the hash refresh a divergent-mirror edit needs had no legal
    run anywhere; and a post-merge run that refreshed a hash left the clean
    propagation worktree dirty, with nothing landing that hash on master.

    - not a git checkout (a test fixture): both, as before K8.
    - the main clone: neither (`problem` says why); it is the shared runtime canon.
    - a clean linked worktree at origin's default: consumers only. Drift in this
      tree there means master itself is out of step; it is fixed on a branch.
    - any other linked worktree (a solo branch, a dirty or stale tree): this
      tree only, committed with the change; consumers wait for the merge.
    """
    problem = propagation_source_problem(manifest_path)
    if problem is None:
        root = resolve_dotfiles_root(manifest_path).resolve()
        return (not (root / ".git").exists(), True, None)
    if in_linked_worktree(manifest_path):
        return (True, False, problem)
    return (False, False, problem)


def sync_hint(repo: str, canonical: str) -> str:
    """The remediation command for a drifted mirror, scoped to where it may run (#577 R13).

    A dotfiles self-row copy and a divergent hash are written in the checkout that
    carries the change; a consumer copy only from a clean origin/master worktree after
    the Gate-2 merge. One hint for every kind sent the self-row fix to a tree where it
    cannot help (the self-row writes into whatever tree runs it).

    A consumer row names the tool repo-relative: the tool reads the manifest beside
    itself, so the absolute path a consumer's vendored checker resolved (the shared main
    clone) ran against the main clone's manifest and was refused from every tree
    (#577 Stage 5 fix review r2).
    """
    if repo == "dotfiles":
        return f"Run in this checkout: python {propagate_tool_path()} --apply --repo dotfiles --file {canonical}"
    cmd = f"python {_PROPAGATE_TOOL_REL} --apply --repo {repo} --file {canonical}"
    return (f"Run in dotfiles: {cmd} (consumer files: from a clean origin/master worktree "
            f"under .claude/worktrees/ after the Gate-2 merge; a divergent hash: in the "
            f"dotfiles checkout that carries the edit; #577 K8)")


def fleet_apply_hint(tool: str) -> str:
    """Where a consumer-writing propagation run goes (#577 K8; fix review R49).

    The writers refuse every tree but a clean dotfiles worktree at origin's default
    branch, so a bare "Run propagate-x --apply" sent the reader to a command that
    fails from the main clone or a solo branch.
    """
    flag = "--all" if tool == "propagate-template.py" else "--apply"
    return (f"run `python SST3/scripts/{tool} {flag}` in dotfiles after the Gate-2 merge, "
            f"from a clean worktree at origin's default branch under .claude/worktrees/ "
            f"(#577 K8: it refuses any other tree)")


SELF_ROW_APPLY_HINT = ("run in this dotfiles checkout: python SST3/scripts/propagate-mirrors.py "
                       "--apply --repo dotfiles")


_PROPAGATE_TOOL_REL = "SST3/scripts/propagate-mirrors.py"


def propagate_tool_path() -> str:
    """Best available path to propagate-mirrors.py, for remediation hints.

    dotfiles#552 Ralph Tier 2 round 8. An earlier fix replaced two conflicting
    hard-coded literals with `_SCRIPTS_DIR`, which is the directory THIS module
    was imported from. That is right in the canonical tree and WRONG for the
    dotfiles self-row, where this module is mirrored flat to `<root>/scripts/`
    while propagate-mirrors.py stays canonical-only under `SST3/scripts/`. The
    hint then names a file that does not exist -- reproduced by planting drift,
    running the real pre-commit hook, and pasting its printed command back:
    "can't open file '.../scripts/propagate-mirrors.py': [Errno 2]".

    Self-verifying, like the loader's own resolver: test for the file rather
    than infer from the directory name. Falls back to the repo-relative literal,
    which is honest and runnable from a repo root, instead of an absolute path
    that is confidently wrong.
    """
    beside = Path(_SCRIPTS_DIR) / "propagate-mirrors.py"
    if beside.is_file():
        return str(beside)
    try:
        resolved = resolve_canonical(find_manifest(), _PROPAGATE_TOOL_REL)
        if resolved.is_file():
            return str(resolved)
    except (ManifestError, OSError):
        pass
    return _PROPAGATE_TOOL_REL


def resolve_canonical(manifest_path: Path, canonical_rel: str) -> Path:
    """Resolve a manifest `canonical` field to an absolute path (reads from
    the canonical root — the worktree when run from one, so #488 in-flight
    edits ARE the validated/propagated bytes)."""
    return resolve_dotfiles_root(manifest_path) / canonical_rel


def resolve_mirror(manifest_path: Path, mirror_repo: str, mirror_rel: str) -> Path:
    """Resolve a manifest mirror entry to an absolute path.

    Mirror repos live as siblings of the MAIN `dotfiles/` clone under
    `DevProjects/` — NEVER as siblings of a linked worktree.
    """
    devprojects = resolve_main_clone_root(manifest_path).parent
    return devprojects / mirror_repo / mirror_rel


def resolve_self_row_destination(
    manifest_path: Path, mirror_repo: str, mirror_rel: str
) -> Path:
    """Resolve a mirror destination with worktree-aware self-row routing
    (dotfiles#495 FRAG-1 / AC 2.1).

    When invoked from a LINKED WORKTREE AND the mirror's `repo` is `dotfiles`
    (the harness self-row), return the WORKTREE path (so an in-flight
    canonical edit lands in the worktree's solo branch, mergeable via Gate-2
    server-FF without a post-merge `--apply` from the main clone). Otherwise
    delegate to `resolve_mirror` (consumer-repo mirrors always resolve to
    main-clone siblings; main-clone invocations resolve the dotfiles self-row
    in the main clone exactly as before).

    Pure deterministic path math via the existing primitives:
    `resolve_dotfiles_root(manifest_path) / mirror_rel` for the worktree
    self-row case; `resolve_mirror(manifest_path, mirror_repo, mirror_rel)`
    for every other case.
    """
    if in_linked_worktree(manifest_path) and mirror_repo == "dotfiles":
        return resolve_dotfiles_root(manifest_path) / mirror_rel
    return resolve_mirror(manifest_path, mirror_repo, mirror_rel)


# -----------------------------------------------------------------------------
# Iteration helpers
# -----------------------------------------------------------------------------


def iter_mirror_entries(
    manifest: dict[str, Any],
    *,
    repo_filter: str | None = None,
    file_filter: str | None = None,
) -> Iterable[tuple[dict[str, Any], dict[str, Any]]]:
    """Yield (entry, mirror) pairs matching filters."""
    for entry in manifest["vendored_files"]:
        if file_filter and entry["canonical"] != file_filter:
            continue
        for mirror in entry["mirrors"]:
            if repo_filter and mirror["repo"] != repo_filter:
                continue
            yield entry, mirror


def iter_managed_block_entries(
    manifest: dict[str, Any],
    *,
    repo_filter: str | None = None,
    file_filter: str | None = None,
) -> Iterable[tuple[dict[str, Any], dict[str, Any]]]:
    """Yield (entry, mirror) pairs from `manifest['managed_blocks']` matching filters.

    Mirrors the shape of `iter_mirror_entries` so propagate-block.py can use
    the same loop pattern as propagate-mirrors.py. The `file_filter` matches
    against `entry['canonical']` (the source template path); `repo_filter`
    matches against `mirror['repo']`. Returns nothing if `managed_blocks` is
    absent or empty.

    Issue #493 AC 1.5.
    """
    for entry in manifest.get("managed_blocks", []):
        if file_filter and entry["canonical"] != file_filter:
            continue
        for mirror in entry["mirrors"]:
            if repo_filter and mirror["repo"] != repo_filter:
                continue
            yield entry, mirror


def sha256_of(path: Path) -> str:
    """Return hex sha256 of file contents. Raises OSError on read failure."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# -----------------------------------------------------------------------------
# Drift comparison
# -----------------------------------------------------------------------------


def check_mirror_drift(
    manifest_path: Path,
    entry: dict[str, Any],
    mirror: dict[str, Any],
    *,
    canonical_text: str | None = None,
) -> tuple[bool, str]:
    """Return (has_drift, detail). detail is an actionable error string if drift else ''.

    Raises ManifestError if canonical file missing.

    `canonical_text` lets callers pre-read the canonical file once and share it
    across multiple mirror entries for the same canonical. Omit to read on
    demand (safe default).
    """
    canonical_path = resolve_canonical(manifest_path, entry["canonical"])
    # dotfiles#495 FRAG-1: use worktree-aware resolution so the dotfiles
    # self-row mirror check looks at the WORKTREE's mirror file (synced via
    # --apply from the same worktree). Consumer-row mirrors are unchanged
    # (resolve_self_row_destination delegates to resolve_mirror for non-dotfiles).
    mirror_path = resolve_self_row_destination(
        manifest_path, mirror["repo"], mirror["path"]
    )

    if not canonical_path.is_file():
        raise ManifestError(
            f"manifest references missing canonical file '{entry['canonical']}' "
            f"(resolved to {canonical_path}). Check manifest or restore file."
        )
    if not mirror_path.is_file():
        return True, (
            f"mirror file missing: {mirror_path} "
            f"(manifest expects {mirror['repo']}/{mirror['path']})"
        )

    if mirror.get("divergent"):
        expected_sha = mirror["mirror_sha256"]
        actual_sha = sha256_of(mirror_path)
        if actual_sha != expected_sha:
            return True, (
                f"{mirror['repo']}/{mirror['path']} sha256 {actual_sha[:12]}… "
                f"(expected {expected_sha[:12]}…) — divergent mirror drifted. "
                # dotfiles#552 AC 3.1 — resolve the tool at RUNTIME rather than
                # emitting a fixed literal. propagate-mirrors.py is canonical-only,
                # so the correct prefix depends on where the operator is standing;
                # the two branches of this function used to print DIFFERENT
                # literals and at most one could be right in any given context.
                # Ralph Tier 2 round 8: "beside this module" was ALSO wrong for the
                # dotfiles self-row, where this module is mirrored flat but the tool
                # is not. propagate_tool_path() tests for the file instead.
                f"If intentional, record it. {sync_hint(mirror['repo'], entry['canonical'])}"
            )
        return False, ""

    # deterministic transform mode
    if canonical_text is None:
        canonical_text = canonical_path.read_text(encoding="utf-8")
    transforms = mirror.get("transforms", [])
    ctx = {"repo": mirror["repo"], "canonical": entry["canonical"], "path": mirror["path"]}
    expected = apply_transforms(canonical_text, transforms, ctx)
    actual = mirror_path.read_text(encoding="utf-8")
    if actual != expected:
        return True, (
            f"{mirror['repo']}/{mirror['path']} has drifted from canonical "
            f"{entry['canonical']} after transforms {transforms}. "
            # dotfiles#552 AC 3.1 — same runtime resolution as the divergent
            # branch above, so both remediation hints agree. Verified by executing
            # the printed command, not by asserting the two branches match.
            f"{sync_hint(mirror['repo'], entry['canonical'])}"
        )
    return False, ""


# -----------------------------------------------------------------------------
# Self-test of transform idempotency (used by tests + smoke checks)
# -----------------------------------------------------------------------------


def assert_idempotent() -> None:
    """Smoke-check: each transform is idempotent on a sample text.

    Intended to run at test time. Raises AssertionError on failure. Cheap
    enough to call from scripts at startup if paranoid, but not required.
    """
    sample = (
        "See ../dotfiles/SST3/ralph/foo.md and SST3/scripts/bar.py. "
        "[Issue #141](https://github.com/hoiung/dotfiles/issues/141) applies. "  # secret-allow
        "hoiung/dotfiles#404 relates. "
        "auto_pb_swing_trader and tradebook_GAS. "
        "pipeline / backtest / SL1 / SL2 / orchestration. "
        'User quote: *"example"*\n'
        "logs/sample_1234_validation.log for reference.\n"
        "# [shared]\n"
        "shared-entry-1\n"
        "# [other-repo]\n"
        "should-not-appear-in-test-subset\n"
        "# [test]\n"
        "test-specific-entry\n"
    )
    ctx = {"repo": "test", "canonical": "test", "path": "test"}
    for name, fn in TRANSFORMS.items():
        once = fn(sample, ctx)
        twice = fn(once, ctx)
        assert once == twice, f"transform {name} not idempotent"


if __name__ == "__main__":  # pragma: no cover
    # CLI self-test
    try:
        assert_idempotent()
        print("OK: transform idempotency check passed", file=sys.stderr)
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
