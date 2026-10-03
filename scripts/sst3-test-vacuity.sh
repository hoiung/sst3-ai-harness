#!/usr/bin/env bash
# sst3-test-vacuity.sh — mechanical pre-Ralph vacuity sweep (#567 Phase 4).
#
# Detects assertions that CANNOT fail and allowlist entries whose reason covers
# more occurrences than it plausibly describes — the two defect classes measured
# on Issue #3 that cost LLM reviewer rounds to find by reading.
# Runs BEFORE Ralph Tier 1 dispatch (Leader.md Stage-4 step 6.5); its findings
# are fixed before any reviewer is spawned.
#
# Usage:   sst3-test-vacuity.sh [--count-in <doc> [--threshold N]] [--paths-from f] [file.py ...]
# Default: no positional files -> scans tests/**/*.py + test_*.py under CWD,
#          EXCLUDING any path under a `test-fixtures/` directory (frozen
#          known-answer corpora are intentionally vacuous positive controls;
#          pre-#567-T3-E3 the bare invocation scanned them and the gate was
#          red by default in its own repo). Explicit paths are never filtered.
# Detects (AST-based, per file):
#   assert-literal      assert of a truthy constant or non-empty
#                       tuple/list/dict/set literal (incl. the classic
#                       `assert (cond, "msg")` and a bare/implicitly-continued
#                       string after `assert`).
#   assert-or-true      assert whose test contains `... or True` (a truthy
#                       constant operand in an `or`).
#   assert-folds-local-literal
#                       an assert whose operands are LOCALS bound exactly once
#                       to a literal earlier in the SAME function, so the test
#                       folds to a truthy constant. `bad = []` ... `assert not
#                       bad`, and `num = "x"` ... `assert num == "x"`, are both
#                       unfalsifiable but neither is a constant AT the assert
#                       node, so the syntactic detectors above cannot see them.
#                       A name is only treated as constant when nothing can
#                       change it: never rebound, never a parameter, never a
#                       loop/walrus/comprehension/with target, and NEVER the
#                       receiver of a method call — `offenders = []` followed
#                       by `offenders.append(x)` is the accumulator idiom every
#                       enumerator gate uses, and folding it would report all
#                       of them. Measured on a 45-file two-repo corpus: 0
#                       findings with the receiver rule, 21 (~all accumulators)
#                       without it. Nothing is executed; only literals,
#                       substituted locals and a closed set of pure operators
#                       are folded.
#   assert-self-compare an assertion whose expected value is computed by the
#                       SAME expression it checks, under an UNFALSIFIABLE
#                       operator only (`==`, `<=`, `>=`, `is`). An
#                       always-FALSE self-compare (`!=`, `<`, `>`, `is not`)
#                       is deliberately NOT claimed: it reddens the suite
#                       itself, so it is not a silent-pass hazard (#567 T3
#                       S6a — flagging it under "cannot fail" was a
#                       mislabel; pinned by test-vacuity-detector-precision).
#   allowlist-overreach with --count-in <doc>: for each entry of an
#                       allowlist-shaped dict ({str: reason-str} assigned to a
#                       name matching ALLOW|EXEMPT|UNBOUND|REASON|WAIV|SKIP),
#                       count standalone occurrences of the key in <doc>;
#                       >= threshold (default 10) = the reason cannot plausibly
#                       describe them all (measured case: "4": "ordinals and
#                       list numbering" — reconciled to 33 occurrences, 24 of
#                       them Model=4, per the #567 dogfood reconciliation; the
#                       frozen allowlist fixture replicates the SHAPE with a
#                       constructed 32/20, not the exact figures — #567 T3 F9).
#                       Structured `word=KEY` hits are reported separately as
#                       the strongest overreach signal.
# NOT enumerated (blind BY CONSTRUCTION — mutation-verification.md sweep gate 2:
# a scanner declares what it cannot produce beside what it does; gate 5: the
# blindness is ASSERTED by the frozen test-vacuity-blindspots fixture, which
# expects exit 0 / 0 findings on exactly these forms and DRIFTS if a widening
# makes the scanner sensitive without updating this disclosure):
#   unittest-Call forms   self.assertTrue(True) / self.assertEqual(1, 1) — Call
#                         nodes, never ast.Assert; the scanner walks ast.Assert
#                         only.
#   pytest.raises no-op   `with pytest.raises(E): pass` — no assert node at all.
#   constant-foldable     `assert len([]) == 0` — sides equal after folding but
#                         not AST-identical, so assert-self-compare (ast.dump
#                         equality) cannot see it.
# These classes remain reviewer work (Ralph break-one-claim angle), not this
# script's. Found by #567 Ralph Tier-2 break-one-claim; disclosed per canon.
# UNSUPPORTED LANGUAGE (c4:T16, #577): TypeScript / JavaScript test files
#   (vitest, jest: .ts .tsx .mts .cts .js .jsx .mjs .cjs) are named as
#   unsupported, per file, instead of crashing the Python parser. So are the
#   *.test.* / *.spec.* JS/TS files a bare run finds, with or without Python
#   tests beside them (node_modules excluded). The run exits 2 (could-not-look) unless a Python
#   file it did scan has findings (exit 1), and prints the manual sweep for
#   the vitest forms: expect(<literal>), a bare .toThrow(), expect(x) compared
#   with x itself, and an it()/test() block with no expect.
#   Any other explicitly passed file whose extension is not .py/.pyw (a shell
#   or PowerShell harness among the diff's test files) is named the same way,
#   as `non-Python (.<ext>)`, and the files after it are still scanned. Before
#   #577 Ralph r2 prep it reached the Python parser, printed ENGINE CRASHED and
#   stopped the run. A file with no extension is still parsed as Python.
# Output:  STDOUT — NDJSON, one object per finding: {file, line, kind, detail}
#          STDERR — always emits the sentinel:
#                   "sst3-test-vacuity: scanned <N> file(s), <M> finding(s)"
# Exit:    0 = ran clean over >=1 scanned file, 1 = findings (this wrapper is a
#          GATE, not a triage reporter — AC 4.1/4.3 wire it pre-Tier-1, so
#          findings block), 2 = could-not-look (engine crashed / unparseable
#          file / UNSUPPORTED LANGUAGE (TypeScript/JavaScript tests, above) /
#          USAGE ERROR on bad arguments / NOTHING SCANNED — a run that
#          scanned zero files proved nothing and must never read as clean;
#          #567 Ralph T3 F2+F4, mirrors sst3-check --strict semantics),
#          127 = engine missing.
set -uo pipefail
export LC_ALL=C

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"

