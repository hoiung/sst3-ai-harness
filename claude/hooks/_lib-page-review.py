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
  stop   Stop: pending pictures block the stop ({"decision":"block","reason":...}),
         background tasks running or not.

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
      CONTENT  a file of a satisfied group whose last write is older than its pictures has
      its git blob id kept ("pictured"). A changed file whose bytes (the work tree's, and at
      a push the pushed commit's) still equal that id is not pending: a pre-commit stash, a
      rebase or a merge moves file and commit times without changing what was pictured.
      DELETED page files are skipped at Stop and at push alike (nothing is left to picture).
      A page edited by Bash and committed in the same turn is not dirty at Stop: the push
      gate is where it is checked.

STATE  $SST3_PAGE_REVIEW_STATE_DIR/<session>.json, written temp + rename:
      {"v": 1, "session": str, "created": float, "session_start": float,
       "edits": {root: {relpath: float}},      # Edit/Write page edits
       "scan_repos": [root],                   # edited or Bash-run since the last Stop,
                                               # or still pending at it
       "reads": [{"path", "width", "height", "mtime", "read"}],   # last MAX_READS
       "stop_blocks": {"key": str, "count": int},
       "pictured": {root: {relpath: [blob, mtime]}},   # bytes a read picture showed
       "kinds": {root: {relpath: [kind, labels]}},     # classified at the edit, so a
       "maps": {root: {viewports, pages, base_url}},   # removed work tree is still judged
       "gone_told": [root],                    # removed work trees already audited
       "last_pass": [picture]}                 # optional: what the last audited pass counted
      Older state files without the optional keys read as empty. State files older than
      PRUNE_DAYS and picture folders older than PICTURE_PRUNE_DAYS are removed on write.

AUDIT  one JSON line per decision, appended to $SST3_PAGE_REVIEW_LOG:
      {"ts", "event", "session", "agent_id", "repo", "decision", "pending", "required",
       "counted", "detail"}
      decisions: recorded, counted, subagent-not-counted, block, warn, pass, gave-up,
      opaque, corrupt-state, bad-map, bad-setting, scan-failed, gone, error. An append that
      does not land is announced on stderr ("SST3 page-review AUDIT WRITE FAILED"); the
      decision stands (same contract as sst3_audit_append in _lib-hook-output.sh). Over
      AUDIT_MAX_BYTES the log is moved to <log>.1 (replacing the older one) before the append.

OPAQUE  a push the reader cannot pin down is checked, never waved through: shell variables
      set earlier in the same command (`W=/x; cd $W`, `export W=...`, `W=/x bash s.sh`) and
      the hook's environment are put in first; a directory still unknown is checked as if
      the push ran in each repo of the session; an unknown source is HEAD, an unknown
      destination is every default branch; a `bash`/`sh`/`source`/`./` script file named
      by the command (text, up to SCRIPT_MAX_BYTES) is read once for a push inside it. Each
      such guess is audited "opaque" with its reason. A failed `git log` is audited
      "scan-failed" and the agent and operator are told.

THREAT MODEL / KNOWN BOUNDARY  a discipline aid that keeps an honest agent from forgetting
      to look, not a security boundary. An agent can still pass it: by editing the repo's
      .design-fidelity.json (ignore_files, viewports), by reading a picture that does not
      show the page, by a push it runs where the reader cannot see (ssh, a script calling a
      script, make targets, a command substitution naming the directory), or by an edit
      whose mtime is set back. The operator's switch (SST3_PAGE_REVIEW_MODE) lives in the
      hook's environment, which an agent's own commands cannot set for the hook.

ENV   SST3_PAGE_REVIEW_MODE BLOCK (default) | WARN | OFF (OFF exits in the bash entry)
      SST3_PAGE_REVIEW_LOG, SST3_PAGE_REVIEW_STATE_DIR (defaults set in the bash entry)
      SST3_PAGE_REVIEW_PICTURE_DIR     where the printed shoot command writes pictures
                                       (default ${XDG_CACHE_HOME:-~/.cache}/sst3-page-review
                                       /pictures; kept PICTURE_PRUNE_DAYS)
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
PICTURE_PRUNE_DAYS = 30
MAX_READS = 500
MAX_PUSHED_COMMITS = 500
AUDIT_MAX_BYTES = 5 * 1024 * 1024   # as sst3-destructive-op-guard.sh's LOG_MAX_BYTES
# One git wait at most GIT_TIMEOUT_S, and all of a run's git waits end by HOOK_BUDGET_S, so a
# slow repo is audited "scan-failed" before Claude Code's 30 s Stop timeout kills the hook.
GIT_TIMEOUT_S = 12.0
HOOK_BUDGET_S = 25.0
MAX_SCAN_CANDIDATES = 2000   # more new paths than this: one whole-tree `ls-files -o` instead
MAX_HASH_BYTES = 20 * 1024 * 1024   # a bigger file is never matched by content (stays pending)
SCRIPT_MAX_BYTES = 256 * 1024       # a bigger or binary script file is not read for a push
OTHER_EDIT_WINDOW_S = 2.0           # another session's recorded edit this close to a file's mtime
MAX_OTHER_STATES = 50               # newest other-session state files read for that check
TRANSCRIPT_HEAD_BYTES = 65536
SAFE_ID = re.compile(r"[^A-Za-z0-9_-]")
VAR_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SHELLS = ("sh", "bash", "dash", "zsh", "ksh", "mksh", "ash")
LOOK_FOR = ("Then Read every picture and look for cut, overlapping or badly wrapped text, alignment, "
            "wrong sums, missing details and anything hard to use. Fix what you find, then finish.")
SHOOT_INSTALLED = os.path.expanduser("~/.claude/skills/design-fidelity/scripts/shoot.py")
SHOOT_PLUGIN_GLOB = os.path.expanduser(
    "~/.claude/plugins/cache/*/design-fidelity/*/skills/design-fidelity/scripts/shoot.py")
HERE = os.path.dirname(os.path.abspath(__file__))

NOW = time.time()
STARTED = time.monotonic()
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
    Every GIT_* is dropped, the same rule as _lib-shellcmd._clean_env (that module is not
    loaded on the fast path, so the one-line rule is repeated, not imported); the class test
    test_hook_git_env_scrub.sh and this hook's own hostile-env case prove it.
    GIT_OPTIONAL_LOCKS=0: a hook's `git status` must never take index.lock, or a commit in
    another session of the same repo can fail on it."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
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
    deadline = min(time.monotonic() + timeout, STARTED + HOOK_BUDGET_S)
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


def blob_id(path: str) -> str | None:
    """git's blob id of a work-tree file (sha1 of "blob <size>\\0" + bytes), None when it is
    gone, not a regular file or over MAX_HASH_BYTES. Compared with `git ls-tree` ids, so a
    SHA-256 repository or a clean filter only ever makes a match fail (stays pending)."""
    try:
        st = os.stat(path)
        if not (st.st_mode & 0o170000 == 0o100000) or st.st_size > MAX_HASH_BYTES:
            return None
        with open(path, "rb") as f:  # sst3-sec: justified: a page file of the session's own repo, hashed only
            data = f.read()
    except OSError:
        return None
    import hashlib
    return hashlib.sha1(b"blob %d\0" % len(data) + data, usedforsecurity=False).hexdigest()


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


OPTIONAL_KEYS = (("pictured", dict), ("kinds", dict), ("maps", dict), ("gone_told", list))


def fresh_state(session: str, payload: dict) -> dict:
    st = {"v": 1, "session": session, "created": NOW, "session_start": session_start(payload),
          "edits": {}, "scan_repos": [], "reads": [], "stop_blocks": {"key": "", "count": 0}}
    for k, kind in OPTIONAL_KEYS:
        st[k] = kind()
    return st


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
        for k, kind in OPTIONAL_KEYS:   # added by the Stage-5 fixes: a state written before reads empty
            if not isinstance(st.get(k), kind):
                st[k] = kind()
        return st, True
    except FileNotFoundError:
        return fresh_state(session, payload), False
    except (OSError, ValueError) as exc:
        audit(event, session, "corrupt-state", detail=f"{path}: {exc}; replaced")
        return fresh_state(session, payload), False


def picture_dir() -> str:
    """Where the printed shoot command writes pictures: kept PICTURE_PRUNE_DAYS, outside /tmp
    (a reboot or WSL reap wipes /tmp), so the pictures a review cites outlast the session."""
    env = os.environ.get("SST3_PAGE_REVIEW_PICTURE_DIR")  # sst3-sec: justified: the operator's picture folder; only printed in the message and pruned by age under it
    if env:
        return env
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")  # sst3-sec: justified: the user's cache root, the parent of the picture folder
    return os.path.join(cache, "sst3-page-review", "pictures")


def prune(d: str, days: int = PRUNE_DAYS) -> None:
    cutoff = NOW - days * 86400
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
        prune(picture_dir(), PICTURE_PRUNE_DAYS)
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


def pushed_page_files(root: str, m: dict, src: str, remote: str,
                      dst: str) -> tuple[dict[str, float] | None, dict[str, str]]:
    """(page files in the commits a push brings onto <remote>/<dst>, their blob ids at src).
    The files are None when git cannot list them (the caller audits and tells, never passes
    on silence). Deleted pages are left out, as at Stop.

    Only the destination's own ref is left out, never the remote's other branches: SST3 pushes
    each commit to its solo branch first, so a page committed there (by Bash, unrecorded) would
    otherwise reach the default branch unchecked. With no <remote>/<dst> here, every ref of the
    remote is left out (a never-fetched remote: nothing to compare with)."""
    base = f"refs/remotes/{remote}/{dst}"
    has_base = bool(dst) and git(root, "show-ref", "--verify", "--quiet", base).returncode == 0
    # core.quotePath=false: a non-ASCII path comes back as itself, not "caf\303\251.html";
    # `--` after the revisions: a branch named like a top-level path is still a revision.
    r = git(root, "-c", "core.quotePath=false", "log", f"-n{MAX_PUSHED_COMMITS}", "--format=%x00%ct",
            "--name-only", "--diff-filter=d", src, "--not", base if has_base else f"--remotes={remote}", "--")
    if r.returncode != 0:
        return None, {}
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
        return out, {}
    blobs: dict[str, str] = {}
    t = git(root, "--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", src, "--", *out)
    if t.returncode == 0:
        for entry in t.stdout.decode("utf-8", "replace").split("\0"):
            meta, tab, path = entry.partition("\t")
            parts = meta.split()
            if tab and len(parts) == 3 and parts[1] == "blob":
                blobs[path] = parts[2]
    # A page whose working copy is what the push sends last changed no later than its commit
    # time or its file's last write, whichever is earlier: a commit made after the pictures were
    # read does not make them stale (Gate 2's order: look, commit, push). A copy that differs
    # or is gone, or a diff that fails, keeps the commit time, which can only block.
    d = git(root, "--literal-pathspecs", "diff", "--name-only", "-z", src, "--", *out)
    if d.returncode != 0:
        return out, blobs
    differs = set(d.stdout.decode("utf-8", "replace").split("\0"))
    for rel in out:
        if rel in differs:
            continue
        try:
            out[rel] = min(out[rel], os.path.getmtime(os.path.join(root, rel)))
        except OSError:
            continue
    return out, blobs


def gone_map(root: str, st: dict) -> dict:
    """The map of a removed work tree: its viewports and pages as kept at the edit."""
    snap = st["maps"].get(root) or {}
    vps = snap.get("viewports")
    return {"path": None, "page_globs": None, "ignore": [], "fixed": [],
            "viewports": vps if isinstance(vps, list) and vps else DEFAULT_VIEWPORTS,
            "pages": snap.get("pages") if isinstance(snap.get("pages"), dict) else {},
            "base_url": None, "error": None}


def kind_of(root: str, rel: str, m: dict, st: dict, gone: bool) -> tuple[str | None, list[str]]:
    """The file's kind: as kept at the edit for a removed work tree, else from the map."""
    if gone:
        kept = st["kinds"].get(root, {}).get(rel)
        if isinstance(kept, list) and len(kept) == 2:
            return kept[0], list(kept[1] or [])
    return classify(rel, m)


def others_edited(root: str, session: str, mtimes: dict[str, float]) -> set[str]:
    """The dirty files another session of the same clone recorded an Edit/Write of at about
    their mtime: theirs to picture, not this session's (two sessions in one clone). The
    operator's editor and another session's Bash edits cannot be told apart (an edge case)."""
    d = state_dir()
    mine = session_key(session) + ".json"
    try:
        files = sorted((e for e in os.scandir(d) if e.name.endswith(".json") and e.name != mine
                        and not SAFE_ID.search(e.name[:-5]) and e.is_file(follow_symlinks=False)),
                       key=lambda e: e.stat().st_mtime, reverse=True)[:MAX_OTHER_STATES]
    except OSError:
        return set()
    theirs: set[str] = set()
    for e in files:
        try:
            with open(e.path, encoding="utf-8") as f:  # sst3-sec: justified: another session's state file in the same state dir (sanitised name), parsed as JSON only
                other = json.load(f)
            recorded = other.get("edits", {}).get(root, {})
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(recorded, dict):
            continue
        for rel, mt in mtimes.items():
            t = recorded.get(rel)
            if isinstance(t, (int, float)) and abs(t - mt) <= OTHER_EDIT_WINDOW_S:
                theirs.add(rel)
    return theirs


def same_as_pictured(root: str, rel: str, want: list, *, worktree: bool, pushed_blob: str | None) -> bool:
    """The file still holds the bytes its pictures showed: in the work tree (when it changed
    there) and in the pushed commit (when it is pushed)."""
    if not (isinstance(want, list) and len(want) == 2 and isinstance(want[0], str)):
        return False
    if pushed_blob is not None and pushed_blob != want[0]:
        return False
    if worktree:
        path = os.path.join(root, rel)
        try:
            unchanged = os.path.getmtime(path) == want[1]
        except OSError:
            return False
        if not unchanged and blob_id(path) != want[0]:
            return False
    return True


def remember_pictured(st: dict, p: dict) -> None:
    """Keep the blob id of each file whose pictures were all read after its last write."""
    root = p["root"]
    if p.get("gone"):
        return
    kept = st["pictured"].setdefault(root, {})
    for rel, pic_time in p.get("pictured_files", {}).items():
        path = os.path.join(root, rel)
        try:
            mt = os.path.getmtime(path)
        except OSError:
            continue
        if mt > pic_time:
            continue                    # written after the pictures were taken: not what they show
        old = kept.get(rel)
        if isinstance(old, list) and len(old) == 2 and old[1] == mt:
            continue
        b = blob_id(path)
        if b:
            kept[rel] = [b, mt]


def pending_for(root: str, st: dict, session: str, event: str, *, scan: bool,
                pushed: dict[str, float] | None = None, pushed_blobs: dict[str, str] | None = None) -> dict | None:
    """What the repo still needs, or None when nothing changed. A satisfied result carries
    pictured_files {rel: the time its pictures were taken} for remember_pictured."""
    gone = not os.path.isdir(root)
    m = gone_map(root, st) if gone else load_map(root, session, event)
    own = st["edits"].get(root, {})
    changed: dict[str, float] = dict(own)
    in_tree = set(own)
    if scan and not gone:
        dirty = dirty_page_files(root, m, st["session_start"], session, event)
        foreign = {rel: t for rel, t in dirty.items() if rel not in own}
        theirs = others_edited(root, session, foreign) if foreign else set()
        for rel, t in dirty.items():
            if rel in theirs:
                continue
            changed[rel] = max(changed.get(rel, 0.0), t)
            in_tree.add(rel)
    pushed = pushed or {}
    for rel, t in pushed.items():
        changed[rel] = max(changed.get(rel, 0.0), t)
    if not changed:
        return None
    if m.get("error") and m["error"] not in NOTES:
        NOTES.append(m["error"])
    p = judge(root, changed, m, st, gone)
    if p["satisfied"]:
        return p
    # The times say pending; a file still holding the bytes its pictures showed is not (a
    # stash, rebase or merge moved its times only). Judge again without those files.
    kept = st["pictured"].get(root, {})
    same = [rel for rel in p["files"] if rel in kept and same_as_pictured(
        root, rel, kept[rel], worktree=rel in in_tree,
        pushed_blob=(pushed_blobs or {}).get(rel, "") if rel in pushed else None)]
    if not same:
        return p
    for rel in same:
        del changed[rel]
    q = judge(root, changed, m, st, gone)
    q["counted"] = sorted(set(q["counted"]) | set(p["counted"]))
    return q


def judge(root: str, changed: dict[str, float], m: dict, st: dict, gone: bool) -> dict:
    """Group the changed files and check each group's pictures (SATISFIED in the header)."""
    groups: dict[str, dict] = {}        # "" = unlabelled pages, "\0fixed" = fixed-size, else a label
    for rel, t in changed.items():
        kind, labels = kind_of(root, rel, m, st, gone)
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
    seen_at: dict[str, float] = {}      # file -> when its satisfied groups' pictures were taken
    for key, g in groups.items():
        t = g["t"]
        fresh = [r for r in reads if r["mtime"] > t and r["read"] > t]
        if key == "\0fixed":
            if fresh:
                counted.append(fresh[-1]["path"])
                for f in g["files"]:
                    seen_at[f] = min(seen_at.get(f, fresh[-1]["mtime"]), fresh[-1]["mtime"])
                continue
            fixed_unread = True
        else:
            missing = []
            used = []
            for v in vps:
                if key == "":
                    hit = [r for r in fresh if viewport_for(r.get("width"), vps) is v]
                else:
                    hit = [r for r in fresh if os.path.basename(r["path"]) == f"{key}-{v['name']}.png"]
                if hit:
                    counted.append(hit[-1]["path"])
                    used.append(hit[-1]["mtime"])
                else:
                    missing.append(v)
            if not missing:
                for f in g["files"]:
                    seen_at[f] = min([seen_at.get(f, min(used))] + used)
                continue
            for v in missing:
                unread[v["name"]] = v
            if key:
                labels_pending.append(key)
        files.extend(f for f in g["files"] if f not in files)
        t_last = t if t_last is None else max(t_last, t)
    pictured_files = {f: t for f, t in seen_at.items() if f not in files}
    if not files:
        return {"satisfied": True, "counted": sorted(set(counted)), "root": root, "gone": gone,
                "pictured_files": pictured_files}
    return {"satisfied": False, "root": root, "files": sorted(files), "labels": sorted(labels_pending),
            "unread": [unread[v["name"]] for v in vps if v["name"] in unread], "fixed_unread": fixed_unread,
            "since": t_last, "map": m, "counted": sorted(set(counted)), "gone": gone,
            "pictured_files": pictured_files}


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
    out_dir = os.path.join(picture_dir(), session_key(session), stamp(NOW))
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
    if p.get("gone"):
        out.append(f"  {tilde(root)} is gone (the work tree was removed): picture these pages where they "
                   f"now live and Read them.")
    if p["unread"]:
        out.append("  Still unread: " + ", ".join(f"{v['name']} {v['width']}" for v in p["unread"]) + ".")
        if p["labels"]:
            v0 = p["unread"][0]["name"]
            out.append(f"  A page's picture counts only when named <page>-<viewport>.png, the names shoot.py "
                       f"writes (e.g. {p['labels'][0]}-{v0}.png); a picture taken another way must be saved "
                       f"under that name.")
        if not p.get("gone"):           # a removed tree has no map or server to shoot from
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
    m = load_map(root, session, "edit")
    kind, labels = classify(rel, m)
    if kind is None:
        return 0
    st, _ = load_state(session, payload, "edit")
    st["edits"].setdefault(root, {})[rel] = NOW
    # Kept so the edit is still judged by its own map once the work tree is removed.
    st["kinds"].setdefault(root, {})[rel] = [kind, labels]
    st["maps"][root] = {"viewports": m["viewports"], "pages": m["pages"]}
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
    # The recorded edits this read completes keep the bytes they showed now (no git: edits
    # only), so a later stash, rebase or merge that moves their times is not a new change.
    for root in list(st["edits"]):
        if os.path.isdir(root):
            p = pending_for(root, st, session, "read", scan=False)
            if p:
                remember_pictured(st, p)
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


ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
DECLARERS = ("export", "local", "declare", "readonly", "typeset")
WRAPPERS = ("env", "command", "exec", "nohup", "time", "builtin")
REF = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*|[1-9])\}|([A-Za-z_][A-Za-z0-9_]*|[1-9]))")
SCRIPT_HINT = re.compile(r"(?:^|[\s;&|(])(?:\.|source|sh|bash|dash|zsh|ksh|mksh|ash)\s|/")


