#!/usr/bin/env python3
"""_lib-shellcmd.py — one shell-command reader for the SST3 PreToolUse hooks (dotfiles#577 Stage 5).

WHY   The destructive-op guard, the branch guard's canon lock, the stash guard and the
      stage-order gate each split the Bash command their own way (`read -ra`, regexes anchored
      on `git` + verb, a bare `cd X` segment). Quoting (`git "push" -f`), wrappers (`sh -c`,
      `eval`, `$( )`, `env -C`, `command`), git config options (`-c ALIAS.p=…`,
      `-c remote.origin.mirror=true`) and cd spellings (`pushd X >/dev/null`, `cd -- X`) all
      got past them; each was measured against real git in the Stage-5 fix review. Patching
      each spelling is the arms race; this reads the command the way the shell does once.
      The canonical-sync guard (R38) matched its build commands against the whole text and
      judged the hook's own directory; it reads the commands here too.

WHAT  Tokenises with quote removal, escapes, operators, redirections (fd prefixes, here-docs,
      here-strings) and nested commands ($( ), backticks, <( )); unwraps env/command/builtin/
      exec/nohup/time/nice/timeout/sudo/xargs/flock/find -exec, `sh -c`, `eval` and a shell
      fed by a pipe, here-string or here-doc; tracks the directory each command runs in (cd,
      pushd/popd, subshells, env -C, git -C, --git-dir, exported GIT_DIR).

USAGE  python3 _lib-shellcmd.py <mode> [--cwd DIR] < command-text
  commands     NDJSON per simple command: {argv, cwd, env}
  git          NDJSON per git invocation and `gh pr checkout`: {tool, cwd, git_dir, verb, args}
  destructive  NDJSON per DENY: {kind, reason}. kind "branch-force-delete" is not a DENY by
               itself: the caller runs its merged-branch check. Every other kind is a DENY.
  cwd is null where the directory cannot be known (`cd -`, `cd $VAR`, popd past the start).
  Every mode adds {"opaque": why} for a part whose text only exists at run time: a script
  piped in from a program the reader cannot run, a process-substitution script, a script or
  eval whose words expand at run time, xargs operands from an unknown pipe. Reading more
  spellings could not close that class (#577 Stage 5 fix review 2), so the caller falls back
  to its whole-text check, on the text with quotes and backslashes removed.
EXIT  0 = read (records may be empty); 2 = usage; 3 = the reader failed (it prints one opaque
      record); the caller treats it as it treats opaque.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

SHELLS = {"sh", "bash", "dash", "zsh", "ksh", "mksh", "ash"}
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "in",
            "case", "esac", "!", "{", "}", "function", "select", "coproc", "[[", "]]"}
OPS = (";;", "&&", "||", "|&", ";", "&", "|", "(", ")", "\n")
REDIRS = ("&>>", "<<<", "<<-", "<<", "<>", "<&", ">>", ">&", ">|", "&>", "<", ">")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_DEPTH = 8
OPAQUE: list = []           # why a part of the command could not be read (main() resets it)


class Word:
    __slots__ = ("text", "subs", "literal")

    def __init__(self):
        self.text, self.subs, self.literal = [], [], True

    def s(self):
        return "".join(self.text)


def _balanced(src: str, i: int, open_: str, close: str) -> int:
    """Index just past the `close` matching the `open_` already consumed before i."""
    depth, n = 1, len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = src.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == "\\" else 1
            i += 1
            continue
        if c == open_:
            depth += 1
        elif c == close:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def tokenize(src: str):
    """Yield ("op", text) / ("word", Word) / ("redir", (op, target Word | None, heredoc body))."""
    src = src.replace("\\\n", "")
    out, i, n = [], 0, len(src)
    word = None
    pending_docs = []          # [(delim, strip_tabs, record)] — bodies start after the next newline

    def end_word():
        nonlocal word
        if word is not None:
            out.append(("word", word))
            word = None

    def cur():
        nonlocal word
        if word is None:
            word = Word()
        return word

    while i < n:
        c = src[i]
        if c in " \t\r":
            end_word()
            i += 1
            continue
        if c == "\n":
            end_word()
            out.append(("op", "\n"))
            i += 1
            for delim, strip, rec in pending_docs:      # here-doc bodies
                body = []
                while i < n:
                    j = src.find("\n", i)
                    line = src[i:] if j < 0 else src[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                rec[2] = "\n".join(body)
            pending_docs = []
            continue
        if src.startswith("$'", i):                       # ANSI-C quoting: $'\x63heckout'
            j = i + 2
            while j < n and src[j] != "'":
                j += 2 if src[j] == "\\" else 1
            raw = src[i + 2:j]
            try:
                raw = raw.encode("latin-1", "backslashreplace").decode("unicode_escape")
            except (UnicodeError, ValueError):
                pass
            cur().text.append(raw)
            i = j + 1
            continue
        if c == "#" and word is None:
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\\":
            if i + 1 < n:
                cur().text.append(src[i + 1])
            i += 2
            continue
        if c == "'":
            j = src.find("'", i + 1)
            j = n if j < 0 else j
            cur().text.append(src[i + 1:j])
            i = j + 1
            continue
        if c == '"':
            w = cur()
            i += 1
            while i < n and src[i] != '"':
                d = src[i]
                if d == "\\" and i + 1 < n and src[i + 1] in '"\\$`\n':
                    w.text.append(src[i + 1])
                    i += 2
                elif src.startswith("$(", i):
                    j = _balanced(src, i + 2, "(", ")")
                    w.subs.append(src[i + 2:j - 1])
                    w.text.append(src[i:j])
                    w.literal = False
                    i = j
                elif d == "`":
                    j = src.find("`", i + 1)
                    j = n if j < 0 else j
                    w.subs.append(src[i + 1:j])
                    w.text.append(src[i:j + 1])
                    w.literal = False
                    i = j + 1
                else:
                    if d == "$":
                        w.literal = False
                    w.text.append(d)
                    i += 1
            i += 1
            continue
        if src.startswith("$(", i) or ((c in "<>") and src.startswith("(", i + 1) and word is None):
            w = cur()
            start = i + 2
            j = _balanced(src, start, "(", ")")
            w.subs.append(src[start:j - 1])
            w.text.append(src[i:j])
            w.literal = False
            i = j
            continue
        if c == "`":
            j = src.find("`", i + 1)
            j = n if j < 0 else j
            w = cur()
            w.subs.append(src[i + 1:j])
            w.text.append(src[i:j + 1])
            w.literal = False
            i = j + 1
            continue
        if c in "<>&" or (c.isdigit() and word is None and re.match(r"\d+[<>]", src[i:])):
            m = re.match(r"\d*", src[i:]) if c.isdigit() else None
            k = i + (len(m.group(0)) if m else 0)
            op = next((r for r in REDIRS if src.startswith(r, k)), None)
            if op is not None and (c != "&" or op in ("&>", "&>>")):
                end_word()
                i = k + len(op)
                while i < n and src[i] in " \t":
                    i += 1
                if op in (">&", "<&") and i < n and (src[i].isdigit() or src[i] == "-"):
                    i += 1
                    out.append(("redir", [op, None, None]))
                    continue
                # the target word: read it with the same rules, then detach it
                sub = tokenize_one_word(src, i)
                tgt, i = sub
                rec = [op, tgt, None]
                if op in ("<<", "<<-") and tgt is not None:
                    pending_docs.append((tgt.s(), op == "<<-", rec))
                out.append(("redir", rec))
                continue
        if c == "$" and src.startswith("{", i + 1):
            j = src.find("}", i)
            j = n if j < 0 else j + 1
            w = cur()
            w.text.append(src[i:j])
            w.literal = False
            i = j
            continue
        op = next((o for o in OPS if src.startswith(o, i)), None)
        if op is not None and op != "\n":
            end_word()
            out.append(("op", op))
            i += len(op)
            continue
        if c == "$":
            cur().literal = False
        cur().text.append(c)
        i += 1
    end_word()
    return out


def tokenize_one_word(src: str, i: int):
    """Read one shell word starting at i (a redirection target or here-doc delimiter)."""
    n = len(src)
    j = i
    while j < n and src[j] not in " \t\r\n;&|()<>":
        if src[j] == "'":
            k = src.find("'", j + 1)
            j = n if k < 0 else k + 1
        elif src[j] == '"':
            j += 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j += 1
        elif src[j] == "\\":
            j += 2
        else:
            j += 1
    toks = [t for t in tokenize(src[i:j]) if t[0] == "word"]
    return (toks[0][1] if toks else None), j


class State:
    """cwd, exported env, unexported shell variables, the pushd stack. `aliases` (git aliases a
    `git config` in this command defined) is one set shared by every copy: config is on disk,
    so a subshell's definition holds after it."""
    def __init__(self, cwd, home, env=None, stack=None, shvars=None, aliases=None):
        self.cwd, self.home = cwd, home
        self.env = dict(env or {})
        self.stack = list(stack or [])
        self.shvars = dict(shvars or {})
        self.aliases = aliases if aliases is not None else {}
        self.from_xargs = False

    def copy(self):
        return State(self.cwd, self.home, self.env, self.stack, self.shvars, self.aliases)


