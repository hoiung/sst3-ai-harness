<!-- stages: 4 -->
# Ralph Review — Stage-4 Canonical

Three-tier code-delivery verification: Haiku surface → Sonnet logic → Opus deep. Sequential (not parallel). One round: each tier reviews the whole diff ONCE.

The bar: simple code that works reliably for the inputs that really arrive. Not coverage of every conceivable case.

<!-- stages: 4 -->
## Tier sequence

| Tier | Model | Lens | Canonical checklist |
|------|-------|------|---------------------|
| 1    | `haiku`  | Surface — convention adherence, formatting, no-debug-leftovers | `../../ralph/haiku-review.md` |
| 2    | `sonnet` | Logic — control flow, contract adherence, test seam | `../../ralph/sonnet-review.md` |
| 3    | `opus`   | Deep — architecture, cross-cutting, governance drift, wrapper-vs-raw counter-query | `../../ralph/opus-review.md` |

Dispatch every tier in the FOREGROUND: `Agent(subagent_type="ralph-review", model=<tier>, run_in_background: false, prompt=…)`. Subagents run in the background by default, and a background dispatch returns at launch with no result. The tier sequence needs each verdict before the next tier starts, and the PostToolUse `Agent` hook that hands the parent its `ralph_restarts` count only has a result to act on for a foreground dispatch.

<!-- stages: 4 -->
## Shared blocks (#498 Cut #10)

