<!-- stages: 4 -->
# Mutation Verification — Stage-4 Canonical (#567)

THE canonical definition of "every new guard is mutation-verified". The Verification Loop, `three-tier-testing.md`, the Ralph tier checklists, and `ralph-review.md`'s escalation section all POINT here (AP #10 — the escalation section keeps its own one-sentence copy for sweep context, nothing else restates the spec).

**The rule**: a gate — any test or check whose purpose is to reject a defect class — is **UNPROVEN until it has been shown to fail**. A gate that passes unconditionally satisfies EXIST and RUN and ships green; the only defence is proof it reddens on its own defect. Evidence (`Issue #3`): 9 review rounds reading gates found 4 members of a defect class that mechanical mutation found 217 of; a client-facing figure was falsified with all 107 tests green.

<!-- stages: 4 -->
## The mutation table (required artefact for any gate-bearing diff)

For any diff that ADDS or MODIFIES a gate, the tier-evidence line carries a mutation result backed by a **mutation table** — one row per gate:

| gate | defect re-injected | reddens? | negative control | stays green? |
|------|--------------------|----------|------------------|--------------|

1. **Defect re-injected**: the exact defect class the gate exists to reject, put back in (mutate the guarded artefact, not the gate).
2. **Reddens**: the suite FAILS on the mutant, for the behavioural reason the gate names — not a syntax error, not a broken anchor, not an inert import (sweep quality gate 6 below — the anchor rule).
3. **≥1 NEGATIVE control that must stay GREEN**: a table with no negative control is REJECTED — it cannot distinguish a working gate from one that fails on everything.

Absent the table, the ACs that gate protects are recorded **`unproven`**, NOT `passed` (enforced at the Verification Loop — `verification-loop.md`).

**Closure of a defect class is an EMPTY SURVIVOR SET, never "the reported findings are fixed"** (measured ratio on `Issue #3`: 4 reported of 217 actual = 1.8%). A `--check` mode that exits non-zero on any unexpected survivor is what makes the claim falsifiable.

<!-- stages: 4 -->
## Proving a new guard, parser or oracle

These rules build the table's proof so it cannot pass for the wrong reason; "revert the fix and confirm red" is the Reddens column.

1. <!-- c4:T02 --> The proof starts from an inventory derived from the artefact's code (its branches and accepted input shapes, never recalled), adds shape-pinning rows for its key, granularity and degenerate input (empty, one element, the boundary), plus one mutant per interpreter where in-process caching can false-green (e.g. a long-lived process holding the old module).
2. <!-- c4:T37 --> Grade the artefact against an independent implementation of the same spec where one exists (e.g. a reference JSON or wire-format library), not a hand-written oracle; derive an external spec's properties from the reference implementation at run time, never hand-maintain them.
3. <!-- c4:T65 --> A test's subject is production code: it is proven by injecting the defect into production code, never by breaking another test; a test-policing guard (one whose subject is another test) proves nothing about shipped behaviour.
4. <!-- c4:T32 --> A ban-style sweep derives each exemption from the line's parsed structure (syntax node, table cell, fenced block), never its raw text shape; the proof includes the smuggling direction: a mutant writing a banned token in the exempt shape must redden.
5. Beyond the conjuncts `mh_mutate` enforces (sweep gate 6), the four mh_mutate mechanics are the author's to apply: (a) the sed anchor matches exactly once, since a non-unique anchor mutates more than the mutant's name says and is BROKEN, not killed; (b) the anchor is TEXT, never a line offset from another match (`,+N`); (c) a conjunct delegated to a per-subject callback (the validator, the reachability probe) is itself mutation-verified, so a hollow mutant is refused, not scored; (d) a pattern-matching gate gets a variant-spelling mutant (same intent, different notation) beside the deletion mutant, since deletion proves only wiring and only a re-spelling proves the gate is not a list of the notations its author thought of.
6. When proven code is deleted, a REMOVAL commit re-runs the mutation set that proved it, so the deletion is shown not to reopen the class that code closed.
7. A gate over a generated artefact is paired with a freshness gate over its input; together they see an input edit that either alone misses.
8. A composite key's shape pin is one near-duplicate pair per keyed column (drop each column in turn and require red), run at the first key finding.
9. When a new test can redden on an existing mutation table's edits, the author re-runs that table in the same commit; grep for every table whose rows edit a file the new test reads.
10. A new guard's live refusal counts as a catch only after it is checked against the live system it models; a refusal that system would accept is a false positive.
11. A gate mirroring an external tool's decision copies the predicate structure of the tool it mirrors from that tool's source (independent checks stay independent, else-if stays else-if); its oracle is the exact check the gate cites, and the predicates are crossed as separate test axes from the first commit.

