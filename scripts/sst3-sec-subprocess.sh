#!/usr/bin/env bash
# sst3-sec-subprocess.sh — Surface every shell-out / subprocess invocation site.
#
# Usage:   sst3-sec-subprocess.sh [<lang>] [--paths-from <ndjson>]
#          (lang optional; default scans python+rust+javascript)
# Output:  NDJSON, one object per call site:
#          {file, line, function, args_shape}
#          line is a 1-indexed editor line (#547 AC 7.1).
#          function: subprocess.run|subprocess.Popen|subprocess.call|os.system|os.popen|Command::new|child_process.exec|child_process.execSync|child_process.spawn
#          args_shape: "literal" | "interpolated" | "var" (best-effort static eyeball)
# Engines: ast-grep (Python + Rust + JS + TypeScript pattern set)
#
# Rationale (#447 Phase 8 — security audit coverage gap): pre-baked patterns
# turn the security-audit scenario from "remember every shell-out form across
# languages" into a single wrapper call. Subagents/auditors get a uniform
# NDJSON contract regardless of source language.

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

trap 'wrapper_sentinel "sst3-sec-subprocess" "$SST3_EMITTED_COUNT" "subprocess-call"' EXIT
on_sigterm() {
    jq -nc --arg n "sst3-sec-subprocess" --argjson e "$SST3_EMITTED_COUNT" \
        '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    exit 143
}
trap on_sigterm SIGTERM

LANG_ARG=""
PATHS_FROM=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from)
            PATHS_FROM="${2:-}"
            shift 2 || break
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
if [[ ${#ARGS[@]} -gt 0 ]]; then
    LANG_ARG="${ARGS[0]}"
fi

if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# Optional paths-from filter: collect allowed paths into an array.
# Stage 5 fix — explicit readability check (read_paths_from exits 64 inside
# process substitution, which doesn't terminate the parent: was failing OPEN
# on unreadable file by emitting full unfiltered output with exit 0).
declare -a ALLOWED_PATHS=()
if [[ -n "$PATHS_FROM" ]]; then
    if [[ ! -r "$PATHS_FROM" ]]; then
        echo "ERROR: --paths-from file not readable: $PATHS_FROM" >&2
        exit 64
    fi
    load_paths_from "$PATHS_FROM" ALLOWED_PATHS
fi
# The engine scans the listed files themselves (sst3-bash-utils.sh paths_from_scan_targets).
declare -a SCAN_TARGETS=()
paths_from_scan_targets ALLOWED_PATHS SCAN_TARGETS

path_allowed() {
    local file="$1"
    [[ ${#ALLOWED_PATHS[@]} -eq 0 ]] && return 0
    for allowed in "${ALLOWED_PATHS[@]}"; do
        [[ "$file" == "$allowed" || "$file" == "./$allowed" ]] && return 0
    done
    return 1
}

# Per-language patterns. Each row: lang|function-name|ast-grep pattern.
PY_PATTERNS=(
    "python|subprocess.run|subprocess.run(\$\$\$)"
    "python|subprocess.Popen|subprocess.Popen(\$\$\$)"
    "python|subprocess.call|subprocess.call(\$\$\$)"
    "python|subprocess.check_output|subprocess.check_output(\$\$\$)"
    "python|os.system|os.system(\$\$\$)"
    "python|os.popen|os.popen(\$\$\$)"
)
RS_PATTERNS=(
    "rust|Command::new|Command::new(\$\$\$)"
)
JS_PATTERNS=(
    "javascript|child_process.exec|child_process.exec(\$\$\$)"
    "javascript|child_process.execSync|child_process.execSync(\$\$\$)"
    "javascript|child_process.spawn|child_process.spawn(\$\$\$)"
)
# The same calls in TypeScript. ast-grep's javascript grammar does not read .ts files,
# and the sst3-sec hook passes them, so until #577's escalation sweep a net-new
# child_process.exec in a .ts file passed unscanned. ast-grep reads .tsx only under its
# own tsx grammar, so the .tsx rows are separate (#577 Ralph r6 T3: the hook passes
# every extension these grammars read, `.pre-commit-config.yaml` sst3-sec `files:`).
TS_PATTERNS=(
    "typescript|child_process.exec|child_process.exec(\$\$\$)"
    "typescript|child_process.execSync|child_process.execSync(\$\$\$)"
    "typescript|child_process.spawn|child_process.spawn(\$\$\$)"
    "tsx|child_process.exec|child_process.exec(\$\$\$)"
    "tsx|child_process.execSync|child_process.execSync(\$\$\$)"
    "tsx|child_process.spawn|child_process.spawn(\$\$\$)"
)

declare -a SELECTED=()
if [[ -z "$LANG_ARG" ]]; then
    SELECTED=("${PY_PATTERNS[@]}" "${RS_PATTERNS[@]}" "${JS_PATTERNS[@]}" "${TS_PATTERNS[@]}")
else
    LANG_NORM=$(normalise_lang "$LANG_ARG")
    case "$LANG_NORM" in
        python) SELECTED=("${PY_PATTERNS[@]}") ;;
        rust) SELECTED=("${RS_PATTERNS[@]}") ;;
        javascript) SELECTED=("${JS_PATTERNS[@]}") ;;
        typescript) SELECTED=("${TS_PATTERNS[@]}") ;;
        *)
            echo "ERROR: sst3-sec-subprocess only supports python|rust|javascript|typescript (got: $LANG_NORM)" >&2
            exit 64
            ;;
    esac
fi

emit_record() {
    local file="$1" line="$2" func="$3" args_shape="$4" end_line="${5:-$2}"
    if path_allowed "$file"; then
        jq -nc --arg f "$file" --argjson l "$line" --argjson e "$end_line" --arg fn "$func" --arg as "$args_shape" \
            '{file:$f, line:$l, end_line:$e, function:$fn, args_shape:$as}'
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    fi
}

infer_args_shape() {
    local snippet="$1"
    if [[ "$snippet" =~ \"[^\"]+\"$|\'[^\']+\'$ ]]; then
        echo "literal"
    elif [[ "$snippet" =~ \{|f\"|\$\{|\+\  ]]; then
        echo "interpolated"
    else
        echo "var"
    fi
}

AG_OUT=$(mktemp)
for spec in "${SELECTED[@]}"; do
    [[ ${#SCAN_TARGETS[@]} -gt 0 ]] || break  # a list naming no existing file: scan nothing
    IFS='|' read -r lang func pattern <<< "$spec"
    AG_RC=0
    run_over_targets "$AG_OUT" SCAN_TARGETS ast-grep run --pattern "$pattern" --lang "$lang" --json=stream || AG_RC=$?
    ast_grep_check_rc "sst3-sec-subprocess" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        end_line=$(jq -r '(.range.end.line + 1) // 0' <<< "$record")  # a call can span lines (#577)
        text=$(jq -r '.text // ""' <<< "$record")
        [[ -z "$file" ]] && continue
        shape=$(infer_args_shape "$text")
        emit_record "$file" "$line" "$func" "$shape" "$end_line"
    done < "$AG_OUT"
done
rm -f "$AG_OUT"

exit 0
