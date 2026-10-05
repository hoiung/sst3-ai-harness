---
description: SST3-Solo Mode — load STANDARDS.md + ANTI-PATTERNS.md + the repo CLAUDE.md, display the reading summary, prompt for the task, then execute it under the SST3 guardrails (worktree branch safety, verification loop, Ralph Review, user-review checklist).
---

# SST3-Solo Mode

## Mandatory Reading

**SST3 script path — resolve `$SST3` FIRST, in the same shell call**:

```bash
SST3=$( [ -f scripts/load-stage-rules.sh ] && echo scripts/ || echo "<your-dotfiles-clone>/scripts/" )
```

Then invoke every SST3 script as `bash $SST3/<script>.sh ...`. This is required because no fixed path works everywhere: a bare `scripts/...` exits 127 from any consumer repo, and a `$HOME`-anchored path silently reads the MAIN dotfiles clone even when you are in a dotfiles worktree — so a session editing `standards/**` would validate the wrong tree. The resolver above picks the local canon when one exists (dotfiles clone or its worktrees, including your own in-flight edits) and falls back to the dotfiles clone otherwise (consumer repos and their worktrees). Verified across all four. Confirm exit 0 before relying on any output. **A 127 here means the path did not resolve — it does NOT mean a missing inner engine**; do not apply the engine-missing remedy below to it. If the fallback branch itself 127s, the dotfiles clone is not at `<your-dotfiles-clone>` on this machine — resolve it instead from the installed command symlink (`dirname $(dirname $(readlink -f ~/.claude/commands))`), which `install.sh` creates pointing at the canonical root. Do NOT substitute a full `STANDARDS.md` read on failure: the per-stage cluster files (`stage-N/*.md`) exist ONLY in the loader's output, so a full-canon read silently omits them.

**Post-#498 Phase 4 — per-stage loader**: prefer `bash $SST3/load-stage-rules.sh always` at session start over reading STANDARDS.md in full. The loader emits the always-load carve-out subset (privacy / voice / destructive-op / MCP-Tool-Schema-Loading), not the full canon (size: `| wc -c`). Per-stage subsets (`load-stage-rules.sh <N>`) load when entering Stage N. AC 4.9 invariant: `grep -F 'load-stage-rules.sh always' .claude/commands/SST3-solo.md` returns ≥1. Non-zero exit = STOP; do not proceed on partial canon.

Default per-session reading set:
1. `bash $SST3/load-stage-rules.sh always` — always-load canonical subset. Non-zero exit = STOP; do not proceed on partial canon.
2. Current repository's `CLAUDE.md` (entire file).
3. `../workflow/WORKFLOW.md` (entire file — defines the 5-stage workflow).

Fallback (when the loader is unavailable on this clone):
1. `../standards/STANDARDS.md` (entire file)
2. Current repository's `CLAUDE.md` (entire file)
3. `../workflow/WORKFLOW.md` (entire file — defines the 5-stage workflow)

## Governance Enforcement — Checkbox MCP (AP #20)

At every Acceptance Criteria checkbox completion → invoke:

```python
mcp__github-checkbox__update_issue_checkbox(
    issue_number=<N>,
    checkbox_text="<exact text without [ ] prefix>",
    evidence="<concise proof: what you did + key results>"
)
```

Comment-only progress tracking is NOT a substitute — it leaves the issue body (the permanent contract) empty of per-criterion evidence. See **AP #20** in `../standards/ANTI-PATTERNS.md`.

**Deferred-tool loading is mandatory, not conditional**: check the deferred-tool list at session start; if `mcp__github-checkbox__*` tools appear there, load their schemas via `ToolSearch(select:mcp__github-checkbox__update_issue_checkbox,mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__health_check,mcp__github-checkbox__get_issue_events,mcp__github-checkbox__list_issue_comments,mcp__github-checkbox__update_issue_comment)` BEFORE any governance work. Full rule (including generic pattern for any deferred MCP tool): STANDARDS.md "MCP Tool Schema Loading".

