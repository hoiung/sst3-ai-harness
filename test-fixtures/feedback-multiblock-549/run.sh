#!/usr/bin/env bash
# feedback-multiblock-549 fixture (#549 AC 1.1/1.2/1.3).
# Regression gate for pair-scan segmentation + per-pair index emission +
# ordinal-aware flip targeting. Asserts:
#   1. feedback-multiblock-1.md (2-pair direct H2, 1563 shape) → stage-5 emits
#      2 records with block_ordinal 1,2; inline `<!-- applied_in: 459 -->`
#      preserved on ordinal 1; `**disposition**:` field parses with 0
#      violations (exit 0, no schema_violation).
#   2. feedback-multiblock-2.md (Round-supplement H3 + trailing `Stage 4 r2`
#      re-run H2) → stage-4 emits ordinals 1,2 (r2 attributed to stage 4's
#      scope); stage-5 emits ordinals 1,2 (supplement).
#   3. Flip-tool integration on a mktemp copy: ordinal-2 flip lands exactly at
#      the parser's --emit-spans status_line (single-sourced segmentation,
#      AC 1.3a); ordinal-1 span byte-identical pre/post (AC 1.3b); ordinal
#      omission on a multi-pair stage exits non-zero naming the ordinals
#      (AC 1.3c); re-flip of the non-pending pair is HELD, file unchanged
#      (AC 1.2 pending-guard).
# PRE-FIX capture (documented, not asserted post-fix): live aggregate of
# feedback-auto_pb_swing_trader-1563.md Stage-5 yielded 1 record (last-pair-
# wins fold) before #549; post-fix it yields 2.

set -euo pipefail

# dotfiles#552 AC 3.2 — sibling-relative walk: `scripts/` is a sibling of
# test-fixtures/ in BOTH the nested canonical and flattened mirror layouts,
# so 2-up-into-scripts is invariant. The old 3-up-to-repo-root then
# /scripts/ re-encoded the nested layout and overshot in the mirror.
SCRIPTS_DIR="$(cd "$(dirname "$0")/../../scripts" && pwd)"
PARSER="$SCRIPTS_DIR/feedback_parser.py"
TOOL="$SCRIPTS_DIR/mark-improvements-applied.sh"

# dotfiles#552 AC 3.2 — fail LOUD when the subject is absent. Without this,
# a missing target made assertions that merely expect a NON-ZERO exit pass
# vacuously (file-not-found is also non-zero), so the fixture reported
# "assertions passed" while testing nothing at all.
[ -f "$PARSER" ] || { echo "FIXTURE-ABORT: $PARSER not found at $PARSER" >&2; exit 2; }
[ -f "$TOOL" ] || { echo "FIXTURE-ABORT: $TOOL not found at $TOOL" >&2; exit 2; }
HERE="$(dirname "$0")"

fail() { echo "FAIL: $*"; exit 1; }