__PATHS_FROM_SST3=""
__ARGS_SST3=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from)
            # A missing operand must fail LOUD: the old `${2:-}` set the
            # filter to empty and broke out of parsing, so the run
            # reported clean instead of erroring (#567 T3 S6c).
            if [[ $# -lt 2 ]]; then
                echo "sst3-test-vacuity: USAGE ERROR: --paths-from requires a file argument" >&2
                exit 2
            fi
            __PATHS_FROM_SST3="$2"; shift 2;;
        *) __ARGS_SST3+=("$1"); shift;;
    esac
done
set -- "${__ARGS_SST3[@]+"${__ARGS_SST3[@]}"}"
activate_paths_from_filter "$__PATHS_FROM_SST3"

if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

python3 - "$@" <<'PYEOF'
import ast, glob, json, os, re, sys

# c4:T16 (#577): test files this Python-AST gate cannot read, named per file.
UNSUPPORTED_LANG = {
    ".ts": "TypeScript", ".tsx": "TypeScript", ".mts": "TypeScript", ".cts": "TypeScript",
    ".js": "JavaScript", ".jsx": "JavaScript", ".mjs": "JavaScript", ".cjs": "JavaScript",
}
JS_TEST_GLOBS = ("**/*.test.*", "**/*.spec.*")
PYTHON_EXT = {".py", ".pyw"}


def unsupported_lang(path):
    """The language this gate cannot read, else None. JS/TS by name; any other
    extension that is not Python (a shell or PowerShell harness passed as one of
    the diff's test files) by extension, so it is named instead of reaching the
    Python parser, which reported it as an engine crash and stopped the run
    before the files after it were scanned (#577 Ralph r2 prep). A file with no
    extension is still tried as Python."""
    ext = os.path.splitext(path)[1].lower()
    if ext in UNSUPPORTED_LANG:
        return UNSUPPORTED_LANG[ext]
    if ext and ext not in PYTHON_EXT:
        return f"non-Python ({ext})"
    return None
MANUAL_SWEEP = (
    "sst3-test-vacuity: this gate parses Python only, so it proved nothing about the file(s) "
    "above. Manual sweep for vitest/jest: grep each for expect(<literal>), a bare .toThrow(), "
    "expect(x) compared with x itself, and an it()/test() block with no expect; record the "
    "result as could-not-look plus the sweep, never as clean."
)
OTHER_LANG_NOTE = (
    "sst3-test-vacuity: this gate parses Python only, so it proved nothing about the "
    "non-Python file(s) above. Prove each another way (a shell test by its mutation "
    "table) and record it as could-not-look, never as clean."
)

def emit(file, line, kind, detail):
    print(json.dumps({"file": file, "line": line, "kind": kind, "detail": detail}))

ALLOWLIST_NAME = re.compile(r"ALLOW|EXEMPT|UNBOUND|REASON|WAIV|SKIP", re.I)

def is_truthy_const(node):
    return isinstance(node, ast.Constant) and bool(node.value) and node.value is not False

LITERAL_NODES = (ast.Constant, ast.List, ast.Dict, ast.Set, ast.Tuple)

class _NoValue:
    def __repr__(self): return "<no-value>"
    def __eq__(self, other): return other is self
    def __hash__(self): return id(self)

NO_VALUE = _NoValue()

def const_value(node, env):
    """The value of `node`, or NO_VALUE when it is not statically known.

    Nothing is executed: literals, substituted locals, and a closed operator
    set only. Anything else returns NO_VALUE and the assert is not claimed.
    """
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        return const_value(env[node.id], env) if node.id in env else NO_VALUE
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        vals = [const_value(e, env) for e in node.elts]
        if any(v is NO_VALUE for v in vals):
            return NO_VALUE
        if isinstance(node, ast.List):
            return list(vals)
        return tuple(vals) if isinstance(node, ast.Tuple) else set(vals)
    if isinstance(node, ast.Dict):
        return {} if not node.keys else NO_VALUE
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        v = const_value(node.operand, env)
        return NO_VALUE if v is NO_VALUE else (not v)
    if isinstance(node, ast.BoolOp):
        vals = [const_value(v, env) for v in node.values]
        if any(v is NO_VALUE for v in vals):
            return NO_VALUE
        return all(vals) if isinstance(node.op, ast.And) else any(vals)
    if isinstance(node, ast.Compare) and len(node.ops) == 1:
        left = const_value(node.left, env)
        right = const_value(node.comparators[0], env)
        if left is NO_VALUE or right is NO_VALUE:
            return NO_VALUE
        op = node.ops[0]
        try:
            if isinstance(op, ast.Eq):    return left == right
            if isinstance(op, ast.NotEq): return left != right
            if isinstance(op, ast.Is):    return left is right
            if isinstance(op, ast.IsNot): return left is not right
            if isinstance(op, ast.In):    return left in right
            if isinstance(op, ast.NotIn): return left not in right
        except TypeError:
            return NO_VALUE
    return NO_VALUE

def literal_env(fn):
    """Names in `fn` bound exactly once to a literal and unchangeable after."""
    assigned, env = {}, {}
    args = fn.args
    for a in (args.args + args.kwonlyargs + getattr(args, "posonlyargs", [])):
        assigned[a.arg] = assigned.get(a.arg, 0) + 2      # a parameter varies
    for node in ast.walk(fn):
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, (ast.AugAssign, ast.AnnAssign, ast.For,
                               ast.NamedExpr, ast.comprehension)):
            targets = [node.target]
        elif isinstance(node, ast.withitem) and node.optional_vars:
            targets = [node.optional_vars]
        for t in targets:
            for nm in ast.walk(t):
                if isinstance(nm, ast.Name):
                    assigned[nm.id] = assigned.get(nm.id, 0) + 1
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and isinstance(node.value, LITERAL_NODES)):
            env[node.targets[0].id] = node.value
    # `x.append(...)` never rebinds `x` but does change it. Without this the
    # accumulator idiom every enumerator gate uses reads as a constant.
    mutated = {n.func.value.id for n in ast.walk(fn)
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
               and isinstance(n.func.value, ast.Name)}
    return {k: v for k, v in env.items()
            if assigned.get(k, 0) == 1 and k not in mutated}

