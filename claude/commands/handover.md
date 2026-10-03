---
description: Pre-compact AI-to-AI handover. Write ONE structured handover to ~/handover/ and point the repo-scoped current-task-<repo>.txt at it, so the post-compact context resumes with no loss. Invoke right before compacting a long session.
---

# /handover — pre-compact AI-to-AI handover

Invoke this right before you compact a long session. It writes ONE structured handover the next (post-compact) context reads to resume with no loss. AI-to-AI: terse, evidence-anchored, not human prose.

Optional argument: `/handover <one-line note>` — a free-text hint folded into the summary.

## Why this exists

Compaction keeps only a summary; this command writes **state + next-steps + learnings** + the operator goal **verbatim** (paraphrase = drift), plus evidence anchors, to a file the post-compact context is commanded to re-read.

**Handovers live in `~/handover`, NOT auto-memory** — a session-scoped resume aid, not durable. `~/handover` (WSL `$HOME`, outside every git repo) survives compaction AND a WSL VM restart — unlike `/tmp`, which a VM teardown wipes. The `SessionStart` compact hook re-injects `~/handover/current-task-<repo>.txt`, pointing the post-compact context at the handover file.

**Do NOT write the handover to auto-memory or add a `MEMORY.md` index bullet** — it bloats the auto-loaded index for no resume value. Auto-memory is for *durable* facts (user/feedback/project/reference); a per-session resume snapshot belongs in `~/handover`. A durable lesson from this session → a separate `feedback_*` / `project_*` memory, not a handover.

**Three-tier state model**: durable facts → auto-memory; session-resume snapshot → `~/handover`; throwaway scratch → `/tmp`. A daily `systemd-tmpfiles` rule prunes `~/handover` after 7 days (access-time is bumped on read, so an in-use handover is not pruned mid-flight).

## What to do when invoked (in order)

**Step 0 — Never state a context reading you did not measure.**
`/handover` is an instruction, not a premise to audit — write the handover whether or not
you agree the context is low.

If you report a context figure at all, quote the `SST3 CONTEXT GAUGE:` line the
`UserPromptSubmit` hook injects into your context on every user message. Normally it is
already there and you just repeat it. To read it on demand:

```bash
node ~/.claude/hooks/_lib-context-gauge.js \
  "$(find ~/.claude/projects -name "$CLAUDE_CODE_SESSION_ID.jsonl" -print -quit)"
```

Never hand-build that transcript path — Claude Code re-homes the transcript
when the session's cwd changes (entering a worktree moves it).
`$CLAUDE_CODE_SESSION_ID` names YOUR session, so `find` locates it wherever it
was re-homed to, and an empty result yields `cannot measure` rather than someone
else's number. The CLI still prints `[measured from: <path>]`: check it names
your own session.

Do NOT substitute `ls -1t ~/.claude/projects/*/*.jsonl | head -1`. That selects
the newest transcript on the MACHINE, which with concurrent sessions is routinely
someone else's, and a caller that does not know its own path cannot check the
suffix either. Writing another session's context figure into a handover is the
precise failure this Issue started from, so the command that reads the gauge must
not be able to produce one.

