#!/usr/bin/env bash
# sst3-doc-frontmatter.sh — Frontmatter presence + required-fields validator.
#
# Usage:   sst3-doc-frontmatter.sh [--strict] [paths...]
# Default: scans docs/research/**/*.md; a directory argument is expanded the same way
# Output:  NDJSON, one object per file: {file, has_frontmatter, missing_fields, valid};
#          a file that could not be read or decoded as UTF-8 adds {error, reason}
# Exit:    0 clean (or findings without --strict); 1 --strict and a file is invalid;
#          3 a file could not be read (could not look), strict or not
# Engine:  python3 (stdlib regex; no PyYAML, no awk path exists). Required fields per
#          docs/research/ convention: domain, type, topics, last_updated, sources, coverage.
# Note:    Reports both presence (has_frontmatter) and required-field coverage.

set -euo pipefail
export LC_ALL=C

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"

# --paths-from retrofit (#447 Phase 8): strip --paths-from from positional args
# and (if a filter NDJSON was supplied) install a transparent stdout filter
# via activate_paths_from_filter from sst3-bash-utils.sh.
__PATHS_FROM_SST3=""
__ARGS_SST3=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from) __PATHS_FROM_SST3="${2:-}"; shift 2 || break;;
        *) __ARGS_SST3+=("$1"); shift;;
    esac
done
set -- "${__ARGS_SST3[@]+"${__ARGS_SST3[@]}"}"
activate_paths_from_filter "$__PATHS_FROM_SST3"

if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

REQUIRED='domain type topics last_updated sources coverage'

# #447 Phase 3: standardise arg parsing on the canonical case-loop pattern
# (already used in sst3-code-callees.sh:34-39). Replaces the prior
# positional-only `if [[ "${1:-}" == "--strict" ]]` check that broke when
# --strict was passed second or in any other position.
STRICT=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done

# #577 escalation (class C3, fail-open reader): a directory argument is expanded
# the way the default is. It used to reach the `-f` skip in the loop, so
# `sst3-doc-frontmatter.sh docs/research` checked nothing and exited 0. Names
# are read NUL-delimited so a newline in a name cannot split it.
# #447 Phase 3: -P prevents symlink-following (defensive against any malicious
# symlink in docs/research/).
PATHS=()
if [[ ${#ARGS[@]} -eq 0 ]]; then
    [[ -d docs/research ]] && ARGS=(docs/research)
fi
for arg in "${ARGS[@]+"${ARGS[@]}"}"; do
    if [[ -d "$arg" && ! -L "$arg" ]]; then
        mapfile -d '' -t FOUND < <(find -P "$arg" -name '*.md' -type f -print0)
        PATHS+=("${FOUND[@]+"${FOUND[@]}"}")
    else
        PATHS+=("$arg")
    fi
done

INVALID_COUNT=0
UNREADABLE_COUNT=0

# Universal "I ran" sentinel — emit on every exit path (#447 Phase 2, silent-zero
# class fix). Without this, a missing docs/research/ directory (or zero matches)
# produced exit 0 + no stderr, indistinguishable from "all valid".
trap 'printf "sst3-doc-frontmatter: scanned %d path(s), %d invalid record(s), %d unreadable\n" "${#PATHS[@]}" "${INVALID_COUNT:-0}" "${UNREADABLE_COUNT:-0}" >&2' EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-doc-frontmatter" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-doc-frontmatter" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM

# #577 escalation (class C3, fail-open reader). The checker ran as
# `OUT=$(python3 ...) || true` and caught only OSError, so a file holding one
# byte that is not UTF-8 raised UnicodeDecodeError, the `|| true` swallowed it,
# the file produced no record at all and `--strict` passed it. A missing path
# was skipped by a `-f` test the same way. Every file now yields a record:
# one the checker cannot read is `valid:false` with `error:"read_failed"` and a
# reason, a checker that dies is `error:"checker_crashed"`, and either makes
# the wrapper exit 3 (could not look), strict or not.
for FILE in "${PATHS[@]+"${PATHS[@]}"}"; do
    rc=0
    OUT=$(python3 - "$FILE" "$REQUIRED" <<'EOF'
import sys, json, re
file_path, required = sys.argv[1], sys.argv[2].split()
try:
    with open(file_path, encoding="utf-8") as f:
        content = f.read()
except (OSError, UnicodeDecodeError) as exc:
    print(json.dumps({"file": file_path, "has_frontmatter": False, "missing_fields": required, "valid": False, "error": "read_failed", "reason": f"{type(exc).__name__}: {exc}"}))
    sys.exit(3)
m = re.match(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    print(json.dumps({"file": file_path, "has_frontmatter": False, "missing_fields": required, "valid": False}))
    sys.exit(0)
fm = m.group(1)
present = set(re.findall(r'^([a-z_][a-z_0-9]*)\s*:', fm, re.MULTILINE))
missing = [f for f in required if f not in present]
print(json.dumps({"file": file_path, "has_frontmatter": True, "missing_fields": missing, "valid": len(missing) == 0}))
EOF
) || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]] || [[ -z "$OUT" ]]; then
        OUT=$(python3 -c 'import json, sys; print(json.dumps({"file": sys.argv[1], "has_frontmatter": False, "missing_fields": sys.argv[2].split(), "valid": False, "error": "checker_crashed", "reason": "checker exited " + sys.argv[3]}))' "$FILE" "$REQUIRED" "$rc")
        rc=3
    fi
    echo "$OUT"
    if [[ "$rc" -eq 3 ]]; then
        UNREADABLE_COUNT=$((UNREADABLE_COUNT + 1))
    fi
    if [[ "$STRICT" -eq 1 ]] && grep -q '"valid": false' <<<"$OUT"; then
        INVALID_COUNT=$((INVALID_COUNT + 1))
    fi
done

[[ "$UNREADABLE_COUNT" -eq 0 ]] || exit 3
[[ "$STRICT" -eq 1 ]] && [[ "$INVALID_COUNT" -gt 0 ]] && exit 1
exit 0
