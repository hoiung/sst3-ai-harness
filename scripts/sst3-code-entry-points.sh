#!/usr/bin/env bash
# sst3-code-entry-points.sh — Pre-baked entry-point discovery.
#
# Usage:   sst3-code-entry-points.sh <lang>
# Example: sst3-code-entry-points.sh python
# Output:  NDJSON, one object per entry point:
#          {file, line, kind, symbol}
#          line is a 1-indexed editor line (#547 AC 7.1).
#          kind: main | cli | http_handler | controller_init | service_main
# Engines: ast-grep pre-baked patterns per language.
#
# Rationale (#447 Phase 8): closes the onboarding-scenario gap (44% coverage).
# A new contributor / subagent can ask "where does this codebase START?"
# and get a uniform NDJSON answer regardless of language.

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

trap 'wrapper_sentinel "sst3-code-entry-points" "$SST3_EMITTED_COUNT" "entry"' EXIT
on_sigterm() {
    jq -nc --arg n "sst3-code-entry-points" --argjson e "$SST3_EMITTED_COUNT" \
        '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    exit 143
}
trap on_sigterm SIGTERM

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

if [[ ${#ARGS[@]} -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <lang> [--paths-from <ndjson>]" >&2
    exit 64
fi

LANG=$(normalise_lang "${ARGS[0]}")

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

emit_record() {
    local file="$1" line="$2" kind="$3" symbol="$4"
    if path_allowed "$file"; then
        jq -nc --arg f "$file" --argjson l "$line" --arg k "$kind" --arg s "$symbol" \
            '{file:$f, line:$l, kind:$k, symbol:$s}'
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    fi
}

run_pattern() {
    local pattern="$1" kind="$2" sym_meta="${3:-}"
    local ag_out ag_rc=0
    ag_out=$(mktemp)
    ast-grep run --pattern "$pattern" --lang "$LANG" --json=stream > "$ag_out" 2>/dev/null || ag_rc=$?
    ast_grep_check_rc "sst3-code-entry-points" "$ag_rc" || { rm -f "$ag_out"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        if [[ -n "$sym_meta" ]]; then
            symbol=$(jq -r --arg m "$sym_meta" '.metaVariables.single[$m].text // ""' <<< "$record")
        else
            symbol="$kind"
        fi
        [[ -z "$file" ]] && continue
        emit_record "$file" "$line" "$kind" "$symbol"
    done < "$ag_out"
    rm -f "$ag_out"
}

# #547 AC 3.1: kind-rule sibling of run_pattern — identical record handling,
# invocation swaps to `ast-grep scan --inline-rules` (rule embeds `language:`).
run_rule() {
    local rule="$1" kind="$2" sym_meta="${3:-}"
    local ag_out ag_rc=0
    ag_out=$(mktemp)
    ast-grep scan --inline-rules "$rule" --json=stream > "$ag_out" 2>/dev/null || ag_rc=$?
    ast_grep_check_rc "sst3-code-entry-points" "$ag_rc" || { rm -f "$ag_out"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        if [[ -n "$sym_meta" ]]; then
            symbol=$(jq -r --arg m "$sym_meta" '.metaVariables.single[$m].text // ""' <<< "$record")
        else
            symbol="$kind"
        fi
        [[ -z "$file" ]] && continue
        emit_record "$file" "$line" "$kind" "$symbol"
    done < "$ag_out"
    rm -f "$ag_out"
}

case "$LANG" in
    python)
        run_pattern 'if __name__ == "__main__": $$$' "main"
        # #547 (Stage-4 #447 recall gate): the single-quote guard form
        # `if __name__ == '__main__'` is a DISTINCT string literal — ast-grep pattern
        # text is quote-significant, so the double-quote pattern above misses it
        # (16 live SST3/scripts python tools use single quotes; probe-confirmed missed.
        #  `grep -rlE "if __name__ == '__main__'" scripts/` returns 17 files, but
        #  the 17th is THIS wrapper's own pattern literal in the run_pattern below,
        #  not a consumer tool).
        # A second exact run_pattern restores recall parity and is inherently
        # false-positive-safe (pins `== '__main__'`); a quote-agnostic kind-rule was
        # probed but needs string_content + ==-operator pinning for zero recall gain.
        run_pattern "if __name__ == '__main__': \$\$\$" "main"
        # #547 AC 3.1 (D4+D9): decorated_definition kind-rules replace the six
        # decorator+def shape patterns, which missed typed handlers (`-> dict`)
        # and ALL stacked-decorator handlers. One rule per decorator, same kind
        # labels + sym_meta. Probe-verified constraints: the `@…` decorator
        # pattern MUST be YAML-quoted (bare `@` is a hard YAML error); sibling
        # relational constraints nest under `all:` (duplicate sibling `has:`
        # keys are a hard rule-parse error).
        # shellcheck disable=SC2016  # $NAME is an ast-grep meta-var, not shell
        py_decorator_rule() {
            printf 'id: entry-points\nlanguage: python\nrule:\n  kind: decorated_definition\n  all:\n    - has: {kind: decorator, pattern: "%s", stopBy: end}\n    - has: {field: definition, kind: function_definition, has: {field: name, pattern: $NAME}}\n' "$1"
        }
        run_rule "$(py_decorator_rule '@app.route($$$)')" "http_handler" "NAME"
        run_rule "$(py_decorator_rule '@app.get($$$)')" "http_handler" "NAME"
        run_rule "$(py_decorator_rule '@app.post($$$)')" "http_handler" "NAME"
        run_rule "$(py_decorator_rule '@router.get($$$)')" "http_handler" "NAME"
        run_rule "$(py_decorator_rule '@router.post($$$)')" "http_handler" "NAME"
        run_rule "$(py_decorator_rule '@click.command($$$)')" "cli" "NAME"
        ;;
    rust)
        # #547 AC 3.2 (D5): ONE kind-rule subsumes plain / pub / `-> Result` /
        # tokio-async / tokio-Result mains — visibility, async, and return
        # types are children of the same function_item node, and the tokio
        # attribute is a SIBLING (which made the old 2-line tokio pattern
        # structurally dead: a pattern spanning sibling top-level nodes cannot
        # parse). 3 arms → 1.
        # #547 Stage-5 finding D: exclude impl-methods — an `impl X { fn main }`
        # method is a `function_item` too, but a struct method named `main` is
        # NOT a program entry point. `not: {inside: {kind: impl_item, stopBy:
        # end}}` drops it (stopBy:end is required — a method's immediate parent
        # is `declaration_list`, so a bare `inside: impl_item` would never match).
        run_rule 'id: entry-points
language: rust
rule:
  kind: function_item
  all:
    - has: {field: name, regex: ^main$}
    - not: {inside: {kind: impl_item, stopBy: end}}' "main"
        ;;
    javascript|typescript|tsx)
        run_pattern 'app.get($$$, $HANDLER)' "http_handler" "HANDLER"
        run_pattern 'app.post($$$, $HANDLER)' "http_handler" "HANDLER"
        run_pattern 'router.get($$$, $HANDLER)' "http_handler" "HANDLER"
        run_pattern 'router.post($$$, $HANDLER)' "http_handler" "HANDLER"
        ;;
    *)
        echo "ERROR: code-entry-points supports python|rust|javascript|typescript|tsx (got: $LANG)" >&2
        exit 64
        ;;
esac

exit 0