# --- 1. multiblock-1: per-pair emission + inline applied_in + disposition field
NDJ1=$(python3 "$PARSER" "$HERE/feedback-multiblock-1.md" --emit-ndjson) || fail "multiblock-1 emit exit != 0"
printf '%s' "$NDJ1" | grep -q '"schema_violation"' && fail "multiblock-1 emitted schema_violation"
ORDINALS1=$(printf '%s\n' "$NDJ1" | python3 -c '
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
s5 = [(r["block_ordinal"], r["improvement_status"]) for r in rows if r["stage"] == 5]
print(";".join(f"{o}:{s}" for o, s in sorted(s5)))
')
[[ "$ORDINALS1" == "1:pending;2:rejected" ]] || fail "multiblock-1 stage-5 pairs: got '$ORDINALS1', want '1:pending;2:rejected'"
printf '%s\n' "$NDJ1" | python3 -c '
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
o1 = [r for r in rows if r["stage"] == 5 and r["block_ordinal"] == 1][0]
marker = o1["inline_applied_in"]
assert marker == [459], "inline_applied_in lost: %r" % marker
' || fail "multiblock-1 inline applied_in marker not preserved on ordinal 1"
echo "PASS: multiblock-1 (2 pairs, ordinals+statuses correct, inline applied_in preserved, disposition field clean)"

# --- 2. multiblock-2: supplement H3 + Stage 4 r2 re-run attribution
NDJ2=$(python3 "$PARSER" "$HERE/feedback-multiblock-2.md" --emit-ndjson) || fail "multiblock-2 emit exit != 0"
SHAPE2=$(printf '%s\n' "$NDJ2" | python3 -c '
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
by = sorted((r["stage"], r["block_ordinal"], r["improvement_status"]) for r in rows)
print(";".join(f"{s}.{o}:{st}" for s, o, st in by))
')
[[ "$SHAPE2" == "4.1:pending;4.2:pending;5.1:applied;5.2:pending" ]] || fail "multiblock-2 shape: got '$SHAPE2'"
echo "PASS: multiblock-2 (r2 re-run attributed to stage 4; supplement is stage-5 ordinal 2)"

# --- 3. flip-tool integration on a temp copy
TD=$(mktemp -d -t feedback_multiblock_549.XXXXXX)
trap 'rm -f "$TD"/* 2>/dev/null; rmdir "$TD" 2>/dev/null || true' EXIT
cp "$HERE/feedback-multiblock-1.md" "$TD/feedback-multiblock-1.md"
F="$TD/feedback-multiblock-1.md"

STATUS_LINE=$(python3 "$PARSER" "$F" --emit-spans | python3 -c '
import sys, json
for l in sys.stdin:
    r = json.loads(l)
    if r["stage"] == 5 and r["block_ordinal"] == 1:
        print(r["status_line"]); break
')
[[ -n "$STATUS_LINE" ]] || fail "no status_line for stage-5 ordinal 1"

SPAN2_PRE=$(python3 - "$F" <<PYEOF
import sys, json
sys.path.insert(0, "$SCRIPTS_DIR")
import feedback_parser as fp
from pathlib import Path
text = Path(sys.argv[1]).read_text()
p = [q for q in fp.scan_improvement_pairs(text) if q.stage_num == 5 and q.block_ordinal == 2][0]
print("\n".join(text.splitlines()[p.start_line - 1 : p.end_line]))
PYEOF
)

printf '[{"file": "%s", "stage": 5, "block_ordinal": 1, "new_status": "superseded", "note": "cycle3 — fixture twin"}]\n' "$F" > "$TD/man.json"
bash "$TOOL" --apply --tuples "$TD/man.json" >/dev/null 2>&1 || fail "flip apply exit != 0"
FLIPPED_LINE=$(sed -n "${STATUS_LINE}p" "$F")
[[ "$FLIPPED_LINE" == "**improvement_status**: superseded" ]] || fail "flip did not land at parser status_line $STATUS_LINE (AC 1.3a); line reads: $FLIPPED_LINE"

SPAN2_POST=$(python3 - "$F" <<PYEOF
import sys, json
sys.path.insert(0, "$SCRIPTS_DIR")
import feedback_parser as fp
from pathlib import Path
text = Path(sys.argv[1]).read_text()
p = [q for q in fp.scan_improvement_pairs(text) if q.stage_num == 5 and q.block_ordinal == 2][0]
print("\n".join(text.splitlines()[p.start_line - 1 : p.end_line]))
PYEOF
)
[[ "$SPAN2_PRE" == "$SPAN2_POST" ]] || fail "untouched sibling pair (ordinal 2) not byte-identical (AC 1.3b)"
python3 "$PARSER" "$F" >/dev/null || fail "flipped fixture no longer validates"
echo "PASS: flip lands at parser status_line, sibling pair byte-identical, post-flip parse clean"

printf '[{"file": "%s", "stage": 5, "block_ordinal": null, "new_status": "rejected", "note": "x"}]\n' "$F" > "$TD/man2.json"
set +e
ERR=$(bash "$TOOL" --dry-run --tuples "$TD/man2.json" 2>&1 >/dev/null)
CODE=$?
set -e
(( CODE != 0 )) || fail "ordinal omission on multi-pair stage did not exit non-zero (AC 1.3c)"
printf '%s' "$ERR" | grep -q "block-ordinal required" || fail "omission error does not name the requirement (AC 1.3c)"
printf '%s' "$ERR" | grep -q "ordinal 1" || fail "omission error does not enumerate ordinals (AC 1.3c)"
echo "PASS: ordinal omission is a loud error naming the ordinals found"

BEFORE_HASH=$(sha256sum "$F" | cut -d' ' -f1)
HELD_OUT=$(bash "$TOOL" --apply --tuples "$TD/man.json" 2>&1) || fail "HELD re-run exited non-zero"
printf '%s' "$HELD_OUT" | grep -q "HELD" || fail "re-flip of non-pending pair not HELD (AC 1.2)"
AFTER_HASH=$(sha256sum "$F" | cut -d' ' -f1)
[[ "$BEFORE_HASH" == "$AFTER_HASH" ]] || fail "HELD row mutated the file (AC 1.2 pending-guard clobber)"
echo "PASS: pending-guard HELD, file unchanged"

# --- 6. applied_in follows the status, for EVERY status the tool accepts (per-stage-feedback-capture.md:
#        "When status moves to applied or partial, set applied_in"; #577 AC 5.1). Each flip is handed
#        applied_in 577: applied + partial write it on the line after the status, superseded + rejected
#        write none. A status with no expectation below fails, so a new enum member cannot pass untested.
STATUSES=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import feedback_parser as fp; print(" ".join(s for s in fp.IMPROVEMENT_STATUS_ENUM if s != "pending"))' "$SCRIPTS_DIR")
[[ -n "$STATUSES" ]] || fail "no statuses derived from IMPROVEMENT_STATUS_ENUM"
TDS=$(mktemp -d -t feedback_multiblock_549s.XXXXXX)
trap 'rm -f "$TD"/* 2>/dev/null; rmdir "$TD" 2>/dev/null; rm -rf "$TDS" 2>/dev/null || true' EXIT
for S in $STATUSES; do
  case "$S" in
    applied|partial) WANT=yes ;;
    superseded|rejected) WANT=no ;;
    *) fail "status $S has no applied_in expectation in this fixture" ;;
  esac
  mkdir "$TDS/$S"
  G="$TDS/$S/feedback-multiblock-1.md"
  cp "$HERE/feedback-multiblock-1.md" "$G"
  printf '[{"file": "%s", "stage": 5, "block_ordinal": 1, "new_status": "%s", "note": "fixture", "applied_in": "577"}]\n' "$G" "$S" > "$TDS/$S.json"
  bash "$TOOL" --apply --tuples "$TDS/$S.json" >/dev/null 2>&1 || fail "$S apply exit != 0"
  [[ "$(sed -n "${STATUS_LINE}p" "$G")" == "**improvement_status**: $S" ]] || fail "$S flip did not land at parser status_line $STATUS_LINE"
  if [[ "$WANT" == yes ]]; then
    [[ "$(sed -n "$((STATUS_LINE + 1))p" "$G")" == "**applied_in**: 577" ]] || fail "$S row has no applied_in on the line after its status"
  elif grep -q '^\*\*applied_in\*\*: 577' "$G"; then
    fail "$S row got applied_in"
  fi
  python3 "$PARSER" "$G" >/dev/null || fail "$S-flipped fixture no longer validates"
done
echo "PASS: applied_in written for applied + partial, withheld for superseded + rejected"

echo "OK: feedback-multiblock-549 fixture (6/6 assertion groups passed)"
