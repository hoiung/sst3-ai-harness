# Stage 4 — Source-of-Intent Verification (AP #28 worked examples)

> Loaded by `load-stage-rules.sh 4`. Worked examples for ANTI-PATTERNS.md AP #28
> "Acting on Appearance or Memory Rather Than Source of Intent" (canonical rule lives
> there; Append-vs-Extend). dotfiles#516 AC 4.1.

<!-- stages: 4 -->
## The four recurring instances

<!-- stages: 4 -->
### 1. Propagation-managed "duplicate" files
A file that *looks* duplicated across repos is often propagation-managed (mirror lane B / template
lane A). **Before consolidating**, read `SST3/drift-manifest.json` and confirm whether the apparent
duplicate is a registered mirror. Worked example: the flattened `scripts/` copies in the dotfiles
self-row are byte-identical mirrors of `../../scripts/` canonicals — consolidating them would break the
drift gate. Source of intent = the manifest, not the file-listing.

<!-- stages: 4 -->
### 2. Pointer vs predicate references
Before a bulk cross-repo rewrite of a reference (e.g. `STANDARDS.md:N` → anchor), classify EACH
occurrence: a **pointer** (a navigational link the reader follows) tolerates a section-anchor rewrite; a
**predicate** (a line-number the code/gate actually asserts against) does NOT — rewriting it silently
breaks the assertion. Read the consuming code before rewriting.

<!-- stages: 4 -->
### 3. Reversing a documented deferral
Before reversing a previously-documented deferral ("we deferred X because Y"), retrieve the rationale
comment URL and confirm it still applies. Memory of "we should do X now" is a hypothesis; the recorded
rationale is the source of intent. If the rationale no longer holds, say so explicitly with evidence —
do not silently reverse.

<!-- stages: 4 -->
### 4. Agent-drafted legal or policy pages
Source of intent for a legal or policy page (privacy, retention, terms): an agent-drafted page is a draft,
never the operator's policy, until the operator confirms it. Before quoting its promises as policy, or
building a feature that enforces them, find that confirmation.

<!-- stages: 4 -->
## State-machine / persistence-schema companion rule (STANDARDS.md "Code Quality")

Any PR shipping state-machine / crash-recovery / idempotency / atomicity logic MUST include a
state-diagram-as-comment enumerating all reachable states and valid transitions in the same commit.
Schema fields representing 3+ states MUST be string enums at design time — never a bool-with-a-magic-
third-state. (Canonical rule: STANDARDS.md "Code Quality".)
