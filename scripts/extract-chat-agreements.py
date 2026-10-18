#!/usr/bin/env python3
"""
Extract the operator's genuine typed chat messages from a Claude Code session
transcript so a verifier panel can reconcile the implementation against what was
actually agreed in chat (vs only the Issue scope).

Claude Code records every session as newline-delimited JSON at
  ~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl
where <cwd-slug> is the working directory with every `/` replaced by `-`
(e.g. /home/you/projects/my-app -> -home-you-projects-my-app).
The transcript survives compaction, so it is the authoritative record of what the
operator actually said — memory and handovers are not.

Three record classes carry operator decisions and all three are read
(dotfiles#555 AC 0.6):
  - `type:"user"` records — typed prose, in `type:"text"` content parts
  - `type:"queue-operation"` records — a message typed WHILE the agent was busy
    is queued and recorded here; it is also replayed as a user turn on dequeue,
    but that replay is not guaranteed to survive every session boundary
  - AskUserQuestion answers — the operator's menu selections arrive as a
    `tool_result` part answering an `AskUserQuestion` tool_use, never as text.
    dotfiles#552 lost SIX consequential decisions this way: the panel
    reconciled against a record containing none of them.

This script reads those JSONL files and recovers ONLY genuine operator-typed
turns, dropping harness-injected noise:
  - tool_result content parts (function outputs)
  - <system-reminder> / <command-*> / <local-command-*> / <bash-*> wrappers
  - skill-body injections (the rendered slash-command body sent as a user turn)
  - compaction summaries ("This session is being continued ...")
  - "[Request interrupted by user]" markers
  - isMeta / isSidechain turns (subagent sidechains, meta events)

The recovered messages are emitted as a `## Agreements Log` markdown block
(default) or JSON (--json) for the Stage 1/3/5 verifier panel to interpret with
fresh eyes — it is shown ONLY these raw messages, never the scope, so its
interpretation is independent.

Exit codes:
  0  success — at least one operator message recovered
  1  usage / IO error (project dir or session file missing / unreadable)
  2  parsed cleanly but recovered ZERO operator messages (caller decides — this
     is suspicious for a non-empty session and is surfaced distinctly)
  3  a record class was seen that is neither parsed nor knowingly ignored — the
     transcript format has moved and this tool may be dropping operator
     decisions. Fail loud rather than under-report with exit 0 (#555 AC 0.6).
  4  a session chosen by discovery belongs to another repository: none of its
     records' `cwd` is at or below the target repo and no message names it
     (dotfiles#577 T47). Nothing is emitted.

Issue: dotfiles#522 Phase 5 (verifier-led chat reconciliation);
       dotfiles#555 AC 0.6 (queue-operation + AskUserQuestion + fail-loud).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sst3_mirror_utils import _main_clone_root  # noqa: E402

# Genuine operator prose never starts with these harness wrappers.
_SKIP_PREFIXES = (
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<local-command",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<system-reminder>",
    # Background-task completion notices: injected as type:"user" turns (isMeta
    # unset, isSidechain false) when a Workflow/Agent/Bash background job ends —
    # harness automation, never operator-typed. The single most frequent
    # user-turn wrapper class in a multi-session corpus, so omitting it leaks
    # fake "operator messages" into the verifier panel (dotfiles#522 Stage 5).
    "<task-notification>",
    "Caveat: The messages below",
    # Compaction summary injected as a user turn — harness-generated, not typed.
    "This session is being continued from a previous conversation",
)

# Skill-body injections: when the operator types `/skill`, the rendered skill
# body is sent as a user-turn text part. These open with a known H1.
_SKILL_BODY_H1 = (
    "# Leader Mode",
    "# Memory",
    "# /handover",
    "# /start",
)

_INTERRUPT_MARKER = "[Request interrupted by user]"

# Top-level record `type` values this tool reads for operator decisions.
_PARSED_TYPES = frozenset({"user", "queue-operation"})

# Every other top-level `type` Claude Code writes. A value in NEITHER set means
# the transcript format has moved and operator decisions may be going
# unrecovered — main() exits 3 rather than under-reporting with exit 0.
#
# DERIVE, never copy. Claude Code adds record classes over time (this census
# moved from 13 to 16 between a single-project sample and the full sweep), and a
# stale set rots into exactly the silent-drop failure this guard exists to
# close. Re-run at every edit:
#
#   for f in ~/.claude/projects/*/*.jsonl; do
#       jq -r 'select(type=="object") | .type' "$f"
#   done | sort -u
#
# Last derived 2026-08-27 (dotfiles#569 Stage 5, 33 transcripts): 19 classes — `user` and
# `queue-operation` parsed, the 17 below ignored. Previously 2026-07-26 (dotfiles#555 AC 0.6):
# 16 classes / 14 ignored. The three added are itemised at the set itself.
#
# `assistant` is ignored for message extraction but IS scanned for
# AskUserQuestion tool_use ids, which are what identify the operator's menu
# selections in the following user turn. Ignored here means "carries no
# operator message", not "never read".
#
# Re-derived 2026-08-27 (dotfiles#569 Stage 5) over 33 transcripts: 19 classes, not the 16
# last recorded. THREE were new, and because this tool fails loud on an unrecognised class it
# had begun exiting 3 on every transcript this Claude Code build writes — i.e. the Stage-5
# chat-reconciliation step was hard-down for every future Issue. Each was inspected before
# being ignored rather than added to silence the error:
#   atis-latch  5,842 records, keys exactly {atis, sessionId, type}. `atis` is either empty
#               (5,443) or one opaque versioned token (400). No operator prose on any record.
#   pr-link        40 records, keys {prNumber, prRepository, prUrl, sessionId, timestamp,
#               type}. A structured PR reference; no free-text field at all.
#   cost-state      3 records, telemetry counters (totalCostUSD, modelUsage, token totals).
#               No free-text field.
# None can carry an operator decision, so ignoring them loses nothing — which is the standard
# this set is held to, not "the error went away".
#
# Re-derived 2026-10-18 (a Stage-5 extraction) over 91 transcripts: 23 classes, 2 parsed,
# 21 ignored. The tool exited 3 on that extraction (history-suppression), and the
# census found three more that this build writes into 77 of the 91. Inspected the same way:
#   history-suppression  476 records, keys {cause, sessionId, ts, type} (+ vetoedAgainstAccountUuid
#               on 4). `cause` is a code: migration / chokepoint_veto / restored_owner_mismatch.
#   api-request   18,307 records. `tail` is a list of blob hashes (56,917, every one hex), `base`
#               null or a request id, `params` model settings. No free-text field.
#   api-request-shape  113 records, `shape` = {system, tools}: the system prompt and tool list.
#   api-request-blob  34,896 records, keys {hash, message, sessionId, type}: one message of a
#               request as sent to the model, so it DOES carry text. Measured over the 77
#               transcripts: of 1,301 distinct blob user texts, every operator-typed one is also
#               in the transcript's own user / queue-operation records (all 41 mid-turn
#               messages included). The 326 the verbatim comparison did not match are system
#               reminders (296, one a cross-session message), command wrappers this tool drops
#               anyway (22, _SKIP_PREFIXES), "Tool loaded." notices (6), and 2 mid-turn
#               wrappers whose operator line is in queue-operation and user, escaped
#               differently. Parsing the class would only re-emit messages already read.
_KNOWN_IGNORED = frozenset({
    "agent-name",
    "ai-title",
    "api-request",
    "api-request-blob",
    "api-request-shape",
    "assistant",
    "atis-latch",
    "attachment",
    "bridge-session",
    "cost-state",
    "custom-title",
    "file-history-delta",
    "file-history-snapshot",
    "history-suppression",
    "last-prompt",
    "mode",
    "permission-mode",
    "pr-link",
    "relocated",
    "system",
    "worktree-state",
})

# Which `queue-operation` operations carry the operator's text in `content`.
#
# DERIVE, never assume. The queue emits FOUR operations and THREE of them carry a
# string body — reading all three re-emits the same text once per lifecycle event
# it passes through, which inflates the Chat Reconciliation panel and the count
# `render_markdown` prints. Re-run at every edit:
#
#   for f in ~/.claude/projects/*/*.jsonl; do
#       jq -r 'select(type=="object" and .type=="queue-operation")
#              | "\(.operation)\t\(.content|type)"' "$f"
#   done | sort | uniq -c
#
# Last derived 2026-07-26 (dotfiles#555, 40 transcripts): enqueue 974/string,
# remove 415/string + 18/null, popAll 50/string, dequeue 487/null.
#
# Only `enqueue` is read. Measured over the same 40 transcripts, adding `remove`
# and `popAll` emitted 246 extra lines and recovered ZERO distinct messages, and
# no transcript carried a text under `remove`/`popAll` that was absent from its
# own enqueues — so the narrower gate is lossless, not a trade-off. `dequeue`
# never carries a body at all. Pinned by test_queue_operation_non_enqueue_*.
_QOP_CONTENT_OPS = frozenset({"enqueue"})

# Every operation the census observed. `_QOP_CONTENT_OPS` says which one is READ;
# this says which ones are KNOWN. An operation in neither is reported through the
# same fail-loud path as an unrecognised record `type` — without it, a fifth
# operation carrying operator text would be dropped in silence, which is the
# failure this tool exists to close, one level below where it was closed.
# Same two-set shape as _PARSED_TYPES / _KNOWN_IGNORED, and derived from the
# same census command above.
_KNOWN_QOP_OPS = frozenset({"enqueue", "remove", "popAll", "dequeue"})

_ASKQ_TOOL = "AskUserQuestion"

# Secondary signal for an AskUserQuestion answer — see _askq_answers().
_ASKQ_ANSWER_PREFIX = "Your questions have been answered:"

# A YAML frontmatter key at LINE START (anchored — not a mid-sentence `name:`).
_FRONTMATTER_KEY_RE = re.compile(r"^(name|description|metadata):", re.MULTILINE)


def _is_frontmatter_doc(stripped: str) -> bool:
    """True if `stripped` opens with a YAML frontmatter block — the signature of
    a rendered skill / memory / doc body injected as a user turn (e.g. a
    `/consultancy-ops` SKILL.md whose first line is `---`), never operator prose.

    Requires: first line exactly `---`, a closing `---` within the first 20
    lines, and a `name:` / `description:` / `metadata:` YAML key at LINE START
    in between (anchored — so an operator message like `---\nRe the name: x\n---`
    where `name:` appears mid-sentence does NOT match, and a bare `---` markdown
    rule an operator might type does NOT match).
    """
    lines = stripped.split("\n")
    if not lines or lines[0].strip() != "---":
        return False
    for i, line in enumerate(lines[1:20], start=1):
        if line.strip() == "---":
            head = "\n".join(lines[1:i])
            return bool(_FRONTMATTER_KEY_RE.search(head))
    return False


def _text_parts(content) -> list[str]:
    """Pull the text strings out of a message `content` (str or list-of-parts).

    A str content is one text. A list content yields each `type:"text"` part;
    `tool_result` (and any other) parts are dropped.
    """
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        out: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                txt = part.get("text", "")
                if isinstance(txt, str):
                    out.append(txt)
        return out
    return []


def is_operator_text(stripped: str) -> bool:
    """True iff `stripped` (an already-.strip()'d text) is genuine operator prose.

    Centralised so the test suite reuses the exact production predicate rather
    than re-deriving a parallel filter (SST3 reuse-production-code rule).
    """
    if not stripped:
        return False
    if stripped.startswith(_SKIP_PREFIXES):
        return False
    if stripped == _INTERRUPT_MARKER:
        return False
    if stripped.startswith(_SKILL_BODY_H1):
        return False
    # The /start skill body opens with its own first line, no H1.
    if stripped.startswith("Scan the DevProjects directory"):
        return False
    # A rendered skill/doc body whose first line is YAML frontmatter (`---`).
    if _is_frontmatter_doc(stripped):
        return False
    return True


def _askq_tool_use_ids(content) -> list[str]:
    """Ids of `AskUserQuestion` tool_use parts in an assistant message content."""
    if not isinstance(content, list):
        return []
    return [
        part["id"]
        for part in content
        if isinstance(part, dict)
        and part.get("type") == "tool_use"
        and part.get("name") == _ASKQ_TOOL
        and isinstance(part.get("id"), str)
    ]


def _askq_answers(content, askq_ids: set[str]) -> list[str]:
    """Operator menu selections: tool_result parts answering an AskUserQuestion.

    Two independent signals, either sufficient:
      1. `tool_use_id` matches an AskUserQuestion tool_use seen earlier in the
         transcript. Structural, cannot drift with harness wording.
      2. the result body opens with the harness answer marker. Covers the case
         where the assistant record carrying the tool_use is absent — a
         `--session` slice, a truncated file, or a compaction boundary — where
         signal 1 alone silently recovers nothing.

    Neither alone is enough: (1) breaks on a missing tool_use record, (2) breaks
    if the harness rewords (AP #24). Together they degrade gracefully.
    """
    if not isinstance(content, list):
        return []
    out: list[str] = []
    for part in content:
        if not isinstance(part, dict) or part.get("type") != "tool_result":
            continue
        body = part.get("content")
        # `tool_use_id` must be type-checked before the set membership test: a
        # malformed record carrying a list/dict there raises
        # `TypeError: unhashable type` and takes down the whole run with a raw
        # traceback. A malformed record is the corrupt-line contract's business
        # (skip it), not a crash — and crashing here would lose every operator
        # decision in the transcript, the exact failure this module exists to
        # prevent (#555 Ralph Tier 2).
        tool_use_id = part.get("tool_use_id")
        by_id = isinstance(tool_use_id, str) and tool_use_id in askq_ids
        by_marker = isinstance(body, str) and body.lstrip().startswith(_ASKQ_ANSWER_PREFIX)
        if not (by_id or by_marker):
            continue
        if isinstance(body, str):
            out.append(body)
        elif isinstance(body, list):
            out.extend(_text_parts(body))
    return out


def extract(records) -> tuple[list[str], set[str]]:
    """Return (ordered operator messages, unrecognised top-level record types).

    `records` is an iterable of decoded JSONL objects, in transcript order. A
    record's `tool_use` always precedes its `tool_result`, so a single ordered
    pass is enough to correlate AskUserQuestion answers.

    Malformed records (non-dict, or no string `type`) are skipped silently —
    the pre-existing corrupt-line contract. That is distinct from a record that
    HAS a type this tool does not know: those land in the returned set and the
    caller fails loud on them.
    """
    messages: list[str] = []
    unknown: set[str] = set()
    askq_ids: set[str] = set()
    # A message typed while the agent is busy is recorded TWICE: once as
    # `queue-operation`/enqueue when it is queued, and again as a replayed `user`
    # turn when it is dequeued (this module's own header describes that replay).
    # Both channels are read on purpose — the replay is not guaranteed to survive
    # every session boundary — but until dotfiles#569 Stage 5 neither was
    # de-duplicated against the other, so every such message reached the caller
    # twice. `_queued_pending` counts enqueued texts not yet matched by their
    # replay; the `user` branch consumes one instead of appending a second copy.
    # Deliberately CROSS-channel only: a genuine repeat typed twice arrives as two
    # `user` records (or two enqueues) and must survive, because "the operator said
    # it twice" is real signal the reconciliation panel is meant to see.
    _queued_pending: dict[str, int] = {}

    for obj in records:
        if not isinstance(obj, dict):
            continue
        rtype = obj.get("type")
        if not isinstance(rtype, str):
            continue

        if rtype == "assistant":
            content = obj.get("message", {}).get("content") if isinstance(obj.get("message"), dict) else None
            askq_ids.update(_askq_tool_use_ids(content))
            continue

        if rtype == "queue-operation":
            # A message typed while the agent was busy. The queue emits four
            # operations; `enqueue`, `remove` and `popAll` all carry the same
            # text in `content` as the message moves through its lifecycle, so
            # reading more than one re-emits it verbatim. Take `enqueue` only —
            # see _QOP_CONTENT_OPS for the census and the losslessness measure.
            # Most enqueued content is harness noise (<task-notification>
            # completions), so the SAME operator-text predicate filters it — no
            # second ruleset.
            # Type-check BEFORE the set lookup: `operation` is untrusted JSONL,
            # and a list/dict value makes `in` raise TypeError: unhashable type,
            # which aborts the whole transcript and loses every message already
            # recovered from it. Same guard as `tool_use_id` above, for the same
            # reason — a malformed record must be skipped, never fatal.
            operation = obj.get("operation")
            if isinstance(operation, str) and operation not in _KNOWN_QOP_OPS:
                # Operation-value drift, reported rather than dropped — the
                # `type` axis alone cannot see it, because `queue-operation`
                # IS a known type.
                unknown.add("queue-operation/" + operation)
            if not isinstance(operation, str) or operation not in _QOP_CONTENT_OPS:
                continue
            body = obj.get("content")
            if isinstance(body, str):
                stripped = body.strip()
                if is_operator_text(stripped):
                    messages.append(stripped)
                    # Expect a replayed `user` turn for this text later in the file;
                    # the `user` branch below consumes this credit rather than
                    # appending a second copy.
                    _queued_pending[stripped] = _queued_pending.get(stripped, 0) + 1
            continue

        if rtype == "user":
            if obj.get("isMeta") or obj.get("isSidechain"):
                continue
            content = obj.get("message", {}).get("content") if isinstance(obj.get("message"), dict) else None
            for text in _text_parts(content):
                stripped = text.strip()
                if is_operator_text(stripped):
                    if _queued_pending.get(stripped):
                        # The dequeue replay of a message already recovered from the
                        # queue. Consume the credit and drop this copy; the enqueue
                        # position is the chronologically correct one.
                        _queued_pending[stripped] -= 1
                        continue
                    messages.append(stripped)
            for answer in _askq_answers(content, askq_ids):
                stripped = answer.strip()
                if stripped:
                    messages.append(stripped)
            continue

        if rtype not in _KNOWN_IGNORED:
            unknown.add(rtype)

    return messages, unknown


def extract_messages(records) -> list[str]:
    """Ordered operator messages only — the thin wrapper `extract()` backs.

    Retained as the stable public name (the test suite and any external caller
    bind to it); callers needing the fail-loud signal use `extract()`.
    """
    return extract(records)[0]


def _iter_records(path: Path):
    """Yield decoded JSON objects from a JSONL file, skipping blank/garbled lines."""
    # Opened in BINARY and decoded per line. Two failures on this Issue forced
    # this shape, and both are re-tested (#555 Ralph Tier 2):
    #
    #   * A text handle decodes inside `for line in fh:`, which is OUTSIDE the try
    #     below, so a raw invalid-UTF-8 byte raised UnicodeDecodeError from the
    #     iterator itself. That is a ValueError, not an OSError, so it escaped
    #     main()'s handler too and killed the whole transcript with EMPTY stdout,
    #     losing every message already recovered from earlier lines.
    #   * Decoding the whole file with errors="replace" cures the crash but turns
    #     the bad byte into U+FFFD *in the text*, which shifts the noise-filter
    #     predicates in is_operator_text(): one corrupt byte in front of a
    #     `<command-name>`-style wrapper defeats its startswith() check, and the
    #     harness noise is then emitted as a fabricated operator message. This
    #     tool feeds the Chat Reconciliation panel, so INVENTING a message is
    #     worse than dropping one — the inverse of the #552 loss, not a fix for it.
    #
    # Per-line strict decode gives the same skip-the-bad-line contract the
    # JSONDecodeError/RecursionError catch below already uses, so all three
    # corrupt-line classes now recover identically. Splitting on newlines before
    # decoding is safe for UTF-8: 0x0A never occurs inside a multi-byte sequence.
    # A genuine U+FFFD inside well-formed UTF-8 still round-trips untouched.
    with path.open("rb") as fh:
        for raw in fh:
            try:
                line = raw.decode("utf-8").strip()
            except UnicodeDecodeError:
                continue
            if not line:
                continue
            try:
                yield json.loads(line)
            except (ValueError, RecursionError):
                # A single corrupt line must not abort the whole transcript.
                # Caught BY HIERARCHY, not by symptom (#555 exhaustive sweep):
                # json.JSONDecodeError IS a ValueError, so this strictly widens
                # the old (JSONDecodeError, RecursionError) catch — every line
                # skipped before is still skipped — while also covering the
                # decoder's other ValueError exits. The one proven in this file:
                # an integer literal of >=4301 digits trips CPython's
                # sys.get_int_max_str_digits() limit inside the scanner and
                # raises a PLAIN ValueError, which the narrower catch missed.
                # RecursionError is separate because a deeply-nested line blows
                # the decoder's stack instead of failing to parse, and it is not
                # a ValueError at all.
                # Guard-by-symptom is what made this Issue loop: four rounds
                # each found one member of this class and widened for that one.
                continue


def _slug_for_cwd(cwd: Path) -> str:
    """Derive the Claude Code project-dir slug from a working directory.

    Claude Code maps EVERY non-alphanumeric character to `-` (#555 Phase 3,
    measured against ~/.claude/projects: `project-a` →
    `auto-pb-swing-trader`, `/.claude` → `--claude`, `solo+issue` →
    `solo-issue`). The earlier `/`-only replacement derived slugs that do not
    exist for underscore/dot/plus paths.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", str(cwd.resolve()))


# A worktree project-dir slug embeds the solo branch (solo/issue-N or the
# EnterWorktree-renamed solo+issue-N) — both flatten to `solo[-+]issue-N` once the
# slug's `/`→`-` transform runs. A slug carrying this marker is unambiguous (it is
# ONE issue's worktree); a slug WITHOUT it is a bare-parent (canonical-clone) dir
# that can accumulate many issues' sessions (dotfiles#528 AC 5.3). KEEP IN SYNC with
# sst3_utils.SOLO_BRANCH_RE. The bare `wt-<N>` worktree naming (#555 Phase 3;
# the auto_pb convention) is a second accepted marker — boundary-anchored so a
# word merely ending in `wt` never false-hits.
_SOLO_ISSUE_SLUG_RE = re.compile(r"solo[-+]issue-(\d+)")
_WT_SLUG_RE = re.compile(r"(?:^|-)wt-(\d+)(?:-|$)")


def _issue_of_slug(name: str) -> int | None:
    """Issue number embedded in a worktree project-dir slug, else None."""
    m = _SOLO_ISSUE_SLUG_RE.search(name) or _WT_SLUG_RE.search(name)
    return int(m.group(1)) if m else None


# Sidecar dirs inside a directory-format session (`<uuid>/subagents/…` etc.)
# hold SUBAGENT transcripts and tool payloads — never the operator's main
# transcript. Sweeping them into the agreements log would pollute the Chat
# Reconciliation panel, so the nested fallback excludes them (#555 Phase 3).
_SESSION_SIDECAR_DIRS = frozenset({"subagents", "tool-results", "workflows"})


def _nested_session_files(proj: Path) -> list[Path]:
    """Main-transcript candidates one level down (directory-format fallback)."""
    out = []
    for p in proj.glob("*/*.jsonl"):
        if p.parent.name in _SESSION_SIDECAR_DIRS:
            continue
        if p.name.startswith("agent-"):
            continue
        out.append(p)
    return sorted(out, key=lambda p: p.stat().st_mtime)


def _dir_has_sessions(proj: Path) -> bool:
    """Does this project dir hold ANY main transcript (flat or one level down)?

    dotfiles#565 Stage 5. A worktree project dir OUTLIVES its worktree: Gate 2
    removes the worktree, Claude Code leaves the directory behind, and it sits
    there holding zero `.jsonl`. `--issue N` matched it by NAME and committed to
    it, so the documented Stage-5 invocation died with "no .jsonl session files"
    for every Issue that reached Stage 5 — which is every Issue, because the
    worktree is always gone by then. Existence is not the question; content is.
    """
    if any(proj.glob("*.jsonl")):
        return True
    return bool(_nested_session_files(proj))


def _sessions_mentioning_issue(paths: list[Path], issue: int,
                               cap: int = 200) -> list[Path]:
    """Subset of `paths` whose transcript text references `issue`.

    The disambiguator for a bare-parent project dir. `/start` cd's within one
    session, so every repo's sessions land under the same parent slug — thousands
    of them — and picking latest-by-mtime can hand back another Issue's
    transcript. Content is the only honest selector. Newest `cap` files are
    scanned so this stays bounded on a slug with years of history.
    """
    # Digit-bounded, with an issue-shaped PREFIX required. A bare substring makes
    # `#565` match `#5650`, and a naked number in prose could select an unrelated
    # transcript — the too-loose-pattern failure this Issue's own AC 2.2
    # discriminability rule exists to prevent.
    pat = re.compile(rf"(?:issues/|issue[-_ ]?#?|#)0*{issue}(?![0-9])",
                     re.IGNORECASE)
    newest = sorted(paths, key=lambda q: q.stat().st_mtime, reverse=True)[:cap]
    hits = []
    for q in newest:
        try:
            with q.open("r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if pat.search(line):
                        hits.append(q)
                        break
        except OSError:
            continue
    return sorted(hits, key=lambda q: q.stat().st_mtime)


def resolve_sessions(args) -> list[Path]:
    """Resolve the ordered list of session JSONL files to read.

    Precedence: explicit --session > --project-dir/derived dir (+ --all-sessions).
    Within a project dir, files are returned oldest-first by mtime so the emitted
    log reads chronologically across a compaction/`/clear` boundary.
    """
    if args.session:
        p = Path(args.session)
        if not p.is_file():
            raise FileNotFoundError(f"--session file not found: {p}")
        return [p]

    issue = getattr(args, "issue", None)

    if args.project_dir:
        proj = Path(args.project_dir)
    elif issue is not None:
        # dotfiles#528 AC 5.3: --issue N selects the issue's OWN worktree project dir
        # (slug carries solo[-+]issue-N), so a bare-parent CWD slug cannot silently pick
        # another issue's session by mtime.
        base = Path(args.projects_root).expanduser()
        # A dir that matches by NAME but holds no transcript is a leftover shell
        # from a removed worktree — selecting it is what made --issue unusable at
        # Stage 5 (dotfiles#565). Require content, then fall through as if absent.
        candidates = sorted(
            d for d in base.glob("*")
            if d.is_dir() and _issue_of_slug(d.name) == issue and _dir_has_sessions(d)
        )
        if len(candidates) == 1:
            proj = candidates[0]
        elif len(candidates) > 1:
            raise ValueError(
                f"--issue {issue} matches {len(candidates)} worktree project dirs "
                f"({[c.name for c in candidates]}); pass --project-dir or --session."
            )
        else:
            # No worktree dir for issue N — fall back to the CWD slug, but VERIFY it is
            # not a different issue's worktree (fail-loud, never silently wrong).
            cwd = Path(args.cwd) if args.cwd else Path.cwd()
            slug = _slug_for_cwd(cwd)
            proj = base / slug
            # `/start` cd's within one session, so a repo's transcripts are often
            # recorded under the PARENT directory's slug, not the repo's own.
            # Walk up until a slug holds a transcript (dotfiles#565 Stage 5).
            if not (proj.is_dir() and _dir_has_sessions(proj)):
                for parent in cwd.resolve().parents:
                    if parent == parent.parent:
                        break
                    cand = base / _slug_for_cwd(parent)
                    if cand.is_dir() and _dir_has_sessions(cand):
                        proj, slug = cand, cand.name
                        break
            if not proj.is_dir():
                # #555 Phase 3: fail loud WITH the exact workaround, not a bare
                # "not found" — the operator can act on this without source-diving.
                raise FileNotFoundError(
                    f"--issue {issue}: no project dir matches solo[-+]issue-{issue} "
                    f"or wt-{issue} under {base}, and the CWD slug '{slug}' does not "
                    f"exist either; workaround: pass "
                    f"--session {base}/<project-dir>/<session-uuid>.jsonl "
                    f"(locate it: ls {base} | grep -- {issue})"
                )
            proj_issue = _issue_of_slug(proj.name)
            if proj_issue is not None and proj_issue != issue:
                raise ValueError(
                    f"--issue {issue} but the resolved project dir '{proj.name}' is for "
                    f"issue {proj_issue}; pass --project-dir or --session."
                )
    else:
        base = Path(args.projects_root).expanduser()
        slug = _slug_for_cwd(Path(args.cwd) if args.cwd else Path.cwd())
        proj = base / slug

    if not proj.is_dir():
        raise FileNotFoundError(f"project dir not found: {proj}")

    sessions = sorted(proj.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    if not sessions:
        # #555 Phase 3: directory-format fallback — a main transcript nested one
        # level down (session subdir) instead of a maxdepth-1 file. Sidecar
        # transcripts (subagents/ tool-results/ workflows/, agent-*.jsonl) are
        # excluded; they are never the operator's transcript.
        nested = _nested_session_files(proj)
        if not nested:
            raise FileNotFoundError(
                f"no .jsonl session files in {proj} (flat or one level down); "
                f"workaround: pass --session <path-to-transcript>.jsonl explicitly"
            )
        if args.all_sessions:
            return nested
        groups: dict[Path, list[Path]] = {}
        for p in nested:
            groups.setdefault(p.parent, []).append(p)
        # The AC 5.3 ambiguity contract is layout-independent: count SESSIONS
        # (distinct session dirs), not files.
        if _issue_of_slug(proj.name) is None and len(groups) > 1:
            raise ValueError(
                f"ambiguous: project dir '{proj.name}' is a non-worktree (bare-parent) "
                f"slug with {len(groups)} nested sessions; pass --issue N, --session FILE, "
                f"or --all-sessions (refusing to silently pick latest-by-mtime — "
                f"dotfiles#528 AC 5.3)."
            )
        # Unambiguous: the latest session dir — ALL its chunks oldest-first
        # (one newest chunk alone would be a partial transcript).
        latest_dir = max(groups, key=lambda d: groups[d][-1].stat().st_mtime)
        return groups[latest_dir]
    if args.all_sessions:
        return sessions
    # dotfiles#528 AC 5.3: fail-loud on an ambiguous bare-parent slug. A non-worktree
    # project dir (slug carries no solo[-+]issue-N marker) with >1 session would otherwise
    # silently `return [sessions[-1]]` — latest-by-mtime — which can be a DIFFERENT issue's
    # session and corrupt the agreements log. Refuse; require an explicit disambiguator.
    if _issue_of_slug(proj.name) is None and len(sessions) > 1:
        # AC 5.3 refuses latest-by-mtime on a bare-parent slug. When --issue N was
        # supplied, telling the caller to "pass --issue N" is a dead end (#565
        # Stage 5) — disambiguate by CONTENT instead, which is a real selector.
        if issue is not None:
            matched = _sessions_mentioning_issue(sessions, issue)
            if not matched:
                raise ValueError(
                    f"--issue {issue}: project dir '{proj.name}' holds "
                    f"{len(sessions)} sessions and none of the newest 200 "
                    f"reference issue {issue}; pass --session FILE."
                )
            return matched if args.all_sessions else [matched[-1]]
        raise ValueError(
            f"ambiguous: project dir '{proj.name}' is a non-worktree (bare-parent) slug "
            f"with {len(sessions)} sessions; pass --issue N, --session FILE, or "
            f"--all-sessions (refusing to silently pick latest-by-mtime — dotfiles#528 AC 5.3)."
        )
    return [sessions[-1]]  # unambiguous: a worktree slug, or a single session


# c4:T47 (dotfiles#577) — a session chosen by DISCOVERY must belong to the target
# repo. The bare-parent project dir holds every repo's sessions (`/start` cd's
# inside one session), and the --issue content selector matches an issue NUMBER,
# which two repos can share: a consumer-private-M session naming "#21" was handed
# back for consumer-private-H #21. One session-level cwd cannot decide ownership —
# the launch dir is the shared parent — so the check reads every record's `cwd`
# (Claude Code updates it as the session cd's) and accepts the session when ANY
# of them is the repo root or below it, or when an extracted message names the
# repo. An explicit --session is the operator's own choice and is not checked.
def _repo_root(start: Path) -> Path | None:
    """The main repository root holding `start`; a linked worktree resolves to
    the repository it belongs to (its `.git` file points into
    `<main>/.git/worktrees/<name>`). None when `start` is in no repository.

    One implementation (AP #10): `sst3_mirror_utils._main_clone_root`. An
    unreadable pointer resolves to the worktree itself, a narrower match that can
    only reject a session, never accept another repo's (--session remains the
    override). Resolved so it compares like the resolved `--repo` path."""
    root = _main_clone_root(start)
    return None if root is None else root.resolve()


def _record_cwds(records) -> set[str]:
    """Every distinct `cwd` string the transcript's records carry."""
    return {r["cwd"] for r in records
            if isinstance(r, dict) and isinstance(r.get("cwd"), str) and r["cwd"]}


def _cwd_in_repo(cwd: str, root: Path) -> bool:
    """Is `cwd` the repo root or below it? Compared by PATH COMPONENT: a string
    prefix would count `<root>-archive` as inside `<root>`."""
    p = Path(cwd)
    return p == root or root in p.parents


def _messages_name_repo(messages: list[str], name: str) -> bool:
    """Does any message name the repo as a whole token (`dotfiles` must not
    match inside `dotfiles-mt5-paper-nodes`)?"""
    pat = re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(name)}(?![A-Za-z0-9_-])",
                     re.IGNORECASE)
    return any(pat.search(m) for m in messages)


def render_markdown(messages: list[str], sources: list[Path]) -> str:
    """Render the recovered messages as a `## Agreements Log` markdown block."""
    lines = ["## Agreements Log", ""]
    lines.append(f"<!-- extracted by extract-chat-agreements.py from "
                 f"{len(sources)} session(s); {len(messages)} operator message(s) -->")
    lines.append("")
    for i, msg in enumerate(messages, 1):
        # Indent continuation lines so multi-line operator messages stay inside
        # the numbered item and don't break the markdown list.
        body = msg.replace("\n", "\n   ")
        lines.append(f"{i}. {body}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Extract genuine operator-typed messages from a Claude Code session "
            "transcript for verifier-led chat reconciliation (dotfiles#522)."
        ),
    )
    parser.add_argument(
        "--session", metavar="FILE",
        help="Explicit path to a single <session>.jsonl (overrides dir discovery).",
    )
    parser.add_argument(
        "--project-dir", metavar="DIR",
        help="Claude Code project dir holding the .jsonl files "
             "(default: derived from --cwd under --projects-root).",
    )
    parser.add_argument(
        "--projects-root", metavar="DIR", default="~/.claude/projects",
        help="Root of Claude Code project dirs (default: ~/.claude/projects).",
    )
    parser.add_argument(
        "--cwd", metavar="DIR",
        help="Working directory whose slug selects the project dir "
             "(default: the actual current working directory).",
    )
    parser.add_argument(
        "--all-sessions", action="store_true",
        help="Read ALL sessions in the project dir (oldest-first), not just the "
             "latest — use when the Issue spans a compaction/`/clear` boundary.",
    )
    parser.add_argument("--issue", metavar="N", type=int, default=None,
        help="Select the worktree project dir for issue N (slug carries "
             "solo[-+]issue-N) instead of the CWD slug — disambiguates a bare-parent "
             "project dir that accumulates many issues' sessions (dotfiles#528 AC 5.3).",
    )
    parser.add_argument(
        "--repo", metavar="DIR",
        help="Target repository root for the session-ownership check (default: "
             "the repository holding --cwd; a linked worktree resolves to its "
             "main repository). A session chosen by discovery must have a record "
             "cwd at or below this root, or a message naming it (dotfiles#577 T47).",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Emit a JSON object instead of the `## Agreements Log` markdown.",
    )
    args = parser.parse_args()

    # The emit at the bottom of main() is the ONE unguarded exception site left in
    # this file, and an encode failure there costs the whole run: every recovered
    # message is already in memory, and the process dies with EMPTY stdout (#555).
    # Two proven triggers, one frame: a lone UTF-16 surrogate in a message (never
    # encodable in UTF-8), and ordinary operator prose — a `£`, a curly quote, an
    # em dash — when stdout's encoding is ascii (PYTHONIOENCODING, a POSIX-locale
    # cron/CI shell). backslashreplace makes the offending character VISIBLE and
    # emits every message, instead of trading the lot for a traceback.
    #
    # This is the OUTPUT side, which is why it is safe here and was not on input.
    # An earlier round "fixed" a decode crash with errors="replace" while READING,
    # which moved the corruption into the text where it defeated the noise filter
    # and invented a fake operator message. Filtering is finished by the time
    # anything reaches this stream, so an escape here cannot change what is kept.
    #
    # hasattr-guarded: under a closed stdout (`>&-`) sys.stdout is None, and an
    # unguarded .reconfigure() would make this fix a new crash of its own.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")

    try:
        sessions = resolve_sessions(args)
    except (OSError, ValueError) as exc:
        # ValueError = ambiguous bare-parent slug / --issue mismatch (dotfiles#528 AC 5.3).
        # OSError (not just FileNotFoundError) because discovery stats paths it did
        # not choose: `d.is_dir()` over --projects-root children and `p.stat()` as the
        # mtime sort key. A dir entry that cannot be stat'ed — symlink loop (ELOOP),
        # no execute bit (PermissionError), over-long name (ENAMETOOLONG) — raises an
        # OSError that is NOT a FileNotFoundError, and the narrower catch turned it
        # into a raw traceback with empty stdout. FileNotFoundError IS an OSError, so
        # this strictly widens: the existing not-found paths are unchanged.
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    # c4:T47 — ownership check for sessions chosen by discovery (see _repo_root).
    repo_root: Path | None = None
    if not args.session:
        if args.repo:
            repo_root = Path(args.repo).expanduser().resolve()
        else:
            here = (Path(args.cwd) if args.cwd else Path.cwd()).expanduser().resolve()
            repo_root = _repo_root(here)
            if repo_root is None:
                print(f"NOTE: session-ownership check skipped — {here} is in no "
                      f"repository; pass --repo DIR to check it.", file=sys.stderr)

    messages: list[str] = []
    unknown: set[str] = set()
    foreign: list[tuple[Path, set[str]]] = []
    for sess in sessions:
        try:
            sess_messages, sess_unknown = extract(_iter_records(sess))
            cwds = _record_cwds(_iter_records(sess)) if repo_root is not None else set()
        except OSError as exc:
            print(f"ERROR: cannot read {sess}: {exc}", file=sys.stderr)
            return 1
        if repo_root is not None and not (
                any(_cwd_in_repo(c, repo_root) for c in cwds)
                or _messages_name_repo(sess_messages, repo_root.name)):
            foreign.append((sess, cwds))
        messages.extend(sess_messages)
        unknown |= sess_unknown

    if foreign:
        # Refuse BEFORE emitting: an agreements log from another repo's session
        # would have the Chat Reconciliation panel audit the wrong conversation.
        for sess, cwds in foreign:
            seen = ", ".join(sorted(cwds)[:10]) or "(no record carries a cwd)"
            print(f"ERROR: session {sess} does not belong to {repo_root}: no record "
                  f"cwd is at or below it and no message names "
                  f"'{repo_root.name}'. cwds seen: {seen}. Pass --session FILE "
                  f"(or --repo DIR if the target repo was mis-derived).",
                  file=sys.stderr)
        return 4

    if args.json:
        print(json.dumps({
            "sources": [str(s) for s in sessions],
            "count": len(messages),
            "messages": messages,
        }, indent=2))
    else:
        print(render_markdown(messages, sessions))

    # Fail loud BEFORE the zero-message check: an unknown class is the more
    # specific diagnosis, and it is the likely CAUSE of a zero-message run.
    if unknown:
        print(
            "ERROR: unrecognised transcript record type(s): "
            + ", ".join(sorted(unknown))
            + ". This tool parses "
            + ", ".join(sorted(_PARSED_TYPES))
            + " and knowingly ignores "
            + str(len(_KNOWN_IGNORED))
            + " others; anything else may be carrying operator decisions that "
            "are being dropped. Re-derive the census (see _KNOWN_IGNORED in "
            "this script), then either parse the new class or add it to the "
            "ignore set with a reason.",
            file=sys.stderr,
        )
        return 3

    if not messages:
        print("WARNING: recovered ZERO operator messages — check the session/dir.",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