def scan_folded_asserts(path, tree):
    n = 0
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        env = literal_env(fn)
        if not env:
            continue
        for node in ast.walk(fn):
            if not isinstance(node, ast.Assert):
                continue
            names = {x.id for x in ast.walk(node.test) if isinstance(x, ast.Name)}
            # Only claim it when a SUBSTITUTED name is what makes it fold;
            # otherwise this restates assert-literal on the same line.
            if not (names & set(env)):
                continue
            value = const_value(node.test, env)
            if value is not NO_VALUE and bool(value):
                via = ", ".join(sorted(names & set(env)))
                emit(path, node.lineno, "assert-folds-local-literal",
                     f"operand(s) {via} are local literals, so this assertion "
                     f"folds to a constant and cannot fail")
                n += 1
    return n

def scan_asserts(path, tree):
    n = 0
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assert):
            continue
        t = node.test
        if isinstance(t, ast.Constant) and bool(t.value):
            kind = "assert-literal"
            what = "string literal" if isinstance(t.value, str) else repr(t.value)
            emit(path, t.lineno, kind, f"assert of truthy constant ({what}) cannot fail")
            n += 1
        elif isinstance(t, (ast.Tuple, ast.List)) and t.elts:
            emit(path, t.lineno, "assert-literal",
                 "assert of a non-empty tuple/list literal is always true (classic `assert (cond, \"msg\")`)")
            n += 1
        elif isinstance(t, ast.Dict) and t.keys:
            emit(path, t.lineno, "assert-literal",
                 "assert of a non-empty dict literal is always true")
            n += 1
        elif isinstance(t, ast.Set) and t.elts:
            emit(path, t.lineno, "assert-literal",
                 "assert of a non-empty set literal is always true")
            n += 1
        if isinstance(t, ast.BoolOp) and isinstance(t.op, ast.Or) and any(is_truthy_const(v) for v in t.values):
            emit(path, t.lineno, "assert-or-true", "`or <truthy constant>` makes this assertion unfalsifiable")
            n += 1
        if isinstance(t, ast.Compare):
            # Only UNFALSIFIABLE operators are vacuity findings (#567 T3
            # S6a): `x == x` / `x <= x` / `x >= x` / `x is x` cannot fail;
            # `x != x` / `x < x` / `x > x` / `x is not x` ALWAYS fail — the
            # suite itself reddens on them, so they are not a silent-pass
            # hazard and this gate deliberately does not claim them.
            left = ast.dump(t.left)
            for op, cmp_ in zip(t.ops, t.comparators):
                if ast.dump(cmp_) == left and isinstance(
                    op, (ast.Eq, ast.LtE, ast.GtE, ast.Is)
                ):
                    emit(path, t.lineno, "assert-self-compare",
                         "expected value is computed by the same expression it checks")
                    n += 1
                    break
    return n

