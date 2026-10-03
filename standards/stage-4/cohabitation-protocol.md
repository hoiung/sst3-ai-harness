<!-- stages: 4 -->
# Cross-Repo Cohabitation Protocol — Stage-4 Canonical

Multi-repo + multi-worktree + multi-agent concurrency contract (orig. #469 Phase 4 / dotfiles#449 stage 5).

<!-- stages: 4 -->
## Single-concurrent-session-per-issue rule

NOT "single-session" — sequential sessions (compact + resume) are FINE. The contract is: NO two concurrent `/Leader` runs on the same Issue from different chat sessions.

Layer B sentinels (in `.sentinels/`) enforce — they auto-release after 24h staleness so a sequential resume can re-acquire; a concurrent acquire trips the sentinel as still-held.

<!-- stages: 4 -->
## Two-worktree concurrency

Two agents working on DIFFERENT Issues in DIFFERENT worktrees of the same canonical clone is the supported case. The dotfiles#488 fix enables it:
- Each agent owns its own worktree (independent HEAD + index)
- Gate 2 uses the remote-FF push procedure (no shared-tree branch-switch)
- The `EnterWorktree` tool creates isolated worktrees from the same canonical

<!-- stages: 4 -->
## Forbidden patterns

- Concurrent worktree creates against the same solo-branch name → second create errors
- Branch-switch in the shared canonical clone while a worktree holds the same branch
- `git pull --rebase` in the canonical's main while a worktree is mid-push

<!-- stages: 4 -->
## Cross-references

- `../../standards/stage-4/per-stage-feedback-capture.md` "Cross-Repo Cohabitation Protocol" + "Multi-Agent Multi-Worktree Concurrency Contract".
- `CLAUDE.md` "Branch Safety (CRITICAL — DO NOT VIOLATE)" — operator-facing prose invariant.
- `claude/hooks/sst3-branch-guard.sh` — runtime enforcement (#490).
- `../../standards/stage-4/gate-2-merge.md` — the recursion-safe merge that respects this protocol.