The three checklists `_*.md` shared blocks live in `../../ralph/`:
- `_wrapper-lane-preconditions.md` — wrapper-lane invocability + AP #19 `mcp_graph_available` rule.
- `_bash-output-discipline.md` — `tee-run.sh` wrap checkbox (#406 F4.9).
- `_doc-only-exemption.md` — doc-only PR exemption + #484 W6.3 doc-lane / sync-lane diff-trigger exceptions.
- `_fallback-clause.md` — retry-aware, evidence-required fallback clause.

<!-- stages: 4 -->
## The three kinds of finding

Every finding is exactly one kind. The reviewer proposes the kind; the main agent decides it, read fresh from this file, and writes one line of reason.

| Kind | Test | Outcome |
|------|------|---------|
| PRODUCTION FAULT | Shipped code gives a wrong result for an input a real user or system can send. The finding names the input and the wrong result. A visible cut, overlap or wrong sum on a shipped page is one: its input is the page and viewport (dotfiles#583). | A fix cycle (below). |
| GAP | Anything that does not change what a real input gets: a missing, weak or vacuous test of behaviour real inputs reach, a surviving mutant, doc drift, a checkbox or record gap, dead or duplicate code, a hardcoded value, a missing log line, a rendered page's missing or unread pictures at each declared viewport (STANDARDS.md "Three-Tier Testing Framework" Run procedure step 3; `claude/hooks/sst3-page-review.sh`). A missing test for a RARE EDGE CASE is not a GAP: no test is built for it. | The main agent fixes it in place. The round continues. Nothing is re-reviewed. |
| RARE EDGE CASE | Needs a chain of unlikely events, or an input no shipped path sends. | Recorded, not fixed: one line in the user-review-checklist §3 as `[edge-case: <why rare>]`. |

- Only a PRODUCTION FAULT starts a fix cycle. A finding with no named input and wrong result is not a PRODUCTION FAULT.
- A RARE EDGE CASE whose consequence is money loss, data loss or a security hole is a PRODUCTION FAULT.
- A GAP fix must not change what a real input gets; the test suite confirms it. A repaired or new test that fails on shipped code is a PRODUCTION FAULT.
- A PRODUCTION FAULT outside the diff (pre-existing) is fixed in this Issue as a fix cycle. A "pre-existing" or "unchanged" claim needs an executed before/after run at both tips (base and branch), output pasted.
- <!-- c4:T65 --> A finding against a test-policing guard (a test whose subject is another test, not production code) is a GAP.
- A finding about code the agent added in-loop that no AC asks for is recorded, not fixed in-loop.
- A reviewer that skipped a required check (wrapper lane, run sentinel, counter-query) is re-dispatched. That is not a finding about the diff.
- A finding that a limit is missing on coverage (pages, items, areas or results read) or on flat-rate Claude subscription usage is rejected, with STANDARDS.md "Caps and limits" as the reason. A limit the diff keeps with no reason written beside it is a GAP.

<!-- stages: 4 -->
## Fix cycle

At most 2 fix cycles. The limit counts fix cycles, not faults.

On a PRODUCTION FAULT:

1. The main agent fixes every production fault in that tier's report, with one test that fails when the fix is reverted. Findings that share a root cause are fixed at the shared cause, by the widest correct generalisation the evidence supports, not symptom by symptom. <!-- c4:T06 --> The defect-class breaker: a second production fault of the same shape is fixed one level up (change the mechanism), never as another instance. <!-- c4:T70 --> A fix that adds a lock is deadlock-probed, before commit, against the implicit locks of every transaction it can meet. An accepted review suggestion is re-run against the defect it neighbours before it ships.
2. Run the test suite until green: the tests that cover the files the fix touches, not every test in the repo (`../../standards/STANDARDS.md` "Which tests get built, and which get run"). Failures here belong to this cycle.
3. Signal `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --restart`, then dispatch ONE Sonnet reviewer on the fix diff only (`../../ralph/sonnet-review.md` "Fix check").
4. Fix check PASS: the sequence resumes at the tier AFTER the one that found the fault, and that tier reviews the whole diff as in round 1. After an Opus fault, a passing fix check is Ralph PASS.
5. A production fault found by the fix check starts the next fix cycle.

A production fault found by Gate 1 after Ralph PASS is a fix cycle against the same limit. Other Gate-1 failures are GAPs fixed in place.

<!-- stages: 4 -->
## Escalation: one Fable fix

A third production fault is NOT a third fix cycle. Signal `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --escalate`, then dispatch ONE fix agent in the FOREGROUND, in the Issue's worktree: `Agent(subagent_type="ralph-fixer", run_in_background: false, prompt=…)` (`.claude/agents/ralph-fixer.md` sets model `fable`, effort `high`). Give it the Issue, the whole diff, and every earlier finding and fix. A session that started before the agent file was installed does not have the `ralph-fixer` type (agent types load at session start): there, dispatch `Agent(subagent_type="general-purpose", model="fable", effort="high")` and tell it to read `~/.claude/agents/ralph-fixer.md` first and follow it, and to end its reply with the reviewer `## RESULT` block as well (the result parser holds a `general-purpose` agent to that block and sends it back once without it).

- It finds the root cause, WRITES the fix and its test, and runs the tests. It is the only subagent in SST3 that writes code.
- The main agent does not edit while it runs. Afterwards the main agent reads its diff, runs the test suite and commits per file.
- Then ONE Sonnet fix check of that diff.
- PASS: the remaining tiers run. Any further production fault is STOP.
- FAIL, or the fix agent cannot be dispatched: STOP.

**STOP is a report to the operator, never a silent abandon**: every outstanding finding with its kind, what was tried, and the question ship or fix. No class sweep, no second escalation, no further cycle.

<!-- stages: 4 -->
## Proof of a fix

Default: one test that fails when the fix is reverted. Run it both ways and paste both results.

Mutation tables and class ledgers (`mutation-verification.md`, `../../templates/class-ledger-template.md`) are opt-in: only for a guard protecting money, data loss, security or a customer-facing figure, or when the operator asks. Money = code that moves real money or places live orders; exploration, paper and lab code is not. Where a ledger exists, every tier RUNS its enumerators instead of re-deriving the class.

<!-- stages: 4 -->
## On PASS (all 3)

Proceed to Verification Loop (Gate 1). Ralph PASS verifies code DELIVERY against the Issue's Acceptance Criteria; it does NOT substitute for Stage 5 adversarial audit (TB-3 N36 — different lens, different class of findings).

<!-- stages: 4 -->
## Stage 5, rework, in-flight Issues

- **Stage 5**: at the start of each Stage-5 round, inside the Stage-5 fix worktree (a `solo/issue-N-*` branch), signal `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --stage5`. It opens a fresh limit of 2. A round is one audit pass and the fixes for its findings; after a STOP, no new round opens without the operator's word. Stage-5 audit findings use the same three kinds: production faults get fix cycles, GAPs are fixed in place, rare edge cases are recorded.
- **Rework after a PASS**: an operator-requested change gets one fix check (test suite plus one Sonnet pass on the change diff). It does not use the limit.
- **In-flight Issues**: an Issue mid-loop under the earlier rule switches at its next fix. Its count carries over; at 2 or more, the next production fault goes to the fix agent.

<!-- stages: 4 -->
## Tier 3 wrapper-vs-raw counter-query

When any Tier-3 finding depends on `sst3-code-*.sh` output, Opus dispatches ≥1 raw-tool counter-query subagent on the same target before signing PASS and records the recall delta + reconciliation in its review comment. A skipped counter-query means Opus is re-dispatched.

<!-- stages: 4 -->
## Counter

`claude/hooks/sst3-ralph-restart-counter.sh` OBSERVES; the main agent ENFORCES. No hook can redirect a dispatch. The counter cannot see a fix cycle or an escalation for itself (every tier dispatches under one agent type), so unsignalled the count stays 0.

- `--restart` at each fix cycle. Bound: `SST3_RALPH_RESTART_BOUND`, default 2.
- `--escalate` when the fix agent is dispatched. It is terminal: a `--restart` after it is a breach, reported as such.
- `--stage5` at the start of each Stage-5 round.
- `--get` for the checkpoint line `ralph_restarts: N` (N = fix cycles; the field name is parsed by scripts and stays).

<!-- stages: 4 -->
## Where this rule is restated (sweep them together, AP #24)

`.claude/commands/Leader.md`, `.claude/commands/SST3-solo.md`, `CLAUDE.md` + `../../templates/CLAUDE_TEMPLATE.md` (and every consumer `CLAUDE.md`), `../../workflow/WORKFLOW.md`, `ralph/README.md` + the three tier checklists, `.claude/agents/ralph-review.md` + `.claude/agents/ralph-fixer.md`, `../../templates/{issue-template,chat-handover,leader-feedback-template,user-review-checklist}.md`, `../../standards/stage-4/per-stage-feedback-capture.md`, `../../standards/stage-5/post-implementation-review-procedure.md`, the messages in `claude/hooks/sst3-subagent-result-parser.sh` and `claude/hooks/sst3-ralph-restart-counter.sh`, the plugin copies (`.claude/plugin-staging/ralph-review-trio/`, `.claude/skills/design-fidelity/.claude-plugin/`) and the hand-pinned mirror copies named in `SST3/drift-manifest.json`. Changing the bound constant alone changes nothing an agent reads.

<!-- stages: 4 -->
## Cross-references

- `.claude/commands/Leader.md` Stage 4 step 7 — the operator-facing Ralph trigger.
- `../../ralph/{haiku,sonnet,opus}-review.md` — per-tier canonical checklists.
- `../docs/research/model-selection-haiku-4-5.md` — model-selection rationale.
