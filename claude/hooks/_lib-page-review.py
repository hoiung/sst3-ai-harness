#!/usr/bin/env python3
"""_lib-page-review.py — the page-review gate behind sst3-page-review.sh (dotfiles#583).

WHAT  A change a person sees rendered is not done until a picture per declared viewport of
      each touched page, taken after the change, has been opened with Read by the agent
      doing the work (rule: standards/STANDARDS.md "Run procedure", blast radius).
      This file decides; sst3-page-review.sh only sets the defaults and checks python3.

EVENTS (argv[1]; the hook JSON on stdin)
  edit   PostToolUse Edit|Write: a page file (or fixed-size output) in a git work tree is
         recorded with the time of the edit.
  read   PostToolUse Read: a picture (.png .jpg .jpeg .webp .pdf) opened by the main agent
         is recorded with its PNG width/height, mtime and read time. A subagent's Read
         (`agent_id` set) is audited and NOT counted: the agent doing the work must look.
  bash   PreToolUse Bash: the repos the command runs in are watched for Bash-made edits;
         a push that updates the default branch from a repo with unread pictures is
         blocked (exit 2, message on stderr). Commits and other pushes are never blocked.
  stop   Stop: pending pictures block the stop ({"decision":"block","reason":...}).

PAGE FILES  per work tree, from <root>/.design-fidelity.json (read by this file; shoot.py
      reads base_url, pages, viewports from the same file):
        page_files        list of globs, or {glob: [page labels from `pages`]}
        ignore_files      globs dropped from both kinds below
        fixed_size_files  globs of true-size outputs (print PDF, A4 sheet, social card)
        viewports         [{"name","width","height"}]; default DEFAULT_VIEWPORTS
      Globs are fnmatch on the repo-relative POSIX path (`*` crosses `/`). With no
      page_files key, DEFAULT_PAGE_SUFFIXES minus DEFAULT_NOT_PAGES are pages.

SATISFIED  per repo and group, T = the newest change in the group (recorded edit; dirty
      file mtime from `git status`, files newer than the session's start; at push, the
      commit time of page files in the commits the push brings onto <remote>/<dst>, those
      already on the remote's solo branch included):
        unlabelled pages  each viewport has a counted PNG with mtime > T and read > T; a
                          PNG counts for the widest declared viewport no wider than it
        label L           each viewport has `<L>-<viewport name>.png` (shoot.py's names)
                          with mtime > T and read > T
        fixed-size        one counted picture of any kind with mtime > T and read > T

STATE  $SST3_PAGE_REVIEW_STATE_DIR/<session>.json, written temp + rename:
      {"v": 1, "session": str, "created": float, "session_start": float,
       "edits": {root: {relpath: float}},      # Edit/Write page edits
       "scan_repos": [root],                   # edited or Bash-run since the last Stop,
                                               # or still pending at it
       "reads": [{"path", "width", "height", "mtime", "read"}],   # last MAX_READS
       "stop_blocks": {"key": str, "count": int},
       "last_pass": [picture]}                 # optional: what the last audited pass counted
      State files and picture folders older than PRUNE_DAYS are removed on write.

AUDIT  one JSON line per decision, appended to $SST3_PAGE_REVIEW_LOG:
      {"ts", "event", "session", "agent_id", "repo", "decision", "pending", "required",
       "counted", "detail"}
      decisions: recorded, counted, subagent-not-counted, block, warn, pass, gave-up,
      deferred, opaque, corrupt-state, bad-map, bad-setting, scan-failed. An append that does not land
      is announced on stderr ("SST3 page-review AUDIT WRITE FAILED"); the decision stands
      (same contract as sst3_audit_append in _lib-hook-output.sh). Over AUDIT_MAX_BYTES
      the log is moved to <log>.1 (replacing the older one) before the append.

ENV   SST3_PAGE_REVIEW_MODE BLOCK (default) | WARN | OFF (OFF exits in the bash entry)
      SST3_PAGE_REVIEW_LOG, SST3_PAGE_REVIEW_STATE_DIR (defaults set in the bash entry)
      SST3_PAGE_REVIEW_SHOOT_PY        shoot.py to name in the message (else installed)
      SST3_PAGE_REVIEW_MAX_STOP_BLOCKS blocks with no progress before a stop is let
                                       through (default 3, clamped to 1..7: Claude Code
                                       itself ends a turn after 8 continuations)
"""
from __future__ import annotations

# Imports are kept to what every event needs: this runs on every Stop of every session, and
# the entry starts it with `python3 -I -S` from its cached bytecode, so start-up is the cost
# (AC 1.9). git runs through os.posix_spawnp (no subprocess import); glob, shlex, contextlib,
# io and datetime load where used.
import fnmatch
import json
import os
import re
import select
import sys
import time

DEFAULT_PAGE_SUFFIXES = (".html", ".htm", ".j2", ".jinja", ".jinja2", ".css", ".scss", ".sass",
                         ".less", ".tsx", ".jsx", ".vue", ".svelte", ".astro", ".liquid", ".hbs",
                         ".njk", ".ejs", ".erb")
