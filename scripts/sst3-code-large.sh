#!/usr/bin/env bash
# sst3-code-large.sh — Refactoring candidate scan: functions meeting-or-exceeding
# (>=) the line threshold — a block of exactly <min_lines> lines IS reported.
#
# Usage:   sst3-code-large.sh <min_lines> <lang>
# Example: sst3-code-large.sh 200 python
# Output:  NDJSON, one object per oversized function: {file, name, lines, kind}
#          kind: "large-fn" (ast path) | "large-md" (markdown path). `lines` is a
#          span COUNT (end - start + 1), not a line index.
# Engines: ast-grep scan --inline-rules + jq end-line minus start-line filter.
#
# #445 R4 fix: switched from `--pattern 'def $NAME($$$): $$$'` to
# `kind: function_definition` rule. The shallow pattern matched only
# `def NAME(simple): simple_body` shapes — failing on typed parameters,
# multi-line signatures, return-type annotations, async, decorators.
# Recall on <consumer-public-1> was 9/52 = 17%; the kind-rule recovers
# 52/52 (matches python ast.walk baseline), including the biggest hit
# `src/backtest/engine.py:run_strategy` at 854 lines that the old
# pattern missed entirely.

set -euo pipefail
export LC_ALL=C


SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-large" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-large" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM

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

if [[ $# -lt 2 ]]; then
    echo "ERROR: usage: $(basename "$0") <min_lines> <lang>" >&2
    exit 64
fi

MIN_LINES="$1"
# #548: route through the shared normaliser (see callees.sh for rationale).
# `md` still reaches the markdown branch below — normalise_lang maps md ->
# markdown, and that branch tests for both spellings.
LANG=$(normalise_lang "$2")

# Markdown special path — heading-block size heuristic. Closes the prose-hotspot
# coverage gap on cv-linkedin (~206 .md) + hoiboy-uk (~634 .md). Counts lines
# between consecutive `^#{1,6} ` heading lines and emits a record per block
# whose size exceeds the threshold. Approximate (does not parse YAML
# frontmatter or fenced code blocks specially) but useful for hotspot scan.
if [[ "$LANG" == "md" || "$LANG" == "markdown" ]]; then
    # #577 Stage 5 S5: jq builds the records. awk printf'd the file name and heading
    # straight into JSON, so a quote, backslash or tab in either printed an invalid
    # record, and the heading had every `\` and `"` rewritten to `_`.
    if ! command -v jq >/dev/null 2>&1; then
        echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
        exit 127
    fi
    find . -type f -name '*.md' \
        -not -path '*/node_modules/*' \
        -not -path '*/.venv/*' \
        -not -path '*/target/*' \
        -not -path '*/.git/*' \
        -not -path '*/dist/*' \
        -not -path '*/build/*' \
        -print0 2>/dev/null \
        | while IFS= read -r -d '' FILE; do
            awk -v min="$MIN_LINES" '
                /^#{1,6} / {
                    if (last_heading_line && (NR - last_heading_line) >= min) {
                        printf "%d\t%s\n", NR - last_heading_line, last_heading_text
                    }
                    last_heading_line = NR
                    last_heading_text = $0
                    sub(/^#+ */, "", last_heading_text)
                }
                END {
                    if (last_heading_line && (NR - last_heading_line + 1) >= min) {
                        printf "%d\t%s\n", NR - last_heading_line + 1, last_heading_text
                    }
                }
            ' "$FILE" | jq -Rc --arg file "$FILE" \
                'capture("^(?<n>[0-9]+)\t(?<name>.*)$") | {file: $file, name: .name, lines: (.n | tonumber), kind: "large-md"}'
        done
    exit 0
fi

# Engine checks for the non-md path (md uses awk + printf, no engines required).
if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
# #447 Phase 3: jq is the wrapper-lane JSON engine — fail-fast at startup
# instead of mid-stream `set -e` trip when jq is missing.
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# kind:-based rule per language. Captures function name via has+field rule.
case "$LANG" in
    python)
        RULE='id: large-fn
language: python
rule:
  kind: function_definition
  has:
    field: name
    pattern: $NAME'
        ;;
    typescript|tsx|javascript)
        # #547 AC 1.1 (D1): per-branch name binding. The old shared
        # `has:{field:name}` was structurally dead for arrow_function (no name
        # field) and for anonymous function_expression assigned to a
        # declarator; js class-field arrows bind via field `property`
        # (ts `public_field_definition` uses `name`) — hence the
        # name/property fallback under `inside:`.
        RULE="id: large-fn
language: $LANG
rule:
  any:
    - kind: function_declaration
      has: {field: name, pattern: \$NAME}
    - kind: method_definition
      has: {field: name, pattern: \$NAME}
    - kind: function_expression
      has: {field: name, pattern: \$NAME}
    - kind: function_expression
      inside:
        any:
          - has: {field: name, pattern: \$NAME}
          - has: {field: property, pattern: \$NAME}
    - kind: arrow_function
      inside:
        any:
          - has: {field: name, pattern: \$NAME}
          - has: {field: property, pattern: \$NAME}"
        ;;
    rust)
        RULE='id: large-fn
language: rust
rule:
  kind: function_item
  has:
    field: name
    pattern: $NAME'
        ;;
    *)
        echo "ERROR: unsupported lang: $LANG (supported: python, typescript, tsx, javascript, rust, md/markdown)" >&2
        exit 64
        ;;
esac

# #547 AC 6.1: buffer-then-check — the rc gate runs BEFORE jq sees the stream
# (a broken engine's garbage stdout cannot crash jq or leak bare stderr).
AG_OUT=$(mktemp)
AG_RC=0
ast-grep scan --inline-rules "$RULE" --json=stream > "$AG_OUT" 2>/dev/null || AG_RC=$?
ast_grep_check_rc "sst3-code-large" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
jq -c --argjson min "$MIN_LINES" '
    . as $m |
    ($m.range.end.line - $m.range.start.line + 1) as $n |
    select($n >= $min) |
    {file: $m.file, name: ($m.metaVariables.single.NAME.text // "?"), lines: $n, kind: "large-fn"}
  ' < "$AG_OUT"
rm -f "$AG_OUT"
