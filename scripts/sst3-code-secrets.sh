#!/usr/bin/env bash
# sst3-code-secrets.sh — Public-repo secret + private-token scanner.
#
# Usage:   sst3-code-secrets.sh --diff <base-branch> [--blocklist <path>]
#          sst3-code-secrets.sh --staged          [--blocklist <path>]
#          sst3-code-secrets.sh --file <path>     [--blocklist <path>]
#          sst3-code-secrets.sh --all             [--blocklist <path>]
# Output:  NDJSON, one object per match: {file, line, match_token, source, category}
#          source=blocklist|regex
#          category=shared|private-business|private-tradebook|public-marker|<other>
# Engines: git diff (mode-dependent) | grep -F -f <blocklist> for literal terms,
#          plus optional `gitleaks` if installed (regex layer).
#
# Rationale (#447 Phase 6): every public-repo push currently relies on the
# pre-commit hook `check-public-repo-secrets.py`. There is no
# request-scoped wrapper for ad-hoc audits ("does branch X contain blocked
# tokens?", "does the staging area leak anything?", "scan a single file in
# isolation"). This wrapper closes that gap with the canonical NDJSON
# contract so subagents can audit secret-leak risk on demand.

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

# The sentinel must not report a clean scan over files it could not read. Any
# entry in the read-failure log turns the exit non-zero, so a caller gating on
# this wrapper sees a could-not-look rather than `emitted 0 leak(s)` — the whole
# point of the Issue, applied to the scanner's own summary line.
_secrets_exit_sentinel() {
    local rc=$?
    wrapper_sentinel "sst3-code-secrets" "$SST3_EMITTED_COUNT" "leak"
    if [[ -s "${SST3_SCAN_READ_FAIL_LOG:-/dev/null}" ]]; then
        printf '%s: sst3-code-secrets: %s file(s) could NOT be read and were not scanned — this run does not certify them clean\n' \
            "$SST3_PROBE_FAILED_MARKER" "$(wc -l <"$SST3_SCAN_READ_FAIL_LOG")" >&2
        [[ "$rc" -eq 0 ]] && rc=2
    fi
    rm -f -- "${LITERAL_TMP:-}" "${SST3_SCAN_READ_FAIL_LOG:-}" "${PATCH_NAMES_TMP:-}"
    exit "$rc"
}
# Set before the trap can run: each is assigned later, or only in one mode, so an exit before
# then read the caller's environment. `PATCH_NAMES_TMP=<file> ... --file` deleted that file,
# and `=--help` printed rm's usage onto the NDJSON output (#577 Ralph r9 Opus).
LITERAL_TMP=""
SST3_SCAN_READ_FAIL_LOG=""
PATCH_NAMES_TMP=""
trap _secrets_exit_sentinel EXIT

SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-secrets" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-secrets" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM


MODE=""
TARGET=""
BLOCKLIST_OVERRIDE=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blocklist)
            BLOCKLIST_OVERRIDE="${2:-}"
            shift 2 || break
            ;;
        --diff|--staged|--file|--all)
            ARGS+=("$1")
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${ARGS[@]}"

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") --diff <base> | --staged | --file <path> | --all  [--blocklist <path>]" >&2
    exit 64
fi

if ! command -v git >/dev/null 2>&1; then
    echo 'ERROR: git not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

MODE="$1"
TARGET="${2:-}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BLOCKLIST=""
if [[ -n "$BLOCKLIST_OVERRIDE" ]]; then
    if [[ ! -r "$BLOCKLIST_OVERRIDE" ]]; then
        echo "ERROR: --blocklist path not readable: $BLOCKLIST_OVERRIDE" >&2
        exit 64
    fi
    BLOCKLIST="$BLOCKLIST_OVERRIDE"
elif [[ -r "$REPO_ROOT/.secret-blocklist" ]]; then
    BLOCKLIST="$REPO_ROOT/.secret-blocklist"
elif [[ -r "$REPO_ROOT/scripts/.secret-blocklist-canonical" ]]; then
    BLOCKLIST="$REPO_ROOT/scripts/.secret-blocklist-canonical"
