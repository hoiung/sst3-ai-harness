# Stage 2 — Pre-Dispatch Author Self-Check Block

> Cluster file loaded by `load-stage-rules.sh 2`.
> Run these checks on `/tmp/issue_draft_<topic>.md` before any Layer-1/2 subagent dispatch; dispatch needs zero unresolved items.

<!-- stages: 2 -->
## Sub-checks (a)–(t)

> Run ALL of (a)–(t). Items (j)–(t) are sub-sections of this catalogue below;
> they are not optional extras. (dotfiles#552 AC 4.5 — they were previously
> sibling `##` headings under a heading that said `(a)–(i)`, so an author who
> read the heading as the whole catalogue would skip them.)

- **(a) placeholder sweep** — `grep -E 'placeholder|stub|\bTODO\b|if needed|nice-to-have|could be|assumed|presumably|expected' /tmp/issue_draft_<topic>.md` → zero hits; re-run after every scope-reversal.
- **(b) scope-narrowing check** — every AC traces to the narrowed operator ask; an AC that does not map to the literal request is overreach — cut or justify.
- **(c) min-v1 sketch** — confirm a minimum-viable-v1 sketch is present BEFORE research-driven extensions; label extensions v1.1 / v2 with deferral rationale.
- **(d) template structure check** — `grep -nE '^### |^## ' $SST3/../templates/issue-template.md`; confirm each mandatory header is present in the draft. (dotfiles#552 AC 4.4: routed through the `$SST3` resolver instead of a bare literal path. `$SST3` ends at the scripts directory, so stepping up one level and into the sibling templates directory resolves in BOTH the nested canonical and the flattened mirror layout.)
- **(e) JBGE pass** — per-AC necessity check; delete any AC that does not prevent a real, named problem.
- **(f) budget sanity** — `wc -l` every target file before codifying any line-count budget; only codify a budget if planned additions are <30% of baseline, otherwise log the delta without a budget. <!-- c4:T24 --> A reduction AC's number (any unit) is written only after the AFTER state is measured on a scratch copy.
- **(g) reuse-before-new** — grep for any new script / subcommand / flag against existing entrypoints (AP #10 at draft-time); reuse in place if found.
- **(h) cross-repo state** — for every "existing X in repo Y" claim, `ls` / `grep` / `gh` against repo Y BEFORE writing the AC. <!-- c4:T67 --> An Issue gated on another branch's merge checks its citations and verifies against the gating branch ref too (`git show <branch>:<path>`).
- **(i) multi-option AC classification** — mark each option as (i) evidence-supported → force, (ii) destructive-irreversible → operator-pre-consent, (iii) policy-level → defer.

<!-- stages: 2 -->
### Sub-check (j) — author-time source-read gate

- For every AC with a Before/After code block, run `Read` on the cited file:line and paste the ACTUAL code into the Before block. <!-- c4:T41 --> Read the whole enclosing function, its sibling guards and the test runner's target list; after adding a fact-establishing AC, re-check same-subject ACs for contradiction.
- For every line-cited verbatim quote, run `sed -n '<line>p' <file>` and record the exit code + line number inline.
- For every AC naming a constant/symbol by file:line, re-grep at author-time (line numbers drift).
- For every count or literal-string verify predicate carried from Stage 1, re-execute the `grep` / `wc` at author-time — do not trust the Stage-1 number.
- For every "reuse existing X" claim, read X's full body, transitive IO calls and the target's actual signature before asserting reuse is safe.
- When an AC pre-enumerates a command's expected output, run it and paste the ACTUAL output. <!-- c4:T14 --> A command pinned as canonical (scope snippet or AC) is run across its full target set (every fleet node, worktree and main clone it will run in), its success rate recorded, before it is trusted.
- Before citing a file:line, `sed -n` it to confirm it is the EXECUTABLE statement, not a comment or blank line. <!-- c4:T26 --> <!-- c4:T64 --> Citation writing keeps the quote line recorded separately from the activity line (says vs does); a deferral citation is re-grepped in the pass that cites it; a literal-grep guard is described without spelling its literal; unattributed commit or doc prose is never cited as the operator's position (only his typed messages are; `git log -1 --format=%B <sha>` shows the author).
- For a template/partial-include change, trace the include chain to its owning template before drafting the Before/After.
- For a multi-file invariant AC, `Read` EVERY named file at its cited lines.
- For a re-sync AC, diff source vs target and list each occurrence's exact replacement plus a verbatim-match verify. <!-- c4:T13 --> Mirror staleness is diffed in both directions, so target-only lines surface.
- For a status-header/staleness claim, read the target's head and grep the EXACT stale string.

<!-- stages: 2 -->
### Shape-gated sub-check (k) — multi-root script file-availability

Fires when the draft touches a **bootstrap / installer / provisioning script that resolves files from more than one root** — a staged kit, a repo it clones part-way through its own run, or a hand-copied staging dir. Skip-clean otherwise.

- **(k) multi-root script file-availability** — for every AC that imports / sources / dot-sources a file inside such a script, identify WHICH root makes that file present **at that step's position in the run order**, before writing the import path. Check all of them in one pass — they are one question, not separate findings to surface across separate review rounds:
  - **pre-clone staged root** (`$PSScriptRoot`-style) — its LAYOUT varies by how the script was invoked: a flat-staged kit puts everything beside the script, while a run straight out of an existing clone keeps the repo's own `subdir\file` shape. Do not assume either; probe both shapes under this root,
  - **post-clone repo root** (only exists after the clone step — absent at every earlier step),
  - **operator-invoked staging dir** (the script was copied somewhere and run by hand; carries only a SUBSET of the kit, so "it's on the kit" is not sufficient).
- Establish the run-order position first — anchor the pattern to the script's own step-header form (`grep -nE '^# --- Step [0-9]'`-style), not a bare word match, which returns mostly prose cross-references. The same file can be reachable at one step and absent at an earlier one; the ordering is the whole check.
- Cite the in-file precedent: these scripts carry comments stating which root a given call must use and why. Read the precedent BEFORE choosing a root; do not infer from a nearby line that sits on the other side of the clone step.
- Prefer a guarded try-both (`Test-Path` / `[ -f ]`) over a single hardcoded path — both ACROSS roots when a call must work on either side of the clone step, and WITHIN the staged root when its layout depends on the invocation mode. Break on the first hit inside a probe loop, so one resolution wins.
- Where a LATER step can re-load the same file — a second attempt from a different root, whether or not the earlier one succeeded — guard that fallback on an already-loaded predicate — `Get-Command` / `command -v` / a sentinel variable — not on the earlier loop's break. A break only ends its own loop; it cannot stop a separate downstream block from re-sourcing the file and resetting whatever script-scope state the first load established.
- Repo-specific script names, manifest variables, and staging paths belong in the owning repo's own sweep issue — not in this catalogue (it mirrors to a public consumer).

<!-- stages: 2 -->
### Sub-check (l) — staged-benign-edit hook dogfood

- If the issue defers a secret-scan/leak-guard finding on a file an AC also touches, run the repo's pre-commit hook on a staged benign edit to each AC-touched file; on a whole-file block, sequence that AC after the deferred issue or scope around it before implementation.

<!-- stages: 2 -->
### Sub-check (m) — repo-gate preflight + baseline disposition

- For every in-scope file, pre-run the repo's OWN commit gates (voice-wrap, secret-scan) and pre-plan any exemption/allowlist remediation inside the AC body. <!-- c4:T12 --> A build-dependent predicate is measured on built or served output (issue-draft step 4e).
- When an AC authors a whole-file gate globbing "all changed files", baseline-scan the REAL candidate set and give each pre-existing violation in unrelated files an explicit disposition.
- For execution-path Issues, record which test tiers are environment-gated (conftest markers/skips).

<!-- stages: 2 -->
### Sub-check (n) — trace-to-endpoint

- For an "X produces Y" claim, read the call chain to the ACTUAL emitting statement before naming the fix locus.
- Trace a NEW payload field or code surface proposed as a decision gate to its user-visible consumer (none found ⇒ fold into mechanism, not a scope choice).

<!-- stages: 2 -->
### Sub-check (o) — runtime-effect trace

- For an AC putting a longer string in a shared UI slot, check CSS wrap/overflow there; add a wrap AC by default.
- Before calling a raise-site or side-write 'safe', `Read` the enclosing try/except and cite what it catches / rolls back.
- Before computing from a nullable field, `Read` the nearest fail-fast guard, place the computation relative to it and cite its file:line.
- An AC setting or changing an HTTP status or response shape on an endpoint with a live UI consumer includes the writer→reader trace (grep frontend `resp.ok`/status branching) at draft time.

<!-- stages: 2 -->
### Sub-check (p) — shared-component consumer sweep

- For a shared component / structure / UI marker, grep its name and import path for EVERY mount site, consumer and branch point (starting at the Stage-1 SEED where possible); carry the list into the scope snippet before drafting per-site ACs. These are RUNTIME CONSUMERS, not AP #14e's pattern spellings.

<!-- stages: 2 -->
### Sub-check (q) — provisional live-probe tag

- An AC resting on a live-DB-probe result (not grep-derivable from static source) is marked `[provisional: live-probe]` and records a blocking Stage-3 sub-check: re-probe the SAME query before scope freeze. <!-- c4:T49 --> A finding about the operator's own workflow or what he can see is tagged `UNVERIFIED-pending-operator` and resolved from his surface or one question — never turned straight into an AC.

<!-- stages: 2 -->
### Sub-check (r) — drift-prone identifier live-verify pairing

- An AC listing platform/vendor identifiers that research flags as cosmetic/unstable pairs them with a live verify (API / permission-list call) in the SAME AC; a static grep alone passes a stale identifier set.

<!-- stages: 2 -->
### Sub-check (s) — propagation-claim field-level verification

- Before asserting 'X propagates to mirror Y', read its vendored_files entry's `divergent` and transform-tier fields in `../dotfiles/SST3/drift-manifest.json`: if `divergent: true`, the propagation claim is FALSE and must be rewritten. List-presence is not propagation.

<!-- stages: 2 -->
### Sub-check (t) — early synthetic repro at filing time

- For a wrapper-lane bug-fix topic, run the synthetic tmp-repo pre-fix repro (Stage 4's harness) before Stage-1 dispatch or during Stage-2 authoring and paste its pre-fix FAIL output into the issue body alongside any live-repo evidence. <!-- c4:T23 --> Build the repro fixture field by field from the documented preconditions, never from the artefact's defaults.
