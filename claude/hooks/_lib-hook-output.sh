#!/usr/bin/env bash
# _lib-hook-output.sh — the one JSON emitter SST3 hooks use to reach the agent (dotfiles#577 AC 1.2),
# and the one audit-line writer (sst3_audit_append, below).
#
# WHY   Claude Code routes a hook message by CHANNEL, not by intent (hooks reference):
#         stderr on exit 0         → the debug log only; Claude never sees it
#         systemMessage            → shown to the USER
#         hookSpecificOutput.additionalContext → the AGENT channel (a system reminder
#                                    beside the tool result / at the stop boundary)
#       Every SST3 message meant to steer the agent therefore goes out as
#       additionalContext, with an optional systemMessage for the operator. JSON on stdout
#       is read on every exit code except 2, and a valid object on exit 1 replaces the
#       bare "hook error" notice, so the degrade paths (exit 1) use this too.
#
# NO jq DEPENDENCY  the jq-missing degrade paths must be able to speak, so the JSON is
#       built in pure bash (sst3_json_escape_to) and never spawns a process.
#
# USE   source "$(dirname "${BASH_SOURCE[0]}")/_lib-hook-output.sh"
#       sst3_hook_emit <hookEventName> <agent context> [operator systemMessage]
#
# Operator-only hints (e.g. "set SST3_*_MODE=DENY") belong in the systemMessage
# argument, never the agent context: an agent cannot set a hook's environment (AC 1.3).

# sst3_json_escape_to <var> <string> — assigns <string> JSON-escaped (no quotes) to <var>.
sst3_json_escape_to() {
  local s="$2" i hex ch
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Remaining C0 controls (JSON forbids them raw). NUL cannot occur in a bash string.
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v hex '%02x' "$i"
    printf -v ch '%b' "\\x$hex"
    [[ "$s" == *"$ch"* ]] && s="${s//"$ch"/\\u00$hex}"
  done
  printf -v "$1" '%s' "$s"
}

# sst3_hook_emit <hookEventName> <agent context> [operator systemMessage] — prints one
# JSON object on stdout. The caller chooses the exit code.
sst3_hook_emit() {
  local ev ctx user=""
  sst3_json_escape_to ev "$1"
  sst3_json_escape_to ctx "$2"
  if [[ -n "${3:-}" ]]; then
    sst3_json_escape_to user "$3"
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
      "$user" "$ev" "$ctx"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$ev" "$ctx"
  fi
}

# sst3_audit_append <log> <record> <hook label> — appends <record> as one line to <log>,
# creating its directory. A write that does not land is announced on stderr and returns 1.
# The hook's decision and exit code stand: a lost audit line leaves the trail incomplete but
# does not make an allowed or denied call wrong, which is the same asymmetry as the Ralph
# counter's _audit_write (sst3-ralph-restart-counter.sh, "DELIBERATE ASYMMETRY"). Callers
# end the call with `|| :` because the failure has already been announced here.
sst3_audit_append() {
  mkdir -p "$(dirname "$1")" 2>/dev/null
  printf '%s\n' "$2" >>"$1" 2>/dev/null && return 0
  printf 'SST3 %s AUDIT WRITE FAILED: could not append to %s. The hook decision stands; its audit trail is incomplete.\n' \
    "$3" "$1" >&2
  return 1
}