<!-- stages: 4 -->
## Sweep quality gates (a sweep is itself a gate — these prove IT can fail)

A mutation sweep answers only for the classes it enumerates; mechanisation removes the READING error, not the IMAGINATION error (`Issue #3` round 10: the sweep missed transposition and sign-flip; both were found by single BREAK-ONE-CLAIM dispatches — "here is ONE claim: break it", see "What reviewers are FOR" below — after nine general passes had not found them). Every sweep therefore:

1. **Declares its enumerated classes, and its headline carries the qualifier.** "0 survivors" without "of <class>" is the overclaim this canon exists to reject. The residual register names every class NOT enumerated beside every residual that is.
2. **Enumerates what its generator CANNOT produce** — sign, unit, order, magnitude scale — beside what it does. A generator that preserves sign measures "single-figure substitution: 0 survivors" over a job list containing no sign flips; blind spots are as load-bearing as coverage.
3. **Passes a `--self-test`**: with every evidence-reading gate removed/blinded, EVERY mutation must report as a survivor. A sweep reporting zero survivors must be mechanically distinguishable from a sweep that cannot see one.
4. **Excludes the COUPLING-ONLY test class from every coverage or mutation measurement**: a test comparing two DERIVED artifacts to each other, never to the source of truth, is not a catch — the author regenerates both and the defect ships (measured: one such test inflated apparent coverage 12.8×, 17 reported survivors vs 217 actual). Expect this class in any repo with a generated artifact.
5. **A gate blind BY CONSTRUCTION asserts its blindness, not its safety.** A census pins a multiset; a multiset cannot see a transposition — disclose the property with a test that FAILS if a future change makes the gate sensitive, so the disclosure is forced to stay correct.
6. **A self-check must not read as a catch.** A hardcoded anchor whose `.replace()` no-ops must fail with "PREMISE BROKEN, not a defect detected" — never score as CAUGHT. Reuse, do not duplicate: `claude/hooks/tests/lib/mutation-harness.sh` (#556) is the existing harness enforcing the mutant-failed-for-a-non-behavioural-reason class (stale anchor / inert mutant / unparseable mutant as conjuncts of one `mh_mutate`).
7. **A probe asserts it still probes what it names.** An out-of-vocabulary probe that lands in-vocabulary after a widening reports CAUGHT while measuring the opposite; assert the probe's premise each run.
8. **A residual register may only assert residuals that OCCURRED, WITH their counts.** A registered residual that does not reproduce is flagged STALE — either it closed, or the probe stopped probing; a count that stops matching fails the run rather than drifting quietly. When prose names a residual risk, enumerate and count the sites that realise it in the same pass — an uncounted residual is a claim, not a register entry.

<!-- stages: 4 -->
## What reviewers are FOR once a sweep runs

Do not re-dispatch reviewers to re-audit a class an enumeration already covers. The reviewer job the enumeration cannot do: **name a class the sweep does not generate** — the prompt shape is "here is ONE claim: break it", not "review this diff". Both classes the `Issue #3` sweep missed came from exactly that shape, in single dispatches, after nine general passes had not found them. Wired in the Ralph tier checklists (`ralph/sonnet-review.md`, `ralph/opus-review.md`).

<!-- stages: 4 -->
## Cross-references

- `three-tier-testing.md` — PROVE clause, the third requirement beside EXIST (BUILD) and RUN (USE) (gate-bearing diffs carry the mutation result within whichever tier holds the gate).
- `verification-loop.md` — the `unproven` recording rule + loop checkbox.
- `ralph-review.md` — fix-time class-ledger rule; escalation sweep contract (deterministic enumeration as a permitted, where-enumerable preferred, method).
- `templates/class-ledger-template.md` + `SST3-metrics/class-ledger/` — where each closed class's enumerator + mutation proof is recorded.
- `STANDARDS.md` "Why three — not two, not four" — mutation stays a technique WITHIN the three tiers; the taxonomy is not split (operator ruling D1, #567).
- `claude/hooks/tests/lib/mutation-harness.sh` — the reusable harness (AP #10: extend, never re-roll).