else
    echo "ERROR: no .secret-blocklist, --blocklist override, or .secret-blocklist-canonical found" >&2
    exit 64
fi

# Build the literal-term list (strip comments, blank lines, section headers).
LITERAL_TMP=$(mktemp)
grep -vE '^\s*#|^\s*$|^\[' -- "$BLOCKLIST" > "$LITERAL_TMP" || true

if [[ ! -s "$LITERAL_TMP" ]]; then
    echo "WARN: blocklist resolved to empty literal-term list ($BLOCKLIST)" >&2
fi

# Section-categorise blocklist entries by section header. We re-scan the file
# carrying the active section forward so the NDJSON `category` field maps
# back to the [shared] / [private-business] / [private-tradebook] / etc. groupings.
classify_token() {
    local needle="$1"
    awk -v want="$needle" '
        /^\[/ { sect = substr($0, 2, length($0)-2); next }
        /^\s*#|^\s*$/ { next }
        $0 == want { print sect; exit }
    ' <"$BLOCKLIST"
}

emit_match() {
    local file="$1"
    local line="$2"
    local token="$3"
    local source="$4"
    local cat
    cat=$(classify_token "$token")
    [[ -z "$cat" ]] && cat="unknown"
    jq -nc --arg f "$file" --argjson l "$line" --arg t "$token" --arg s "$source" --arg c "$cat" \
        '{file:$f, line:$l, match_token:$t, source:$s, category:$c}'
    SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
}

# Read ONE file against the literal blocklist, distinguishing "no leak" from
# "could not read it" (#565 round 12, T3 S4).
#
# grep's contract: 0 = matched, 1 = matched nothing (the healthy empty), >=2 =
# an error — unreadable file, I/O failure. The previous `2>/dev/null || true`
# collapsed all three into silence, so a file the scanner could not open was
# indistinguishable from one it read and found clean. That is this Issue's
# thesis, inside the security scanner, at the level below the `find` walk round
# 11 repaired.
#
# Records failures in a FILE, not a variable. This runs inside `< <(...)`, a
# process substitution, which bash executes in a SUBSHELL — an incremented
# counter variable would be discarded on return and the parent would report a
# clean tree having been told nothing. (Noted explicitly because that is the
# same swallow one layer out, and the first draft of this fix had it.)
SST3_SCAN_READ_FAIL_LOG="$(mktemp)"
_scan_file_or_fail() {
    local file="$1" out rc
    # `if`-guarded, NOT a bare assignment. This file runs under `set -e` (:21),
    # so a bare `out="$(grep ...)"` on a failing grep aborts the shell BEFORE
    # `rc=$?` is reached — and because this executes inside a `< <(...)` process
    # substitution, the subshell dies in silence and the caller reads an empty
    # scan as a clean file. That is this Issue's own F2 (`ddd964a5`, "set -e made
    # the could-not-look path unreachable") reappearing in the fix for S4.
    # Inside an `if` condition, errexit is suspended and the status is ours.
    # `--` ends grep's options: a tracked file named `-i` was read as an option, grep
    # then read the caller's file list from stdin, and every file after it went
    # unscanned at exit 0 (#577 Ralph r8c).
    if out="$(grep -Fnof "$LITERAL_TMP" -- "$file" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [[ "$rc" -ge 2 ]]; then
        printf '%s: sst3-code-secrets: could not look: grep exited %s reading %s — this file was NOT scanned\n' \
            "$SST3_PROBE_FAILED_MARKER" "$rc" "$file" >&2
        printf '%s\n' "$file" >>"$SST3_SCAN_READ_FAIL_LOG"
        return 0
    fi
    # `\n`, not `%s` bare. Without the trailing newline the caller's
    # `while IFS= read -r RECORD` sets RECORD on the final line but `read`
    # returns non-zero at EOF, so the loop body never runs for it and a real
    # match is dropped in silence. Measured: the bare form reported
    # `emitted 0 leak(s)` on a file the shipped code finds a leak in.
    # An empty `out` yields one blank line, which the caller already skips.
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

# Scan a single text stream against the literal blocklist; emit one record
# per (line, blocked-token) hit. We use `grep -F -n -f` to surface line
# numbers + matched literals together.
scan_stream() {
    local label="$1"
    while IFS=: read -r line_no rest; do
        [[ -z "$line_no" || -z "$rest" ]] && continue
        # Find which blocked token matched (grep -F -o emits per-match).
        while IFS= read -r tok; do
            [[ -z "$tok" ]] && continue
            emit_match "$label" "$line_no" "$tok" "blocklist"
        done < <(printf '%s\n' "$rest" | grep -Fof "$LITERAL_TMP" -o 2>/dev/null || true)
    done
}

# --all scan-target enumeration (#565 AC 5.2 + AC 5.3).
#
# Pre-fix this was `git ls-files 2>/dev/null || true`, which is vacuous in TWO
# distinct ways, both MEASURED on a throwaway directory holding a
# `.secret-blocklist` listing a token and a `leaky.py` containing it, with
# `--blocklist` resolvable (without that precondition the scanner exits 64 and
# neither defect reproduces):
#
#   non-git directory        -> `emitted 0 leak(s)`, exit 0
#   git init, file UNTRACKED -> `emitted 0 leak(s)`, exit 0   <- the dangerous one
#   git init + git add       -> `emitted 1 leak(s)`
#
# So the real scope of the bug is *any file absent from `git ls-files`* — which
# includes a brand-new untracked file sitting in a fully governed live repo, not
# merely the exotic non-repo case. `--all` means all; it now enumerates tracked
# AND untracked-but-not-ignored files, and walks the filesystem when there is no
# repo at all. The walk is the CORRECT answer for `--all` outside a repo, not a
# silent degradation — and a genuine git failure inside a repo is loud.
# Both diff modes (--diff, --staged) scan added lines through here. Each file's name comes
# from git's NUL-separated name list, and that file's added lines from a diff of that file
# alone, so no name is ever parsed from a patch header (#577 Ralph r8b). Parsing `+++ b/`
# missed every name git quotes there (`"`, `\`, a tab; non-ASCII before core.quotePath),
# and a missed header kept the previous file's name, so with --paths-from the leak was
# dropped; a name with a space kept git's trailing tab. Hunk lines are read by state (after
# `@@`, before the next `diff --git`), so an added line that starts with `+` and an empty
# context line (diff.suppressBlankEmpty) are counted too. The diff reads as text whatever
# the config says (#577 Ralph r7 Opus): no colour, external diff, textconv or rename
# pairing. git runs from the repo root (so diff.relative cannot narrow it, #577 Ralph r8),
# with literal pathspecs.
scan_patch() {
    local label="$1"; shift
    local names_file err rc=0
    if ! names_file="$(mktemp)"; then
        printf '%s: %s — could not look: mktemp failed\n' "$SST3_PROBE_FAILED_MARKER" "$label" >&2
        return 2
    fi
    PATCH_NAMES_TMP="$names_file"
    err="$(git -C "$REPO_ROOT" diff --name-only -z --no-renames "$@" 2>&1 >"$names_file")" || rc=$?
    if (( rc != 0 )); then
        printf '%s: %s — could not look: git diff --name-only exited %s: %s\n' \
            "$SST3_PROBE_FAILED_MARKER" "$label" "$rc" "${err:0:300}" >&2
        return 2
    fi
    local -a names=()
    mapfile -d '' -t names < "$names_file"
    local name patch line content tok in_hunk offset
    for name in "${names[@]}"; do
        patch="$(probe_or_fail "$label ($name)" -- git -C "$REPO_ROOT" --literal-pathspecs \
            diff --no-color --no-ext-diff --no-textconv --text --no-renames "$@" -- "$name")" || return 2
        in_hunk=0
        offset=0
        while IFS= read -r line; do
            if [[ "$line" == "diff --git "* ]]; then
                in_hunk=0
                continue
            fi
            if [[ "$line" =~ ^@@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+) ]]; then
                offset="${BASH_REMATCH[2]}"
                in_hunk=1
                continue
            fi
            (( in_hunk )) || continue
            case "$line" in
                +*)
                    content="${line:1}"
                    while IFS= read -r tok; do
                        [[ -z "$tok" ]] && continue
                        emit_match "$name" "$offset" "$tok" "blocklist"
                    done < <(printf '%s\n' "$content" | grep -Fof "$LITERAL_TMP" -o 2>/dev/null || true)
                    offset=$((offset + 1)) ;;
                " "*|"") offset=$((offset + 1)) ;;
            esac
        done <<< "$patch"
    done
    return 0
}