DEFAULT_NOT_PAGES = {
    "dirs": ("test", "tests", "__tests__", "fixtures", "test-fixtures", "node_modules", ".git",
             "dist", "build", "public", "_site", "htmlcov", "coverage"),
    "names": ("*.test.*", "*.spec.*", "*.stories.*"),
}
PICTURE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".pdf")
# Must equal shoot.py's DEFAULT_VIEWPORTS (a test compares the two by ast parse).
DEFAULT_VIEWPORTS = [
    {"name": "desktop", "width": 1440, "height": 900},
    {"name": "mobile", "width": 390, "height": 844},
]
MAP_NAME = ".design-fidelity.json"
DEFAULT_MAX_STOP_BLOCKS = 3
MAX_STOP_BLOCKS_CEILING = 7
PRUNE_DAYS = 7
MAX_READS = 500
MAX_PUSHED_COMMITS = 500
AUDIT_MAX_BYTES = 5 * 1024 * 1024   # as sst3-destructive-op-guard.sh's LOG_MAX_BYTES
GIT_TIMEOUT_S = 20.0
MAX_SCAN_CANDIDATES = 2000   # more new paths than this: one whole-tree `ls-files -o` instead
TRANSCRIPT_HEAD_BYTES = 65536
GIT_ENV_SCRUB = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")
SAFE_ID = re.compile(r"[^A-Za-z0-9_-]")
LOOK_FOR = ("Then Read every picture and look for cut, overlapping or badly wrapped text, alignment, "
            "wrong sums, missing details and anything hard to use. Fix what you find, then finish.")
SHOOT_INSTALLED = os.path.expanduser("~/.claude/skills/design-fidelity/scripts/shoot.py")
SHOOT_PLUGIN_GLOB = os.path.expanduser(
    "~/.claude/plugins/cache/*/design-fidelity/*/skills/design-fidelity/scripts/shoot.py")
HERE = os.path.dirname(os.path.abspath(__file__))

NOW = time.time()
MODE = "BLOCK"
NOTES: list[str] = []     # operator-facing setting problems, shown in a systemMessage


# ------------------------------------------------------------------ small helpers ---
def utc(ts: float) -> str:
    return time.strftime("%H:%M:%S UTC", time.gmtime(ts))


def stamp(ts: float) -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(ts))


def tilde(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def git_env() -> dict:
    """The environment for `git -C <repo>`: an inherited GIT_DIR would override -C (AP #31).
    GIT_OPTIONAL_LOCKS=0: a hook's `git status` must never take index.lock, or a commit in
    another session of the same repo can fail on it."""
    env = {k: v for k, v in os.environ.items() if k not in GIT_ENV_SCRUB}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


class Ran:
    """A finished git run: returncode (124 = timed out, 127 = git could not start), stdout."""
    __slots__ = ("returncode", "stdout")

    def __init__(self, returncode: int, stdout: bytes) -> None:
        self.returncode, self.stdout = returncode, stdout


def git_spawn(root: str, *args: str) -> tuple[int, int] | Ran:
    """Start `git -C <root> <args>`: (pid, stdout fd), or a Ran(127) when it cannot start.
    stdin and stderr are /dev/null; the pipe's own fds are close-on-exec."""
    rfd, wfd = os.pipe()
    try:
        pid = os.posix_spawnp("git", ["git", "-C", root, *args], git_env(), file_actions=[  # sst3-sec: justified: argv list, no shell; the repo path is an option value
            (os.POSIX_SPAWN_OPEN, 0, os.devnull, os.O_RDONLY, 0),
            (os.POSIX_SPAWN_DUP2, wfd, 1),
            (os.POSIX_SPAWN_OPEN, 2, os.devnull, os.O_WRONLY, 0)])
    except OSError:
        os.close(rfd)
        return Ran(127, b"")
    finally:
        os.close(wfd)
    return pid, rfd


def git_wait(started: list, timeout: float = GIT_TIMEOUT_S) -> list[Ran]:
    """Read every started run to its end (side by side), kill what outlives the timeout."""
    bufs: dict[int, list[bytes]] = {s[1]: [] for s in started if not isinstance(s, Ran)}
    live = set(bufs)
    deadline = time.monotonic() + timeout
    while live:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        ready, _, _ = select.select(list(live), [], [], left)
        for fd in ready:
            chunk = os.read(fd, 65536)
            if chunk:
                bufs[fd].append(chunk)
            else:
                live.discard(fd)
    out: list[Ran] = []
    for s in started:
        if isinstance(s, Ran):
            out.append(s)
            continue
        pid, fd = s
        timed_out = fd in live
        if timed_out:
            os.kill(pid, 9)
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        out.append(Ran(124 if timed_out else os.waitstatus_to_exitcode(status), b"".join(bufs[fd])))
    return out


def git(root: str, *args: str) -> Ran:
    return git_wait([git_spawn(root, *args)])[0]


def work_tree_root(path: str) -> str | None:
    """The nearest ancestor holding a .git entry (dir or a worktree's file), else None."""
    d = path if os.path.isdir(path) else os.path.dirname(path)
    d = os.path.abspath(d)
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def png_size(path: str) -> tuple[int | None, int | None]:
    try:
        with open(path, "rb") as f:  # sst3-sec: justified: 24 header bytes of a picture the agent itself opened with Read
            head = f.read(24)
    except OSError:
        return None, None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None, None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


# ---------------------------------------------------------------------- audit ---
def audit(event: str, session: str, decision: str, *, agent_id=None, repo=None, pending=None,
          required=None, counted=None, detail=None) -> None:
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(NOW)),
           "event": event, "session": session, "agent_id": agent_id, "repo": repo,
           "decision": decision, "pending": pending or [], "required": required or [],
           "counted": counted or [], "detail": detail}
    log = os.environ.get("SST3_PAGE_REVIEW_LOG") or os.path.expanduser("~/.claude/hooks/page-review.log")  # sst3-sec: justified: the operator's audit log path (the entry sets the default); appended to, never run
    try:
        os.makedirs(os.path.dirname(log), exist_ok=True)
        try:
            if os.path.getsize(log) > AUDIT_MAX_BYTES:
                os.replace(log, log + ".1")
        except OSError:
            pass   # silent by design: no log yet, or another hook moved it first; the append below still lands
        with open(log, "a", encoding="utf-8") as f:  # sst3-sec: justified: appends one JSON line to the operator's audit log
            f.write(json.dumps(rec) + "\n")
    except OSError:
        print(f"SST3 page-review AUDIT WRITE FAILED: could not append to {log}. "
              "The hook decision stands; its audit trail is incomplete.", file=sys.stderr)