def _word(text: str, literal: bool = True) -> Word:
    w = Word()
    w.text, w.literal = [text], literal
    return w


def _join(words) -> Word:
    """Words joined with spaces, as `watch` and `env -S` hand them to a shell."""
    return _word(" ".join(x.s() for x in words), all(x.literal for x in words))


def expand_path(w: Word, st: State):
    """A directory word as the shell would expand it, or None when that needs runtime state."""
    t = w.s()
    if t == "~" or t.startswith("~/"):
        t = st.home + t[1:]
    for var, val in (("$HOME", st.home), ("${HOME}", st.home), ("$PWD", st.cwd), ("${PWD}", st.cwd),
                     ("$(pwd)", st.cwd), ("`pwd`", st.cwd)):
        if t.startswith(var):
            if val is None:
                return None
            t = val + t[len(var):]
    if "$" in t or "`" in t or "*" in t or "?" in t:
        return None
    if not t:
        return None
    if not t.startswith("/"):
        if st.cwd is None:
            return None
        t = os.path.join(st.cwd, t)
    return os.path.normpath(t)


def parse(src: str, st: State, depth: int, emit):
    """Walk the token stream; call emit(argv_words, state, stdin_text) per simple command."""
    if depth > MAX_DEPTH:
        return
    toks = tokenize(src)
    words, stdin_text, prev = [], None, None
    saved = []

    def flush(op):
        nonlocal words, stdin_text, prev
        if words:
            if op in ("|", "|&"):
                run = st.copy()          # a pipeline element runs in a subshell
                _command(words, run, depth, emit, stdin_text, prev)
            else:
                _command(words, st, depth, emit, stdin_text, prev)
            prev = (words, op, stdin_text)
        elif op not in ("|", "|&"):
            prev = None
        words, stdin_text = [], None

    for kind, val in toks:
        if kind == "word":
            for sub in val.subs:
                parse(sub, st.copy(), depth + 1, emit)
            words.append(val)
        elif kind == "redir":
            op, tgt, body = val
            if tgt is not None:
                for sub in tgt.subs:
                    parse(sub, st.copy(), depth + 1, emit)
            if op == "<<<" and tgt is not None:
                stdin_text = tgt.s()
            elif op in ("<<", "<<-"):
                stdin_text = val          # filled when the body is read (list is mutable)
        else:
            flush(val)
            if val == "(":
                saved.append(st.copy())
            elif val == ")" and saved:
                old = saved.pop()
                st.cwd, st.env, st.stack = old.cwd, old.env, old.stack
    flush(";")