enumerate_all_scan_targets() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # NOT a probe failure — the walk is the CORRECT answer for `--all`
        # outside a repo. This notice carried $SST3_PROBE_FAILED_MARKER until
        # #565 Ralph round 11 T3, which had it exactly backwards: the marker
        # fired on every healthy walk and stayed silent when the walk actually
        # broke, so it discriminated nothing. MEASURED both ways before and
        # after. Informational now; the marker below means what it says.
        printf 'sst3-code-secrets --all — not inside a git work tree; walking the filesystem instead of enumerating the index\n' >&2
        local walk_out walk_err walk_rc
        walk_out="$(mktemp)" || { printf '%s: sst3-code-secrets --all: filesystem walk — could not look: mktemp failed\n' "$SST3_PROBE_FAILED_MARKER" >&2; return 1; }
        walk_err="$(mktemp)" || { rm -f "$walk_out"; printf '%s: sst3-code-secrets --all: filesystem walk — could not look: mktemp failed\n' "$SST3_PROBE_FAILED_MARKER" >&2; return 1; }
        find . -type f -not -path './.git/*' >"$walk_out" 2>"$walk_err"
        walk_rc=$?
        # `find` exits non-zero if ANY directory was unreadable, having still
        # printed what it could. Taking that partial list as the whole tree is
        # how an unreadable subtree became `emitted 0 leak(s)` at exit 0 over a
        # real on-disk leak — the caller's "refusing to report 0 leaks over a
        # tree it never read" guard was unreachable from this leg because the
        # unconditional `return 0` never let it fire. Four of the five probe
        # legs in this file already used probe_or_fail; this was the fifth.
        if [[ "$walk_rc" -ne 0 ]]; then
            printf '%s: sst3-code-secrets --all: filesystem walk — could not look: find exited %s: %s\n' \
                "$SST3_PROBE_FAILED_MARKER" "$walk_rc" \
                "$(head -3 "$walk_err" | tr '\n' ' ')" >&2
            rm -f "$walk_out" "$walk_err"
            return 1
        fi
        sed 's|^\./||' "$walk_out" | sort -u
        rm -f "$walk_out" "$walk_err"
        return 0
    fi
    local tracked others
    # -z (#577 Stage 5 S7): a name git would quote — a `"`, a `\`, a non-ASCII byte —
    # came back as `"caf\303\251.py"`, failed the reader's `-f` test, and a leak in it
    # was never read.
    if ! tracked="$(probe_names_or_fail "sst3-code-secrets --all: tracked files" -- git ls-files -z)"; then
        return 1
    fi
    # `--exclude-standard` keeps .gitignore honoured, so .venv / node_modules
    # stay out; an ignored file cannot reach a remote, which is the risk this
    # scanner exists to bound.
    if ! others="$(probe_names_or_fail "sst3-code-secrets --all: untracked files" -- git ls-files -z --others --exclude-standard)"; then
        return 1
    fi
    printf '%s\n%s\n' "$tracked" "$others" | sed '/^$/d' | sort -u
}