# ---------------------------------------------------------------------- state ---
def state_dir() -> str:
    tmp = os.environ.get("TMPDIR") or "/tmp"  # sst3-sec: justified: the system temp dir, the state dir's parent when the entry did not set one
    return os.environ.get("SST3_PAGE_REVIEW_STATE_DIR") or os.path.join(tmp, "sst3-page-review")  # sst3-sec: justified: the operator's state dir; files in it are named by a sanitised session id


def session_key(session: str) -> str:
    return SAFE_ID.sub("_", session or "")[:80] or "nosession"


def session_start(payload: dict) -> float:
    """The first timestamp in the session's transcript; the hook's own first sight of it if none."""
    path = payload.get("transcript_path")
    if isinstance(path, str):
        try:
            with open(path, "rb") as f:  # sst3-sec: justified: the head of this session's own transcript (path from the hook payload), parsed as JSON
                head = f.read(TRANSCRIPT_HEAD_BYTES)
            for line in head.splitlines():
                try:
                    ts = json.loads(line).get("timestamp")
                except (ValueError, AttributeError):
                    continue
                if isinstance(ts, str):
                    from datetime import datetime
                    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except OSError:
            pass
    return NOW


def fresh_state(session: str, payload: dict) -> dict:
    return {"v": 1, "session": session, "created": NOW, "session_start": session_start(payload),
            "edits": {}, "scan_repos": [], "reads": [], "stop_blocks": {"key": "", "count": 0}}


def load_state(session: str, payload: dict, event: str) -> tuple[dict, bool]:
    """(state, existed). An unparseable file is audited and replaced."""
    path = os.path.join(state_dir(), session_key(session) + ".json")
    try:
        with open(path, encoding="utf-8") as f:  # sst3-sec: justified: this session's own state file (sanitised name under the state dir), parsed as JSON
            st = json.load(f)
        if not isinstance(st, dict) or st.get("v") != 1:
            raise ValueError("not a v1 state object")
        for k, kind in (("edits", dict), ("scan_repos", list), ("reads", list), ("stop_blocks", dict)):
            if not isinstance(st.get(k), kind):
                raise ValueError(f"{k} is not a {kind.__name__}")
        return st, True
    except FileNotFoundError:
        return fresh_state(session, payload), False
    except (OSError, ValueError) as exc:
        audit(event, session, "corrupt-state", detail=f"{path}: {exc}; replaced")
        return fresh_state(session, payload), False


def prune(d: str) -> None:
    cutoff = NOW - PRUNE_DAYS * 86400
    try:
        entries = list(os.scandir(d))
    except OSError:
        return
    for e in entries:
        name = e.name[:-5] if e.name.endswith(".json") else e.name
        if e.name.startswith(".state-") and e.name.endswith(".tmp"):
            name = "tmp"
        if SAFE_ID.search(name) or e.is_symlink():
            continue
        try:
            if e.stat().st_mtime >= cutoff:
                continue
            if e.is_dir():
                for root, dirs, files in os.walk(e.path, topdown=False):
                    for fn in files:
                        os.unlink(os.path.join(root, fn))
                    for dn in dirs:
                        os.rmdir(os.path.join(root, dn))
                os.rmdir(e.path)
            elif e.name.endswith((".json", ".tmp")):
                os.unlink(e.path)
        except OSError:
            continue


