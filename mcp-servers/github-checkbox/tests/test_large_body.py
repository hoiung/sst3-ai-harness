"""Issue and comment bodies reach gh on stdin, never as one argv element (dotfiles#577 AC 0.1).

Linux rejects any single argument of 131,072 bytes or more (E2BIG), so a checkbox
tick on an Issue body of 128 KiB or more failed while GitHub accepts ~262K on edit.
A stub `gh` first on PATH records its argv and stdin; the tests drive both body
writers with a 140,000-char body and assert the body travelled on stdin only.
"""

import asyncio
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402

BODY_CHARS = 140000
ARGV_ELEMENT_CAP_BYTES = 4096

STUB_GH = """#!/usr/bin/env python3
import json, os, sys
record = {"argv": sys.argv[1:], "stdin": sys.stdin.buffer.read().decode("utf-8")}
with open(os.environ["GH_STUB_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(record) + "\\n")
"""


@pytest.fixture
def stub_gh(tmp_path, monkeypatch):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    gh = bindir / "gh"
    gh.write_text(STUB_GH, encoding="utf-8")
    gh.chmod(0o755)
    log = tmp_path / "gh-calls.ndjson"
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("GH_STUB_LOG", str(log))
    return log


def large_body() -> str:
    line = "- [ ] **AC 9.9** — a checkbox line in a large Issue body " + "x" * 42 + "\n"
    body = (line * (BODY_CHARS // len(line) + 1))[:BODY_CHARS]
    assert len(body) == 140000
    return body


def only_gh_call(log: Path) -> dict:
    assert log.exists(), "gh was never executed (pre-fix: exec fails with E2BIG before gh starts)"
    records = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
    assert len(records) == 1, records
    return records[0]


def assert_body_on_stdin_only(record: dict, body: str) -> None:
    longest = max(len(arg.encode("utf-8")) for arg in record["argv"])
    assert longest <= ARGV_ELEMENT_CAP_BYTES, f"an argv element is {longest} bytes"
    assert record["stdin"] == body


def test_update_issue_body_sends_140000_char_body_on_stdin(stub_gh):
    body = large_body()
    ok, error = server.update_issue_body(577, body, "owner/repo")
    record = only_gh_call(stub_gh)
    assert_body_on_stdin_only(record, body)
    assert ok, error
    assert record["argv"][:4] == ["issue", "edit", "577", "--body-file"]


def test_update_issue_comment_sends_140000_char_body_on_stdin(stub_gh):
    body = large_body()
    result = asyncio.run(server.update_issue_comment(comment_id=1, body=body, repo="owner/repo"))
    record = only_gh_call(stub_gh)
    assert_body_on_stdin_only(record, body)
    assert result.startswith("SUCCESS"), result
    assert "body=@-" in record["argv"]
