# Feedback Closure-Loop Formats

> Reference for the per-stage feedback closure loop (`../standards/stage-4/per-stage-feedback-capture.md`, `improvement_status`).
> Moved here because no `/Leader` stage loaded it: a `stage-4/` section tagged for stages 1 and 5 reaches
> no emit (dotfiles#577). Stage 1 step 0b closes the loop with `mark-improvements-applied.sh`, which
> writes these formats, so they are never hand-written.

**Closure-loop content-match format**: Stage 1 closure-loop entries MUST quote the first 80 chars of the source improvement field verbatim:

```
<repo>#<issue> stage=<N> [bullet=<i>]: "<first 80 chars verbatim>" → <applied-where>
```

`[bullet=<i>]` (1-indexed) is REQUIRED for a multi-bullet improvement field, OPTIONAL for a single bullet. Byte-match key: the improvement bullet's first 80 chars after its `**improvement**:` or `- ` prefix, then leading/trailing whitespace stripped.

**Multi-bullet partial-application schema**: when only a subset of bullets in a multi-bullet improvement field is applied this run, mark per-bullet rather than per-improvement:

```
**improvement_status**: partial
**applied_in_bullets**: [1, 3]
**carry_forward_bullets**: [2]
**applied_in**: <issue-number>
```

Inline per-bullet markers go AFTER the bullet text using HTML comments — e.g. ``- **template-vs-mirror lane mapping** ...<!-- applied_in: 459 -->``. The aggregator and `check-closure-loop-applied.py` (Phase 6) parse these markers via `feedback_parser.py`; the parser emits `applied_in_bullets` + `carry_forward_bullets` into the NDJSON index for cross-issue reporting.
