#!/usr/bin/env bash
# sst3-dep-cve.sh — Wrap pip-audit / cargo audit / npm audit into NDJSON.
#
# Usage:   sst3-dep-cve.sh
# Output:  NDJSON, one object per advisory:
#          {ecosystem, package, version, cve_id, severity}
#          severity: lowercase canonical (low|medium|high|critical|unknown)
# Engines: pip-audit (Python) | cargo audit (Rust) | npm audit (JS).
#          require_engine_version warn-only on each (per Phase 3).
# Behaviour: advisories flow via NDJSON, never via the exit code — consumers
#            decide. Every ecosystem is attempted; then the exit code says
#            whether each one was actually LOOKED AT:
#            0   = every present manifest's engine ran and its output parsed;
#            3   = an engine ran but broke (no output, unparseable output, or an
#                  npm `.error` payload): one {kind:"dep-cve-error"} record per
#                  ecosystem, and sst3-check --strict reads the phase as error;
#            127 = a manifest is present but its engine is not installed.
#            Until #577 all three printed a stderr WARN and exited 0, which
#            `sst3-check --dep --strict` (the CI gate) read as "no advisories"
#            (escalation class C3, fail-open reader).

set -euo pipefail

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"
export LC_ALL=C
SST3_EMITTED_COUNT=0

trap 'wrapper_sentinel "sst3-dep-cve" "$SST3_EMITTED_COUNT" "advisory"' EXIT
on_sigterm() {
    jq -nc --arg n "sst3-dep-cve" --argjson e "$SST3_EMITTED_COUNT" \
        '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    exit 143
}
trap on_sigterm SIGTERM

if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# Parse synthetic-fixture mode: if --fixture-stub is set, emit a single
# canned advisory record so the self-test fixture does not need network.
# Stage 5 fix (D2) — recognise --paths-from explicitly to surface bad usage.
# (Records lack a `.file` field by design — the canonical filter is a no-op
# here per the activate_paths_from_filter `if (.file? // null) == null`
# fallback, but silently swallowing an unknown flag is worse UX than
# accepting it and emitting unfiltered output.)
FIXTURE_STUB=""
PATHS_FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture-stub)
            FIXTURE_STUB="${2:-}"
            shift 2 || break
            ;;
        --paths-from)
            PATHS_FROM="${2:-}"
            shift 2 || break
            ;;
        *)
            shift
            ;;
    esac
done

# Validate --paths-from path even though records lack .file (per design).
if [[ -n "$PATHS_FROM" && ! -r "$PATHS_FROM" ]]; then
    echo "ERROR: --paths-from file not readable: $PATHS_FROM" >&2
    exit 64
fi

if [[ -n "$FIXTURE_STUB" ]]; then
    if [[ ! -r "$FIXTURE_STUB" ]]; then
        echo "ERROR: --fixture-stub path not readable: $FIXTURE_STUB" >&2
        exit 64
    fi
    # Stub is NDJSON; pass through and count.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line"
        SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
    done < "$FIXTURE_STUB"
    exit 0
fi

emit_record() {
    local ecosystem="$1" package="$2" version="$3" cve_id="$4" severity="$5"
    severity=$(printf '%s' "$severity" | tr '[:upper:]' '[:lower:]')
    [[ -z "$severity" ]] && severity="unknown"
    jq -nc --arg e "$ecosystem" --arg p "$package" --arg v "$version" --arg c "$cve_id" --arg s "$severity" \
        '{ecosystem:$e, package:$p, version:$v, cve_id:$c, severity:$s}'
    SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
}

COULD_NOT_LOOK=()
ENGINE_MISSING=()
# could_not_look <ecosystem> <reason>: the engine ran but its answer is unusable.
could_not_look() {
    COULD_NOT_LOOK+=("$1")
    echo "ERROR: $1 advisories could not be read: $2" >&2
    jq -nc --arg e "$1" --arg r "$2" '{kind:"sst3-dep-cve-error", ecosystem:$e, reason:$r}'
}
# rows <ecosystem> <json> <jq-filter>: emit one record per advisory row. Parsing
# is checked: a malformed payload used to be `2>/dev/null || true`, i.e. zero
# rows, i.e. clean.
rows() {
    local eco="$1" json="$2" filter="$3" tsv
    if ! tsv="$(printf '%s' "$json" | jq -r "$filter" 2>&1)"; then
        could_not_look "$eco" "its JSON did not parse as expected: $(printf '%s' "$tsv" | head -c 200)"
        return 0
    fi
    while IFS=$'\t' read -r pkg ver cve sev; do
        [[ -z "$pkg" ]] && continue
        emit_record "$eco" "$pkg" "$ver" "$cve" "$sev"
    done <<< "$tsv"
}

