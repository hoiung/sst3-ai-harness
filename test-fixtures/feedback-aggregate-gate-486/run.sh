#!/usr/bin/env bash
# feedback-aggregate-gate-486 fixture (#486).
# Regression gate for the commit-path strict/advisory split in
# leader-feedback-aggregate.sh. The every-commit pre-commit hook
# (`sst3-metrics-feedback-drift`) runs `--summarize`. Asserts:
#   A. clean in-scope corpus            -> --summarize exit 0
#   B. + a broken in-scope file         -> --summarize exit != 0  (AC5: hard
#                                          parse failure BLOCKS the commit;
#                                          this is the silent-rot regression
#                                          guard — pre-#486 --summarize was 0)
#   C. clean + a non-conforming-filename
#      file (not a telemetry file)      -> --summarize exit 0 + stderr WARNING
#                                          (AC7: a misfiled draft must NOT
#                                          wedge the gate / force --no-verify)
# Uses the SST3_FEEDBACK_DIR test seam so the real corpus is never touched.
# AC6 (advisory DRIFT never blocks) is proven on the real corpus in the
# Issue #486 Verification Loop; synthesising a 5-weighted-didnt DRIFT corpus
# here would be fixture overengineering for no extra signal.

set -euo pipefail

# dotfiles#552 AC 3.2 — sibling-relative walk: `scripts/` is a sibling of
# test-fixtures/ in BOTH the nested canonical and flattened mirror layouts,
# so 2-up-into-scripts is invariant. The old 3-up-to-repo-root then
# /scripts/ re-encoded the nested layout and overshot in the mirror.
SCRIPTS_DIR="$(cd "$(dirname "$0")/../../scripts" && pwd)"
AGG="$SCRIPTS_DIR/leader-feedback-aggregate.sh"

# dotfiles#552 AC 3.2 — fail LOUD when the subject is absent. Without this,
# a missing target made assertions that merely expect a NON-ZERO exit pass
# vacuously (file-not-found is also non-zero), so the fixture reported
# "assertions passed" while testing nothing at all.
[ -f "$AGG" ] || { echo "FIXTURE-ABORT: $AGG not found at $AGG" >&2; exit 2; }
HERE="$(dirname "$0")"

