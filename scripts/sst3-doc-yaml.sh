#!/usr/bin/env bash
# sst3-doc-yaml.sh — YAML lint for SST3 configs (yamllint wrapper).
#
# Usage:   sst3-doc-yaml.sh [paths...]
# Default: lints .github/, .pre-commit-config.yaml, SST3/**/*.yml, SST3/**/*.yaml
# Output:  NDJSON, one object per violation: {file, line, level, rule, description}
# Engine:  yamllint (pipx). Exit 127 + stderr contract on missing engine.

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

if ! command -v yamllint >/dev/null 2>&1; then
    echo 'ERROR: yamllint not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

if [[ $# -eq 0 ]]; then
    PATHS=('.github/' '.pre-commit-config.yaml' 'SST3/')
    # Filter to existing paths only.
    EXISTING=()
    for p in "${PATHS[@]}"; do
        [[ -e "$p" ]] && EXISTING+=("$p")
    done
    PATHS=("${EXISTING[@]}")
else
    PATHS=("$@")
fi

# Empty-paths guard (#447 Phase 2): yamllint invoked with no args has undefined
# behaviour across versions (some scan cwd, others error). Fail loud + clean
# rather than silent-zero or scan-the-world.
if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "sst3-doc-yaml: no input paths" >&2
    exit 0
fi

VIOLATION_COUNT=0

# Universal "I ran" sentinel — emit on every exit path (#447 Phase 2).
trap 'printf "sst3-doc-yaml: scanned %d path(s), %d violation(s)\n" "${#PATHS[@]}" "${VIOLATION_COUNT:-0}" >&2' EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-doc-yaml" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-doc-yaml" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM


# yamllint -f parsable emits: <file>:<line>:<col>: [<level>] <description> (<rule>)
#
# #577 escalation (class C3, fail-open reader). This ran as
# `yamllint ... 2>/dev/null || true`: one file yamllint cannot decode (an
# invalid UTF-8 byte) raises a traceback that ENDS the batch, every file after
# it went unlinted, and exit 1 looked the same as "violations found". The
# batch now runs once with its stderr and status kept; on a crash each file is
# re-linted alone (`--list-files` expands directories the way yamllint's own
# config does), so every other file is still linted and each crashing file is
# named in a sst3-doc-yaml-error record, and the wrapper exits 3 (could not
# look). Not a UTF-8 pre-check: yamllint reads UTF-16 YAML with a BOM.
YL_OUT="$(mktemp)"
YL_ERR="$(mktemp)"
CRASHED=0
yl_crashed() { grep -q '^Traceback' "$YL_ERR" || (( $1 > 2 )); }
yl_rc=0
yamllint -f parsable "${PATHS[@]}" >"$YL_OUT" 2>"$YL_ERR" || yl_rc=$?
if yl_crashed "$yl_rc"; then
    : >"$YL_OUT"
    if ! mapfile -t YL_FILES < <(yamllint --list-files "${PATHS[@]}" 2>/dev/null) || [[ ${#YL_FILES[@]} -eq 0 ]]; then
        jq -nc --arg r "$(grep -v '^ ' "$YL_ERR" | tail -1 | cut -c1-200)" \
            '{kind:"sst3-doc-yaml-error", file:null, reason:("yamllint crashed and could not list its files: " + $r)}'
        CRASHED=1
        YL_FILES=()
    fi
    for f in "${YL_FILES[@]}"; do
        rc=0
        yamllint -f parsable "$f" >>"$YL_OUT" 2>"$YL_ERR" || rc=$?
        if yl_crashed "$rc"; then
            jq -nc --arg f "$f" --arg r "$(grep -v '^ ' "$YL_ERR" | tail -1 | cut -c1-200)" \
                '{kind:"sst3-doc-yaml-error", file:$f, reason:("yamllint crashed: " + $r)}'
            CRASHED=1
        fi
    done
fi
# Pipe through a counter that increments VIOLATION_COUNT (reading a file, not a
# subshell, to avoid the subshell-counter trap that bit Bug B in sst3-check.sh).
# The line is split from the RIGHT (greedy path, then :line:col:) so a path
# holding a colon keeps its line number.
while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^(.*):([0-9]+):([0-9]+):\ (.*)$ ]]; then
        FILE="${BASH_REMATCH[1]}"; LN="${BASH_REMATCH[2]}"; REST="${BASH_REMATCH[4]}"
    else
        FILE="$LINE"; LN=0; REST="$LINE"
    fi
    LEVEL=$(echo "$REST" | grep -oE '\[(error|warning)\]' | tr -d '[]' || echo "info")
    RULE=$(echo "$REST" | grep -oE '\([a-z-]+\)$' | tr -d '()' || echo "unknown")
    DESC=$(echo "$REST" | sed -E 's/^\s*\[(error|warning)\]\s*//; s/\s*\([a-z-]+\)$//')
    jq -nc --arg f "$FILE" --argjson l "$LN" --arg lv "$LEVEL" --arg r "$RULE" --arg d "$DESC" \
        '{file: $f, line: $l, level: $lv, rule: $r, description: $d}'
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
done <"$YL_OUT"
rm -f "$YL_OUT" "$YL_ERR"
[[ "$CRASHED" -eq 0 ]] || exit 3
