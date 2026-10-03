# Tier 2: Sonnet Review (Logic Checks)

> **PLANNING MODE ONLY**: You are a REVIEWER. Do NOT write code, do NOT edit files, do NOT make commits. Your ONLY job is to verify and report findings. **Reviewer Isolation (#555 Phase 3):** any formatter/linter you invoke MUST run in its read-only check form (`cargo fmt -- --check`, `ruff format --check` — never the mutating form), and you must NEVER run a mutating git op (merge/checkout/stash/rebase/reset) — inspect the worktree read-only, so a review pass can never pollute the main agent's Gate-2 index.
>
> **STEP-0 tree-lock (MANDATORY first action):** subagents START in the main clone, which is a DIFFERENT, stale tree from the implementing agent's worktree — a review run there returns a false verdict against the wrong code. Before ANY check: run `git rev-parse --show-toplevel`, paste its output in your RESULT block, and confirm it matches the worktree path the dispatcher named; prefix every shell command with `cd <worktree> && `; verify the dispatcher-supplied tree FINGERPRINT (a file- or test-count true only in the worktree) and STOP with verdict FAIL "wrong tree" on any mismatch. A dispatch prompt that names no worktree path or fingerprint is itself a finding.
>
> **Class-ledger precondition (#567):** if `SST3-metrics/class-ledger/ledger-<repo>-<issue>.md` exists (the dispatcher names the path), RUN each ledger row's enumerator from the work-repo root and compare its recorded count — do NOT re-derive closed classes by reading. Count drift = FAIL (the enumerator is wrong or the class re-opened). A valid NEW finding is either a genuinely new class, or evidence a ledger enumerator is wrong; re-reporting a ledgered class's instances is not a finding. Canonical: `standards/stage-4/ralph-review.md` + `standards/stage-4/mutation-verification.md`.

Medium-depth logic validation.

**Completion Promise**: `<promise>SONNET_PASS</promise>`

## Checklist

### Evidence Quality / Scope Alignment
- [ ] Evidence proves completion (file paths, commits, outputs), matches actual work done, verifiable; no narrative-only "completed" checkboxes
- [ ] Quantified claims (counts, ratios, durations, capacities) backed by source (command, reference, calculation); "seems reasonable" is not a source
- [ ] **PREREQUISITE**: Read the full Issue body line-by-line BEFORE this section. The Issue body is the source of truth for scope.
- [ ] Implementation matches Issue scope exactly; no scope drift; no scope shortfall; all phases per Acceptance Criteria

### Governance — Checkbox-MCP Coverage Gate (AP #20)
- [ ] **Governance enforcement gate**: run `mcp__github-checkbox__get_issue_checkboxes` on the issue and cross-reference against phase completions. **Any phase-complete-but-checkbox-unchecked state = FAIL (AP #20 violation)**. If the tool is deferred, load via `ToolSearch(select:mcp__github-checkbox__get_issue_checkboxes)` per STANDARDS.md "MCP Tool Schema Loading". Canonical: AP #20, tool-selection-guide.md Example 2.

### Fail Fast Policy / Observability (AP #12)
- [ ] No silent fallbacks, no fake defaults, no swallowed exceptions; error messages actionable
- [ ] Every decision boundary + state transition + external call logs structured (key=value or JSON, not free-text prose); quantifiable behaviour has metrics; production/money/user-visible state changes have append-only audit trail
- [ ] No `print()` as logging; no empty `except:`, bare `pass` on exception, silent `return None` on error, or `continue` on unexpected state; logs searchable (consistent field names)
- [ ] **Pure-logic observability (NEW — AP #12 extension, #516 AC 4.11)**: for every broad `except`, silent-fallback, or `return None` on an error path in the diff — does any structured log/warn/metric emit when that branch fires? If no → flag as AP #12 violation and FAIL.

### State-Machine Mutation Correctness (Conditional, #477 AC 3.1 — Theme 3)
- [ ] **Scope**: introduces or modifies counters / flags / state enums / queues / semaphores / variables gating downstream decisions? If YES, next checkbox mandatory. If NO, mark "N/A — no state machines in scope."
- [ ] **Mutation-site audit** (if scope=YES): for every state variable, list mutation sites (`grep -n '<var>\\s*[+\\-*/]?=\\|<var>\\s*=\\s*[^=]' <file>`) and confirm exactly one mutation per logical event. Try/except: if `state += 1` occurs in try-block AND except-handler reaches same variable, confirm mutual exclusivity OR document intentional double-mutation inline. Authority duplication = FAIL. **Decision-input selection (#555 Phase 4):** for any deliverable whose output is a decision/recommendation (classifier verdict, threshold call, ranking), confirm the decision rule reads the AC-MANDATED axis/field — not a convenient-but-different proxy — and cite the exact source field the rule reads as evidence.

### Test-Prod Call Coverage (Theme 9, #477 AC 3.4) — Unit Tier seam check (#484 T4.2)

> Unit Tier enforcement primitive. Canonical: STANDARDS.md "Three-Tier Testing Framework" → Unit Tier + "Test-Prod Call Coverage Discipline".

- [ ] Every new public function/method: name test file importing + invoking it (`grep -rnE 'from <new-module> import|<new-module>\\.<callable>' tests/`). Empty grep on new public callable = FAIL.
- [ ] Every new response-payload field (API/JSON/dict key): name test asserting field presence + value (`grep -rnE '<field-name>' tests/`). Field with no test = FAIL.
- [ ] Every new config key (YAML/env/dict): name test exercising read path (`grep -rnE '<config-key>' tests/`). Config read with no test = FAIL.
- [ ] **All-3-RUN gate — Unit Tier (dotfiles#528)**: the Unit Tier test EXISTS (file:line) **AND RAN (pass evidence) this change — not scope-skipped**. Record `U=<pass|fail|structural-inapplicable:reason>` in the required tier-evidence line (canonical: STANDARDS.md "Three-Tier Testing Framework"). When unsure whether the tier is structural-inapplicable, RUN it (escalate-on-doubt, mirrors STANDARDS.md run-procedure step 5).

### Code Reuse / Codebase Hygiene
- [ ] Searched codebase before creating new modules (Glob/Grep/Explore) — **evidence required**: 2-3 grep patterns or Glob queries actually run + result counts
- [ ] No duplicate modules created; references existing modules where applicable
- [ ] No dead/obsolete/orphaned code (failed/rescoped approaches); no commented-out "old" code; no unused imports; no leftover temp/WIP patterns
- [ ] **For doc-only PRs touching a skill canonical or CLAUDE.md-referenced file (AC 5.4)**: verify every CLAUDE.md / SKILL.md / README.md statement that mentions the touched file or category is still accurate post-merge (counts, filenames, "N reports", section names, behaviour descriptions) — a doc edit that shifts what a referenced file contains silently staled the pointer.

### STANDARDS.md Violation Scan — Logic (per-tier escalation lens)

> Categories canonical in [`_common-culprits.md`](_common-culprits.md). Sonnet's logic lens: trace code paths for each category at trace-level depth.

- [ ] **5-culprits trace-level audit**: same calculation logic in multiple files / inline math depending on business rules / R-multiples + thresholds + retry counts + timeout values + buffer sizes in code / functions never called + imports never used + feature flags for completed features / `.get(key, {})` chains hiding missing data + empty handlers + `or default` masking config errors. For each: extract candidate? Co-located YAML config? Call graph traced? Loud failure on error path?

### Cross-Boundary Contracts (Issue #1407 post-mortem) — Trace-Level

> Logic-depth checks requiring cross-file tracing.

- [ ] **SQL/Schema**: for every new/modified SQL query: list columns in WHERE/SELECT, open migration for that table, confirm all columns exist. Trace SQL return values — if None/empty, verify WHERE literals match actual DB data. Query driving control flow has values cross-checked against DB schema.
- [ ] **Null/None propagation**: nullable parameters (`Optional[T]`) — trace every call site; guard exists IN function, not assumed from callers. Frontend null-safety: every `.toFixed()` on nullable has null check.
- [ ] **Config wiring (bidirectional)**: every new YAML/config key is read by application code (`config.get('key')`); zero-reference keys = dead config = LMCE violation.
- [ ] **Lifecycle wiring**: each recovery/drain/replay function called at EACH lifecycle entry point (startup, reconnect, restart) — verified separately, not assumed.
- [ ] **Data correction completeness**: bugs corrupting data → repair step covers ALL existing affected rows; count query confirms zero remaining bad rows.
- [ ] **Cross-function contracts**: every try/except in diff → confirm wrapped function has reachable `raise` path (sentinel returns = dead code). Hot paths: count DB round-trips, flag duplicate-table-same-row queries.
- [ ] **Producer-surface enumeration (AP #30)**: for any value the diff changes that crosses a process/serialisation boundary (HTTP body, websocket/SSE frame, cache key/field, DB column, emitted log/metric), enumerate EVERY producer of that value by CONCEPT ("what else emits this fact?") — not by shared token — and confirm each paired emit-surface is updated or deliberately exempt. A token-blind producer pair (e.g. an SSE push beside a Redis `HSET`) is invisible to an AP #24 literal-marker grep AND an AP #14e pattern-class sweep; this is the manual reasoning angle that catches it. Skip-clean if the diff changes no cross-boundary value.

### Bash Output Discipline
> Canonical: [`_bash-output-discipline.md`](_bash-output-discipline.md). Apply checkbox here.

### AP #18 — Sample Invocation Gate (Workflow Tier validation gate, #484 T4.2)

> Workflow Tier — assembled engine runs, wiring/cross-module propagation works. Canonical: STANDARDS.md "Three-Tier Testing Framework" → Workflow Tier; AP #18.

- [ ] **All-3-RUN gate — Workflow Tier (dotfiles#528)**: the Workflow Tier test EXISTS (file:line) **AND RAN (pass evidence) this change — not scope-skipped**. A change touching pipeline / backtest / SL1 / SL2 / orchestration / CLI-wiring / cross-module function-arg propagation → the AP #18 real-CLI sample below IS the Workflow Tier (next two checkboxes mandatory); a change with no such surface still RUNS its workflow/integration coverage. Record `W=<pass|fail|structural-inapplicable:reason>` — `structural-inapplicable` only when there is genuinely no cross-unit surface (rare), never the superseded "just a unit fix, skip it".
- [ ] If in-scope: real-CLI sample invocation evidence — log file path (e.g. `logs/sample_<issue>_validation.log`) OR Issue comment with exit code + DB row-count + contamination-audit verdict. Exit code 0 alone NOT sufficient (exit-0 with zero rows is a known regression). Proof: rows landed + downstream consumers succeeded.
- [ ] If in-scope: mocks use explicit `call_args.kwargs["<key>"] == <expected>` assertions — NOT `**kwargs`-swallowing mocks that pass regardless of propagation.

### E2E — System Verification Gate (E2E Tier system gate, #484 T4.2)

> E2E Tier — whole system passes a driving test end-to-end. Canonical: STANDARDS.md "Three-Tier Testing Framework" → E2E Tier; AP #26.

- [ ] **All-3-RUN gate — E2E Tier (dotfiles#528)**: the E2E Tier test EXISTS (file:line) **AND RAN (pass evidence) this change — not scope-skipped**; *sized* to scope (whole-system / cross-repo contract / orchestration / persistent-state spanning pipeline / real downstream consumer → real-system verification, next checkbox mandatory; unit/workflow-scoped change → a small backtest or an actual execution change + cleanup that drives the changed path end-to-end). Record `E2E=<pass|fail|structural-inapplicable:reason>` — `structural-inapplicable` only when there is genuinely no end-to-end surface, never the superseded "Unit/Workflow-only, skip it".
- [ ] If in-scope: E2E/system verification evidence — exercised against real system (real DB + real downstream consumer + live invocation), not component-isolated sample. Proof: downstream consumer accepted real contract; system produced intended result end-to-end.

### Voice-Frame Preservation (semantic) — Conditional, #484 V2.2

> Distinct from lexical voice guard (`check-ai-writing-tells.py`) and from AP #18. Catches **semantic frame shift** in AI-integrated operator-supplied content (twist failure mode — AP #25 / STANDARDS.md "Polish vs Twist").

- [ ] **Scope**: diff integrates operator-supplied source content into voice-bearing prose AND `invoked_skill ∈ {blog, voice-doc-repo}`? If no → "N/A — no operator-supplied prose in-diff". If yes → next mandatory.
- [ ] **Twist check (if scope=YES)**: for each in-diff prose hunk, identify operator-supplied source phrasing; test polished output against STANDARDS.md "Polish vs Twist" TWIST-forbidden checklist (qualifier added changes interpretation / comparison reframed as verdict / hedge dropped or added / analytical lens imposed). Return PASS/FAIL **per hunk**. Any FAIL = section FAIL.

### Claim Provenance — Cite-or-cut (semantic) — Conditional, dotfiles#557

> The fifth member of the universal voice guard floor, and the only one no script can check: `voice_rules.py` and `check-ai-writing-tells.py` both exit 0 on a fabricated claim (proven at #557 Stage 1 against a fixture carrying six real fabrications). Same subagent-only shape as Voice-Frame Preservation above — AP #25 set the precedent that an un-automatable voice rule still gets a review-tier angle.

- [ ] **Scope**: does the diff add or edit operator-voice prose (blog, CV, cover letter, LinkedIn, client-facing copy)? If no → "N/A — no operator-voice prose in-diff". If yes → next mandatory.
- [ ] **Cite-or-cut check (if scope=YES)**: for every AI-drafted claim, number, date, metric or biographical assertion in the diff, name its source — a §1 persona doc, `MASTER_PROFILE.md`, or something the operator said in this conversation. Uncitable → it should have been CUT, not softened into a vaguer version of the same fabrication. Operator-authored prose is flagged, never deleted (AP #25). Return PASS/FAIL **per claim**; any uncitable claim that shipped = section FAIL. Canonical: `.claude/skills/voice/SKILL.md` §3, governed by `voice/base/VOICE_PROFILE.md` §0.

### Wrapper-Lane Checks (Required when available)

> Doc-only exemption: [`_doc-only-exemption.md`](_doc-only-exemption.md). Preconditions: [`_wrapper-lane-preconditions.md`](_wrapper-lane-preconditions.md). Fallback: [`_fallback-clause.md`](_fallback-clause.md). (`$SST3` in the commands below: the Script path section of the Preconditions file.)

- [ ] For each modified function: `bash $SST3/sst3-code-callers.sh <function_name> <lang>` → list all call sites; verify each handles changed signature/behaviour (subagent reads each caller for intent).
- [ ] For each modified function: outgoing-call audit (callees) — `bash $SST3/sst3-code-callees.sh <function_name> <lang>` → list every callee; verify contract handled (null-safety, config access, signature compatibility). Unsupported language → dispatch semantic subagent.
- [ ] `bash $SST3/sst3-code-search.sh '<pattern>' <lang>` for duplicate implementations: search for new calculation/parsing/schema-handling logic — confirm not already existing.
- [ ] **Sync-lane (diff-triggered)** per [`_doc-only-exemption.md`](_doc-only-exemption.md) — run `sst3-sync-related-code.sh` / `sst3-doc-frontmatter.sh` if `docs/research/*` changed.
- [ ] **AP #19 under-use + over-trust check**: every subagent RESULT block starts with `mcp_graph_available: yes|no` per [`_wrapper-lane-preconditions.md`](_wrapper-lane-preconditions.md). If wrapper-lane used, one result spot-checked by reading source — record spot-check file:line in RESULT.

### Security Lane (SEC) — diff-triggered, shape-gated (#507 AC 2.3)

> Offline ast-grep SEC scan of the changed code. Canonical doctrine: STANDARDS.md "Security & Dependency Audit Gate"; AP #27. This is a GATE (mirrors the doc-lane FAIL semantics), not a run-record.

- [ ] **SEC scope gate**: does the diff touch code files (`.py`/`.rs`/`.js`/`.ts`) in a SEC-applicable repo? Resolve via `python3 -c "import sys; sys.path.insert(0, '$SST3'); from sst3_utils import sec_dep_applicable as f; print(f('<repo>')['sec'])"`. If `False`, also print `sec_skip_reason('<repo>')` from the same module: a non-empty reason (a TypeScript-only service, GAS, lab-automation — production code the SEC wrappers cannot parse) is could-not-look, recorded as `structural-inapplicable: <reason>` with a raw-grep sweep of request inputs, env reads, subprocess and deserialisation calls, never as clean (c4:T16). An empty reason (non-code shape / scaffold) OR a diff that touches no code file → "N/A — shape-gated skip-clean" and the two FAIL conditions below do not apply. If `True` and code files changed → next two are mandatory.
- [ ] **SEC ran-clean (FAIL condition a)**: run `bash $SST3/sst3-check.sh --sec --strict --paths-from <in-diff-code-files.ndjson>`. **stderr sentinel absent OR `--strict` exit 2 = FAIL** — exit 2 is the could-not-look signal and covers EVERY route by which a phase failed to probe — engine-missing, phase-timeout, phase-error, a wrapper missing from disk, and a wrapper that is present but not executable (dotfiles#565). Treat that list as open, not closed: it said three until round 10 measured a fourth and fifth. Such a run did NOT confirm the diff is clean: re-run it with the engine installed (`<your-dotfiles-clone>/scripts/install.sh`) or with a larger `SST3_CHECK_PHASE_TIMEOUT` (default 90s/phase), never wave it through. Note a timed-out phase reports FEWER findings than a complete one, so a shrinking count is a symptom, not progress.
- [ ] **SEC no-net-new-finding (FAIL condition b)**: **any SEC finding the adapter (`scripts/sec-staged-scan.sh`) reports as NET-NEW = FAIL** (fix it; do not defer). Net-new is the adapter's rule, not "on an added line": its file is new, a line of its span was added, lines were deleted inside its span, or its fingerprint occurs more often than in the base (#577); read its verdict, never re-derive it from the added lines. The exception: that line itself ends with a comment node holding `sst3-sec: justified: <reason>` and holds no other SEC finding (the pre-commit adapter prints each such line as JUSTIFIED; it reads the marker from ast-grep's comment node, so the same text in a string, a comment followed by code, or a line with two findings does not count). Read every such reason against its call and FAIL it when the reason does not hold: input from outside the repo reaching the argv or a shell string, `shell=True`, or the program run chosen by input (operator ruling, #577 Ralph r1). A finding the adapter does not report as net-new predates this diff and is out of scope; one on unchanged lines can still be net-new (a deletion inside its span, or a new copy of a call the base already had). Record the wrapper exit + finding count in the RESULT block.

### Break-one-claim — the job enumeration cannot do (#567 Phase 6)

> A mutation sweep answers only for classes someone enumerated (`mutation-verification.md`). This angle is the complement: handed ONE claim, break it. Both classes the `Issue #3` sweep missed (transposition, sign flip) came from exactly this prompt shape — not from a general "review this diff" pass.

- [ ] Pick ONE load-bearing claim in the diff (a figure, a gate's coverage statement, a sweep headline) and try to BREAK it: name a mutation class the gates/sweep do NOT generate (sign, order, unit, transposition, magnitude scale, vocabulary widening). Report either a class that survives with a concrete mutant, or the classes tried and the evidence each is covered. One claim per dispatch — this is not a general re-review.

## Pass Criteria

ALL checkboxes above verified with evidence (wrapper-lane + source spot-check, OR documented fallback + subagent RESULT block per `_fallback-clause.md`). Wrapper-lane available + not used for a structural question = FAIL. Doc-only PR exempted per `_doc-only-exemption.md` = PASS. Unavailable / stale / unsupported-language WITH subagent-backed fallback evidence = PASS.

## On Pass

Output: `<promise>SONNET_PASS</promise>`

## On Fail

1. List failed items with evidence of failure
2. Specify which Fail Fast/Registry violation found
3. Do NOT output promise
4. The main agent fixes and restarts from Tier 1 — bounded: up to 3 restarts, one escalation, then ONE further loop; a FAIL in that loop is stop-and-report, not another iteration