def _opt_span(o: str, takes) -> int:
    """Words an option uses: 2 when its value is the next word, else 1. A short cluster
    (`-Eu root`) takes the next word when its first value-taking letter is its last."""
    if o.startswith("--"):
        return 2 if o in takes else 1
    for k, ch in enumerate(o[1:], 1):
        if "-" + ch in takes:
            return 2 if k == len(o) - 1 else 1
    return 1


def _strip_prefix(argv, st, env):
    """Drop assignments and exec wrappers; return the argv that actually runs (may be empty)."""
    i = 0
    while i < len(argv) and ASSIGN.match(argv[i].s()):
        k, _, v = argv[i].s().partition("=")
        env[k] = v
        i += 1
    while i < len(argv):
        a = os.path.basename(argv[i].s())
        if a in KEYWORDS:
            i += 1
            continue
        if a in ("command", "builtin", "exec", "nohup", "chronic", "unbuffer", "setsid", "time", "busybox"):
            i += 1
            while i < len(argv) and argv[i].s().startswith("-") and argv[i].s() != "--":
                if a == "exec" and argv[i].s() == "-a":
                    i += 1
                if a == "command" and argv[i].s() in ("-v", "-V"):
                    return []
                i += 1
            if i < len(argv) and argv[i].s() == "--":
                i += 1
            continue
        if a in ("nice", "ionice", "stdbuf", "timeout", "sudo", "doas", "flock", "watch"):
            takes = {"nice": {"-n"}, "ionice": {"-c", "-n", "-p", "-P", "-u"}, "stdbuf": {"-i", "-o", "-e"},
                     "timeout": {"-s", "-k", "--signal", "--kill-after"},
                     "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-T", "-R", "-D", "--user",
                              "--group", "--close-from", "--host", "--prompt", "--role", "--type",
                              "--other-user", "--command-timeout", "--chroot", "--chdir"},
                     "doas": {"-u", "-C"},
                     "flock": {"-w", "-E", "--timeout", "--conflict-exit-code"},
                     "watch": {"-n", "--interval"}}[a]
            execs = False                    # watch -x runs its words itself, not through sh -c
            i += 1
            while i < len(argv) and argv[i].s().startswith("-") and argv[i].s() != "--":
                o = argv[i].s()
                if a == "sudo" and o in ("-D", "--chdir") and i + 1 < len(argv):
                    st.cwd = expand_path(argv[i + 1], st)
                elif a == "sudo" and o.startswith("--chdir="):
                    st.cwd = expand_path(_word(o.split("=", 1)[1]), st)
                if a == "flock" and o in ("-c", "--command") and i + 1 < len(argv):
                    return ["__EVAL__", argv[i + 1]]
                if a == "watch" and (o in ("-x", "--exec") or (not o.startswith("--") and "x" in o[1:])):
                    execs = True
                i += _opt_span(o, takes)
            if i < len(argv) and argv[i].s() == "--":
                i += 1
            if a in ("timeout",) and i < len(argv):
                i += 1                       # the duration
            if a == "flock" and i < len(argv):
                i += 1                       # the lock file; `flock <file> -c <command>` is its usual form
                if i + 1 < len(argv) and argv[i].s() in ("-c", "--command"):
                    return ["__EVAL__", argv[i + 1]]
            if a == "watch" and not execs:
                return ["__EVAL__", _join(argv[i:])]   # watch runs sh -c '<words>'
            continue
        if a == "env":
            i += 1
            while i < len(argv):
                o = argv[i].s()
                if o in ("-C", "--chdir") and i + 1 < len(argv):
                    st.cwd = expand_path(argv[i + 1], st)
                    i += 2
                elif o.startswith("--chdir="):
                    w = Word()
                    w.text = [o.split("=", 1)[1]]
                    st.cwd = expand_path(w, st)
                    i += 1
                elif o in ("-S", "--split-string") and i + 1 < len(argv):
                    return ["__EVAL__", _join(argv[i + 1:])]
                elif o.startswith("--split-string="):
                    return ["__EVAL__", _join([_word(o.split("=", 1)[1], argv[i].literal), *argv[i + 1:]])]
                elif o in ("-u", "--unset") and i + 1 < len(argv):
                    env.pop(argv[i + 1].s(), None)
                    i += 2
                elif o == "--":
                    i += 1
                elif o.startswith("-"):
                    i += 1
                elif ASSIGN.match(o):
                    k, _, v = o.partition("=")
                    env[k] = v
                    i += 1
                else:
                    break
            continue
        if a == "xargs":
            i += 1
            takes = {"-a", "-d", "-E", "-e", "-I", "-i", "-L", "-l", "-n", "-P", "-s", "--arg-file",
                     "--delimiter", "--max-args", "--max-procs", "--max-chars", "--replace"}
            while i < len(argv) and argv[i].s().startswith("-"):
                o = argv[i].s()
                i += 2 if (o in takes and "=" not in o) else 1
            st.from_xargs = True             # its operands arrive on stdin (see _command)
            continue
        break
    return argv[i:]