Do **not** compute a percentage from `<total_tokens>`. That tag is a per-turn allowance
which refills on every message and is not context occupancy (AP #32). Sessions that did so
reported `Context: 15.0M of 15.0M tokens remain (100%) — not low`, argued with
the operator about compacting, then wrote the wrong figure into the resume
pointer for the next session to inherit. If the gauge says `cannot measure`, or
no line is present (subagents never get one), say the context cannot be measured
— never substitute another number.

**Step 1 — Write the handover file to `~/handover`.**
Write a new file `~/handover/handover_<repo-or-topic-slug>_<YYYY-MM-DD>.md`. For Issue-tied work, put the issue number in the slug (e.g. `handover_<repo>-<issue>-<topic>_<date>.md`). Optional light frontmatter (`name` / `description`) is fine for readability, but this is a `~/handover` working file, NOT a memory file — do not give it `metadata.node_type: memory`. (`~/handover` is created by the per-machine install; if it is somehow absent, the Write tool creates the parent directory anyway.) <!-- c4:T39 --> When a `/handover` re-writes an existing handover file (same slug), superseded `STATE` content collapses to one line per stage (tip SHA + what it settled), so the handover stays under ~25K tokens; the 8 field labels below are unchanged.

The body uses these **8 field labels VERBATIM** (this is the authoring contract — do not rename, do not drop):

1. `GOAL (verbatim)` — the operator's goal quoted word-for-word. Do NOT paraphrase. This is the single most important field; paraphrasing it is the #1 source of post-compact drift.
2. `STATE` — what is DONE vs IN-PROGRESS, each line carrying an evidence anchor (commit SHA / test count / file:line). Not "auth is mostly done" — "auth login flow done (commit a1b2c3d, 7/7 tests pass); refresh-token path IN-PROGRESS (src/auth.py:88)".
3. `NEXT ACTION` — the single concrete next step the reader should take first. One step, not a backlog. When a sign-off pause may span the compact, NEXT ACTION carries the full 2b contract text verbatim (the files-changed table, the mechanism summary, the class-tagged out-of-scope list and every open decision — Stage-3 step 2b), because a pointer to it does not survive the compact.
4. `ANCHORS` — the real file:line / artifact paths the reader must re-open to continue. Pointers to source, so the reader verifies rather than trusts the summary. <!-- c4:T71 --> In a worktree session, ANCHORS also records the worktree's untracked runtime environment (a local database name, untracked config files) beside the runner scripts that need it: `scripts/setup-worktree-deps.sh` links only `.venv` and `node_modules` and copies `.env`, so anything else is lost with the worktree.
5. `DECISIONS` — decisions already made, each with its rationale AND what was RULED OUT (so the reader does not re-litigate or undo them).
6. `CONSTRAINTS` — hard rules in force this session ("don't touch X", required format, branch safety) that would otherwise be lost with the conversation.
7. `OPEN` — open questions / blockers genuinely undecided (so the reader knows what is settled vs not).
8. `LEARNINGS` — gotchas discovered this session (e.g. "endpoint is side-effecting — use --head", "test harness needs RTH ticks"). Cheap to record, expensive to rediscover.

**Step 2 — Update the compact-hook task file (deterministic re-surface).**
Write to the REPO-SCOPED pointer file the `SessionStart` compact hook reads.
**Do NOT hand-derive that filename.** The key is `<repo>-<digest>`, the digest
computed from the repo root — any formula written here drifts from the hook the
moment the hook changes, and a pointer written to a path the hook does not read
is a silent total failure (dotfiles#568 Ralph round 2 F-B: that exact drift
shipped once). Ask the hook where it reads:

```bash
bash ~/.claude/hooks/sst3-session-context-injector.sh --test </dev/null \
  | jq -r '.additionalContext.post_compact_directive' \
  | grep -oE '/[^ ]*/handover/current-task-[^ ]*\.txt' | head -1
```

Write to that exact path the verbatim current task PLUS an explicit imperative — NOT a bare path — so the post-compact context is commanded to open the handover:

```text
<verbatim operator goal>
Post-compact: READ ~/handover/handover_<slug>_<date>.md IN FULL before resuming — it holds the goal/state/next-action.
```

The hook re-surfaces this text and a fixed re-read directive — "re-read CLAUDE.md/STANDARDS/ANTI-PATTERNS/WORKFLOW/Issue", PLUS (since dotfiles#528) "read the named handover file in full" and "re-read the active /Leader stage line-by-line" — but it does NOT itself read the handover body, so the imperative above is what closes the loop. (The hook is the single authority on the pointer path — it resolves the repo key itself, so `/handover` should always ask it rather than reconstruct one. There is deliberately no fallback to a global path.)

(Concurrent sessions in DIFFERENT repos no longer collide: each writes its own `current-task-<repo>.txt` (dotfiles#568). Until then this was one global file, so whichever session compacted last overwrote it and SessionStart injected that text into every other repo's session. Two sessions in the SAME repo still share one pointer — the last to compact wins, which is the intended behaviour for a single repo's resume state.)

**Step 3 — Report and confirm.**
Tell the operator: the `~/handover` handover file path, the task-file line you wrote, and a one-line "safe to compact now". Then stop — let the operator trigger the compact.

## Anti-patterns — do NOT do these

- **Do NOT write to auto-memory / `MEMORY.md`.** Handovers are session-scoped `~/handover` files. Writing them to memory bloats the auto-loaded index permanently — the exact failure this skill was rewritten to stop.
- **No prose-narrative summary.** A paragraph retelling the session strips the reasoning chain and is unverifiable. Use the 8 structured fields.
- **Not a raw-history dump.** Dumping everything adds noise and buries the signal (lost-in-the-middle). Write the high-leverage fields only.
- **Do not paraphrase the operator goal.** Quote it verbatim in field 1 — paraphrase is where drift begins.
- **Never drop the file:line anchors.** Anchors let the reader re-read source instead of trusting a summary; dropping them is the direct cause of post-compact hallucination.

## Relationship to the Issue-comment handover

For Issue-tied SST3 work, the canonical session checkpoint still goes to the GitHub Issue comment per `templates/chat-handover.md`. `/handover` complements that — it is the `~/handover` resume snapshot for any pre-compact moment (Issue or not). Use both when on an active Issue; the Issue comment is the durable record, the `~/handover` handover is the same-session resume aid.
