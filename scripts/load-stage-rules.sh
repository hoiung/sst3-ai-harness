#!/usr/bin/env bash
# load-stage-rules.sh — F-Phase-4 per-stage canonical loader (#498 AC 4.6).
#
# WHAT  Outputs the subset of SST3 canon needed by a specific /Leader stage.
#       Reads STANDARDS.md + ANTI-PATTERNS.md + WORKFLOW.md, extracts:
#         (1) Every section tagged `<!-- stages: always -->`
#         (2) Every section tagged with the requested stage number
#       For any stage N (1-5), additionally includes `standards/stage-N/*.md`
#       if that directory exists (#516 AC 1.1 — generalised from stage-4-only).
#       Concatenates to stdout for the agent's context loader to read.
#
# WHY   Pre-refactor, the agent loaded the full STANDARDS.md (1420 lines, ~49K
#       tokens) + ANTI-PATTERNS.md (645 lines, ~22K tokens) at every stage,
#       even when most sections were stage-irrelevant. Per-stage tagging +
#       this loader reduce the per-stage in-context load by ~50-70% while
#       preserving always-load sections (privacy / force-push / branch-deletion
#       / voice contamination — the Layer-2 Angle C carve-out).
#
# USAGE
#   bash scripts/load-stage-rules.sh <N>          # N = 1..5
#   bash scripts/load-stage-rules.sh always       # always-load subset
#
# EXIT  0 = stdout populated AND the extractor emitted canon; 1 = invalid stage /
#       canon files missing / extractor unreachable, failed, or silent.
#
# FAIL-FAST CONTRACT (#552 Phase 0). Before this, the script ran `set -uo pipefail`
# with no `-e` and invoked the extractor with no `|| exit`, no `$?`, no PIPESTATUS.
# When the extractor was unreachable the loader printed nothing and exited 0 — the
# `always` subset (privacy / voice / destructive-op carve-out) silently became 0
# bytes, and stage 4 silently degraded to 61,255 of 268,746 bytes because the
# stage-N/*.md cluster glob still succeeded. Both looked like success to every
# caller. Every failure path below now exits non-zero and prints a diagnostic
# carrying the fixed `load-stage-rules:` sentinel, which is this script's own —
# distinct from python3's `[Errno 2]`, which already satisfied a "non-empty stderr
# naming the extractor" test at exit 0 and so could never have proved the fix.
set -euo pipefail

# Fixed sentinel prefix — asserted by the Phase-5 execution gate (#552 AC 0.2).
die() {
  echo "load-stage-rules: $*" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <stage-number-1-to-5 | always>" >&2
  exit 1
fi
STAGE_ARG="$1"

case "$STAGE_ARG" in
  1|2|3|4|5|always) : ;;
  *)
    echo "error: stage must be 1-5 or 'always', got: $STAGE_ARG" >&2
    exit 1
    ;;
esac

