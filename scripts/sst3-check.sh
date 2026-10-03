#!/usr/bin/env bash
# sst3-check.sh — Layer-2 orchestrator composing the wrapper-lane (code, sec, dep, doc, sync).
#
# Usage:   sst3-check.sh [--code | --sec | --dep | --doc | --sync | --all] [--quiet]
# Default: --all
# Output:  NDJSON stream:
#          - One {kind:"orchestrator-progress", phase:"<label>", status:"started"} per phase
#          - Findings from each wrapper, tagged with {kind:"<area>", ...}
#            EXCEPT records whose kind ends in "-error" or "-killed" — those
#            pass through with their own kind preserved (#547 AC 6.3)
#          - One {kind:"orchestrator-progress", phase:"<label>", status:"complete|...", findings:N, seconds:T}
#            per phase on completion
#          - One terminating {kind:"orchestrator-complete", phases:[...], findings:N} on EXIT
#          The orchestrator-complete sentinel is emitted via EXIT trap so it
#          appears EVEN on early termination — lets consumers distinguish
#          "all phases done" from "killed mid-stream".
# Exit:    0 = no findings
#          1 = findings emitted
#          2 = --strict and at least one phase COULD NOT LOOK (see below)
#          64 = usage error (unreadable --paths-from)
#          This line previously read "127 = required engine missing", which this
#          script has never returned — engine-missing is an inner wrapper's exit
#          code, escalated here to 2. Corrected in the same pass as the fourth
#          could-not-look route (#565 Ralph round 10 T3).
# Engines: composes sst3-code-* (Phase A) + sst3-doc-* (Phase B) + sst3-sync-* (Phase C)
#          + sst3-sec-* / sst3-dep-* (Phase 8a/8b); the run_or_skip lines below are the list.
#
# #445 R4 Bug B fix: pre-fix, the FINDINGS counter was incremented inside a
# pipeline subshell at the old emit() function — parent shell always saw 0.
# No completion sentinel meant consumers couldn't tell "ran clean" from
# "killed mid-stream". 5 inner wrappers exiting 127 silently produced no
# diagnostic JSON, indistinguishable from "no findings". Now: counter is
# captured via temp file + wc -l (real count, not subshell-lost), each phase
# emits started/complete progress sentinels with status+findings+seconds,
# and the EXIT trap guarantees orchestrator-complete fires even on SIGTERM
# from outer `timeout`.

set -euo pipefail