def save_state(st: dict, event: str) -> None:
    d = state_dir()
    try:
        os.makedirs(d, exist_ok=True)
        prune(d)
        st["reads"] = st["reads"][-MAX_READS:]
        tmp = os.path.join(d, f".state-{os.getpid()}-{time.time_ns()}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(st, f)
        os.replace(tmp, os.path.join(d, session_key(st["session"]) + ".json"))
    except OSError as exc:
        audit(event, st["session"], "corrupt-state", detail=f"could not write state in {d}: {exc}")


# ------------------------------------------------------------------- page map ---
_MAPS: dict[str, dict] = {}


def load_map(root: str, session: str, event: str) -> dict:
    """The repo's map, normalised: page_globs [(glob, labels)], ignore, fixed, viewports,
    pages, base_url, path, error. Cached per run."""
    if root in _MAPS:
        return _MAPS[root]
    path = os.path.join(root, MAP_NAME)
    m = {"path": None, "page_globs": None, "ignore": [], "fixed": [], "viewports": DEFAULT_VIEWPORTS,
         "pages": {}, "base_url": None, "error": None}
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as f:  # sst3-sec: justified: the repo's own .design-fidelity.json, parsed as JSON only
                raw = json.load(f)
            if not isinstance(raw, dict):
                raise ValueError("not a JSON object")
            m["path"] = path
            pf = raw.get("page_files")
            if isinstance(pf, list):
                m["page_globs"] = [(str(g), []) for g in pf]
            elif isinstance(pf, dict):
                if not all(v is None or isinstance(v, list) for v in pf.values()):
                    raise ValueError("each page_files label value must be a list of page labels")
                m["page_globs"] = [(str(g), [str(x) for x in (v or [])]) for g, v in pf.items()]
            elif pf is not None:
                raise ValueError("page_files must be a list or an object")
            for key, dest in (("ignore_files", "ignore"), ("fixed_size_files", "fixed")):
                val = raw.get(key, [])
                if not isinstance(val, list):
                    raise ValueError(f"{key} must be a list")
                m[dest] = [str(g) for g in val]
            vps = raw.get("viewports")
            if vps is not None:
                if not (isinstance(vps, list) and vps and all(
                        isinstance(v, dict) and isinstance(v.get("width"), int) and v.get("name") for v in vps)):
                    raise ValueError("viewports must be a list of {name, width, height}")
                m["viewports"] = [{"name": str(v["name"]), "width": v["width"], "height": v.get("height")} for v in vps]
            pages = raw.get("pages", {})
            m["pages"] = pages if isinstance(pages, dict) else {}
            m["base_url"] = raw.get("base_url") if isinstance(raw.get("base_url"), str) else None
        except (OSError, ValueError) as exc:
            m = {**m, "path": None, "page_globs": None, "ignore": [], "fixed": [],
                 "viewports": DEFAULT_VIEWPORTS, "error": f"{path} does not parse ({exc}); default page kinds used"}
            audit(event, session, "bad-map", repo=root, detail=m["error"])
    _MAPS[root] = m
    return m


def _any(rel: str, globs) -> bool:
    return any(fnmatch.fnmatchcase(rel, g) for g in globs)


def classify(rel: str, m: dict) -> tuple[str | None, list[str]]:
    """('page' | 'fixed' | None, labels) for a repo-relative POSIX path."""
    if _any(rel, m["ignore"]):
        return None, []
    if _any(rel, m["fixed"]):
        return "fixed", []
    if m["page_globs"] is not None:
        labels: list[str] = []
        hit = False
        for g, ls in m["page_globs"]:
            if fnmatch.fnmatchcase(rel, g):
                hit = True
                labels.extend(x for x in ls if x not in labels)
        return ("page", labels) if hit else (None, [])
    parts = rel.split("/")
    name = parts[-1]
    if not name.lower().endswith(DEFAULT_PAGE_SUFFIXES):
        return None, []
    if any(p in DEFAULT_NOT_PAGES["dirs"] for p in parts[:-1]):
        return None, []
    if any(fnmatch.fnmatchcase(name, g) for g in DEFAULT_NOT_PAGES["names"]):
        return None, []
    return "page", []


def relpath(root: str, path: str) -> str:
    return os.path.relpath(os.path.abspath(path), root).replace(os.sep, "/")


# ------------------------------------------------------------------- pending ---
def viewport_for(width: int | None, viewports: list[dict]) -> dict | None:
    """The widest declared viewport no wider than the picture."""
    if not width:
        return None
    fits = [v for v in viewports if v["width"] <= width]
    return max(fits, key=lambda v: v["width"]) if fits else None


def new_untracked(root: str, m: dict, since: float, listing: bytes) -> tuple[list[str], Ran | None]:
    """Untracked, not ignored page files created since `since`, without git's whole-tree walk
    (most of a Stop's cost in a big repo). A file created in a directory changes that
    directory's mtime, so only the directories that hold tracked files (from the `ls-files`
    listing, with their ancestors) and changed since are read; their new page files and new
    subdirectories go to one `ls-files -o` limited to them, which drops the ignored and the
    tracked. Stated limit: an untracked page that existed before the session and is edited
    in place, or a page added inside an untracked directory that existed before it, is not
    seen at Stop (no tracked directory changed); once committed, the push gate sees it.
    Returns (paths, the narrowed run or None when nothing was a candidate)."""
    direct = {path.rpartition(b"/")[0] for path in listing.split(b"\0")}
    dirs = set(direct)
    for d in direct:                    # ancestors: a new file can land in a dir holding only dirs
        d = d.rpartition(b"/")[0]
        while d and d not in dirs:
            dirs.add(d)
            d = d.rpartition(b"/")[0]
    dirs.add(b"")
    broot = os.fsencode(root)
    cand: list[str] = []
    for d in dirs:
        full = broot + b"/" + d if d else broot
        try:
            if os.stat(full).st_mtime <= since:
                continue
            entries = list(os.scandir(full))
        except OSError:
            continue
        for e in entries:
            rel_b = d + b"/" + e.name if d else e.name
            rel = os.fsdecode(rel_b)
            try:
                if e.is_dir(follow_symlinks=False):
                    if e.name != b".git" and rel_b not in dirs and e.stat(follow_symlinks=False).st_mtime > since:
                        cand.append(rel + "/")
                elif classify(rel, m)[0] is not None and e.stat(follow_symlinks=False).st_mtime > since:
                    cand.append(rel)
            except OSError:
                continue
    if not cand:
        return [], None
    narrowed = ["--"] + cand if len(cand) <= MAX_SCAN_CANDIDATES else []
    r = git(root, "--literal-pathspecs", "ls-files", "-o", "--exclude-standard", "-z", *narrowed)
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p], r


def dirty_page_files(root: str, m: dict, since: float, session: str, event: str) -> dict[str, float]:
    """Page files changed against the index (tracked, `status -uno`) or not in it (untracked,
    not ignored: new_untracked), with mtime > since. The two first git runs go side by side."""
    tracked, listing = git_wait([git_spawn(root, "status", "--porcelain=v1", "-z", "-uno"),
                                 git_spawn(root, "ls-files", "-z")])
    untracked, narrowed = new_untracked(root, m, since, listing.stdout) if listing.returncode == 0 else ([], None)
    failed = [f"git {name} exit {r.returncode}" for name, r in
              (("status", tracked), ("ls-files", listing), ("ls-files -o", narrowed)) if r and r.returncode != 0]
    if failed:
        audit(event, session, "scan-failed", repo=root,
              detail="; ".join(failed) + ": Bash-made page edits there were not checked")
    rels: list[str] = list(untracked)
    if tracked.returncode == 0:
        items = tracked.stdout.decode("utf-8", "replace").split("\0")
        i = 0
        while i < len(items):
            it = items[i]
            i += 1
            if len(it) < 4:
                continue
            code, rel = it[:2], it[3:]
            if code[0] in "RC":
                i += 1                  # -z puts the rename's source path next
            if "D" not in code:
                rels.append(rel)
    out: dict[str, float] = {}
    for rel in rels:
        if classify(rel, m)[0] is None:
            continue
        try:
            mt = os.path.getmtime(os.path.join(root, rel))
        except OSError:
            continue
        if mt > since:
            out[rel] = mt
    return out


