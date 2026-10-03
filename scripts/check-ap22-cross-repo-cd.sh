#!/usr/bin/env bash
# AP #22 enforcement: catch unprotected `cd <path> && git ...` patterns in
# scripts under scripts/ + scripts/. Subshell-protected forms
# `(cd <path> && git ...)` are exempt; `git -C <path>` is preferred.
#
# Wired as a pre-commit hook. Exits 1 if any violation found.
#
# Issue: hoiung/dotfiles#460 Phase 9 AC 9.7.
set -uo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$(readlink -f "$0")")/sst3-bash-utils.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DIRS=("$ROOT/SST3/scripts" "$ROOT/scripts")

# #565 AC 5.2. Two could-not-look paths were reported as clean:
#   * `[[ -d "$d" ]] || continue` — a MISSING scan directory was skipped in
#     silence. Both entries are structural to this repo; their absence means
#     ROOT resolved wrongly, so the scan covered nothing and still exited 0.
#   * `grep -rnE ... 2>/dev/null || true` — grep exits 1 on zero matches (a
#     legitimate empty result) but >1 on a real error, and the `|| true`
#     collapsed both into "no violations".
probe_failures=0

# Pattern: line starts with optional whitespace, has `cd <non-amp>` followed by
# `&& git ` — but NOT inside subshell parens. We can't detect parens with grep
# alone; we use a 2-step approach: first list candidates, then exclude lines
# containing `(cd `.
violations=()
for d in "${DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        printf '%s: check-ap22-cross-repo-cd — could not look: expected scan directory %s is absent (ROOT=%s resolved wrongly?)\n' \
            "$SST3_PROBE_FAILED_MARKER" "$d" "$ROOT" >&2
        probe_failures=$((probe_failures + 1))
        continue
    fi
    # grep: 0 = matches, 1 = zero matches (a real empty result), >1 = error.
    # Only the last is a could-not-look, so this cannot use probe_or_fail as-is.
    scan_out="$(grep -rnE 'cd [^&]+&& *git ' "$d" 2>&1)"
    scan_rc=$?
    if [[ "$scan_rc" -gt 1 ]]; then
        printf '%s: check-ap22-cross-repo-cd — could not look: grep exited %s scanning %s: %s\n' \
            "$SST3_PROBE_FAILED_MARKER" "$scan_rc" "$d" "$(printf '%s' "$scan_out" | tr '\n' ' ' | cut -c1-200)" >&2
        probe_failures=$((probe_failures + 1))
        continue
    fi
    [[ -z "$scan_out" ]] && continue
    while IFS= read -r line; do
        # Skip if subshell-protected (contains literal `(cd `).
        if grep -q '(cd ' <<<"$line"; then
            continue
        fi
        # Strip the file:lineno: prefix from grep -n output to inspect content.
        content=$(echo "$line" | sed -E 's/^[^:]+:[0-9]+://')
        # Skip pure-comment lines (bash `#` or shell-script `# `).
        if grep -qE '^[[:space:]]*#' <<<"$content"; then
            continue
        fi
        # Skip lines inside heredoc/string-literal contexts where `cd` is data
        # not a command. Heuristic: skip lines with backticks-only or single-quote
        # only context surrounding `cd`. Cheap detection of common false positives.
        if grep -qE '`cd [^&]+&& *git' <<<"$content"; then
            continue
        fi
        violations+=("$line")
    done <<< "$scan_out"
done

# A scan that could not run reports could-not-look, never clean — even when the
# part of it that DID run found nothing.
if [[ "$probe_failures" -gt 0 ]]; then
    echo "[ap22-check] FAIL: $probe_failures scan probe(s) could not be completed — refusing to report clean on an unscanned tree." >&2
    exit 2
fi

if [[ ${#violations[@]} -eq 0 ]]; then
    exit 0
fi

echo "============================================================" >&2
echo "AP #22 violation(s) detected (cross-repo cd && git not subshell-protected):" >&2
echo "============================================================" >&2
for v in "${violations[@]}"; do
    echo "  $v" >&2
done
echo "" >&2
echo "Fix: use 'git -C <path> <subcmd>' (preferred) or '(cd <path> && git ...)' (subshell-protected)." >&2
echo "Canonical: standards/ANTI-PATTERNS.md AP #22." >&2
exit 1