def segments(text: str) -> list[list[str]]:
    """The command's simple commands as word lists (quotes removed), split at ; & | ( ) < >
    and newlines. [] when the text does not split (an unclosed quote, a heredoc's body)."""
    import shlex
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = "#"
    out: list[list[str]] = [[]]
    try:
        for w in lex:
            if w and all(c in ";&|()<>\n" for c in w):
                out.append([])
            else:
                out[-1].append(w)
    except ValueError:
        return []
    return [s for s in out if s]


def resolve(value: str, known: dict[str, str]) -> str | None:
    """A word with its $NAME / ${NAME} put in from known; None while any $ or ` is left."""
    value = REF.sub(lambda mm: known.get(mm.group(1) or mm.group(2), mm.group(0)), value)
    return None if ("$" in value or "`" in value) else value


def shell_values(text: str, cwd: str, args: list[str] | None = None) -> dict[str, str]:
    """Names the command sets to a plain value before it uses them (NAME=value at a command's
    start, `export`/`local`/`declare`/`readonly NAME=value`, `NAME=value cmd`), on top of the
    hook's environment (the Bash tool's shell inherits it), PWD = the tool's cwd and a script's
    own arguments $1..$9. A name set twice to different values, or to a value from a command
    substitution, is dropped: it stays unresolved and the push is checked as opaque."""
    known = dict(os.environ)  # sst3-sec: justified: names the Bash tool inherits, only put into a copy of the command for the shell reader
    known["PWD"] = cwd
    for i, a in enumerate((args or [])[:9], 1):
        known[str(i)] = a
    seen: dict[str, str | None] = {}
    for words in segments(text):
        if words[0] in DECLARERS:
            cands = [w for w in words[1:] if not w.startswith("-")]
        else:
            cands = []
            for w in words:
                if not ASSIGN.match(w):
                    break
                cands.append(w)
        for w in cands:
            mm = ASSIGN.match(w)
            if not mm:
                continue
            name, val = mm.group(1), resolve(w[mm.end():], known)
            if val is None or (name in seen and seen[name] != val):
                seen[name] = None
                known.pop(name, None)
            else:
                seen[name] = known[name] = val
    return known


