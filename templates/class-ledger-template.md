---
issue: <N>
repo: <work-repo>
created: <YYYY-MM-DD>
---

<!--
Template for SST3-metrics/class-ledger/ledger-<repo>-<issue>.md.

The ledger is opened at the first restart (c4:T06, #577): created at the issue's
first Ralph restart, it records that finding's shape so a second same-shape FAIL is
seen against it (the defect-class breaker, stage-4/ralph-review.md); `## Class:`
blocks follow as classes close. Most issues never restart and never carry one. Operator ruling D2 (#567): a
separate artefact, NOT a section of the per-issue feedback file (the feedback file
is strictly-parsed prose in dotfiles; this must be RUNNABLE from the work repo's
Ralph worktree). The feedback file carries a one-line pointer to this file.

Rules (canonical: stage-4/ralph-review.md "At fix time" + stage-4/mutation-verification.md):
- One `## Class:` block per CLOSED defect class. A fix that closes only the known
  INSTANCES of a class is rejected at Ralph — the fix IS the enumerator.
- The ENUMERATOR is a runnable command over the WHOLE class (grep/ast-grep/script),
  run from the work repo root. Its current match-count is recorded; every Ralph tier
  RUNS it rather than re-deriving the class. Count drift = the enumerator is wrong
  or the class re-opened — either way a FAIL, never a shrug.
- The enumerator SELF-EXCLUDES `SST3-metrics/class-ledger/`: a ledger quotes the
  vocabulary it enumerates (mutation-proof lines, assertion examples), so an
  unexcluded grep drifts on its own documentation the moment the ledger is written
  (#567 round-2 Tier-1 measured exactly this; probe discipline,
  mutation-verification.md gate 7 — a probe asserts it still probes what it names).
- The MUTATION PROOF names the re-injected defect that reddened the gate + the
  negative control that stayed green (spec: mutation-verification.md).
- RESIDUALS carry their counts and may only assert residuals that OCCURRED; one
  that stops reproducing is STALE (it closed, or the probe stopped probing).
- NOT-ENUMERATED lists classes the sweep/enumerator deliberately does not cover —
  the honesty register that keeps "0 survivors" qualified.
-->

## Restart shapes

- restart <N>: <the failing finding's shape, one line> — same shape as restart <N-1>: <yes | no>

## Class: <short-kebab-slug>

- **class**: <one-sentence definition of the defect class — the CONCEPT, not an instance list>
- **round-closed**: <Ralph round N>
- **enumerator**: `<runnable command from work-repo root>`
- **enumerator-count**: <N matches at close>
- **mutation-proof**: reddened on `<re-injected defect>`; negative control `<control>` stayed green
- **residuals** (counts, occurred-only): <none | `<residual>`: <count>>
- **not-enumerated**: <classes deliberately outside this enumerator — sign / order / unit / ... | none declared>
