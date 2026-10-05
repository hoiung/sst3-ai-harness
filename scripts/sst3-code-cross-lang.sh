#!/usr/bin/env bash
# sst3-code-cross-lang.sh — Cross-language IPC edge detector.
#
# Usage:   sst3-code-cross-lang.sh <symbol> [--mechanism M1,M2,M3,M4,M6] [--include-tests]
# Example: sst3-code-cross-lang.sh pb-data-service-rs1
#          sst3-code-cross-lang.sh "pb:cmd:sentiment" --mechanism M3,M4
# Output:  NDJSON, one object per detected edge:
#          {kind:"cross-lang-edge", mechanism, source:{file,line,lang,role},
#           target:{file,line,lang,role}, token, confidence, evidence}
# Engines: ripgrep (literal token search) + jq + python3 (YAML parse).
#
# Mechanism roster (Phase 6 ships M1/M2/M3/M4/M6; M5/M7-M10 deferred):
#   M1 subprocess     — Python subprocess.run / shell exec of a known binary
#   M2 systemd        — `[Unit]` files / `ExecStart=` referencing a unit
#   M3 redis-key      — Redis key CQRS (key prefix in YAML matched in source)
#   M4 redis-cmd-queue — Redis cmd-queue literal (queue name in YAML matched)
#   M6 SQL tables     — Tables shared across binaries (FROM/JOIN/INSERT/UPDATE)
#
# Per-repo IPC binary map (REQUIRED for M1/M2): file at
#     <repo-root>/SST3-config/sst3-cross-lang-binaries.yaml
# Schema documented at: dotfiles/config/sst3-cross-lang-binaries.template.yaml
# Missing config: stderr WARN + skip M1/M2 (FAIL-LOUD, not silent-zero).

set -euo pipefail

export LC_ALL=C
SST3_EMITTED_COUNT=0
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

trap 'wrapper_sentinel "sst3-code-cross-lang" "$SST3_EMITTED_COUNT" "edge"' EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-cross-lang" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-cross-lang" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM


if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <symbol> [--mechanism M1,M2,M3,M4,M6] [--include-tests]" >&2
    exit 64
fi

SYMBOL="$1"
shift
# An empty needle matches every line (`rg -F -e ""`) and every binary name, so M3/M4 emitted
# an edge per line of the repo (#577 Stage 5 fix review r2).
if [[ -z "$SYMBOL" ]]; then
    echo "ERROR: the symbol is empty; name the symbol to trace." >&2
    exit 64
fi
MECHANISMS="M1,M2,M3,M4,M6"
INCLUDE_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --mechanism)
            : # consume value below
            ;;
        --mechanism=*) MECHANISMS="${arg#--mechanism=}" ;;
        --include-tests) INCLUDE_TESTS=1 ;;
        M[1-9]*|M[1-9]*,*) MECHANISMS="$arg" ;;
    esac
done

if ! command -v rg >/dev/null 2>&1; then
    echo 'ERROR: ripgrep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CONFIG_FILE="$REPO_ROOT/SST3-config/sst3-cross-lang-binaries.yaml"
HAS_CONFIG=0
if [[ -r "$CONFIG_FILE" ]]; then
    HAS_CONFIG=1
fi

# Test-path filter: skip if --include-tests not set.
TEST_FILTER=()
if [[ "$INCLUDE_TESTS" -eq 0 ]]; then
    TEST_FILTER=(-g '!**/test_*' -g '!**/*_test.*' -g '!**/tests/**' -g '!**/__tests__/**')
fi

emit_edge() {
    local mechanism="$1"
    local src_file="$2"
    local src_line="$3"
    local src_lang="$4"
    local src_role="$5"
    local tgt_file="$6"
    local tgt_line="$7"
    local tgt_lang="$8"
    local tgt_role="$9"
    local token="${10}"
    local confidence="${11}"
    local evidence="${12}"
    jq -nc \
        --arg m "$mechanism" \
        --arg sf "$src_file" --argjson sl "$src_line" --arg slg "$src_lang" --arg sr "$src_role" \
        --arg tf "$tgt_file" --argjson tl "$tgt_line" --arg tlg "$tgt_lang" --arg tr "$tgt_role" \
        --arg t "$token" --arg c "$confidence" --arg e "$evidence" \
        '{kind:"cross-lang-edge", mechanism:$m,
          source:{file:$sf, line:$sl, lang:$slg, role:$sr},
          target:{file:$tf, line:$tl, lang:$tlg, role:$tr},
          token:$t, confidence:$c, evidence:$e}'
    SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
}

# Lang inference from extension.
infer_lang() {
    case "$1" in
        *.py) echo python ;;
        *.rs) echo rust ;;
        *.ts) echo typescript ;;
        *.tsx) echo tsx ;;
        *.js) echo javascript ;;
        # #548: .jsx → javascript (NOT tsx — the tsx grammar parses no .jsx on
        # ast-grep 0.42.1). `*.js)` above cannot shadow this: it matches only
        # names ending in ".js".
        *.jsx) echo javascript ;;
        *.go) echo go ;;
        *.sh|*.bash) echo bash ;;
        *.yml|*.yaml) echo yaml ;;
        *.sql) echo sql ;;
        *.service|*.target|*.timer) echo systemd ;;
        *) echo unknown ;;
    esac
}