def pushed_page_files(root: str, m: dict, src: str, remote: str, dst: str) -> dict[str, float]:
    """Page files in the commits a push brings onto <remote>/<dst>.

    Only the destination's own ref is left out, never the remote's other branches: SST3 pushes
    each commit to its solo branch first, so a page committed there (by Bash, unrecorded) would
    otherwise reach the default branch unchecked. With no <remote>/<dst> here, every ref of the
    remote is left out (a never-fetched remote: nothing to compare with)."""
    base = f"refs/remotes/{remote}/{dst}"
    has_base = bool(dst) and git(root, "show-ref", "--verify", "--quiet", base).returncode == 0
    r = git(root, "log", f"-n{MAX_PUSHED_COMMITS}", "--format=%x00%ct", "--name-only", src,
            "--not", base if has_base else f"--remotes={remote}")
    if r.returncode != 0:
        return {}
    out: dict[str, float] = {}
    for block in r.stdout.decode("utf-8", "replace").split("\0")[1:]:
        lines = [ln for ln in block.splitlines() if ln.strip()]
        if not lines:
            continue
        try:
            ct = float(lines[0])
        except ValueError:
            continue
        for rel in lines[1:]:
            if classify(rel, m)[0] is not None:
                out[rel] = max(out.get(rel, 0.0), ct)
    if not out or len(out) > MAX_SCAN_CANDIDATES:
        return out
    # A page whose working copy is what the push sends last changed no later than its commit
    # time or its file's last write, whichever is earlier: a commit made after the pictures were
    # read does not make them stale (Gate 2's order: look, commit, push). A copy that differs
    # or is gone, or a diff that fails, keeps the commit time, which can only block.
    d = git(root, "--literal-pathspecs", "diff", "--name-only", "-z", src, "--", *out)
    if d.returncode != 0:
        return out
    differs = set(d.stdout.decode("utf-8", "replace").split("\0"))
    for rel in out:
        if rel in differs:
            continue
        try:
            out[rel] = min(out[rel], os.path.getmtime(os.path.join(root, rel)))
        except OSError:
            continue
    return out


def pending_for(root: str, st: dict, session: str, event: str, *, scan: bool,
                pushed: dict[str, float] | None = None) -> dict | None:
    """What the repo still needs, or None when satisfied."""
    m = load_map(root, session, event)
    changed: dict[str, float] = dict(st["edits"].get(root, {}))
    if scan:
        for rel, t in dirty_page_files(root, m, st["session_start"], session, event).items():
            changed[rel] = max(changed.get(rel, 0.0), t)
    for rel, t in (pushed or {}).items():
        changed[rel] = max(changed.get(rel, 0.0), t)
    if not changed:
        return None
    groups: dict[str, dict] = {}        # "" = unlabelled pages, "\0fixed" = fixed-size, else a label
    for rel, t in changed.items():
        kind, labels = classify(rel, m)
        if kind is None:
            continue
        keys = ["\0fixed"] if kind == "fixed" else (labels or [""])
        for k in keys:
            g = groups.setdefault(k, {"t": 0.0, "files": []})
            g["t"] = max(g["t"], t)
            g["files"].append(rel)
    reads = st["reads"]
    vps = m["viewports"]
    files: list[str] = []
    labels_pending: list[str] = []
    unread: dict[str, dict] = {}
    fixed_unread = False
    t_last = None
    counted: list[str] = []
    for key, g in groups.items():
        t = g["t"]
        fresh = [r for r in reads if r["mtime"] > t and r["read"] > t]
        if key == "\0fixed":
            if fresh:
                counted.append(fresh[-1]["path"])
                continue
            fixed_unread = True
        else:
            missing = []
            for v in vps:
                if key == "":
                    hit = [r for r in fresh if viewport_for(r.get("width"), vps) is v]
                else:
                    hit = [r for r in fresh if os.path.basename(r["path"]) == f"{key}-{v['name']}.png"]
                if hit:
                    counted.append(hit[-1]["path"])
                else:
                    missing.append(v)
            if not missing:
                continue
            for v in missing:
                unread[v["name"]] = v
            if key:
                labels_pending.append(key)
        files.extend(f for f in g["files"] if f not in files)
        t_last = t if t_last is None else max(t_last, t)
    if not files:
        return {"satisfied": True, "counted": sorted(set(counted)), "root": root}
    return {"satisfied": False, "root": root, "files": sorted(files), "labels": sorted(labels_pending),
            "unread": [unread[v["name"]] for v in vps if v["name"] in unread], "fixed_unread": fixed_unread,
            "since": t_last, "map": m, "counted": sorted(set(counted))}


# ------------------------------------------------------------------- message ---
def shoot_py() -> tuple[str | None, str | None]:
    """(path, problem). The env override, the installed skill, then the plugin cache."""
    env = os.environ.get("SST3_PAGE_REVIEW_SHOOT_PY")  # sst3-sec: justified: the operator's shoot.py path: only printed in the message, never run
    if env:
        return (env, None) if os.path.isfile(env) else (None, f"SST3_PAGE_REVIEW_SHOOT_PY={env} is not a file")
    if os.path.isfile(SHOOT_INSTALLED):
        return SHOOT_INSTALLED, None
    import glob
    hits = sorted(glob.glob(SHOOT_PLUGIN_GLOB))
    if hits:
        return hits[-1], None
    return None, ("design-fidelity's shoot.py is not installed: run <your-dotfiles-clone>/scripts/install.sh from the dotfiles "
                  "clone, or install the design-fidelity plugin from the sst3-skills marketplace")