# Resolve the canon root from THIS script's own location — the canon files live
# next to the script (scripts/ -> repo root is ../..) regardless of CWD.
# Do NOT use `git rev-parse --show-toplevel` as primary: when /Leader runs from a
# DIFFERENT git repo's working directory it succeeds but returns THAT repo's root,
# so the loader looks for <other-repo>/standards/… (absent) and exits 1 —
# silently defeating the per-stage subset (#498). The script's own dirname is the
# only reliable anchor for the canon files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Layout-agnostic canon resolution (#552 Phase 2). This script is vendored to the
# PUBLIC mirror, where the tree is FLATTENED: canonical is `<root>/scripts/`
# but the mirror is `<root>/scripts/`. A fixed `$SCRIPT_DIR/../..` is right for
# one and wrong for the other, which is why every mirrored stage exited 1 with
# "canon file missing" from #523 until now.
#
# Ordered candidates, first match wins, fail loudly if none -- the same shape as
# `find_manifest` in sst3_mirror_utils.py, reused rather than reinvented so there
# is ONE resolver in the codebase. Each candidate is validated by testing for the
# canon files themselves, so resolution is self-verifying rather than inferred
# from directory names.
#
# The `SST3` token below is deliberately written WITHOUT a following `<subdir>/`.
# path_scrub's _SST3_SELF_RE matches `SST3/<subdir>/`, so a bare `SST3` survives
# the mirror transform intact. Writing the candidate as a full `standards/`
# path would have let the transform rewrite this resolver's own detection string
# and collapse both candidates into one -- the self-defeating case AC 2.3 exists
# to catch.
# Nested-layout marker (#552 Ralph Tier 3 F1). The first candidate walks up TWO
# levels. That is correct nested (`<root>/scripts/` -> `<root>`) but in the
# FLATTENED mirror (`<root>/scripts/`) it lands OUTSIDE the repo entirely, where
# a sibling `SST3/` belonging to a DIFFERENT repo satisfies the canon test. The
# loader then exits 0 having loaded a foreign repo's canon, and stamps a
# provenance header naming a source it did not read -- the exact fail-open shape
# this issue exists to close, in the resolver added to close it.
#
# Reordering the candidates does NOT fix this: both match in the nested layout
# and yield different REPO_ROOT (`<root>` vs `<root>/SST3`), which is load-bearing
# for the extractor's --root and the provenance label. So discriminate on the
# layout itself: nested is exactly the case where the script's PARENT directory
# is the canon dir. `SST3` is written bare, with no trailing `<subdir>/`, for the
# same path_scrub reason documented for the candidate list above.
# Probe for the repo marker FIRST, name-heuristic only as fallback (Ralph Tier 2,
# dotfiles#552 round 2). An earlier revision used the name heuristic alone and
# claimed a `.git` probe was "NOT usable here because a tarball export has no
# `.git`". That was too broad, and Tier 2 was right to push back: probing first and
# falling THROUGH to the heuristic leaves the tarball path byte-for-byte unchanged
# while resolving every real clone correctly.
#
# ONE-UP ONLY. A `.git` directly above `scripts/` proves the repo root is one level
# up, which means FLATTENED, unambiguously. `-e` not `-d`, because `.git` is a FILE
# in a linked worktree and a DIR in a clone.
#
# A two-up probe was tried and REVERTED: it reopened the foreign-canon escape this
# discriminator exists to close. A flattened mirror with no `.git` of its own,
# unpacked inside a host repo that HAS one, made the two-up probe find the HOST's
# marker and conclude "nested" -- so candidate 1 fired and bound the host's canon:
#   exit=0  HOST_SECRET_MARKER hits: 1  MIRROR_OWN_MARKER hits: 0
# Reproduced before shipping. The one-up probe cannot make that mistake, because a
# marker one level up is positive evidence about THIS repo, never about a parent.
# Absence of a marker is not evidence either way, so absence falls through to the
# name heuristic rather than guessing upward.
# KNOWN LIMIT, still live on the FALLBACK branch only (Ralph Tier 2, dotfiles#552).
# When no `.git` marker is found one level up, the name heuristic runs, and a
# FLATTENED repo whose own checkout directory is literally named `SST3` sets
# _NESTED=1 -- because from the script's own path alone the two cases are
# genuinely indistinguishable: both put the canon at `$SCRIPT_DIR/..`, and the
# only difference is whether that dir is the repo root or a subdir of it.
# The one-up probe above removes this for every real clone and worktree; it
# survives only for a `.git`-less export (tarball/zip), which must keep working.
# Consequence is bounded and NON-CORRUPTING: CANON_DIR still resolves to the same
# real directory (the arithmetic coincides), so THE FILES READ ARE CORRECT and no
# foreign canon can be bound -- verified by executing that layout, not argued.
# Only REPO_ROOT is off by one level, which surfaces as a nested-style provenance
# label on a flattened repo. Documented rather than "fixed", because no added
# complexity resolves a genuinely ambiguous input.
if [[ -e "$SCRIPT_DIR/../.git" ]]; then
  _NESTED=0
else
  _NESTED=0
  [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == "SST3" ]] && _NESTED=1
fi

REPO_ROOT=""
CANON_DIR=""
for _cand in "$SCRIPT_DIR/../..:SST3" "$SCRIPT_DIR/..:."; do
  _root="${_cand%:*}"
  _sub="${_cand##*:}"
  # The two-level candidate is only meaningful -- and only SAFE -- when nested.
  [[ "$_sub" != "." && "$_NESTED" -eq 0 ]] && continue
  [[ -d "$_root" ]] || continue
  _root="$(cd "$_root" && pwd)"
  _canon="$_root"
  [[ "$_sub" != "." ]] && _canon="$_root/$_sub"
  if [[ -f "$_canon/standards/STANDARDS.md" \
     && -f "$_canon/standards/ANTI-PATTERNS.md" \
     && -f "$_canon/workflow/WORKFLOW.md" ]]; then
    REPO_ROOT="$_root"
    CANON_DIR="$_canon"
    break
  fi
