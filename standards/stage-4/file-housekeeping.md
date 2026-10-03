<!-- stages: 4 -->
# File Housekeeping — Stage-4 Canonical

Per-Issue housekeeping invariants (#108).

<!-- stages: 4 -->
## Per-Issue housekeeping

- Every Issue scope MUST include a "Cleanup Requirements" subsection (Code Hygiene + File Housekeeping). Template: `../../templates/issue-template.md`.
- Code Hygiene: remove dead code touched by this Issue; remove commented-out blocks; remove `print()` debug-leftovers; remove unused imports; remove "TODO: later" without owner.
- File Housekeeping: delete files this Issue obsoletes; remove duplicate fixtures; delete temp scripts in `/tmp/` if they were committed; delete `_drafts/` files migrated upstream.

<!-- stages: 4 -->
## Repetition is intentional (#108)

The housekeeping checklist appears in EVERY Issue body, not a global doc — a per-Issue scope is a contract, a global doc is a wishlist. Cleanup is an acceptance criterion, not a separate doc.

<!-- stages: 4 -->
## What does NOT belong in housekeeping

- Reorganising files unrelated to this Issue (scope creep)
- Renaming functions for "consistency" when no caller needs the rename
- "Modernising" old code that still works (Quality First — don't churn working code)

<!-- stages: 4 -->
## Cross-references

- `../../standards/STANDARDS.md` "File Housekeeping" + "Issue #108 Lesson".
- `../../templates/issue-template.md` "Cleanup Requirements" subsection.
- `../../standards/ANTI-PATTERNS.md` AP #6 (Scope Creep) — counterweight to housekeeping ambition.