def substitute(text: str, values: dict[str, str]) -> str:
    """A copy of the command with each known $NAME / ${NAME} outside single quotes replaced by
    its value, quoted so the shell reader reads the same words."""
    import shlex
    out: list[str] = []
    i, n, sq, dq = 0, len(text), False, False
    while i < n:
        c = text[i]
        if c == "\\" and not sq:
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == "'" and not dq:
            sq = not sq
        elif c == '"' and not sq:
            dq = not dq
        elif c == "$" and not sq:
            mm = REF.match(text, i)
            name = mm and (mm.group(1) or mm.group(2))
            if name and name in values:
                v = values[name]
                out.append(re.sub(r'([\\"$`])', r"\\\1", v) if dq else shlex.quote(v))
                i = mm.end()
                continue
        out.append(c)
        i += 1
    return "".join(out)


def scripts_named(text: str, cwd: str) -> list[tuple[str, str | None, list[str]]]:
    """(script path, the directory it runs in or None, its arguments) for each script file the
    command runs: `bash|sh|... <file>`, `source|. <file>`, `./file` or `/path/file`. A literal
    `cd` before it moves the directory; a `cd` to a shell value makes it unknown."""
    out = []
    cur: str | None = cwd
    for words in segments(text):
        i = 0
        while i < len(words) and ASSIGN.match(words[i]):
            i += 1
        while i < len(words) and words[i] in WRAPPERS:
            i += 1
            while i < len(words) and (ASSIGN.match(words[i]) or words[i].startswith("-")):
                i += 1
        if i >= len(words):
            continue
        w0, rest = words[i], words[i + 1:]
        if w0 in ("cd", "pushd"):
            target = next((w for w in rest if not w.startswith("-")), os.path.expanduser("~"))
            if cur is None or "$" in target or "`" in target:
                cur = None
            else:
                cur = os.path.normpath(os.path.join(cur, os.path.expanduser(target)))
            continue
        path, sargs = None, []
        if os.path.basename(w0) in SHELLS:
            k, inline = 0, False
            while k < len(rest) and len(rest[k]) > 1 and rest[k][0] in "-+":
                o = rest[k]
                if o.startswith("--"):
                    k += 1
                    continue
                inline |= o[0] == "-" and "c" in o[1:]
                k += 1 + sum(ch in "oO" for ch in o[1:])
            if not inline and k < len(rest):
                path, sargs = rest[k], rest[k + 1:]
        elif w0 in (".", "source"):
            if rest:
                path, sargs = rest[0], rest[1:]
        elif "/" in w0:
            path, sargs = w0, rest
        if path and "$" not in path and "`" not in path:
            out.append((path, cur, sargs))
    return out


