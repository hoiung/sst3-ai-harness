#!/usr/bin/env bash
# sst3-dep-usage.sh — Enumerate import + first-symbol-use sites for a package.
#
# Usage:   sst3-dep-usage.sh <package> <lang>
# Example: sst3-dep-usage.sh requests python
# Output:  NDJSON, one object per usage site: {file, line, symbol, import_kind}
#          line is a 1-indexed editor line (#547 AC 7.1).
#          import_kind: import | from_import | call_site
# Engines: ast-grep (Python / Rust / JS).
#
# Rationale (#447 Phase 8): pre-step for dep-blast-radius. Auditors trace
# what surfaces of a package the codebase actually uses BEFORE deciding
# upgrade safety.

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

trap 'wrapper_sentinel "sst3-dep-usage" "$SST3_EMITTED_COUNT" "use-site"' EXIT
on_sigterm() {
    jq -nc --arg n "sst3-dep-usage" --argjson e "$SST3_EMITTED_COUNT" \
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

if [[ ${#ARGS[@]} -lt 2 ]]; then
    echo "ERROR: usage: $(basename "$0") <package> <lang> [--paths-from <ndjson>]" >&2
    exit 64
fi

PACKAGE="${ARGS[0]}"
LANG_RAW="${ARGS[1]}"
assert_safe_identifier "$PACKAGE"
LANG=$(normalise_lang "$LANG_RAW")

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
    local file="$1" line="$2" symbol="$3" import_kind="$4"
    if path_allowed "$file"; then
        jq -nc --arg f "$file" --argjson l "$line" --arg s "$symbol" --arg ik "$import_kind" \
            '{file:$f, line:$l, symbol:$s, import_kind:$ik}'
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    fi
}

run_ast() {
    local pattern="$1" import_kind="$2" symbol_meta="${3:-}"
    local ag_out ag_rc=0
    ag_out=$(mktemp)
    ast-grep run --pattern "$pattern" --lang "$LANG" --json=stream > "$ag_out" 2>/dev/null || ag_rc=$?
    ast_grep_check_rc "sst3-dep-usage" "$ag_rc" || { rm -f "$ag_out"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        if [[ -n "$symbol_meta" ]]; then
            symbol=$(jq -r --arg m "$symbol_meta" '.metaVariables.single[$m].text // ""' <<< "$record")
        else
            symbol="$PACKAGE"
        fi
        [[ -z "$file" ]] && continue
        emit_record "$file" "$line" "$symbol" "$import_kind"
    done < "$ag_out"
    rm -f "$ag_out"
}

case "$LANG" in
    python)
        run_ast "import $PACKAGE" "import"
        run_ast "import $PACKAGE as \$ALIAS" "import" "ALIAS"
        run_ast "from $PACKAGE import \$WHAT" "from_import" "WHAT"
        run_ast "from $PACKAGE.\$SUB import \$WHAT" "from_import" "WHAT"
        run_ast "$PACKAGE.\$SYM" "call_site" "SYM"
        ;;
    rust)
        run_ast "use $PACKAGE::\$SYM" "import" "SYM"
        run_ast "use $PACKAGE::\$SYM::*" "import" "SYM"
        run_ast "$PACKAGE::\$SYM" "call_site" "SYM"
        ;;
    javascript|typescript|tsx)
        # #547 Stage-5 finding G: ast-grep string literals are quote-significant,
        # so a single-quoted specifier pattern never matches a double-quoted
        # import. Prettier (the JS/TS default formatter) emits DOUBLE quotes, so
        # the single-quote-only patterns missed the common case. Run both quote
        # styles; a given import site is one style, so no double-emit.
        run_ast "import \$WHAT from '$PACKAGE'" "import" "WHAT"
        run_ast "import \$WHAT from \"$PACKAGE\"" "import" "WHAT"
        run_ast "import { \$WHAT } from '$PACKAGE'" "from_import" "WHAT"
        run_ast "import { \$WHAT } from \"$PACKAGE\"" "from_import" "WHAT"
        run_ast "require('$PACKAGE')" "import"
        run_ast "require(\"$PACKAGE\")" "import"
        ;;
    *)
        echo "ERROR: dep-usage supports python|rust|javascript|typescript|tsx (got: $LANG)" >&2
        exit 64
        ;;
esac

exit 0
