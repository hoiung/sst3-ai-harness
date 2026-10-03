# Tier 1: Haiku Review (Surface Checks)

> **PLANNING MODE ONLY**: You are a REVIEWER. Do NOT write code, do NOT edit files, do NOT make commits. Your ONLY job is to verify and report findings. **Reviewer Isolation (#555 Phase 3):** any formatter/linter you invoke MUST run in its read-only check form (`cargo fmt -- --check`, `ruff format --check` — never the mutating form), and you must NEVER run a mutating git op (merge/checkout/stash/rebase/reset) — inspect the worktree read-only, so a review pass can never pollute the main agent's Gate-2 index.
>
> **STEP-0 tree-lock (MANDATORY first action):** subagents START in the main clone, which is a DIFFERENT, stale tree from the implementing agent's worktree — a review run there returns a false verdict against the wrong code. Before ANY check: run `git rev-parse --show-toplevel`, paste its output in your RESULT block, and confirm it matches the worktree path the dispatcher named; prefix every shell command with `cd <worktree> && `; verify the dispatcher-supplied tree FINGERPRINT (a file- or test-count true only in the worktree) and STOP with verdict FAIL "wrong tree" on any mismatch. A dispatch prompt that names no worktree path or fingerprint is itself a finding.
>
> **Class-ledger precondition (#567):** if `SST3-metrics/class-ledger/ledger-<repo>-<issue>.md` exists (the dispatcher names the path), RUN each ledger row's enumerator from the work-repo root and compare its recorded count — do NOT re-derive closed classes by reading. Count drift = FAIL (the enumerator is wrong or the class re-opened). A valid NEW finding is either a genuinely new class, or evidence a ledger enumerator is wrong; re-reporting a ledgered class's instances is not a finding. Canonical: `standards/stage-4/ralph-review.md` + `standards/stage-4/mutation-verification.md`.

Fast surface validation.

**Completion Promise**: `<promise>HAIKU_PASS</promise>`

## Checklist

### File Structure / Checkboxes / Commits / Debug Code
- [ ] All new files in correct locations per STANDARDS.md; named per conventions; no temp files (`temp/`, `C:/temp/`, `$SST3_TEMP/`, `*.tmp`, `*.bak`)
- [ ] All "Expected Behavior" + "Acceptance Criteria" checkboxes have evidence; no unchecked mandatory checkboxes
- [ ] All commits on current solo branch reference issue number (#X); format `type: description (#issue)`; no WIP/temp commits
- [ ] No `console.log`, `print()` debug statements, debug flags enabled, or commented-out old code
- [ ] Linter documented in CLAUDE.md (ruff / shellcheck / etc.) runs clean on the diff (sub-30s) (AC 5.4)

### Governance — Checkbox-MCP Evidence Audit (AP #20)
- [ ] **Checkbox-MCP evidence audit**: fetch issue body via `mcp__github__get_issue` or `mcp__github-checkbox__get_issue_checkboxes` (ToolSearch-bootstrap if deferred per STANDARDS.md "MCP Tool Schema Loading"); parse `## Proof of Work` section. Sample 3 random `[x]` boxes; verify each has a matching PoW entry AND the evidence text matches a `mcp__github-checkbox__update_issue_checkbox` invocation pattern (file:line / commit / command output / subagent RESULT). **Fail if any checked box has narrative-only evidence OR lacks a Proof of Work entry**. Do NOT use `get_issue_events` timeline (self-edit-suppressed per STANDARDS.md). Canonical: STANDARDS.md "Governance Evidence Signal (Canonical)", AP #20, tool-selection-guide.md Example 2.

### STANDARDS.md Violation Scan — Surface (per-tier escalation lens)

> Categories canonical in [`_common-culprits.md`](_common-culprits.md). Haiku's surface lens: scan for the syntactic surface signature of each category.

- [ ] **5-culprits surface scan**: copy-pasted code blocks / magic numbers + hardcoded URLs+paths / inline math + hardcoded thresholds / commented-out code + TODO referencing old approaches / `except: pass` + `|| default` patterns hiding required config. Flag occurrences with file:line. Legitimate optional defaults (argparse `default=`, function default args for non-required tunables) are NOT violations.

### Cross-Boundary Contracts (Issue #1407 post-mortem) — Surface

- [ ] SQL WHERE values match actual DB enum/column values; new SQL queries only reference columns existing in target table; new YAML keys consumed by code (`.get()` or `[]`); nullable params guarded before arithmetic / `.toFixed()` / `float()` / `Decimal()`; recovery/replay/drain wired to ALL lifecycle events (startup AND reconnect, not just one); try/except blocks wrap functions that actually raise; no duplicate DB queries within same function; data-bug fixes repair existing bad rows (not just future data).

### Bash Output Discipline
> Canonical: [`_bash-output-discipline.md`](_bash-output-discipline.md). Apply checkbox here.

### Wrapper-Lane Surface Checks

> Doc-only exemption: [`_doc-only-exemption.md`](_doc-only-exemption.md) (run FIRST — short-circuits CODE checks). Preconditions: [`_wrapper-lane-preconditions.md`](_wrapper-lane-preconditions.md). (`$SST3` in the commands below: the Script path section of the Preconditions file.)

- [ ] **Doc-lane (diff-triggered, #484 W6.3 — runs regardless of `graph_applicable` / doc-only-exemption whenever the diff touches `*.md`/frontmatter)**: run `bash $SST3/sst3-doc-lint.sh <changed.md...>` + `bash $SST3/sst3-doc-links.sh <changed.md...>` on the diff's changed docs. **Both are triage REPORTERS, not zero-gates**: emit one NDJSON object per finding. **Run-proof contract (#484 Stage-5 — FIXED)**: BOTH wrappers emit an unconditional stderr sentinel — `sst3-doc-links: scanned N path(s), M broken link(s)` and `sst3-doc-lint: scanned N path(s), M finding(s)` — and on engine crash emit a loud `ENGINE CRASHED (exit=N)` line + non-zero exit (2). A clean run (exit 0, sentinel present) is mechanically distinguishable from "didn't run". **RESULT MUST confirm the `scanned N path(s)` sentinel is present; its absence or an `ENGINE CRASHED` line is a FAIL.** Triage: a finding is a FAIL only if **net-new on a doc this diff changed** — and net-new is **MEASURED, never assumed**: lint the base-commit content of the same paths (`git show <merge-base>:<path>` into a temp file, then lint that) and compare the counts. Long-form governance docs routinely carry hundreds of pre-existing MD013 line-length findings, so an unmeasured baseline of 0 is almost always wrong and turns a no-op diff into a FAIL. A baseline you did not run is a vacuous baseline. Method canonical: WORKFLOW.md VL-4 — do not restate it, run it. Skip-clean if no doc file in diff.
- [ ] `bash $SST3/sst3-code-large.sh 100 <lang>` — any new/modified function approaching 200 lines?
- [ ] `bash $SST3/sst3-code-impact.sh <base-branch>` — any unexpected downstream impacts in callers?
- [ ] Orphaned-function scan: for each modified function, `bash $SST3/sst3-code-callers.sh <name> <lang>` — zero callers in the same module = orphan candidate (subagent confirms intent).

### Fallback + MCP discrimination
> Fallback clause: [`_fallback-clause.md`](_fallback-clause.md). AP #19 `mcp_graph_available: yes|no` first-line rule in [`_wrapper-lane-preconditions.md`](_wrapper-lane-preconditions.md). Apply both here.

## Pass Criteria

ALL checkboxes above verified with evidence (structural via wrapper-lane where supported, semantic/fallback via subagent per `_fallback-clause.md`). RESULT block documents wrapper calls + fallback reasons. Silent skip of wrapper checks when available = FAIL. Doc-only PR exemption per `_doc-only-exemption.md` = PASS.

## On Pass

Output: `<promise>HAIKU_PASS</promise>`

## On Fail

1. List failed items with file:line references
2. Do NOT output promise
3. The main agent fixes and restarts from Tier 1 — bounded: up to 3 restarts, one escalation, then ONE further loop; a FAIL in that loop is stop-and-report, not another iteration