MODE=all
QUIET=0
STRICT=0
PATHS_FROM=""
# while-shift loop (not `for arg`) so --paths-from can consume its value arg.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --code) MODE=code ;;
        --sec) MODE=sec ;;
        --dep) MODE=dep ;;
        --doc) MODE=doc ;;
        --sync) MODE=sync ;;
        --all) MODE=all ;;
        --quiet) QUIET=1 ;;
        --strict) STRICT=1 ;;
        --paths-from)
            shift
            [[ $# -gt 0 ]] || { echo "ERROR: --paths-from requires a path argument" >&2; exit 64; }
            PATHS_FROM="$1"
            ;;
        --paths-from=*) PATHS_FROM="${1#*=}" ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 64 ;;
    esac
    shift
done

# Diff-scoping forward (#507 AC 2.2): only the SEC/DEP wrappers accept --paths-from.
# Built as an array so it expands to nothing when unset — no spurious empty arg
# reaches the code/doc/sync wrappers under `set -u`.
PATHS_FROM_ARGS=()
if [[ -n "$PATHS_FROM" ]]; then
    if [[ ! -r "$PATHS_FROM" ]]; then
        echo "ERROR: --paths-from file not readable: $PATHS_FROM" >&2
        exit 64
    fi
    PATHS_FROM_ARGS=(--paths-from "$PATHS_FROM")
fi

WRAPPER_DIR="$(dirname "$(realpath "$0")")"
FINDINGS=0
PHASES_DONE=()
ENGINE_MISSING_COUNT=0

# Wrappers that REQUIRE explicit args (target symbol/class/lang) and therefore
# do NOT compose into --all — they're invoked directly when needed. The Shape 31
# orchestrator-meta record exposes this list so engineers reading "phases=N"
# from the output understand which wrappers got skipped by design vs by failure.
TARGET_REQUIRED_SKIPPED=(
    sst3-code-callers
    sst3-code-callees
    sst3-code-search
    sst3-code-impact
    sst3-code-review
    sst3-code-subclasses
    sst3-code-callers-transitive
    sst3-code-coverage
    sst3-code-cross-lang
    sst3-code-secrets
    sst3-code-shell
    sst3-code-recent-changes
    sst3-code-at-ref
    sst3-dep-usage
    sst3-dep-blast-radius
    sst3-sync-doc-to-code
)

# Per-phase timeout — prevents one slow inner wrapper from starving the rest
# under an outer wallclock cap.
PHASE_TIMEOUT="${SST3_CHECK_PHASE_TIMEOUT:-90}"
# Whole seconds only: `timeout` read a value such as `--help` as its own option, printed its
# help and ran no phase, so `--strict` exited 0 over a finding (#577 Ralph r9b Sonnet).
if [[ ! "$PHASE_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SST3_CHECK_PHASE_TIMEOUT must be a whole number of seconds, not '$PHASE_TIMEOUT'" >&2
    exit 64
fi
# mktemp builds the per-phase capture paths from TMPDIR, and they reach rm and head as trusted
# operands: `TMPDIR=-x` made `rm` read one as an option and `set -e` stop the run after its
# first phase with exit 1, the findings code (#577 Ralph r9c).
if [[ -n "${TMPDIR:-}" && "$TMPDIR" != /* ]]; then
    echo "ERROR: TMPDIR must be an absolute path, not '$TMPDIR'" >&2
    exit 64
fi

# EXIT trap: emit orchestrator-complete sentinel UNCONDITIONALLY. Guarantees
# downstream consumers can detect "orchestrator finished" via a terminating
# NDJSON record, regardless of whether we exited cleanly, hit `set -e`, or
# got SIGTERM from an outer timeout.
on_exit() {
    local rc=$?
    local phases_json
    if [[ ${#PHASES_DONE[@]} -eq 0 ]]; then
        phases_json='[]'
    else
        phases_json=$(printf '%s\n' "${PHASES_DONE[@]}" | jq -R . | jq -sc .)
    fi
    jq -nc \
        --argjson p "$phases_json" \
        --argjson n "$FINDINGS" \
        --arg m "$MODE" \
        '{kind:"orchestrator-complete", mode:$m, phases:$p, findings:$n}'
    exit "$rc"
}
trap on_exit EXIT

run_or_skip() {
    local LABEL="$1"
    local SCRIPT="$2"
    shift 2

    # Started sentinel
    jq -nc --arg p "$LABEL" '{kind:"orchestrator-progress", phase:$p, status:"started"}'

    # A wrapper that is not on disk did not probe anything. It used to record
    # `skipped`, which nothing consumed, so `--strict` returned 0 — byte-identical
    # to a run where every phase completed clean (#565 Ralph round 10 T3). The
    # status is now DISTINCT from a by-design skip so the could-not-look gate
    # below can escalate it without swallowing any legitimate skip.
    if [[ ! -f "$SCRIPT" ]]; then
        jq -nc --arg p "$LABEL" '{kind:"orchestrator-progress", phase:$p, status:"missing-script", reason:"script not found"}'
        PHASES_DONE+=("$LABEL:missing-script")
        return 0
    fi

    [[ "$QUIET" -eq 0 ]] && echo "[sst3-check] running $LABEL" >&2

    local start=$SECONDS
    local tmp stderr_tmp
    # A temp file that cannot be made stopped the run under `set -e` with exit 1, the findings
    # code, over no phase at all. It is a could-not-look (#577 Ralph r9 Opus).
    tmp="" stderr_tmp=""
    if ! tmp=$(mktemp) || ! stderr_tmp=$(mktemp); then
        [[ -n "$tmp" ]] && rm -f -- "$tmp"
        echo "[sst3-check] could not make a temp file under '${TMPDIR:-/tmp}'; this run did NOT confirm the target is clean" >&2
        exit 2
    fi
    set +e
    # #447 Phase 2: capture inner stderr to per-phase tmp file instead of
    # /dev/null. Engine-broken wrappers wrote diagnostics to stderr that the
    # orchestrator was throwing away; now we surface them in NDJSON so consumers
    # can debug without re-running.
    timeout --preserve-status -- "$PHASE_TIMEOUT" bash -- "$SCRIPT" "$@" >"$tmp" 2>"$stderr_tmp"
    local rc=$?
    set -e

    local lines=0
    if [[ -s "$tmp" ]]; then
        # Tag each wrapper-emitted NDJSON line with the orchestrator's kind.
        # #547 AC 6.3 (defect B): DISCRIMINATING passthrough — `-error` records
        # (ast_grep_check_rc broken-engine, #544 convention) and `-killed`
        # SIGTERM sentinels keep their own kind (the blanket `. + {kind:$k}`
        # right-operand-wins relabel was masking them as normal findings);
        # every other record keeps today's area relabel.
        while IFS= read -r LINE; do
            [[ -z "$LINE" ]] && continue
            echo "$LINE" | jq -c --arg k "$LABEL" \
                'if (.kind // "" | (endswith("-error") or endswith("-killed"))) then . else . + {kind: $k} end' \
                2>/dev/null || true
            lines=$((lines + 1))
        done < "$tmp"
    fi
    rm -f "$tmp"

    # Surface captured stderr as a structured NDJSON record (#447 Phase 2 / Shape 27).
    if [[ -s "$stderr_tmp" ]]; then
        local stderr_lines stderr_sample
        stderr_lines=$(wc -l < "$stderr_tmp")
        # Sample first 5 lines, JSON-array-encoded.
        stderr_sample=$(head -n 5 "$stderr_tmp" | jq -R . | jq -sc .)
        jq -nc \
            --arg p "$LABEL" \
            --argjson n "$stderr_lines" \
            --argjson s "$stderr_sample" \
            '{kind:($p + "-stderr-captured"), lines:$n, sample:$s}'
    fi
    rm -f "$stderr_tmp"

    # Inventory phases (#537): their stdout rows are enumerations of what EXISTS
    # (one row per dependency / a repo-status object), not defects — they must
    # not drive the exit-1 "findings emitted" gate. Pre-#537 `--dep --strict`
    # exited 1 on ANY repo with ≥1 dependency even with zero dep-cve advisories
    # (the sec-dep-audit.yml chronic red). Gate-relevant rows (sec-*, dep-cve,
    # doc-*, code-large, ...) still count. The per-phase progress sentinel below
    # reports the raw line count either way.
    case "$LABEL" in
        dep-list|code-status) ;;  # inventory — excluded from the findings gate
        *) FINDINGS=$((FINDINGS + lines)) ;;
    esac

    local status
    case "$rc" in
        0)        status=complete ;;
        124|143)  status=timeout ;;       # 124 = `timeout` direct, 143 = SIGTERM via --preserve-status
        127)      status=engine-missing ;;
        # 126 = found but not executable (bad mode bits, noexec mount). The
        # wrapper never ran, so this is could-not-look, not a skip. It was
        # labelled `skipped` and exited 0 under --strict until #565 round 10 T3.
        126)      status=not-executable ;;
        *)        status=error ;;
    esac

    if [[ "$status" == "engine-missing" ]]; then
        ENGINE_MISSING_COUNT=$((ENGINE_MISSING_COUNT + 1))
    fi

    jq -nc \
        --arg p "$LABEL" \
        --arg s "$status" \
        --argjson n "$lines" \
        --argjson t $((SECONDS - start)) \
        --argjson rc "$rc" \
        '{kind:"orchestrator-progress", phase:$p, status:$s, findings:$n, seconds:$t, exit:$rc}'

    PHASES_DONE+=("$LABEL:$status")
}

if [[ "$MODE" == "all" || "$MODE" == "code" ]]; then
    run_or_skip code-status "$WRAPPER_DIR/sst3-code-status.sh"
    run_or_skip code-large "$WRAPPER_DIR/sst3-code-large.sh" 200 python
    run_or_skip code-untested-py "$WRAPPER_DIR/sst3-code-untested-py.sh"
    # Stage 5 fix (D5) — wire Phase 8 no-arg code wrappers.
    run_or_skip code-config "$WRAPPER_DIR/sst3-code-config.sh"
    run_or_skip code-orphans "$WRAPPER_DIR/sst3-code-orphans.sh" python
    # #547 AC 7.5: entry-points requires a <lang> positional (like orphans above);
    # the bare dispatch usage-errored every --all run (pre-existing, canonical
    # 27439841 identical) so it never drove records through the preserve-kind
    # path. `python` matches the orphans precedent (this repo is python/bash).
    run_or_skip code-entry-points "$WRAPPER_DIR/sst3-code-entry-points.sh" python
    # NOTE: sst3-code-{callers, callees, callers-transitive, search, impact, review,
    # subclasses, coverage, cross-lang, secrets, shell, recent-changes, at-ref}
    # require explicit targets — see TARGET_REQUIRED_SKIPPED.
fi

# Stage 5 fix (D5) — Phase 8a security wrappers (all no-arg).
if [[ "$MODE" == "all" || "$MODE" == "sec" ]]; then
    run_or_skip sec-subprocess "$WRAPPER_DIR/sst3-sec-subprocess.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
    run_or_skip sec-deserialize "$WRAPPER_DIR/sst3-sec-deserialize.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
    run_or_skip sec-secret-touchpoints "$WRAPPER_DIR/sst3-sec-secret-touchpoints.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
    run_or_skip sec-input-sources "$WRAPPER_DIR/sst3-sec-input-sources.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
fi

# Stage 5 fix (D5) — Phase 8b dep wrappers (no-arg subset; usage + blast-radius
# require <package> arg → TARGET_REQUIRED_SKIPPED).
if [[ "$MODE" == "all" || "$MODE" == "dep" ]]; then
    run_or_skip dep-list "$WRAPPER_DIR/sst3-dep-list.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
    run_or_skip dep-cve "$WRAPPER_DIR/sst3-dep-cve.sh" "${PATHS_FROM_ARGS[@]+"${PATHS_FROM_ARGS[@]}"}"
fi

if [[ "$MODE" == "all" || "$MODE" == "doc" ]]; then
    run_or_skip doc-lint "$WRAPPER_DIR/sst3-doc-lint.sh"
    run_or_skip doc-yaml "$WRAPPER_DIR/sst3-doc-yaml.sh"
    run_or_skip doc-frontmatter "$WRAPPER_DIR/sst3-doc-frontmatter.sh"
    run_or_skip doc-links "$WRAPPER_DIR/sst3-doc-links.sh"
    # Stage 5 fix (D5) — Phase 8c doc anchor-link drift (no-arg).
    run_or_skip doc-toc "$WRAPPER_DIR/sst3-doc-toc.sh"
fi

if [[ "$MODE" == "all" || "$MODE" == "sync" ]]; then
    run_or_skip sync-related-code "$WRAPPER_DIR/sst3-sync-related-code.sh"
    # Eviction guard: detect references to the displaced legacy MCP graph token.
    # Token is constructed at runtime to avoid tripping the same eviction hook
    # that this orchestrator phase is designed to detect.
    EVICTION_TOKEN="mcp__$(printf '%s' code-review-graph)__"
    run_or_skip sync-tool-eviction "$WRAPPER_DIR/sst3-sync-tool-eviction.sh" "$EVICTION_TOKEN"
    # NOTE: sst3-sync-doc-to-code.sh requires <doc> + <lang> args — not composable
    # without a default doc selection. Invoke directly when needed.
fi

if [[ "$QUIET" -eq 0 ]]; then
    echo "[sst3-check] mode=$MODE findings=$FINDINGS phases=${#PHASES_DONE[@]} engine_missing=$ENGINE_MISSING_COUNT strict=$STRICT" >&2
fi

# Shape 31 fix (#447 Phase 2): emit an orchestrator-meta record exposing how
# many wrappers actually composed vs how many were skipped by design. Without
# this, "phases=9" leaves engineers wondering whether there are 9 wrappers
# total or 19 with 10 silently absent.
SKIPPED_JSON=$(printf '%s\n' "${TARGET_REQUIRED_SKIPPED[@]}" | jq -R . | jq -sc .)
jq -nc \
    --argjson r "${#PHASES_DONE[@]}" \
    --argjson s "$SKIPPED_JSON" \
    --arg m "$MODE" \
    '{kind:"orchestrator-meta", mode:$m, composable_phases_run:$r, target_required_skipped:$s}'

# --strict propagation (#447 Phase 2 silent-clean fix): without --strict, any
# inner engine-missing exits 0 (silent-clean). With --strict, ANY engine-missing
# wrapper escalates to exit 2 — distinct from "findings present" (1) and "all
# clean" (0). /Leader Stage 1a runs --strict by default per Phase 5 edits.
if [[ "$STRICT" -eq 1 ]] && [[ "$ENGINE_MISSING_COUNT" -gt 0 ]]; then
    echo "[sst3-check] STRICT: $ENGINE_MISSING_COUNT phase(s) missing engine — exit 2" >&2
    exit 2
fi

# A phase that TIMED OUT or ERRORED is a could-not-look, exactly like
# engine-missing, and until dotfiles#565 escalation-1 it drove nothing
# (dotfiles#565). Only ENGINE_MISSING_COUNT and FINDINGS decided the exit code,
# so `doc-lint:timeout` was recorded in the phases array and then ignored.
#
# MEASURED on this repo at 453ec43e: `--doc --strict` runs five phases, doc-lint
# exceeds the 90s PHASE_TIMEOUT against the whole tree, and the command exited 1
# — but ONLY because 506 pre-existing findings happened to exist in the other
# four phases. On a tree with those cleaned up, the identical run exits 0 and
# reports "clean" while one phase of five never executed. That is the invariant
# this Issue is named for, living in the orchestrator that fronts the whole
# wrapper lane and is called by Ralph tiers and pre-commit hooks.
#
# The doc lane is whole-tree by design — `--paths-from` is forwarded to the
# SEC/DEP wrappers only (STANDARDS.md "Fail-loud contract"), so it cannot be
# diff-scoped down to fit. Raise the budget for a big tree with
# SST3_CHECK_PHASE_TIMEOUT=<seconds> rather than reading exit 0 as clean.
#
# Exit 2 is the same signal as engine-missing because it means the same thing:
# this run did NOT establish that the target is clean. Deliberately NOT exit 1
# — that means "ran, found things", which is a different and much weaker claim.
# FOUR routes, not two. The first version of this block converted timeout and
# error — the two statuses in front of it at the time — and left the two that
# arrive through the early-return above and the 126 arm. A missing wrapper
# exited 0 with an EMPTY stderr, indistinguishable from a clean run, in the
# gate built to stop exactly that (#565 Ralph round 10 T3). engine-missing is
# handled by its own counter below and is not repeated here.
_could_not_look=()
for _p in "${PHASES_DONE[@]}"; do
    case "$_p" in
        *:timeout|*:error|*:missing-script|*:not-executable) _could_not_look+=("$_p") ;;
    esac
done
if [[ "$STRICT" -eq 1 ]] && [[ "${#_could_not_look[@]}" -gt 0 ]]; then
    echo "[sst3-check] STRICT: ${#_could_not_look[@]} phase(s) could not complete — ${_could_not_look[*]} — exit 2" >&2
    echo "[sst3-check] a phase that did not finish has NOT confirmed the target is clean; re-run with SST3_CHECK_PHASE_TIMEOUT=<seconds> (current: ${PHASE_TIMEOUT}s) or install the failing engine" >&2
    exit 2
fi

[[ "$FINDINGS" -gt 0 ]] && exit 1
exit 0