def _printf_text(args):
    """What `printf FORMAT ARGS` prints: the format reused until the arguments run out."""
    if args[:1] == ["--"]:
        args = args[1:]
    if not args or args[0].startswith("-v"):
        return "" if not args else None      # -v assigns a variable and prints nothing
    esc = {"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"'}
    fmt = re.sub(r"\\(.)", lambda m: esc.get(m.group(1), "\\" + m.group(1)), args[0])
    rest, out = args[1:], []
    spec = re.compile(r"%(%|[-+ #0-9.]*[sbqdiouxXeEfFgGc])")
    while True:
        used = 0

        def fill(m):
            nonlocal used
            if m.group(1) == "%":
                return "%"
            used += 1
            return rest[used - 1] if used <= len(rest) else ""
        out.append(spec.sub(fill, fmt))
        rest = rest[used:]
        if not rest or not used:
            return "".join(out)


def _pipe_text(prev):
    """The text a pipe's producer writes, when the reader can know it: echo / printf of literal
    words, or `cat` of a here-doc or here-string. None when it is another program's output."""
    if not prev or prev[1] not in ("|", "|&") or not prev[0]:
        return None
    pw, stdin_text = prev[0], prev[2]
    name, args = os.path.basename(pw[0].s()), pw[1:]
    if not all(w.literal for w in pw):
        return None
    if name == "echo":
        return " ".join(w.s() for w in args if not re.fullmatch(r"-[neE]+", w.s()))
    if name == "printf":
        return _printf_text([w.s() for w in args])
    if name == "cat" and not [w for w in args if not w.s().startswith("-")]:
        return stdin_text[2] if isinstance(stdin_text, list) else stdin_text
    return None


def _script(w: Word, st: State, depth, emit, what: str):
    """Read a script handed over as one word (sh -c, eval, flock -c, watch, env -S)."""
    if not w.literal:
        OPAQUE.append(f"{what}: the script's words expand only at run time")
    parse(w.s(), st.copy(), depth + 1, emit)


def _command(words, st: State, depth, emit, stdin_text, prev):
    env = dict(st.env)
    run = st.copy()              # env -C / sudo -D move this one command only
    argv = _strip_prefix(list(words), run, env)
    if argv and argv[0] == "__EVAL__":
        _script(argv[1], run, depth, emit, "a wrapped command")
        return
    if not argv:
        # A bare assignment statement sets a shell variable. It reaches a child process once
        # exported (`GIT_DIR=x; export GIT_DIR`), or at once when the name is already exported.
        for w in words:
            if ASSIGN.match(w.s()):
                k, _, v = w.s().partition("=")
                st.shvars[k] = v
                if k in st.env:
                    st.env[k] = v
        return
    name = os.path.basename(argv[0].s())
    args = argv[1:]
    if isinstance(stdin_text, list):
        stdin_text = stdin_text[2]
    if run.from_xargs:
        # xargs adds the words it reads from stdin to the command: known for a literal echo /
        # printf / here-doc producer, otherwise only at run time.
        fed = _pipe_text(prev) if prev else stdin_text
        if fed is None:
            OPAQUE.append(f"xargs {name}: its operands come from a pipe the reader cannot see")
        else:
            argv = argv + [_word(t) for t in fed.split()]
            args = argv[1:]
    if name in ("cd", "pushd"):
        ops = [a for a in args if not (a.s().startswith("-") and a.s() != "-")]
        if name == "pushd":
            st.stack.append(st.cwd)
        if not ops:
            st.cwd = st.home if name == "cd" else None
        elif ops[0].s() == "-" or re.match(r"^[+-]\d+$", ops[0].s()):
            st.cwd = None
        else:
            st.cwd = expand_path(ops[0], st)
        return
    if name == "popd":
        st.cwd = st.stack.pop() if st.stack else None
        return
    if name in ("export", "declare", "typeset", "local", "readonly"):
        if name == "export" or any(a.s().startswith("-") and "x" in a.s() for a in args):
            for a in args:
                t = a.s()
                if ASSIGN.match(t):
                    k, _, v = t.partition("=")
                    st.env[k] = st.shvars[k] = v
                elif t in st.shvars:
                    st.env[t] = st.shvars[t]
        return
    if name == "unset":
        for a in args:
            st.env.pop(a.s(), None)
            st.shvars.pop(a.s(), None)
        return
    if name == "eval":
        _script(_join(args), run, depth, emit, "eval")
        return
    if name in (".", "source") and args and args[0].s().startswith("<("):
        OPAQUE.append(f"{name} reads a script from a process substitution")
        return
    if name in SHELLS:
        # Options first (-o/-O/+o/+O take a value; `--` or `-` ends them), then the script:
        # the first operand with -c, else a script file, else stdin (-s, or no operand).
        k, cflag, sflag = 0, False, False
        while k < len(args):
            o = args[k].s()
            if o in ("--", "-"):
                k += 1
                break
            if len(o) > 1 and o[0] in "-+":
                if o.startswith("--"):
                    k += 2 if o in ("--rcfile", "--init-file") else 1
                    continue
                cflag |= o[0] == "-" and "c" in o[1:]
                sflag |= o[0] == "-" and "s" in o[1:]
                k += 1 + sum(ch in "oO" for ch in o[1:])
                continue
            break
        if cflag:
            if k < len(args):
                _script(args[k], run, depth, emit, f"{name} -c")
            return
        if k < len(args) and not sflag:
            if args[k].s().startswith("<("):
                OPAQUE.append(f"{name} runs a script from a process substitution")
            return                   # a script file
        if stdin_text:
            parse(stdin_text, run.copy(), depth + 1, emit)
        elif prev and prev[1] in ("|", "|&"):
            fed = _pipe_text(prev)
            if fed is None:
                OPAQUE.append(f"{name} runs a script piped in from a program the reader cannot run")
            else:
                parse(fed, run.copy(), depth + 1, emit)
        return
    if name == "find":
        # -exec runs its command once per found path; `{}` is one of the starting points or a
        # path under it, so it is read as each starting point.
        starts = []
        for a in args:
            if a.s().startswith("-") or a.s() in ("(", "!", ")"):
                break
            starts.append(a)
        starts = starts or [_word(".")]
        k = 0
        while k < len(args):
            if args[k].s() in ("-exec", "-execdir", "-ok", "-okdir"):
                j = k + 1
                while j < len(args) and args[j].s() not in (";", "+", "\\;"):
                    j += 1
                if j > k + 1:
                    sub = []
                    for w in args[k + 1:j]:
                        sub.extend(starts if w.s() == "{}" and args[k].s() in ("-exec", "-ok") else [w])
                    _command(sub, run.copy(), depth + 1, emit, None, None)
                k = j
            k += 1
    emit(argv, run, env)


# ------------------------------------------------------------------------------- git reading
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                  "--super-prefix", "--attr-source"}


