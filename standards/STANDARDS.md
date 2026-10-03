# Engineering Standards

<!-- stages: 4 -->
## Foundational Philosophy

**Quality First**: SST3 sets the execution standard for all projects built with it.

**Quality Attributes**: Maintainability, Accuracy, Standardized, No Regression, Transparency, Intentional, Enforcement, Reusable, Predictability, Testability, Robustness, Reliability, Discoverability, Prevention > Cure.

**ROI = Quality Execution** (not token/time savings). Token efficiency is a byproduct, not the goal.

**Clarity > Brevity** (Issue #141): Prune based on quality (JBGE + LMCE), never to hit a number. Clear instructions prevent rework.

<!-- stages: always -->
## Core Principles

<!-- stages: 4 -->
## Achieving Quality

**Quality Attributes Table**: AI-optimized reference for execution standards

| Attribute | Definition | How to Achieve | Enforcement |
|-----------|-----------|----------------|-------------|
| **Maintainability** | Self-cleaning, organized, evolves without cruft | Follow housekeeping checklists, document files, archive superseded | Verification Loop, pre-commit hooks |
| **Accuracy** | Conforms to evidence, results, factual requirements | Verify against actual values, test with real data, cite sources | Stage 1 Research, Verification Loop |
| **Standardized** | Consistent patterns, uniform naming, predictable organization | Use templates, follow tool standards, maintain structure | issue-template.md, Tool Standardization |
| **No Regression** | Changes don't break existing functionality | Check call sites, run existing tests, verify compatibility | Verification Loop, pre-commit hooks |
| **Transparency** | Factual reporting, researched claims, honest analysis | Provide evidence not claims, challenge assumptions, document sources | Critical Thinking, Ralph Review evidence |
| **Intentional** | Deliberate decisions, not accidental changes | Plan before implementing, document rationale, avoid scope drift | Stage 1 Research, Triple-Check Gate |
| **Enforcement** | Validation through checkboxes, gates, scripts - not honor system | Verification Loop, Ralph Review, pre-commit hooks | SST3 is Enforcement principle |
| **Reusable** | Designed for reuse, not one-off solutions | Modular components, clear interfaces, avoid hardcoding | Modularity, Codebase Review |
| **Predictability** | Expected results, no surprises, consistent behavior | Document behavior, test edge cases, fail fast with clear errors | Fail Fast, Verification Loop |
| **Testability** | Code designed to be verifiable and validated | Write tests first, isolate dependencies, provide test fixtures | Verification Loop, regression tests |

**Behavioural enforcement** (the table answers "what does quality mean?", this answers "what must I DO?"):

| Action | Enforced by |
|---|---|
| Use existing before building | Stage 1 Research, Codebase Review |
| Complete scope fully (no partial) | Verification Loop (fully working) |
| Self-clean and housekeep | Cleanup Requirements, pre-commit hooks |
| Leave codebase better than found | Stage 5 Post-Implementation Review |
| Realign when scope drifts | Triple-Check Gate (Stage 3) |
| Regular self-check vs original plan | Phase checkpoints |

**JBGE** (Just Barely Good Enough): Document only what prevents problems.

**Discoverability Requirement** (Issue #119): All SST3 files MUST be discoverable from CLAUDE.md in EVERY repo.
- **Chain**: CLAUDE.md → STANDARDS.md / WORKFLOW.md, or a stage's canon via `load-stage-rules.sh`
- **Validation**: the reviewer, at Gate 3 (user-review-checklist §6)
- **Exception**: CLAUDE_TEMPLATE.md (template), .sst3-local/ (project-specific)
- **Enforcement**: an unreachable file is a Gate-3 finding; no script gates this (#577)

**Don't Explain Claude to Claude** (Issue #119): Document YOUR rules/decisions/patterns. Not model capabilities or standard practices. ✓ "Ralph Tier 1 uses haiku for surface checks" ✗ "Haiku is fast"

**LMCE** (Lean, Mean, Clean, Effective): JBGE defines *what* to keep; LMCE defines *how* to deliver it.
- **Lean**: Remove if removable without breaking. Keep only if ROI > 1x — EXCEPT rules guarding irreversible-impact actions (public-repo privacy leak, force-push to main, branch/data deletion, secret exposure, voice contamination). These are kept by **impact-ROI not count-ROI**; cite the rule + the incident, never delete. Sections in this regime carry an `<!-- impact-roi-carve-out -->` HTML comment marker (Cut #5, AC 1.10/1.11).
- **Mean**: Actionable commands. Strip "consider", "might", "it's important".
- **Clean**: Findable in <30 seconds. No >10-line blocks without headers/bullets.
- **Effective**: Root cause, not symptoms. Simplest permanent solution.

**Pruning rule**: Keep examples that prevent real problems and decision thresholds. Remove AI-known explanations and motivational language. If pruned content caused problems, restore it.

See: `ANTI-PATTERNS.md` for top 5 recurring problems (Issue #79)

**AI-First Documentation** (Issue #153): Internal docs optimize for AI consumption.

**Three-Category Framework**:

| Category | Examples | Rule |
|----------|----------|------|
| Internal AI-to-AI | WORKFLOW.md, checklists | Remove tutorials/motivation. Keep commands/criteria/guardrails. |
| User Touchpoints | PR diffs, Issue comments | Keep human-readable, 30-second scan. |
| Hybrid | STANDARDS.md, WORKFLOW.md overview | Tables+bullets for AI, context for user. |

**Decision Rule**: User ever reads it → keep human-readable. AI-only → optimize for AI.

**Remove from AI-to-AI**: tutorials, "Purpose" sections, motivational language, teaching examples.

**Always Keep**: checklists `[ ]`, commands, decision thresholds, MANDATORY/CRITICAL/NEVER tags, file paths, issue refs, tables, DO/DON'T, pattern→fix pairs, If X→do Y recovery steps.

**Compression, not deletion** (Issue #124): preserve all functional content.

<!-- stages: 2 -->
### Skill Authoring

Skills are AI-for-AI. A skill (`.claude/skills/*/SKILL.md` + companions, `.claude/commands/*`) and the SST3 harness canonical (STANDARDS / ANTI-PATTERNS / WORKFLOW / CLAUDE.md / templates / ralph / reference / stage-extracts) are "Internal AI-to-AI" artifacts — write them lean per the Three-Category rule above. **STRIP THE STORY, keep the RULE.**
- Beyond the "Remove from AI-to-AI" list above, also **remove**: backstories, incident narratives ("this broke X", "made the operator angry"), and the operator's words requoted as a story to justify a rule.
- Beyond the "Always Keep" list above, also **keep**: the mechanic/how, verify-commands, and a SHORT load-bearing why (the guardrail that prevents recurrence).
- A short provenance tag (issue/AC ref) that prevents future-audit re-litigation stays; the narrative around it goes.
- **Voice carve-out**: preserve voice-guards (`<!-- iamhoi -->`) and operator/business-voice prose verbatim — never strip voice content as "backstory".
- **Impact-ROI carve-out**: sections marked `<!-- impact-roi-carve-out -->` (privacy-leak / force-push / data-deletion / secret-exposure / voice-contamination guards, per LMCE) KEEP their cited incident — compress wording, never delete the cite.
- **Operator-facing carve-out**: a companion doc read by the operator (User-Touchpoint / Hybrid per the Decision Rule above, e.g. a "reading notes" reference) keeps its human-readable voice — the AI-for-AI lean rule does not flatten it.
- Exemplar: dotfiles `ca887503` (verbose→lean blog social-card — dropped the quote + incident, kept the directive + `head.html` mechanic + cache-bust steps).

<a id="quality-mantras"></a>

<!-- stages: 2 -->
### Quality Mantras (Doctrinal — 9 items)

These 9 mantras are the canonical authoring + audit criteria invoked verbatim from every Stage of /Leader, the issue template's Quality Mantras section, and the user-review-checklist. WORKFLOW.md Stage-3 surfaces a 5-item operational subset; the doctrinal list lives only here.

- No inefficiencies, fix optimisation opportunities
- Reliable and robust (not prone to breakage or failing)
- Dedupe duplicate codes
- No bottlenecks
- Runs super fast and safe
- No memory leaks using preventions
- Follows STANDARDS.md
- No false positives — everything real gets fixed
- No such thing as high priority or low priority — all must be fixed

<!-- stages: 4 -->
## Engineering Practices

<!-- stages: 4 -->
### Use Existing Before Building
- Research existing libraries/packages FIRST
- Evaluate: popularity, maintenance, license, security
- Build custom only when existing solutions don't fit
- Document why existing solutions rejected

See: `../workflow/WORKFLOW.md` (Stage 1 — Research) for detailed library research process.

<!-- stages: 1,2,4 -->
### Append vs Extend Rule

**Principle**: Appending to a `CLAUDE.md` (or any session-loaded entry-point doc) is the **last resort**, not the default. The first move when adding context, rationale, runbook prose, or design notes is to ask: "is there an existing `docs/<area>.md` that is the right home — and can I extend it and leave a one-line pointer here?"

**Why**: session-loaded entry-points (CLAUDE.md, MEMORY.md index, top-of-template prose) live in the model's context window on every turn. Every paragraph appended there costs tokens on every future session AND increases the chance the truly load-bearing content gets skim-scrolled past. Evidence: Issue #1494 trimmed one CLAUDE.md from 58.5k → 28.1k (51.8% reduction) after multiple refactors each appended 1-3k of WHY-prose to `## Project-Specific Notes`. Without this rule, the same drift recurs every 12-18 months.

**Decision procedure** (3 steps, applied when ANY of: drafting a new paragraph for a CLAUDE.md / extending `## Project-Specific Notes` / writing >10 lines of WHY-prose in any entry-point doc):
1. **Is there a destination doc?** `ls docs/` + `grep -l '<topic>' docs/`. If a doc on the topic exists → extend it; add a one-line pointer in CLAUDE.md only if the topic was not already referenced.
2. **No destination doc, but topic deserves one?** Create `docs/<area>.md` with the new content; add a single one-line pointer in CLAUDE.md.
3. **Genuinely belongs in CLAUDE.md?** (per-session reminder, mandatory-reading list addition, boundary marker rule, branch-safety invariant.) Append, but keep it to the minimum that survives compression — link out to `docs/` for detail.

**MUST NOT**:
- Append 1-3k of WHY-prose to `## Project-Specific Notes` "because it's project context" — that's how the 58k bloat happened.
- Duplicate content between CLAUDE.md and `docs/<area>.md` (canonical lives in one place; the other carries the pointer).
- Use CLAUDE.md as a changelog ("decision: X, after Y") — git history + Issue body are the audit surface; CLAUDE.md is the session-load surface.

**Enforcement**: in-context reminder immediately above the boundary divider in `../templates/CLAUDE_TEMPLATE.md` `### Append vs Extend` subsection (catches Claude at session start; propagated to every consumer CLAUDE.md by `propagate-template.py`); this rule (catches at Stage 1 / Stage 4 entry via the Leader + SST3-solo mandatory-reading chain). Companion: AP #10 "Failure to Search Before Adding" (this rule is its entry-point-doc instantiation).

<!-- stages: 4 -->
### Critical Thinking & Honest Analysis

**Critical Thinking**: AI must challenge ideas with evidence, not validate blindly.

**DO**: Disagree with evidence when flawed. Find holes/edge cases/trade-offs. Surface risks early.
**DON'T**: Validate blindly or cherry-pick positives.

**BAD**: "Good idea! I will proceed." **GOOD**: "Method X is O(n^2); Method Y is O(n). Recommend Y unless constraint requires X."

See: ../workflow/WORKFLOW.md (Stage 1 — Research) for research-specific critical thinking

<!-- stages: 4 -->
### Never Assume — Always Check

**Principle**: Read the actual source before drawing conclusions. Assumptions cause silent errors. User assertion + handover claim are NOT exceptions — they trigger source verification, not source bypass.

**DO**: Read before editing. Check actual values. Verify function/pattern exists before referencing.
**DON'T**: State file contents without reading. Assume variable names or API shapes from memory. Skip verification. Say "you're right" before checking. Validate user assertions without grepping source.

**Pattern**: When in doubt → Read first, conclude after.

**User Assertion = Immediate Source Verification** (merged sub-rule; also covers handover claims and post-compact recovery summaries)

**Principle**: User assertion = verify source IMMEDIATELY. Do not debate; do not validate without checking. Source file is ground truth.

**Rules**:
1. **User asserts → grep source immediately**, with multiple synonyms and partial-figure variants. Don't grep just `676K`; grep `676|redhill|3fp|digital realty`.
1b. **Handover claim → grep source immediately** (Theme 1, #477): same discipline applies to claims sourced from prior-research handovers, post-compact recovery summaries, or memory entries — not just user assertions. When entering a session with a handover that names file:lines / counts / table sizes / function-existence assertions, the main agent extracts 3-5 headline claims and verifies each via raw-grep / direct read BEFORE dispatching the Stage 1 swarm. Document drift in the research file as "handover claim X corrected from Y to Z before swarm dispatch". Memory ≠ source of truth; a handover is a starting hypothesis, not a frozen contract. Cross-reference: Leader.md Stage 1 step 1a.5 (PRE-SWARM SOURCE-VERIFICATION GATE for handover claims); ANTI-PATTERNS.md AP #14d (Scope-gap blindness — Stage 1 research specific).
2. **Never say "you're right" before checking**. Verification is the response, not validation.
3. **Never debate or push back** based on a subagent's earlier finding. The subagent could have missed it.
4. **Trust structured data** (tables, PO lists, project enumerations) over narrative paraphrases or subagent summaries.
5. **Report verbatim with line numbers**. No editorial. If the source genuinely contradicts the user, quote the source verbatim and let them decide.
6. **Cross-check swarm subagent claims against source before applying ANY removal or change**. Two swarm subagents disagreeing → read MASTER directly. Don't pick the "safer" recommendation.

**Anti-patterns**:
- ❌ "You're right!" followed by an edit you made without checking
- ❌ Removing a claim because a subagent said "not in MASTER" without grepping yourself
- ❌ Trusting v2 swarm output over v1 swarm output without reading source
- ❌ Grepping a single narrow term and concluding "not found"
- ❌ Debating with the user from memory ("I'm sure I checked that")

**Enforcement**: Every fact-removal, every dollar-figure change, every date change, every claim deletion must be preceded by a direct source read. The swarm recommends; you verify; the source decides.

<!-- stages: 4 -->
### Factual Claims Must Have Provenance

**Principle**: No number without a source. Every quantified claim in documentation, issue bodies, commit messages, or review comments must be backed by a verifiable source.

**Rules**:
- Every number must have a **verification method**: a command that produces it, a document that cites it, or a calculation that derives it
- Estimates must be labelled as estimates ("~6 months", "up to $1.25M") — never presented as precise facts
- "Seems reasonable" is NOT a source. If you cannot reproduce the number, do not write it
- When researching facts, use **multiple independent sources** (code, git history, external documentation) — never trust a single unverified claim
- AI agents must use subagents to **research and verify** before stating facts — read the actual code, run the actual command, check the actual data

**Verification Methods** (in order of preference):
1. **Reproducible command**: `git log --oneline | wc -l` → "10,385 commits"
2. **API query**: `gh issue list --state all --json number` → "1,309 issues"
3. **Code reference**: `grep -c "def test_" tests/` → "N test functions"
4. **Document citation**: "per a documented external citation; see private VOICE_PROFILE for source"
5. **Calculation**: "(total - open) / total = 99.4% close rate"

**Anti-patterns**:
- ❌ "3-5 concurrent agents" with no measurement or architectural derivation
- ❌ "catches 85% of bugs" with no data source
- ❌ "average of $1.25M" when source says "up to $1.25M"
- ❌ Repeating a number from another document without verifying it is still accurate

**Enforcement**: Ralph Review Tier 2 (Sonnet) — Evidence Quality section. User Review Checklist — Gap Analysis section.

<!-- stages: 1 -->
### Research Must Be Applied Collectively, Never Singularly

**Principle**: Every change must integrate ALL relevant sources in the same pass. Single-source edits silently override constraints from every other source. (Applies to: code, CV, config, any multi-source artefact.)

**Rules**:
1. Before any edit to a multi-source artefact, load ALL referenced research/profile/memory files. Not the relevant one. All of them.
2. Check every proposed change against every loaded source in the SAME pass, not sequentially. Any failed check = invalid edit.
3. Conflicts between sources must be resolved EXPLICITLY via documented conflict-resolution rules. Never silently pick one.
4. New audit/subagent output is ADDITIVE to the collective, never replacement.
5. The mandatory-reading list at the top of any skill / CLAUDE.md is non-negotiable. Reading 1 of N = reading 0.
6. Commit messages must name every source consulted. Shorter than the mandatory-reading list = invalid edit.
7. **SST3 self-reference**: never edit a STANDARDS / ANTI-PATTERNS / workflow / template / ralph / hook file without cross-checking the rest of the SST3 corpus first. The corpus governs itself.

**See ANTI-PATTERNS.md #9** for evidence, root cause, worked examples, and self-healing.

<!-- stages: 1,2,3,4,5 -->
### Subagent Orchestration Discipline

**Principle**: Use MANY subagents in LAYERS, cross-checking from different angles. Verify every finding against source. Document proof method inline.

**Scope gate (read FIRST — this whole discipline is for SUBSTANTIVE work only)**: a swarm governs audits, migrations, cross-repo reviews — work that genuinely spans many files/claims. A **trivial, yes/no, single-file, or single-fact question is NOT swarm work**: answer it directly with one `grep` / read / `git` command, SOLO. Before launching ANY swarm or Workflow, ask "could one command answer this?" — if yes, just run it. Over-swarming a trivial lookup burns the operator's tokens for ZERO added correctness and reads as not thinking (dotfiles#534: 6 agents fired at a one-line yes/no about a single artifact — a single `grep` answered it; operator emphatic). "Ultracode" / "be thorough" raises the bar on substantive work; it does NOT license swarming trivial questions. Match agent count to the QUESTION, not to a standing default. <!-- c4:T60 --> On Issue work, a Scope-gate skip rationale is written into the Issue body (one line: the skipped swarm or stage, and why one command answered it), not only the feedback file.

**Rules**:
1. **Subagent count is dynamic**: cover every directory, file, and claim category line-by-line. NEVER 2-3 as default. Size to work (e.g. 12 categories → ≥12 subagents, 20 files → 4-5 subagents). Stinginess produces shallow skims.
2. **Layered cross-checking**: dispatch a second wave of subagents from a DIFFERENT angle to verify the first wave. Layer 1 = "find the violations". Layer 2 = "verify each violation isn't a false positive". Layer 3 (if applying changes) = "verify the proposed fix doesn't break anything else".
3. **Different angles per layer**: layer 2 must NOT use the same prompt or framing as layer 1. Different lens = different blind spots = real cross-check.
4. **Main agent verifies, never assumes**: every subagent finding is read against source by the main agent before being acted on. The swarm recommends; the main agent verifies; the source decides.
5. **Factually provable AND documented**: every claim/figure/decision must be provable AND the proof method (file:line, command, query, source-doc reference) must be documented inline so future audits can re-verify it without re-deriving from scratch.
6. **Prevent false-positive flagging by design**: when a section is intentional architectural design (defence-in-depth, intentional duplication, specialised verbosity), document it inline so future audits skip it.
7. **No stingy exceptions — WITHIN substantive work only**: once the scope gate confirms a task IS substantive, "to save time" / "to save tokens" are NOT valid reasons to under-cover its real angles — size to the angles. This does NOT invert the scope gate: a genuinely trivial / yes-no / single-fact question is answered SOLO with one command, never swarmed. The rule is "don't skimp on a real audit", not "swarm everything"; match scale to the QUESTION.
8. **Orchestrator MUST embed wrapper-lane caveats in subagent prompts, not just in the RESULT schema**. When dispatching a subagent that may invoke wrapper-lane queries, the orchestrator's prompt MUST explicitly name the known caveats: (a) `mcp_graph_available: yes|no` as first RESULT line (AP #19; under wrapper-lane this is always `no` per Issue #445); (b) `search` is keyword-only — there are no embeddings; verify with synonym sweep before any "no match" conclusion; (c) current `last_updated` (repo HEAD time, not query freshness — wrapper-lane is stateless); (d) inner-engine availability (exit 127 = ast-grep / ripgrep / jq missing). The RESULT schema is a receipt check — the prompt-embedded reminders are the primary trigger. Author-time drift (orchestrator writes the rule but forgets to embed it in dispatched prompts) is the documented failure mode (round-5 S1 + N45 — 2× corroboration).

**Procedural minimum** for any audit-driven change to a multi-source artefact:
1. Layer 1 swarm (sized to cover every angle of the audit): identify violations
2. Layer 2 swarm (sized to verify every layer-1 finding): false-positive sweep — verify each violation isn't documented architectural design
3. Main agent: read source for every confirmed violation before applying any edit
4. Apply edits with inline proof-method comments where helpful
5. Layer 3 swarm (3-5 subagents): verify applied edits didn't break cross-references or surface new violations

**See ANTI-PATTERNS.md #14** for the no-discipline failure modes.

#### Default Dispatch Mechanism — the Workflow tool (#514)

**Rule**: the dynamic **Workflow tool** is the DEFAULT dispatch mechanism for every `/Leader` parallel swarm (Stage 1 research, Stage 2 draft-check, Stage 3 sanity-check, Stage 5 post-implementation audit). Author the swarm inline and run it via the Workflow tool; do NOT hand-dispatch Agent/Task subagents for these swarms. Plain Agent/Task dispatch is retained ONLY as a documented fallback for a trivial single-angle check (one reader, no cross-check layer). This supersedes #507's optional/`ultracode`-gated framing: "optional" had no reliable trigger — the imperative "Launch parallel subagents" overrode the soft "MAY", so the feature never fired even when explicitly directed. Ralph Review tiers (sequential Haiku→Sonnet→Opus, restart-on-fail) and the AP #20 "Layer 1/2/3" checkbox-MCP enforcement gates are NOT swarms — they stay Agent/Task and are NOT converted. The escalation Workflow is not a Ralph tier and does not convert Ralph's sequential tiers to a swarm: it is a distinct dispatch that fires when the restart bound is reached, produces fixes, and hands back to Ralph for tier verification.

**Monitoring (AP #16)**: a backgrounded Workflow run is launched-not-done. The orchestrator MUST **monitor** the Workflow end-to-end: launch → await the completion notification (or poll its status) → read the run output → verify every finding against source (AP #14) before acting. A `wf_…` run id is recorded in the stage checkpoint as the audit trail. "Started" is never "complete". <!-- c4:T15 --> Workflow legs write to script-named paths, never leg-chosen ones. Narrative legs return free text ending in a fenced RESULT block or, if schema'd, cap string fields at 1,200+ chars. Never put `head`/`tail` between a writer and a load-bearing exit code (use `PIPESTATUS` or a full-output file; the Bash Output Budgets `tail -n 100` is for logs, not gating); gate chained commands (`set -e` or per-step exit checks). A pausable run saves each leg's result to a file and ends with a continuation script over them; never edit one prompt of a concurrent fan-out and resume (later legs re-run live). Syntax-check the script or run a 1-agent smoke leg before full dispatch.

**Scope-scaling (no runaway)**: making the Workflow tool the default for four stages does NOT relax AP #14 scope-scaling — swarm size **matches coverage** (one subtask per real angle / directory / claim-cluster), neither a fixed cap nor unbounded. The Workflow auto-scales DOWN for tiny jobs (a Stage-2 draft-check needs few subtasks) and UP for large audits, always governed by AP #14 "no stingy, no runaway". **Kill/timeout seam for a frozen background Workflow** (freeze-detection parity with a hung subprocess): a backgrounded Workflow run surfaces a task-id + a `wf_…` run id. Monitor it per AP #16 — await the completion notification (the harness re-invokes you when it finishes) or watch `/workflows` / read the run's task-output file. If a run exceeds its expected wall-clock with NO completion notification AND `/workflows` (or the output file) shows no forward progress, treat it as frozen: stop it with `TaskStop <task-id>`, then re-author with a smaller fan-out (fewer concurrent subtasks) or split the swarm into sequential batches and re-run. Do NOT leave a frozen run unbounded — an un-monitored background Workflow is the AP #16 fire-and-forget failure mode. (Wall-clock baseline: a typical /Leader audit swarm completes in minutes; a run with no notification well past that, and no `/workflows` progress, is the kill trigger.)

<!-- stages: 1,3,5 -->
#### Default Tier Assignment per Swarm Role

**Rule**: when authoring a Workflow-tool swarm, assign each subtask a model tier by ROLE via `agent({model})`, per this static map:

| Swarm role | Tier | Examples |
|------------|------|----------|
| Mechanical extraction | `haiku` | grep / inventory / file enumeration / AP #24 marker-substring enumeration |
| Coverage / synthesis | `sonnet` (default for Layer-1 legs) | Stage-1 angles, Stage-2 draft-check, scope-vs-audit, wiring, dangling-pointer, goal-alignment |
| Adversarial / quality-critical | `opus` | AP #14 Layer-2 cross-check, raw-tools-only, voice-canonical comprehensive-walk, §3-deferral re-litigation, contract/TOCTOU |

**Economics note**: subagents share NO prompt cache — each builds its own prefix from zero (5-min TTL). Uncached-prefix × fan-out is the dominant token cost, NOT reasoning depth. Model tier is the only cost lever the Workflow tool exposes (no effort knob); two adjacent levers are fan-out (AP #14) and per-leg prefix size (a tight scope snippet + ≤5 files shrinks each leg). <!-- c4:T51 --> A swarm cost estimate prices each leg per model tier and per duty delta at its measured cost, never one blended per-agent average, which under-counts the Opus and long-duty legs.

**HARD invariant**: cost-optimisation MUST NEVER tier the verification legs (Layer-2 adversarial / AP #14 cross-check) below Opus. Tiering down a Layer-1 coverage leg is fine; tiering down the cross-check that catches the coverage leg's blind spots defeats the layering.

**Design principle**: start deterministic — a static role→tier map via `agent({model})` + this table. Do NOT build adaptive / budget-aware tiering in v1; ship the deterministic table first.

**OPEN integration-research** (tagged `[research]`, not v1 gates): validate role→tier quality-vs-cost across n>1 real runs; deterministic-table vs adaptive-escalation comparison; token-rate-limit optimisation (Sonnet = fewest raw tokens); confirm no leg needs the 1M window (a Sonnet/Haiku override drops to 200K — fine for lean legs). Provenance: Issue #16. Answered: StructuredOutput reliability by tier ("Workflow Tool Operational Quirks").

<!-- stages: 1 -->
#### Stage 1 Layer-2 Adversarial Gap-Finder Discipline (Theme 8, #477)

**Principle**: Layer-1 swarm finds what's in scope; Layer-2 adversarial swarm finds what Layer-1 missed. Different lens = different blind spots = real gap coverage. Mandatory for infrastructure / governance / cross-cutting Stage 1 research.

**The Layer-2 prompt** (verbatim template): "Layer-1 found X, Y, Z. Find 3 things they missed — either (a) false-positive claims already covered by modern equivalents, or (b) genuine gaps not yet surfaced." Layer-2 prompt MUST differ from Layer-1 (per AP #14c).

**Two failure modes Layer-2 catches**:

1. **False-positive legacy claims**: Layer-1 cites an obsolete API / registry key / convention that has a modern equivalent already in use. Examples (worked examples, surfaced in #477 research):
   - Layer-1 cited Win10 `SetUserFTA` legacy API → Layer-2 surfaces Win11 24H2 modern path: `UserChoice ProgId` registry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts`. Apply: replace SetUserFTA invocation with UserChoice ProgId write.
   - Layer-1 cited deprecated registry key for default-app association → Layer-2 surfaces `dism.exe /Set-DefaultAppAssociation` modern equivalent shipped in Win10+. Apply: prefer dism.exe over registry direct-write.

2. **Scope-adjacent genuine gaps**: Layer-1's angles cover the named scope but miss adjacent surfaces. Examples:
   - Layer-1 swarm covers Stage 1 hooks → Layer-2 surfaces Stage 4 sample-invocation gate also needs the same angle (#477 Themes 1+8 cross-cutting).
   - Layer-1 covers `feedback_parser.py` schema → Layer-2 surfaces `check-closure-loop-applied.py` pre-commit hook also reads the schema (closure-loop integrity gap).

**Main-agent verification gate**: when Layer-2 surfaces a false-positive correction (e.g. "Layer-1 cited X but modern equivalent Y exists"), the main agent MUST verify the equivalence against source before accepting the correction. Document the verification method inline (command run, file:line, URL). Drift between Layer-1, Layer-2, and source = block scope-acceptance until reconciled. Pattern: dispatch a verification subagent with the prompt "Run `grep / ls / Query` against <file>:<line> to confirm whether <Layer-1 legacy claim> or <Layer-2 modern equivalent> is present in the actual codebase. Report file:line + verbatim quote." Both Layer-1 and Layer-2 outputs are recommendations; the source decides (per AP #14c).

**Enforcement**: Leader.md Stage 1 step 2a (Layer-2 adversarial gap-finder MANDATORY). ANTI-PATTERNS.md AP #14d (Scope-gap blindness — Stage 1 research specific).

**Required structural Layer-2 angles (AC 1.8)** — the Layer-2 prompt MUST include these 8 named angles when applicable: (1) **hot/cold path enumeration** — per data-consumption site enumerate cold-path validation, hot-path validation, and revalidation interval; flag any path with cold-path validation lacking hot-path; (2) **async/sync compatibility** — verify the async/sync context of any recommended reuse target matches the call site; (3) **operator-semantics grep** — verify `>=`/`>`/`<=`/`<` in threshold claims against source, not prose; (4) **tool-disambiguation** — when the operator names a specific product/tool, verify exact feature identity against official docs; (5) **self-disconfirmation** — list 2-3 simplest scenarios under which the alleged gap does NOT exist, and verify each against source; (6) **Sibling-pattern enumeration (AP #14e)** — for any finding about a function, pattern class, or family member, enumerate ALL callers / branches / sibling files that could share the same defect class before returning a verdict: extract the CONCEPT and use concept-based grep, not literal-pattern grep. A literal sweep finds only what already shares your vocabulary, so a family member named differently survives it untouched. Mirrors the Stage-5 **Sibling-pattern enumeration (AC 5.3)** angle — deliberate twins, edit both or neither. <!-- c4:T01 --> The sweep covers every absence or completeness claim, not only function-X findings; <!-- c4:T66 --> a retired-identifier sweep adds a data-flow pass over scripts that replay committed run settings into a live run; (7) **Source-as-consumer enumeration (AP #30)** — when a producer and its consumer share no token, the producer is itself a candidate consumer. Enumerate paired surfaces by asking "what else emits or consumes this fact?", never by grepping the producer's own name; a token-blind pair escapes both the AP #24 literal-marker grep and the AP #14e pattern-class sweep. Mirrors the Stage-3 **Producer-surface enumeration** angle. (8) **canonical-assumption challenge** — read the active repo's CLAUDE.md cover-to-cover; flag the most load-bearing architectural claim adopted as a starting truth without recent operator confirmation.

**See "AC Verifiability — pre-Stage-3 sub-gate" under "Workflow Validation Gate" below** — the Acceptance Criteria Measurability rule is merged into Workflow Validation Gate as its pre-Stage-3 half. Cut #8 / AC 1.18 (#498).

**Probe-before-assert (AP #29)**: before a swarm asserts a contract / param mode / endpoint behaviour / file absence / tool availability, it runs a live probe and captures the output; absence is an unverified hypothesis. See cluster: `../standards/stage-5/probe-before-assert.md` (per-target probe recipes); canonical rule ANTI-PATTERNS.md AP #29.

<!-- stages: 5 -->
#### Stage 5 Fix-Locus — Parked-Branch Authorisation

When a Stage 5 fix touches an artefact whose canonical lives on a **parked branch** (a different issue's solo branch, not the current merge target), the operator must explicitly authorise the parked-branch commit in the same `/Leader 5` invocation — otherwise the fix is limited to main-branch propagation only. Never silently switch to or commit on another issue's parked branch to land a Stage-5 fix (branch-safety + the fix would ride an unrelated, unreviewed branch). Surface the cross-branch locus to the operator with the proposed commands and wait for authorisation.

<!-- stages: 1,3,5 -->
#### Scope Snippet Rule (#406 F5.1)

When dispatching ≥10 subagents on an issue, the main agent writes a **frozen scope snippet** (≤2K tokens, scope + acceptance criteria only) to `${SST3_TMP:-/tmp}/sst3-issue-<N>-scope.md` and passes the path to subagents instead of the full issue body. ONE "scout" subagent reads the full issue and validates that the snippet covers the relevant scope. Saves O(N × full-issue-tokens) of subagent context bloat. <!-- c4:T03 --> Each pinned fact carries `{value, source: operator-said|repo-derived|inherited, class: MEASURED|INFERRED|UNVERIFIED, command, artefact@time, cost if re-run, cross-check}`; an inherited HEAD/tree fact is re-derived before pinning.

#### RESULT Block Schema (#406 F5.2)

Every swarm subagent ends its return with a fenced block:

```

<!-- stages: 1,3,5 -->
## RESULT
- verdict: pass|fail|unknown
- files_touched: [...]
- findings: [{path, line, claim, evidence}]
- tee_log: <path or none>
- scope_gaps: [...]
- wrapper_invoked: no|yes|n/a   (REQUIRED for Layer-2 raw-tools-only subagents — `no` proves the raw-only failsafe ran without wrapper-lane)
```

Main agent parses the RESULT block; subagent prose body is informational. Reduces typical 4-8K-token return per subagent to ~500 tokens with zero signal loss because every claim already has provenance per Rule 5 above. **When a subagent discusses graph queries, prepend `mcp_graph_available: yes|no` as the FIRST line** — AP #19 "Subagent wrapper-lane access" bullet (Ralph Tier 1 uses this with documented-fallback evidence: `no`+evidence=PASS, `no`+no-evidence=FAIL). **Wrapper-lane disposition (Issue #445)**: under the wrapper-lane, this field is always `no` — wrappers are bash-tool calls, not MCP-protocol calls, and subagents do not inherit the bash-tool set from the main agent in the same way. Documented fallback (grep + manual file reads) is the expected path under wrapper-lane, not a degradation. Ralph Tier 1 sees `no` + valid fallback evidence → PASS, not FAIL. <!-- c4:T50 --> In a schema'd Workflow leg, required RESULT fields are schema-required (in `required`), never prompt-only.

**Completeness-claim re-verification (AC 5.10)**: when any Layer-1 angle makes a *completeness claim* — "N sites", "no leaks", "0 occurrences", "every caller handled" — a raw-tools-only Layer-2 re-verification of that SPECIFIC claim is mandatory (direct grep / ast-grep / find, `wrapper_invoked: no`). A completeness claim is exactly the assertion most vulnerable to a wrapper recall-miss or a too-narrow pattern; one independent raw sweep per such claim is the failsafe. Cross-ref AP #29 (absence is an unverified hypothesis) + AP #14e (concept-based grep). <!-- c4:T11 --> Every clean verdict or figure states the set and commit it was measured over, and that set is diffed against an independently enumerated target set before the verdict is trusted.

<!-- stages: 4 -->
### Bash Output Budgets (#406 F4.7)

Default flags for the 10 commands SST3 runs hot. Provenance: each row backed by file:line in the audit findings of #406. The `tee-run.sh` wrapper (`../scripts/tee-run.sh <label> -- <cmd>`) provides recovery for any compressed output: full log saved to `~/.cache/sst3/tee/`, last 200 lines printed.

| Command | Default | Why |
|---|---|---|
| `git status` | `--short --untracked-files=no` | Avoid 200-line untracked dump (per `MEMORY.md` "never use -uall flag") |
| `git log` | `--oneline -20` | Full pager output is ~600 lines; agent needs 10-20 subjects |
| `git diff` | `--stat` first, then targeted `git diff -- <file>` | 20K-line diffs collapse to file list + hunk count |
| `pytest` | `-x --tb=line -q --no-header` (use `tee-run.sh pytest -- pytest …`) | Fail-fast, one-line tracebacks. tee-run preserves full log on disk. |
| `grep` (content search) | Use the **Grep tool** with `head_limit`, NOT bash `grep` | Tool is dedicated and observable |
| `find` (file discovery) | Use the **Glob tool**, NOT bash `find` | Tool is dedicated and observable |
| `Read` on file > 1500 lines | Grep first, then `Read` with `offset` + `limit` | Eager full reads burn 10K+ tokens for one function |
| `gh issue view` | `--json title,body,state --jq '...'` always; comments via separate `--json comments --jq '.comments[-5:]'` | Avoid 50-comment dumps |
| `curl` | `--fail --max-time 30` (any JSON consumer pipes through `jq -e .`) | Fail loud on HTTP errors; no invalid-JSON consumers |
| Logs | `tail -n 100` or `tee-run.sh logs -- cat <log>` | Never `cat` a log of unknown size |

Rule of thumb: any single Bash invocation that produces > 200 lines should be wrapped with `../scripts/tee-run.sh <label> -- <cmd>` so the agent gets the tail and the full log is recoverable.

<!-- stages: 4 -->
### Structural Code Queries — Wrapper-Lane First, Subagent Fallback

For structural code questions (callers, callees, imports, inheritance, blast radius, dead code, large functions, test coverage) in a language the wrapper-lane parses (Python, TypeScript, TSX, JavaScript, Rust — the five languages ast-grep is wired for in the wrappers), prefer **wrapper-lane** bash queries (`bash $SST3/sst3-code-*.sh`) over subagent exploration — when the pre-query gate passes:

1. **Wrapper invocable**: `bash $SST3/sst3-code-status.sh` exits 0 and emits valid JSON `{last_updated, file_count, source_languages}`. The lane is stateless — there is no graph to build. `file_count` reports the count of supported source files in the target repo (audit-trail aid, not a precondition).
2. **No staleness — every call re-parses from disk**. The wrapper-lane has no persistent cache; `sst3-code-update.sh` is a no-op contract-preservation shim. `last_updated` reflects the repo HEAD commit time, not query freshness.
3. **Target file / project language is in the supported list**. If not (Markdown, YAML, JSON, SQL, TOML, shell, HTML, Jinja, Dockerfile, etc.), skip the wrapper-lane; use subagent exploration.
4. **`search` is keyword-only**. The wrapper invokes ripgrep (`--literal` mode) or ast-grep structural patterns — there are no embeddings, no semantic similarity. Any "no match" must be cross-checked with a synonym sweep before drawing a negative conclusion.
5. **Spot-check one result** by reading source before drawing conclusions. "Never Assume — Always Check" applies to wrapper output the same as to memory or subagent summaries.
6. **Data-layer boundary** (round-5 N54): if the structural question spans a data-layer boundary (ORM ↔ SQL, HTTP ↔ service, JSONB ↔ Python type, serialisation round-trip, enum ↔ DB literal), wrapper-lane alone is INSUFFICIENT — it is AST-only; does NOT verify DB column existence, SQL literal values, JSONB schema, or runtime types. Verify per STANDARDS.md "Contract Verification" + AP #18 real-DB sample invocation. Field evidence: JSONB schema mismatch between planned-state and realized-state tables caught only by real-DB invocation (round-5).

The wrapper-lane is **NOT a replacement** for subagents. See ANTI-PATTERNS.md AP #19 for the full list of 12 subagent-only moments (voice, intent, cross-document, non-code audits, etc.) that MUST NOT be demoted by a "wrapper-first" rule.

**Naming-honesty note (Issue #445 Stage 5)**: the lane is called "wrapper-lane", not "graph". There is no graph database, no SQLite, no Tree-sitter store, no embeddings. Every query re-parses on disk via ast-grep + ripgrep + git. Field names in the wrapper JSON output reflect what is actually computed (`file_count`, not `total_nodes`); displaced daemon-MCP lineage: see `git log --grep="#445"`.

**Non-interactive shell PATH bootstrap (Issue #456)**: wrappers self-augment PATH via `../scripts/sst3-bash-utils.sh` (sourced by every end-user wrapper outside the exempt list) so engines under `~/.cargo/bin`, `~/.local/bin`, `~/.npm-global/bin` resolve from `bash --noprofile --norc -c '...'` (the shape Claude Code's Bash tool spawns). Without this bootstrap, `.bashrc` early-returns on non-interactive shells and engines on disk are invisible. The exempt end-user wrappers (system-PATH-only) plus the meta-validator `sst3-self-test.sh` (self-bootstraps PATH inline, and is infra outside the end-user-wrapper denominator) are listed in `../scripts/.bash-utils-exempt-list`; the `check-wrapper-bash-utils-source` pre-commit hook (declared BEFORE `sst3-self-test`) catches future drift at commit time.

See also `../reference/tool-selection-guide.md` "Decision Tree: Code-Understanding Queries" and `../docs/guides/code-query-playbook.md`.

**Three-signal contract policy**: every wrapper emits exit code, stdout NDJSON and stderr sentinel; consumers MUST check ≥2 of 3 to declare clean (taxonomy: `../docs/research/wrapper-lane-vs-raw/03_comparison.md`).

**Raw-tool cross-validation REQUIRED moments**: dispatch a raw-only subagent counter-query on (a) any `../scripts/sst3-*.sh` change; (b) any zero-result structural query; (c) post-implementation review of >100 LOC changes; (d) a RESULT with `wrapper_invokable: yes` AND `wrapper_invoked: no` and no documented reason.

**AI-agent fallback heuristic**: when a wrapper exits 127 / 1 / 2, the agent MUST (1) run the raw command the `../docs/guides/code-query-playbook.md` "Raw Fallback Recipes" table lists for the query type and record substitution + raw command + result count in the RESULT block; (2) if no row matches, go subagent-only per the AP #19 12-moments carve-out, citing "no fallback recipe"; (3) NEVER substitute raw output for wrapper output without recording it. Exit 127 = engine missing on disk: run `<your-dotfiles-clone>/scripts/install.sh`, never a custom PATH workaround.

<!-- stages: 3 -->
### Double-Guardrail Principle (N32 — user-authoritative)

**Principle**: every `/Leader` invocation verifies work against BOTH guardrails — the cross-cutting SST3 canonical (STANDARDS.md + ANTI-PATTERNS.md + WORKFLOW.md + project CLAUDE.md) AND the invoked-skill's domain canonical. Skill-specific rules are NOT suggestions; they are load-bearing canonical, equal in authority to SST3 standards within the skill's domain. Single-guardrail `/Leader` runs on non-SST3-infrastructure work operate with half their guardrails missing.

**Failure mode**: `/Leader 1-6` passes every SST3 check but silently violates the invoked skill's domain canonical (banned voice words, Seagate HARD CONTRACT, prompt-caching, stale claude-api model ID) — clean against SST3, broken against the skill.

**Invoked-skill canonical by domain** (load-bearing references — see skill definitions for the full rules; this table is a pointer, not a restate):

| Skill | Canonical rules |
|---|---|
| `blog` / `voice-doc-repo` / CV / LinkedIn | `voice_rules.py` banned words + KEEP_LIST; `iamhoi` / `iamhoiend` marker wrapping (carve-outs: `iamhoi-skip` / `iamhoi-skipend`); `check-ai-writing-tells.py` exit 0 |
| `ebay-seller-tool` | Seagate series HARD CONTRACT; 21-field listing contract; SMART gate; dual-path BOTH directions; never-dispute-customer |
| `claude-api` | Prompt caching wired on every cacheable prompt; model IDs current (no retired models); SDK idioms |
| `SST3-solo` / `Leader` | Cross-cutting SST3 canonical + AP #19 12-moments carve-out + stage-order discipline |
| Project-specific (`auto_pb`, `project-b`, etc.) | Paper/live parity; never-touch-production-positions; RTH-only E2E; per-project CLAUDE.md rules |

**Stage-by-stage integration**:

- **Stage 1 step 0a**: identify invoked skill + record `invoked_skill` + `skill_canonical_files` in the research file. First link of the chain; downstream stages read from this.
- **Stage 2**: main-agent author-time compliance — draft MUST NOT violate skill canonical.
- **Stage 3**: subagent angle verifies draft against skill canonical (main agent verifies against source).
- **Stage 4**: main-agent implementation-time compliance at every edit + Ralph Tier 2/3 verify + Gate 1 Verification Loop runs the skill's own verification hooks (e.g. `check-ai-writing-tells.py`, pre-commit hooks) with evidence in issue comment.
- **Stage 5**: Post-Implementation Review subagent angle audits delivered work against skill canonical; same verify-against-source discipline as the graph-backed audit.

**Enforcement**: Leader.md Guardrails block (all stages) + Stage 3 subagent angle list + Stage 4 Gate 1 checkbox + Stage 5 Post-Implementation Review appendix. Absence of skill-canonical checking on a non-SST3-infrastructure task = violation.

**Evidence**: round-5 user observation N32 (2026-04-20) — operator directed /Leader to also check the invoked skill's workflow, not just SST3 ("a double guardrail"). Pre-existing research: `docs/research/LEADER_SKILL_ENGINEERING_2026_04_12.md`.

<!-- stages: 2,3,5 -->
#### Skill-Canonical Audit Template (Comprehensive Walk)

**Use for AUDIT prompts** (Stage 2 author / Stage 3 subagent / Stage 5 subagent): walk every section of the invoked-skill canonical, return per-section pass/fail. **NOT for INVARIANT GATES** (Ralph checklists, Stage 4 Gate 1, AC checkboxes, Mirror-lane triggers, file:line/exit-code checks) — gates verify named conditions; audits verify a draft against a multi-section canonical.

**Scaffolding** (subagent receives verbatim):

> Read EVERY file in `skill_canonical_files` (Stage 1 metadata). For each: walk every `## ` and `### ` heading; for non-markdown structure (numbered `### 1.`, `**bold**` headers, prose-only) walk every numbered/bold/prose section as a logical unit. Per section, identify rules + verify [draft|delivered work] does not violate any. Do NOT pre-filter. Return per-section [PASS|FAIL|N/A] with file:line evidence for any FAIL, tagged by `source_file`.

**Fallbacks**: (a) empty `skill_canonical_files` → walk "Double-Guardrail Principle" pointer-table row + URLs; document in RESULT. (b) missing on disk → `verdict: fail` + `error: missing_canonical_file: <path>`. (c) multi-canonical → aggregate `section_failures`, tag by `source_file`.

**RESULT extension**:
```
section_failures: [{source_file, section_heading, canonical_file_line, draft_violation, evidence}]
canonicals_walked: [list of files actually walked]
fallback_applied: <none|inline_pointer_table|multi_canonical_aggregation>
```
Coverage = `canonicals_walked` matches `skill_canonical_files` (no separate counts).

**Failure diagnosis**: (a) subagent failure (in walked file, RESULT omitted → re-dispatch); (b) template failure (heading regex didn't match → widen); (c) canonical incompleteness (absent everywhere → add to canonical / pointer table).

**Prevents**: AP #23 (curator-bounded audit recall). **Stage refs**: Leader.md Stage 2 author + Stage 3 subagent + Stage 5 subagent. Multi-skill dispatch (split >5K tokens) lives in Leader.md Stage 3.

<!-- stages: 4 -->
### Contract Verification — Three Contracts (Issue #1407 post-mortem)

> Stage-4 checklist form (verification commands): `stage-4/contract-verification.md`.

Every change that crosses a boundary must verify all three contracts:

**1. Type Contract**
- Every function parameter with a non-Optional type annotation: grep all call sites and confirm no `None` can flow in
- If any caller can pass `None`, the annotation MUST be `T | None` and the function MUST have a null guard
- Pattern that causes silent bugs: annotated `float` but caller passes `float | None` → TypeError at runtime

**2. Schema Contract**
- Every SQL query that references a column: verify the column exists in the target table (run `\d tablename` or check migration file)
- Every SQL literal value in WHERE clauses: verify it matches the actual data stored (e.g., DB normalizes `'SLD'` → `'SELL'` on insert)
- Never infer column names from application-level variable names — the DB schema is ground truth

**3. Config Contract**
- Every key added to a config YAML: grep the source code for a matching read (`config.get('key')` or `config['key']`)
- Every config read in code: grep the YAML for the matching key definition
- Dead config (key in YAML, never read) = incomplete implementation, must be wired or removed
- Dead read (code reads key that doesn't exist in YAML) = runtime KeyError, must be added or removed

**Enforcement**: All three contracts are checked in the Verification Loop (Stage 4) and Ralph Review (all 3 tiers).

<!-- stages: 4 -->
### Fail Fast, No Silent Fallbacks

> Stage-4 write-time invariants: `stage-4/observability-fail-fast.md`.

**Principle**: Fail loudly at startup. Silent fallbacks hide bugs. Fix root cause. Error indicators must be unmistakable (cannot be confused with valid data).

| FORBIDDEN | Why | USE INSTEAD |
|-----------|-----|-------------|
| `0.0`, `0` | Valid metric values | `None` (internal) → `ER` (display) |
| `N/A` | Looks like "not applicable" | `ER` (clearly an error) |
| `""`, `-`, `--` | Invisible/soft placeholders | `ER` or explicit error message |

**See ANTI-PATTERNS.md #7** for full DO/DON'T list, code examples, detection patterns, and the Issue #269 post-mortem.

<!-- stages: 4 -->
### Observability — No Code Without Logs, Metrics, and Audit Trails

> Stage-4 write-time invariants: `stage-4/observability-fail-fast.md`.

**Principle**: Logs, metrics, and audit trails are mandatory at write time. If a system can run silently, it will — and you'll have no signal when it produces the wrong answer.

**Rules** (apply to every component you write):
1. **Log every decision boundary**, state transition, and external call (DB/API/file/subprocess/IPC) with structured fields (key=value or JSON), inputs, duration, and outcome.
2. **Metrics on anything quantifiable**: counters, durations, queue depths, success/failure ratios. Surface them where a human can see.
3. **Audit trail for any state change** affecting production data, money, or user-visible behaviour. Append-only, with actor + timestamp + reason.
4. **Logs must be searchable**: structured fields, consistent naming, no `print()`, no free-text prose.

(Loud failures at boundaries are covered by Fail Fast above. Don't restate them here.)

**See ANTI-PATTERNS.md #12** for the no-observability failure mode and self-healing.

<!-- stages: 4 -->
### Monitor, Don't Fire-and-Forget

**Principle**: When you launch a script / command / subprocess / deployment / test run / commit / push / background process, you own it from launch to completion. "Started" is not "done". Tail the logs, check the exit code, verify the expected output, confirm the side effects landed. The user repeatedly asking "did it work?" is the failure signal.

**Rules**:
1. Every script launch verified end-to-end: tail logs, check exit code, verify output, confirm side effects.
2. Every `run_in_background` command watched via Monitor or its output file, OR its completion notification awaited. Never fire and walk away.
3. Every test run reported with pass/fail counts, not just "tests ran".
4. Every commit/push/merge verified: commit landed, push succeeded, CI started, CI finished.
5. Every deployment includes post-deploy health checks before declaring done.
6. Every subagent dispatch followed by reading the output and verifying it did what was asked.
7. Every observability surface (logs, metrics, audit trails) READ when relevant — not just written.

**Test**: if you cannot answer "what happened?" with specifics, you fired and forgot. Go check NOW.

AP #12 builds the observability surfaces; AP #16 enforces reading them.

**See ANTI-PATTERNS.md #16** for the failure mode.

<!-- stages: 4 -->
### Not Done Until Working

**Principle**: NOT complete until ALL scope requirements verified WORKING.

| State | Status |
|-------|--------|
| "Mostly works" / "works except X" / "I think it works" / "tests pass but feature broken" | NOT DONE |
| All acceptance criteria verified / scope tested / user can perform expected actions | DONE |

**Self-Healing**: Return to appropriate stage → fix → re-verify → then mark complete.

**Enforcement**: Verification Loop requires explicit "fully working" before proceeding.

<!-- stages: 4 -->
### No Hardcoded Settings

**Principle**: All configurable values must be in external config files. Hardcoded values cause inconsistency and block reuse.

**Must Externalize**: numeric thresholds, URLs/paths/credentials, colors, timeouts/retry/limits, feature flags.

**Where Settings Go** (per project's CONFIG_SYSTEM.md):

| Setting Type | Location | Discovery |
|--------------|----------|-----------|
| Environment (dev/prod) | `.env` or env vars | Fail if missing |
| Strategy parameters | Config YAML (Layer 2) | config_loader.py |
| Component metadata | Co-located YAML (Layer 3) | config_loader.py |
| UI theming | CSS variables (Layer 4) | stylesheet |
| Indicator colors | Component YAML | Part of component |

**Allowed Hardcoding** (exceptions):
- \ constants with descriptive names (explicit intent)
- Array indices and loop counters
- Line numbers in error messages
- Test fixtures in \ directory

**Enforcement**:
1. **SST3 workflow**: Pre-commit hook `check-hardcoded-params.py` (BLOCKING)
2. **Pre-commit hook**: \ blocks commit with guidance
3. **Discovery**: Project's \ documents where each type goes

**Error Format** (from pre-commit hook):
**Impact**: Issue #383 — 309 hardcoded values found in frontend code (pre-commit hook now prevents recurrence).

<!-- impact-roi-carve-out -->

<!-- stages: always -->
### Voice Content Protection (Marker-Driven)

**Principle**: Any prose written in the operator's voice in any repo (CV, LinkedIn, cover letters, blog posts, profile docs) MUST be wrapped in `<!-- iamhoi -->` ... `<!-- iamhoiend -->` markers so the marker-driven voice guard can scan it. Default = SKIP. Untagged prose is silently unprotected.

**Canonical source of truth**: `../scripts/voice_rules.py` (~80 banned words, banned phrases, KEEP_LIST, cutoff date 2026-04-07). Human companion: `voice-doc-repo/VOICE_PROFILE.md` Sections 8 + 19. NEVER duplicate the rules — both `check-ai-writing-tells.py` (canonical) and any vendored copy (e.g. `hoiboy-uk/scripts/check-ai-writing-tells.py`) import from `voice_rules.py` only.

**MUST**:
- Wrap every new voice-prose paragraph in `<!-- iamhoi --> ... <!-- iamhoiend -->` before commit.
- For quoted JD content, banned-word examples, or proper-noun usage inside a tagged block, carve out with `<!-- iamhoi-skip --> ... <!-- iamhoi-skipend -->`.
- For whole-file exemption, put `<!-- iamhoi-exempt -->` as the FIRST non-blank line.
- For new banned words: edit `voice_rules.py` AND `voice-doc-repo/VOICE_PROFILE.md` Section 8 in the SAME pass (single-source-edits, AP #9).

**MUST NOT**:
- Sanitise authentic the operator vocabulary out (passion, journey, deeply, truly, navigate, back to basics, attention to detail — see KEEP_LIST).
- Add banned words anywhere inside iamhoi markers.
- Duplicate rule data outside `voice_rules.py`.
- Mix HTML `<!-- iamhoi -->` and `# iamhoi` syntax in the same file (hard fail).

**Enforcement**: a pre-commit hook in every voice-guarded consumer, plus CI in dotfiles (`validate.yml` voice-tells job) and hoiboy-uk (`ci.yml` voice-tells step). The consumer set is deliberately NOT enumerated here — read the `voice_rules.py` mirrors in `SST3/drift-manifest.json`, which is the authority (#560 grew the set, and a hand-listed copy rots on the next onboard). Drift between canonical and vendored copies is enforced by `check-mirror-drift.py` (manifest-driven), not a `cmp -s` hook.

**Known coverage boundary**: the CI half of the above is NOT universal — a consumer whose voice guard is pre-commit-only is bypassable with `git commit -n` / `SKIP=`. Before relying on the double guardrail for a given repo, check that repo's `.github/workflows/` for a voice job rather than assuming this section grants it. Full boundary detail, including which registers each hook does and does not scan: `check-iamhoi-wrapping.py` `has_voice_prose` docstring.

**Reference**: dotfiles#404, hoiboy-uk#3.

---

<!-- stages: 3 -->
### Polish vs Twist (Semantic Frame Preservation)

**Principle**: When integrating operator-supplied content (a paragraph, sentence, point, rough thought) into any draft — blog, LinkedIn, CV, cover letter, anywhere — polish it for flow but preserve his meaning AND his interpretive frame. He writes rough thoughts to AI specifically to have them turned into publishable prose, so editing is mandatory; verbatim copy-paste defeats the point, and so does twisting. The marker-driven voice guard (above) catches banned WORDS — it is structurally blind to a semantic FRAME shift. This subsection is the semantic-frame companion to that lexical guard. The instinct to "improve / sharpen / tighten" must be bounded: fire ONLY on AI-drafted prose that integrates operator-supplied source, never on the load-bearing nouns / verbs / hedges the operator actually wrote.

**Scope — when this rule fires** (bound it; over-application is the symmetric failure): fires ONLY when AI integrates operator-supplied source content (a rough paragraph / sentence / point he wrote) into voice-bearing prose — blog, LinkedIn, CV, cover letter, profile narrative. Does NOT fire on: fully-AI-authored governance/standards/docs prose (this very subsection is not operator-voice), code or config, or the operator's own words preserved verbatim as a marked quote. The fire-condition is authorship-gated: no operator-supplied source in-diff → rule is inert.

**MUST — CLEAN UP (allowed, expected, the whole point)**:
- Grammar normalisation (subject-verb agreement, tense)
- Sentence-boundary adjustments (split a run-on, join clunky fragments)
- Remove duplicated words from rough-draft input
- Punctuation standardisation (Oxford comma preference, quote-style)
- Light connectors ("also", "and", "but") so ideas flow
- Capitalise proper nouns
- Slight word reorder for natural English sentence rhythm

**MUST NOT — TWIST (forbidden)**:
- Add qualifiers that change interpretation: "at that size", "by comparison", "in essence", "fundamentally", "ultimately"
- Reframe a comparison as a verdict. **Canonical worked example (verbatim — load-bearing)**: the operator wrote `costs vs value` (a relationship/comparison the reader weighs); AI wrote `costs outweigh the value` (a verdict the writer hands down). Same surface words, opposite interpretive frame. This single example is THE canonical case — any future twist detector that cannot separate these two is measuring nothing.
- Drop hedges the operator used: "probably", "just", "really", "maybe"
- Add hedges the operator did not use
- Substitute "smoother" synonyms that lose nuance ("doesn't scale" replacing his "doesn't scale economically")
- Add analytical phrases ("the economics here", "the real point is") that impose interpretive structure
- Add subject-clarifications that change emphasis ("for them", "for those companies") when context already carried it — light disambiguating connectors that just maintain context flow are OK; **the test is whether the addition changes the reader's interpretation**

**Mechanical procedure when integrating operator-supplied content** (5 steps):
1. Quote his literal phrasing in chat before editing, so the source is visible.
2. Identify the interpretive load — what is he claiming, hedging, comparing, framing? What is the SHAPE of the point?
3. Polish for grammar / flow — fix rough-draft artefacts (typos, missing articles where clunky, sentence boundaries).
4. Test each candidate phrasing against the TWIST checklist above. Adds a qualifier / reframes a comparison as a verdict / drops a hedge → back it out.
5. Show the polished version in the response before the final sync-and-push iteration so the operator can spot drift early.

**Why it is load-bearing**: operator-voice trades on authenticity AND on his interpretive frame being preserved. `costs vs value` → `costs outweigh value` is invisible to AI generic-good-writing instinct but load-bearing for the operator — the first is observational (a comparison the reader weighs), the second conclusive (a verdict the writer hands down). Over-correcting the other way (verbatim copy-paste) is the symmetric failure and equally wrong.

**No programmatic detector is possible — subagent-only semantic check (architecturally foreclosed)**: there is no `check-twist*.py` and none should be scoped. `voice_rules.py` is a `re.escape`-literal single-document word/phrase matcher with no source-vs-draft input channel; the canonical `costs vs value` → `costs outweigh value` example has 0% lexical separability (identical tokens, opposite frame); the fire-condition is authorship-gated (only when AI-integrated operator-supplied source is in-diff). Enforcement is therefore a semantic subagent check, NOT a heuristic script. A future agent proposing a programmatic detector must first explain why the `tests/fixtures/` foreclosure-regression fixture (a twisted paragraph the word-list guard PASSES at exit 0) now fails — it cannot.

**Enforcement**: ANTI-PATTERNS.md AP #25 (Twisting the operator-Supplied Content — the failure mode + Evidence). Ralph `sonnet-review.md` "Voice-Frame Preservation (semantic)" angle (fires when `invoked_skill ∈ {blog, voice-doc-repo}` and prose is in-diff). Leader.md Stage 3 + Stage 5 skill-canonical twist sub-prompt. Memory a per-rule pointer file (operator-private) is the ≤30-line pointer — if memory and this file diverge, this file wins.

**Reference**: rule promoted from auto-memory a per-rule pointer file (operator-private) (now the ≤30-line pointer) onto the canonical surface in dotfiles#484. Lexical sibling: "Voice Content Protection (Marker-Driven)" above + ANTI-PATTERNS.md AP #15 (banned-words guard); this subsection is the semantic-frame half of the same protection.

---

<!-- impact-roi-carve-out -->

<!-- stages: always -->
### Public Repo Secret Detection

**Principle**: Public repos (`ebay-seller-tool`, `SST3-AI-Harness`, `hoiboy-uk`) must never contain secrets, business identifiers, or private filesystem paths. Repos opt in via `.public-repo` marker file at root.

**What is blocked**: Platform tokens (GitHub PATs, AWS keys, GCP, Stripe, JWT), private key headers (PEM, PGP), generic secret assignments (password/token/credential with non-placeholder values), private paths (`/mnt/c/Users/`, `My Drive/`, `Google Drive/`, `OneDrive/`), per-repo business terms (from `.secret-blocklist`).

**Per-repo config**: `.secret-blocklist` (business terms, one per line) and `.secret-allowlist` (false positive suppressions, `path/file` or `path/file:line` format). Script handles missing files as empty sets.

**Enforcement**: Pre-commit hook `check-public-repo-secrets.py` (BLOCKING, `--staged-only` mode) + CI step (full repo scan, no `continue-on-error`). Vendored to consumer repos with drift-check hooks.

**Evidence**: Issue #410 — private business identifiers leaked into a public-facing repo (2026-04-11), required manual scrub + force-push.

**Mirror propagation transform tiers** (#497 A.5 / E.2.1): the canonical-side propagator (`../scripts/sst3_mirror_utils.py`) exposes the following named transforms; each canonical-mirrored entry in `SST3/drift-manifest.json:vendored_files` declares which transforms apply to which mirror:

- `path_scrub` — rewrites cross-repo `../dotfiles/SST3/<subdir>/` references to the mirror's flattened root.
- `issue_url_scrub` — collapses `https://github.com/dotfiles/issues/NNN` URLs to bare `Issue #NNN` form.
- `repo_ref_scrub` — strips the `hoiung/` org prefix from public-repo URL refs.
- `project_name_scrub` — replaces operator-acknowledged-public project names with `project-a` / `project-b` generic placeholders for the public mirror surface.
- `private_repo_issue_scrub` (NEW #497 A.5.1) — replaces `<private-repo>#NNN` shorthand with `Issue #NNN`, removing the cross-repo issue references that enumerate the operator's private consumer repos (`consumer-private-A`, `voice-doc-repo`, `idea-repo`, `voice-staging`, `lab-harness`, `consultancy-ops`, `project-x`).
- `blocklist_subset` — emits the `[shared]` + per-target sections of `.secret-blocklist-canonical` to each mirror.
- `private_path_scrub` — generic log-path scrubber for run-time path leaks.
- `trading_term_scrub` — genericises pipeline/SL1/SL2/backtest trading-pipeline terminology.
- `user_quote_scrub` — strips `User quote: *"..."*` inline attribution blocks.
- `substitute_repo_slug` — substitutes the `<REPO_SLUG>` token in managed-block propagation.

The opaque-token mechanism for hash-redacting literal business identifiers in public mirror `.secret-blocklist` files is documented inline at `../scripts/.secret-blocklist-hashes.json` (`unmirrored_canonical_files` — never propagated). `check-public-repo-secrets.py` expands tokens via that mapping when the canonical-side dev-clone is the scanner's working tree; public-mirror clones fall back to verbatim-token matching (degraded mode, documented).

---

<!-- impact-roi-carve-out -->

<!-- stages: always -->
### Local-Only Artifacts (claude.ai Artifact Tool Banned)

**Principle**: Any HTML/data artifact is built LOCAL via the `artifact-branding` skill (`sst3_brand_html`) — carrying the hoiboy.uk brand — and saved into the owning repo under a findable path (e.g. `docs/`), so it is organised, versioned, and retrievable. If published, it goes only to the operator's own site by explicit choice. The built-in claude.ai `Artifact` tool — which renders to an ephemeral claude.ai-hosted URL — is **BANNED**. Never call it to render, preview, or publish anything.

**Why**: claude.ai-hosted artifacts get lost — they are unbranded, indistinguishable from one another, and not in any repo, so the operator cannot find or attribute one later. Local artifacts are (1) branded (hoiboy.uk identity) and (2) organised in the owning repo (committed, versioned, findable). Findability + branding are the point; the local helper also leak-scans, but that is a secondary benefit, not the reason.

**Enforcement**: `"enableArtifact": false` in canonical `claude/settings.json` removes the `Artifact` tool from every session (needs Claude Code >= 2.1.242; `<your-dotfiles-clone>/scripts/install.sh` checks the CLI before merging it) + this always-load rule. Build local per `.claude/skills/artifact-branding/SKILL.md` and commit it to the repo.

**Evidence**: dotfiles#538 — walkthrough diagrams rendered to claude.ai URLs got lost / indistinguishable; operator: artifacts must be local so they are "branded" and "organised in the repo" (findable again), not scattered on claude servers.

---

<!-- stages: 4 -->
### No Backwards-Compatibility Hacks

**Principle**: When code is removed or refactored, delete it completely.

**FORBIDDEN**: `_oldVar` aliases, re-exported removed types, `// deprecated` comments, dead code paths, shim layers, feature flags for removed features.

**DO**: Delete unused code completely. Update all call sites. Use git history to recover. Trust tests.

**Enforcement**: Verification Loop catches compatibility hacks.

---

<!-- stages: always -->
### Fix Everything — No Scope/Language Excuses

**Principle**: Fix ALL problems found. No deferrals, no scope/language excuses.

**DO**: Fix every real bug — Python, Rust, JS, SQL, YAML, shell. Only valid skip: confirmed false positive (document why).
**DON'T**: "not in scope", "pre-existing", priority tiers — if it's real, fix it.

---

<!-- stages: always -->
### Named-Entity Scope — Don't Broaden a Named Set

**Principle**: When the operator enumerates specific entities, values, or a SET (e.g. `MB100/MBS100`, a named file list, specific tickers/IDs/issues), that enumeration IS the scope. NEVER broaden a named set to "all" / "every" / "uniform" / "any" as a simplification — a superset is a different (wrong) scope, even when it looks "more general" or "cleaner". Likewise a copy remark is recorded as one instance (which string, which change), never widened into a rule unless the operator states the rule.

**Failure mode**: an agent reads "keep the MB100/MBS100 rows" and ships "keep ANY row / uniform across all strategies" — the opposite of a precise instruction (operator caught this live on auto_pb#1522, 2026-06-03). Broadening feels like generalisation but silently violates the contract.

**The inverse of AP #14e**: #14e says *enumerate every site of a pattern-CLASS you are extending* (don't under-apply). Named-Entity Scope is the mirror: *don't widen a SET the operator explicitly bounded* (don't over-apply). Both are scope-fidelity rules.

**Enforcement**: Leader.md Stage 1 step 0 (restatement preserves named entities verbatim) + Stage 3 "Named-scope fidelity" sanity angle (flag any AC applying to a broader set than the operator named).

---

<!-- stages: 1,3,5 -->
### Chat Reconciliation (Verifier-Led)

**Why**: Anti-scope-creep is NOT about feedback being caught post-hoc — that is too late. The live failure is agents drifting from what was AGREED IN CHAT: overengineering, inventing features, or shipping the opposite of what was agreed. A self-reported reconciliation table does not fix this (the drifting agent writes its own verdicts — it catches omission, not self-deception). The fix is VERIFIER-LED and grounded in the recorded transcript (Claude Code stores every session as JSONL under `~/.claude/projects/<project-slug>/<session>.jsonl`, which survives compaction).

**Mechanism** (one early pass at Stage 1; the full panel at Stage 3 and Stage 5):
1. **Transcript-reader** — `../scripts/extract-chat-agreements.py` extracts the operator's raw human-typed messages (drops tool_result / `<system-reminder>` / `<command-*>` noise). <!-- c4:T64 --> Only what the operator typed is his position: unattributed commit or doc prose is never cited as one he held or overruled (`git log -1 --format=%B <sha>` shows its author).
2. **`## Agreements Log`** — appended to the research file AS agreements are made (captured-when-agreed > reconstructed-late; a low-bias anchor for the verifier).
3. **Three-model neutral verifier panel** — one Haiku + one Sonnet + one Opus, dispatched IN PARALLEL via the Workflow tool's per-agent `model` override (model diversity = different blind spots; distinct from Ralph's SEQUENTIAL code-review). Each fresh-context verifier is given ONLY the extracted messages + the agreements log and a NEUTRAL prompt ("from these messages, what did the operator ask for / agree to / rule out? cite each; no speculation") — it is NOT shown the agent's scope/issue/diff, so it cannot be led into rubber-stamping. It produces a fresh INDEPENDENT interpretation.
4. **Main-agent divergence check** — the main agent double-checks each independent interpretation against (a) its own understanding and (b) the current artifact (research scope @ S1 / issue scope @ S3 / delivered diff @ S5). Divergence is the drift signal, classified with three tokens: `invented` (in the artifact, never in the interpretation), `dropped` (in the interpretation, missing from the artifact), `inverted` (the artifact contradicts the interpretation). <!-- c4:T75 --> A panel leg whose output quotes none of the supplied messages is re-run before it is read.
5. **Operator sign-off** — the consolidated `## Chat Reconciliation` report is POSTED and the operator approves it at the two commitment points: Stage 3 (before `gh issue create`) and Stage 5 (before sign-off).

**Honest limit**: the deterministic floors only guarantee the verifier RAN and the report is POSTED (cannot be silently skipped) — the Stage-1 `## Agreements Log` presence gate, the Stage-3 `## Chat Reconciliation` binary-grep gate, and the Stage-5 `C17` presence check. A script cannot judge whether a verdict is honest; the three independent model reads + the operator's sign-off are what catch truthfulness.

---

<!-- stages: 4 -->
### Investigate Before Coding

**Principle**: Investigate → root cause → plan → alignment → THEN code. Use subagents to research; main agent collates and plans.

---

<!-- stages: 4 -->
### Before Fixing Any Function — Verify the Live Code Path

**Principle**: A fix applied to a function nobody calls is not a fix. Prove the function is on the live code path before editing it.

**Rules**:
1. `grep -rn 'foo' src/ scripts/ tests/ rust/` (excluding the definition itself). Zero non-test callers → dead. **Delete instead of fix.** Record in commit.
2. If callers exist, confirm at least one is reachable from a production entry point (CLI, route, scheduled task, queue consumer, systemd service).
3. Commit message: `Verified live: <caller path>` or `Verified dead: deleted`.

**Python ↔ Rust parallel implementations**: any change to a Python file under `src/data/adapters/` (or a parallel Rust port in `rust/pb-data-service/src/`) MUST also check the Rust file. Apply equivalent change OR: `Rust equivalent: N/A — <reason>` or `Rust equivalent: <file:line> — <commit hash>`.

**Evidence**: Issue #1416 — three manifestations in one session (silent 23-day crash, fix landed in a dead copy, live Rust path broken 45+ days), all from skipping the grep.

---

<!-- stages: 4 -->
### Fix Big Problems First

**Principle**: Fix PRODUCTION/architecture problems before infrastructure issues. A stuck repair loop beats a pytest timeout.

---

<!-- stages: 4 -->
### Never Replace — ADD Alongside

**Principle**: When adding config values, NEVER replace existing user-set values. Add new ones alongside. ASK if an existing value seems wrong. (Evidence: scheduler incident — refresh ran 2 hrs late.)

---

<!-- stages: 4 -->
### Solo Branch Merge Safety

**Principle**: Solo branches merge to main via the worktree-first server-side fast-forward pattern (dotfiles#488 AC 1.3) — `git push origin <solo-branch>` then `git push origin <solo-branch>:master` from inside the isolated worktree. On non-fast-forward rejection (origin/master advanced concurrently), `git fetch origin master` then `git rebase origin/master` *inside the worktree*, then retry — bounded ≤3 attempts. NEVER `--force` / `--force-with-lease`. NEVER shared-tree branch-switch — no `git checkout main`, no `pull main` instruction in the merge procedure (those would mutate every concurrent agent's HEAD on the shared clone).

**Preserve BOTH principle** (originally from Issue #1347 — concurrent work overwritten): the rebase-inside-worktree produces equivalent preserve-BOTH outcome as the pre-#488 shared-tree resolve. `git rebase origin/master` is 3-way merge semantics; on a conflict it surfaces the conflict for explicit resolution preserving both intent sets — same outcome as the pre-#488 manual resolve, different mechanic, no shared-HEAD mutation.

---

<!-- stages: 4 -->
### Test Live Operations

**Principle**: After fixing operational infrastructure (services, restarts, systemd), trigger a live end-to-end smoke test. Don't just verify imports. (Evidence: crash-loop undetected because restart never triggered.)

---

<!-- stages: 4 -->
### Wiring Verification

> Stage-4 loop checkboxes: `stage-4/verification-loop.md`.

**Principle**: After ANY fix/enhance/refactor, verify changed code is wired into existing functions and processes.

**Enforcement**: Verification Loop mandatory check.

---

<!-- stages: 4 -->
### E2E Tests Must Reuse Production Code

**Pointer**: folded into ANTI-PATTERNS.md AP #26 "E2E System Verification" (single source of truth — the E2E/System Tier). The reuse principle (E2E tests reuse production code paths — calculators, order gateways, price validation — never build parallel logic; search production code before writing any test helper) lives there + in STANDARDS.md "Three-Tier Testing Framework" → E2E Tier.

---

<!-- stages: 1,5 -->
### Exhaustive Line-by-Line Audit

**Principle**: Audits are line-by-line per directory using separate subagents, NOT grep pattern skims. Each subagent gets a focused area. Covers: scope review, wiring check, inefficiency scan, memory leaks, STANDARDS.md compliance.

**Evidence**: OHLCV audit first pass (grep skim) missed 40-60% of issues. Line-by-line with separate subagents per directory catches everything.

---

<!-- stages: 4 -->
### SST3 is Enforcement, Not Honor System

**Principle**: 5-stage workflow and verification checkpoints are mandatory, not suggestions. Follow in order.

**Enforcement Mechanisms**:
- **Stage 1 Research Gate**: Must complete before writing Issue body
- **Stage 3 Triple-Check Gate**: Must complete before Solo Assignment
- **Verification Loop**: Repeat until ALL pass (overengineering, reuse, duplication, fallbacks, wiring, regression, quality)
- **Ralph Review**: Haiku → Sonnet → Opus — all 3 must pass before merge
- **user-review-checklist.md**: ALL sections mandatory
- **Pre-commit hooks**: Block on size limits, propagation, hardcoded params, debug code

**DON'T**: Skip stages for "simple" changes. Mark checkboxes without evidence. Use honor system.

**Flow**: Research Gate ✓ → Issue written → Triple-Check Gate ✓ → Implement → Verification Loop ✓ → Ralph Review ✓ → Merge → user-review-checklist ✓ → Close

<!-- stages: 4 -->
### Minimal Comments

**Write AI-readable code**:
- Use clear, descriptive names (functions, variables, classes)
- Keep functions small and focused
- Self-documenting code saves tokens in context window
- **WHAT comments are forbidden** - use descriptive names instead
- Comment WHY (business logic, gotchas), not WHAT (code already shows this)
- Only comment non-obvious decisions

Comment WHY for non-obvious business logic (e.g., `time.sleep(2)` for IBKR rate-limit). Never comment WHAT.

<!-- stages: 1,2,3 -->
### Plan Mode by Default

**Principle**: Default state is plan-only. No file ops, no subagents, no commands until execution trigger.

**Execution triggers**: "work on #X", "implement", "autonomously".

**Immediate execution** (ALL must be true): <5 min, <10 lines, zero external deps, reversible, user explicitly requested.

**Enforcement**: Ambiguous requests → stay in Plan Mode, ask for clarification.

<!-- stages: 4 -->
## Tool Standardization

| Category | Python | JavaScript/TypeScript |
|----------|--------|----------------------|
| Package manager | `uv` | `npm` or `pnpm` |
| Linter/formatter | `ruff` | `eslint` + `prettier` |
| Testing | `pytest` | `jest` or `vitest` |

Document tool choices in CLAUDE.md.

See: `../workflow/WORKFLOW.md` (Stage 1 — Research) for library research process.

<!-- stages: 4 -->
## MCP Tool Schema Loading (Deferred Tools + ToolSearch)

**What it is**: The Claude Code harness may defer MCP tool schemas — tools appear as NAMES ONLY in the agent's active tools (no parameter schema). Calling a deferred tool directly returns `InputValidationError`. Detection: the `ToolSearch` tool is listed in the agent's available tools, and MCP tool names appear in a `<system-reminder>` block labelled "deferred tools".

**Rule (generic — applies to ANY deferred MCP tool, not just github-checkbox)**: Before invoking any MCP tool whose schema is not present in the session-start tool list, call `ToolSearch` with `select:<tool_name>[,<tool_name>...]` to load the schema. Only after the schema is loaded may the tool be invoked. This applies to `mcp__github-checkbox__*`, project-local MCPs registered in `.sst3-local/.claude.json`, and any future MCP servers added to `~/.claude.json`.

**Pattern — github-checkbox** (canonical six-tool load):

```
ToolSearch(query="select:mcp__github-checkbox__update_issue_checkbox,mcp__github-checkbox__get_issue_checkboxes,mcp__github-checkbox__health_check,mcp__github-checkbox__get_issue_events,mcp__github-checkbox__list_issue_comments,mcp__github-checkbox__update_issue_comment")

# then:
mcp__github-checkbox__update_issue_checkbox(
    issue_number=N,
    checkbox_text="...",
    evidence="..."
)
```

**Pattern — generic** (any deferred MCP tool):

```
ToolSearch(query="select:mcp__<server>__<tool>")
# then call the tool as documented by the MCP server
```

**Fail modes**:
- **InputValidationError on direct call** (schema not loaded) → invoke `ToolSearch` first, then retry the call. This is the canonical path; not a failure, just an unloaded schema.
- **ToolSearch returns no match** → retry ONCE with short backoff (transient harness issue). On second no-match, STOP and surface the error. Do NOT fall back to comment-only progress — that is AP #20.
- **ToolSearch succeeds but tool still errors** → normal tool-error handling; fix the call, do not silently skip.
- **`gh issue edit --body-file` fallback clobber (AC 5.5)** → the 401 / MCP-down fallback path (`gh issue edit --body-file`) OVERWRITES the ENTIRE issue body, clobbering MCP-set checkbox `[x]` state. Before using it, re-fetch the CURRENT body (or the `get_issue_checkboxes` state) and preserve every `[x]` mark in the file you pass — otherwise the MCP-ticked ACs silently revert to `[ ]`.

**Canonical scope boundary**: this section is THE canonical source for the ToolSearch / deferred-tool rule. `../reference/tool-selection-guide.md` "Example 2: Stage 4 Checkbox Update" is THE canonical source for per-deliverable evidence-quality patterns. The two are separate concerns — do not duplicate content between them; cross-link by section header only.

**Canonical invocation points**: `../claude/commands/Leader.md` Guardrails block + `../claude/commands/SST3-solo.md` Governance Enforcement section reference this rule. `../ralph/{haiku,sonnet,opus}-review.md` enforce it at review time.

<!-- stages: 5 -->
## Governance Evidence Signal (Canonical)

Canonical audit signal for verifying that `mcp__github-checkbox__update_issue_checkbox` was actually invoked (AP #20 compliance) is the **`## Proof of Work` section in the issue body** — NOT the GitHub timeline `edited` event log.

**Why the body section, not the timeline**: GitHub's timeline API (`mcp__github-checkbox__get_issue_events`) does not emit `edited` events for an issue author's own body edits on their own issue — a documented API behavior. Since solo-workflow agents ARE the issue author in ~99% of cases, PATCH-event-based audit false-negatives every honored invocation. The body content itself, however, is always externally readable via `mcp__github__get_issue` or `mcp__github-checkbox__get_issue_checkboxes`, regardless of who authored the edit.

**Structure of the signal**: `<MCP servers — operator-only>/github-checkbox/server.py` function `append_to_proof_of_work` (locate it with `grep -n`) appends a structured entry per invocation to the body's `## Proof of Work` section. Each entry names its checkbox by the box text, cut to its first 80 characters and `…` when longer, and carries the evidence string supplied at call time. The body PATCH that toggles `[ ]` → `[x]` is the SAME PATCH that appends the entry, so presence in Proof of Work strictly implies the tool was called.

**Verification procedure** (for Ralph tiers and any external auditor):
1. Fetch issue body via `mcp__github__get_issue` (or `mcp__github-checkbox__get_issue_checkboxes` for live-state cross-check).
2. Parse the `## Proof of Work` section. Each entry starts with `- **<checkbox text>**: <evidence>`; match a cut label (`…`) to its box by prefix.
3. For every `[x]` box in the body, there MUST be a matching entry in Proof of Work. Missing entry = AP #20 violation (comment-only / narrative-only progress).
4. For each entry, verify the cited evidence:
   - `file:line` claims → `mcp__github__get_file_contents` or local Read on the solo branch
   - commit hashes → `mcp__github__list_commits` / `git show <hash>` / GitHub `/commits/<sha>` endpoint
   - subagent RESULT blocks → comment-id referenced in entry, fetched via `list_issue_comments`
   - command output → reproducible via the same command, or cited via tee log path

**Tier-A cadence verification (opus-review.md Governance Drift Audit)**: ordering of Proof of Work entries is authoritative — the section appends in invocation order. Cross-reference the entry order against the branch's `git log --oneline` to confirm Tier A items closed within the same phase's commit window. Do NOT use `get_issue_events` timestamps for this — self-edit suppression breaks it.

**What this signal does NOT provide**:
- Authenticity of evidence text (a dishonest agent could write false file:line claims). Secondary verification via `get_file_contents` / `list_commits` is required for that — see verification procedure step 4.
- Tamper-detection (issue authors can edit the body to remove Proof of Work entries — use `git log` commit trail as immutable secondary audit).

**Canonical scope boundary**: this section is THE canonical source for which signal Ralph / external audits use. `../ralph/{haiku,sonnet,opus}-review.md` reference this section and do NOT duplicate the procedure. `../reference/tool-selection-guide.md` Example 2 remains canonical for per-deliverable evidence-quality patterns (what to write INTO the Proof of Work entry). This section is canonical for what to DO WITH Proof of Work entries at audit time.

<!-- stages: 5 -->
## Task-Close Drain Gate (Canonical)

Every Stage-5 task close must verify residue drained or waived — `bash $SST3/leader-stage5-drain-check.sh <issue>` exit 0 mandatory before sign-off. The gate fires on six classes (D1: uncommitted task-touched files / D2: self-created stash / D3: self-opened worktree / D4: un-pushed commits / D5: unfinished propagation tail — dotfiles-scoped / D6: the issue's dotfiles feedback file `feedback-<repo>-<issue>.md` is not committed + pushed + synced to `origin/master` — runs regardless of `--repo`, since feedback lives in dotfiles even when the work repo differs; #522). Either drain the residue and re-run, or pass an explicit `--waive-residue <class>:<reason>` flag per class to record the operator's deliberate exception. Layer-A pre-flight (Leader.md step 7a.1, between the 7a.0 sweep and the 7a completeness check) + Layer-B GHA failsafe (`.github/workflows/stage5-completeness.yml`) replay the same gate server-side; both layers are mandatory. Parallel to the completeness-gate principle (#460 W4) but enforces "the task left no residue", not "the feature is complete". Introduced in #493 Phase 2.

<!-- stages: 4 -->
## Per-Stage Feedback Capture (Canonical)

> Canonical: `../standards/stage-4/per-stage-feedback-capture.md` (extracted for de-bloat, dotfiles#516 AC 6.2). The section-name anchor "Per-Stage Feedback Capture (Canonical)" is preserved here; the full mechanism + 10-field spec + write-time template rules live in the cluster file (loaded by `load-stage-rules.sh 4`). Note (dotfiles#528 AC 3.5): the Stage-5 `friction` field carries a `closing_comment_posted: <yes:url|no:reason>` SUB-value inside its value body (NOT an 11th top-level field) — full spec in the cluster file's 10-field schema. Note (dotfiles#528 AC 5.2 — stub-first): the commit-msg presence hook (`check-sst3-metrics-feedback.py`) validates with `allow_placeholder=True`, so a fresh template stub (frontmatter filled, field values still `<to-be-filled>`) does NOT block the first phase commit; the strict close-gate stays `allow_placeholder=False` and rejects placeholders — populate every field before Stage-5 sign-off.

**Commit + push the feedback file (cross-repo sync — #522)**: the per-issue feedback file lives in dotfiles `SST3-metrics/leader-feedback/feedback-<repo>-<issue>.md` EVEN WHEN the work repo is a different repo (auto_pb, consumer-private-A, …). It MUST be committed AND pushed to dotfiles `origin/master` before Stage-5 sign-off — a consumer-repo session that drains only its own work repo leaves the dotfiles-side feedback orphaned and un-aggregated (the recurring "feedbacks just sitting uncommitted" failure). Stage-5 drain-check class **D6** gates this (present + committed + pushed to `origin/master`). Use `mark-improvements-applied.sh` for closure marks so `applied_in` lands on its own field line, never crammed into `improvement_status`.

<!-- stages: 4 -->
## Path Portability

**Environment Variables**:
- `DOTFILES_ROOT`: Path to dotfiles repository (default: `<your-dotfiles-clone>`)
- `SST3_TEMP`: Path to temp folder (default: `C:/temp`)

**Usage in scripts**:
```bash
# Use environment variable with fallback
cd "${DOTFILES_ROOT:-"<your-dotfiles-clone>"}"

# OR use relative paths from known location
cd ../dotfiles  # from DevProjects/[repo]
```

**Usage in documentation**:
- Use `$DOTFILES_ROOT` in examples requiring absolute paths
- Use relative paths (e.g., `../dotfiles/SST3/...`) for cross-repo references
- Never hardcode `C:\Users\username` in documentation

<!-- stages: 4 -->
## DevProjects Directory Structure

```
DevProjects/              ← Local parent (not a git repo, not on GitHub)
├── dotfiles/             ← SST3 source of truth (git repo)
│   ├── SST3/            ← Workflow documentation
│   └── CLAUDE.md        ← Entry point
├── project-a/ ← Git repo (uses SST3)
│   └── CLAUDE.md        → ../dotfiles/SST3/...
├── project-b/        ← Git repo (uses SST3)
│   └── CLAUDE.md        → ../dotfiles/SST3/...

C:/temp/                  ← Shared temp folder
```

**Key Implications**: DevProjects/ is local only. Each repo is independent. SST3 lives in dotfiles/, referenced via `../dotfiles/SST3/`. Temp: `C:/temp/{repo}-{issue}-{description}.ext`.

<!-- stages: 4 -->
### Architecture Validation

**CRITICAL: DevProjects/ MUST NOT be a git repository.**

**Validation**: `cd .. && git status` → expected: `fatal: not a git repository`.

**If fails**: `cd .. && mv .git .git.DISABLED.{issue-number}` → remove duplicate files from DevProjects/ root → document → add to pre-commit hooks. See Issue #172.

<!-- stages: 4 -->
### DevProjects Cleanliness Enforcement

**Pre-commit hook** `check-devprojects-clean` validates DevProjects/ before
every commit. It is `always_run: true`, so it fires on its own changes.

The hook resolves DevProjects/ through
`sst3_mirror_utils.resolve_main_clone_root`, NOT through
`git rev-parse --show-toplevel`. From a linked worktree the latter returns the
worktree, whose parent is `<clone>/.claude/worktrees` — a directory that
exists, so the fail-fast passed and the hook exited 0 having opened no repo at
all (#565).

**Allowed:**

- Known repos: read from `sst3_utils.KNOWN_REPOS` — never hand-listed here.
  This line used to enumerate three repos against a real twenty-two; a
  hand-maintained tally rots on the next onboard, which is how it got that far
  out. The probed set is `probed_repos()`, read by every caller so no two can
  disagree. It is ROLE-SCOPED via `sst3_utils.expected_clones()`: on a `master`
  host it is KNOWN_REPOS plus the two mirror clones; on a `lab`/`prod` host it
  is `dotfiles` + `LAB_ROLE_REPOS`, which is what `install.sh` actually creates
  there. The role comes from `${XDG_CONFIG_HOME:-$HOME/.config}/sst3/node-role`,
  written by `install.sh`, and defaults to `master` when absent — the strict
  superset, so a missing marker fails loud instead of quietly narrowing the
  claim. A non-master run prints its scope on the paths that reach a scoped
  claim — the could-not-look arms and the role-scoped pass. It is NOT every
  path: `main()` has ten return points and the early ones exit before a role
  is resolved, so there is no scoped claim to qualify. (This bullet asserted
  "on every path, pass or fail" until #565 Ralph T3 round 3 measured it — the
  canonical twin of the same false claim in `scope_note()`'s docstring.
  Fixing the docstring alone would have left the STANDARD asserting it: AP #9.)
- Shared temp: `temp/`
- New git repos: Any directory containing `.git/`
- Disabled git: `.git.DISABLED.*` pattern

**Blocked:**

- Files at DevProjects/ root
- Folders not matching allowed criteria
- A `scaffold`-shaped repo that has grown a dependency manifest or a source
  root — `_SHAPE_SEC_DEP['scaffold']` is `(False, False)`, so both audit lanes
  report clean without running until `_REPO_SHAPE` is re-pointed
- A probed clone absent from disk, or a root holding none of them — a repo the
  hook never opened cannot support its "DevProjects is clean" claim, so it
  reports `PROBE_FAILED` rather than skipping silently. "Probed" is role-scoped
  (above), so a repo `install.sh` never clones on THIS role is not a failure;
  one it does clone still is. This line previously said `install.sh` "clones
  every one of them, so the printed remedy actually resolves the failure" —
  false on a `lab`/`prod` node, where the installer clones three repos and the
  gate demanded twenty-four, making an `always_run` pre-commit AND pre-push hook
  unpassable by construction while printing a remedy that could not fix it
- A probed clone holding commits that exist on no remote. Primitive:
  `git rev-list --count --branches --not --remotes=origin` — no network, no
  default-branch resolution. In-flight `solo/*` worktree branches and commits
  touching only `SST3-metrics/` are excluded by design; both are unpushed on
  purpose

Every could-not-look path reports `PROBE_FAILED` and exits non-zero. A probe
that could not run must never be indistinguishable from a probe that ran and
found nothing.

The exit-code half of that has always held. The MARKER half was false in
`check-devprojects-clean.py` until #565 Ralph T3 round 3: its
`except PermissionError` / `except OSError` arms printed a bare `ERROR: ...`,
demonstrated with a chmod-000 DevProjects root. Nothing passed vacuously —
both arms returned 1 — but anything ENUMERATING could-not-look outcomes by
grepping for the marker under-counted them. Both arms now carry it. The
lesson generalises: when a standard states two conjoined properties, verify
them separately, because the weaker one is where the drift hides.

**Script:** `../scripts/check-devprojects-clean.py`

**Reference:** Issue #249, Issue #565

<!-- stages: 4 -->
## Documentation Requirements

| Document | When Required | Max Size |
|----------|--------------|----------|
| README.md | Always | 80 lines |
| Inline comments | Complex logic only | Minimal |
| GitHub Issues | All decisions | N/A |

<!-- stages: 4 -->
### README Standards

**Philosophy**: READMEs follow both [Core Philosophy](#foundational-philosophy) principles:
- **JBGE**: Document only what's essential (4 key questions)
- **LMCE**: Deliver it effectively (80-line limit, clear structure)

**The 4 Questions Every README Must Answer**:
1. **What?** - What does this do? (1-2 sentences)
2. **Get?** - How do I get/install it? (Quick start commands)
3. **Install?** - How do I set it up? (Dependencies and config)
4. **Learn?** - Where can I learn more? (Links to docs)

**Structure**: Use the What/Get/Install/Learn format from `../templates/CLAUDE_TEMPLATE.md` (Project-Specific Configuration section).
```

**Enforcement**: None — the 80-line figure is an authoring guideline, not a gated check. No pre-commit hook enforces a README line-count limit, and several repo READMEs (the root README, the SST3 scripts-dir README) intentionally exceed it. Keep new READMEs lean per the What/Get/Install/Learn structure above; do not treat 80 as a hard ceiling.

**Per-Stage Feedback / Telemetry**: see canonical section "Per-Stage Feedback Capture (Canonical)" earlier in this file. The previous `SST3-metrics/retrospectives/` lifecycle (per-Issue retrospective files, quarterly review trigger) was superseded in #448 — `archive/retrospective-template.md` produced zero retrospectives across its lifetime; the new per-stage capture mechanism replaces it with 3-layer enforcement, dynamic stage discovery, and a closure-loop on improvements.

<!-- stages: 4 -->
### File Housekeeping

> Per-Issue housekeeping invariants: `stage-4/file-housekeeping.md`.

**Delete vs Archive**:
- **Delete**: Temp files, build artifacts, failed experiments with no learnings
- **Archive**: Superseded configs, old docs with context value, deprecated code worth reviewing later

**temp/ Folder**:
- **Location**: `C:/temp/` (cross-repo, shared by all projects)
- **Purpose**: Short-lived working files during active development
- **Naming**: `{repo}-{issue#}-{description}.{ext}` (e.g., `dotfiles-121-api-design.md`)
- **NOT for**: Handovers (use GitHub Issue comments)
- **Cleanup**: Script-based deletion when issue closed OR file age >30 days
- **Script**: `python $SST3/cleanup-temp.py` (dry-run by default)
- **Script Documentation**: See [scripts/README.md](../scripts/README.md)
- **Enforcement**: Pre-commit hook `no-temp-folder` blocks commits with temp/ paths (see Issue #241)

**Archive**:
- **Location**: `/archive` at repo root
- **Naming**: `filename_ARCHIVED_YYYYMMDD_reason.ext`
- **Example**: `old-config.json` → `/archive/old-config_ARCHIVED_20250108_superseded-by-new-config.json`

**Branch and Worktree Cleanup** (MANDATORY after merge):
- **When**: Immediately after merge to main, in the canonical sequence below
- **Step 1 — Confirm push landed**: `git ls-remote origin master` reports the solo-branch tip SHA (Gate-2 server-FF succeeded; do NOT proceed to step 2 until this is confirmed)
- **Step 2 — Remove worktree**: `ExitWorktree action:remove` (releases the worktree directory + drops the local solo branch metadata; metadata-only operation, AP-safe per `[[feedback-worktree-remove-is-metadata-not-cohabitation-mutation]]`)
- **Step 3 — Delete remote solo branch**: `git push origin --delete {branch-name}` (cleans up the worktree-published branch on origin)
- **Step 4 — Prune local refs**: `git fetch --prune` (drops stale `origin/<solo>` ref)
- **Verify**: `git branch -a` shows no orphaned branches for completed issues; `git worktree list` shows no orphaned worktrees
- **Monthly**: `git branch --merged master | grep -v "master" | xargs -r git branch -d`; `git worktree prune` to clean up any stragglers

**Rollback Cleanup**: See `../reference/self-healing-guide.md` for full rollback procedures. Key: one logical change per commit (enables surgical `git revert`), separate debug commits, document rollback in Issue before restarting.
- **Implementation guidance**: Commit incrementally (per-file) supports this strategy

**Removal Reporting** (Issue #119): When removing content, post a brief summary (`File: section (-X tokens/lines) — Removed: X, Kept: Y`) so user can approve deletions quickly.

<!-- stages: 4 -->
## "READ IN FULL" Warning Criteria

Add if: sequential checklists, interdependent instructions, skipping causes failures, order matters.
Skip if: pure reference/lookup, independent sections, spot-check only.

**Format**: `**⚠️ READ IN FULL - DO NOT SKIP SECTIONS ⚠️**` + `**This document contains [type] that must be [action]. Selective [action] causes [consequence].**`

**Cleanup Empty Folders**: After archiving/deleting files, remove empty directories

<!-- stages: 4 -->
### Issue #108 Lesson: Why Housekeeping Repetition is Intentional

Housekeeping in 3 places (during work, after merge, STANDARDS.md) is intentional — each is a different execution context. Compressing them caused file sprawl (Issue #108). Prevention > Cure.

<!-- stages: 4 -->
## Code Quality

<!-- stages: 4 -->
### DO
- [ ] Set up pre-commit hooks (`$SST3/check-propagation.py`, `$SST3/auto-stage-tracked-folders.py`)
- [ ] Write tests for critical paths (85% bug catch rate at Verification Loop)
- [ ] Isolate components with clear interfaces
- [ ] Require PR review before merging
- [ ] Run automated tests in CI/CD
- [ ] **State-machine & persistence-schema rule (#516 AC 4.1)**: any PR shipping state-machine / crash-recovery / idempotency / atomicity logic MUST include a `state-diagram-as-comment` enumerating all reachable states and valid transitions in the same commit. Schema fields representing 3+ states MUST be string enums at design time — never a bool-with-a-magic-third-state.

<!-- stages: 4 -->
### DON'T
- [ ] Skip tests for "simple" changes
- [ ] Bypass pre-commit hooks (`$SST3/check-propagation.py`, `$SST3/auto-stage-tracked-folders.py`)
- [ ] Mix concerns in single modules
- [ ] Merge without passing tests
- [ ] Ignore linter warnings

<!-- stages: 4 -->
## Three-Tier Testing Framework

> Stage-4 BUILD/USE summary: `stage-4/three-tier-testing.md`.

> **Source of truth**: the operator's verbatim framing of the three tiers (the car analogy + the BUILD-vs-USE clarification), recorded in the originating Issue's verbatim Source block. This section transcribes that framing; it does NOT paraphrase it into any one project's failure-mode list. On any conflict the verbatim Source block wins. (Meta: the anti-twist rule — "Polish vs Twist (Semantic Frame Preservation)" / ANTI-PATTERNS.md AP #25 — applies to this section's own wording.)

SST3 **builds and uses three co-equal test tiers** that work together (they compose, never substitute). They are named (namespace decision — these are NEVER rendered as bare "Tier 1/2/3" inside Ralph review files, which already use that for the Haiku/Sonnet/Opus review tiers, nor confused with the AP #20 "Tier A/B" checkbox cadence): **Unit Tier**, **Workflow Tier**, **E2E Tier**. The only permitted compact form is "Test-Tier 1 / Test-Tier 2 / Test-Tier 3".

**the operator's car analogy** (comprehension aid — NOT the label):
- **Unit Tier** = a QC check on a single cog / process / part — like a piston in a car engine. Checks the quality and calculations are correct and the part works as designed and intended.
- **Workflow Tier** = many cogs / processes / parts working together as a component — like the car engine working. Ensures the whole component works; finds problems that need fixing, and wiring.
- **E2E Tier** = the system: all components working together systematically end to end — like taking the car for a driving test. Everything works together, no breakage, results as expected and intended; finds problems that need fixing systematically, and wiring.

<!-- stages: 4 -->
### Unit Tier
- **Scope**: a single unit — one function / cog / calculation / part on its own.
- **What it catches**: wrong calculations, wrong output for a given input, the part not behaving as designed/intended.
- **When run**: on any change touching that unit; cheapest and fastest, run most often.
- **Where it lives**: the project's unit-test suite (checked in).
- **Who writes it**: whoever changes the unit, in the same change.
- **SST3 enforcement primitive**: the call-seam grep — "Test-Prod Call Coverage Discipline" (a new public callable / payload field / config key with no test exercising it = FAIL). That seam IS the cog-QC gate.

<!-- stages: 4 -->
### Workflow Tier
- **Scope**: a component — many units wired together (a pipeline, an orchestration path, a multi-step workflow).
- **What it catches**: units individually fine but the COMPONENT broken — wiring gaps, cross-module arg propagation, a step that silently does nothing, mismatched contracts between parts.
- **When run**: when a change affects how units connect (more than one unit, or the wiring between them).
- **Where it lives**: the project's workflow/integration tests + the real-CLI sample invocation.
- **Who writes it**: whoever changes the workflow wiring.
- **SST3 enforcement primitive**: ANTI-PATTERNS.md AP #18 "Smoke-Tested Pipeline Shipped Without End-to-End Sample Run (Workflow-Tier validation)" — smoke is necessary but NOT sufficient for component wiring.

<!-- stages: 4 -->
### E2E Tier
- **Scope**: the whole system — all components together, end to end, against the real environment (real DB, real downstream consumers, real interfaces).
- **What it catches**: what only the full system reveals — real-DB schema drift, downstream-consumer rejection, environmental assumptions, integration regressions no single component test sees. The driving test.
- **When run**: when a change can impact the whole system (cross-component, schema, contract, environment).
- **Where it lives**: the project's E2E/system tests, exercising production code paths — NOT parallel test logic (search production code before writing any helper).
- **Who writes it**: whoever ships a change with whole-system blast radius.
- **SST3 enforcement primitive**: ANTI-PATTERNS.md AP #26 "E2E System Verification".

<!-- stages: 4 -->
### BUILD vs USE (load-bearing — both halves required: all 3 tiers EXIST *and* all 3 RUN every change)
- **BUILD: always all 3 tiers.** Every change ships with Unit + Workflow + E2E tests. The tests must EXIST. There is no "this is only a unit, skip tier 2/3" exemption at authoring time.
- **USE: all 3 tiers RUN (fire & pass) on EVERY change** (operator directive 2026-06-13, dotfiles#528 — this SUPERSEDES the prior "situational / scope-matched fire" rule, of which the operator is the authority). At the Verification Loop, Unit AND Workflow AND E2E each RUN and PASS for this change. The E2E Tier may be *sized* to the change — a small backtest, or an actual execution change + cleanup, where a full whole-system E2E does not apply — but it still RUNS. The ONLY permitted non-run is a tier explicitly recorded `structural-inapplicable: <reason>` (rare — e.g. a pure-doc diff has no Unit surface). Tiers **compose, never substitute** — a higher tier passing does not excuse a missing lower-tier test, and a lower tier passing does not prove the system.
- **Why both halves**: BUILD (all 3 exist) means the E2E Tier is THERE the day a "small" change unexpectedly impacts the whole system; RUN (all 3 fire every change) means a mis-wired or system-breaking change is caught at the commit that introduced it, not in a later incident — the operator's named failure mode: "it always does unit tests and nothing more … so workflow and E2E tests are never done", and "simple broken implementations that isn't wired properly" slip through. Drop BUILD → the safety net is absent when suddenly needed. Drop the all-3-RUN rule → exactly that: only the Unit Tier ever fires and un-wired implementations ship.

<!-- stages: always -->
### Run procedure (operationalises BUILD-vs-USE — all 3 tiers RUN; blast radius only SIZES the E2E tier)
Run this at authoring time AND again at the Verification Loop:
1. **BUILD is unconditional**: all 3 tiers' tests must EXIST for the affected surface — write the missing ones in this change. No "unit-only, skip the rest" at authoring time.
2. **RUN is unconditional**: all 3 tiers RUN (fire & pass) for this change. No scope-skip — a tier that exists but never fires catches nothing.
3. **Identify the blast radius** — this no longer decides WHICH tiers run (all 3 do); it SIZES the E2E tier: whole-system change (schema, contract, environment, cross-component) → full E2E against the real environment; workflow- or unit-scoped change → E2E may be a small backtest or an actual execution change + cleanup that exercises the changed path end-to-end. Either way the E2E tier RUNS.
4. **The ONLY non-run is `structural-inapplicable: <reason>`** — a tier with genuinely no surface for this change (rare; e.g. a pure-doc diff has no Unit surface). Record the reason inline; never silently skip a tier.
5. **When unsure whether a tier is structural-inapplicable, RUN it** — running a tier is cheap; a wrongly-skipped tier is the incident. Under-claiming inapplicability is the safe direction.
6. **Record the required evidence line** (defined ONCE, immediately below) in the Verification-Loop evidence. "All tests pass" without the per-tier line is not evidence.

**Required tier-evidence line (defined ONCE here — `WORKFLOW.md` Verification Loop + `issue-template.md` PREREQUISITE CHECKPOINT point to this definition, never redefine it):**
```
tiers: U=<pass|fail|structural-inapplicable:reason> W=<pass|fail|structural-inapplicable:reason> E2E=<pass|fail|structural-inapplicable:reason> M=<reddened+control-green|unproven|n/a:no-gate-in-diff> | BUILD-evidence:<file:line of the checked-in test per tier>
```
All 3 tiers must show `pass` (or a documented `structural-inapplicable:<reason>`). A `fail` blocks the Verification Loop; a bare "tests pass" without this line does not satisfy the gate. The `M=` field is the mutation-verification result for gate-bearing diffs (#567 — spec: `stage-4/mutation-verification.md`, duty site: the `stage-4/three-tier-testing.md` PROVE clause): `M=unproven` blocks exactly as a `fail` does — a gate-bearing diff without its mutation table is `unproven`, never `passed`; `M=n/a:no-gate-in-diff` records that the diff carries no gate. <!-- c4:T21 --> The evidence beside the line records the exact command per tier (literal invocation, not only a count).

<!-- stages: 2 -->
### Tier composition — never substitute (worked illustration, general)
A change adds a new calculation, used by a pipeline step, consumed by a downstream system:
- Unit GREEN, Workflow + E2E absent → the calculation is correct in isolation but nothing proves the step calls it right or the downstream accepts the result. **Not done.**
- Workflow GREEN, Unit absent → the pipeline runs on sample input but a boundary input the sample missed is mis-calculated. **Not done.**
- E2E GREEN, Unit + Workflow absent → the system worked for the one path E2E hit; a sibling path is silently broken with no cheap signal to localise it. **Not done.**
- All 3 BUILT and all 3 RUN (E2E sized to the change) → every failure surface is exercised at the change that introduced it; nothing waits for a later incident. **Done.**
Higher tiers do NOT substitute for lower (a passing system does not prove every unit); lower do NOT substitute for higher (correct units do not prove the wired system). They COMPOSE.

<!-- stages: 2 -->
### Why three — not two, not four
Three is canonical because it maps to the three real failure surfaces: a part is wrong (Unit), the parts are wired wrong (Workflow), the whole system meets reality wrong (E2E). Collapsing Workflow into Unit loses the wiring-gap class; collapsing E2E into Workflow loses the real-environment / real-downstream class. Adding a fourth tier (mutation / property / contract testing) is explicitly out of scope — those are *techniques applied within* a tier, not a fourth surface — and for GATES that is a duty, not an option: any diff adding or modifying a gate carries mutation verification per the `stage-4/three-tier-testing.md` PROVE clause and `stage-4/mutation-verification.md` (a gate is unproven until it has been shown to fail; #567). the operator's 3-tier framing is the canonical taxonomy; do not split or merge it.

<!-- stages: always -->
### Glossary: "regression test" vs the three tiers
"**The project test suite**" — what the Stage 4 Verification Loop runs, and what "no regressions" refers to — is the **union of the checked-in Unit + Workflow + E2E tests**, not any single tier. "**Regression test**" is NOT a synonym for the Unit Tier, nor for any one tier: it is the property that the existing suite (all tiers together) still passes after a change. "**Smoke test**" is a fast subset (typically Unit-Tier-weighted) — necessary but NOT sufficient for the Workflow or E2E tiers (AP #18). Use a tier name when you mean a tier; say "the project test suite" / "regression run" when you mean "all checked-in tests still pass". <!-- c4:T25 --> Gate 1 runs the project test suite locally when CI is dark (WORKFLOW.md Verification Loop).

<!-- stages: 2 -->
### Cost of skipping each tier (why BUILD is unconditional)
- **Skip the Unit Tier** → boundary-input and calculation errors ship; the bug surfaces deep in a workflow or in production where it is expensive to localise back to the single wrong cog. The cheapest possible signal was simply never built.
- **Skip the Workflow Tier** → every unit is correct in isolation but the component is mis-wired (a step that silently no-ops, an arg dropped across a module boundary, a contract mismatch between parts). Unit tests are structurally blind to this — it is exactly the #1424 class (component tests passed; the wiring did not).
- **Skip the E2E Tier** → the component bench-tests fine but the live system rejects it: real-DB schema drift, a downstream consumer's real contract, an environment assumption only production encodes. Only the assembled system against the real environment reveals it — by then it is an incident, not a test failure.
- **Compounding**: a skipped lower tier also makes a higher-tier failure harder to localise (an E2E failure with no Unit/Workflow coverage gives no narrowing signal — you bisect the whole system by hand).
- **The asymmetry**: building a tier costs minutes once; the absent tier costs an incident at the worst possible time, plus the localisation tax above. That asymmetry is why BUILD is unconditional — and why USE is now unconditional too: all 3 tiers RUN every change, because a tier that exists but never fires catches nothing (the operator's "workflow and E2E are never done" failure mode). The only non-run is a documented `structural-inapplicable:<reason>`.

<!-- stages: 2 -->
### Where this is enforced
- **WORKFLOW.md Verification Loop** — the three named tier checkboxes, each encoding BUILD (tests exist) + USE (all 3 RUN this change — the required tier-evidence line above). Canonical; this is where the gate actually lives.
- **Leader.md Gate 1 + SST3-solo.md Verification Loop** — reference the WORKFLOW.md tiers; they do NOT re-define them (single-source).
- **issue-template.md PREREQUISITE CHECKPOINT** — splits into three tier bullets so every Issue scopes all three at draft time.
- **Ralph `sonnet-review.md`** — per-tier test sections + the E2E-Tier system gate (review-time verification).
- **Anti-pattern / enforcement anchors** — Unit Tier = "Test-Prod Call Coverage Discipline" (call-seam grep); Workflow Tier = AP #18 "Smoke-Tested Pipeline … (Workflow-Tier validation)"; E2E Tier = AP #26 "E2E System Verification".
- **Per-shape mapping** — the per-shape recipe table in `../reference/ap18-workflow-tier-reference.md` carries a "Tier coverage (Unit / Workflow / E2E)" column; the CLAUDE.md per-repo narrative twin is annotated to match and kept in sync in the same pass (AP #9 single-source-edits).

---

<!-- stages: 4 -->
## Security & Dependency Audit Gate

Doctrine home for the SEC lane (`sst3-sec-*`, offline ast-grep) and the DEP lane (`sst3-dep-*`, dependency/CVE audit). Pointer: ANTI-PATTERNS.md AP #27 (built-but-unwired = false comfort). An audit lane is not done until it fires automatically in a cadence — building it is necessary but not sufficient.

**Shape-gating (no vacuous PASS).** SEC/DEP run only where they can actually parse the production surface. Applicability is resolved by `sst3_utils.sec_dep_applicable(repo_or_shape) -> {sec, dep}`:
- **Code-bearing → run**: Service, eBay-MCP, Config-heavy (ast-grep-parseable Python/Rust/JS + a dependency manifest — SEC and DEP both run), and mt5-ea (SEC only: ast-grep-parseable Python production surface but NO dependency manifest, so DEP skip-clean is honest, not vacuous — the `(True, False)` pair in `_SHAPE_SEC_DEP`, #567 Phase 7).
- **Skip-clean → do NOT run**: non-code shapes (Static-blog/Static-site/Voice-doc/Brainstorm/Business-ops), day-1 scaffolds, AND surfaces ast-grep/pip-audit cannot parse — GAS (`.gs`, test-harness Python only) and lab-automation (PowerShell + bash). Running SEC/DEP there would scan nothing meaningful and report a clean PASS that means nothing — the precise false-PASS this gate exists to prevent. The helper fails loud on an unknown repo/shape rather than defaulting to a silent skip. A TypeScript-only service (`service-ts`) runs DEP (npm audit) but not SEC, whose wrappers read TypeScript only for subprocess calls and secret literals. GAS, lab-automation and `service-ts` hold production code, so their SEC skip is could-not-look, not clean: `sst3_utils.sec_skip_reason()` names it, the gate prints it, and the lane is recorded `structural-inapplicable` with a raw-grep sweep (c4:T16).

**Fail-loud contract (three signals).** SEC/DEP use the existing `sst3-check.sh` orchestrator. `--strict` escalates any wrapper that **could not look** to **exit 2** (distinct from findings=1 and clean=0); the per-phase stderr-sentinel must be present to confirm a wrapper actually ran. Could-not-look is **engine-missing OR phase-timeout OR phase-error OR a missing wrapper script OR a non-executable wrapper** — every one means the run did not establish that the target is clean, and none may be waved through. Do not read that list as closed: it is the set of routes MEASURED so far, and it has grown twice. It said "all three" until #565 Ralph round 10 measured a fourth and fifth — a wrapper absent from disk, and a wrapper present but not executable, both recorded as `skipped`, which nothing consumed, so `--strict` returned **0** with an EMPTY stderr, byte-identical to a run where every phase completed. The lesson generalises past this contract: when you convert the members in front of you, go and look for the ones that arrive by a different path first. Engine-missing is re-run after `<your-dotfiles-clone>/scripts/install.sh`; a timeout is re-run with a larger `SST3_CHECK_PHASE_TIMEOUT` (default 90s per phase). Timeout was added to this contract by dotfiles#565 escalation-1, which measured the orchestrator recording `doc-lint:timeout` in its phases array while nothing gated on it: only engine-missing and findings drove the exit code, so a timed-out phase on an otherwise-clean tree exited **0**. Worse, a timeout REDUCES the finding count (measured: 326 with all phases complete, 189 with two timed out), so the vacuous run looks like an improvement. Diff-scope with `--paths-from <ndjson>` (forwarded to the SEC/DEP wrappers).

**dependabot boundary (no duplication).** `.github/dependabot.yml` and the `sst3-dep-cve` lane do NOT overlap: **dependabot** opens *scheduled upgrade PRs* (it bumps versions), while **`sst3-dep-cve`** is an *on-demand / PR-time CVE scan* emitting NDJSON findings (it reports, it does not bump). They are complementary — keep both.

**Which surface wires what.** SEC (offline) wires into the Ralph **Sonnet** tier (diff-triggered, shape-gated, gating) + a pre-commit local hook (Claude's own edits) + a pre-commit-framework **pre-push** hook (operator/non-Claude commits the security-guidance plugin cannot see). DEP-cve (network) wires into a **GHA** security job (`sec-dep-audit.yml`), NOT pre-commit (network calls do not belong in the commit path). All are shape-gated; non-applicable shapes skip-clean.

---

<!-- stages: 4 -->
## Testing Priority

Test in this order:

1. **Critical Paths** (MUST work)
   - Authentication
   - Payment processing
   - Data persistence

2. **Integration Points**
   - API boundaries
   - External services
   - Component interfaces

3. **Edge Cases**
   - Error handling
   - Boundary conditions

4. **Everything Else**
   - UI polish
   - Nice-to-haves

**Minimum coverage**: 85% for Stage 5 verification

<!-- stages: 2,3 -->
### Workflow Validation Gate (AP #18 — MANDATORY)

> Stage-4 loop checkboxes: `stage-4/verification-loop.md`.

This gate fires at TWO ends of the workflow:
- **Pre-Stage-3 (AC Verifiability)**: every AC must be falsifiable (see "AC Verifiability — pre-Stage-3 sub-gate" below).
- **Stage 4 (Sample Invocation)**: every implementation must pass real-CLI sample invocation against real DB (the AP #18 rule below).

Unit + smoke tests are necessary but NOT sufficient for pipeline / backtest / CLI-wiring / cross-module propagation changes. Every such change MUST pass a **real-CLI sample invocation** against real DB before the issue closes.

**Per-shape recipes**: the per-shape sample-invocation table in `../reference/ap18-workflow-tier-reference.md` (not restated here: a copy rots). Non-auto_pb repos use their shape's recipe from that table, not the auto_pb 8-item-liquid-basket pattern.

Cross-link: the **three-signal contract policy** + **Raw-tool cross-validation REQUIRED moments** + **AI-agent fallback heuristic** above ("Structural Code Queries" section) bound when raw-tool counter-queries become MANDATORY at the wrapper-lane boundary. AP #18 sample invocation and raw-tool cross-validation are complementary gates: AP #18 covers downstream-consumer verification, the raw-tool counter-query covers recall verification. Both fire on wrapper-script changes per Phase 5.

**Applies to (ANY match → gate active):**
- New/modified CLI flags threaded into downstream function signatures
- SL1 / SL2 / backtest / queue-orchestrator / pipeline wiring
- Coverage pre-flights, auto-bootstrap paths, snapshot-suffix / experiment-path logic
- Multi-module function-arg propagation chains (>1 hop from CLI to DB write)
- Any change where a `**kwargs`-accepting mock could silently hide the regression
- **Idempotency re-run paths**: for idempotency or feature-detect logic (e.g. "if X already configured: skip"), the sample MUST cover BOTH first-install AND re-run-with-feature-already-present paths.
- **Documentation cross-reference resolution**: for infrastructure-shape work (e.g. homelab bootstrap), a Stage 5 swarm angle MUST confirm every script-path / URL / file-reference / cross-link in the Issue's docs resolves (`ls`/`grep -F` exit 0, `curl -fsI` 2xx).
- **Every-return-path wiring**: for added cache-read or guard helpers ("check state and return early"), Stage 4 must enumerate every `return` in the guarded function (`grep -n return <file>`) and confirm each emits the new instrumentation/cache-write OR is documented exempt.

**Gate (verification loop item — NOT optional)**:
1. Small liquid basket (8 tickers typical), real CLI, real DB.
2. Verify rows land; downstream consumers (contamination audit, snapshot copy, dashboard display) succeed.
3. Mocks MUST assert explicit kwargs (`call_args.kwargs["window_start"] == expected`). No `**kwargs`-swallowing proof.
4. Stage 5 integration test added for every new cross-module signature or CLI flag.

**Enforcement**: AP #18, Stage 4 Verification Loop, `issue-template.md` PREREQUISITE CHECKPOINT.

<!-- stages: 2,3 -->
#### AC Verifiability — pre-Stage-3 sub-gate (Theme 10, #477)

**Principle**: Every Acceptance Criteria checkbox MUST have an explicit verification command/method that is **falsifiable** (binary pass/fail). Unfalsifiable ACs leak through Stage 2 audit because subagents can rubber-stamp ambiguity ("looks reasonable") — the gate MUST fire BEFORE swarm dispatch, not after.

**Failure mode**: subjective ACs ("cleaner architecture", "better performance", "improved coverage") get marked `[x]` at Stage 4 with vibes-based evidence. Stage 5 audit can't reject them because there's no falsifiable test to fail. The contract becomes infinitely flexible.

**Reject (unfalsifiable)** — examples observed in #477 prior-feedback aggregation:
- "subsystem length ≤500 lines" — line counts not bound to a specific file/path
- "improved coverage" — no metric, no threshold, no source of truth
- "cleaner architecture" — subjective, no test
- "better performance" — no baseline, no measurement, no pass/fail
- "more maintainable" — no proxy metric (cyclomatic complexity, file count, dep count)
- "reduce duplication" — no count of duplicates eliminated

**Accept (falsifiable)**:
- ``wc -l <specific-file>`` returns N where N ≤ 500 (file path explicit)
- ``pytest tests/<specific>.py`` exit 0 (or specific test count)
- ``grep <pattern> <specific-file>`` returns ≥N matches (pattern + file explicit)
- ``coverage report --include=<file>`` returns ≥N% (N stated)
- ``radon cc <file> -a`` returns avg ≤B (or per-function rank ≤C)
- File at `<specific-path>:<line-range>` contains the named text/structure (verbatim)
- Command + expected output recorded inline in the AC

**Path portability (dotfiles#516 Stage 5)**: verification commands MUST use **repo-relative paths** run from the repo root (e.g. `grep -nE '...' STANDARDS.md`, `wc -l <path-under-the-repo>`), never a main-clone-absolute path (`/home/<user>/DevProjects/<repo>/...`). An absolute canonical-clone path silently no-ops when CWD is a Stage-4 worktree (the AC 4.2 / AP #29 canonical-clone-absolute-path failure) AND false-FAILs when run against a main clone that has not been fast-forwarded post-merge. An AC whose own verify command hardcodes the main-clone path is not portably falsifiable — rewrite it relative before dispatch.

**Pre-fix FAIL assertion (#522)**: a falsifiable verify is not enough — it must also DISCRIMINATE. Dry-run each AC verification command against the current PRE-FIX tree and confirm it returns the FAIL value (non-zero exit / the pre-impl count); a verify that passes pre-fix is vacuous (it would pass whether or not the work is done) and MUST be re-scoped (line-range / exact-pattern / call-site anchor) before dispatch. Pin `/usr/bin/grep` in any piped grep verify — the default `grep` is a ugrep function wrapper that emits nothing in a pipe, a silent vacuous PASS. <!-- c4:T08 --> The verify also runs through the enforcing gate, on artefacts that exist by the end of its own phase, over the AC's full contract, evidenced on the named target.

**Enforcement**:
- Leader.md Stage 2 step 4e (AC verifiability sweep — author runs before subagent dispatch).
- issue-template.md "AC Verifiability Gate" subsection (template-time gate).
- Stage 3 sanity-check subagent angle: any AC without falsifiable verification = block issue creation until rewritten.

**Apply rule**: ACs without falsifiable verification get rewritten in-place OR moved to Cleanup Requirements with rationale BEFORE subagent dispatch. Do NOT pass unfalsifiable ACs into the Stage 3 swarm — subagents anchor on whatever scope they receive.

**Verify**: ``grep -cE '^- \[ \] \*?\*?\(?[0-9]+\.[0-9]+' <issue-draft>`` returns count of ACs; spot-check 3-5 random ACs and confirm each carries either a verification command (`grep`/`wc`/`pytest`/`exit 0`) OR a verbatim file:line target. Document any reject→rewrite in the per-stage feedback file Stage 2 `worked` field.

**Self-gate Tier A ACs** (dotfiles#495 FRAG-2): Self-gate Tier A ACs (AC whose verification literal IS the Stage-5 sign-off of the Issue containing them — i.e. self-referential closure dependency) MUST be tagged `<!-- self-gate-ac: <reason> -->` on the line IMMEDIATELY preceding the checkbox; see `../templates/issue-template.md` `### Self-Gate AC Marker` for the canonical convention. Without the tag the cadence hook treats the AC as a normal Tier A and blocks Phase-N+1 commits per AP #20.

<!-- stages: 4 -->
### Test-Prod Call Coverage Discipline (Theme 9, #477)

**Tier: Unit Tier enforcement primitive.** The call-seam grep (every new public callable / response-payload field / config key must be exercised by a test) IS the cog-QC gate of the **Unit Tier** — see STANDARDS.md "Three-Tier Testing Framework". A unit that no test calls is a piston nobody QC'd.

**Distinct from**: AP #18 Workflow Validation Gate (end-to-end pipeline sample) AND the regression-test gate (broader). This discipline targets the specific failure mode where a function compiles, lints, and ships but is never actually exercised by any test — the **call-site seam** between new prod code and tests is missing.

**Three-bullet doctrine** (each bullet is a falsifiable check):

1. **Function call seams**: For every new public function/method added in a phase, name the test file that imports + invokes it. Verification: `grep -rnE 'from <new-module> import|<new-module>\\.<callable>' tests/`. Empty grep on a new public callable = FAIL.
2. **Response-payload field assertions**: For every new field added to an API response / JSON payload / dict structure, name the test that asserts the field's presence + value. Verification: `grep -rnE '<field-name>' tests/`. Field with no assertion = FAIL.
3. **Config-key read coverage**: For every new config key read by code (YAML/env/dict), name the test that exercises the read path. Verification: `grep -rnE '<config-key>' tests/`. Config read with no test = FAIL.

**Why it's distinct from AP #18**: AP #18 verifies the end-to-end pipeline lands rows (downstream-consumer verification). Test-Prod Call Coverage verifies the function-level seam exists at all (a function with no test caller can pass AP #18 if the pipeline never invokes it during the sample run, and pass Workflow Validation Gate if it ships untouched).

**Why it's distinct from regression tests**: regression tests cover existing behavior; this discipline targets NEW prod code added in the current phase. The grep pattern is scoped to the diff, not the full codebase.

**Enforcement**:
- `ralph/sonnet-review.md` Test-Prod Call Coverage section (Tier 2 logic-depth gate).
- `.claude/commands/Leader.md` Stage 4 step 3.5 (per-phase-boundary author sweep before MCP close-out).
- Phase-boundary AP #20 close-out: every Tier A box claiming a new public callable MUST cite the test file in evidence.

**Apply rule**: when phase work introduces a new public callable / response field / config key, the implementer runs the matching grep BEFORE closing the phase via MCP. Empty grep = test seam missing = FAIL the phase boundary; either add the test seam OR document explicit no-test-needed rationale (rare; usually only valid for trivial dataclasses or pure-data exports).

<!-- stages: 1 -->
### Marker-Substring Discipline (Theme 2, #477)

**Cross-reference**: full rule lives in `ANTI-PATTERNS.md` AP #24 ("Marker-Substring Changes Without Full Emit-Site Enumeration"). This subsection is the STANDARDS.md anchor — short paragraph + two-stage contract. (Sample-run anchor for #477 Phase 6 AC 6.7 — `STANDARDS.md` edited to exercise the post-commit `sst3-tier-a-auto-tick` hook end-to-end against the live #477 Issue body.)

**Two-stage contract** (all marker substring changes — error-message partition string, counter name, diagnostic flag, feature-gate literal, status-enum value, log-line prefix):

1. **Stage 1 baseline grep enumeration** — before any implementation, run `grep -rn -F '<exact_literal>' src/ tests/ scripts/ --include='*.py'` (or per-language equivalent) over the entire codebase. Record count + per-site triage (emission / fixture / mock / stale) in the Issue body as "Known Emit Sites: (N)".
2. **Stage 4 count-drift verification gate** — at Verification Loop, re-run the same grep. Confirm count matches the Stage 1 baseline. Mismatch = either implementation added emission sites that should have been in scope (expand scope) or removed sites that shouldn't have changed (revert removal). Either way FAIL until reconciled.

**Why it's distinct from AP #18**: AP #18 verifies the end-to-end pipeline lands rows under sample invocation. Marker-Substring Discipline verifies the SCOPE of marker references is enumerated and updated together. The two gates are complementary; both fire when the marker change affects pipeline / CLI args / cross-module propagation.

**Why it's distinct from AP #10**: AP #10 prevents creating a duplicate of something that already exists (search before adding). AP #24 prevents incomplete change of something that already exists (enumerate every reference before modifying).

**Enforcement**: ANTI-PATTERNS.md AP #24 (canonical rule), `.claude/commands/Leader.md` Stage 1 step 2.1 (subagent dispatch), `WORKFLOW.md` Verification Loop (Stage 4 Gate 1 checkbox).

**Generalisation to pattern-classes (AP #14e — dotfiles#495)**: the same enumeration discipline applies when the change is not a single string literal but a regex/glob/pattern-class extension across multiple files (e.g. extending `^solo/issue-(\d+)-` to `^(?:solo/|worktree-solo\+)issue-(\d+)-` across cadence-gate + branch-guard + auto-tick + metrics-feedback + GHA branch triggers). Stage 1 enumerates every site of the class via `grep -rnE '<class-pattern>' SST3/ scripts/ claude/ tests/ .github/ --include='*.py' --include='*.sh' --include='*.yml' --include='*.md'`; classifies each match as (a) canonical-aligned, (b) intentionally narrower (with WHY), (c) BUG (silent class-blindness — in-scope AC, partial-fix not an option). Stage 4 Verification Loop re-runs the enumeration. See ANTI-PATTERNS.md AP #14e for evidence + the dotfiles#495 instantiation (parse_issue_from_branch + GHA branch trigger were two distinct sibling-fix-pattern misses in one Issue).

<!-- stages: 4 -->
## Modularity Standards

<!-- stages: 4 -->
### Single Responsibility
Each file/function does ONE thing well.

<!-- stages: 4 -->
### Clear Interfaces
Each function/class: single responsibility, typed parameters, descriptive name. `calculate_price(item: Item, discount: float) -> Decimal` not `process_stuff(data)`.
```

<!-- stages: 4 -->
### Component Isolation
- Separate concerns into distinct modules
- Use dependency injection
- Avoid tight coupling
- Follow DRY principle

<!-- stages: 4 -->
### Checklist
- [ ] One responsibility per function
- [ ] Clear input/output contracts
- [ ] No circular dependencies
- [ ] Testable in isolation
- [ ] Reusable components

<!-- stages: 4 -->
### Finding Reusable Modules

Before creating new code: search with Glob/Grep/Agent(Explore), check `docs/INDEX.md`, `docs/components/`. Extend existing — don't duplicate. If new: add documentation. See WORKFLOW.md Stage 1.

<!-- stages: 4 -->
## Git Workflow

<!-- stages: 4 -->
### Branch Naming
`solo/issue-{number}-{description}` (Solo workflow — primary)
`type/issue-number-description` (legacy format)

Examples: `solo/issue-399-sst3-deep-cleanup`, `fix/80-auth-bug`, `docs/81-update-readme`

<!-- stages: 4 -->
### Commit Format
```
Brief description of change

Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>
```

<!-- stages: 4 -->
### PR Checklist
- [ ] Links to issue
- [ ] Clear description
- [ ] Tests pass
- [ ] Code reviewed

<!-- stages: 2,3 -->
### Issue & PR Naming Standards

**Principle**: Titles must be self-contained and discoverable without context. Embedding issue/PR numbers causes confusion (documented in Issues #225, #294).

**DO**:
- Use `[Phase X]` for hierarchical work (e.g., `[Phase 1a] Database Schema`)
- Use `[Stage X]` ONLY for SST3 workflow documentation
- Create self-contained titles (no issue/PR number references)
- Track relationships in body: Issues use "Implements #X", PRs use "Related to #X"
- PRs: Use TYPE prefix (feat, fix, refactor, docs, test, chore)

**DON'T**:
- Embed issue/PR numbers in title (e.g., "[#179]", "(Issue #42)")
- Mix [Stage X] and [Phase X] (they serve different purposes)

<!-- stages: 2,3 -->
### Marker Distinction (CRITICAL)

| Marker | Scope | Example |
|--------|-------|---------|
| `[Stage Xa-z]` | SST3 workflow ONLY | `[Stage 1] Issue Enforcement Validation` |
| `[Phase Xa-z]` | Project hierarchical work | `[Phase 1a] Database Schema Design` |

When you see `[Stage X]`, it's SST3 process work. `[Phase X]` is project feature work. NEVER mix.

**When to Use**: Sequential phases (`[Phase 1a]`, `[Phase 1b]`), sub-phases with letters/numbers. Skip markers for standalone features, simple bugs, single-issue implementations.

**Good**: `[Phase 1a] Database Schema Design`, `feat: Add email validation`, `Fix auth timeout`
**Bad**: ❌ `Sub-issue [#179] Database Schema #180`, ❌ `feat: Add validation (#42)`

**Enforcement**: Triple-Check Gate (Issues) and Verification Loop (PRs) validate naming. New items only; legacy exempt.

<!-- stages: 4 -->
### PR Linking Convention

**ALWAYS use**: `Related to #X`
**NEVER use**: `Closes #X`, `Fixes #X`

**Reason**: Issues closed manually after user review, not auto-closed on merge. Prevents premature closure.

**Enforcement**: PR template pre-fills "Related to #". Verification Loop verifies format.

<!-- impact-roi-carve-out -->
**NEVER force push to main/master**

<!-- stages: 2,5 -->
## Checklist Enhancement Process

**Principle**: Enforcement gaps → add checkboxes to workflow checklists, not explanatory paragraphs. Checkboxes force execution; explanations get skipped.

**Process**: Identify gap → add direct actionable checkbox to appropriate stage → reference STANDARDS.md for detail.
- ✓ `[ ] Verify: Components follow single responsibility (Modularity - STANDARDS.md)`
- ✗ Adding 5 paragraphs explaining modularity to stage file

**Impact**: Issue #248 found 40+ enforcement gaps fixed this way.

<!-- stages: 2 -->
## Template Accuracy Principle

**Principle**: Templates must match workflow instructions exactly. Instruction conflicts with template → template is wrong.

**Prevention**: When updating workflow, update templates in the same commit. Triple-Check Gate + Verification Loop verify against templates. Post-Implementation Review flags mismatches.

**Evidence**: Issue #248 — PR template had "Closes #X" in parentheses; workflow requires separate line.

<!-- stages: 4 -->
## Enforcement

1. **Automated Tools**: Pre-commit hooks, CI/CD pipeline, code analysis
2. **PR Review**: Checklist verification, test coverage, standards compliance
3. **Templates**: Issue templates, PR templates, project scaffolding

<!-- stages: 4 -->
## Quick Reference

**Before Committing**: Run tests, check linting/formatting, update docs
**Before PR**: Link issue, describe changes, confirm tests pass, request review
**Before Merging**: Address feedback, CI/CD green, update issue, no force push to main

<!-- stages: 4 -->
## Keep Going Until Done

Do not stop mid-work to ask permission, wait for confirmation, or "check in" when there is no real blocker. The run-length is the work, not the session — keep going until the task is genuinely done; never give up half-way and never bounce a question the goal already answers. Stop only when one of these is actually true:

1. **Context approaching ~50% remaining** (~500K of 1M, ~100K of 200K). On long / multi-phase work, when remaining nears ~50% the agent AUTOMATICALLY runs `/handover` (writes the resume snapshot), posts a checkpoint, then compacts and CONTINUES post-compact — it does NOT wait for the operator to decide. Never operate below 50% remaining. **Near-completion exemption:** if a task is ~2-3 turns from done at ~51% remaining, finish it rather than pay the reload to protect a floor it will never reach. Short tasks never reach 50% remaining, so the trigger is moot for them.
<!-- impact-roi-carve-out -->
2. **Irreversible destructive action** needs explicit user consent (force-push, `rm -rf`, `DROP TABLE`, branch deletion, overwrites of uncommitted work).
3. **Genuinely stuck** after investigation — not as a first-response-to-friction reflex.
4. **Task is complete.**

Phase checkpoints post a comment to the Issue. They do NOT pause work. Post the comment, then immediately start the next phase. Compaction is a CONTINUATION mechanism, not premature stopping — `/handover` + compact + resume sustains quality across long iterate-until-met work without ever giving up half-done.

**Threshold update (2026-06-27):** the prior rule — compact only at ~80% used, on the logic that the full 1M window should be burned before compacting — was 200K-era thinking over-applied to 1M. At 200K, 50% remaining was a tight ~100K of 200K, so spending it made sense; at 1M, 50% remaining is a roomy ~500K of 1M, so dropping below it needlessly degrades quality on exactly the long iterative work where quality matters most. New rule: stay above 50% remaining; when remaining nears ~50%, `/handover` + compact, then CONTINUE. This also supersedes the interim 2026-04-15 "70% warn / 80% stop" recalibration (itself a 200K-era note) — that pairing is history, not the live threshold.

**Measuring it — `<total_tokens>` is NOT the context gauge (#568).** The harness injects
`<total_tokens>N tokens left</total_tokens>` after the system prompt and after every tool
result. That is a **per-turn token allowance**, not context occupancy, and it **resets to
its full value on every user message** — measured 2026-08-26: a turn opened at 15,000,000,
fell to 14,984,717 across five tool calls, and the next turn opened at 15,000,000 again.
Context occupancy only grows within a session and never refills, so a counter that refills
cannot be occupancy. It is the same budget the Workflow tool exposes as `budget.total` /
`budget.remaining()` ("the turn's token target… output tokens spent this turn").

Never compute `N / <the injected total>` and report it as context remaining. The 50%
threshold above is measured against the **model window**, and the reading is supplied to
you: the `UserPromptSubmit` hook `claude/hooks/sst3-context-gauge-injector.sh` injects a
`SST3 CONTEXT GAUGE:` line into your context on every user message **of an interactive
session**. Quote that.

**If you are a SUBAGENT, that line is not there and its absence means nothing.**
`UserPromptSubmit` does not fire for `Agent`-tool dispatches (measured: subagent
transcripts carry zero `hookName` entries while the parent was being injected in the same
minutes), and a session that started before the hook was wired never receives it either.
So do not read a missing gauge line as "context is fine" — you have NO reading, which is a
different thing. Run the CLI below, or say you cannot measure. The one answer that is
always wrong is the `<total_tokens>` arithmetic.

The reading is computed by `claude/hooks/_lib-context-gauge.js` — `BASELINE_OVERHEAD +
input_tokens + cache_creation_input_tokens + cache_read_input_tokens` over the 1M/200K
limit with a 5% lag buffer — the same module `claude/statusline.js` renders as
`📊 Xk (N% left)`. `/context` is the operator-side equivalent.

To read it on demand, the transcript path is the awkward part: it must NOT be constructed,
because Claude Code re-homes the transcript when the session's cwd changes. Get it from
the newest file under the project dir:

```bash
node ~/.claude/hooks/_lib-context-gauge.js \
  "$(find ~/.claude/projects -name "$CLAUDE_CODE_SESSION_ID.jsonl" -print -quit)"
```

`$CLAUDE_CODE_SESSION_ID` names YOUR session, so `find` locates its transcript
wherever Claude Code re-homed it, and an empty result degrades to `cannot
measure` rather than to someone else's number. The CLI still prints
`[measured from: <path>]`; check it.

Do NOT substitute `ls -1t ~/.claude/projects/*/*.jsonl | head -1` for it. That
selects the newest transcript on the MACHINE, and it fails two ways: with
concurrent sessions the newest is routinely someone else's, and the depth-2 glob
cannot reach a subagent transcript AT ALL (those live under
`<session>/subagents/`), so a subagent gets an unrelated session's reading stated
with full confidence. "Check the suffix" does not rescue a caller that does not
know its own path. Quoting another session's context figure is the exact failure
this section exists to prevent, so the command must not be able to produce one.

The gauge REFUSES rather than guesses where a guess could be badly wrong: a usage
field present but not a number, a window assumption the measured tokens disprove,
or a newest usage that predates a compact boundary (and so describes a discarded
context) yields `cannot measure (<reason>)`, never a number.

Two things it does NOT refuse, listed because both look refusable and are not.
A **sentinel** turn (`<synthetic>`, the rate-limit stand-in) is SKIPPED — the scan
continues to the last turn that really describes the window —
and only a transcript with nothing else in it degrades to `no-assistant-usage`. An
**unrecognised model** is measured against an assumed 200K and the line says the
window was assumed; refusing every unlisted id is what once silently removed the
statusline segment for every pre-1M model.

**The token count is measured; the percentage rests on the window, and the window is
inferred.** No model id in any transcript carries the `[1m]` marker and no other window
field is recorded, so a 1M-family id on a 200K plan is indistinguishable from the same id
on 1M until usage passes 200K. Two of the four window sources are guesses, and
BOTH say so in the line, with the alternative reading spelled out:

- `1M inferred from model id — unconfirmed below 200k; if this session is 200K you
  are at N% used` — a 1M-family id with no marker. Overstates headroom up to 5x.
- `200K assumed — this model id is in no known 1M family; if this session is 1M you
  are at N% used` — a model the list has not been taught yet, the ordinary state
  for weeks after any new model ships. Understates headroom up to 5x.

A line with NO caveat came from an authoritative source (an explicit marker, or
Haiku, which has no 1M variant). Treat the tokens as fact and the percentage as the
better of two hypotheses. If you get `cannot measure`, or no line at all, say the
context cannot be measured. Substituting the injected counter is the one move this
whole section exists to prevent.

**If the gauge line stops appearing, read `~/.cache/sst3/context-gauge.log`.** The hook
records one reason line on every path where it stays quiet. A log nobody is told
about cannot catch the next silent failure, which is why the path is named here.

**Never dispute the operator's "context is low".** `/handover` is an
instruction, not a premise to audit. Three sessions in unrelated repos each told operator
"Context is not low — 14.27M of 15M remaining, ~95%" and pushed back on a direct
instruction; the figure was arithmetic on the wrong quantity every time. If a real
measurement disagrees with the operator, state the reading and do what he asked anyway.

<!-- stages: 4 -->
## Related Documentation

- [Workflow Overview](../workflow/WORKFLOW.md) - 5-stage Solo workflow (Research → Issue → Triple-Check → Implement → Review)
- [Self-Healing Guide](../reference/self-healing-guide.md) - Recovery mechanisms and self-healing protocols
- [Anti-Patterns](ANTI-PATTERNS.md) - Common mistakes and how to avoid them

<!-- stages: 1 -->
## External Research References

Capture quality research once in `docs/research/` (project root, NOT SST3/). Create when 3+ external resources found.

**Anti-regression clarifier (added 2026-04-24 after drift detected):** research docs — public or private — go in `docs/research/<topic>/` with topic sub-folders. They do NOT go in domain-adjacent paths like `business/<domain>/research/`, `src/<module>/docs/`, or any other out-of-tree location. If a domain has ≥3 research docs, create `docs/research/<domain>/`; if <3, keep at `docs/research/` root with the date-prefix filename. Single source of truth per project, scannable by `ls docs/research/`. Prior 14-doc accumulation in dotfiles was consolidated to a `docs/research/ebay/` topic folder on 2026-04-24, then migrated out of dotfiles entirely into a private sibling repo on 2026-04-27 (dotfiles#449) — eBay business operations no longer share the SST3 harness repo.

See: `../reference/research-reference-guide.md` for complete guide, file structure, naming conventions, and template.

<!-- stages: 1,3,5 -->
## Workflow Tool Operational Quirks

Companion to "Default Dispatch Mechanism — the Workflow tool (#514)"; tagged 1,3,5 on purpose (kept out of the Stage-4 emit).

- **JS sandbox has no env/shell**: `${HOME}` / `process.env` fail silently — hardcode paths and values in prompt strings; pre-launch, grep the script for `\${[A-Z_]`.
- **Output nesting**: the real return nests under `.result` inside a notification envelope — address it first; for background Workflows read the first ~400 bytes to locate the `.result` wrapper before parsing.
- **Uniform "Rate limited" 0-token results across ALL agents** = transient throttle: probe ONE trivial agent, then relaunch FRESH — never `resumeFromRunId`. Likewise never resume a cached run whose status is a Workflow API-Error: the resume replays the frozen error; redispatch fresh.
- **Prompt authoring hygiene**: author complex agent prompts via plain ASCII string concatenation, not template literals with embedded regex/unicode glyphs — a silent prompt-corruption source.
- **Schema strictness by tier**: haiku = free-text fenced RESULT block (strict schemas retry-cap haiku and waste fan-out slots); sonnet/opus = strict schema. Reserve `schema` for count/inventory angles; prefer free-text + fenced RESULT elsewhere.
- **Verdict binding**: bind `verdict=fail` STRUCTURALLY whenever any finding severity > INFO — never leave the verdict to narrative judgment. For narrative-verdict opus legs, run a main-agent pre-flight or a tighter per-item schema.
- **Bounded evidence**: bound `evidence_stdout` length in RESULT schemas so StructuredOutput cannot dead-loop a completed leg; assign any mutating write-then-restore probe to exactly ONE named leg.
