#!/usr/bin/env bash
# sst3-page-review.sh — a change a person sees rendered is not done until a picture per
# declared viewport of each touched page has been taken and READ (dotfiles#583).
#
# WIRED (claude/settings.json)   PostToolUse Edit|Write → edit    PostToolUse Read → read
#                                PreToolUse Bash        → bash    Stop             → stop
# The decision lives in _lib-page-review.py (its header holds the page-file rules, the state
# and audit shapes); this entry sets the defaults the tests redirect, checks python3 and
# hands stdin through UNREAD (a Read payload carries the picture as base64: megabytes).
#
# MODE   SST3_PAGE_REVIEW_MODE=BLOCK (default: Stop blocked, a push to the default branch
#        exit 2) | WARN (told, never blocked) | OFF (this entry exits 0 at once).
#        The operator's switch; an agent cannot set a hook's environment.
# LOOP   After SST3_PAGE_REVIEW_MAX_STOP_BLOCKS (default 3) blocks with no new picture read,
#        the stop is let through and the operator told: the gate can never trap a session.
# DEGRADE python3 missing → one systemMessage to the operator at Stop, exit 0. Never
#        additionalContext at Stop: it continues the turn like a block and would loop.
set -u

event="${1:-}"
case "$event" in
  edit|read|bash|stop) ;;
  *) echo "usage: sst3-page-review.sh <edit|read|bash|stop> < hook-json" >&2; exit 2 ;;
esac

mode="${SST3_PAGE_REVIEW_MODE:-BLOCK}"
[[ "${mode^^}" == OFF ]] && exit 0

export SST3_PAGE_REVIEW_LOG="${SST3_PAGE_REVIEW_LOG:-$HOME/.claude/hooks/page-review.log}"
export SST3_PAGE_REVIEW_STATE_DIR="${SST3_PAGE_REVIEW_STATE_DIR:-${TMPDIR:-/tmp}/sst3-page-review}"
src="${BASH_SOURCE[0]}"
[[ "$src" == */* ]] && here="${src%/*}" || here=.   # no subshells: this runs on every Stop

if ! command -v python3 >/dev/null 2>&1; then
  if [[ "$event" == stop ]]; then
    msg=""
    # shellcheck source=_lib-hook-output.sh
    source "$here/_lib-hook-output.sh"
    sst3_json_escape_to msg "sst3-page-review could not run: python3 is not on PATH, so page pictures are not being checked. Install python3 (<your-dotfiles-clone>/scripts/install.sh) or set SST3_PAGE_REVIEW_MODE=OFF."
    printf '{"systemMessage":"%s"}\n' "$msg"
  fi
  exit 0
fi

# -I: no PYTHON* env, user site or script dir on sys.path; -S: no site import (the helper
# needs only the standard library). The helper runs from its __pycache__ bytecode, which a
# script named on the command line never gets: compiling it on every Stop cost ~13 ms (AC 1.9).
exec python3 -I -S -c '
import sys
from importlib.machinery import SourceFileLoader
path = sys.argv[1]
sys.argv = sys.argv[1:]
code = SourceFileLoader("sst3_page_review", path).get_code("sst3_page_review")
exec(code, {"__name__": "__main__", "__file__": path, "__builtins__": __builtins__})
' "$here/_lib-page-review.py" "$event"
