#!/usr/bin/env bash
# code-callees-recall fixture (dotfiles#577 AC 4.7). Before this, sst3-code-callees.sh had only
# security-path (command-injection) and error-path (code-broken-engine-error-records) coverage:
# nothing asserted that it RETURNS the right callees. Each assertion is a pair so a wrapper that
# returns every call in the file, or none, cannot pass:
#   named_callee_present      — helper_a and helper_b (called in target) are in the output, on their lines
#   named_non_callee_absent   — unrelated_function (called only in other()) is NOT in the output
#   method_scope              — Box.open returns helper_b and not helper_a

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/../../scripts" && pwd)"
INPUT_DIR="$(cd "$(dirname "$0")/input" && pwd)"

fail() { echo "FAIL: $*"; exit 1; }

callees() {
    ( cd "$INPUT_DIR" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
        && bash "$SCRIPTS_DIR/sst3-code-callees.sh" "$@" )
}

has_callee() {  # <ndjson> <callee> [line]
    if [[ $# -eq 3 ]]; then
        jq -e --arg c "$2" --argjson l "$3" 'select(.callee == $c and .line == $l)' <<<"$1" >/dev/null
    else
        jq -e --arg c "$2" 'select(.callee == $c)' <<<"$1" >/dev/null
    fi
}

out=$(callees target python) || fail "sst3-code-callees.sh target python exited non-zero"
[[ -n "$out" ]] || fail "no callee records for target (recall zero)"

has_callee "$out" helper_a 19 || fail "named callee helper_a (pkg.py:19) missing from: $out"
has_callee "$out" helper_b 20 || fail "named callee helper_b (pkg.py:20) missing from: $out"
echo "PASS: named_callee_present"

if has_callee "$out" unrelated_function; then
    fail "named non-callee unrelated_function (called only in other()) reported as a callee of target"
fi
echo "PASS: named_non_callee_absent"

m=$(callees Box.open python) || fail "sst3-code-callees.sh Box.open python exited non-zero"
has_callee "$m" helper_b 15 || fail "Box.open should call helper_b (pkg.py:15); got: $m"
if has_callee "$m" helper_a; then
    fail "Box.open reported helper_a, which only target() calls"
fi
echo "PASS: method_scope"
