#!/usr/bin/env bash
# sst3-sync-related-code.sh — Frontmatter `related_code:` path drift detector.
#
# Usage:   sst3-sync-related-code.sh [--strict] [paths...]
# Default: scans docs/research/**/*.md; a directory argument is expanded the same way
# Output:  NDJSON, one object per cited path: {doc, line, claimed_path, exists};
#          a doc that could not be read or decoded as UTF-8 yields
#          {kind:"sst3-sync-related-code-error", doc, reason}
# Exit:    0 clean (or drift without --strict); 1 --strict and a cited path is
#          missing; 3 a doc could not be read (could not look), strict or not
# Engine:  python3 (PyYAML optional). No external engines required.
# Note:    This is the wrapper that would have caught Stage 5 finding 3 (the
#          AST_ANALYSIS.md L27 + L805 path drift) automatically.

set -euo pipefail
export LC_ALL=C

if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# #447 Phase 3: standardise arg parsing on the canonical case-loop pattern.
STRICT=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done

# #577 escalation (class C3, fail-open reader): a directory argument is expanded
# the way the default is (it used to be skipped by a `-f` test, so a directory
# checked nothing and exited 0), and names are read NUL-delimited.
# #447 Phase 3: -P prevents symlink-following.
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

# Repo root for resolving paths cited in frontmatter
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
DEVPROJECTS_ROOT=$(dirname "$REPO_ROOT")

MISSING_COUNT=0
UNREADABLE_COUNT=0

# Universal "I ran" sentinel — emit on every exit path (#447 Phase 2, silent-zero).
trap 'printf "sst3-sync-related-code: scanned %d path(s), %d missing path(s), %d unreadable\n" "${#PATHS[@]}" "${MISSING_COUNT:-0}" "${UNREADABLE_COUNT:-0}" >&2' EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-sync-related-code" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-sync-related-code" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM

# #577 escalation (class C3, fail-open reader). The checker ran as
# `OUT=$(python3 ...) || true` and answered a read failure with a bare
# `sys.exit(0)`, so a doc it could not read (a byte that is not UTF-8 raised
# UnicodeDecodeError, which nothing caught) produced no record and passed
# `--strict`; a missing path was skipped by a `-f` test. Each now emits a
# sst3-sync-related-code-error record naming the doc, and the wrapper exits 3
# (could not look), strict or not.
for FILE in "${PATHS[@]+"${PATHS[@]}"}"; do
    # Symlink guard (security audit L1B): refuse to follow symlinks to avoid
    # path-traversal class (e.g. malicious symlink to /etc/shadow).
    if [[ -L "$FILE" ]]; then
        echo "WARN: skipping symlink $FILE (sst3-sync-related-code refuses to follow symlinks)" >&2
        continue
    fi
    rc=0
    OUT=$(python3 - "$FILE" "$DEVPROJECTS_ROOT" <<'EOF'
import sys, os, re, json
file_path, dp_root = sys.argv[1], sys.argv[2]
try:
    with open(file_path, encoding="utf-8") as f:
        content = f.read()
except (OSError, UnicodeDecodeError) as exc:
    print(json.dumps({"kind": "sst3-sync-related-code-error", "doc": file_path, "reason": f"{type(exc).__name__}: {exc}"}))
    sys.exit(3)
# Match YAML frontmatter at file start OR after a heading prelude.
# Both forms found in dotfiles/docs/research/.
fm = None
fm_start_line = 0
m = re.match(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if m:
    fm = m.group(1)
    fm_start_line = 1
else:
    # Search for a YAML block delimited by --- elsewhere in the file
    for sm in re.finditer(r'(?m)^---\s*$', content):
        start = sm.end()
        em = re.search(r'(?m)^---\s*$', content[start:])
        if em:
            fm = content[start:start+em.start()]
            fm_start_line = content[:sm.start()].count('\n') + 2
            break
if not fm:
    sys.exit(0)
in_block = False
for i, line in enumerate(fm.split('\n'), start=fm_start_line):
    s = line.rstrip()
    if re.match(r'^related_code\s*:\s*$', s):
        in_block = True
        continue
    if in_block:
        m2 = re.match(r'^\s+-\s+file:\s*(\S.*)$', s)
        if m2:
            cited = m2.group(1).strip().strip('"\'')
            full = os.path.join(dp_root, cited)
            print(json.dumps({"doc": file_path, "line": i, "claimed_path": cited, "exists": os.path.exists(full)}))
        elif re.match(r'^[a-z_]+\s*:', s):
            in_block = False
EOF
) || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
        OUT=$(python3 -c 'import json, sys; print(json.dumps({"kind": "sst3-sync-related-code-error", "doc": sys.argv[1], "reason": "checker exited " + sys.argv[2]}))' "$FILE" "$rc")
        rc=3
    fi
    [[ -n "$OUT" ]] && echo "$OUT"
    if [[ "$rc" -eq 3 ]]; then
        UNREADABLE_COUNT=$((UNREADABLE_COUNT + 1))
    fi
    if [[ "$STRICT" -eq 1 ]] && grep -q '"exists": false' <<<"$OUT"; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
done

[[ "$UNREADABLE_COUNT" -eq 0 ]] || exit 3
[[ "$STRICT" -eq 1 ]] && [[ "$MISSING_COUNT" -gt 0 ]] && exit 1
exit 0