def allowlist_dicts(tree):
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Dict):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
            if not any(ALLOWLIST_NAME.search(nm) for nm in names):
                continue
            for k, v in zip(node.value.keys, node.value.values):
                if isinstance(k, ast.Constant) and isinstance(k.value, str) \
                   and isinstance(v, ast.Constant) and isinstance(v.value, str):
                    yield names[0], k.value, v.value, k.lineno

def scan_allowlist(path, tree, doc_path, doc_text, threshold):
    n = 0
    for dname, key, reason, lineno in allowlist_dicts(tree):
        esc = re.escape(key)
        # `=` is excluded from the standalone lookbehind so a `word=KEY` hit is
        # counted ONCE, in the structured bucket — double-counting would inflate
        # the total and misreport the measured shape.
        standalone = re.findall(rf"(?<![\w.=]){esc}(?![\w.])", doc_text)
        structured = re.findall(rf"\w+={esc}(?![\w.])", doc_text)
        total = len(standalone) + len(structured)
        if total >= threshold:
            emit(path, lineno, "allowlist-overreach",
                 f"{dname}[{key!r}] reason ({reason!r}) covers {total} occurrence(s) in {doc_path} "
                 f"({len(structured)} in structured word={key} contexts) — one reason cannot "
                 f"plausibly describe them all; scope the exemption per occurrence class")
            n += 1
    return n

args = sys.argv[1:]
def usage_error(msg):
    # Unusable arguments are a could-not-look, not a findings state: exit 2,
    # never the findings code 1 and never a raw traceback (#567 Ralph T3 F4).
    print(f"sst3-test-vacuity: USAGE ERROR: {msg}", file=sys.stderr)
    sys.exit(2)

