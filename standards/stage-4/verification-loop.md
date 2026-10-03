<!-- stages: 4 -->
# Verification Loop — Stage-4 Canonical

The Verification Loop is the iteration block that runs AFTER all phase ACs land, again once Ralph Review PASSes, and BEFORE Gate 2 (merge). Loop exits only when EVERY checkbox passes; iterate until clean.

<!-- stages: 4 -->
## Loop checkboxes (canonical: `../../workflow/WORKFLOW.md` "Verification Loop")

- Graph-backed diff audit when `graph_applicable=true` (carry-forward from Stage 1 research file; NEVER re-classify).
- Layer 3 Checkbox-MCP coverage gate (AP #20 final check). All Tier-A boxes MCP-ticked with canonical evidence.
- Overengineering / Reuse / Duplication / Fallback-policy / Wiring checks.
- Three-Tier test gate (Unit / Workflow / E2E) per `three-tier-testing.md`.
- **Mutation-verification gate (#567)**: any diff adding or modifying a gate carries the mutation table — defect re-injected → gate REDDENS, ≥1 negative control stays green — per `mutation-verification.md` (the single canonical; "every new guard is mutation-verified" is defined THERE, this line is a pointer). **Absent the table, the ACs that gate protects are recorded `unproven`, NOT `passed`** — an `unproven` AC blocks the loop exactly as a `fail` does. Closure of a defect class = an EMPTY SURVIVOR SET, never "the reported findings are fixed". Skip-clean (`M=n/a:no-gate-in-diff`) when the diff adds/modifies no gate.
- AP #18 sample-invocation (Workflow Tier real-CLI invocation; the Workflow-Tier USE clause). CI-log fetch fallback (#555 Ralph r3): empty `gh run view --log`/`--log-failed` ⇒ don't retry view variants — `gh api repos/<owner>/<repo>/actions/runs/<id>/logs` (zip download) directly.
- Skill-canonical verification (Double-Guardrail; runs invoked-skill's own hooks).
- Mirror-lane Lane A + Lane B 3-command verification.
- Doc-lane diff-trigger when diff touches `*.md` / frontmatter.
- External-store write lifetime audit (conditional) — every new keyed write to an external store carries an explicit TTL/expiry, or documents inline why a lifetime-less write is correct. Skip-clean when the diff adds no external-store write.
- Stage-4 rigor expansion: (1) short-circuit paths — a mocked-DI reachability test proves the legacy-vs-new bookkeeping parity path is REACHED, cohabiting with the completeness gate; (2) new scripts — `check-fallbacks.py` run + schema-parametrized synthesis tests + the CLAUDE.md script-inventory auto-update gate; (3) DB_NAME/env overrides — fixture-scoped mutation only + a sentinel-pair row-count regression check; (4) threaded guards — one test per call-site asserting `call_args.kwargs` propagation; (5) route/shape/signature diffs — one FULL pytest run before Ralph Tier 1 + a Gate-3 decision-marker re-grep. <!-- c4:T74 --> (6) equivalence harnesses: a harness invoking a writing tool runs every row on copies, expected-refusal rows included; a refactor's behaviour-equivalence proof lists every consumer of the unit (grep its loaders) and exercises each.
- N-variant data-repair parity: an in-place repair touching N table/data variants runs a FULL-POPULATION stored-vs-recomputed parity probe PER VARIANT before Gate 1 closes.

<!-- stages: 4 -->
## Cross-references

- `../../workflow/WORKFLOW.md` — canonical loop checkboxes.
- `.claude/commands/Leader.md` Stage 4 Gate 1 — the operator-facing trigger.
- `../../standards/STANDARDS.md` "Workflow Validation Gate" — AP #18 binding rule.
- `../../standards/ANTI-PATTERNS.md` AP #14c (subagent verification), AP #18 (sample invocation), AP #20 (checkbox MCP).
- `../../standards/stage-4/three-tier-testing.md` — Unit/Workflow/E2E tier USE rules.
- `../../standards/stage-4/observability-fail-fast.md` — runtime observability invariants the loop verifies.

<!-- stages: 4 -->
## When the loop exits

Loop exits ONLY when every checkbox PASSES — no exceptions for "high priority" or "low priority". The only valid skip is a confirmed false positive with documented evidence (AP #11). Skipping a check because it's inconvenient is a direct STANDARDS.md violation (Fix Everything).

On any FAIL: fix, re-run ALL checks (not just the failed one). The cascading-fix property is intentional — one fix can re-break a previously-clean check, so the cheapest way to confirm clean state is full re-run.