def shoot_command(p: dict, session: str) -> list[str]:
    m = p["map"]
    out_dir = os.path.join(state_dir(), session_key(session), stamp(NOW))
    path, problem = shoot_py()
    if path is None:
        return [f"  {problem}; then take a picture per viewport into {out_dir}"]
    cmd = ["python3", path]
    lines = []
    if m["path"]:
        cmd += ["--config", m["path"]]
    labels = p["labels"]
    if labels:
        pages = ",".join(f"{lb}:{m['pages'].get(lb, '<its path>')}" for lb in labels)
        cmd += ["--pages", pages]
    elif not (m["path"] and m["pages"]):
        cmd += ["--pages", "page:<its path>"]
    if not (m["path"] and m["base_url"]):
        cmd += ["--base-url", "<the page's URL>"]
        lines.append("              (start the repo's build or server first if the page is not served yet)")
    cmd += ["--out-dir", out_dir]
    import shlex
    shown = " ".join(c if c.startswith("<") or ":<" in c else shlex.quote(c) for c in cmd)
    return [f"  Take them:  {shown}"] + lines


def repo_lines(p: dict, session: str, head: str) -> list[str]:
    root = p["root"]
    files = ", ".join(p["files"])
    pages = f" (pages: {', '.join(p['labels'])})" if p["labels"] else ""
    out = [f"  {tilde(root)}: {head} (the last at {utc(p['since'])}; pictures must be newer): {files}{pages}"]
    if p["map"].get("error"):
        out.append(f"  Note: {p['map']['error']}")
    if p["unread"]:
        out.append("  Still unread: " + ", ".join(f"{v['name']} {v['width']}" for v in p["unread"]) + ".")
        if p["labels"]:
            v0 = p["unread"][0]["name"]
            out.append(f"  A page's picture counts only when named <page>-<viewport>.png, the names shoot.py "
                       f"writes (e.g. {p['labels'][0]}-{v0}.png); a picture taken another way must be saved "
                       f"under that name.")
        out += shoot_command(p, session)
    if p["fixed_unread"]:
        out.append("  A fixed-size output changed: render it at its true size, save the picture to a file "
                   "and Read it.")
    return out


def message(title: str, pend: list[dict], session: str, head: str) -> str:
    lines = [title]
    for p in pend:
        lines += repo_lines(p, session, head)
    lines.append("  " + LOOK_FOR)
    return "\n".join(lines)


def emit(obj: dict) -> None:
    if NOTES:
        obj["systemMessage"] = (obj.get("systemMessage", "") + "\n" if obj.get("systemMessage") else "") + \
            "sst3-page-review: " + " ".join(NOTES)
    print(json.dumps(obj))


def flat(pend: list[dict], key: str) -> list[str]:
    return [f"{p['root']}:{x}" for p in pend for x in p.get(key, [])]


def required(pend: list[dict]) -> list[str]:
    return [f"{p['root']}:{v['name']}" for p in pend for v in p.get("unread", [])] + \
           [f"{p['root']}:fixed-size" for p in pend if p.get("fixed_unread")]


# --------------------------------------------------------------------- events ---
def on_edit(payload: dict, session: str) -> int:
    path = (payload.get("tool_input") or {}).get("file_path")
    if not isinstance(path, str) or not path:
        return 0
    root = work_tree_root(path)
    if root is None:
        return 0
    rel = relpath(root, path)
    if rel.startswith("../") or rel.startswith(".git/"):
        return 0
    kind, labels = classify(rel, load_map(root, session, "edit"))
    if kind is None:
        return 0
    st, _ = load_state(session, payload, "edit")
    st["edits"].setdefault(root, {})[rel] = NOW
    if root not in st["scan_repos"]:
        st["scan_repos"].append(root)
    save_state(st, "edit")
    audit("edit", session, "recorded", agent_id=payload.get("agent_id"), repo=root, pending=[rel],
          detail={"kind": kind, "labels": labels})
    return 0


def on_read(payload: dict, session: str) -> int:
    path = (payload.get("tool_input") or {}).get("file_path")
    if not isinstance(path, str) or not path.lower().endswith(PICTURE_SUFFIXES):
        return 0
    if not os.path.isfile(path):
        return 0
    agent_id = payload.get("agent_id")
    if agent_id:
        audit("read", session, "subagent-not-counted", agent_id=agent_id, counted=[path])
        return 0
    w, h = png_size(path) if path.lower().endswith(".png") else (None, None)
    st, _ = load_state(session, payload, "read")
    st["reads"].append({"path": os.path.abspath(path), "width": w, "height": h,
                        "mtime": os.path.getmtime(path), "read": NOW})
    save_state(st, "read")
    audit("read", session, "counted", counted=[path], detail={"width": w, "height": h})
    note = sideways_note(path, w, st, session)
    if note:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note}}))
    return 0


def sideways_note(path: str, width: int | None, st: dict, session: str) -> str | None:
    """A shoot.py picture wider than its own viewport: the page scrolls sideways there."""
    if not width:
        return None
    base = os.path.basename(path)[:-4]
    vps = DEFAULT_VIEWPORTS
    for root in st["edits"]:
        vps = load_map(root, session, "read")["viewports"]
        break
    for v in vps:
        if base.endswith("-" + v["name"]) and width > v["width"]:
            return (f"sst3-page-review: {os.path.basename(path)} is {width} px wide for the {v['width']} px "
                    f"{v['name']} viewport: the page scrolls sideways at {v['width']}. Look for what overflows.")
    return None


_SHELLCMD: list = []


def _shellcmd_module():
    if not _SHELLCMD:
        import importlib.util
        spec = importlib.util.spec_from_file_location("_sst3_shellcmd", os.path.join(HERE, "_lib-shellcmd.py"))
        if spec is None or spec.loader is None:
            raise OSError("the shell reader _lib-shellcmd.py cannot be loaded")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _SHELLCMD.append(mod)
    return _SHELLCMD[0]


