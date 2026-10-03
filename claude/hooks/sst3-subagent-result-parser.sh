#!/usr/bin/env bash
# sst3-subagent-result-parser.sh — F-7 subagent RESULT-block parser (#498 AC 2.10; inputs,
# channels and the parent route rebuilt in dotfiles#577 AC 1.2).
#
# WHAT  One script, two events, branching on `.hook_event_name`:
#   SubagentStop  checks the subagent's own work, in this order:
#     1. WRITE-BYPASS — reads the SUBAGENT's transcript (`.agent_transcript_path`; its Bash
#        tool inputs live there, not in the final text) and flags a redirect/tee to a
#        tracked-looking file. Runs FIRST, before every early exit, for REVIEW_AGENT_TYPES.
#     2. RESULT contract — reads `.last_assistant_message` (the subagent's final text) for
#        a `## RESULT` block with the required fields, for RESULT_CONTRACT_TYPES.
#     Findings go back to the SUBAGENT as hookSpecificOutput.additionalContext, which keeps
#     it running one more turn so it can re-send its answer with the block, or disclose the
#     write. `.stop_hook_active` true (it was already sent back once) → no message; the
#     native 8-consecutive-continuation cap is the backstop. `.transcript_path` is the
#     PARENT's transcript on this event and is never read.
#   PostToolUse (settings matcher `Agent`)  the parent-facing route. SubagentStop output
#     reaches only the subagent, so after a foreground `ralph-review` dispatch returns this
#     reads `sst3-ralph-restart-counter.sh --get` and hands the count, or the reason it is
#     unavailable, to the PARENT as additionalContext. `tool_response.status` of
#     `async_launched` (a background dispatch: no result yet) → no message. The counter is
#     never wired to PostToolUse itself: its event mode would book a second tier event.
#
# AGENT TYPES (edit here; nothing else names them)
#   RESULT_CONTRACT_TYPES — types whose final message must carry `## RESULT`:
#     ralph-review     every Ralph tier checklist requires it
#     general-purpose  the Agent-tool swarm fallback (Leader.md "Subagent RESULT block")
#     Anything else is silent: workflow-subagent (a Workflow leg's contract is its schema),
#     built-ins SST3 does not prompt with the contract (Explore, Plan, claude-code-guide,
#     statusline-setup, claude), and an empty agent_type.
#   REVIEW_AGENT_TYPES — WRITE-BYPASS scan. SST3 subagents are planning-only (CLAUDE.md
#     Ralph loop); the Write/Edit permission block does not cover a shell redirect.
#
# AUDIT (AP #12)  one line per event to SST3_SUBAGENT_RESULT_LOG
#   (default ~/.claude/hooks/subagent-result-parser.log): event, agent_type, agent_id,
#   decision, detail — so "has this ever fired" is answerable from the log.
#
# CONTRACT  stdin = the event JSON. jq required: without it nothing can be parsed, so the
#   hook tells the OPERATOR (systemMessage — an additionalContext would send every
#   subagent round again for an install defect) and exits 1.
#
# REVERSIBLE  Remove the SubagentStop and PostToolUse `Agent` entries from claude/settings.json.
set -uo pipefail

RESULT_CONTRACT_TYPES="ralph-review general-purpose"
REVIEW_AGENT_TYPES="ralph-review general-purpose workflow-subagent Explore Plan"
LOG="${SST3_SUBAGENT_RESULT_LOG:-$HOME/.claude/hooks/subagent-result-parser.log}"
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"
COUNTER="$HOOK_DIR/sst3-ralph-restart-counter.sh"

# shellcheck source=_lib-hook-output.sh
source "$HOOK_DIR/_lib-hook-output.sh"

EVENT="" ATYPE="" AID=""
audit() { # <decision> [detail]
  local rec
  printf -v rec 'ts=%s event=%s agent_type=%s agent_id=%s decision=%s detail=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${EVENT:--}" "${ATYPE:--}" "${AID:--}" "$1" "${2:--}"
  sst3_audit_append "$LOG" "$rec" subagent-result-parser || :
}
in_list() { [[ -n "$1" && " $2 " == *" $1 "* ]]; }

raw_stdin="$(cat 2>/dev/null || true)"
if ! command -v jq >/dev/null 2>&1; then
  audit degraded "jq missing"
  printf '{"systemMessage":"%s"}\n' 'SST3 subagent-result-parser: jq not found — subagent RESULT and write-bypass checks are OFF. Install jq: apt install jq (scripts/provision.sh installs it from wsl/packages.txt).'
  exit 1
fi

field() { printf '%s' "$raw_stdin" | jq -r "$1" 2>/dev/null; }
EVENT="$(field '.hook_event_name // empty')"