def read_script(path: str, cwd: str | None, fallback: str) -> str | None:
    """A named script file's text: a regular file up to SCRIPT_MAX_BYTES with no NUL byte."""
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(cwd or fallback, path)
    try:
        st = os.stat(path)
        if not (st.st_mode & 0o170000 == 0o100000) or st.st_size > SCRIPT_MAX_BYTES:
            return None
        with open(path, "rb") as f:  # sst3-sec: justified: a script the agent's own command runs, read as text for a push; never run
            data = f.read()
    except OSError:
        return None
    return None if b"\0" in data else data.decode("utf-8", "replace")


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
ANY_BRANCH = "\0any"     # a destination the hook cannot read: every default branch


def unknown(word: str) -> bool:
    return "$" in word or "`" in word


def push_targets(root: str, args: list[str]) -> tuple[str, list[tuple[str, str]], bool]:
    """(remote, [(src, dst branch)], updates-everything) for `git push <args>`. A shell value
    the hook could not put in reads as: remote origin, source HEAD, destination ANY_BRANCH."""
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
    remote = pos[0] if pos and not unknown(pos[0]) else "origin"
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
        if unknown(spec) and ":" not in re.sub(r"\$\([^)]*\)|`[^`]*`", "", spec):
            refs.append(("" if delete else "HEAD", ANY_BRANCH))   # `$REFSPEC`, `$(…)`: anything
            continue
        src, sep, dst = spec.partition(":")
        if not sep:
            dst = src
        if unknown(src):
            src = "HEAD"
        if unknown(dst):
            refs.append(("" if delete else src, ANY_BRANCH))
            continue
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


