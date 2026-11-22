<!-- stages: 4 -->
# Three-Tier Testing Framework — Stage-4 Canonical

BUILD-vs-USE testing model: the canonical (BUILD) requires all 3 tiers to EXIST; the USE clause requires all 3 tiers to RUN (fire & pass) on EVERY change (operator directive dotfiles#528 — supersedes the prior scope-matched fire), the only non-run being a documented `structural-inapplicable: <reason>`. Project test suite ("no regressions") = the checked-in Unit + Workflow + E2E tests that cover what the change touches, not every test in the repo. Canonical: `../../standards/STANDARDS.md` "Which tests get built, and which get run": build tests for what real inputs do (none for a rare edge case with no production risk), run the tests that cover the touched files, run the whole suite only when the change touches something most tests depend on or the operator asks, and before a wait of over 5 minutes say what will run and how much of it covers the change.

<!-- stages: 4 -->
## Tiers

| Tier | Scope | Runs (all 3 every change — dotfiles#528; each tier runs the tests that cover the touched files) |
|------|-------|----------------|
| Unit     | Single function / class / module | Every change. |
| Workflow | Cross-module CLI invocation / state propagation | Every change — AP #18 real-CLI sample when the change touches CLI / pipeline / SL1 / SL2 / cross-module function-arg propagation; else its workflow/integration coverage. |
| E2E      | Real-system end-to-end against real DB / real services | Every change, sized to scope — full real-system when the change affects entire system / persistence / live-trade safety; else a small backtest or an actual execution change + cleanup. A change a person sees rendered includes a picture of every touched page at each declared viewport (the repo's `.design-fidelity.json` `viewports`; default desktop 1440 + phone 390; a fixed-size output at its true size), each read (STANDARDS.md "Three-Tier Testing Framework" Run procedure step 3; `claude/hooks/sst3-page-review.sh`; dotfiles#583). |

<!-- stages: 4 -->
## BUILD vs USE

- **BUILD** (always required): all 3 tiers' tests EXIST in repo. **No pre-commit gate verifies test presence** — the BUILD-existence enumeration at the Verification Loop (WORKFLOW.md three-tier gate) plus the Ralph `sonnet-review.md` per-tier sections are the gate.
- **USE** (operator directive dotfiles#528 — all 3 RUN every change; supersedes scope-matched fire):
  - Unit AND Workflow AND E2E each RUN (fire & pass) for this change.
  - E2E may be *sized* to the change — a small backtest, or an actual execution change + cleanup — but it still RUNS.
  - E2E tests that execute real SQL seed SYNTHETIC rows and never read prod data or gate a prod-read behind `requires_postgres`.
  - The ONLY non-run is a tier recorded `structural-inapplicable: <reason>` (rare; e.g. a pure-doc diff has no Unit surface).
- "Tests pass" means all 3 tiers RAN and PASS (or are documented `structural-inapplicable`), recorded in the required tier-evidence line (canonical: STANDARDS.md "Three-Tier Testing Framework"): `tiers: U=.. W=.. E2E=.. M=.. | BUILD-evidence:<file:line per tier>`.
- **PROVE (opt-in — `ralph-review.md` "Proof of a fix")**: the default proof of a fix is one test that fails when the fix is reverted, and the tier-evidence line carries `M=n/a:not-opted-in`. Only for a diff that adds or modifies a **gate** (a test or check whose purpose is to reject a defect class) on money, data loss, security or a customer-facing figure, or when the operator asks, the tier-evidence line ALSO carries a mutation result — the gate shown to REDDEN on its re-injected defect, with ≥1 negative control that stays green — applied WITHIN whichever tier holds that gate. A gate that merely EXISTs and RUNs can pass unconditionally; only failure proves it. Absent the mutation table, the ACs that gate protects are recorded `unproven`, not `passed`. Spec + sweep quality gates: `mutation-verification.md` (single canonical — do not restate it here). Append `M=<reddened+control-green|unproven|n/a:not-opted-in>` to the tier-evidence line.

<!-- stages: 4 -->
## AP #18 sample-invocation = the Workflow Tier USE clause

The Workflow-Tier USE clause is canonically AP #18: real-CLI ≥3-repo-shape invocation, raw-tool counter-query, row-count + downstream-consumer + wrapper-vs-raw-delta verification, exit-0-insufficient, explicit `call_args.kwargs[...]` mock-assertions. Spec lives in `../../standards/STANDARDS.md` "Three-Tier Testing Framework" / "Workflow Validation Gate" + `../../standards/ANTI-PATTERNS.md` AP #18.

<!-- stages: 4 -->
## Cross-references

- `../../workflow/WORKFLOW.md` "Verification Loop" canonical tier checkboxes.
- `../../standards/STANDARDS.md` "Three-Tier Testing Framework" subsection.
- `../../standards/ANTI-PATTERNS.md` AP #18 — sample-invocation = Workflow Tier USE clause.
- Per-shape recipes: see the "Tier coverage (Unit / Workflow / E2E)" column of the per-shape recipe table in `../../reference/ap18-workflow-tier-reference.md`.