# --- Python via pip-audit ---
if [[ -n "$(find . -maxdepth 4 -type f \( -name pyproject.toml -o -name requirements.txt -o -name poetry.lock \) \
    -not -path './.git/*' -print -quit 2>/dev/null)" ]]; then
    if command -v pip-audit >/dev/null 2>&1; then
        require_engine_version pip-audit 2.6
        # Stage 5 fix (D2) — capture pip-audit exit code; emit stderr WARN
        # if non-zero so consumers can distinguish "engine ran cleanly, no
        # advisories" from "engine broke / network blocked" without changing
        # exit-code policy (advisory data flows via NDJSON per docstring).
        # pip-audit -f json emits {dependencies:[{name, version, vulns:[{id, fix_versions, ...}]}]}
        _pip_audit_rc=0
        _pip_audit_out=$(pip-audit -f json 2>/dev/null) || _pip_audit_rc=$?
        # pip-audit exits 1 when it FINDS advisories, with JSON on stdout, so a
        # non-zero rc alone is not a failure; a payload without .dependencies is.
        if ! printf '%s' "$_pip_audit_out" | jq -e '.dependencies | type == "array"' >/dev/null 2>&1; then
            could_not_look python "pip-audit exited $_pip_audit_rc without a dependency list (network blocked? environment broken?)"
        else
            rows python "$_pip_audit_out" '
                .dependencies[]
                | . as $d
                | $d.vulns[]?
                | [$d.name, $d.version, .id, (.severity // "unknown")] | @tsv'
            # A dependency pip-audit could not audit (a local package not on
            # PyPI, say) carries skip_reason. Not a failure, but it was dropped
            # without a word; it is now counted and named.
            _skipped="$(printf '%s' "$_pip_audit_out" | jq -r '[.dependencies[] | select(.skip_reason) | "\(.name) (\(.skip_reason))"] | join("; ")')"
            if [[ -n "$_skipped" ]]; then
                echo "WARN: pip-audit could not audit: $_skipped" >&2
            fi
        fi
    else
        echo "ERROR: pip-audit not installed, but a python manifest is present: python advisories were NOT checked" >&2
        ENGINE_MISSING+=(python)
    fi
fi

# --- Rust via cargo audit ---
if [[ -n "$(find . -maxdepth 4 -type f -name Cargo.lock -not -path './.git/*' -print -quit 2>/dev/null)" ]]; then
    if command -v cargo-audit >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1; then
        require_engine_version cargo 1.70
        _cargo_audit_rc=0
        _cargo_audit_out=$(cargo audit --json 2>/dev/null) || _cargo_audit_rc=$?
        # cargo audit exits non-zero ALSO when vulnerabilities are found, so the
        # payload decides: one without .vulnerabilities means it did not run.
        if ! printf '%s' "$_cargo_audit_out" | jq -e '.vulnerabilities | type == "object"' >/dev/null 2>&1; then
            could_not_look rust "cargo audit exited $_cargo_audit_rc without a vulnerability report (network blocked? Cargo.lock malformed?)"
        else
            rows rust "$_cargo_audit_out" '
                .vulnerabilities.list[]?
                | [.package.name, .package.version, .advisory.id, (.advisory.severity // "unknown")] | @tsv'
        fi
    else
        echo "ERROR: cargo audit not installed, but a Cargo.lock is present: rust advisories were NOT checked" >&2
        ENGINE_MISSING+=(rust)
    fi
fi

# --- JavaScript via npm audit ---
if [[ -n "$(find . -maxdepth 4 -type f -name package-lock.json -not -path './.git/*' -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]]; then
    if command -v npm >/dev/null 2>&1; then
        require_engine_version npm 9.0
        _npm_audit_rc=0
        _npm_audit_out=$(npm audit --json 2>/dev/null) || _npm_audit_rc=$?
        # npm reports its own failures (ENOLOCK, a registry error) as JSON with
        # an .error key and no .vulnerabilities; that parsed to zero rows.
        if ! printf '%s' "$_npm_audit_out" | jq -e '(.error | not) and (.vulnerabilities | type == "object")' >/dev/null 2>&1; then
            could_not_look javascript "npm audit exited $_npm_audit_rc without a vulnerability report: $(printf '%s' "$_npm_audit_out" | jq -r '.error.summary // .error.code // empty' 2>/dev/null | head -c 200)"
        else
            rows javascript "$_npm_audit_out" '
                .vulnerabilities | to_entries[]
                | .key as $k
                | .value.via[]?
                | select(type == "object")
                | [$k, (.range // ""), (.url // ""), (.severity // "unknown")] | @tsv'
        fi
    else
        echo "ERROR: npm not installed, but a package-lock.json is present: javascript advisories were NOT checked" >&2
        ENGINE_MISSING+=(javascript)
    fi
fi

if [[ "${#COULD_NOT_LOOK[@]}" -gt 0 ]]; then
    echo "ERROR: advisories NOT established for: ${COULD_NOT_LOOK[*]} (engine ran but broke)" >&2
    exit 3
fi
if [[ "${#ENGINE_MISSING[@]}" -gt 0 ]]; then
    echo "ERROR: advisories NOT established for: ${ENGINE_MISSING[*]} (engine not installed)" >&2
    exit 127
fi
exit 0