def push_records(text: str, cwd: str | None, session: str) -> list[dict]:
    """The reader's git records of a command (cwd None: the directory is unknown, "." makes
    the reader say so instead of using the hook's own)."""
    recs, _ = _reader(cwd or ".", "git", text)
    out = []
    for rec in recs:
        if "opaque" in rec:
            audit("bash", session, "opaque", detail=rec["opaque"])
            continue
        verb = rec.get("verb") or ""
        if rec.get("tool") == "git" and (verb == "push" or unknown(verb)):
            out.append(rec)
    return out


def check_push(rec: dict, cwd: str | None, candidates: list[str], st: dict, session: str,
               pend: dict, warnings: list[str], why: str) -> None:
    """Judge one push record against every repo it may run in; add what is pending to pend."""
    rcwd = rec.get("cwd")
    if rec.get("git_dir") and isinstance(rcwd or cwd, str):
        rcwd = os.path.dirname(os.path.abspath(os.path.join(rcwd or cwd, rec["git_dir"])))
    args = list(rec.get("args") or [])
    reasons = [why] if why else []
    verb = rec.get("verb") or ""
    if unknown(verb):
        reasons.append(f"its git command is a shell value ({verb})")
        args = ["origin", "$ANY"]       # maybe a push, to anywhere
    if isinstance(rcwd, str):
        root = work_tree_root(rcwd)
        if root is None:
            return                      # a real directory outside any work tree: not a repo push
        targets = [root]
    else:
        reasons.append("its directory is a shell value the hook could not put in")
        targets = candidates
    if any(unknown(a) for a in args) and not unknown(verb):
        reasons.append("a remote or ref is a shell value the hook could not put in")
    if reasons:
        audit("bash", session, "opaque", repo=targets[0] if len(targets) == 1 else None,
              detail=f"push checked as if it updates a default branch where it cannot be read: "
                     f"{'; '.join(reasons)}; repos checked: {len(targets)}")
    for root in targets:
        remote, refs, every = push_targets(root, args)
        defaults = default_branches(root, remote)
        hits: list[tuple[str, str]] = []
        for s, d in refs:
            if d == ANY_BRANCH:
                hits += [(s, b) for b in sorted(defaults)]
            elif d in defaults:
                hits.append((s, d))
        if every:
            hits = [(b, b) for b in sorted(defaults)]
        if not hits:
            continue
        m = load_map(root, session, "bash")
        pushed: dict[str, float] = {}
        blobs: dict[str, str] = {}
        failed = []
        for src, dst in hits:
            if not src:
                continue
            files, found = pushed_page_files(root, m, src, remote, dst)
            if files is None:
                failed.append(f"{src} -> {remote}/{dst}")
                continue
            for rel, t in files.items():
                pushed[rel] = max(pushed.get(rel, 0.0), t)
            for rel, b in found.items():
                blobs[rel] = b if blobs.get(rel, b) == b else ""   # two sources disagree: no match
        if failed:
            audit("bash", session, "scan-failed", repo=root,
                  detail=f"git log could not list the commits of {', '.join(failed)}: only edited and "
                         f"uncommitted page files were checked")
            warnings.append(f"{tilde(root)}: git could not list the commits of {', '.join(failed)}, so only "
                            f"edited and uncommitted page files were checked. Picture any page those commits "
                            f"change before the push lands.")
        p = pending_for(root, st, session, "bash", scan=True, pushed=pushed, pushed_blobs=blobs)
        if p:
            remember_pictured(st, p)
        if p and not p["satisfied"]:
            pend[root] = p
        elif root not in pend:
            audit("bash", session, "pass", repo=root, counted=(p or {}).get("counted"),
                  detail="push to the default branch")


