#!/usr/bin/env bash
# sst3-code-recent-changes.sh — Files changed in a recent time window.
#
# Usage:   sst3-code-recent-changes.sh <since> [<paths>...]
# Example: sst3-code-recent-changes.sh '2 weeks ago'
#          sst3-code-recent-changes.sh '2026-04-20' SST3/scripts
# Output:  NDJSON, one object per (file, commit): {file, last_commit, author, sha, lines_changed}
# Engine:  git log --since=<since> -z --no-renames --numstat --format=... (records read by python3)
#
# Rationale (#447 Phase 6): incident response and regression hunts currently
# rely on ad-hoc `git log` scrapes. This wrapper produces a stable NDJSON
# contract so subagents can ingest "what changed recently in <area>" without
# crafting bespoke git invocations each time.

set -euo pipefail

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

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <since> [<paths>...]" >&2
    exit 64
fi

SINCE="$1"
shift
PATHS=("$@")

export LC_ALL=C
SST3_EMITTED_COUNT=0

if ! command -v git >/dev/null 2>&1; then
    echo 'ERROR: git not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# EXIT-trap sentinel — the silent-zero guard. Without this, "no commits in
# window" produced exit 0 + no stderr, indistinguishable from "wrapper crashed
# before emitting".
trap 'wrapper_sentinel "sst3-code-recent-changes" "$SST3_EMITTED_COUNT" "change"' EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-recent-changes" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-recent-changes" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM


# #577 Stage 5 fix review R8: git reads <since> with approxidate, which accepts nonsense with
# rc 0: 'garbage-not-a-date' is "now" (an empty window) and the typo '7 dyas ago' lands in the
# future. A window that starts now or later is refused as could-not-look; any other reading is
# printed to stderr so the window that actually ran is visible (approxidate also skips words it
# does not know: 'abc 2 weeks' reads as 2 weeks, and only the printed date shows it).
NOW_EPOCH="$(date +%s)"
SINCE_EPOCH="$(git rev-parse --since="$SINCE" 2>/dev/null)" || SINCE_EPOCH=""
SINCE_EPOCH="${SINCE_EPOCH#--max-age=}"
if [[ ! "$SINCE_EPOCH" =~ ^[0-9]+$ ]]; then
    printf '%s: sst3-code-recent-changes — could not look: git could not read the window "%s" (not in a git repository?)\n' \
        "$SST3_PROBE_FAILED_MARKER" "$SINCE" >&2
    exit 2
fi
if (( SINCE_EPOCH >= NOW_EPOCH )); then
    printf '%s: sst3-code-recent-changes — could not look: git read "%s" as %s, a window that starts now or later (an unreadable date reads as "now")\n' \
        "$SST3_PROBE_FAILED_MARKER" "$SINCE" "$(date -u -d "@$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" >&2
    exit 2
fi
printf 'sst3-code-recent-changes: window since %s (from "%s")\n' "$(date -u -d "@$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" "$SINCE" >&2

# Build the git log argv. --numstat emits per-file added/deleted line counts;
# --format injects a sentinel record we parse below to anchor commit metadata.
# -z: every record ends in NUL and a path is never C-quoted (`q"uote.py`, `back\slash.py`
# and a tab in a name came out quoted, then mangled by an awk gsub into names that do not
# exist — #577 Stage 5 fix review R3). --no-renames: a rename is its delete and its add,
# two real paths, instead of the brace form `src/{old.py => new.py}`, which names no file.
GIT_ARGS=(log --since="$SINCE" --no-merges -z --no-renames --numstat --format='__SST3_COMMIT__%H%x09%an%x09%ad' --date=iso-strict)
if [[ ${#PATHS[@]} -gt 0 ]]; then
    GIT_ARGS+=(-- "${PATHS[@]}")
fi

# git's output is buffered and its rc checked first — `git … 2>/dev/null |` turned a failed
# log (not a repo) into "emitted 0 change(s)" (#577 Stage 5 S4). The records are read in
# Python and written by its JSON encoder (the awk printf + gsub built JSON by hand, the
# class S5 fixed in sst3-code-large.sh); a parse failure is could-not-look. The loop reads
# a file, NOT a pipe, so the increment stays in the parent shell and the EXIT-trap sentinel
# reports the real count. PYTHONIOENCODING: LC_ALL=C above must not turn a UTF-8 path
# into an encoding error.
GIT_OUT="$(mktemp)"
GIT_RC=0
git -c core.quotePath=false "${GIT_ARGS[@]}" >"$GIT_OUT" 2>"$GIT_OUT.err" || GIT_RC=$?
if [[ $GIT_RC -ne 0 ]]; then
    printf '%s: sst3-code-recent-changes — could not look: `git log` exited %s: %s\n' \
        "$SST3_PROBE_FAILED_MARKER" "$GIT_RC" "$(tail -1 "$GIT_OUT.err")" >&2
    rm -f "$GIT_OUT" "$GIT_OUT.err"
    exit 2
fi
PARSED="$(mktemp)"
if ! PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
MARK = b"__SST3_COMMIT__"
sha = author = date = ""
for rec in sys.stdin.buffer.read().split(b"\0"):
    rec = rec.lstrip(b"\n")
    if not rec:
        continue
    if rec.startswith(MARK):
        sha, author, date = (rec[len(MARK):].decode("utf-8", "replace").split("\t") + ["", ""])[:3]
        continue
    parts = rec.split(b"\t", 2)
    if len(parts) != 3 or not all(f == b"-" or f.isdigit() for f in parts[:2]):
        sys.exit("unexpected git log record: %r" % rec[:80])
    lines = sum(int(f) for f in parts[:2] if f != b"-")
    # A record carries a text name. A name that is not UTF-8 was decoded with U+FFFD, a
    # path that does not exist, and --paths-from then dropped it without a word (#577
    # Stage 5 fix review r2); it is named on stderr instead.
    try:
        name = parts[2].decode("utf-8")
    except UnicodeDecodeError:
        print("NOTE: %r changed in %s but its name is not UTF-8, so it is not listed: "
              "records carry text names. Rename the file." % (parts[2], sha[:12]), file=sys.stderr)
        continue
    print(json.dumps({"file": name, "last_commit": date,
                      "author": author, "sha": sha, "lines_changed": lines},
                     ensure_ascii=False, separators=(",", ":")))
' <"$GIT_OUT" >"$PARSED" 2>"$GIT_OUT.err"; then
    printf '%s: sst3-code-recent-changes — could not look: the git log records could not be read: %s\n' \
        "$SST3_PROBE_FAILED_MARKER" "$(tail -1 "$GIT_OUT.err")" >&2
    rm -f "$GIT_OUT" "$GIT_OUT.err" "$PARSED"
    exit 2
fi
{ grep '^NOTE: ' "$GIT_OUT.err" || true; } | sed 's/^NOTE: /[sst3-code-recent-changes] /' >&2
while IFS= read -r RECORD; do
    echo "$RECORD"
    SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
done <"$PARSED"
rm -f "$GIT_OUT" "$GIT_OUT.err" "$PARSED"