done
[[ -n "$CANON_DIR" ]] || die "canon not found from $SCRIPT_DIR (tried the nested and flattened layouts)"

STANDARDS_MD="$CANON_DIR/standards/STANDARDS.md"
ANTIPATTERNS_MD="$CANON_DIR/standards/ANTI-PATTERNS.md"
WORKFLOW_MD="$CANON_DIR/workflow/WORKFLOW.md"
# Derived from CANON_DIR, not from REPO_ROOT. The old form hard-coded
# `$REPO_ROOT/SST3/standards`, which path_scrub did NOT rewrite because the
# reference carried no trailing slash -- so the mirror looked for a `SST3/`
# directory that does not exist there and silently loaded no stage-N clusters.
STANDARDS_DIR="$CANON_DIR/standards"

# c4:T46 (#577) — canon freshness on STDERR. One line naming the canon clone's
# branch, short SHA and behind-count against origin's default, read from the remote
# refs already on disk (no fetch, no network), so a stale canon is visible at every
# stage load. stdout stays the canon emit: the pinned `| wc -c` sizes are unchanged.
# Reported ONLY when git's own toplevel for REPO_ROOT is REPO_ROOT itself — a canon
# nested inside a host repo (a flattened mirror unpacked in another checkout) must
# not report the HOST's branch. Every git failure (no `.git`, a `.git` file pointing
# nowhere, no remote refs) omits the line or the count; none may abort the loader
# under `set -euo pipefail`, which is why each call carries its own `||`.
# Every git call runs with the git-identity variables UNSET: the loader is run from
# inside git hooks (pre-commit runs the self-test, which runs this loader), and an
# inherited GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE overrides `-C`, so the probe
# would report the HOOK's repository (dotfiles#569; AP #31). The list mirrors
# sst3_scrub_git_env in claude/hooks/_lib-repo-identity.sh, which this loader cannot
# source: it ships to mirrors that carry no claude/hooks/.
_canon_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY \
    git -C "$REPO_ROOT" "$@" 2>/dev/null
}
canon_freshness() {
  local top here branch sha def="" behind="" ref
  top="$(_canon_git rev-parse --show-toplevel)" || return 0
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 0
  here="$(cd "$REPO_ROOT" && pwd -P)" || return 0
  [[ "$top" == "$here" ]] || return 0
  branch="$(_canon_git rev-parse --abbrev-ref HEAD)" || return 0
  sha="$(_canon_git rev-parse --short HEAD)" || return 0
  for ref in "$(_canon_git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)" \
             origin/main origin/master; do
    [[ -n "$ref" ]] || continue
    if behind="$(_canon_git rev-list --count "HEAD..$ref")"; then def="$ref"; break; fi
    behind=""
  done
  if [[ -n "$def" ]]; then
    echo "load-stage-rules: canon $REPO_ROOT on $branch @ $sha, $behind behind $def" >&2
  else
    echo "load-stage-rules: canon $REPO_ROOT on $branch @ $sha, behind-count unknown (no origin default ref on disk)" >&2
  fi
}
canon_freshness || true

# Extraction logic lives in _load_stage_rules.py — single source of truth for
# the per-stage section-extraction algorithm. The .py shares regex constants
# with check-stage-tags.py via sst3_stage_tag_parser (#498 Stage 5 L1C F3).
# SCRIPT_DIR is already resolved above (canon-root anchor).
EXTRACTOR="$SCRIPT_DIR/_load_stage_rules.py"
[[ -f "$EXTRACTOR" ]] || die "extractor missing: $EXTRACTOR"

# Buffer to a temp file rather than a command substitution: `$(...)` strips
# trailing newlines, which would silently change the canonical byte counts that
# AC 0.4 pins. A file preserves the extractor's bytes exactly AND lets us test
# for the silent-empty case, which streaming straight to stdout cannot.
EXTRACT_OUT="$(mktemp)"
trap 'rm -f "$EXTRACT_OUT"' EXIT

