<!-- stages: 4 -->
# Contract Verification — Stage-4 Canonical

Three contracts every component MUST honour (Issue #1407 post-mortem).

<!-- stages: 4 -->
## The three contracts

1. **Type Contract** — every function argument and return value is type-safe. Python: type hints on every new function. Rust: explicit types (no `_` for non-trivial). Bash: validate `$#` + quote `"$@"`. SQL: column types match queries.
2. **Schema Contract** — every persistence write conforms to the schema (Pydantic / SQLModel / Postgres column types / Redis HSET fields). Schema drift = silent failure class — write tests assert exact field-presence + types. <!-- c4:T63 --> Two exported surfaces joined on a key (e.g. a report and its per-row export) are asserted to join totally: every row on each side finds its partner and both row counts are asserted.
3. **Config Contract** — every config-driven branch documents which config key gates it, and where that key's default lives. Tests cover both the default branch + the override branch.

<!-- stages: 4 -->
## Verification (Stage-4 Verification Loop)

- `python3 -m mypy --strict <new modules>` exit 0
- `bash -n <new scripts>` exit 0
- Schema tests assert exact field set: `assert set(record.keys()) == EXPECTED_FIELDS`
- Config-traceability tests: for every `if config["x"] == "y":` branch, test fires with both `y` and `not-y` values.

<!-- stages: 4 -->
## Failure mode this prevents

Writer renames a persisted field; reader silently gets `None`; the writer's mocks accept anything so tests stay green; surfaces only in prod. Schema tests force the writer-reader pair to agree on the exact field name at write time.

<!-- stages: 4 -->
## Cross-references

- `../../standards/STANDARDS.md` "Contract Verification — Three Contracts" (#1407 post-mortem).
- `../../standards/ANTI-PATTERNS.md` AP #12 (No Observability — write-time enforcement is contract verification's twin).
- `../../standards/stage-4/observability-fail-fast.md` — runtime invariants contract verification supplements.