# literal_hits <needle> <dest> — rg in literal mode + test filter; per-match NUL-ended
# (file, line, text) into <dest>. `-e` keeps a needle that starts with `-` a pattern, not
# an rg option, and rg's rc is checked before jq reads anything: `rg … 2>/dev/null | jq`
# read `-v_table` as flags and an unreadable directory as zero matches, exit 0 (#577
# Stage 5 fix review R4 — the S3 class in sst3-code-search.sh). rc >= 2 emits the engine
# error record and ends the run, as sst3-code-search.sh does.
literal_hits() {
    local needle="$1" dest="$2" raw rc=0
    raw="$(mktemp)"
    rg --json -F -n -e "$needle" "${TEST_FILTER[@]}" . > "$raw" 2>/dev/null || rc=$?
    if ! ast_grep_check_rc "sst3-code-cross-lang" "$rc" rg; then
        rm -f "$raw" "$dest"
        exit 0
    fi
    # Three NUL-ended fields per match (file, line, text). The hit loops read TSV with a tab
    # IFS until #577 Stage 5 fix review r2: a file name that is not UTF-8 reaches rg's JSON as
    # .data.path.bytes, .text was null, the empty first field merged into the next, and
    # M1-M4 died in emit_edge's --argjson (rc 2, partial output) while M6 dropped the match.
    # An edge carries a text name, so such a match is named on stderr instead of lost.
    jq -j 'select(.type=="match" and .data.path.text != null)
           | (.data.path.text, (.data.line_number|tostring), ((.data.lines.text // "") | rtrimstr("\n"))) + "\u0000"' \
        < "$raw" > "$dest"
    jq -r 'select(.type=="match" and .data.path.text == null) | .data.path.bytes' < "$raw" | sort -u \
        | while IFS= read -r b64; do
            printf '[sst3-code-cross-lang] a match in a file whose name is not UTF-8 (base64 %s) is not reported: edges carry text names. Rename the file.\n' "$b64" >&2
        done
    rm -f "$raw"
}

# _config_rows <M1|M2> — the config's binaries table as TSV rows (M1: name, lang,
# source_dir; M2: unit, name, lang, source_dir). The config path is passed in argv: it
# was pasted into `python3 -c`, so a quote in the path broke the program. A config
# python cannot read (PyYAML missing, malformed YAML, a non-mapping entry) is
# could-not-look, rc 2 — `2>/dev/null || true` read it as "no binaries" and the
# lane reported zero edges (#577 Stage 5 S6).
_config_rows() {
    local mode="$1" out err rc=0
    err="$(mktemp)"
    out="$(python3 - "$CONFIG_FILE" "$mode" 2>"$err" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
for name, meta in (data.get("binaries") or {}).items():
    meta = meta or {}
    lang, src = meta.get("lang", "unknown"), meta.get("source_dir", "")
    if sys.argv[2] == "M1":
        print(f"{name}\x1f{lang}\x1f{src}")
    elif meta.get("systemd_unit"):
        print(f"{meta['systemd_unit']}\x1f{name}\x1f{lang}\x1f{src}")
PY
)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s: sst3-code-cross-lang %s — could not look: python3 could not read %s (rc %s): %s\n' \
            "$SST3_PROBE_FAILED_MARKER" "$mode" "$CONFIG_FILE" "$rc" "$(tail -1 "$err")" >&2
        rm -f "$err"
        return 2
    fi
    rm -f "$err"
    printf '%s\n' "$out"
}

run_M1() {
    # Subprocess invocations of known binaries from YAML.
    if [[ "$HAS_CONFIG" -ne 1 ]]; then
        echo "WARN: M1 (subprocess) skipped — no $CONFIG_FILE; populate from dotfiles/config/sst3-cross-lang-binaries.template.yaml" >&2
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARN: M1 (subprocess) skipped — python3 not installed (needed to parse YAML)" >&2
        return 0
    fi
    # Iterate binaries from YAML where binary basename matches SYMBOL or YAML
    # contains SYMBOL anywhere relevant.
    local rows
    rows="$(_config_rows M1)" || exit 2
    # Rows are \x1f-joined: with a tab IFS an empty name merged into the next field, so
    # the guard below never saw it (#577 Stage 5 fix review R11).
    while IFS=$'\x1f' read -r BIN BIN_LANG BIN_SRC; do
        # An empty name would match every SYMBOL (every string contains "").
        [[ -z "$BIN" ]] && continue
        # Match if SYMBOL == binary name OR symbol is contained in binary name.
        if [[ "$BIN" != *"$SYMBOL"* && "$SYMBOL" != *"$BIN"* ]]; then
            continue
        fi
        local hits
        hits="$(mktemp)"
        literal_hits "$BIN" "$hits"
        while IFS= read -r -d '' FILE && IFS= read -r -d '' LN && IFS= read -r -d '' TEXT; do
            [[ -z "$FILE" ]] && continue
            local SRC_LANG
            SRC_LANG=$(infer_lang "$FILE")
            emit_edge "M1" "$FILE" "$LN" "$SRC_LANG" "caller" \
                "$BIN_SRC" 0 "$BIN_LANG" "callee" \
                "$BIN" "high" "subprocess invocation"
        done < "$hits"
        rm -f "$hits"
    done <<< "$rows"
}

run_M2() {
    # systemd unit references.
    if [[ "$HAS_CONFIG" -ne 1 ]]; then
        echo "WARN: M2 (systemd) skipped — no $CONFIG_FILE" >&2
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARN: M2 (systemd) skipped — python3 not installed" >&2
        return 0
    fi
    local rows
    rows="$(_config_rows M2)" || exit 2
    while IFS=$'\x1f' read -r UNIT BIN_NAME BIN_LANG BIN_SRC; do
        [[ -z "$UNIT" ]] && continue
        if [[ "$UNIT" != *"$SYMBOL"* && "$SYMBOL" != *"$UNIT"* && "$BIN_NAME" != *"$SYMBOL"* ]]; then
            continue
        fi
        local hits
        hits="$(mktemp)"
        literal_hits "$UNIT" "$hits"
        while IFS= read -r -d '' FILE && IFS= read -r -d '' LN && IFS= read -r -d '' TEXT; do
            [[ -z "$FILE" ]] && continue
            local SRC_LANG
            SRC_LANG=$(infer_lang "$FILE")
            emit_edge "M2" "$FILE" "$LN" "$SRC_LANG" "controller" \
                "$BIN_SRC" 0 "$BIN_LANG" "service" \
                "$UNIT" "high" "systemd unit reference"
        done < "$hits"
        rm -f "$hits"
    done <<< "$rows"
}

run_M3() {
    # Redis key CQRS — keys with prefix matching SYMBOL or YAML pattern.
    local hits
    hits="$(mktemp)"
    literal_hits "$SYMBOL" "$hits"
    while IFS= read -r -d '' FILE && IFS= read -r -d '' LN && IFS= read -r -d '' TEXT; do
        [[ -z "$FILE" ]] && continue
        local SRC_LANG
        SRC_LANG=$(infer_lang "$FILE")
        emit_edge "M3" "$FILE" "$LN" "$SRC_LANG" "redis-client" \
            "redis://" 0 "redis" "key-store" \
            "$SYMBOL" "medium" "redis key reference"
    done < "$hits"
    rm -f "$hits"
}

run_M4() {
    # Redis cmd-queue — literal queue name SYMBOL appears in source. Same
    # mechanic as M3 from the wrapper's POV; the distinction is documentary
    # (operator chooses --mechanism M3 vs M4 to label the edge correctly).
    local hits
    hits="$(mktemp)"
    literal_hits "$SYMBOL" "$hits"
    while IFS= read -r -d '' FILE && IFS= read -r -d '' LN && IFS= read -r -d '' TEXT; do
        [[ -z "$FILE" ]] && continue
        local SRC_LANG
        SRC_LANG=$(infer_lang "$FILE")
        emit_edge "M4" "$FILE" "$LN" "$SRC_LANG" "queue-producer-or-consumer" \
            "redis-queue" 0 "redis" "queue" \
            "$SYMBOL" "medium" "redis cmd-queue reference"
    done < "$hits"
    rm -f "$hits"
}

run_M6() {
    # SQL table names referenced across files (FROM/JOIN/INSERT/UPDATE/DELETE).
    local hits
    hits="$(mktemp)"
    literal_hits "$SYMBOL" "$hits"
    while IFS= read -r -d '' FILE && IFS= read -r -d '' LN && IFS= read -r -d '' TEXT; do
        [[ -z "$FILE" ]] && continue
        local SRC_LANG
        SRC_LANG=$(infer_lang "$FILE")
        # Cheap heuristic: only emit when the line contains a SQL keyword
        # to filter out comments / variable names / unrelated mentions.
        if grep -Eqi '\b(FROM|JOIN|INSERT INTO|UPDATE|DELETE FROM|TABLE)\b' <<<"$TEXT"; then
            emit_edge "M6" "$FILE" "$LN" "$SRC_LANG" "sql-caller" \
                "$SYMBOL" 0 "sql" "table" \
                "$SYMBOL" "high" "SQL table reference (FROM/JOIN/INSERT/UPDATE/DELETE)"
        fi
    done < "$hits"
    rm -f "$hits"
}

# Drive the requested mechanisms.
IFS=',' read -ra REQ <<< "$MECHANISMS"
for M in "${REQ[@]}"; do
    case "$M" in
        M1) run_M1 ;;
        M2) run_M2 ;;
        M3) run_M3 ;;
        M4) run_M4 ;;
        M6) run_M6 ;;
        M5|M7|M8|M9|M10)
            echo "WARN: mechanism $M not yet implemented (#447 Phase 6 ships M1/M2/M3/M4/M6); see Issue #447 for follow-up scope" >&2
            ;;
        *) echo "WARN: unknown mechanism: $M" >&2 ;;
    esac
done
