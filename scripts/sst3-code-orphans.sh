#!/usr/bin/env bash
# sst3-code-orphans.sh — Dead-code (orphan) detection.
#
# Usage:   sst3-code-orphans.sh <lang> [--allowlist <path>] [--paths-from <ndjson>]
# Example: sst3-code-orphans.sh python
# Output:  NDJSON, one object per orphan symbol:
#          {file, line, symbol, kind, exported, last_modified}
#          line is a 1-indexed editor line (#547 AC 7.1).
#          kind: function | method | class
#          exported: true if symbol is referenced in `__all__` or `pub` exposure
#          last_modified: ISO8601 from `git log -1 --format=%aI` (best-effort)
# Engines: ast-grep (def lookup + batch caller-name index; #544 — NOT composed
#          from sst3-code-callers.sh, the index is built inline) + git log.
#
# Rationale (#447 Phase 8): functions with 0 callers AND 0 imports across the
# repo. Allowlist-aware (mirrors Bug G fix in sync-doc-to-code) so monkey-
# patched / dynamically-loaded symbols don't false-positive.

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

on_sigterm() {
    jq -nc --arg n "sst3-code-orphans" --argjson e "$SST3_EMITTED_COUNT" \
        '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    exit 143
}
trap on_sigterm SIGTERM
# (EXIT trap registered later, after $ALLOW is created — combines tmpfile
# cleanup with wrapper_sentinel to avoid overwriting the sentinel registration.)

PATHS_FROM=""
ALLOWLIST_PATH=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from)
            PATHS_FROM="${2:-}"
            shift 2 || break
            ;;
        --allowlist)
            ALLOWLIST_PATH="${2:-}"
            shift 2 || break
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <lang> [--allowlist <path>] [--paths-from <ndjson>]" >&2
    exit 64
fi

LANG=$(normalise_lang "${ARGS[0]}")

if [[ "$LANG" != "python" ]]; then
    echo "ERROR: orphan detection currently supports python only (got: $LANG); rust/javascript follow-up" >&2
    exit 64
fi

if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

declare -a ALLOWED_PATHS=()
if [[ -n "$PATHS_FROM" ]]; then
    if [[ ! -r "$PATHS_FROM" ]]; then
        echo "ERROR: --paths-from file not readable: $PATHS_FROM" >&2
        exit 64
    fi
    load_paths_from "$PATHS_FROM" ALLOWED_PATHS