case "$MODE" in
    --diff)
        if [[ -z "$TARGET" ]]; then
            echo "ERROR: --diff requires <base-branch>" >&2
            exit 64
        fi
        # A ref never starts with `-`; git read `--output=P` as an option, wrote the diff
        # to P and the scan reported 0 leaks (#577 Ralph r8c).
        if [[ "$TARGET" == -* ]]; then
            echo "ERROR: --diff <base-branch> must be a branch or commit, not an option: '$TARGET'" >&2
            exit 64
        fi
        # Enumeration status captured BEFORE the loop, exactly as --all does.
        # dotfiles#565 Ralph Tier 3 F9: AC 5.3 fixed --all and left --diff and
        # --staged carrying `2>/dev/null || true` inside a process substitution,
        # which discards the status twice over. Both are documented operator
        # modes. Tier 3 measured `--diff origin/main` against an unresolvable
        # ref: `emitted 0 leak(s)`, EXIT=0, over a real on-disk leak.
        if ! scan_patch "sst3-code-secrets --diff: diff ${TARGET}...HEAD" "${TARGET}...HEAD"; then
            echo "ERROR: sst3-code-secrets --diff could not produce a diff against '${TARGET}' — refusing to report 0 leaks over a range it never read (dotfiles#565 AC 5.3 / Ralph T3 F9)." >&2
            exit 2
        fi
        ;;
    --staged)
        # Same treatment as --diff above; this is the pre-commit path, so a
        # swallowed failure here reports a clean commit over an unread index.
        if ! scan_patch "sst3-code-secrets --staged: diff --cached" --cached; then
            echo "ERROR: sst3-code-secrets --staged could not read the staged diff — refusing to report 0 leaks over an index it never read (dotfiles#565 AC 5.3 / Ralph T3 F9)." >&2
            exit 2
        fi
        ;;
    --file)
        if [[ -z "$TARGET" || ! -r "$TARGET" ]]; then
            echo "ERROR: --file requires a readable path" >&2
            exit 64
        fi
        while IFS= read -r RECORD; do
            [[ -z "$RECORD" ]] && continue
            line_no="${RECORD%%:*}"
            rest="${RECORD#*:}"
            while IFS= read -r tok; do
                [[ -z "$tok" ]] && continue
                emit_match "$TARGET" "$line_no" "$tok" "blocklist"
            done < <(printf '%s\n' "$rest" | grep -Fof "$LITERAL_TMP" -o 2>/dev/null || true)
        # The same read --all uses: a path grep cannot read (a directory passes -r) is a
        # could-not-look, not a clean file (#577 Ralph r8c).
        done < <(_scan_file_or_fail "$TARGET")
        ;;
    --all)
        # The enumeration's exit status is captured BEFORE the loop: a process
        # substitution (`done < <(...)`) discards it entirely, which is half of
        # why the pre-fix `|| true` went unnoticed for so long.
        if ! ALL_TARGETS="$(enumerate_all_scan_targets)"; then
            echo "ERROR: sst3-code-secrets --all could not enumerate its scan targets — refusing to report 0 leaks over a tree it never read (dotfiles#565 AC 5.2)." >&2
            exit 2
        fi
        # Skip the blocklist/allowlist files themselves.
        while IFS= read -r FILE; do
            [[ ! -f "$FILE" ]] && continue
            [[ "$FILE" == *".secret-blocklist"* ]] && continue
            [[ "$FILE" == *".secret-allowlist"* ]] && continue
            while IFS= read -r RECORD; do
                [[ -z "$RECORD" ]] && continue
                line_no="${RECORD%%:*}"
                rest="${RECORD#*:}"
                while IFS= read -r tok; do
                    [[ -z "$tok" ]] && continue
                    emit_match "$FILE" "$line_no" "$tok" "blocklist"
                done < <(printf '%s\n' "$rest" | grep -Fof "$LITERAL_TMP" -o 2>/dev/null || true)
            # `2>/dev/null || true` swallowed a per-file READ failure, so an
            # unreadable file scanned as clean — a secrets scanner reporting
            # "0 leak(s)" over content it never saw. Round 11's F1 fixed the
            # `find` walk that BUILDS this list; this is the read of each file
            # ON the list, a second member of the same class one level down.
            #
            # grep's exit codes: 0 = matched, 1 = no match (the healthy empty),
            # >=2 = could not read. Only the first two are results.
            done < <(_scan_file_or_fail "$FILE")
        done <<< "$ALL_TARGETS"
        ;;
    *)
        echo "ERROR: unknown mode: $MODE (expected --diff|--staged|--file|--all)" >&2
        exit 64
        ;;
esac
