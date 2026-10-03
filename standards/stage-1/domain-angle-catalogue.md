# Stage 1 — Domain-Class & Situational Angle Catalogue

> Cluster file loaded by `load-stage-rules.sh 1`. Angles are additive to the generic Layer-1 coverage, not a replacement.

<!-- stages: 1 -->
## Required domain-class angles (dispatch the ones that match the task)

1. **vendor-behaviour** — when the task depends on a third-party product/API behaviour,
   `WebFetch` the vendor's official docs and verify the exact feature identity against
   them; never infer vendor behaviour from memory or from a sibling product. If that fetch 403s, fall back to `WebSearch`: an official-domain result snippet is citable evidence (cite its URL); never report 'no fetch performed'. <!-- c4:T35 --> Name one fetch-owner per vendor at dispatch.
2. **legal-multi-stack** — for any legal/compliance framing, run an Angle-0 sweep of the
   *non-data-protection* legal stack (company law, consumer law, contract, IP, sector
   regulation) before narrowing to the obvious statute; the obvious one is rarely the
   only one in force.
3. **GDPR** — when personal data is in scope, walk every data-subject right in GDPR
   Articles 12–23 individually and confirm the design satisfies (or explicitly defers)
   each; do not stop at "we have a privacy policy".
4. **post-system-change** — after any system/config change, grep the adjacent calibration
   surface (thresholds, defaults, dependent configs, downstream consumers) and enumerate
   every surface the change could have silently shifted.
5. **pipeline-architecture** — for pipeline/orchestration changes, dispatch a
   downstream-docs-staleness angle: walk CLAUDE.md / README / runbook references to the
   changing surface and flag any that now describe the old shape.
6. **business-workflow** — for business-ops/product work, include a design-system / brand
   angle so the deliverable matches the established voice, layout, and brand constraints,
   not just the functional spec.
7. **extending-prior-features** — when extending an existing feature v(N)→v(N+1), dispatch
   a schema-bridge angle: enumerate every persisted/serialised shape the prior version
   wrote and confirm the new version reads it (or migrates it) — no silent shape breaks.
8. **external-API** — for any external-API integration, dispatch a fallback-design-path
   angle: what happens on timeout / rate-limit / 5xx / auth-expiry, and is the fallback
   itself observable (not a silent swallow)?
9. **UI/frontend-completeness** — UI-accuracy-across-variants topics get a live-DB per-entity probe as a Layer-1 angle; a pre-swarm "page X is windowed" gate enumerates ALL the page file's bounce-data hooks; for UI-marker features, ask the surface-coverage + persistence questions upfront in the scope snippet, never via wireframe reaction.
10. **incident-investigation** — a reported timestamp matching no code-derived schedule gets a live-state reconciliation sub-task naming the exact runtime artefacts Stage 4 needs; snapshot the incident's per-ticker/TTL'd Redis keys to /tmp (`redis-cli GET` each) before any swarm.
11. **DB-probe verdicts** — dispatch each as a standalone subagent told to run the decisive query FIRST, never buried in context-gathering. Before asserting writer/run exclusivity, query which (run_id, variant) pairs wrote the rows and check coexisting provenance metadata against the claimed writer's transaction shape. New operator-list equality-scoping: probe stored casing/whitespace normalization before accepting a byte-identical match.
12. **redundancy/proxy-metric framing** — when the operator asks "is X redundant with / a proxy for Y?", the primary angle is the decisive within-Y-conditioned cut (Y held constant, does X carry independent signal?), not correlation alone.
13. **CMS-config template consumer** — a site's CMS config (e.g. Sveltia/Decap `config.yml`) is a mandatory Stage-1 read with the layouts: a template consumer whose field definitions must stay in sync with layout changes.
14. **CI-log fetch fallback** — empty `gh run view --log`/`--log-failed`: no view-variant retries; use `gh api repos/<owner>/<repo>/actions/runs/<id>/logs`.
15. **new-content-surface linkage + claim audit** (Stage-1/2 draft time) — new content page in an existing section: audit the section HUB / repo INDEX / nav-landing body that should link it; feature with a separate onboarding/runbook doc: enumerate every doc on the changed workflow as in-scope; new data-processor/retention behaviour: grep the legal pages for every claim it invalidates.
16. **image-source reading** — <!-- c4:T73 --> an image-reading leg is told which dimension of a drawn shape carries the signal (e.g. a TradingView rectangle's anchor bar + height, not drawn width) and converts a pixel extent to axis units from labelled ticks before any range claim.

<!-- stages: 1 -->
## Situational angles (dispatch when the trigger condition holds)

1. **carve-out bullet-proofing** — when the operator flags a do-not-touch surface, dispatch
   an angle whose sole job is to confirm no AC re-absorbs or mutates that surface; the
   carve-out must hold against the *implementation*, not just the stated intent.
2. **dual-mode codepath split** — for tools with two execution modes (CLI + module / strict
   + lax / emit + validate), dispatch an angle that verifies BOTH codepaths are exercised
   and that a fix to one is mirrored to the other.
3. **synthesis ordering** — dispatch synthesis subagents AFTER confirmed task-completion
   notification of the inputs they read; never in parallel with the producers and never on
   a fixed timer (the inputs may not exist yet). The synthesis prompt names its input files.
4. **enumerate-before-bounding** — do not set an acceptance threshold, ceiling, or cap
   before the candidate set has been enumerated: enumerate first, then bound. A number
   chosen before the set exists is a guess wearing a threshold's clothing, and every later
   decision inherits it as though it were measured. Issue #52 fixed a reuse ceiling at
   "2-3" before the candidate sweep ran, then found the real set already saturated it.
5. **credential-role binding** — a new credential/account/identity named in the task gets a research question binding it to a role (automation-consumed vs operator-manual-use) before any AC touching it is scoped.
6. **PowerShell tree-wide parse check (shape-gated)** — PowerShell-bearing repo audits get a tree-wide PARSE check as their own Layer-1 angle, not diff-scoped (Stage-5 twin: post-implementation procedure).
7. **new-sibling scratch-tree simulation** — for a new sibling (a strategy core, a package, a
   section), simulate adding it in a scratch tree at Stage 1 to measure the touch-set and commit
   plan before drafting.