if ! python3 "$EXTRACTOR" "$STAGE_ARG" --root "$REPO_ROOT" \
  "$STANDARDS_MD" "$ANTIPATTERNS_MD" "$WORKFLOW_MD" >"$EXTRACT_OUT"; then
  die "extractor failed for stage '$STAGE_ARG': $EXTRACTOR"
fi

# A zero-byte extraction is the failure that used to pass as success. Every row of
# the #552 harm table had the extractor contributing 0 bytes while the cluster glob
# below still emitted, so an exit-status check alone does NOT cover this — the
# extractor can exit 0 having matched nothing when the canon paths resolve wrongly.
[[ -s "$EXTRACT_OUT" ]] || die "extractor produced no canon for stage '$STAGE_ARG' — refusing to emit a partial subset"

cat "$EXTRACT_OUT"

# Per-stage cluster files: any standards/stage-N/ directory is loaded for
# stage N (#516 AC 1.1 — generalised from the prior stage-4-only special case).
# The loader globs stage-{1,2,3,4,5}/*.md when the directory exists; 'always'
# has no cluster dir. Backward-compatible: stage-4 still loads stage-4/*.md.
# KNOWN LIMIT (#552 Ralph Tier 3 round 9) -- this glob FAILS OPEN on a missing
# cluster directory, and that is deliberate rather than overlooked. Measured: moving
# standards/stage-4/ away takes stage 4 from 268607 to 207365 bytes (-22.8%) at
# rc=0 with empty stderr, dropping verification-loop.md, ralph-review.md,
# gate-2-merge.md and gate-3-user-review.md -- a mirror without them would run
# Stage 4 with no verification loop and no Ralph checklist.
#
# The loader CANNOT close this itself. stage-3 legitimately has no cluster directory
# (counts today: stage-1 1, stage-2 2, stage-3 ABSENT, stage-4 12, stage-5 1), so a
# "the directory must exist" rule false-positives on stage 3, and from inside a
# mirror an absent directory is indistinguishable from a legitimately absent one.
# Asserting an expected per-stage file count here would fail closed on every
# legitimate canon edit instead.
#
# It is closed one layer out, where the information actually exists: every
# standards/stage-*/*.md file is declared MIRRORED in drift-manifest.json (0
# canonical-only, 0 undeclared), and `check-mirror-drift.py --repo <mirror> --strict`
# exits non-zero on a MISSING mirror file, naming it. That check works today and is
# wired to nothing -- wiring it is sequenced after Gate-2 propagation, because the
# published mirror is drifted until then and the gate would go red on arrival.
if [[ "$STAGE_ARG" =~ ^[1-5]$ ]]; then
  STAGE_DIR="$STANDARDS_DIR/stage-$STAGE_ARG"
  if [[ -d "$STAGE_DIR" ]]; then
    _CLUSTER_EMITTED=0
    for f in "$STAGE_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      # #555 AC 2.4 (the F2 root cause): a cluster file carrying stage tags is
      # TAG-FILTERED through the same extractor the canon files use, so routing
      # content into a cluster no longer converts a taggable rule into an
      # unconditionally-loaded one. An untagged cluster file still cat's whole —
      # its directory IS its stage scope (backward compatible; a partially
      # tagged file must be FULLY tagged before it gains its first tag, or the
      # extractor silently drops its untagged sections).
      if grep -q '<!-- stages:' "$f"; then
        # --emit-preamble (#555 Stage 5): cluster files were cat'd whole
        # pre-#555, so their H1 + intro must survive tag-filtering (an H1
        # cannot carry a section tag — walk_sections starts at ##).
        python3 "$SCRIPT_DIR/_load_stage_rules.py" "$STAGE_ARG" --emit-preamble --root "$REPO_ROOT" "$f" \
          || die "tag-filtered cluster extraction failed for $f (stage $STAGE_ARG)"
      else
        printf '\n<!-- ===== %s ===== -->\n' "${f#"$REPO_ROOT"/}"
        cat "$f"
      fi
      _CLUSTER_EMITTED=1
    done
    # The one case the loader CAN see unambiguously: the directory is present but
    # yields nothing. A stage cluster dir never legitimately exists while empty --
    # it is created to hold files -- so this is a partial-sync signature, not a
    # shape any canon edit produces.
    [[ "$_CLUSTER_EMITTED" -eq 1 ]] || die "stage-$STAGE_ARG cluster directory exists but contains no .md files: $STAGE_DIR — refusing to emit a subset missing its whole cluster"
  fi
fi
