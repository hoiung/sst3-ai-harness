#!/usr/bin/env bash
# sst3-sec-secret-touchpoints.sh — Surface every secret/credential touchpoint.
#
# Usage:   sst3-sec-secret-touchpoints.sh [--paths-from <ndjson>]
# Output:  NDJSON, one object per touchpoint: {file, line, kind, identifier}
#          line is a 1-indexed editor line (#547 AC 7.1).
#          kind: env_read | env_default | dotenv_load | password_literal | aws_access_key | aws_secret_key
#          identifier: the env-var name, dotenv path, or token (truncated)
# Engines: ast-grep (Python env_read / dotenv_load) + ripgrep (regex literals)
#
# Rationale (#447 Phase 8): the current secrets wrapper (sst3-code-secrets.sh)
# scans against a literal blocklist. This wrapper is upstream of that — it
# enumerates every CALL SITE that touches a secret / credential / env-var,
# regardless of whether the value itself leaked. Auditors use it to verify
# the secret-handling surface area before each release.

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

trap 'wrapper_sentinel "sst3-sec-secret-touchpoints" "$SST3_EMITTED_COUNT" "touchpoint"' EXIT
on_sigterm() {
    jq -nc --arg n "sst3-sec-secret-touchpoints" --argjson e "$SST3_EMITTED_COUNT" \
        '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    exit 143
}
trap on_sigterm SIGTERM

PATHS_FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from)
            PATHS_FROM="${2:-}"
            shift 2 || break
            ;;
        *)
            shift
            ;;
    esac
done

if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v rg >/dev/null 2>&1; then
    echo 'ERROR: ripgrep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
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
# The engines scan the listed files themselves (sst3-bash-utils.sh paths_from_scan_targets).
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

emit_record() {
    local file="$1" line="$2" kind="$3" ident="$4" end_line="${5:-$2}"
    if path_allowed "$file"; then
        jq -nc --arg f "$file" --argjson l "$line" --argjson e "$end_line" --arg k "$kind" --arg i "$ident" \
            '{file:$f, line:$l, end_line:$e, kind:$k, identifier:$i}'
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    fi
}

# 1) ast-grep — Python env reads.
PY_PATTERNS=(
    "env_read|os.environ[\$KEY]"
    "env_read|os.environ.get(\$KEY)"
    "env_default|os.environ.get(\$KEY, \$DEF)"
    "env_read|os.getenv(\$KEY)"
    "env_default|os.getenv(\$KEY, \$DEF)"
    "dotenv_load|dotenv.load_dotenv(\$\$\$)"
    "dotenv_load|load_dotenv(\$\$\$)"
)

AG_OUT=$(mktemp)
for spec in "${PY_PATTERNS[@]}"; do
    [[ ${#SCAN_TARGETS[@]} -gt 0 ]] || break  # a list naming no existing file: scan nothing
    IFS='|' read -r kind pattern <<< "$spec"
    AG_RC=0
    run_over_targets "$AG_OUT" SCAN_TARGETS ast-grep run --pattern "$pattern" --lang python --json=stream || AG_RC=$?
    ast_grep_check_rc "sst3-sec-secret-touchpoints" "$AG_RC" || { rm -f "$AG_OUT"; exit 0; }
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        file=$(jq -r '.file // ""' <<< "$record")
        line=$(jq -r '(.range.start.line + 1) // 0' <<< "$record")  # #547 AC 7.1: 1-indexed
        end_line=$(jq -r '(.range.end.line + 1) // 0' <<< "$record")  # a call can span lines (#577)
        ident=$(jq -r '.metaVariables.single.KEY.text // ""' <<< "$record")
        [[ -z "$file" ]] && continue
        emit_record "$file" "$line" "$kind" "$ident" "$end_line"
    done < "$AG_OUT"
done
rm -f "$AG_OUT"

# 2) ripgrep — literal patterns. We enumerate matches with --json so we get
# file + line. Each pattern gets its own kind.
declare -a RG_RULES=(
    'password_literal|password\s*=\s*["\x27][^"\x27]+["\x27]'
    'aws_access_key|AKIA[0-9A-Z]{16}'
    'aws_secret_key|aws_secret_access_key\s*=\s*["\x27][^"\x27]+["\x27]'
)

RG_OUT=$(mktemp)
for rule in "${RG_RULES[@]}"; do
    [[ ${#SCAN_TARGETS[@]} -gt 0 ]] || break  # a list naming no existing file: scan nothing
    IFS='|' read -r kind regex <<< "$rule"
    # The target is never empty, and that is load-bearing, not cosmetic. With no path
    # argument rg reads stdin whenever stdin is a pipe or a regular file — and
    # pre-commit supplies exactly that — so every rule below emitted ZERO records in
    # each automated context (pre-commit, pre-push, CI) while still firing correctly
    # when run by hand from a terminal. A secret-detection gate that works only when a
    # human is watching is a fail-OPEN gate. Measured before that fix: a file holding
    # AKIA-prefixed keys and a password literal passed `sst3-sec` clean under a pipe
    # and emitted 2 records under `< /dev/null`. Its exit code is read, not discarded:
    # 2 (a named file it cannot read, a bad regex) was once `|| true`, so the scan
    # could miss a file and still look clean (#577 escalation sweep).
    RG_RC=0
    run_over_targets "$RG_OUT" SCAN_TARGETS rg --json -e "$regex" --no-messages || RG_RC=$?
    ast_grep_check_rc "sst3-sec-secret-touchpoints" "$RG_RC" rg || { rm -f "$RG_OUT"; exit 0; }
    while IFS= read -r json_line; do
        [[ -z "$json_line" ]] && continue
        type=$(jq -r '.type' <<< "$json_line" 2>/dev/null || echo "")
        [[ "$type" != "match" ]] && continue
        file=$(jq -r '.data.path.text // empty' <<< "$json_line")
        line=$(jq -r '.data.line_number' <<< "$json_line")
        match=$(jq -r '.data.submatches[0].match.text // ""' <<< "$json_line")
        # Truncate the match to keep the NDJSON small.
        ident="${match:0:60}"
        [[ -n "$file" && -n "$line" ]] && emit_record "$file" "$line" "$kind" "$ident"
    done < "$RG_OUT"
done
rm -f "$RG_OUT"

exit 0
