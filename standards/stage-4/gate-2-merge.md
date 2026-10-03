<!-- stages: 4 -->
# Gate 2 — Recursion-Safe Remote Fast-Forward Merge

Stage-4 merge gate. Replaces the pre-#488 shared-tree branch-switch + pull + local-merge + push chain with a worktree-isolated remote FF push that touches NO shared working tree.

<!-- stages: 4 -->
## Canonical procedure (dotfiles#488 AC 1.3)

1. Ensure all work committed by exact pathspec (NEVER `git add -A`).
2. Publish the solo branch: `git push origin <solo-branch>`.
3. Server-side fast-forward: `git push origin <solo-branch>:master`.
4. On non-fast-forward rejection (transient pre-push race): `git fetch origin master` then `git rebase origin/master` INSIDE the worktree, retry step 3. Bounded ≤3 attempts. **NEVER** `--force` / `--force-with-lease`.
5. `ExitWorktree action:keep` until push confirmed landed (`git ls-remote origin master` == solo tip); then `ExitWorktree action:remove`; then `git push origin --delete <solo-branch>`; then `git fetch --prune`.

<!-- stages: 4 -->
## Branch-switch invariant

This gate runs ONLY `git push` / `git fetch` / `git rebase` INSIDE the isolated worktree. It NEVER:
- branch-switches in the shared clone
- local-merges (`git merge` in main)
- resets the shared main working tree

This is the dotfiles#488 chokepoint. The shared-clone branch-switch class moves every concurrent agent's HEAD; the worktree-isolated remote FF is the cure.

<!-- stages: 4 -->
## When the rebase race fires

`origin/master` advances between step 2 and step 3 (another solo branch landed in the same window). Fetch + rebase + retry handles it; the 3-attempt bound prevents indefinite spin on a real fault (protected-branch rule, server-side reject).

<!-- stages: 4 -->
## Cross-references

- `.claude/commands/Leader.md` Stage 4 Gate 2 — operator-facing procedure.
- `CLAUDE.md` "Branch Safety (CRITICAL — DO NOT VIOLATE)" — the prose-level invariant.
- `claude/hooks/sst3-branch-guard.sh` — runtime backstop (dotfiles#490).
- `claude/hooks/sst3-destructive-op-guard.sh` — DENY mode on `--force` / `--force-with-lease` / `filter-repo` / `reset --hard` / `branch -D` (#498 F-4). One exception (#577 AC 1.4): a single plain `git branch -D <name>` passes when `refs/heads/<name>` is an ancestor of `origin/HEAD` in the repo the payload's cwd names; several names, a `-C` / `--git-dir` / `--work-tree` / `cd` prefix, or a failed check stay DENY.
