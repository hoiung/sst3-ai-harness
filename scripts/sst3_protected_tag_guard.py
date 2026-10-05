#!/usr/bin/env python3
"""SST3 protected-tag-push guard.

Blocks `git push` from leaking local-only safety/backup tags to the remote.
The pre-push hook receives `<local-ref> <local-sha> <remote-ref> <remote-sha>`
lines on stdin (one per ref being pushed). Any `refs/tags/<protected-pattern>`
line in that list causes the push to fail.

Protected patterns (configurable via PROTECTED_PATTERNS):
  - backup/*           Operator/agent local rebase + checkpoint bookmarks.
  - pre-*-YYYY-MM-DD   Operator pre-merge / pre-leader checkpoint tags.
  - pre-*-pre-*        Pre-tool-adoption / pre-X-Y compound checkpoints.
  - tmp/*, wip/*       Generic work-in-progress markers.

Bypass (operator-authorised only):
  SST3_PROTECTED_TAG_OVERRIDE=1 git push origin <protected-tag>

Rationale: git's default is NOT to push tags, but `git push --tags`,
`git push --follow-tags` over a release commit, or explicit
`git push origin backup/foo` will leak local-only bookmarks. This hook
defends against that across all consumer repos via SST3 propagation.

Exit codes:
  0 — no protected tags in the push, allow.
  1 — protected tag detected, push blocked.

Issue: auto_pb#1483 Stage 5 closure follow-up — operator: "otherwise we
get into the same problem every time".
"""

from __future__ import annotations

import fnmatch
import os
import sys

# Patterns that must not leak to remote. Add new ones here; consumer repos
# pick them up on next propagate-mirrors run.
PROTECTED_PATTERNS = [
    "backup/*",
    "pre-leader-merge-*",
    "pre-rebase-*",
    "pre-tool-adoption*",
    "v*-pre-tool-adoption",
    "tmp/*",
    "wip/*",
]

# Refs git passes for tag deletion (sha = zeros). We don't block deletions —
# tag cleanup is exactly the use case we want to allow.
DELETION_SHA = "0000000000000000000000000000000000000000"
# `git push` pre-push hook passes 4 fields per ref: local_ref, local_sha,
# remote_ref, remote_sha. Anything shorter is malformed input — skip.
PRE_PUSH_FIELD_COUNT = 4


def main() -> int:
    if os.environ.get("SST3_PROTECTED_TAG_OVERRIDE") == "1":  # sst3-sec: justified: operator bypass flag, compared to "1" only, value never used
        print(
            "[sst3-protected-tag-guard] SST3_PROTECTED_TAG_OVERRIDE=1 — bypassed.",
            file=sys.stderr,
        )
        return 0

    blocked: list[tuple[str, str]] = []
    for raw in sys.stdin:
        parts = raw.split()
        if len(parts) < PRE_PUSH_FIELD_COUNT:
            continue
        _local_ref, local_sha, remote_ref, _remote_sha = (
            parts[0],
            parts[1],
            parts[2],
            parts[3],
        )
        # Only inspect tag pushes (not branches, not deletions).
        if not remote_ref.startswith("refs/tags/"):
            continue
        if local_sha == DELETION_SHA:
            # Tag deletion via `git push origin :refs/tags/<name>` — allow.
            continue
        tag_name = remote_ref[len("refs/tags/") :]
        for pattern in PROTECTED_PATTERNS:
            if fnmatch.fnmatch(tag_name, pattern):
                blocked.append((tag_name, pattern))
                break

    if not blocked:
        return 0

    print(
        "[sst3-protected-tag-guard] BLOCKED — local-only tags in push:", file=sys.stderr
    )
    for tag, pat in blocked:
        print(
            f"  refs/tags/{tag}  (matches protected pattern '{pat}')", file=sys.stderr
        )
    print("", file=sys.stderr)
    print(
        "These tags are local-only safety bookmarks (rebase backups, pre-merge",
        file=sys.stderr,
    )
    print(
        "checkpoints, WIP markers). If you genuinely need to push one (e.g. for",
        file=sys.stderr,
    )
    print("cross-machine sync), bypass with:", file=sys.stderr)
    print("  SST3_PROTECTED_TAG_OVERRIDE=1 git push origin <tag>", file=sys.stderr)
    print("", file=sys.stderr)
    print("To remove a protected tag locally instead:", file=sys.stderr)
    print("  git tag -d <tag>", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