def _reader(cwd: str, mode: str, command: str) -> tuple[list[dict], bool]:
    """(records, ok) from the shared shell reader, run in-process through its CLI contract
    (`_lib-shellcmd.py <mode> --cwd <cwd>`: NDJSON on stdout, exit 0 = read)."""
    import contextlib
    import io
    try:
        mod = _shellcmd_module()
    except (OSError, SyntaxError) as exc:
        return [{"opaque": f"the shell reader could not be loaded ({exc})"}], False

    class _In:
        buffer = io.BytesIO(command.encode("utf-8", "surrogatepass"))

    out = io.StringIO()
    saved = sys.stdin
    sys.stdin = _In()  # type: ignore[assignment]
    try:
        with contextlib.redirect_stdout(out):
            rc = mod.main(["_lib-shellcmd.py", mode, "--cwd", cwd])
    finally:
        sys.stdin = saved
    recs = []
    for line in out.getvalue().splitlines():
        try:
            recs.append(json.loads(line))
        except ValueError:
            continue
    return recs, rc == 0


def default_branches(root: str, remote: str) -> set[str]:
    r = git(root, "symbolic-ref", "--quiet", "--short", f"refs/remotes/{remote}/HEAD")
    if r.returncode == 0:
        return {r.stdout.decode().strip().split("/", 1)[-1]}
    found = {b for b in ("main", "master")
             if git(root, "show-ref", "--verify", "--quiet", f"refs/remotes/{remote}/{b}").returncode == 0}
    return found if len(found) == 1 else {"main", "master"}


def current_branch(root: str) -> str | None:
    r = git(root, "symbolic-ref", "--quiet", "--short", "HEAD")
    return r.stdout.decode().strip() if r.returncode == 0 else None


PUSH_VALUE_OPTS = {"--repo", "-o", "--push-option", "--receive-pack", "--exec"}


def push_targets(root: str, args: list[str]) -> tuple[str, list[tuple[str, str]], bool]:
    """(remote, [(src, dst branch)], updates-everything) for `git push <args>`."""
    pos, every, delete, dry = [], False, False, False
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            pos += args[i:]
            break
        if a in PUSH_VALUE_OPTS:
            i += 1
        elif a in ("--all", "--mirror", "--branches"):
            every = True
        elif a in ("-d", "--delete"):
            delete = True
        elif a in ("-n", "--dry-run"):
            dry = True
        elif not a.startswith("-"):
            pos.append(a)
    if dry:
        return "", [], False
    cur = current_branch(root)
    remote = pos[0] if pos else "origin"
    refs: list[tuple[str, str]] = []
    if len(pos) <= 1 and not every:
        if cur:
            refs.append(("HEAD", cur))
            up = git(root, "config", "--get", f"branch.{cur}.merge").stdout.decode().strip()
            how = git(root, "config", "--get", "push.default").stdout.decode().strip()
            if up.startswith("refs/heads/") and how in ("upstream", "tracking"):
                refs.append(("HEAD", up[len("refs/heads/"):]))
    for spec in pos[1:]:
        spec = spec.lstrip("+")
        src, sep, dst = spec.partition(":")
        if not sep:
            dst = src
        if delete and not sep:
            src = ""
        if src == "HEAD" and dst == "HEAD":
            dst = cur or ""
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        elif dst.startswith("refs/"):
            continue
        refs.append((src, dst))
    return remote, refs, every


