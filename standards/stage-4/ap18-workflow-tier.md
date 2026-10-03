# Stage 4 — AP #18 Workflow-Tier Sample-Invocation (worked detail)

> Cluster file loaded by `load-stage-rules.sh 4`. The body of ANTI-PATTERNS.md
> AP #18 'Smoke-Tested Pipeline Shipped Without End-to-End Sample Run', extracted
> for de-bloat (dotfiles#516 AC 6.2). ANTI-PATTERNS.md keeps the `## Anti-Pattern #18:`
> header (so `AP #18` citations resolve) + a redirect; the rule detail lives here, and the
> worked evidence, per-shape recipe table and enforcement map are in
> `../../reference/ap18-workflow-tier-reference.md`.

<!-- stages: 4 -->
### Tier placement (Workflow vs E2E vs Unit)

> **Three-Tier placement** (STANDARDS.md "Three-Tier Testing Framework"): this AP is the **Workflow Tier** gate — the assembled component (pipeline / orchestration / CLI-wiring) runs end-to-end. The distinct **E2E / System Tier** (the whole system, real DB + real downstream consumers, environmental drift) is **AP #26 "E2E System Verification"**. The **Unit Tier** primitive is the call-seam check (STANDARDS.md "Test-Prod Call Coverage Discipline"). The three compose; none substitutes for another.

<!-- stages: 4 -->
### Rule and scope triggers

**Rule — Sample Invocation Validates Workflow Logic**:
For any change that touches pipeline / backtest / SL1 / SL2 / orchestration / CLI-wiring / cross-module function-arg propagation, run an actual end-to-end sample invocation matching the intended user workflow BEFORE closing the issue. Real DB. Real CLI. Real downstream consumers. Unit + smoke tests are necessary but NOT sufficient.

**Service/backend scope triggers** (ANY of these → sample invocation mandatory; auto_pb-shape canonical):
- New or modified CLI flags and their threading into downstream function signatures
- SL1 / SL2 / backtest / queue-orchestrator wiring changes
- Pipeline operations tracker, coverage pre-flights, auto-bootstrap paths
- Snapshot-suffix / window-scoped / experiment-path logic
- Multi-module function-arg propagation chains (>1 hop from CLI to DB write)
- Any change where a `**kwargs`-accepting mock could silently hide the regression
- Any `../../scripts/sst3-*.sh` wrapper change
- **Idempotency re-run paths**: for changes claiming idempotency or feature-detect logic (e.g. "if X already configured: skip" branches), the sample MUST cover BOTH first-install AND re-run-with-feature-already-present paths.
- **Documentation cross-reference resolution**: for infrastructure-shape work (homelab bootstrap, runbook scripts, multi-node setup), a Stage 5 swarm angle MUST confirm every script-path / URL / file-reference / cross-link in the Issue's docs resolves (`ls`/`grep -F` exit 0, `curl -fsI` 2xx).
- **Every-return-path wiring**: for cache-read or guard-helper ("check state and return early") additions, Stage 4 must confirm every `return` in the guarded function (`grep -n return`) emits the new instrumentation/cache-write or is documented exempt with rationale.

<!-- stages: 4 -->
### How to apply (MANDATORY in Stage 4 Verification Loop)
1. Run real-CLI sample invocation on a small liquid basket (8 tickers typical) exercising the full pipeline end-to-end.
2. Verify row counts land in DB, contamination audit passes, downstream consumers succeed.
3. Smoke first (cheap, fast). If smoke passes → STILL run the sample. Exit gate = sample succeeds.
4. Assertions MUST verify arg propagation explicitly (`mock.call_args.kwargs["window_start"] == expected`), NOT rely on `**kwargs` swallowing.
5. Add a Stage 5 integration test covering the sample path when the change introduces cross-module signatures or CLI flags.

**Do / Don't**:
- ✓ DO: run 8-ticker real-CLI sample on every pipeline-touching issue before close
- ✓ DO: assert function-arg propagation with explicit `call_args` checks
- ✓ DO: write a regression integration test when adding/changing cross-module function signatures
- ✗ DON'T: close on unit + smoke alone for pipeline / wiring / CLI changes
- ✗ DON'T: defer the sample run to "the next issue's smoke" — that is how #1424 shipped broken
- ✗ DON'T: rely on mocks that discard kwargs to prove propagation

**Self-Healing**: If you catch yourself about to close a pipeline/wiring issue without running a real sample → run the sample first. If you already closed one → reopen, run the sample, and add the missing Workflow-Tier test (the integration / sample-invocation coverage that would have caught it — STANDARDS.md "Three-Tier Testing Framework"; not a bare "regression test", which is the union suite, not a single tier) in the same fix.
