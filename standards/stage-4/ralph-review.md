<!-- stages: 4 -->
# Ralph Review — Stage-4 Canonical

Three-tier code-delivery verification: Haiku surface → Sonnet logic → Opus deep. Sequential (not parallel).

<!-- stages: 4 -->
## Tier sequence

| Tier | Model | Lens | Canonical checklist |
|------|-------|------|---------------------|
| 1    | `haiku`  | Surface — convention adherence, formatting, no-debug-leftovers | `../../ralph/haiku-review.md` |
| 2    | `sonnet` | Logic — control flow, edge cases, contract adherence, test seam | `../../ralph/sonnet-review.md` |
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
## On FAIL

Fix → restart from Tier 1 (NOT continue from failed tier). Restarts are bounded: after 3, escalate, then ONE further loop, then stop and report (below, "After the escalation"). **Round scoping (#567 — replaces the full re-review)**: cascade risk (a Sonnet fix re-breaking a Haiku check) is confirmed by **re-running the test suite** — mechanical, deterministic, seconds — NOT by re-dispatching LLM reviewers over the entire diff. The REVIEWERS in round N+1 are scoped to (a) commits since the previous round and (b) the class ledger's gates (run each enumerator; count drift = FAIL). Full re-review of the whole diff happens ONLY at escalation. Rationale, measured (`Issue #3`; figures sourced from the dotfiles#567 issue body, "Measured evidence" block — 87,296 + 82,222 + 143,972 + 208,901): under the unscoped rule round 9 still ran a full multi-dispatch re-review — 522,391 subagent tokens across four dispatches, ~174k per review-phase commit — while the cascade class it defended against is exactly what the suite catches for free.

<!-- stages: 4 -->
## On PASS (all 3)

Proceed to Verification Loop (Gate 1). Ralph PASS verifies code DELIVERY against the Issue's Acceptance Criteria; it does NOT substitute for Stage 5 adversarial audit (TB-3 N36 — different lens, different class of findings).

<!-- stages: 4 -->
## Tier 3 wrapper-vs-raw counter-query

When any Tier-3 finding depends on `sst3-code-*.sh` output, Opus MUST dispatch ≥1 raw-tool counter-query subagent on the same target before signing PASS and record the recall delta + reconciliation in its review comment; skipping it = Tier-3 FAIL.

<!-- stages: 4 -->
## Cross-references

- `.claude/commands/Leader.md` Stage 4 step 7 — the operator-facing Ralph trigger.
- `../../ralph/{haiku,sonnet,opus}-review.md` — per-tier canonical checklists.
- `../docs/research/model-selection-haiku-4-5.md` — model-selection rationale.

<!-- stages: 4 -->
## Restart bound, escalation, and terminal state (#567 — operator directive replaces the unbounded cycle)

A Ralph ROUND is one dispatch of the tier sequence starting at Tier 1. A RESTART is a return to Tier 1 after a FAIL, so round N+1 begins with restart N.
The bound counts RESTARTS, not rounds — that definition is UNCHANGED by #567 (only the bound's value and what follows it changed; the counter still measures the same thing).

**Restarts 1 to 3**: on a tier FAIL that qualifies (see below), fix and restart from Tier 1.
At the moment you restart, signal the counter: `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --restart`. This is REQUIRED, not optional bookkeeping. The SubagentStop event stream cannot see a restart at all — every tier dispatches under the same agent type, so a restart and an ordinary tier event are indistinguishable in it. The counter therefore derives NOTHING from event volume: unsignalled, the count stays 0 no matter how many events arrive, and the bound is never observed to be reached. (This paragraph previously said the stream "under-reports by up to 5x", which described an event-inference model that was removed — there is no partial credit, only 0.)

At fix time, on every restart: if a finding shares a root mechanism with an earlier finding in this issue, sweep the whole class before fixing.
Fix by the widest correct generalisation the evidence supports, not by the observed symptom. Guard-by-symptom fixing is what serialises one class member per restart. An accepted review suggestion is re-run against the defect it neighbours before it ships: a reviewer's alternative fix is a new change, not a verified one. <!-- c4:T70 --> A fix that adds a lock is deadlock-probed, before commit, against the implicit locks of every transaction it can meet.
A fix closing only the KNOWN instances of a class is rejected at Ralph: the fix must be an enumerator covering every member, proven by mutation, with the class recorded in the per-issue class ledger (opened at the first restart from `../../templates/class-ledger-template.md`). From then on every tier RUNS the ledger's enumerators instead of re-deriving the class; a ledgered class re-appearing means the enumerator is wrong: fix it, not another instance. When the Issue's subject is a defect class, sweep its own diff for that class before closure and re-run the detector on every artefact authored in the same session.

Only a finding that changes SHIPPED BEHAVIOUR restarts the sequence. A finding confined to tests, comments, or documentation is fixed IN PLACE and the round CONTINUES to the next tier.
A finding that invalidates the EVIDENCE for an acceptance criterion counts as shipped behaviour and DOES restart. A vacuous test, a gate that passes without checking, and a surviving mutant are all evidence-invalidating. <!-- c4:T65 --> Exception: a finding against a test-policing guard (a test whose subject is another test, not production code) never restarts, since no AC's evidence rests on it; it is fixed in place.

**Loop-quality breakers.** <!-- c4:T06 --> (1) the defect-class breaker: two consecutive same-shape FAILs require a structural alternative (fix one level up, change the mechanism, or escalate) before a third same-shape fix. (2) Each round's dispatch names a distinct attack angle, and every finding records `reachable: yes/no` (by a shipped input) before it is scored a FAIL. (3) A finding about code the agent added in-loop that no AC asks for is recorded, not fixed in-loop. (4) Classify each finding against the restart rule read fresh from this file, never a handover-inherited label. (5) A "pre-existing" or "unchanged" claim about a finding needs an executed before/after run at both tips (base and branch), output pasted. A post-close checkpoint still discloses the Ralph status (Leader.md step 9).

**Restart 4 is NOT taken. Escalate instead**: run ONE class-sweep, then resume Ralph with the restart count reset to zero.
Effect that reset with `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --escalate`, which is the ONLY thing that resets the count within a stage. At Stage-5 entry the main agent signals `bash ~/.claude/hooks/sst3-ralph-restart-counter.sh --stage5` once: it archives Stage 4's numbers under the same state key and opens Stage 5's own loop, so a scoped Stage-5 restart does not inherit Stage 4's terminal state. The counter is deliberately blind to the sweep's own subagents, so it cannot detect the escalation for itself; unsignalled, the count keeps climbing to 4, 5, 6 while this rule says 1 to 3 — wrong from the escalation onward.
Deterministic enumeration is a permitted escalation method, PREFERRED where the class is mechanically enumerable; it does NOT replace the subagent fan-out, whose hunt-and-refute shape finds classes the sweep does not generate. The escalation, in either shape, has no agent-count bound (size it to the angles) and MUST record its agent count and token cost.
The escalation MUST use and record a method DIFFERENT from those the issue's failed rounds tried (a mutation sweep counts as one); "different" binds against the issue's own failed attempts, and against a prior escalation only where the operator has authorised further loops past the terminal stop.
The fan-out prompt shape is hunt and adversarial refute: parallel hunt angles enumerate the whole class in one pass, adversarial refuters try to find a survivor, and closure is declared only on an empty survivor set. Every new guard is mutation-verified — spec and sweep quality gates (declared classes, generator blind spots, `--self-test`, coupling-only exclusion, residual rules): `mutation-verification.md` (the single canonical; this sentence is the escalation's working copy).

**After the escalation, exactly ONE further Ralph loop is permitted. If that loop does not reach PASS, the loop STOPS — this is a TERMINAL STATE.** The stop is a REPORT, never a silent abandon: list every outstanding finding with its class, what was tried, and the ledger state, so the operator rules on ship-vs-fix. Do NOT take a further restart, do NOT run a second escalation — the sequence is: up to 3 restarts → one escalation → one Ralph loop → PASS or stop-and-report.

**The counter OBSERVES; the main agent ENFORCES (#567 AC 5.6).** No hook can redirect a dispatch. The bound's MECHANISM constant (`claude/hooks/sst3-ralph-restart-counter.sh` `SST3_RALPH_RESTART_BOUND`, default 3) only keeps the telemetry honest — changing the constant alone changes NOTHING an agent reads. This prose, and its propagated copies, are the load-bearing deliverable; a future editor must not "fix" the bound by editing the constant alone, nor by editing this file alone (the bound is restated across Leader.md / SST3-solo.md / the dotfiles CLAUDE.md + CLAUDE_TEMPLATE.md / ralph/README.md / issue-template.md / the ralph-review-trio AND design-fidelity plugin copies incl. their README + marketplace.json / the drift-manifest.json divergent-pin notes + every consumer CLAUDE.md — sweep them together, AP #24).
