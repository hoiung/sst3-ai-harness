# Stage 4 — Per-Stage Feedback Capture (Canonical)

> Cluster file loaded by `load-stage-rules.sh 4`. The canonical Per-Stage Feedback
> Capture mechanism, extracted from STANDARDS.md for de-bloat (dotfiles#516 AC 6.2).
> STANDARDS.md keeps the heading + a redirect; section-name references
> ("§Per-Stage Feedback Capture") still resolve to the STANDARDS.md heading.

<!-- stages: 4 -->
## Mechanism, storage and write-time schemas

Canonical telemetry mechanism for the SST3 5-stage `/Leader` workflow. Each `/Leader` stage close writes a 10-field feedback record so we accumulate observed patterns across runs (which stage routinely catches what bug class, which subagent angles are wasted, which corrections came from the user vs the agent self-caught).

**Write-time template (use it — do not hand-roll the structure)**: copy `<your-dotfiles-clone>/SST3/templates/leader-feedback-template.md` when creating a new `feedback-<repo>-<issue>.md`. It carries the canonical frontmatter (8 fields) + the `## Stage N — <Title>` H2 headings (matching `feedback_parser.py` `STAGE_HEADING_RE`) + the 10 per-stage `**field**:` lines. Hand-rolling from memory produces a bare `## Stage N` heading the strict parser rejects (it requires `— <Title>`) (dotfiles#486/#488).

**Storage convention** (literal path lives in unmirrored CLAUDE.md only): one `feedback-<repo>-<issue>.md` per issue under the `SST3-metrics/leader-feedback/` runtime telemetry directory. Filename encodes repo to prevent cross-repo collision (e.g. `dotfiles#449` vs `project-a#449`). Pre-commit hook `sst3-metrics-feedback-present` validates filename regex `^feedback-([a-z][a-z0-9_]*(?:-[a-z0-9_]+)*)-([1-9]\d*)\.md$` AND filename↔frontmatter parity. The repo-segment grammar disallows trailing hyphens, double hyphens, and digit-prefix names; the issue segment is a positive int with no leading zeros (rejects `0`, `007`, `00` collisions). All 5 stages append `## Stage <N>` blocks to the same file. Index NDJSON co-located in the same directory.

**Stage discovery**: parser reads `### Stage <N> — <name>` headings from `../../workflow/WORKFLOW.md` at runtime. NEVER hardcode the stage list — hardcoded lists silently break when a stage is deleted (#428).

**Frontmatter schema** (8 fields):
- `issue` — GitHub issue number (integer)
- `repo` — repository name (encoded in filename via `feedback-<repo>-<issue>.md`; parity-validated against frontmatter at commit time)
- `created` — ISO date of first stage close
- `last_updated` — ISO date of most recent stage close
- `stages_logged` — list of stage numbers logged (e.g. `[1, 2, 3, 4, 5]`)
- `verdict_summary` — one-paragraph headline observation across all logged stages
- `topic_keywords` — list of normalized keywords for `--shape-match` lookup (e.g. `[feedback, telemetry, sst3-metrics]`)
- `reconstructed_stages` — list of stage numbers whose body fields were filled with `[reconstructed-post-compact: ...]` markers (lower-weighted in DRIFT ALERT counts)

**Per-stage body schema (10 fields, hard-cap)**:
- `model` — agent model id used for the stage (e.g. `opus-4-7-1m`)
- `worked` — observations of what the workflow caught / surfaced correctly
- `didnt` — observations of what the workflow missed (FP correctly identified does NOT belong here — see FP-handling rule below)
- `why` — root-cause analysis of the `didnt` items
- `improvement` — concrete next-run change suggestion
- `improvement_status` — enum (see below)
- `evidence` — file:line / commit hash / command output / subagent RESULT comment-id
- `friction` — token cost, wall-clock, restart count, per-Ralph-tier outcomes (Stage 4 sub-structure); at Stage 5 the friction value body additionally carries the `closing_comment_posted: <yes:url|no:reason>` SUB-value (inside the friction value, NOT an 11th top-level `**field**:` marker line — keeps the 10-field schema + `feedback_parser.validate_record` strict-schema intact; dotfiles#528 AC 3.5, records whether the mandatory closing-summary comment was posted)
- `rule_self_caught` — agent-self-caught violations of an existing canonical rule
- `rule_user_caught` — user-caught corrections (attribution wording is FINE — see channel-separation rule)

**`caught_by:` enum** (sub-attribute on findings inside `worked` / `didnt`, written as a `- caught_by:` sub-bullet): `wrapper / raw / haiku / sonnet / opus / fable / swarm / gate / user / agent-self` — `swarm` = a multi-agent layer (Workflow legs, a subagent swarm, the Ralph trio) or more than one catcher; `gate` = a mechanical check (hook, verify command, script). `feedback_parser.py` maps known synonyms (`CAUGHT_BY_SYNONYMS`) and rejects any other value; an empty value is absent (`null` in the index). Lets the aggregator answer queries like "how often did raw-only Layer 2 catch what wrapper missed".

**`improvement_status` enum**: `pending / applied / partial / superseded / rejected`. When status moves to `applied` or `partial`, set `applied_in: <issue#>`. Closure loop: future Stage 1 Step 0 picks up `pending` improvements from prior issues + marks them `applied` (or `partial` for multi-bullet improvements) when the next run satisfies them. <!-- c4:T52 --> A batch of status flips re-checks every reference between the flipped rows against the post-batch corpus, not the pre-batch snapshot.

<!-- stages: 4 -->
### Write mechanics and enforcement (Stage-4 operative)

**Soft-cap guidance**: tiny issues 10-20 lines per stage block / medium 30-60 / large 60-120 / >150 revisit. **Hard cap**: 10 fields exactly. Parser emits stderr WARNING (advisory, exit 0) if a per-stage block exceeds 80 lines. Tiny-issue terminal one-liners permitted (`rule_user_caught: none` / `friction: trivial`).

**YAML authoring note (AC 2.7)**: use unstyled YAML field names (`graph_applicable: false`, not backtick-wrapped). Allowed values for `graph_applicable`: `false | hybrid | true` — do not invent synonyms. YAML inline comments inside scalar values cause parse failures. The Stage-2 entry validator (`check-stage1-research-fields.py`) hard-blocks on any of these authoring errors.

**Stage-4 stub-block timing (AC 4.4)**: at Stage 4 entry, the FIRST action is to write the `## Stage 4` stub-block to the per-issue feedback file and stage it — before any code edit or commit. A stub-block is the 10-field skeleton populated with `<to-be-filled>` placeholders; the pre-commit hook requires the block to EXIST, not be complete. **Pre-write channel check**: `grep -E "prefers|always|from now on|default ON|going forward" <feedback-file>` must return zero hits before staging. **Dual-write**: pre-issue feedback drafts are written to BOTH `SST3-metrics/leader-feedback/_drafts/<file>` AND `/tmp/<file>` — a compact cannot lose /tmp; the parked-feedback sweep tracks both.

**FP-handling rule**: a false positive correctly identified counts as `worked`, NOT `didnt`. Filter the FP, document why, that's a successful audit. (Avoids inflating DRIFT ALERT counts with the audit's own correctly-rejected hypotheses.)

**Channel-separation rule** (forward-preference-blocklist, NOT attribution-blocklist): feedback files MUST NOT contain forward-looking memory-channel signals: `prefers / always / from now on / default ON / going forward`. Those phrases belong to auto-memory (the user-voice channel). Attribution words that describe what happened in this run (`the operator flagged`, `user pointed out`, `the operator caught`) are FINE — they're the natural vocabulary of `rule_user_caught`. Pre-commit hook enforces.

**DRIFT ALERT spec**: count-based on `(stage, verdict=didnt) >= threshold`. Default threshold 5 (placeholder; calibrate after 10 issues). Configurable via env var `SST3_FEEDBACK_DRIFT_THRESHOLD`. Fires from `leader-feedback-aggregate.sh --summarize` to stderr; AP #21 forbids autonomous Issue creation, so DRIFT ALERTs are advisory signals not actions.

**Single-CONCURRENT-session-per-issue rule** (NOT "single-session"): two parallel `/Leader` runs on the same issue from different chat sessions is OUT OF SCOPE. Sequential sessions (compact + resume) FINE — sentinel auto-releases after 24h staleness so a resumed session can re-acquire.

**Cross-repo support**: every repo's `/Leader` runs write to `SST3-metrics/leader-feedback/`. Repo is encoded in both the filename (`feedback-<repo>-<issue>.md`) and the frontmatter `repo:` field; the filename↔frontmatter parity check enforces consistency. Repo source for new files: `/Leader` workflow fills frontmatter `repo:` at file-creation time (per existing manual-fill convention). The dotfiles pre-commit hook validates parity; it does NOT auto-detect repo because it always runs in dotfiles context regardless of which sister repo's `/Leader` triggered the work.

**Post-compact reconstruction protocol**: if an agent compacted mid-stage and cannot recover original observations, fields use the literal marker `[reconstructed-post-compact: <evidence-source>]` (e.g. `[reconstructed-post-compact: chat-handover.md]`, `[reconstructed-post-compact: phase-3-checkpoint-comment]`). Frontmatter `reconstructed_stages: [N]` flag set. Aggregator weights these lower in DRIFT ALERT counts so reconstructed observations don't dominate signal.

**Stage 4 sub-structure**: Stage 4 `worked` / `didnt` MAY contain per-Ralph-tier sub-bullets (Tier 1 Haiku / Tier 2 Sonnet / Tier 3 Opus). The `friction` field captures `ralph_restarts: <N>` + per-tier outcomes (PASS / FAIL → restart → PASS).

**Activation-sha gate**: `SST3-metrics/leader-feedback/.activation-sha` holds the canonical merge SHA when this mechanism lands on master. The `sst3-metrics-feedback-present` pre-commit hook fires only on solo branches whose first commit descends from `.activation-sha`. Pre-existing branches grandfathered (hook exits 0 with stderr note `pre-activation branch: hook skipped, hand-write feedback retroactively if desired`).

**Stage detection**: pre-commit hook detects which stage a commit belongs to via the `Phase: N` git-trailer in the commit message OR an explicit `--stage N` CLI flag. NO fragile heuristic. NO silent skip. Fail loud if a solo-branch commit on an activated branch has neither.

**`Phase: N` trailer convention (AC 4.10)**: the `Phase: N` trailer value is the ISSUE implementation phase number (1, 2, 3...), NOT the Leader Stage number (which is always 4 during Stage 4). ALL implementation commits in a Stage-4 session with no sub-phases use `Phase: 4` only. When the issue has sub-phases numbered 1..M, use the sub-phase number. The `## Stage 4` feedback block must be open before the first commit where N > 1.

**Auto-archive**: after 90 days of inactivity, records auto-archive to a `_archive/` subfolder.

**Index**: `feedback-index.ndjson` regenerated post-commit (incremental — input-hash check; full rebuild via `--rebuild`). Queryable via `<your-dotfiles-clone>/SST3/scripts/leader-feedback-aggregate.sh --summarize | --report | --shape-match | --staleness`.

**Enforcement (3 layers)**:
- **Layer A**: pre-commit hook `sst3-metrics-feedback-present` (compact-resilient — survives context loss). Bypass: `SKIP=sst3-metrics-feedback-present git commit ...` — an INTENDED path for non-code artifact commits on a solo branch's metrics-feedback lane (e.g. the feedback file, aggregator output); use it up front there. Other uses stay emergency-class, justified in-message. The lenient-stub/strict-close-gate distinction is canonical HERE — Leader.md Stage-4 step 1 Stub-first points at it and no other placeholder-stub instruction exists (swept #555). The aggregator applies the same split per file wherever it validates: while `stages_logged` lacks 5, a failed strict validate retries with `--allow-placeholder` and a stderr WARNING names the file; once it logs 5, placeholders fail hard.
- **Layer B**: persistent sentinel files in the gitignored `.sentinels/` subfolder catch Stages 1+2 (which don't produce commits). Auto-release after 24h staleness so compact-resume cycles can re-acquire. Layer B sentinels also catch compact-before-commit gaps — if `/Leader N` completes work that gets compacted before the per-stage feedback commit lands, the `.sentinels/` marker survives compaction and is detected at next session start, so the post-compact agent sees the unflushed feedback rather than silently bypassing it (#498 F-22).
- **Layer C**: skill-body sign-off line in `../claude/commands/Leader.md` for each of the 5 stages — the redundant-by-design third layer (AP #20 case proved skill-body alone leaks).

**Hook-failure protocol**: `feedback_parser.py` exits 1 with single-line stderr `feedback_parser: <human-readable error> at <file>:<line>`. NEVER raises stack trace. NEVER prints debug noise. The error must be diagnosable from the single line.

**No retrofill**: pre-existing closed issues are NOT seeded with fabricated feedback records. The first live record under this canonical IS the implementation Issue's own dogfood (#448). Avoids the fabrication-vs-criterion contradiction that killed the original retrofill scope.

**Canonical scope boundary**: this section is THE canonical source for what / how / why feedback records exist. `../claude/commands/Leader.md` SIGN-OFF lines reference this section for the per-stage write step. `../claude/commands/SST3-solo.md` references this section at Per-Session Initialization and Verification Loop. `../../workflow/WORKFLOW.md` references this section in each stage trailer. `../dotfiles/CLAUDE.md` is the single place where the literal `SST3-metrics/leader-feedback/...` storage path lives — the workflow files are mirrored to public repos and use this section reference only.

<!-- stages: always -->
### Cross-Repo Cohabitation Protocol

> Concurrency summary: `cohabitation-protocol.md`.

A sister-repo `/Leader` run whose feedback also covers a dotfiles-side artefact change may need entries at both repos' canonical paths, but only ONE can merge at a time ("NEVER switch branches"):

1. **Active-branch minimal marker**: on the sister repo's solo branch, write `SST3-metrics/leader-feedback/feedback-<sister-repo>-<issue>.md` with only the FM block + the body `[parked: full block at /tmp/feedback-<sister-repo>-<issue>-stage-N.md awaiting cross-repo apply post-merge]`. Stages 1-2 write this placeholder, not the full block, since a same-session cross-repo dotfiles commit needing a shared-tree branch-switch risks a CONTENDED mutation; the operator MAY instead parallel-EnterWorktree into the dotfiles clone and commit fully (isolated worktrees are not CONTENDED).
2. **Sister parked full block**: stage the FULL stage block to `/tmp/feedback-<sister-repo>-<issue>-stage-N.md` — the data-of-record until applied.
3. **Sign-off comment with apply commands**: at /Leader 5 sign-off, comment the apply commands on the sister-repo Issue: `cp /tmp/feedback-<sister-repo>-<issue>-stage-N.md $DOTFILES_ROOT/SST3-metrics/leader-feedback/feedback-<sister-repo>-<issue>.md && cd $DOTFILES_ROOT && git add -f SST3-metrics/leader-feedback/feedback-<sister-repo>-<issue>.md && git commit -m "metrics(feedback): apply parked block from <sister-repo>#<issue> (Phase: 5)"`. The `-f` is required: a block promoted from the gitignored `_drafts/` MUST be force-added; at the canonical root it is a no-op, kept so the command matches the `sweep-parked-feedback.sh` suggested-apply (AP #9).
4. **Post-merge sweep enforcement**: at Stage 5 step 7a.0, `bash $SST3/sweep-parked-feedback.sh <issue> [--repo <sister-repo>]` BLOCKs sign-off while any `/tmp/feedback-<sister-repo>-<issue>*.md` remains; the operator MUST apply the full block first. Completeness-check C15 enforces server-side (Layer B GHA).

**TBD-issue staging via `_drafts/` subdir**: pre-issue feedback goes to `SST3-metrics/leader-feedback/_drafts/feedback-<repo>-<topic>-pre-issue.md`, **gitignored + git-untracked** so a parallel agent's draft is never swept into a bystander's commit during Stages 1-3; the aggregator's non-recursive `feedback-*.md` glob skips it. On Issue assignment: `mv _drafts/feedback-<repo>-<topic>-pre-issue.md feedback-<repo>-<issue>.md && git add -f feedback-<repo>-<issue>.md` + update FM `issue:`; the forced add is required so the file enters tracking and the Stage-5 `sweep-parked-feedback.sh` BLOCK + C15 still see it.

<!-- stages: 4 -->
### Multi-Agent Multi-Worktree Concurrency Contract

> Concurrency summary: `cohabitation-protocol.md`.

**Principle** (dotfiles#495 / dotfiles#488 worktree-first canonical): the SST3 harness supports multiple agents working in parallel via EnterWorktree-isolated worktrees on the same clone, provided each agent operates on its own solo branch in its own worktree. This section is the explicit scope contract.

**IN-SCOPE**:
- Multiple agents in parallel worktrees on the SAME clone working on DIFFERENT Issues (e.g. agent-A in `worktree-solo+issue-500-foo`, agent-B in `worktree-solo+issue-501-bar`, both on the same dotfiles clone)
- Multiple agents across different machines/operators on DIFFERENT Issues (no shared filesystem; coordination via origin/master push race resolved by Gate-2 server-FF rebase-retry)
- Cross-repo parallelism: agent-A in sister-repo `project-a` worktree + agent-B EnterWorktree into the dotfiles clone for canonical edits (per Cohabitation Protocol clarification above)

**OUT-OF-SCOPE**:
- Two parallel `/Leader` sessions on the SAME Issue from different chat sessions — see the **Single-CONCURRENT-session-per-issue rule** above in this cluster (sentinel auto-releases after 24h staleness for sequential compact+resume; concurrent same-issue is forbidden)
- Cross-machine residue detection — `leader-stage5-drain-check.sh` D3 (self-opened worktree detection) is LOCAL-only by design (`leader-stage5-drain-check.sh:55-62`); residue on a different machine's clone is the operator's responsibility, not the harness's
- Shared-tree concurrent mutation — two agents committing to the SAME working tree (not the same clone, the same TREE) remains Cohabitation-CONTENDED and forbidden

**IN-WORKTREE INVARIANTS** (every Stage-4 implementing agent in a worktree, no exceptions):
- NEVER `git checkout main`, `git checkout master`, `git switch main`, `git switch master`
- NEVER `git pull origin main`, `git pull origin master`, `git merge solo`
- ALWAYS commit and push to the CURRENT worktree's solo branch
- Gate-2 merge is ALWAYS the server-FF push pattern (`git push origin <solo>:master` per `### Solo Branch Merge Safety`), NEVER a shared-tree branch-switch + local-merge
- ExitWorktree cleanup happens AFTER Gate-2 push is confirmed landed (`git ls-remote origin master` == solo tip), per `**Branch and Worktree Cleanup**`
- Runtime backstop: `claude/hooks/sst3-branch-guard.sh` PreToolUse hook intercepts forbidden branch-switch attempts (WARN by default; DENY via `SST3_BRANCH_GUARD_MODE=DENY`)

**Cross-references**:
- Worktree-first canonical rule: CLAUDE.md "Branch Safety (CRITICAL — DO NOT VIOLATE)" anchor
- Merge mechanic: STANDARDS.md `### Solo Branch Merge Safety` section
- Cleanup mechanic: STANDARDS.md `**Branch and Worktree Cleanup**` section
- Cohabitation distinction: this file's `### Cross-Repo Cohabitation Protocol` section

<!-- stages: 4 -->
### Canonical field-line format vs Banned legacy formats

The parser strictly requires `**field**:` bare bold form. Banned legacy formats (parser rejects since #469 Phase 3 strict mode):

| Form | Status | Example |
|------|--------|---------|
| `**field**: value` | Canonical | `**model**: opus-4-7-1m` |
| `- **field**: value` | Banned (bullet-prefix-bold) | `- **model**: ...` |
| `- field: value` | Banned (bullet-prefix-no-bold) | `- model: ...` |
| `- field: \|<br>    indented value` | Banned (YAML literal block) | (multi-line legacy) |
| `## Field` (H2 section) | Banned (header-as-field) | `## Model` |

Continuation lines for multi-line values: bare bullets at column 0, no leading `- ` prefix on the field line itself. Migration scripts for the banned forms live transient in `/tmp/` for one-shot use; canonical pattern is to enforce via parser strict mode + per-file validate at aggregator boundary (`leader-feedback-aggregate.sh` calls `validate_record()` per file BEFORE its `--emit-ndjson` parse, closing the pre-commit hook-order window without a `.pre-commit-config.yaml` change), not retroactive correction.

**Codepath-split note**: `parse_record()` (`--emit-ndjson`) and `validate_record()` (default + aggregator) both validate first, so CLI and Python-module consumers see identical strictness (no lax-path silent skip).
