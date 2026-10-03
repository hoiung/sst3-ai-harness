---
description: Layer-2 orchestrator composing the SST3 wrapper-lane to surface code, security, dependency, doc and sync findings in one command. Wraps scripts/sst3-check.sh.
---

# /sync-check Skill

Layer-2 orchestrator that composes the SST3 wrapper-lane to surface code, sec, dep, doc and sync findings in one command. Wraps `dotfiles/scripts/sst3-check.sh`.

## What this skill does

When invoked, this skill runs `bash $SST3/sst3-check.sh` in the current repo (`$SST3` resolved first, in the same shell call, by `SST3=$( [ -f scripts/load-stage-rules.sh ] && echo scripts/ || echo "<your-dotfiles-clone>/scripts/" )` — the Leader.md Guardrails resolver, so the skill runs in a consumer repo and in any worktree, c4:T68) and reports findings as a structured table. By default it runs every area (`--all`: code, sec, dep, doc, sync); pass an arg to narrow scope.

## Usage

```
/sync-check                  → run every area (--all)
/sync-check code             → code wrappers only (--code)
/sync-check sec              → security wrappers only (--sec)
/sync-check dep              → dependency wrappers only (--dep; dep-cve needs the network)
/sync-check doc              → doc wrappers only (--doc)
/sync-check sync             → sync wrappers only (--sync)
```

**What `/sync-check` does NOT compose** (intentional — these need explicit args):

The wrappers that need a target symbol, pattern, package or base branch are not orchestrator-composable. `sst3-check.sh` names them in its `TARGET_REQUIRED_SKIPPED` list and reports that list in its `orchestrator-meta` record. Invoke them directly when needed, for example:

```bash
bash $SST3/sst3-code-callers.sh <symbol> <lang>
bash $SST3/sst3-code-callees.sh <function> <lang>
bash $SST3/sst3-code-callees.sh <Class.method> <lang>          # method scoped to class
bash $SST3/sst3-code-callees.sh <Class> <lang> --class         # union of all class methods
bash $SST3/sst3-code-subclasses.sh <ClassName> <lang>          # reverse-inheritance lookup (#445 R4)
bash $SST3/sst3-code-search.sh <pattern> <lang> [--literal]
bash $SST3/sst3-code-impact.sh <base-branch>
bash $SST3/sst3-code-review.sh origin/<base-branch>   # fetched remote ref: a stale local branch widens the diff
bash $SST3/sst3-sync-doc-to-code.sh <doc-file> [<lang>]
```

Same applies to `sst3-sync-tool-eviction.sh <evicted_token>` — the orchestrator composes it with a runtime-constructed displaced-MCP token; for any other eviction guard, invoke directly.

## Orchestrator output contract (#445 R4)

Each invocation of `sst3-check.sh` emits, in addition to per-phase findings:

- `{kind:"orchestrator-progress", phase, status:"started"}` per phase
- `{kind:"orchestrator-progress", phase, status, findings, seconds, exit}` on phase completion
  - `status`: `complete | timeout | engine-missing | error | missing-script | not-executable`. `skipped` was REMOVED in #565 — both producers were renamed so the could-not-look gate could escalate them; a status this enum still listed could no longer be emitted, and the two that replaced it were absent
- One terminating `{kind:"orchestrator-complete", mode, phases:[...], findings:N}` via EXIT trap (fires on SIGTERM / `set -e` / clean exit)

The orchestrator-complete sentinel is the canonical done marker — its absence = killed mid-stream. Per-phase 90s timeout via `$SST3_CHECK_PHASE_TIMEOUT`.

## What it composes

The `run_or_skip` lines in `sst3-check.sh` are the authority; this is a reader's copy.

- **code**: `sst3-code-status.sh` (wrapper-lane status), `sst3-code-large.sh 200 python` (functions over 200 lines), `sst3-code-untested-py.sh`, `sst3-code-config.sh`, `sst3-code-orphans.sh python`, `sst3-code-entry-points.sh python`
- **sec**: `sst3-sec-{subprocess,deserialize,secret-touchpoints,input-sources}.sh`
- **dep**: `sst3-dep-list.sh`, `sst3-dep-cve.sh`
- **doc**: `sst3-doc-{lint,yaml,frontmatter,links,toc}.sh`
- **sync**: `sst3-sync-related-code.sh` (frontmatter `related_code:` drift), `sst3-sync-tool-eviction.sh <displaced-mcp-token>` (the orchestrator builds the token at runtime so it does not trip its own guard)

## Output

NDJSON to stdout, one finding per line, each tagged with `kind: "<area>"`. Pipe to `jq` for filtering:

```bash
bash $SST3/sst3-check.sh --all 2>/dev/null | jq -c 'select(.kind | startswith("doc-"))'
```

## Exit codes

- 0 — no findings
- 1 — findings emitted (review and fix)
- 2 — `--strict` and at least one phase could not look (an inner wrapper's engine missing, a timeout, an error; see `docs/guides/code-query-playbook.md` "Wrapper-Script Lane > Install")
- 64 — usage error (an unreadable `--paths-from`)

## Required engines

Per the wrapper-lane install steps:
- `ast-grep` (cargo install ast-grep --locked)
- `ripgrep` (apt install ripgrep)
- `lychee` (cargo install lychee --locked)
- `markdownlint-cli2` (npm install -g markdownlint-cli2)
- `yamllint` (pipx install yamllint)
- `coverage` (pipx install coverage) — for code-untested-py
- `pip-audit` / `cargo audit` / `npm audit` — for dep-cve, one per manifest type present
- `jq` (apt install jq)

If any engine is missing, the relevant wrapper exits 127 with a documented stderr contract message; `sst3-check.sh` continues with the rest.

## Pre-commit hook integration

The default `--all` mode has no pre-commit wiring. Only `--sec` does, via hooks `sst3-sec` (pre-commit) and `sst3-sec-prepush` (pre-push), both through `scripts/sec-staged-scan.sh`; `--dep` runs in CI (`.github/workflows/sec-dep-audit.yml`).

## See also

- `docs/guides/code-query-playbook.md` — operational guide for the wrapper-lane
- `standards/wrapper-lane-tools.txt` — authoritative allow-list