fi
path_allowed() {
    local file="$1"
    [[ ${#ALLOWED_PATHS[@]} -eq 0 ]] && return 0
    for allowed in "${ALLOWED_PATHS[@]}"; do
        [[ "$file" == "$allowed" || "$file" == "./$allowed" ]] && return 0
    done
    return 1
}

# Build allowlist: explicit file + any name in `__all__` lists.
ALLOW=$(mktemp)
# Stage 5 fix (D1) — batch caller-name index; was spawning `bash callers.sh`
# per def (O(defs × repo-scan); ~50-80 min on 1000-file Python repos). Now
# one ast-grep pass collects all bare-call call-sites grouped by callee name.
CALLER_INDEX=$(mktemp)
# Combine tmpfile cleanup with wrapper_sentinel for EXIT (Ralph Tier 3 FAIL C).
trap 'rm -f "$ALLOW" "$CALLER_INDEX"; wrapper_sentinel "sst3-code-orphans" "$SST3_EMITTED_COUNT" "orphan"' EXIT
trap 'rm -f "$ALLOW" "$CALLER_INDEX"' INT TERM
if [[ -n "$ALLOWLIST_PATH" && -r "$ALLOWLIST_PATH" ]]; then
    grep -vE '^\s*(#|$)' "$ALLOWLIST_PATH" >> "$ALLOW" || true
fi

# Extract __all__ entries best-effort. Each ast-grep run buffers to $AG_OUT and
# routes its real rc through ast_grep_check_rc (#547 AC 6.1 — a broken engine
# emits the -error record and exits 0 instead of a silent all-zero pass).
AG_OUT=$(mktemp)
AG_RC=0
ast-grep run --pattern '__all__ = $$$' --lang python --json=stream > "$AG_OUT" 2>/dev/null || AG_RC=$?
ast_grep_check_rc "sst3-code-orphans" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
while IFS= read -r record; do
    [[ -z "$record" ]] && continue
    text=$(jq -r '.text // ""' <<< "$record")
    while IFS= read -r tok; do
        [[ -n "$tok" ]] && echo "$tok" >> "$ALLOW"
    done < <(printf '%s' "$text" | grep -oE "['\"][a-zA-Z_][a-zA-Z0-9_]*['\"]" | tr -d "'\"")
done < "$AG_OUT"

# Also match PEP 526 annotated form: `__all__: list[str] = [...]` (Ralph Tier 3 FAIL E).
AG_RC=0
ast-grep run --pattern '__all__: $TYPE = $$$' --lang python --json=stream > "$AG_OUT" 2>/dev/null || AG_RC=$?
ast_grep_check_rc "sst3-code-orphans" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
while IFS= read -r record; do
    [[ -z "$record" ]] && continue
    text=$(jq -r '.text // ""' <<< "$record")
    while IFS= read -r tok; do
        [[ -n "$tok" ]] && echo "$tok" >> "$ALLOW"
    done < <(printf '%s' "$text" | grep -oE "['\"][a-zA-Z_][a-zA-Z0-9_]*['\"]" | tr -d "'\"")
done < "$AG_OUT"

# Build the caller-name index ONCE — equivalent to running sst3-code-callers
# for every possible name in one batch. `$NAME($$$)` binds NAME to the FULL
# dotted callee for receiver/module-qualified calls (`obj.foo()` → `obj.foo`,
# `mod.foo()` → `mod.foo`), so keying the index by the raw binding made every
# symbol called ONLY through a receiver a FALSE-POSITIVE orphan (the #496
# recall class, fixed here under #544 Stage 5). Reduce each callee to its
# last dotted component so bare-name lookups count both shapes — matching
# post-#496 callers.sh recall. Same-name methods on different classes can
# over-count a shared name, which errs SAFE for an orphan detector (a missed
# orphan, never a false deletion candidate).
set +o pipefail
ast-grep run --pattern '$NAME($$$)' --lang python --json=stream 2>/dev/null \
    | jq -r '.metaVariables.single.NAME.text // empty' 2>/dev/null \
    | grep -E '^[a-zA-Z_][a-zA-Z0-9_.]*$' \
    | awk -F'.' '{print $NF}' \
    | sort | uniq -c | awk '{print $2"\t"$1}' > "$CALLER_INDEX"
AG_RC=${PIPESTATUS[0]}
set -o pipefail
ast_grep_check_rc "sst3-code-orphans" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }

# O(1)-ish lookup: extract count column for matching key, default 0 if missing.
caller_count() {
    awk -F'\t' -v k="$1" '$1 == k { print $2; found=1; exit } END { if (!found) print 0 }' "$CALLER_INDEX"
}

# Extract def + class definitions — #547 AC 2.1 (D2+D3): kind-rules replace
# the shape patterns (`def $NAME($$$): $$$` missed every return-type-annotated
# def; `class $NAME: $$$` missed every based/metaclass class). Rule convention
# = impact.sh EXTRACT_RULE (#546).
# shellcheck disable=SC2016  # $NAME is an ast-grep meta-var, not shell
DEF_RULES=(
    'function|id: orphan-defs
language: python
rule:
  kind: function_definition
  has:
    field: name
    pattern: $NAME'
    'class|id: orphan-defs
language: python
rule:
  kind: class_definition
  has:
    field: name
    pattern: $NAME'
)

for spec in "${DEF_RULES[@]}"; do
    # Parameter-expansion split — an IFS read would TRUNCATE the multi-line
    # rule at the first newline (#547 AC 2.1 probe: 19 garbage chars survive).
    kind="${spec%%|*}"
    rule="${spec#*|}"
    AG_RC=0
    ast-grep scan --inline-rules "$rule" --json=stream > "$AG_OUT" 2>/dev/null || AG_RC=$?
    ast_grep_check_rc "sst3-code-orphans" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        name=$(jq -r '.metaVariables.single.NAME.text // ""' <<< "$record")
        [[ -z "$file" || -z "$name" ]] && continue
        path_allowed "$file" || continue
        # Skip dunder + leading-underscore (private convention) + test_ functions.
        [[ "$name" =~ ^__|^_|^test_ ]] && continue
        # NOTE: do NOT skip allowlisted symbols here — emit them with exported:true
        # so consumers can filter intentionally-public-but-no-in-repo-caller cases.
        # (Stage 5 fix — was making the exported field permanently false.)
        # Count callers via batch index (Stage 5 D1 perf fix).
        callers_count=$(caller_count "$name")
        if [[ "$callers_count" -gt 0 ]]; then
            continue
        fi
        # Last-modified via git.
        last_mod=$(git log -1 --format=%aI -- "$file" 2>/dev/null || echo "")
        # Exported = present in __all__.
        exported="false"
        if [[ -s "$ALLOW" ]] && grep -Fxq "$name" "$ALLOW"; then
            exported="true"
        fi
        jq -nc --arg f "$file" --argjson l "$line" --arg s "$name" --arg k "$kind" \
            --arg lm "$last_mod" --argjson e "$exported" \
            '{file:$f, line:$l, symbol:$s, kind:$k, exported:$e, last_modified:$lm}'
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    done < "$AG_OUT"
done
rm -f "$AG_OUT"

exit 0