# ------------------------------------------------------------ PostToolUse (parent)
if [[ "$EVENT" == "PostToolUse" ]]; then
  ATYPE="$(field '.tool_input.subagent_type // empty')"
  AID="$(field '.tool_response.agentId // empty')"
  if [[ "$ATYPE" != "ralph-review" ]]; then
    audit out-of-scope; exit 0
  fi
  if [[ "$(field '.tool_response.status // empty')" == "async_launched" ]]; then
    audit async-launched "background dispatch: no result yet, count not reported"; exit 0
  fi
  cwd="$(field '.cwd // empty')"
  [[ -d "$cwd" ]] || cwd="$PWD"
  errf="$(mktemp -t sst3-parser-counter.XXXXXX)"
  count="$(cd "$cwd" && bash "$COUNTER" --get </dev/null 2>"$errf")"; rc=$?
  first_err="$(head -n1 "$errf" 2>/dev/null)"; rm -f "$errf"
  if [[ $rc -eq 0 && "$count" =~ ^[0-9]+$ ]]; then
    # The count alone cannot say what a FAIL now means: after --escalate it reads 0
    # again, and the one loop canon then permits ends in a report, not a restart
    # (ralph-review.md "Restart bound"). Before #577's escalation sweep this message
    # told that loop to --restart. The escalation is read from the current stage's
    # state field: --stage5 archives Stage 4's and opens a fresh loop. The path comes
    # from a dry run, which never writes a state file; no file means no escalation.
    bound="${SST3_RALPH_RESTART_BOUND:-3}"
    state_path="$(cd "$cwd" && SST3_RALPH_COUNTER_DRYRUN=1 bash "$COUNTER" --print-state-path </dev/null 2>/dev/null)"
    esc="null"
    if [[ -n "$state_path" && -f "$state_path" ]]; then
      esc="$(jq -r '.last_escalation_restart // "null"' "$state_path" 2>/dev/null)" || esc="unreadable"
      [[ -n "$esc" ]] || esc="unreadable"
    fi
    audit counter-reported "ralph_restarts=$count escalated=$esc"
    head_msg="SST3 ralph-restart-counter: ralph_restarts=$count for this worktree (read via --get)"
    if [[ "$esc" == "unreadable" ]]; then
      sst3_hook_emit PostToolUse "$head_msg, but whether an escalation is recorded could not be read from $state_path, so what a FAIL means now is unknown. Read ~/.claude/hooks/sst3-ralph-restart-counter.sh --print-state-path before acting (standards/stage-4/ralph-review.md)."
    elif [[ "$esc" != "null" ]]; then
      sst3_hook_emit PostToolUse "$head_msg; an escalation is recorded (at restart $esc), so this is the ONE Ralph loop canon permits after it. A tier FAIL that changes shipped behaviour is TERMINAL: do NOT --restart and do NOT --escalate again. Stop and report every outstanding finding with its class, what was tried, and the ledger state to the operator (standards/stage-4/ralph-review.md)."
    elif (( count >= bound )); then
      sst3_hook_emit PostToolUse "$head_msg: the restart bound ($bound) is reached. A tier FAIL that changes shipped behaviour does not restart: escalate once (bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --escalate, then ONE class-sweep), after which exactly ONE further Ralph loop is permitted (standards/stage-4/ralph-review.md)."
    else
      sst3_hook_emit PostToolUse "$head_msg. A tier FAIL that changes shipped behaviour: fix it, signal bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --restart, and restart at Tier 1. Restart $((bound + 1)) is not taken: escalate with --escalate instead (standards/stage-4/ralph-review.md)."
    fi
  else
    audit counter-unavailable "rc=$rc ${first_err:-no stderr}"
    sst3_hook_emit PostToolUse "SST3 ralph-restart-counter: --get exited $rc, so the restart count for this worktree is NOT available; do not report ralph_restarts as 0. ${first_err:-The counter printed no reason.}"
  fi
  exit 0
fi

# ------------------------------------------------------------- SubagentStop (subagent)
if [[ "$EVENT" != "SubagentStop" ]]; then
  audit ignored "unhandled event"
  exit 0
fi
ATYPE="$(field '.agent_type // empty')"
AID="$(field '.agent_id // empty')"
STOP_ACTIVE="$(field '.stop_hook_active // false')"
MSGS=()

