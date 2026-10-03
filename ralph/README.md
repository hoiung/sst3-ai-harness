# Ralph Review Loop

Automated 3-tier quality review for SST3 workflow.

> **CRITICAL: PLANNING MODE ONLY**
> Review subagents are REVIEWERS, not implementers. They:
> - **DO**: Read files, verify evidence, check compliance, report findings
> - **DO NOT**: Write code, edit files, make commits, fix issues
>
> If issues found, subagent reports findings → Main agent fixes → Restart review (up to 3 restarts, then ONE escalation, then ONE final loop, then stop-and-report).

## What

Main agent spawns 3 review subagents in sequence; the LOOP as a whole is bounded at 3 restarts, then ONE escalation, then ONE final loop, then a terminal stop-and-report:
- **Tier 1 (Haiku)**: Surface checks - files, checkboxes, commits
- **Tier 2 (Sonnet)**: Logic checks - evidence, scope, fallbacks
- **Tier 3 (Opus)**: Deep checks - architecture, standards, review

### The 5 Common Culprits

Every tier scans for these STANDARDS.md violations at increasing depth:

| Violation | What | Standard |
|-----------|------|----------|
| **Duplicate Code** | Same logic in multiple places | DRY, Modularity |
| **On-the-fly Calculations** | Inline math/formulas that should be in config | No Hardcoded Settings |
| **Hardcoded Settings** | Magic numbers, embedded config values | STANDARDS.md |
| **Obsolete/Dead Code** | Old code that should have been deleted | LMCE |
| **Silent Fallbacks** | Defaults that hide errors | Fail Fast |

## Setup

No plugin. Each tier is one dispatch of the `ralph-review` subagent type, defined in `.claude/agents/ralph-review.md` with `Write` / `Edit` / `NotebookEdit` disallowed, so a reviewer cannot change the tree. The installer links that directory as `~/.claude/agents`, so the type resolves in every repo.

## Usage

**Main agent dispatches each tier in the FOREGROUND, one at a time (each reviewer reads STANDARDS.md + its tier checklist):**

```text
# Tier 1: Haiku surface checks
Agent(model=haiku, subagent_type=ralph-review, run_in_background=false, prompt="Review per SST3/standards/STANDARDS.md and SST3/ralph/haiku-review.md ...")

# Tier 2: Sonnet logic checks
Agent(model=sonnet, subagent_type=ralph-review, run_in_background=false, prompt="Review per SST3/standards/STANDARDS.md and SST3/ralph/sonnet-review.md ...")

# Tier 3: Opus deep checks
Agent(model=opus, subagent_type=ralph-review, run_in_background=false, prompt="Review per SST3/standards/STANDARDS.md and SST3/ralph/opus-review.md ...")
```

A background dispatch returns at launch with no verdict, and each tier needs the previous tier's verdict, so every tier runs in the foreground.

**Flow:**
1. Main agent completes implementation
2. Dispatches the Haiku tier
3. Haiku PASS → dispatches Sonnet
4. Sonnet PASS → dispatches Opus
5. Opus PASS → Verification Loop (Gate 1), then merge, then user review
6. If ANY FAIL → Main agent fixes → Restart from Haiku (restarts 1-3; restart 4 is NOT taken — escalate, then ONE further loop, then stop-and-report)

**Max iterations**: the loop is bounded at 3 restarts, then escalates to a class-sweep and resumes for exactly ONE further loop; if that loop does not PASS, it STOPS and reports the outstanding findings + classes to the operator (terminal state, #567). The bound counts RESTARTS, not rounds. **The counter cannot observe either boundary for itself** — signal it: `sst3-ralph-restart-counter.sh --restart` at each restart, `--escalate` at the escalation (the only reset within a stage), `--stage5` once at Stage-5 entry (Stage 5's own loop; Stage 4's numbers are archived). Unsignalled the count stays 0 at any event volume, so the bound is never reached. See standards/stage-4/ralph-review.md for the canonical rule.

## Learn

- [haiku-review.md](haiku-review.md) - Tier 1 checklist
- [sonnet-review.md](sonnet-review.md) - Tier 2 checklist
- [opus-review.md](opus-review.md) - Tier 3 checklist
- [Ralph technique](https://ghuntley.com/ralph/) - Original methodology