def on_bash(payload: dict, session: str) -> int:
    command = (payload.get("tool_input") or {}).get("command")
    cwd = payload.get("cwd") or os.getcwd()
    if not isinstance(command, str) or not command.strip():
        return 0
    # Shell values the command sets itself (`W=/x; cd $W`) are put in before the reader reads it.
    values = shell_values(command, cwd) if "$" in command else {}
    text = substitute(command, values) if values else command
    flat_text = re.sub(r"[\"'\\]", "", text)
    roots: list[str] = []
    r0 = work_tree_root(cwd)
    if r0:
        roots.append(r0)
    if "/" in flat_text or "cd" in flat_text:
        recs, _ = _reader(cwd, "commands", text)
        for rec in recs:
            c = rec.get("cwd")
            r = work_tree_root(c) if isinstance(c, str) else None
            if r and r not in roots:
                roots.append(r)
    # A script file the command runs is read once for a push inside it (depth 1).
    scripts = []
    if SCRIPT_HINT.search(flat_text):
        for path, scwd, sargs in scripts_named(text, cwd):
            body = read_script(path, scwd, cwd)
            if body and "push" in re.sub(r"[\"'\\]", "", body):
                svals = shell_values(body, scwd or cwd, sargs)
                svals.update({k: v for k, v in values.items() if k not in svals})
                scripts.append((path, scwd, substitute(body, svals) if "$" in body else body))
    st, _ = load_state(session, payload, "bash")
    new = [r for r in roots if r not in st["scan_repos"]]
    if new:
        st["scan_repos"] += new
        save_state(st, "bash")
    if "push" not in flat_text and not scripts:
        return 0
    candidates = []
    for r in st["scan_repos"] + list(st["edits"]) + ([r0] if r0 else []):
        if r not in candidates and os.path.isdir(r):
            candidates.append(r)
    pend: dict[str, dict] = {}
    warnings: list[str] = []
    if "push" in flat_text:
        for rec in push_records(text, cwd, session):
            check_push(rec, cwd, candidates, st, session, pend, warnings, "")
    for path, scwd, body in scripts:
        for rec in push_records(body, scwd, session):
            check_push(rec, scwd, candidates, st, session, pend, warnings,
                       f"a push inside the script {path}")
    save_state(st, "bash")
    if not pend:
        if warnings:
            note = "sst3-page-review: " + " ".join(warnings)
            print(json.dumps({"systemMessage": note, "hookSpecificOutput": {
                "hookEventName": "PreToolUse", "additionalContext": note}}))
        return 0
    plist = list(pend.values())
    msg = message("sst3-page-review: push to the default branch blocked: page pictures are still unread.",
                  plist, session, "page files changed")
    if warnings:
        msg += "\n  " + " ".join(warnings)
    if MODE == "WARN":
        audit("bash", session, "warn", repo=plist[0]["root"], pending=flat(plist, "files"), required=required(plist))
        emit({"systemMessage": msg, "hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                          "additionalContext": msg}})
        return 0
    audit("bash", session, "block", repo=plist[0]["root"], pending=flat(plist, "files"), required=required(plist))
    print(msg, file=sys.stderr)   # setting NOTES are the operator's: they go to the Stop's systemMessage
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


def drop_root(st: dict, root: str) -> None:
    """Forget a removed work tree: its edits, kinds, map and pictured bytes."""
    for k in ("edits", "kinds", "maps", "pictured"):
        st[k].pop(root, None)
    st["scan_repos"] = [r for r in st["scan_repos"] if r != root]


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
    gone: list[str] = []
    for root in roots:
        if not os.path.isdir(root):
            gone.append(root)
            if root not in st["gone_told"]:
                st["gone_told"].append(root)
                audit("stop", session, "gone", repo=root, pending=sorted(st["edits"].get(root, {})),
                      detail="the work tree was removed: its recorded edits are judged from what was kept at "
                             "the edit, and nothing is scanned there")
        p = pending_for(root, st, session, "stop", scan=root in scan_set and root not in gone)
        if p is None:
            if root in gone:
                drop_root(st, root)
            continue
        remember_pictured(st, p)
        if p["satisfied"]:
            counted += p["counted"]
            if root in gone:
                drop_root(st, root)     # pictured where it now lives: nothing more to ask
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
        if NOTES:                       # a setting or map problem reaches the operator on a pass too
            emit({})
        return 0
    st["scan_repos"] = [p["root"] for p in pend if p["root"] not in gone]
    msg = message("Stop hook (sst3-page-review) blocked:", pend, session, "page files changed")
    pending_files, req = flat(pend, "files"), required(pend)
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
        for root in gone:               # a removed tree is never asked about again after a give-up
            drop_root(st, root)
        save_state(st, "stop")
        audit("stop", session, "gave-up", pending=pending_files, required=req,
              detail=f"{limit} blocks with no new picture read"
                     + (f"; removed work trees dropped: {', '.join(gone)}" if gone else ""))
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
        # Exit 0: for a Stop or PreToolUse hook exit 2 is a block, so a mistyped settings entry
        # would hold every Stop or every Bash call. The usage line still shows in the hook log.
        print("usage: _lib-page-review.py <edit|read|bash|stop> < hook-json", file=sys.stderr)
        return 0
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
    try:
        return handler(payload, session)
    except Exception as exc:  # noqa: BLE001 — any failure is audited and told, never a raw traceback
        detail = f"{type(exc).__name__}: {exc}"
        audit(event, session, "error", detail=detail)
        if event in ("stop", "bash"):
            print(json.dumps({"systemMessage": f"sst3-page-review could not check page pictures this time "
                                               f"({detail}); the {event} went ahead. Details: "
                                               f"{os.environ.get('SST3_PAGE_REVIEW_LOG', 'the page-review log')}"}))  # sst3-sec: justified: the audit log path, printed for the operator
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))  # sst3-sec: justified: the event word, validated in main()