count_in = None
threshold = 10
files = []
i = 0
while i < len(args):
    if args[i] == "--count-in":
        if i + 1 >= len(args):
            usage_error("--count-in requires a <doc> argument")
        count_in = args[i + 1]; i += 2
    elif args[i] == "--threshold":
        if i + 1 >= len(args):
            usage_error("--threshold requires an integer argument")
        try:
            threshold = int(args[i + 1])
        except ValueError:
            usage_error(f"--threshold expects an integer, got {args[i + 1]!r}")
        if threshold < 1:
            usage_error(f"--threshold must be >= 1, got {threshold}")
        i += 2
    else:
        files.append(args[i]); i += 1
explicit = bool(files)
if not files:
    files = sorted(set(glob.glob("tests/**/*.py", recursive=True) + glob.glob("**/test_*.py", recursive=True)))
    # Discovery-mode exclusion (#567 T3 E3): a `test-fixtures/` directory
    # holds frozen known-answer corpora that are INTENTIONALLY vacuous
    # (the gate's own positive controls), so a bare repo-root invocation
    # scanned its own fixtures and exited 1 on a clean tree — the
    # documented Leader.md step-6.5 gate was red BY DEFAULT in dotfiles.
    # Explicitly-passed paths are never filtered (the self-test drives
    # the fixtures by explicit path and must keep doing so).
    files = [f for f in files if "test-fixtures/" not in f.replace("\\", "/")]
    # vitest/jest tests are named whether or not Python tests sit beside them
    # (c4:T16). Collecting them only in a Python-less tree left a mixed tree's
    # JS/TS tests unnamed and the run clean (#577 Ralph r1).
    js = set()
    for pattern in JS_TEST_GLOBS:
        js.update(glob.glob(pattern, recursive=True))
    files += sorted(
        f for f in js
        if os.path.splitext(f)[1].lower() in UNSUPPORTED_LANG
        and "node_modules/" not in f.replace("\\", "/")
        and "test-fixtures/" not in f.replace("\\", "/")
    )

doc_text = None
if count_in is not None:
    try:
        with open(count_in, encoding="utf-8", errors="replace") as fh:
            doc_text = fh.read()
    except OSError as e:
        usage_error(f"--count-in doc unreadable: {e}")

scanned = findings = 0
unsupported = []
for path in files:
    lang = unsupported_lang(path)
    if lang:
        unsupported.append((path, lang))
        continue
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        tree = ast.parse(src, filename=path)
    except (OSError, SyntaxError) as e:
        # Could-not-look is loud, never a silent skip (Fail Fast / AP #7).
        print(f"sst3-test-vacuity: ENGINE CRASHED parsing {path}: {e}", file=sys.stderr)
        sys.exit(2)
    scanned += 1
    findings += scan_asserts(path, tree)
    findings += scan_folded_asserts(path, tree)
    if doc_text is not None:
        findings += scan_allowlist(path, tree, count_in, doc_text, threshold)

print(f"sst3-test-vacuity: scanned {scanned} file(s), {findings} finding(s)", file=sys.stderr)
if unsupported:
    for path, lang in unsupported:
        kind = "vitest/jest test file" if lang in UNSUPPORTED_LANG.values() else "test file"
        print(f"sst3-test-vacuity: UNSUPPORTED LANGUAGE {lang} ({kind}, not scanned): {path}",
              file=sys.stderr)
    if any(lang in UNSUPPORTED_LANG.values() for _, lang in unsupported):
        print(MANUAL_SWEEP, file=sys.stderr)
    if any(lang not in UNSUPPORTED_LANG.values() for _, lang in unsupported):
        print(OTHER_LANG_NOTE, file=sys.stderr)
    # Findings in the Python files that were scanned still block first.
    sys.exit(1 if findings else 2)
if scanned == 0:
    # A run that scanned nothing proved nothing — exit 0 here would be the
    # vacuous PASS this very gate exists to reject (#567 Ralph T3 F2: a vacuous
    # file outside the discovery glob left 'scanned 0' at exit 0, byte-for-byte
    # a clean gate). Could-not-look exits 2, mirroring sst3-check --strict.
    mode = "explicit paths matched no scannable file" if explicit else \
        "bare discovery found no tests/**/*.py or **/test_*.py under CWD"
    print(
        f"sst3-test-vacuity: NOTHING SCANNED ({mode}) — nothing proven. "
        "Pass the diff's test files explicitly, or record skip-clean "
        "(no Python test surface in diff) instead of citing this run.",
        file=sys.stderr,
    )
    sys.exit(2)
sys.exit(1 if findings else 0)
PYEOF
