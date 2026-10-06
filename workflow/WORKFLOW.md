# SST3 Solo Workflow

> Wrapper-lane replaced the deprecated daemon-MCP in #445 (history: `git log --grep="#445"`).

**Subagents**: research, read, audit, plan, verify. NEVER write code, create issues, or implement. **Main agent**: collates findings, writes /tmp, creates issues, implements, commits, merges.

<!-- stages: always -->
## The 5-Stage Sequential Workflow

**CRITICAL**: ORDER-DEPENDENT. No skipping, no reordering.

<!-- stages: 1 -->
### Stage 1 — Research (Subagent Swarm → /tmp)

- [ ] Check `docs/research/` for existing research on this domain first
- [ ] **MANDATORY self-test + status CHECK at Stage 1 top** (three-way twin with Leader.md + SST3-solo.md). Run `bash $SST3/sst3-self-test.sh` **FIRST**; any `{"kind":"fixture-drift",...}` NDJSON line = **ABORT swarm dispatch**, reproduce + fix on `solo/wrapper-fix-<bug>` (NOT this Issue's branch) through its own Stage 4, then resume (judge on a clean tree: unstaged-edit drift with `wrapper drift` 0 is no regression). Then run `bash $SST3/sst3-code-status.sh` unconditionally; record `last_updated` + `file_count` in the research file. Stateless lane (no build/staleness step; `sst3-code-update.sh` is a no-op shim). Doc + sync audit: `/sync-check`; recipes: `docs/guides/code-query-playbook.md` "Stage-Mapped Recipes".
- [ ] **Doc-lane is diff-triggered, NOT graph-gated** (#484 W6.1 — resolves the `graph_applicable` overload). `graph_applicable` gates ONLY the CODE SEED (`sst3-code-callers`/`callees`/`search`/`impact`). The DOC lane (`sst3-doc-lint`/`sst3-doc-links`/`sst3-doc-frontmatter`/`sst3-doc-toc`/`sst3-doc-yaml`) runs **whenever the diff touches `*.md` / frontmatter / docs, regardless of `graph_applicable`** — mirroring how `sst3-code-status.sh` runs unconditionally for audit. A semantic / voice / cross-document Issue (`graph_applicable=false`) still runs the doc-lane on its `*.md` diff (this is why a governance-only Issue is NOT exempt from doc linting). Skip-clean only when the diff touches no `*.md` / frontmatter / doc file.
- [ ] **Pre-swarm graph SEED** (STANDARDS.md "Structural Code Queries"): if the research topic is structural code in a supported language, use graph to DEFINE scope BEFORE dispatching the swarm — not to verify pre-formed scope AFTER. Run `bash $SST3/sst3-code-callers.sh <symbol> <lang>` / `bash $SST3/sst3-code-search.sh '<pattern>' <lang>` on every symbol the USER MENTIONED in the task description, plus `bash $SST3/sst3-code-impact.sh <base-branch>` on user-named files. Feed the resulting evidence into subagent prompts so layer-1 angles are scoped to real call-sites / symbols / blast-radius — not hypothesis. Graph SEEDS the swarm; it does NOT replace its different-angle coverage. Skip-condition: if the topic is semantic / voice / intent / cross-document / non-code (one of the 12 subagent-only moments), skip graph queries; go straight to swarm. (The status freshness CHECK above still runs unconditionally for audit trail.)
- [ ] **Wrapper-lane class-coverage matrix (AC 2.6)**: write a 3-column table (language, query-type, wrapper-status: functional/empty) to the /tmp scope file so all Stage-2 subagents see which combinations need raw counter-queries instead of dispatch-vs-raw delta gates.
- [ ] Author + run the research swarm via the Workflow tool (DEFAULT), each subtask a focused area (5 files max per subtask). Subagents remain required for the 12 subagent-only moments.
- [ ] **Workflow tool — DEFAULT swarm dispatch (#514)**: this swarm is authored + run via the Workflow tool by default (no `/effort ultracode` gate). AP #14 still governs — the main agent verifies every finding against source, and the Layer-2 adversarial angle stays raw-tools-only. Read-only audit swarms (Stages 1/3/5) require no per-agent worktree isolation; the Stage-4 main-agent EnterWorktree is separate and unaffected. Agent/Task dispatch is the documented fallback ONLY for a trivial single-angle check. The swarm contract (RESULT block, layered cross-check) is unchanged; a `wf_…` run id is recorded in the stage checkpoint (AP #16 monitoring). Canonical rule: STANDARDS.md "Default Dispatch Mechanism — the Workflow tool (#514)".
- [ ] **Swarm fan-out discipline (AC 1.10)**: if the brief names N angles, N is the HARD MINIMUM. Derive coverage clusters from full `ls` output. Synthesis subtasks wait for all swarm outputs to land before dispatch.
- [ ] **Prior-art angle (AC 1.12)** is a standing MANDATORY Layer-1 subagent in every swarm — grep the mechanism name + synonyms before proposing new work. <!-- c4:T01 --> It is one case of the AP #14e concept sweep over every absence or completeness claim: grep the concept, never only the literal name.
- [ ] **Layer-2 adversarial gap-finder MANDATORY** (Theme 8, #477; AP #14 instantiation): after the Layer-1 swarm completes, dispatch a Layer-2 subagent with prompt: "Layer-1 found X, Y, Z. Find 3 things they missed — false-positive claims with modern equivalents OR genuine gaps not yet surfaced." Layer-2 prompt MUST differ from Layer-1 (per AP #14c). For infrastructure / governance / cross-cutting Issues this angle is load-bearing — generic Layer-1 coverage misses scope-adjacent gaps. Canonical rule: STANDARDS.md "Stage 1 Layer-2 Adversarial Gap-Finder Discipline"; cross-reference: ANTI-PATTERNS.md AP #14d. Procedure expanded in Leader.md Stage 1 step 2a.
- [ ] **Topology-trigger angles (AC 3.9 — CONDITIONAL)**: (A) if the issue touches a shared helper / middleware called from multiple call paths, dispatch an infrastructure-asymmetry angle — list every governance/observability/breaker/rate-limit/retry mechanism attached to call path A, confirm the same is attached to call path B, and list ASYMMETRIES; (B) if the issue touches a runtime-pipeline-architecture surface (install unit shape, service wiring, propagation), dispatch a downstream-consumer-staleness angle — walk CLAUDE.md/README/runbook references to the changing surface; (C) if the issue edits SST3 governance canon itself (Leader.md, templates and stage-N files included), dispatch a dedicated architecture/wiring angle: `<!-- stages: N -->` loader tags, cross-doc delegation refs, resulting gate set, mirror/propagation lanes.
- [ ] **Subagent prompt preamble — destructive-op safety (AC 2.9)**: include in every swarm subtask prompt: "If you need a scratch directory, use `mktemp -d` and leave cleanup to the harness. To remove a specific file, use `rm <filename>` by exact path. Never use `rm -rf` — the destructive-op guard will abort the agent before StructuredOutput is emitted." (Applies identically to the Stage 3 and Stage 5 swarm-dispatch instructions.) <!-- c4:T59 --> Swarm scratch goes only under /tmp/sst3-<topic>/ (named in the prompt), so the Stage-5 drain gate and the operator can find and clear it; a leg never writes scratch into the repo or the operator's folders.
- [ ] Main context = orchestrator only — NEVER read source files directly in main context
- [ ] Research phase must use <30% of context budget
- [ ] Main agent collates all subagent findings into /tmp file containing: **findings + gaps + plan**. Record any wrapper-lane calls used + `last_updated` + `file_count` + spot-check source file:line. Also record `graph_applicable: true|false (reason: <class>)` — downstream stages MUST read this field and NOT re-derive the classification independently (single-declaration-carries-forward). (`graph_applicable` is the historical field name retained for downstream-stage carry-forward; it gates whether wrapper-lane queries are run.) `findings_compact` option (AC 1.6): `["<file>:<line>: <category>: <quote>", ...]` for Layer-1 angles that need token-economy without losing evidence provenance.
- [ ] **Research-file canonical section schema (AC 1.3)**: the /tmp research file carries §0 frontmatter (`pre_swarm_graph_seed: <skipped|ran>`, `graph_applicable`, `invoked_skill`); §0.5 Pre-Stage-2 empirical decisions (open scope-gaps requiring runtime validation, marked DO NOT DECIDE IN STAGE 2 WITHOUT EMPIRICAL VALIDATION); §1-N findings (each backed by file:line / command / URL); §N+1 **Stage-4 validation matrix** (file + simulated state + spot-check method); §N+2 Known Design Decisions appendix (previously-documented limitations so Layer-1/2 agents skip rediscovery).
- [ ] **Scope-snippet completeness (AC 1.4)**: the scope snippet must carry a Structural-Decisions section, verbatim operator constraints, a Known Design Limits appendix, and binary decision gates — see Leader.md Stage 1 scope-snippet checklist. <!-- c4:T03 --> Pinned facts carry the STANDARDS.md "Scope Snippet Rule" provenance (source: operator-said|repo-derived|inherited, …).
- [ ] **Unblocker-as-Phase-0 + waive cross-read (AC 1.5)**: when the issue combines an unblocker bug-fix with forward-looking work, flag the bug-fix as Phase 0 at the TOP of the idea-repo section. When a scope snippet cites a README waive-statement, cross-read the operative CLAUDE.md rule in the same pass. Record the production build command source-of-truth explicitly in the research file for deploy-shape repos.
- [ ] **Bootstrap / public-surface angle (AC 1.13)**: for bootstrap/UX-friction topics, pair the structural audit with an operator-walkthrough re-trace angle to surface friction items that do not appear in code-grep. For public-facing content topics, include a live-surface angle (rendered pages, public profiles, deployed endpoints) alongside local-file analysis.
- [ ] **Collation completeness (AC 3.15 — CONDITIONAL, only when a raw-scan JSON was produced, e.g. `/tmp/<repo>-findings-flat.json`)**: after writing the themed research file, run `diff <(jq -r '.[].id' /tmp/<repo>-findings-flat.json | sort) <(grep -oE '[A-Z]+[0-9][0-9A-Za-z-]*' <research-file> | sort -u)`; any raw ID absent from the research file is a collation drop — re-home it before Stage 2. Skip-clean if no raw-scan JSON was produced (manual-only research).
- [ ] Output /tmp file for user review before proceeding to Stage 2
- [ ] Per-stage feedback per STANDARDS.md §Per-Stage Feedback Capture — write the Stage 1 block before declaring complete

<!-- stages: 1,2 -->
### Stage 2 — Issue Creation (Main Agent from /tmp Research)

- [ ] Use `../templates/issue-template.md` — NEVER create issues from scratch
- [ ] Add ALL before/after illustrations for comparison after implementation <!-- c4:T43 --> — a visual or computed-definition deliverable is rendered from live data for the operator before Stage 2 closes
- [ ] Add phase checkpoints between phases in Acceptance Criteria
- [ ] Check context memory — on long work, when remaining nears ~50% (~500K of 1M) auto-`/handover` + compact + continue; never operate below 50% remaining
- [ ] Author + run the draft-check swarm via the Workflow tool (DEFAULT) — full-coverage scope-check vs audit, one subtask per coverage angle; Agent/Task is the documented fallback only for a trivial single-angle check
- [ ] **Layer-2 correction-tag preservation (AC 2.5)**: keep Layer-2-introduced correction tags (e.g. `**Bootstrap ordering** (Layer-2 Angle A):`) in the final GitHub issue body for Stage-5 provenance.
- [ ] **Multi-phase gating matrix (AC 2.8)**: for multi-phase drafts, author an explicit Phase N → Phase M dependency table (per Leader.md Stage 2 step 7.5) in the draft before Stage 3.
- [ ] Quality mantras listed VERBATIM in issue scope — not summarized:
  - No inefficiencies, fix optimisation opportunities
  - Reliable and robust (not prone to breakage or failing)
  - Dedupe duplicate codes
  - No bottlenecks
  - Runs super fast and safe
  - No memory leaks using preventions
  - Follows STANDARDS.md
- [ ] No false positives — everything real gets fixed
- [ ] No such thing as high priority or low priority — all must be fixed
- [ ] Per-stage feedback per STANDARDS.md §Per-Stage Feedback Capture — write the Stage 2 block before declaring complete

<!-- stages: 2,3 -->
### Stage 3 — Triple-Check (Subagents Verify Scope)

- [ ] **Dispatch Layer-1 subagents; wait for all /tmp output files; THEN dispatch Layer-2 subagents with Layer-1 outputs as input context (AC 3.12)** — Layer-2 must NOT be dispatched concurrently with Layer-1 (Layer-2 verifies false-positive claims against actual Layer-1 verdicts, not hypotheticals). Authored + run via the Workflow tool (DEFAULT; minimum 3 subtasks, scale up); Agent/Task is the documented fallback only for a trivial single-angle check. AP #14 governs — the main agent verifies every finding against source.
- [ ] Scope vs audit doc = 100% captured, nothing missing, no gaps
- [ ] No overengineering — only what was agreed
- [ ] **Chat Reconciliation (Verifier-Led) — MAIN-AGENT-OWNED, non-delegable** (subagents never receive the conversation, so this cannot be a subagent self-cert). Per Leader.md Stage-3 step 2a: extract the operator's raw messages (`extract-chat-agreements.py`), dispatch the THREE-MODEL neutral verifier panel (one Haiku + one Sonnet + one Opus, shown ONLY the raw messages — NOT the scope), then the main agent flags `invented` / `dropped` / `inverted` divergence against the drafted issue, POSTs the `## Chat Reconciliation` report, and PAUSEs for operator sign-off before `gh issue create`. Doctrine: STANDARDS.md "Chat Reconciliation (Verifier-Led)" (#522).
- [ ] Check for dead/obsolete/legacy code cleanup opportunities
- [ ] **Verify-command execution (AC 3.1)**: for every AC verify command in the draft, run it against the live repo; any FAIL or vacuous-pass = block Issue creation until the AC is rewritten. <!-- c4:T31 --> This includes appended template boilerplate: the copied Solo Assignment tail's branch/path/command literals are resolved against the target repo.
- [ ] **Filesystem-state verification (AC 3.7)**: all path/file/dir existence claims verified via `ls` / `find` / `git ls-tree` against the live repo.
- [ ] **Raw-tool subagent self-checks (AC 3.10)**: the raw-tool L1 subagent prompt MUST include — (1) filter comment-only lines (`grep -vE '^\s*#|^\s*"""'`) before reporting a live reference as a blocker; (2) read the production AC text from the draft, not a `/tmp/*_proto.py` throwaway, when evaluating spec compliance; (3) classify whether the queried symbol is an identifier ast-grep matches natively (flag) or a non-identifier string (bash array name, comment, docstring — expected, do not flag) before reporting a wrapper-vs-raw delta.
- [ ] **(S3-WR) Writer-reader contract angle (CONDITIONAL)** — when scope introduces a SSOT key/field (Redis key, API shape, DB column): dispatch one subagent angle that, for each key, locates the writer (command + payload fields) and every reader (command + accessed fields); flags any SET/HSET vs GET/HGETALL mismatch or payload-field mismatch as a Stage 3 FAIL. Skip-clean if no SSOT key/field introduced.
- [ ] **(S3-MATH) Numeric-claim verification angle (CONDITIONAL)** — when scope cites numeric bounds (contrast ratios, thresholds, band bounds, tolerances): dispatch one subagent angle that re-derives the cited figure across the full stated range (not just the midpoint); flags any value in the range violating the cited spec as a Stage 3 FAIL. Skip-clean if no numeric spec claims in scope.
- [ ] **Post-fix mini-audit (AC 3.8)**: after applying all audit-driven fixes, dispatch one consolidated post-fix subagent: "Stage 3 found N gaps and applied N fixes [enumerate]. Walk the corrected draft and confirm each fix addresses its gap. RESULT block: each gap PASS|FAIL with file:line evidence." Do not create the Issue until all N are PASS. <!-- c4:T22 --> At Stage 2, a ≥10-item correction batch gets this mini-audit before the wide swarm sees the corrected draft, and the mini-audit re-runs after every correction round.
- [ ] <a id="quality-mantras"></a> **Stage-3 Quality Mantras Checkbox (5-item operational subset of [STANDARDS.md Quality Mantras (Doctrinal)](../standards/STANDARDS.md#quality-mantras))** <!-- subset of STANDARDS.md Quality Mantras (Doctrinal) -->: confirm the Stage-3 audit applied no-inefficiencies / reliable+robust / dedupe / no-bottlenecks-and-leaks / follows-STANDARDS.md. The doctrinal 9-item list is canonical at STANDARDS.md; this subset is the operational checkbox shape Stage 3 runs.
- [ ] All scope goes in issue BODY — never in comments (comments are temporal, body is permanent)
- [ ] Per-stage feedback per STANDARDS.md §Per-Stage Feedback Capture — write the Stage 3 block before declaring complete

<!-- stages: 4 -->
### Stage 4 — Implementation + Merge + User Review

- [ ] **Cross-repo scope-transfer sweep (AC 5.13)**: when transferring Issue scope to a DIFFERENT repo than where it was drafted, dispatch a single Plan-mode sweep surfacing all cross-repo deltas (paths, repo shape, ACs, branch names, feedback-file naming) BEFORE Stage 4 starts — a scope authored against repo A's layout silently mis-targets repo B. Skip-clean if the implementation repo == the drafting repo.
- [ ] Implement all phases from issue Acceptance Criteria
- [ ] Commit after EACH file change: `git add {file} && git commit -m "type: description (#issue)" && git push`
- [ ] **Consumer-onboarding procedure (AC 4.9)**: before adding a new consumer to any shared table/list (`KNOWN_REPOS`, `CONSUMERS`, `drift-manifest.json`), enumerate the full current membership and diff it against the most-recently-added consumer's registration footprint to catch incomplete prior registrations. <!-- c4:T13 --> Likewise for the Nth member of any set: a presence-matrix check of member N-1 across every surface it was registered in. A new consumer also gets the GitHub tag ruleset `SST3 protected local-only tag patterns`, the only thing that stops a local checkpoint tag (`backup/**`, `tmp/**`, `wip/**`, `pre-rebase-*`, `pre-leader-merge-*`, `pre-tool-adoption*`, `v*-pre-tool-adoption`) being pushed: copy it from an existing consumer (`gh api repos/<owner>/<repo>/rulesets/<id>`, then `gh api -X POST repos/<owner>/<new-repo>/rulesets --input <file>` with its `name`, `target`, `enforcement`, `conditions`, `rules` and `bypass_actors`).
- [ ] Run Verification Loop (repeat until clean — see below)
- [ ] Run Ralph Review: Haiku → Sonnet → Opus (all 3 mandatory)
- [ ] Merge BEFORE user review (protects work) — recursion-safe remote fast-forward, NO shared-tree checkout (dotfiles#488 Fix-A / Leader.md Gate 2 / AC 1.3):
  - From the worktree: `git push origin <solo-branch>` then `git push origin <solo-branch>:master` (server-side FF of `origin/master`)
  - On non-FF reject: `git fetch origin master` → `git rebase origin/master` (in worktree) → retry (≤3, NEVER `--force`); NO shared-tree branch-switch/local-merge/reset (the one write after a dotfiles push is the ff-only catch-up of the runtime canon clone: `gate-2-merge.md` "Branch-switch invariant")
  - `ExitWorktree action:keep` until `git ls-remote origin master` == solo tip, then `action:remove`; `git push origin --delete <solo-branch>`; `git fetch --prune`
  - **Mirror Propagation Routing (AC 4.10)**: consumer writes (propagate-mirrors/-block/-template) run ONLY after the confirmed Gate-2 fast-forward, from a clean `.claude/worktrees/` worktree at origin/master, NEVER the main clone (the shared runtime canon); any other tree defers or refuses them. On a solo branch `--apply` writes only that tree, committed with the change (#577 K8).
- [ ] POST `user-review-checklist.md` from TEMPLATE — not made up, ALL sections mandatory, NONE optional
- [ ] Work through checklist WITH user
- [ ] Fix any gaps found — no deferrals, no excuses unless confirmed false positive
- [ ] User approves
- [ ] Per-stage feedback per STANDARDS.md §Per-Stage Feedback Capture — write the Stage 4 block (per-Ralph-tier sub-bullets in `worked` + `ralph_restarts` in `friction`) before declaring complete

<!-- stages: 1,5 -->
### Stage 5 — Post-Implementation Review (Subagent Swarm)

- [ ] Review against issue body scope, goal alignment, and design doc
- [ ] **Pre-flight CI check (AC 5.2)**: run `gh run list --repo <owner>/<repo> --limit 5 --json conclusion` and surface any FAILURE before dispatching the swarm — a red pipeline invalidates "the change is green" and must be triaged first (probe-before-assert, AP #29).
- [ ] **Worktree cleanup hard gate (AC 5.8)**: `git worktree list` shows no `solo/issue-<N>-*` or `worktree-solo+issue-<N>-*` entry AND `git branch --list` shows no such branch before Stage 5 proceeds. A lingering worktree/branch means Gate-2 cleanup did not complete — finish it first.
- [ ] **Workflow tool — DEFAULT swarm dispatch (#514)**: this post-implementation swarm is authored + run via the Workflow tool by default (no `/effort ultracode` gate). AP #14 still governs (main agent verifies every finding; the Layer-2 raw-tools-only angle stays raw-tools-only). Read-only audit swarms (Stages 1/3/5) require no per-agent worktree isolation; the Stage-4 main-agent EnterWorktree is separate and unaffected. Agent/Task is the documented fallback only for a trivial single-angle check; a `wf_…` run id is recorded in the Stage-5 checkpoint (AP #16 monitoring). Canonical rule: STANDARDS.md "Default Dispatch Mechanism — the Workflow tool (#514)".
- [ ] **Audit Research Preservation**: if the issue research phase produced 3+ external sources, verify all have been captured in `docs/research/` per `research-reference-guide.md` schema (YAML frontmatter, canonical filename `YYYY-MM-DD-topic-description-issue-NNN.md`, quality score ≥8/10). Checklist template: `../reference/research-reference-guide.md`.
- [ ] **Consumer-mirror cross-canonical drift angle (AC 5.6)**: for multi-canonical rollup Issues, include an angle that, for every cross-reference inserted by this rollup, grep-verifies the target canonical actually contains the referenced rule (e.g. a "see ANTI-PATTERNS.md AP #29" pointer is dead unless AP #29 exists). Pointer→target resolution across STANDARDS/ANTI-PATTERNS/WORKFLOW/Leader + consumer mirrors must be 100%.
- [ ] **Verdict-conflict — PASS-but-critical re-prompt (AC 5.11)**: after collecting all Layer-1 RESULT blocks, scan every PASS-verdict block for any finding whose severity > INFORMATIONAL. For each hit, re-prompt that subagent: "your finding warrants a FAIL — confirm or refute" before accepting the PASS verdict.
- [ ] **Verdict-conflict — L2-vs-AC triangulation (AC 5.11)**: when Layer-2 surfaces a high-conviction single_highest_impact_fix that contradicts an explicit AC text in the Issue body, dispatch one verification subagent to read the AC + spec text + Layer-2 finding side-by-side and return a 3-way reconciliation (AC says X / Layer-2 claims Y / source shows Z) before applying the fix. <!-- c4:T17 --> When layers disagree whether a defect is live, or an AC names where a check must be green, the smallest real execution at that target decides, output pasted, never source reasoning or a proxy tool.
- [ ] **Wiring check**: Everything wired up properly — common failure: fix/enhance/refactor but forget to wire up to existing functions
- [ ] **Graph-backed diff audit** (when graph available per STANDARDS.md "Structural Code Queries"): `bash $SST3/sst3-code-review.sh origin/<default-branch>` (after a fetch; `origin/main` or `origin/master` per repo default — never a bare local branch name, whose stale ref silently widens the diff) generates a diff-scoped context block (changed files + per-file `impacted_callers` blast radius + untested-function warnings + engine `review-error` records — #544; high-`impacted_callers` files = the wide-blast-radius signal). Feed this into ONE of the subagent audit prompts. Subagents still do the semantic wiring / intent / cross-document audits. Graph findings feed subagents, never replace them.
- [ ] Check for: inefficiencies, dead code from refactors, optimisation opportunities
- [ ] Reliable and robust (not prone to breakage or failing)
- [ ] Duplications that need dedupe, bottlenecks
- [ ] No memory leaks using preventions
- [ ] Follows STANDARDS.md
- [ ] Check issue body scope 100% completed — no gaps
- [ ] Fix ALL problems — no deferrals, no excuses
- [ ] Run regression tests — if not run yet, run them now
- [ ] **Task-close drain gate**: `bash $SST3/leader-stage5-drain-check.sh <issue-number> [--repo <repo>]` exit 0 mandatory before sign-off (STANDARDS.md "Task-Close Drain Gate (Canonical)").
- [ ] Per-stage feedback per STANDARDS.md §Per-Stage Feedback Capture — write the Stage 5 block before declaring complete

<!-- stages: 5 -->
<!-- stages: 4 -->
## Verification Loop

- [ ] **Scope completeness gate**: Enumerate every Acceptance Criteria checkbox from issue body. For EACH one: state file:line that implements it. Any checkbox without file:line = NOT DONE. Do NOT proceed until all checkboxes have evidence.
- [ ] **Checkbox-MCP coverage gate (AP #20)**: **(0) Auto-tick precondition**: inspect `SST3-metrics/.tier-a-auto-tick/<issue#>-<phase>.json` and the Issue body's `PoW [<ac_id>]: ... (auto-ticked via tier-a-auto-tick.yml)` lines; if every Tier-A box of the just-completed phase is `[x]` with auto-tick evidence, say so in the checkpoint comment and skip to step (4); otherwise run manual steps (1)-(3) (the AP #20 fallback). **(1)** if `mcp__github-checkbox__get_issue_checkboxes` is deferred, load its schema via `ToolSearch(select:mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__update_issue_checkbox)` per STANDARDS.md "MCP Tool Schema Loading" — bootstrap step, mandatory before the gate runs. **(2)** run `get_issue_checkboxes` and list every Tier-A box still `[ ]` that corresponds to completed work. **(3)** for each such box, invoke `update_issue_checkbox(issue_number, exact_checkbox_text, evidence)` with canonical evidence (file:line / commit hash / command+output / subagent RESULT comment-id per `../reference/tool-selection-guide.md` Example 2). **(4)** re-run `get_issue_checkboxes` and confirm every Tier-A box is `[x]`. Comment-only progress = FAIL. If this gate fails, use `update_issue_checkbox` to close every remaining box with evidence within this Gate 1 run (in-issue retroactivity, not historical — historical drift is handled separately) before declaring Gate 1 clean.
- [ ] All checkboxes verified with evidence
- [ ] Overengineering check: simpler solution exists?
- [ ] Architecture reuse check: duplicated instead of reused?
- [ ] Code duplication check: needs deduplication?
- [ ] Fallback policy check: silent failures?
- [ ] **Wiring check — 4 parts** (structural layer: `bash $SST3/sst3-code-callers.sh <function> <lang>` + `bash $SST3/sst3-code-impact.sh <base-branch>` when graph available per STANDARDS.md "Structural Code Queries"; semantic layer: subagent verifies each caller handles the new contract correctly. Document both layers in the RESULT block. If graph unavailable / stale / unsupported-language, fall back to grep + subagent and document why.):
  1. Every new function/method is called from at least one caller (`query callers_of(<name>)` first; grep fallback for unsupported languages)
  2. Every config key added to YAML is read by code (grep for key name in source — zero results = dead config). YAML is unsupported by graph, so grep is the primary tool here.
  3. Every SQL query's column names exist in the target table (verify with `\d tablename` or migration file)
  4. Every None-producing code path: confirm callee's type annotation accepts `Optional` / has null guard
- [ ] **Legacy-vs-new-path bookkeeping diff (AC 5.1)**: when a change adds a new code path alongside an existing one (new channel, new param mode, migration shim), diff the bookkeeping the OLD path does (counters incremented, state cleared, logs emitted, caches invalidated) against the NEW path — every side-effect the old path performed must be performed (or deliberately dropped with a noted reason) by the new path. Silent bookkeeping drift between sibling paths is the failure mode. <!-- c4:T69 --> A change that lets a new actor write a row (a takeover, a merge, a claim) lists, in its own commit, every mark or cached decision about that row taken before the change can run, and re-checks each at its next write.
- [ ] **Negative-path invocation (AC 5.1)**: exercise the failure/empty/reject branch, not just the happy path — feed the malformed / empty / out-of-range / unauthorised input and confirm the code takes the intended negative branch (raises, returns the error shape, skips-clean). A gate only proven on the happy path is unproven. <!-- c4:T21 --> A gate-BLOCKS claim is proven only by a proof that attempts the real protected action (push, write, publish) and shows the refusal.
- [ ] **Invariant coverage parity (AC 5.1)**: for every named invariant the Issue claims to enforce, confirm a test or assertion actually covers it (count invariants stated vs invariants asserted; any stated-but-unasserted invariant = gap).
- [ ] **Post-merge doc/mirror sweep (AC 5.1)**: after the change, re-grep the doc tree + mirror manifest for references to what changed (renamed symbol, moved file, changed value) and confirm every reference resolves post-change. Any cleanup commit or operator-confirmed fix triggers a focused re-audit swarm scoped to what it touches (a fix is itself a change that can introduce a regression — re-audit, don't assume).
- [ ] **Writer→reader frontend trace (conditional, AC 5.14)**: for any Issue that changes a JSON field type, dict structure, enum value set, or HSET key — dispatch a dedicated writer→reader frontend trace: `grep -rn <field_name>` across all frontend/consumer source directories; verify every consumer handles the new shape AND remains backward-compatible during the deploy window. Skip-clean if no backend response shape changed. Also fires when an AC delivers operator-facing text/UI content with no backend shape change: the Workflow/E2E tier asserts the RENDERED FRONTEND (screenshot or DOM text), not backend emission.
- [ ] **External-store write lifetime audit (conditional)**: every new write to an external key/value store either carries an explicit TTL/expiry matching the service's documented lifetime contract, OR documents inline why a lifetime-less write is correct (self-cleaning command key, bounded queue, intentional-persistent counter). Skip-clean if the diff adds no external-store write.
  (Store shapes in scope: a cache-client `SET`/`SETEX`/`HSET` — e.g. Redis — a message/queue-broker write, or any keyed write to a store whose entries are not reclaimed by the owning process. Orphan-key leaks are the failure mode: Issue #1470 shipped two such writes and both surfaced only at Stage-5 adversarial audit.)
- [ ] **Marker-substring enumeration (AP #24, #477 Phase 4 AC 4.4)**: if the change introduces, modifies, or removes a marker substring (error-message partition, counter name, diagnostic flag, feature-gate literal, status-enum value, log-line prefix, partition key), run `grep -rn -F '<exact_marker_substring>' src/ tests/ scripts/ --include='*.py'` (or per-language equivalent) and confirm the count matches the Stage 1 baseline recorded in the Issue body as "Known Emit Sites: (N)". Mismatch = FAIL — either implementation added emission sites that should have been in scope (expand scope) or removed sites that shouldn't have changed (revert removal). Skip-clean if no marker substring change in this Issue. Canonical rule: `ANTI-PATTERNS.md` AP #24 (Marker-Substring Changes Without Full Emit-Site Enumeration); cross-reference: `STANDARDS.md` "Marker-Substring Discipline".
- [ ] **(VL-0) Shape-Change Caller Sweep (AC 4.3)**: before any commit renaming a symbol / restructuring a data shape / modifying default behaviour, `grep -rn <old_name> . --include="*.py" --include="*.ts" --include="*.md"` returns zero hits (all updated). Applies to: function renames, Redis key schema changes, CLI flag renames, response-shape restructures. **Concept-level wrapper-consumer pass:** for a wrapper OUTPUT-CONTRACT change, also grep `scripts/` and `../scripts/` for the ROLE the changed output plays, not just its name, before declaring "no consumer affected". <!-- c4:T61 --> A behaviour change to a validator, parser or gate also sweeps every doc surface describing it in the same commit. A change that withdraws a promise greps every sentence of every legal page and email for it, not only the table it edited.
- [ ] **(VL-1) Phase-deferral scan (AC 4.6)**: `grep -rE "Phase [0-9]+ (will|to|owns) " src/` must return zero hits before Gate 1.
- [ ] **(VL-2) Multi-channel state audit (AC 4.6)**: for any refactor adding a success channel to a state field, enumerate all channels and assert a CLEAR/reset site exists on each channel.
- [ ] **(VL-3) Helper coverage cross-check (AC 4.6)**: for any AC delegating work to a script, run `grep -n <enumerated_targets> <script>` and confirm each target is reached by the script.
- [ ] **(VL-4) Full-diff scope (AC 4.6)**: run pattern checks against `git diff <merge-base> HEAD --name-only` output, not an in-memory file list. **Doc-lane:** `sst3-doc-lint` every changed `*.md` in that name-list (edited AND new); diff its FINDING-COUNT against an origin/main baseline run of the same files.
- [ ] Config/infra shapes require an actual `workflow_dispatch` or PR-trigger CI run, not only a construction proof. <!-- c4:T25 --> Gate 1 runs every checked-in suite family locally when CI is dark (minutes exhausted, workflows disabled, branch not triggered) and records each family's count; the CI run is recorded as owed, never claimed.
- [ ] **Three-Tier test gate (canonical — Leader.md + SST3-solo.md defer here; #484 T4.1)**. the operator's rule (verbatim Source block, STANDARDS.md "Three-Tier Testing Framework"): the three tiers compose, none substitutes — "3 forms as they work together". **BUILD: always all 3** (every change ships with Unit + Workflow + E2E tests that EXIST — no "this is only a unit, skip 2/3" exemption at authoring time). **USE: all 3 RUN (fire & pass) every change** (operator directive dotfiles#528 — SUPERSEDES the prior "scope-matched fire" rule; E2E may be *sized* to the change — a small backtest, or an actual execution change + cleanup — but it still RUNS; the ONLY non-run is a tier recorded `structural-inapplicable: <reason>`, rare). For EACH of Unit / Workflow / E2E record (a) the **file:line of the checked-in test** (exists) AND (b) the **pass/fail of actually RUNNING it** for this change — a tier missing either = FAIL. Record the required tier-evidence line (defined ONCE in STANDARDS.md "Three-Tier Testing Framework"): `tiers: U=<pass|fail|structural-inapplicable:reason> W=<…> E2E=<…> M=<reddened+control-green|unproven|n/a:no-gate-in-diff> | BUILD-evidence:<file:line per tier>` — the `M=` field is the #567 PROVE clause (gate-bearing diff carries its mutation result per the three-tier-testing.md USE clause; `M=unproven` blocks like a `fail`). The project test suite — what "no regressions" means — is the union of the checked-in Unit + Workflow + E2E tests, NOT a synonym for any single tier (STANDARDS.md glossary).
  - [ ] **Unit Tier — cog/piston QC** (canonical: STANDARDS.md "Three-Tier Testing Framework" → Unit Tier + "Test-Prod Call Coverage Discipline"). BUILD: every changed/added unit (public callable / response-payload field / config key) has a checked-in test that exercises it — the call-seam gate; an untested unit is a piston nobody QC'd. USE: RUNS this change — record `U=pass` + the test file:line; `structural-inapplicable: <reason>` only for a diff with genuinely no unit surface (e.g. pure-doc / pure-prose governance edit). Run the project test suite here — no regressions.
  - [ ] **Workflow Tier — the assembled engine** (canonical: STANDARDS.md "Three-Tier Testing Framework" → Workflow Tier; ANTI-PATTERNS.md AP #18 "Smoke-Tested Pipeline Shipped Without End-to-End Sample Run (Workflow-Tier validation)"). BUILD: a workflow/integration test + the AP #18 real-CLI sample-invocation artefact exist for the component. USE: fires when the change affects how units connect — pipeline / backtest / SL1 / SL2 / orchestration / CLI-wiring / cross-module function-arg propagation / **persistent-state write (JSONB schema mutation, SQL literal drift across SET and READ sites, DB column rename, enum-value drift)** / **any `../scripts/sst3-*.sh` wrapper change**. When it fires: a REAL-CLI sample invocation (service shapes: 8-item liquid basket against real DB; wrapper-script shapes: ≥3 repo shapes auto_pb / voice-doc-repo / dotfiles + raw-tool counter-query for recall comparison). Exit code 0 alone INSUFFICIENT — verify row-count landed, downstream consumers succeeded, contamination audit OK, wrapper-vs-raw delta within tolerance. Mocks MUST assert `call_args.kwargs[...]` explicitly (a `**kwargs`-swallowing mock proves nothing). Document the sample log path + verification queries + wrapper/raw delta in an Issue comment. USE: RUNS this change — record `W=pass` + the workflow/AP#18 sample artefact file:line. A pure single-unit change still RUNS its workflow/integration coverage (it stays green); `structural-inapplicable: <reason>` only when the change has genuinely no cross-unit / wiring / sample surface (rare; e.g. a pure-doc diff) — NOT the superseded "this is just a unit fix, skip it".
  - [ ] **E2E Tier — the driving test** (canonical: STANDARDS.md "Three-Tier Testing Framework" → E2E Tier; ANTI-PATTERNS.md AP #26 "E2E System Verification"). BUILD: an end-to-end/system test exists for the system path. USE: fires when the change affects how whole components connect end-to-end — multi-component / cross-repo contract / orchestration / persistent-state spanning the pipeline / a contract a real downstream consumer reads. When it fires: exercise against the real system (real DB + real downstream consumer + live invocation); confirm the downstream consumer accepted the real contract and the system produced the intended result end-to-end (real-DB schema / enum / contract drift surfaced if present). A Workflow-Tier sample alone is NOT sufficient for a system-scope change — the three compose, none substitutes. USE: RUNS this change — record `E2E=pass` + the system-test file:line; *sized* to scope (whole-system change → full real-system; unit/workflow-scoped change → a small backtest or an actual execution change + cleanup that drives the changed path end-to-end). `structural-inapplicable: <reason>` only when the change has genuinely no end-to-end surface (rare) — NOT the superseded "single-unit change, skip it".
- [ ] **Quality scan**: No inefficiencies, no bottlenecks, no memory leaks, no dead code, STANDARDS.md compliant
- [ ] **Raw-tool cross-validation gate**: if a check above used `sst3-code-*.sh` output as load-bearing evidence, dispatch ONE Layer-3 subagent to run the raw equivalent (grep / ast-grep / find / git log): wrapper 0 + raw ≥1 = recall miss, FAIL that check until reconciled; wrapper N vs raw M with `|N-M|/max(N,M) > 0.2` = wrapper-lane SUSPECT, file a `solo/wrapper-fix-<bug>` Issue. **Wrapper-self-change variant:** if the diff changes a wrapper's own output contract, scope the raw counter-query like the NEW contract, split any delta into scan-scope artifact vs real defect before filing, and exclude the wrapper's own file from its self-referential file counts.
- [ ] **Mirror-lane verification (AP #9)**: a change touching a canonical file with `SST3/drift-manifest.json` mirror entries (lane B) or CLAUDE.md's SST3 section (lane A) must exercise BOTH lanes. Lane A: `python3 $SST3/propagate-template.py --all --dry-run` exit 0 (every consumer's SST3 section resolves; drift shows only as its stderr `N would update` line, 0 only post-merge). Lane B gates: `python3 $SST3/propagate-mirrors.py --validate <the branch's canonical files>` exit 0 (no self-row drift); pass `git diff --name-only origin/<default>...HEAD` — with no file argument on a committed tree it prints "nothing to check" and exits 0. From a worktree, consumer-row drift is advisory until the post-merge `--apply`, and a canonical file missing from the manifest is a WARNING whose gate is `check-manifest-completeness.sh` (c4:T16). `propagate-mirrors.py --dry-run` is report-only (`do_dry_run` returns `EXIT_OK` even with drift). Either lane failing blocks Gate 1 until reconciled; skip-clean when no mirror-tracked surface is touched.
- [ ] **Test-CI-wiring (AC 3.14)**: for every new test file introduced by this issue, confirm it appears in a CI workflow glob or pre-commit hook pattern — `grep -rn <test-file-path-or-parent-dir> .github/workflows/*.yml .pre-commit-config.yaml`; zero hits = FAIL (wire the test into CI before Gate 1 passes).

<!-- stages: 4 -->
## Per-Stage Feedback Capture

Canonical: STANDARDS.md §Per-Stage Feedback Capture (the single source of truth — schema, channel-separation rule, FP-handling rule, DRIFT ALERT spec, activation-sha gate, post-compact reconstruction protocol, 3-layer enforcement). When creating a new per-issue feedback file, copy the write-time template `<your-dotfiles-clone>/SST3/templates/leader-feedback-template.md` (canonical frontmatter + `## Stage N — <Title>` H2 headings + 10 `**field**:` lines) — never hand-roll the structure (the bare-heading halt class, dotfiles#486/#488). Each stage above ends with a per-stage feedback bullet. Aggregator + reporter + shape-match: see `<your-dotfiles-clone>/SST3/scripts/leader-feedback-aggregate.sh --report | --summarize | --shape-match | --staleness`. Pre-commit hook `sst3-metrics-feedback-present` is Layer A; persistent sentinels under `.sentinels/` (gitignored) are Layer B; the per-stage bullets above are Layer C.

<!-- stages: 4 -->
## Branch & Commit Discipline

Worktree-per-agent is canonical (dotfiles#488 Fix-A; rationale + trigger: the CLAUDE.md "Branch Safety (CRITICAL — DO NOT VIOLATE)" anchor — `EnterWorktree` only activates from a user/CLAUDE.md/memory directive). `NEVER switch branches` mid-implementation is the in-worktree invariant.

```bash
# Isolate: EnterWorktree tool, named solo/issue-{number}-{description}
#   (NOT a bare `git checkout -b solo/...` in the shared clone — #488 Fix-A).

# HARD STOP: NEVER switch branches mid-implementation (in-worktree invariant)
# NEVER use git add -A or git add . — stage files individually

# After EACH file change (in the worktree, on its solo branch)
git add {file}
git commit -m "type: description (#issue)"
git push origin <solo-branch>

# Merge + cleanup — recursion-safe remote fast-forward (Leader.md Gate 2 / #488 AC 1.3):
#   git push origin <solo-branch>:master   # server-side FF of origin/master
#   on non-FF reject: git fetch origin master; git rebase origin/master (in worktree); retry (<=3, NEVER --force)
#   NO shared-tree branch-switch / local-merge / reset (except the ff-only catch-up of the
#   runtime canon clone after a dotfiles push: gate-2-merge.md "Branch-switch invariant").
# Then: ExitWorktree action:keep until push landed (git ls-remote origin master == solo tip),
#   ExitWorktree action:remove; git push origin --delete <solo-branch>; git fetch --prune
```

<!-- stages: 4 -->
## Context Management

**Context**: 1M window (Opus/Sonnet), 200K (Haiku). Handover at ~50% remaining (~500K of 1M / ~100K of 200K) — on long work, auto-`/handover` + compact + continue; never operate below 50% remaining. Canon size: `load-stage-rules.sh <N> | wc -c`. Research budget <30% Stage 1. At the ~50%-remaining trigger (or any planned compact), run `/handover` to write the structured pre-compact handover to `~/handover/` (survives compaction AND a WSL VM reboot, auto-pruned after 7 days) — re-surfaced post-compact by the SessionStart hook, NOT persisted to auto-memory.

<!-- stages: 4 -->
## Quality Standards

See STANDARDS.md (mandatory read). Key rule labels: Quality First, JBGE, LMCE, Fail Fast, Fix Everything, Investigate Before Coding, Wiring Verification, Never Replace — ADD Alongside.

<!-- stages: 2 -->
## Templates

- **Issue Creation**: `../templates/issue-template.md`
- **Execution Template**: `../templates/subagent-solo-template.md`
- **User Review**: `../templates/user-review-checklist.md`
- **Chat Handover**: `../templates/chat-handover.md`

<!-- stages: 4 -->
## Checkpoint Format

Post to Issue after each phase:

```markdown

<!-- stages: 4 -->
## Phase X Checkpoint

**Completed**:
- [description of phase work]

**Files Modified**:
- `path/to/file.ext` (lines X-Y)

**Next**:
- [upcoming work]

**Context**: ~X% used
```
