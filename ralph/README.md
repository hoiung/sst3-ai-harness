# Ralph Review Loop

Automated 3-tier quality review for SST3 workflow.

> **CRITICAL: PLANNING MODE ONLY**
> Review subagents are REVIEWERS, not implementers. They:
> - **DO**: Read files, verify evidence, check compliance, report findings
> - **DO NOT**: Write code, edit files, make commits, fix issues
>
> If a production fault is found, the subagent reports it → the main agent runs a fix cycle (at most 2 fix cycles, then one fix agent, then stop-and-report). The one exception to "reviewers never write" is that escalation fix agent (`ralph-fixer`).

## What

Main agent spawns 3 review subagents in sequence, each reviewing the whole diff once; fixes are bounded at 2 fix cycles, then ONE fix agent, then a terminal stop-and-report:
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
6. A tier FAILs only on a PRODUCTION FAULT (shipped code gives a wrong result for an input a real user or system can send). Then: fix → test suite → ONE Sonnet fix check on the fix diff → the sequence resumes at the NEXT tier.
7. GAPs (tests, docs, records, hygiene) are fixed in place with no re-review. RARE EDGE CASEs are recorded, not fixed.

**Max iterations**: the loop is bounded at 2 fix cycles. A third production fault goes to ONE fix agent (`ralph-fixer`: Fable, high effort) that reviews and writes the fix, followed by one Sonnet fix check; if that does not PASS, the loop STOPS and reports the outstanding findings to the operator (terminal state). The bound counts fix cycles, not faults. **The counter cannot observe either boundary for itself** — signal it: `sst3-ralph-restart-counter.sh --restart` at each fix cycle, `--escalate` when the fix agent is dispatched, `--stage5` at the start of each Stage-5 round (Stage 5 has its own limit of 2). Unsignalled the count stays 0 at any event volume. See standards/stage-4/ralph-review.md for the canonical rule.

## Learn

- [haiku-review.md](haiku-review.md) - Tier 1 checklist
- [sonnet-review.md](sonnet-review.md) - Tier 2 checklist
- [opus-review.md](opus-review.md) - Tier 3 checklist
- [Ralph technique](https://ghuntley.com/ralph/) - Original methodology