**Evidence-quality patterns**: canonical table in `../reference/tool-selection-guide.md` Example 2.

## Per-Session Initialization

On each SST3-solo invocation, run this block ONCE (not per subagent dispatch).

**Per-Stage Feedback Capture (canonical: STANDARDS.md §Per-Stage Feedback Capture)**: at session start, if a feedback file exists for the in-flight Issue (per the `solo/issue-N-*` branch), the agent reads any prior `## Stage <N>` blocks to recover stage-level context after compact. Reconstruction-marker convention applies for stages where observations cannot be recovered.

**MANDATORY wrapper-lane self-test + status CHECK** — runs unconditionally. The wrapper-lane is MCP-independent.

Run `sst3-self-test.sh` **FIRST**, then the status CHECK. The wrapper-lane is stateless; there is no staleness or build step. "MANDATORY" refers to the CHECK being unconditionally attempted, NOT to halting the workflow when the tool is unavailable — fallback is documented and Ralph-acceptable. This mirrors the unconditional self-test/status leg in `WORKFLOW.md` Stage 1 and `Leader.md` (the #484 W6.2 three-way consistency contract).

0. **Self-test first**: run `bash $SST3/sst3-self-test.sh`. On ANY `{"kind":"fixture-drift",...}` NDJSON line, log `[WRAPPER-LANE self-test drift: <fixture-list>]` and HALT — open `solo/wrapper-fix-<bug>` (NOT this session's branch), reproduce + fix, push it through its own Stage 4, then resume. Engine-missing (exit 127) degrades THIS session to subagent-only fallback, same as wrapper-lane unavailable below.
1. Run `bash $SST3/sst3-code-status.sh`. If the call exits non-zero, log `[WRAPPER-LANE] status check failed: <stderr>; retrying once.` and retry once. If second attempt fails, log `[WRAPPER-LANE unavailable: wrapper call failed after retry]` and continue — downstream will fall back to subagent with documented evidence. Common failure: exit 127 — FIRST rule out an unresolved `$SST3` (see the SST3 script path rule at the top; that 127 is a path failure and the installer below will not fix it), THEN treat it as an inner engine like ast-grep genuinely missing on disk ( PATH propagation to non-interactive shells is handled by `sst3-bash-utils.sh` self-bootstrap). Run `<your-dotfiles-clone>/scripts/install.sh` to install missing engines — do NOT add custom PATH workarounds in the calling agent.
2. No build step + no staleness check — the wrapper-lane is stateless; every query re-parses on disk (`last_updated` = repo HEAD commit time, not a query-cache freshness indicator).
3. **End-to-end smoke** (G-4 fix, #444): after status check succeeds, run a tiny `bash $SST3/sst3-code-search.sh '<symbol>' <lang>` against a known-good symbol from the active repo to confirm the round-trip works. Symbol-selection: see canonical shell snippet at `../docs/guides/code-query-playbook.md` "Stage-Mapped Recipes — Stage 1 — symbol-extraction snippet". If the smoke fails with non-zero exit, log `[WRAPPER-LANE smoke test failed: <stderr>]`, fall back to subagent for THIS session.

Cadence: this check runs ONCE per SST3-solo invocation, not per subagent dispatch. The wrapper-lane is request-scoped; there is no daemon to keep fresh. See `../docs/guides/code-query-playbook.md` for operational notes.

**github-checkbox availability check** — only if `github-checkbox` is registered in `~/.claude.json`.

Registration detection (explicit): run
`grep -q '"github-checkbox"' ~/.claude.json && echo registered || echo unregistered`
- If `unregistered`: log `[CHECKBOX] Server not registered; skipping availability check. Governance work MAY proceed without MCP invocation only if the skill being invoked does NOT contain AP #20 directives; otherwise STOP.` and continue.
- If `registered`: proceed with the checkbox check below.

Checkbox availability check (registered case):
1. Load schema: `ToolSearch(query="select:mcp__github-checkbox__health_check,mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__update_issue_checkbox,mcp__github-checkbox__get_issue_events,mcp__github-checkbox__list_issue_comments,mcp__github-checkbox__update_issue_comment")` — mandatory pre-bootstrap per `../standards/STANDARDS.md` "MCP Tool Schema Loading".
2. Call `mcp__github-checkbox__health_check`. On error, log `[CHECKBOX] health_check failed: <error>; retrying once.` and retry once. If second attempt fails, log `[CHECKBOX unavailable: ...]` and **HARD STOP** — do not proceed with governance-sensitive work under any circumstances. This is fail-fast by design (AP #20 + STANDARDS.md "MCP Tool Schema Loading"). Layer 1 (phase-boundary close-out in "During Work") + Layer 2 (Pre-Verification-Loop baseline in "Verification Loop") both REQUIRE this bootstrap to have succeeded — if the bootstrap STOPs, those layers MUST NOT run. There is no "proceed with warning" path. (Cadence: once per SST3-solo invocation, same as the wrapper-lane check.)

This is the structural-query layer (graph) + governance-signal layer (github-checkbox); the subagent swarm remains your semantic layer. Rule detail for the wrapper-lane structural-query layer lives in STANDARDS.md "Structural Code Queries"; rule detail for checkbox-MCP bootstrap lives in STANDARDS.md "MCP Tool Schema Loading" + "Governance Evidence Signal (Canonical)".

## Solo Mode Summary

**Context**: read the injected `SST3 CONTEXT GAUGE` line; `/clear` between unrelated tasks
**Content Budget**: per-stage loading (#498) — session start loads CLAUDE.md + the `load-stage-rules.sh always` subset + the Issue; each stage adds its `load-stage-rules.sh <N>` subset on entry
**Handover at**: ~50% remaining (~500K of 1M / ~100K of 200K) — on long work, auto-`/handover` + compact + continue; never below 50% remaining

## 5-Stage Sequential Workflow

**ORDER-DEPENDENT** — do not reorder, skip, or skim.

**Subagents** = research/explore/audit/verify/review (NEVER code)
**Main agent** = collate, write /tmp, create issues, implement, commit, merge

### Stage 1 — Research (Subagent Swarm → /tmp)

**Stage 1 mandatory-reading directive**: run `bash $SST3/load-stage-rules.sh 1` at Stage-1 entry (research / subagent-swarm / pre-swarm SEED rules). Parity with `Leader.md` Stage 1. Non-zero exit = STOP; do not proceed on partial canon. <!-- c4:T46 --> Before the load, fetch and fast-forward the canon clone when clean on its default branch; otherwise report its branch and behind-count first. In a worktree session, file state read from the shared clone before `EnterWorktree` is re-derived at the point of use.

- Author + run the research swarm via the Workflow tool (DEFAULT; 5 files max per subtask); Agent/Task = the documented fallback only for a trivial single-angle check
- Main context = orchestrator only — NEVER read source files directly
- Research phase <30% of context budget
- Main agent collates findings → writes /tmp file: **findings + gaps + plan**
- Check `docs/research/` for existing research first
- **Leader.md parity** (solo loads WORKFLOW.md, NOT Leader.md — so also apply these Leader.md Stage-1 steps): handover-claim verification gate — step 1a.5's 3 verification classes (closure-rationale / pre-existing-classification / fix-ranking) + run any mechanically-testable hypothesis before scope [AC 1.7]; for any non-code / operator-side / "false-positive-on-contract" framing, dispatch a live-system probe + capture a host-baseline file fed to every subagent [AC 1.9]; empty-SEED → raw-grep fallback + `pre_swarm_graph_seed` frontmatter when the wrapper returns near-empty for a symbol known to exist [AC 1.11]

### Stage 2 — Issue Creation (Main Agent from /tmp)

**Stage 2 mandatory-reading directive**: run `bash $SST3/load-stage-rules.sh 2` at Stage-2 entry. This is what loads the `standards/stage-2/*.md` cluster — the pre-dispatch author self-check catalogue (a)–(k) and the L1/L2 prompt-angle catalogue. Without it those checks are unreachable in solo mode. Parity with `Leader.md` Stage 2. Non-zero exit = STOP; do not proceed on partial canon.

- Create issue using `issue-template.md` from /tmp research
- Add ALL before/after illustrations, phase checkpoints between phases <!-- c4:T43 --> (a visual or computed-definition deliverable is rendered from live data for the operator before Stage 2 closes)
- Author + run the draft-check swarm via the Workflow tool (DEFAULT) for scope-check vs audit; Agent/Task = the documented fallback only for a trivial single-angle check
- Quality mantras VERBATIM: no inefficiencies, fix optimisations, reliable/robust, dedupe, no bottlenecks, fast/safe, no memory leaks, follows STANDARDS.md
- No false positives. No priority levels. All must be fixed.
- **Leader.md parity** (also apply these Leader.md Stage-2 author/draft steps): author self-check block — run the full pre-dispatch catalogue in `standards/stage-2/pre-dispatch-self-checks.md` (loaded by the Stage-2 loader call above), sub-checks (a)–(k), zero unresolved items before any subagent dispatch [AC 2.1]; two-angle verifiability sweep — falsifiability (passes the FAIL state too = toothless) + discriminability (no bare-substring where exact-match exists) + script/gate preconditions [AC 2.2]; finding-to-AC traceability table — every Fn AND Gn → an AC or explicit out-of-scope, bound at sub-element not headline level [AC 2.3]; expanded L1/L2 prompts — implementation-correctness axis, carve-out respect, backwards-compat source-read, shape-gated angles [AC 2.4]; author-time citation freshness — grep-verify every file:line before writing it + stale-count cleanup [AC 3.4]; scope decomposition — sub-issue merge/drop tracing, multi-axis split, JBGE-DEFERRED knob gate [AC 3.11]; voice-mirror vendor prerequisite pre-check for voice-scanner consumers [AC 3.16]

### Stage 3 — Triple-Check (Subagents Verify Scope)

**Stage 3 mandatory-reading directive**: run `bash $SST3/load-stage-rules.sh 3` at Stage-3 entry (skill-canonical compliance / scope-vs-audit / raw-tool counter-query rules). Parity with `Leader.md` Stage 3. Non-zero exit = STOP; do not proceed on partial canon.

- Scope vs audit = 100% captured, no gaps, no overengineering
- **Chat Reconciliation (Verifier-Led, MAIN-AGENT-owned, non-delegable)** — the chat-history / opposite-scoping check is NOT a subagent self-cert (subagents never receive the conversation). Dispatch the 3-model neutral panel (Haiku+Sonnet+Opus, shown ONLY the operator's raw messages from `extract-chat-agreements.py`), flag invented/dropped/inverted vs the draft, POST `## Chat Reconciliation`, PAUSE for operator sign-off before issue creation (Leader.md step 2a / AC 7.1; STANDARDS.md "Chat Reconciliation (Verifier-Led)"; #522)
- Check for dead/obsolete/legacy code cleanup
- All scope in issue BODY — never comments
- **Leader.md parity** (also apply these Leader.md Stage-3 sanity angles): draft internal-consistency — Expected-Behavior ↔ AC binding + deferred-feature coherence [AC 3.3]; subagent BLOCK/FAIL findings get main-agent source-verify before acting + a rejected-finding-revisit angle [AC 3.6]; cross-stage contradiction resolution — source decides over recency-bias, and Stage-2 parked feedback is fed to the Stage-3 subagents [AC 3.13]

### Stage 4 — Implementation + Merge + User Review

**Stage 4 mandatory-reading directive**: run `bash $SST3/load-stage-rules.sh 4` at Stage-4 entry — emits the Stage-4-tagged canon PLUS every `stage-4/*.md` extract file (verification-loop, ralph-review, the gate files, three-tier-testing, and the rest — the loader's glob is the authority on the set, deliberately not restated as a count here because a hardcoded count drifts as files are added). Parity with `Leader.md` Stage 4; the "Before Starting Work" checklist item below is the same invocation. Non-zero exit = STOP; do not proceed on partial canon.

- Implement all phases, commit per file
- **When-needed (NOT every run)**: for goal / discovery / analysis / iterate-until-met work, invoke `/goal-loop` (wraps native `/goal`, loops until every acceptance gate passes or an honest NO-GO is recorded)
- Verification Loop (repeat until clean)
- **Pre-Ralph vacuity sweep (parity with Leader.md step 6.5(0))**: run `bash $SST3/sst3-test-vacuity.sh` over the diff's test files (plus `--count-in <doc>` for any allowlist-shaped dict the diff touches) and FIX every finding BEFORE dispatching any Ralph tier — exit 1 blocks Tier-1 dispatch.
- **Pre-Ralph citation sweeper (parity with Leader.md step 6.5(0a))** <!-- c4:T37 -->: run `python3 $SST3/check-sst3-citations.py --sweep-body <issue-body.md> --repo-root <repo>` over the Issue body, PoW lines included, and fix every flagged citation before Ralph Tier 1; exit 1 blocks dispatch.
- Ralph Review: Haiku → Sonnet → Opus (all 3 mandatory, dispatched with subagent_type=ralph-review), up to 3 restarts. Restart 4: NOT taken — escalate to a class-sweep (deterministic enumeration preferred where the class is mechanically enumerable), then resume Ralph with the count reset to zero for exactly ONE further loop; if that loop does not PASS, STOP and report the outstanding findings + classes to the operator (terminal state — canonical: `standards/stage-4/ralph-review.md`, #567). Signal the counter at both boundaries — `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --restart` on each restart, `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --escalate` on each escalation (the only reset within a stage; at Stage-5 entry `--stage5` opens Stage 5's own loop). The counter cannot infer either from the event stream, so unsignalled the count stays 0 — not merely low — and the bound is never seen to be reached.
- Merge to main BEFORE user review (Solo Branch Merge Safety: pull, diff, preserve both)
- POST user-review-checklist.md from TEMPLATE (ALL sections mandatory)
- POST a mandatory closing-summary comment before close (dotfiles#528 AC 3.7): carry the sentinel `<!-- sst3-closing-summary -->` on a line of its own + outcome + commit SHAs + completeness JSON + Ralph verdicts; then re-run `bash $SST3/leader-stage5-completeness-check.sh <N> --expect-closing-comment` (C18 fail-closed → PASS). Use `gh issue comment`, never `--body-file` (clobbers checkbox state, AC 5.5).
- Fix gaps — no deferrals, no excuses unless confirmed false positive
- **Leader.md parity** (also apply this Leader.md Stage-4 step): worktree setup + pre-commit formatter staging hygiene — when a formatter hook (end-of-file-fixer / trailing-whitespace) modifies a file mid-commit, re-stage by exact pathspec and re-commit; never `| tail -N` between hook output and exit-code propagation under `set -e` [AC 4.2]

### Stage 5 — Post-Implementation Review (Subagent Swarm)

**Stage 5 mandatory-reading directive**: run `bash $SST3/load-stage-rules.sh 5` at Stage-5 entry (adversarial-audit / completeness-gate / regression / wrapper-vs-raw delta / §3-deferral re-litigation rules). Parity with `Leader.md` Stage 5. Non-zero exit = STOP; do not proceed on partial canon.

- Author + run the post-implementation audit swarm via the Workflow tool (DEFAULT); Agent/Task = the documented fallback only for a trivial single-angle check
- Phase-by-phase review against issue body scope, goal alignment, design doc
- Wiring check: everything connected to existing functions?
- Inefficiencies, dead code, optimisations, dedupe, bottlenecks, memory leaks
- STANDARDS.md compliance. Issue body 100% complete.
- Fix ALL problems. Run regression tests.
- Before any Stage-5 fix or Ralph dispatch, signal Stage-5 entry once: `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --stage5` (Stage 5's Ralph loop is its own; parity with Leader.md Stage 5)
- **Leader.md parity** (also apply this Leader.md Stage-5 step): scope-snippet source verification — a step-0 HEAD re-derive checklist (re-grep the scope snippet against current `HEAD` before auditing) + a truth-table temporal axis so post-merge state is not audited against a pre-merge snapshot [AC 5.5]

## Task Description

Describe the task you need to complete:

[User will provide task description here]

## Execution Guardrails (Built-in)

### Before Starting Work
- [ ] Read CLAUDE.md in full
- [ ] Load the STANDARDS canon via `bash $SST3/load-stage-rules.sh 4` (Stage-4 subset + always carve-out) — the #498 per-stage loader, preferred over a full STANDARDS.md read (see file top). Non-zero exit = STOP; do not proceed on partial canon
- [ ] Read Issue line-by-line (not skim)
- [ ] Enter an isolated worktree per the CLAUDE.md "Branch Safety (CRITICAL — DO NOT VIOLATE)" anchor (dotfiles#488 Fix-A): call the `EnterWorktree` tool named `solo/issue-{number}-{description}` — do NOT bare `git checkout -b solo/...` in the shared clone (a clone has one HEAD/index; a concurrent agent's branch-create moves yours). The CLAUDE.md anchor is authoritative (the tool only activates from a user/CLAUDE.md/memory directive); this line REFERENCES it.
- [ ] **HARD STOP**: NEVER switch branches mid-implementation — this remains the in-worktree invariant (commit + push to the worktree's solo branch only; Gate-2 uses the AC 1.3 remote-FF procedure, never a shared-tree branch-switch).

### During Work (At Each Phase Checkpoint)
- [ ] Post checkpoint to Issue comment
- [ ] **Close Tier A checkboxes via MCP** (AP #20 Layer 1 — MANDATORY in execute mode only, before moving to next phase): for every completed Tier A Acceptance Criteria in the just-finished phase, invoke `mcp__github-checkbox__update_issue_checkbox(issue_number, checkbox_text, evidence)` with canonical evidence (file:line / commit hash / command+output / subagent RESULT comment-id per `../reference/tool-selection-guide.md` Example 2). ToolSearch-bootstrap if deferred: `ToolSearch(query="select:mcp__github-checkbox__update_issue_checkbox,mcp__github-checkbox__get_issue_checkboxes")`. No phase boundary may be crossed with a Tier A `[ ]` box behind. See `../claude/commands/Leader.md` Stage 4 step 3a for the full rule.
- [ ] Check context memory: on long/multi-phase work, when remaining nears ~50% (~500K of 1M) auto-run `/handover` + compact + continue; never operate below 50% remaining.
- [ ] Commit after EACH file change — NEVER use `git add -A`

### After Compact (Context Recovery)
- [ ] Re-read CLAUDE.md
- [ ] Re-read STANDARDS.md
- [ ] Re-read Issue (or last checkpoint comment)
- [ ] Continue from last checkpoint

## Verification Loop (MANDATORY)

> Canonical: ../workflow/WORKFLOW.md "## Verification Loop" — run that loop here. The SST3-solo-specific gates below extend it; the generic checks (Overengineering / Architecture reuse / Code duplication / Fallback policy) live in the canonical and MUST NOT be restated here (Cut #3, AC 1.6).

**Layer 2 — Pre-Verification-Loop baseline (MANDATORY)**: if the tool is deferred, `ToolSearch(query="select:mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__update_issue_checkbox")` first. Then run `mcp__github-checkbox__get_issue_checkboxes` and confirm every Tier A phase-complete box is `[x]` with canonical evidence (file:line / commit / command / subagent RESULT per `../reference/tool-selection-guide.md` Example 2). Close any lingering `[ ]` box NOW via `update_issue_checkbox` with canonical evidence — do NOT defer to the loop below. The loop enters from a clean baseline. (Complements Layer 1 at phase-boundary; the expanded bullet below is Layer 3 final-check.)

- [ ] **Layer 3 — All Tier A checkboxes closed via MCP with canonical evidence**: (1) `ToolSearch(query="select:mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__update_issue_checkbox")` if deferred; (2) run `mcp__github-checkbox__get_issue_checkboxes`; (3) for each Tier A `[ ]`-but-done box, invoke `update_issue_checkbox(issue_number, exact_checkbox_text, evidence)` with canonical evidence (file:line / commit / command / subagent RESULT comment-id per `../reference/tool-selection-guide.md` Example 2); (4) re-run `get_issue_checkboxes`, confirm all Tier A `[x]`. Tier B batched-closures applied here are acceptable per AP #20 Phase 9 cadence. (`../workflow/WORKFLOW.md` is canonical — Verification Loop rule lives there; procedure expanded here per skill-execution requirement, not duplicated.)
- [ ] **Per-stage feedback gate** (canonical: STANDARDS.md §Per-Stage Feedback Capture): every `/Leader` stage executed within this session has its `## Stage <N>` block written to the per-issue feedback file with all 10 fields populated (or with documented `[reconstructed-post-compact: ...]` markers + `reconstructed_stages: [N]` frontmatter). Pre-commit hook `sst3-metrics-feedback-present` is the enforcing layer — if the hook fires loud during commit, the file is incomplete; fix and re-stage.
- [ ] **Wiring check**: All changed code actually called by existing functions/processes? Structural layer: `bash $SST3/sst3-code-callers.sh <function> <lang>` + `bash $SST3/sst3-code-impact.sh <base-branch>` when graph available (per STANDARDS.md "Structural Code Queries" pre-query gate). Semantic layer: subagent verifies each caller handles the new contract. YAML / shell / unsupported-language keys still grep-based. Wrapper-based claims must also pass the WORKFLOW.md Raw-tool cross-validation gate.
- [ ] **Three-Tier test gate (Unit / Workflow / E2E)** — per WORKFLOW.md "Verification Loop" canonical tier checkboxes (#484 T4.4): BUILD = all 3 tiers' tests exist; USE = all 3 RUN (fire & pass) every change (dotfiles#528; supersedes scope-matched fire). E2E may be sized to a small backtest / execution+cleanup but still RUNS; the only non-run is a documented `structural-inapplicable: <reason>`. Record the tier-evidence line `tiers: U=.. W=.. E2E=.. M=.. | BUILD-evidence:<file:line per tier>` (defined once in STANDARDS.md; `M=` is the #567 mutation-verification result — `M=unproven` blocks like a fail). The project test suite ("no regressions") = the union of the checked-in Unit + Workflow + E2E tests, not any single tier (STANDARDS.md glossary). WORKFLOW.md is canonical — do NOT re-define here.
- [ ] **Quality scan**: No inefficiencies, no bottlenecks, no memory leaks, no dead code, STANDARDS.md compliant
- [ ] **AP #18 sample-invocation = the Workflow Tier of the Three-Tier test gate above** (#484 T4.4): scope triggers (pipeline / backtest / SL1 / SL2 / orchestration / CLI-wiring / cross-module function-arg propagation / persistent-state write / any `../scripts/sst3-*.sh` wrapper change), real-CLI ≥3-repo-shape invocation + raw-tool counter-query, and the skip-rule are the Workflow-Tier USE clause. Canonical spec: WORKFLOW.md "Verification Loop" Workflow Tier checkbox + ANTI-PATTERNS.md AP #18 + STANDARDS.md "Three-Tier Testing Framework". Do NOT duplicate here.

## Quality Standards

- Quality First (proper execution over speed)
- JBGE (only problem-preventing content)
- LMCE (lean, mean, clean, effective)
- Fail Fast (error loudly, no silent fallbacks)
- Fix Everything (no deferrals, no scope excuses, no language boundaries)
- Investigate Before Coding (understand → plan → align → then code)
- Not Done Until Working (half-working = not done)