run_summarize() {
    # echoes "<exit_code>" and writes stderr to $1
    local corpus="$1" errfile="$2" code
    set +e
    SST3_FEEDBACK_DIR="$corpus" bash "$AGG" --summarize >/dev/null 2>"$errfile"
    code=$?
    set -e
    echo "$code"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Scenario A: clean in-scope corpus -> gate passes (exit 0) ---
A="$WORK/a"; mkdir -p "$A"
cp "$HERE/clean.md" "$A/feedback-test-1.md"
a_code=$(run_summarize "$A" "$WORK/a.err")
if [[ "$a_code" != "0" ]]; then
    echo "FAIL: scenario A (clean corpus) expected --summarize exit 0, got $a_code"
    cat "$WORK/a.err" >&2 || true
    exit 1
fi
echo "PASS: scenario A clean-corpus --summarize exit 0"

# --- Scenario B: + broken in-scope file -> gate BLOCKS (exit != 0) [AC5] ---
B="$WORK/b"; mkdir -p "$B"
cp "$HERE/clean.md"  "$B/feedback-test-1.md"
cp "$HERE/broken.md" "$B/feedback-test-2.md"
b_code=$(run_summarize "$B" "$WORK/b.err")
if [[ "$b_code" == "0" ]]; then
    echo "FAIL: scenario B (broken in-scope file present) expected --summarize exit != 0, got 0 — SILENT-ROT REGRESSION"
    cat "$WORK/b.err" >&2 || true
    exit 1
fi
echo "PASS: scenario B broken-in-scope --summarize exit $b_code (blocks, AC5)"

# --- Scenario C: clean + non-conforming filename -> exit 0 + WARNING [AC7] ---
C="$WORK/c"; mkdir -p "$C"
cp "$HERE/clean.md" "$C/feedback-test-1.md"
cp "$HERE/clean.md" "$C/feedback-misfiled-note.md"   # no -<N>.md => non-conforming
c_code=$(run_summarize "$C" "$WORK/c.err")
if [[ "$c_code" != "0" ]]; then
    echo "FAIL: scenario C (non-conforming filename) expected --summarize exit 0 (must not wedge), got $c_code"
    cat "$WORK/c.err" >&2 || true
    exit 1
fi
if ! grep -q 'WARNING non-conforming filename' "$WORK/c.err"; then
    echo "FAIL: scenario C expected a loud non-conforming WARNING on stderr; not found"
    cat "$WORK/c.err" >&2 || true
    exit 1
fi
echo "PASS: scenario C non-conforming-filename --summarize exit 0 + WARNING (AC7)"

# --- Scenario D (dotfiles#577 AC 0.4): a placeholder in a file that LOGS
# Stage 5 stays a hard failure — in-flight tolerance must not reach it ---
D="$WORK/d"; mkdir -p "$D"
cp "$HERE/clean.md" "$D/feedback-test-1.md"
cp "$HERE/stage5-placeholder.md" "$D/feedback-fixture-9997.md"
d_code=$(run_summarize "$D" "$WORK/d.err")
if [[ "$d_code" == "0" ]] || ! grep -q 'feedback-fixture-9997' "$WORK/d.err"; then
    echo "FAIL: stage5_placeholder_still_fails — expected --summarize exit != 0 naming feedback-fixture-9997, got exit $d_code"
    cat "$WORK/d.err" >&2 || true
    exit 1
fi
echo "PASS: scenario D stage5_placeholder_still_fails --summarize exit $d_code"

# --- Scenario E (dotfiles#577 AC 0.4): in-flight files (stages_logged lacks 5)
# are validated with --allow-placeholder and named in a WARNING; a verbatim
# template stub (whose HTML comment names the forward-preference phrases) is
# one of them. Pre-fix, either file made the whole run exit 1. ---
TEMPLATE="$(cd "$(dirname "$0")/../../templates" && pwd)/leader-feedback-template.md"
[ -f "$TEMPLATE" ] || { echo "FIXTURE-ABORT: $TEMPLATE not found" >&2; exit 2; }
E="$WORK/e"; mkdir -p "$E"
cp "$HERE/clean.md" "$E/feedback-test-1.md"
cp "$HERE/in-flight.md" "$E/feedback-fixture-9999.md"
sed -e 's/^issue: <N>$/issue: 9998/' -e 's/^repo: dotfiles$/repo: fixture/' \
    -e 's/<YYYY-MM-DD>/2026-09-25/' -e 's/^verdict_summary: .*/verdict_summary: verbatim template stub/' \
    -e 's/^topic_keywords: .*/topic_keywords: [test]/' "$TEMPLATE" >"$E/feedback-fixture-9998.md"
e_code=$(run_summarize "$E" "$WORK/e.err")
for want in feedback-fixture-9999 feedback-fixture-9998; do
    if [[ "$e_code" != "0" ]] || ! grep -q "WARNING in-flight $want" "$WORK/e.err"; then
        echo "FAIL: in_flight_placeholder_tolerated — expected --summarize exit 0 + WARNING naming $want, got exit $e_code"
        cat "$WORK/e.err" >&2 || true
        exit 1
    fi
done
e_rows=$(jq -r 'select(.issue==9999)|.stage' "$E/feedback-index.ndjson" | wc -l)
if (( e_rows < 1 )); then
    echo "FAIL: in_flight_placeholder_tolerated — issue 9999 has no index rows"
    exit 1
fi
echo "PASS: scenario E in_flight_placeholder_tolerated --summarize exit 0 + WARNING x2 + $e_rows index row(s) for 9999"

echo "OK: feedback-aggregate-gate-486 fixture (5/5 assertions passed)"