# 1. WRITE-BYPASS (dotfiles#528 AC 4.3), before any early exit. Scans only the Bash tool
# inputs of the subagent's own transcript — never prose or the RESULT block, so the
# `tee_log:` field cannot trip it. fd redirects (`2>`) and scratch extensions (.log, .txt)
# are excluded by the non-digit lead + the code/doc extension filter, and so is a write
# under /tmp/ with no `..` in its path: the reviewers' scope files tell them to write
# scratch there, and flagging it (a Ralph scope's own `> /tmp/…/body.md`) told a
# compliant reviewer it had broken the rule (#577 Ralph r4 T3). `fromjson?` skips a
# partly-written last line (the transcript is written asynchronously).
if in_list "$ATYPE" "$REVIEW_AGENT_TYPES"; then
  at="$(field '.agent_transcript_path // empty')"
  # One pass prints the count of records jq could not read, then every Bash command. The
  # count is taken per record because jq's exit status reflects only the LAST line: a bad
  # earlier record was skipped in silence, and a bad last one hid the commands already found.
  # `objects` drops a bare-string content element (indexing one stops the record with "Cannot
  # index string", losing a write later in the same record). A scan that did not read every
  # record is logged as could-not-look, never as "no redirect found"; what it did find is
  # still reported.
  if [[ -n "$at" && -f "$at" && -r "$at" ]]; then
    jrc=0
    scan="$(jq -nrR '[inputs | fromjson? | try (select(.type=="assistant") | .message.content[]? | objects
                        | select(.type=="tool_use" and .name=="Bash") | {c: (.input.command // empty)}) catch {e: .}]
                     | (map(select(has("e"))) | length), (.[] | .c // empty)' "$at" 2>/dev/null)" || jrc=$?
    nerr="${scan%%$'\n'*}"; cmds="${scan#"$nerr"}"
    if [[ "$jrc" -ne 0 || "$nerr" != 0 ]]; then
      audit write-bypass-scan-failed "jq exit $jrc, unreadable records: ${nerr:-unknown}, reading $at"
    fi
    hits="$(printf '%s\n' "$cmds" \
      | grep -oE '((^|[^0-9])>>?[[:space:]]*|(^|[^A-Za-z0-9_])tee[[:space:]]+(-a[[:space:]]+)?)["'"'"']?[A-Za-z0-9_./-]+\.(py|js|jsx|ts|tsx|sh|md|json|ya?ml|toml|rs|sql|cfg|ini)([^A-Za-z0-9]|$)' \
      | awk '{ t = $0; sub(/^[^\/]*/, "", t); if (t ~ /^\/tmp\// && t !~ /\/\.\.(\/|$)/) next; print }' \
      | head -n5 | tr '\n' ' ')"
    if [[ -n "$hits" ]]; then
      audit write-bypass "$hits"
      MSGS+=("F-7 WRITE-BYPASS-DETECTED: your Bash commands wrote to a tracked-looking file through a shell redirect or tee ($hits). SST3 review subagents are planning-only, and a redirect bypasses the Write/Edit block. Write nothing more. Re-send your complete final answer and list every file you wrote under files_touched in its RESULT block, so the parent agent can check and revert it.")
    fi
  elif [[ -n "$at" ]]; then
    audit write-bypass-unreadable "$at"
  else
    audit write-bypass-no-transcript
  fi
fi

# 2. RESULT contract.
if in_list "$ATYPE" "$RESULT_CONTRACT_TYPES"; then
  if [[ "$(field 'has("last_assistant_message")')" != "true" ]]; then
    audit degraded "no last_assistant_message field"
    if [[ ${#MSGS[@]} -eq 0 ]]; then
      printf '{"systemMessage":"%s"}\n' 'SST3 subagent-result-parser: this SubagentStop event carries no last_assistant_message, so the RESULT check could not run (a Claude Code older than the hooks reference this parser follows?).'
      exit 1
    fi
  else
    final="$(field '.last_assistant_message')"
    block="$(printf '%s' "$final" | awk '
      /^[[:space:]]*##[[:space:]]+RESULT[[:space:]]*$/ { found=1; next }
      found && /^[[:space:]]*##[[:space:]]/ { found=0 }
      found { print }')"
    if [[ -z "${block//[[:space:]]/}" ]]; then
      audit result-missing
      MSGS+=("F-7: your final message has no \`## RESULT\` block (AP #14). Re-send your complete final answer and end it with the fenced \`## RESULT\` block your prompt requires: verdict, files_touched, findings, tee_log, scope_gaps (mcp_graph_available as its first line when you discuss graph queries).")
    else
      missing=()
      for f in "verdict:" "files_touched:" "findings:" "tee_log:" "scope_gaps:"; do
        grep -qF "$f" <<<"$block" || missing+=("$f")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        audit fields-missing "${missing[*]}"
        MSGS+=("F-7: your \`## RESULT\` block is missing fields: ${missing[*]}. Re-send your complete final answer with every required field in the block.")
      fi
      if grep -qiE 'graph|mcp_graph|callers_of|sst3-code-' <<<"$block"; then
        first="$(printf '%s' "$block" | awk 'NF { print; exit }')"
        if ! grep -qiE '^[[:space:]]*mcp_graph_available[[:space:]]*:[[:space:]]*(yes|no)' <<<"$first"; then
          audit graph-first-line
          MSGS+=("F-7: your \`## RESULT\` block discusses graph queries, so mcp_graph_available: yes|no must be its FIRST line (AP #19). Re-send your complete final answer with that line first.")
        fi
      fi
    fi
  fi
elif [[ ${#MSGS[@]} -eq 0 ]]; then
  audit out-of-contract
  exit 0
fi

if [[ ${#MSGS[@]} -eq 0 ]]; then
  audit result-ok
  exit 0
fi
if [[ "$STOP_ACTIVE" == "true" ]]; then
  # Already sent back once: say nothing more (loop bound); the findings stay in the log.
  audit stop-hook-active "suppressed ${#MSGS[@]} message(s)"
  exit 0
fi
sst3_hook_emit SubagentStop "${MSGS[*]}"
exit 0
