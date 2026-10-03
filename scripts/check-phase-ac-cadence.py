#!/usr/bin/env python3
"""
check-phase-ac-cadence.py — AP #20 Tier A interleave enforcement (#454 follow-up).

Pre-commit hook (commit-msg stage): on a `solo/issue-N-*` branch, when a commit
carries a `Phase: M` trailer, verify all Tier A acceptance criteria in phases
1..M-1 are already `[x]` on the parent issue. Block the commit if any are still
`[ ]` — the violation that #454 surfaced was 21/21 ACs batch-closed at end
rather than per-phase.

Tier A vs Tier B:
- Tier A (this hook): checkboxes under `### Phase N` headings — phase deliverables.
- Tier B (not gated): checkboxes under `## Engineering Requirements`,
  `## Cleanup Requirements`, etc. — cross-cutting meta. AP #20 Phase 9 cadence
  permits batched-at-end for Tier B.

Bypass (genuine emergency only):
    SKIP=sst3-phase-ac-cadence git commit -m "..."

Graceful-skip conditions (return 0):
- Branch is not `solo/issue-N-*` (master/main work, etc.)
- Commit message has no `Phase: M` trailer
- Phase is 1 (no prior phases to gate on)
- gh CLI unavailable / unauthenticated / network down
- Issue has no `### Phase N` structure (e.g. #454 itself, created out of band)
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

# #509 AC6.5: the solo-branch matcher is now single-sourced in sst3_utils
# (was a local BRANCH_RE that drifted from the other 4 sites). The canonical
# form is the union/most-permissive correct alternation; the cadence/tier-a
# narrowing #495 left in place was #495-scope-specific, and this Issue (whose
# named invariant IS the matcher) safely unifies — verified the cadence +
# tier-a unit tests stay green (positive forms still match, main/master/feature
# still return None) and the broad form does not re-recognise this branch
# differently (no self-block).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sst3_utils import PhaseTrailerError, parse_solo_branch_issue, read_phase_trailer  # noqa: E402
PHASE_HEADING_RE = re.compile(r"^###\s+Phase\s+(\d+)")
OTHER_H3_RE = re.compile(r"^###\s+(?!Phase\s+\d+)")
H2_RE = re.compile(r"^##\s+")
CHECKBOX_RE = re.compile(r"^- \[([ x])\]\s+(.+)$")
# dotfiles#495 FRAG-2 (AC 4.1): HTML-comment marker tagging a self-gate AC.
# The marker MUST appear on the line IMMEDIATELY PRECEDING the checkbox.
# Example: `<!-- self-gate-ac: closes-on-stage-5-sign-off -->`
SELF_GATE_TAG_RE = re.compile(r"^<!--\s*self-gate-ac:\s*.*-->\s*$")


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return 1, ""


def get_branch() -> str:
    rc, out = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    return out.strip() if rc == 0 else ""


def issue_num_from_branch(branch: str) -> int | None:
    return parse_solo_branch_issue(branch)


def phase_from_message(msg: str) -> int | None:
    """The shared reader: the LAST `Phase:` line, its leading number (#577).
    Raises PhaseTrailerError for a value with no number."""
    return read_phase_trailer(msg)


def fetch_issue_body(num: int) -> str | None:
    rc, out = run(["gh", "issue", "view", str(num), "--json", "body"])
    if rc != 0:
        return None
    try:
        return json.loads(out).get("body", "")
    except json.JSONDecodeError:
        return None


def parse_phase_acs(body: str) -> dict[int, list[tuple[bool, str, bool]]]:
    """Parse `### Phase N` sections and their `- [ ]`/`- [x]` checkboxes.

    Phase scope ends when a different `## ` section or a non-Phase `### ` heading
    appears, so Engineering Requirements / Cleanup Requirements / Quality
    Mantras (Tier B) are correctly excluded.

    dotfiles#495 FRAG-2 (AC 4.1): each AC carries an additional `is_self_gate`
    bool. True iff the line IMMEDIATELY PRECEDING the checkbox matches
    `^<!--\\s*self-gate-ac:\\s*.*-->\\s*$`. Self-gate ACs are recognised by
    main() as cadence-exempt (per AC 4.2). The return-type change is paired
    with the call-site unpack in main() in the same commit (AC 4.1 ATOMICITY
    REQUIREMENT — never stage parser ahead of caller).
    """
    phases: dict[int, list[tuple[bool, str, bool]]] = {}
    current = None
    prev_line = ""  # AC 4.1: tracks the immediately-preceding line for self-gate detection
    for line in body.split("\n"):
        if H2_RE.match(line) or OTHER_H3_RE.match(line):
            current = None
            prev_line = line
            continue
        m = PHASE_HEADING_RE.match(line)
        if m:
            current = int(m.group(1))
            phases.setdefault(current, [])
            prev_line = line
            continue
        if current is not None:
            cb = CHECKBOX_RE.match(line)
            if cb:
                is_self_gate = bool(SELF_GATE_TAG_RE.match(prev_line))
                phases[current].append((cb.group(1) == "x", cb.group(2), is_self_gate))
        prev_line = line
    return phases


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    branch = get_branch()
    issue = issue_num_from_branch(branch)
    if issue is None:
        return 0

    # An unreadable message or a Phase value with no number stops the commit:
    # both used to return 0, which skipped the cadence check (#577 escalation).
    try:
        msg = Path(sys.argv[1]).read_text(encoding="utf-8")  # sst3-sec: justified: the commit-msg hook's own argv, read as text
        phase = phase_from_message(msg)
    except (OSError, UnicodeDecodeError, PhaseTrailerError) as exc:
        sys.stderr.write(f"sst3-phase-ac-cadence: cannot read the Phase trailer: {exc}\n")
        return 1
    if phase is None or phase <= 1:
        return 0

    body = fetch_issue_body(issue)
    if body is None:
        sys.stderr.write(
            f"sst3-phase-ac-cadence: gh issue view {issue} unavailable; "
            "skipping cadence check (graceful degrade)\n"
        )
        return 0

    phases = parse_phase_acs(body)
    if not phases:
        return 0

    open_priors: list[tuple[int, str]] = []
    for prior in range(1, phase):
        # AC 4.1 + 4.2 (dotfiles#495 FRAG-2): unpack the new 3-tuple
        # (checked, text, is_self_gate). ACs with is_self_gate=True are
        # treated as cadence-exempt — self-referential closure dependency
        # ACs (e.g. AC whose verification literal IS the Stage-5 sign-off of
        # the Issue containing them) MUST NOT block Phase-N+1 commits.
        for checked, text, is_self_gate in phases.get(prior, []):
            if not checked and not is_self_gate:
                open_priors.append((prior, text))

    if not open_priors:
        return 0

    sys.stderr.write(
        f"\nsst3-phase-ac-cadence: AP #20 Tier A violation — commit advances "
        f"to Phase {phase} but earlier phases on issue #{issue} have unchecked "
        "acceptance criteria:\n\n"
    )
    for p, text in open_priors:
        preview = text[:100] + ("…" if len(text) > 100 else "")
        sys.stderr.write(f"  Phase {p}: [ ] {preview}\n")
    sys.stderr.write(
        "\nClose each via mcp__github-checkbox__update_issue_checkbox with "
        "canonical evidence per dotfiles/reference/tool-selection-guide.md "
        "Example 2, then re-commit.\n"
        "\nBypass (genuine emergency only): "
        "SKIP=sst3-phase-ac-cadence git commit ...\n\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