def on_bash(payload: dict, session: str) -> int:
    command = (payload.get("tool_input") or {}).get("command")
    cwd = payload.get("cwd") or os.getcwd()
    if not isinstance(command, str) or not command.strip():
        return 0
    flat_text = re.sub(r"[\"'\\]", "", command)
    roots: list[str] = []
    r0 = work_tree_root(cwd)
    if r0:
        roots.append(r0)
    if "/" in flat_text or "cd" in flat_text:
        recs, _ = _reader(cwd, "commands", command)
        for rec in recs:
            c = rec.get("cwd")
            r = work_tree_root(c) if isinstance(c, str) else None
            if r and r not in roots:
                roots.append(r)
    st, _ = load_state(session, payload, "bash")
    new = [r for r in roots if r not in st["scan_repos"]]
    if new:
        st["scan_repos"] += new
        save_state(st, "bash")
    if "push" not in flat_text:
        return 0
    recs, ok = _reader(cwd, "git", command)
    pend: list[dict] = []
    for rec in recs:
        if "opaque" in rec:
            audit("bash", session, "opaque", detail=rec["opaque"])
            continue
        if rec.get("tool") != "git" or rec.get("verb") != "push":
            continue
        rcwd = rec.get("cwd")
        if rec.get("git_dir"):
            rcwd = os.path.dirname(os.path.abspath(os.path.join(rcwd or cwd, rec["git_dir"])))
        root = work_tree_root(rcwd) if isinstance(rcwd, str) else None
        if root is None:
            continue
        remote, refs, every = push_targets(root, rec.get("args") or [])
        defaults = default_branches(root, remote or "origin")
        hits = [(s, d) for s, d in refs if d in defaults]
        if every:
            hits = [(b, b) for b in defaults]
        if not hits:
            continue
        m = load_map(root, session, "bash")
        pushed: dict[str, float] = {}
        for src, dst in hits:
            if not src:
                continue
            for rel, t in pushed_page_files(root, m, src, remote or "origin", dst).items():
                pushed[rel] = max(pushed.get(rel, 0.0), t)
        p = pending_for(root, st, session, "bash", scan=True, pushed=pushed)
        if p and not p["satisfied"]:
            pend.append(p)
        else:
            audit("bash", session, "pass", repo=root, counted=(p or {}).get("counted"),
                  detail="push to the default branch")
    if not ok and not recs:
        audit("bash", session, "opaque", detail="the shell reader failed")
    if not pend:
        return 0
    msg = message("sst3-page-review: push to the default branch blocked: page pictures are still unread.",
                  pend, session, "page files changed")
    if MODE == "WARN":
        audit("bash", session, "warn", repo=pend[0]["root"], pending=flat(pend, "files"), required=required(pend))
        emit({"systemMessage": msg, "hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                          "additionalContext": msg}})
        return 0
    audit("bash", session, "block", repo=pend[0]["root"], pending=flat(pend, "files"), required=required(pend))
    if NOTES:
        print("sst3-page-review: " + " ".join(NOTES), file=sys.stderr)
    print(msg, file=sys.stderr)
    return 2


def max_stop_blocks() -> int:
    raw = os.environ.get("SST3_PAGE_REVIEW_MAX_STOP_BLOCKS")  # sst3-sec: justified: operator setting, parsed as int and clamped to 1..7
    if raw is None or raw == "":
        return DEFAULT_MAX_STOP_BLOCKS
    try:
        n = int(raw)
    except ValueError:
        NOTES.append(f"SST3_PAGE_REVIEW_MAX_STOP_BLOCKS={raw!r} is not a number; {DEFAULT_MAX_STOP_BLOCKS} used.")
        return DEFAULT_MAX_STOP_BLOCKS
    if n > MAX_STOP_BLOCKS_CEILING:
        NOTES.append(f"SST3_PAGE_REVIEW_MAX_STOP_BLOCKS={n} is above {MAX_STOP_BLOCKS_CEILING} (Claude Code ends a "
                     f"turn after 8 continuations); {MAX_STOP_BLOCKS_CEILING} used.")
        return MAX_STOP_BLOCKS_CEILING
    return max(n, 1)


def on_stop(payload: dict, session: str) -> int:
    cwd = payload.get("cwd") or os.getcwd()
    st, existed = load_state(session, payload, "stop")
    roots = list(st["scan_repos"])
    r0 = work_tree_root(cwd)
    if r0 and r0 not in roots:
        roots.append(r0)
    for r in st["edits"]:
        if r not in roots:
            roots.append(r)
    scan_set = set(st["scan_repos"])    # git status only where the session edited or ran Bash (AC 1.5)
    pend: list[dict] = []
    counted: list[str] = []
    for root in roots:
        p = pending_for(root, st, session, "stop", scan=root in scan_set)
        if p is None:
            continue
        if p["satisfied"]:
            counted += p["counted"]
        else:
            pend.append(p)
    touched = existed or bool(pend)
    if not pend:
        st["scan_repos"] = []
        st["stop_blocks"] = {"key": "", "count": 0}
        if touched:
            seen = sorted(set(counted))
            if seen and st.get("last_pass") != seen:
                st["last_pass"] = seen
                audit("stop", session, "pass", counted=seen)
            save_state(st, "stop")
        return 0
    st["scan_repos"] = [p["root"] for p in pend]
    msg = message("Stop hook (sst3-page-review) blocked:", pend, session, "page files changed")
    pending_files, req = flat(pend, "files"), required(pend)
    if payload.get("background_tasks"):
        save_state(st, "stop")
        audit("stop", session, "deferred", pending=pending_files, required=req,
              detail=f"{len(payload['background_tasks'])} background task(s) running")
        return 0
    if MODE == "WARN":
        save_state(st, "stop")
        audit("stop", session, "warn", pending=pending_files, required=req)
        emit({"systemMessage": msg})
        return 0
    key = json.dumps([pending_files, req], sort_keys=True)
    blocks = st["stop_blocks"]
    count = blocks["count"] + 1 if blocks.get("key") == key else 1
    limit = max_stop_blocks()
    if count > limit:
        st["stop_blocks"] = {"key": "", "count": 0}
        save_state(st, "stop")
        audit("stop", session, "gave-up", pending=pending_files, required=req,
              detail=f"{limit} blocks with no new picture read")
        emit({"systemMessage": f"sst3-page-review let this stop through after {limit} blocks with no new "
                               f"picture read. Still unread:\n{msg}"})
        return 0
    st["stop_blocks"] = {"key": key, "count": count}
    save_state(st, "stop")
    audit("stop", session, "block", pending=pending_files, required=req, counted=sorted(set(counted)),
          detail={"block": count, "of": limit})
    emit({"decision": "block", "reason": msg})
    return 0


def main(argv: list[str]) -> int:
    global MODE
    if len(argv) != 2 or argv[1] not in ("edit", "read", "bash", "stop"):
        print("usage: _lib-page-review.py <edit|read|bash|stop> < hook-json", file=sys.stderr)
        return 2
    event = argv[1]
    raw_mode = (os.environ.get("SST3_PAGE_REVIEW_MODE") or "BLOCK").upper()  # sst3-sec: justified: operator setting, checked against BLOCK/WARN/OFF
    if raw_mode == "OFF":
        return 0
    if raw_mode not in ("BLOCK", "WARN"):
        NOTES.append(f"SST3_PAGE_REVIEW_MODE={raw_mode!r} is not BLOCK, WARN or OFF; BLOCK used.")
        raw_mode = "BLOCK"
    MODE = raw_mode
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        audit(event, "", "opaque", detail="the hook payload is not JSON")
        return 0
    if not isinstance(payload, dict):
        return 0
    session = str(payload.get("session_id") or "")
    if NOTES:
        audit(event, session, "bad-setting", detail=" ".join(NOTES))
    handler = {"edit": on_edit, "read": on_read, "bash": on_bash, "stop": on_stop}[event]
    return handler(payload, session)


if __name__ == "__main__":
    sys.exit(main(sys.argv))  # sst3-sec: justified: the event word, validated in main()