def git_view(argv, st: State, env):
    """{cwd, git_dir, configs, env_config, verb, args} for one git argv."""
    cwd, git_dir, configs = st.cwd, env.get("GIT_DIR"), []
    if git_dir is not None:
        w = Word()
        w.text = [git_dir]
        git_dir = expand_path(w, st)
    a = argv[1:]
    i = 0
    while i < len(a):
        t = a[i].s()
        val = None
        if t in GIT_VALUE_OPTS:
            val = a[i + 1] if i + 1 < len(a) else None
            i += 2
        elif t.startswith("--") and "=" in t and t.split("=", 1)[0] in GIT_VALUE_OPTS:
            w = Word()
            w.text = [t.split("=", 1)[1]]
            val, t = w, t.split("=", 1)[0]
            i += 1
        elif t.startswith("-c") and len(t) > 2 and not t.startswith("--"):
            w = Word()
            w.text = [t[2:]]
            val, t = w, "-c"
            i += 1
        elif t.startswith("-"):
            i += 1
            continue
        else:
            break
        if val is None:
            continue
        if t == "-C":
            if val.s() != "":      # git -C "" is a no-op
                cwd = expand_path(val, State(cwd, st.home))
        elif t == "--git-dir":
            git_dir = expand_path(val, State(cwd, st.home))
        elif t == "-c":
            k, _, v = val.s().partition("=")
            configs.append((k.lower(), v))
        elif t == "--config-env":
            k, _, v = val.s().partition("=")
            configs.append((k.lower(), "$" + v))
    env_config = any(k in env for k in ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG"))
    verb = a[i].s() if i < len(a) else ""
    args = [w.s() for w in a[i + 1:]]
    shell_alias = False
    for _ in range(5):                    # an alias defined earlier in this command, expanded
        value = st.aliases.get(verb.lower())
        if value is None:
            break
        if value.startswith("!"):
            shell_alias = True
            OPAQUE.append(f"git {verb}: a shell alias defined in this command")
            break
        words = value.split()
        verb, args = (words[0], words[1:] + args) if words else ("", args)
    return {"cwd": cwd, "git_dir": git_dir, "configs": configs, "env_config": env_config,
            "verb": verb, "args": args, "aliases": st.aliases, "shell_alias": shell_alias}


_CONFIG_READS = re.compile(r"^(--get|--get-all|--get-regexp|--get-urlmatch|--unset|--unset-all|-l|--list"
                           r"|--remove-section|--rename-section|get|unset|list|remove-section|rename-section)$")


def note_alias(gv) -> None:
    """Remember an alias a `git config` in this command defines: a later `git <alias>` in the
    same command runs whatever it was set to (`git config alias.p 'push --force' && git p`)."""
    if gv["verb"] != "config" or any(_CONFIG_READS.match(t) for t in gv["args"]):
        return
    ops = [t for t in gv["args"] if not t.startswith("-") and t != "set"]
    for k, t in enumerate(ops[:-1]):
        m = re.match(r"(?i)^alias\.(.+)$", t)
        if m:
            gv["aliases"][m.group(1).lower()] = ops[k + 1]


def _is_prefix(t: str, full: str, minlen: int) -> bool:
    return len(t) >= minlen and full.startswith(t)


def _clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def _branch_exists(gv, name) -> bool | None:
    """True / False, or None when the repository cannot be known (cd $VAR, cd -). A directory
    that is not a repository answers False: the command would fail there, losing nothing."""
    where = gv["git_dir"] and ["--git-dir", gv["git_dir"]] or (gv["cwd"] and ["-C", gv["cwd"]])
    if not where:
        return None
    try:
        r = subprocess.run(["git", *where, "show-ref", "--verify", "--quiet", "refs/heads/" + name],  # sst3-sec: justified: argv list, no shell; the name is prefixed refs/heads/ and the path is an option value
                           capture_output=True, env=_clean_env())
    except (OSError, ValueError):          # a name git cannot be given (a lone surrogate): unknown
        return None
    return r.returncode == 0


def _current_branch(gv):
    where = gv["git_dir"] and ["--git-dir", gv["git_dir"]] or (gv["cwd"] and ["-C", gv["cwd"]])
    if not where:
        return None
    try:
        r = subprocess.run(["git", *where, "symbolic-ref", "--quiet", "--short", "HEAD"],  # sst3-sec: justified: argv list, no shell; fixed arguments, the path is an option value
                           capture_output=True, text=True, env=_clean_env())
    except (OSError, ValueError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def _local_remote(r: str, configs=()) -> bool:
    """A push target that is a repository on this machine. A remote named on the command line
    (`git -c remote.x.url=. push x`) is judged by the URL given there."""
    for k, v in configs:
        if k in (f"remote.{r.lower()}.url", f"remote.{r.lower()}.pushurl"):
            return _local_remote(v)
    return (r in (".", "./", "..", "~") or r.startswith(("/", "./", "../", "~/", "file://", "$PWD", "${PWD}",
                                                         "$(pwd)", "`pwd`"))
            or (r.endswith((".git", ".git/")) and ":" not in r))


def destructive(gv):
    """DENY reasons for one git invocation (list of (kind, reason))."""
    out = []
    for k, v in gv["configs"]:
        if k.startswith("alias."):
            out.append(("git-config", "git -c alias.… (an inline alias hides the verb)"))
        elif k == "include.path" or (k.startswith("includeif.") and k.endswith(".path")):
            out.append(("git-config", "git -c include.path (an included config file can define an alias)"))
        elif re.fullmatch(r"remote\..+\.mirror", k):
            out.append(("git-config", "git -c remote.<name>.mirror (the push force-updates and deletes every remote ref)"))
        elif re.fullmatch(r"remote\..+\.push", k) and v.startswith("+"):
            out.append(("git-config", "git -c remote.<name>.push=+… (a force refspec)"))
    if gv["env_config"]:
        out.append(("git-config", "git config injected through GIT_CONFIG_* environment (can hide the verb or force a push)"))
    verb, args = gv["verb"], gv["args"]
    if gv["shell_alias"]:
        out.append(("git-config", f"git {verb}: a shell alias defined earlier in this command (it can run anything)"))
    if verb == "push":
        force = dele = 0
        ops, endopts, i = [], False, 0
        while i < len(args):
            t = args[i]
            i += 1
            if not endopts and t.startswith("-") and t != "-":
                if t == "--":
                    endopts = True
                elif t.startswith("--"):
                    base = t.split("=", 1)[0]
                    if base.startswith("--for"):
                        force = 1
                    elif _is_prefix(base, "--mirror", 4):
                        out.append(("push", "git push --mirror (force-updates and deletes every remote ref)"))
                    elif _is_prefix(base, "--prune", 5):
                        out.append(("push", "git push --prune (deletes remote branches)"))
                    elif _is_prefix(base, "--delete", 4):
                        dele = 1
                    elif base in ("--push-option", "--repo", "--receive-pack", "--exec") and "=" not in t:
                        i += 1
                else:
                    for j, ch in enumerate(t[1:]):
                        if ch == "f":
                            force = 1
                        elif ch == "d":
                            dele = 1
                        elif ch == "o":
                            if j == len(t) - 2:
                                i += 1
                            break
                continue
            if t.startswith("+"):
                force = 1
            ops.append(t)
        if force:
            out.append(("push", "git push with a force flag or +refspec (irreversible)"))
        if ops and _local_remote(ops[0], gv["configs"]) and (dele or any(r.startswith(":") for r in ops[1:])):
            out.append(("push", "git push to a local repository deleting a branch (bypasses the merged check)"))
    elif verb in ("fetch", "pull"):    # `pull --force . +a:b` moves b the way fetch does
        force = any(t in ("-f",) or (t.startswith("--") and _is_prefix(t, "--force", 5)) or
                    (t.startswith("-") and not t.startswith("--") and "f" in t[1:]) for t in args)
        for t in args:
            if ":" in t and not t.startswith("-"):
                dst = t.split(":", 1)[1]
                if dst and (dst.startswith("refs/heads/") or not dst.startswith("refs/")) and (t.startswith("+") or force):
                    out.append(("fetch", "git fetch +<src>:<local branch> (force-moves a local branch; its commits can be lost)"))
                    break
    elif verb == "reset":
        if any(_is_prefix(t, "--hard", 4) for t in args):
            out.append(("reset", "git reset --hard (uncommitted-work loss)"))
    elif verb == "update-ref":
        ops, k = [], 0
        while k < len(args):              # -m <reason> takes a value; it is not the ref
            if args[k] == "-m":
                k += 2
                continue
            if not args[k].startswith("-"):
                ops.append(args[k])
            k += 1
        if any(t == "--stdin" or _is_prefix(t, "--delete", 3) or re.fullmatch(r"-[a-z]*d[a-z]*", t) for t in args):
            out.append(("update-ref", "git update-ref deleting a ref (bypasses the merged check)"))
        elif ops and (ops[0] == "HEAD" or (ops[0].startswith("refs/heads/")
                                           and _branch_exists(gv, ops[0][len("refs/heads/"):]) is not False)):
            out.append(("update-ref", "git update-ref moving an existing branch (its commits can be lost)"))
    elif verb in ("filter-repo", "filter-branch"):
        out.append(("rewrite", f"git {verb} (history rewrite, irreversible to public mirrors)"))
    elif verb == "branch":
        frc = dele = mov = cop = 0
        names = []
        for t in args:
            if t.startswith("--"):
                b = t.split("=", 1)[0]
                if _is_prefix(b, "--force", 6):
                    frc = 1
                elif _is_prefix(b, "--delete", 5):
                    dele = 1
                elif _is_prefix(b, "--move", 4):
                    mov = 1
                elif _is_prefix(b, "--copy", 4):
                    cop = 1
            elif t.startswith("-") and t != "-":
                for ch in t[1:]:
                    frc |= ch in "fDMC"
                    dele |= ch in "dD"
                    mov |= ch in "mM"
                    cop |= ch in "cC"
            else:
                names.append(t)
        if dele and frc:
            out.append(("branch-force-delete", "git branch force-delete"))
        elif (mov or cop) and frc:
            target = names[-1] if names else None
            src = names[0] if len(names) >= 2 else _current_branch(gv)
            exists = _branch_exists(gv, target) if target else None
            if exists is not False and target != src:
                out.append(("branch", "git branch -M/-C onto an existing branch (overwrites it; its commits can be lost)"))
        elif frc and not dele:
            out.append(("branch", "git branch --force (moves an existing branch; its commits can be lost)"))
    elif verb in ("checkout", "switch"):
        # -B / -C in any spelling: alone, stuck (-Bmain), in a cluster (-fB), and switch's
        # --force-create[=name] or an abbreviation of it.
        target, start, k, rest = None, None, 0, []
        letter = "B" if verb == "checkout" else "C"
        while k < len(args) and args[k] != "--":
            t = args[k]
            if verb == "switch" and t.startswith("--") and _is_prefix(t.split("=", 1)[0], "--force-create", 9):
                target, rest = (t.split("=", 1)[1], args[k + 1:]) if "=" in t else (
                    args[k + 1] if k + 1 < len(args) else None, args[k + 2:])
                break
            if t.startswith("-") and not t.startswith("--") and letter in t[1:]:
                pos = t.index(letter, 1)
                target, rest = (t[pos + 1:], args[k + 1:]) if pos < len(t) - 1 else (
                    args[k + 1] if k + 1 < len(args) else None, args[k + 2:])
                break
            k += 1
        rest = [x for x in rest if not x.startswith("-")]
        start = rest[0] if rest else None
        if target:
            exists = _branch_exists(gv, target)
            cur = _current_branch(gv)
            if exists is not False and (start is not None or target != cur):
                out.append((verb, f"git {verb} {'-B' if verb == 'checkout' else '-C'} onto an existing branch (resets it; its commits can be lost)"))
    return out


RM_OPERAND = re.compile(r"^(/($|[^.])|~($|/)|\$HOME($|/)|\$\{HOME\}($|/))")


def _rm_operand(t: str) -> bool:
    """An absolute path is judged as the kernel resolves it: `/./home` and `//home` are /home."""
    return bool(RM_OPERAND.match(os.path.normpath(t) if t.startswith("/") else t))


def rm_destructive(args):
    rec = frc = 0
    ops, endopts = [], False
    for t in args:
        if not endopts and t.startswith("-") and t != "-":
            if t == "--":
                endopts = True
            elif t.startswith("--"):
                if _is_prefix(t, "--recursive", 3):
                    rec = 1
                elif _is_prefix(t, "--force", 3):
                    frc = 1
                elif _is_prefix(t, "--no-preserve-root", 4):
                    rec = frc = 1
            else:
                rec |= any(ch in "rR" for ch in t[1:])
                frc |= "f" in t[1:]
            continue
        ops.append(t)
    if rec and frc and any(_rm_operand(t) for t in ops):
        return [("rm", "rm -rf / (filesystem destruction)")]
    return []


def main(argv):
    if len(argv) < 2 or argv[1] not in ("commands", "git", "destructive"):
        print(__doc__.split("USAGE", 1)[1].split("EXIT", 1)[0], file=sys.stderr)
        return 2
    mode = argv[1]
    cwd = None
    if "--cwd" in argv:
        k = argv.index("--cwd")
        cwd = argv[k + 1] if k + 1 < len(argv) and argv[k + 1] else None
    cwd = os.path.normpath(cwd) if cwd and os.path.isabs(cwd) else (os.getcwd() if cwd is None else None)
    try:
        text = sys.stdin.buffer.read().decode("utf-8", "replace")
    except OSError as exc:
        print(f"_lib-shellcmd: could not read the command: {exc}", file=sys.stderr)
        return 3
    st = State(cwd, os.path.expanduser("~"))
    exported = {k: v for k, v in os.environ.items() if k in ("GIT_DIR",)}
    st.env.update(exported)
    records = []
    OPAQUE.clear()

    def emit(av, s, env):
        name = os.path.basename(av[0].s())
        gv = None
        if name == "git":                 # every mode: an alias it defines changes later commands
            gv = git_view(av, s, env)
            note_alias(gv)
        if mode == "commands":
            records.append({"argv": [w.s() for w in av], "cwd": s.cwd, "env": env})
        elif gv is not None:
            if mode == "git":
                records.append({"tool": "git", "cwd": gv["cwd"], "git_dir": gv["git_dir"],
                                "verb": gv["verb"], "args": gv["args"]})
            else:
                for kind, reason in destructive(gv):
                    records.append({"kind": kind, "reason": reason})
        elif name == "gh" and mode == "git":
            a = [w.s() for w in av[1:]]
            if a[:2] == ["pr", "checkout"] or a[:1] == ["co"]:
                records.append({"tool": "gh", "cwd": s.cwd, "git_dir": None, "verb": "checkout", "args": a[2:]})
        elif name == "rm" and mode == "destructive":
            for kind, reason in rm_destructive([w.s() for w in av[1:]]):
                records.append({"kind": kind, "reason": reason})

    # Any failure is said, never a silent pass: the callers fall back to their whole-text check
    # (#577 Stage 5 fix review 2: a lone surrogate from $'\ud800' raised here, and the
    # destructive guard's DENY became an advisory). ensure_ascii keeps such text printable.
    try:
        parse(text, st, 0, emit)
    except Exception as exc:  # noqa: BLE001 — every failure is reported as opaque, exit 3
        print(json.dumps({"opaque": f"the reader failed ({type(exc).__name__})"}))
        return 3
    for r in records + [{"opaque": why} for why in dict.fromkeys(OPAQUE)]:
        print(json.dumps(r))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))  # sst3-sec: justified: the mode word and --cwd, both validated in main()
