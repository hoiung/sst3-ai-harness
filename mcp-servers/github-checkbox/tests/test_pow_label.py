"""A Proof of Work entry names its checkbox by a prefix, not the whole box text (dotfiles#577).

An entry that repeated the whole box text added every ticked box to the body a second
time, so a long Issue reached GitHub's body cap with boxes still open. The label is
the box text, cut to its first POW_LABEL_MAX characters at a word boundary when
longer; it never leaves a code or bold span open, and it still matches exactly one
box.
"""

import asyncio
import json
import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402
from server import POW_LABEL_MAX, pow_label  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
TEMPLATE = REPO_ROOT / "templates/issue-template.md"
BOX_RE = re.compile(r"^\s*- \[[ x]\] (.*)$")

LONG_AC = (
    "**AC 0.1** — `mcp-servers/github-checkbox/server.py` sends issue bodies and comment "
    "bodies on stdin, never as one argv element. Today `update_issue_body` runs `gh issue "
    "edit N --body <new_body>`."
)

# Each case: (name, box text). Every one is longer than POW_LABEL_MAX.
LONG_CASES = [
    ("ac_box_with_code_spans", LONG_AC),
    ("backtick_open_at_the_cut", "word " * 10 + "`code span with spaces that runs past the cut point` tail"),
    ("bold_open_at_the_cut", "word " * 10 + "**bold span with spaces that runs past the cut point** tail"),
    ("bold_drop_reopens_code", "word " * 13 + "`a **b` c " + "more " * 12),
    ("plain_prose", "Read this Issue line-by-line and list three to five key scope items as evidence of reading it"),
]


def _balanced(text: str) -> bool:
    return text.count("`") % 2 == 0 and text.count("**") % 2 == 0


@pytest.mark.parametrize("name,text", LONG_CASES, ids=[c[0] for c in LONG_CASES])
def test_long_box_label_is_a_balanced_word_boundary_prefix(name, text):
    assert len(text) > POW_LABEL_MAX, f"{name}: premise broken, case is not long"
    label = pow_label(text)
    assert label.endswith("…"), f"{name}: a cut label must be marked: {label!r}"
    head = label[:-1]
    assert text.startswith(head), f"{name}: label is not a prefix of its box: {label!r}"
    assert len(head) <= POW_LABEL_MAX, f"{name}: label longer than the cap: {len(head)}"
    assert text[len(head)] == " ", f"{name}: cut is not at a word boundary: {label!r}"
    assert _balanced(head), f"{name}: label leaves a span open: {label!r}"


@pytest.mark.parametrize("length", [1, POW_LABEL_MAX - 1, POW_LABEL_MAX])
def test_box_up_to_the_cap_is_kept_whole(length):
    text = ("x" * (length - 1) + "y")[:length]
    assert pow_label(text) == text


def test_degenerate_inputs():
    assert pow_label("") == ""
    # No space in the first POW_LABEL_MAX characters: a plain cut at the cap.
    unbroken = "a" * (POW_LABEL_MAX + 20)
    assert pow_label(unbroken) == "a" * POW_LABEL_MAX + "…"
    # Balancing would empty the label (the text opens with a code span past the cap):
    # keep the whole text rather than write an entry that names nothing.
    code_first = "`" + "c" * (POW_LABEL_MAX + 10) + "` then prose"
    assert pow_label(code_first) == code_first


def test_labels_name_exactly_one_box_of_the_issue_template():
    """The template's real boxes: every label is a prefix of its own box text only."""
    texts = sorted({m.group(1) for line in TEMPLATE.read_text(encoding="utf-8").splitlines()
                    if (m := BOX_RE.match(line))})
    assert len(texts) > 50, f"premise broken: only {len(texts)} boxes read from {TEMPLATE}"
    cut = [t for t in texts if len(t) > POW_LABEL_MAX]
    assert len(cut) > 10, f"premise broken: only {len(cut)} template boxes are long enough to be cut"
    for text in texts:
        head = pow_label(text).removesuffix("…")
        owners = [t for t in texts if t.startswith(head)]
        assert owners == [text], f"label {head!r} matches {len(owners)} boxes"


STUB_GH = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ["issue", "view"]:
    sys.stdout.write(open(os.environ["GH_STUB_BODY"], encoding="utf-8").read())
elif args[:2] == ["issue", "edit"]:
    with open(os.environ["GH_STUB_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps({"argv": args, "stdin": sys.stdin.read()}) + "\\n")
else:
    sys.exit(f"unexpected gh call: {args}")
"""


def test_tool_writes_the_short_label_and_never_repeats_the_box(tmp_path, monkeypatch):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    gh = bindir / "gh"
    gh.write_text(STUB_GH, encoding="utf-8")
    gh.chmod(0o755)
    body_file = tmp_path / "body.md"
    body_file.write_text(f"## Acceptance Criteria\n\n- [ ] {LONG_AC}\n\n## Proof of Work\n\n", encoding="utf-8")
    log = tmp_path / "gh-edits.ndjson"
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("GH_STUB_BODY", str(body_file))
    monkeypatch.setenv("GH_STUB_LOG", str(log))

    result = asyncio.run(server.update_issue_checkbox(9999, LONG_AC, "commit abc1234; test 2 passed"))
    assert result.startswith("SUCCESS"), result

    edits = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
    assert len(edits) == 1, f"expected one body write, got {len(edits)}"
    written = edits[0]["stdin"]
    assert f"- [x] {LONG_AC}" in written
    assert f"- **{pow_label(LONG_AC)}**: commit abc1234; test 2 passed" in written.splitlines()
    assert written.count(LONG_AC) == 1, "the box text was written into Proof of Work again"
