#!/usr/bin/env python3
"""
Public Repo Secret Detection Script

Scans codebase for secrets, business identifiers, and private paths
that must never be committed to public repositories.

Exit codes:
  0: looked, and found no violation -- or declined to look because this is not a
     public repo, which is announced on stdout as [SKIP] rather than passing in
     silence (a silent 0 is indistinguishable from a completed clean scan)
  1: looked, and found violations (FAIL)
  2: could NOT look, so the result is not evidence: --require-public was passed
     but the .public-repo marker is absent, or a whole-repo scan collected zero
     scannable files. Distinct from 0 on purpose -- "no violations" and "no
     evidence" are opposite outcomes an exit-code check alone cannot tell apart
     (hoiboy-uk#56; taxonomy in that repo's scripts/gate_coverage.py).

Usage:
  python check-public-repo-secrets.py <path>
  python check-public-repo-secrets.py <path> --staged-only
  python check-public-repo-secrets.py <path> --allowlist .secret-allowlist
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Set, Tuple

try:
    from sst3_utils import (
        SST3UtilError,
        fix_windows_console,
        get_repo_root,
        log_event,
        should_ignore_path,
    )
    fix_windows_console()
except ImportError:
    # Standalone mode — vendored copy without sst3_utils
    import io
    import json
    from datetime import datetime, timezone

    class SST3UtilError(RuntimeError):
        pass

    def fix_windows_console() -> None:
        if sys.platform == "win32":
            sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
            sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

    fix_windows_console()

    def should_ignore_path(file_path: Path, ignore_patterns, allowed_files=()) -> bool:
        file_str = str(file_path).replace("\\", "/")
        parts = file_path.parts
        for pattern in ignore_patterns:
            pattern_norm = pattern.replace("\\", "/")
            if Path(file_str).match(pattern_norm):
                return True
            clean = pattern_norm.strip("*/").strip("/")
            if clean in parts:
                return True
        return False

    def get_repo_root() -> Path:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return Path(result.stdout.strip())

    def log_event(script: str, event: str, level: str = "info", **fields) -> None:
        try:
            log_dir = Path.home() / ".cache" / "sst3"
            log_dir.mkdir(parents=True, exist_ok=True)
            record = json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "script": script, "event": event, "level": level,
                "fields": fields,
            }, ensure_ascii=True)
            with open(log_dir / "sst3-events.jsonl", "a") as f:
                f.write(record + "\n")
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Finding data structure
# ---------------------------------------------------------------------------

class Finding(NamedTuple):
    line_num: int
    line: str
    category: str
    message: str
    fix: str


# ---------------------------------------------------------------------------
# Pattern definitions — compiled once at module load
# ---------------------------------------------------------------------------

PLATFORM_TOKEN_PATTERNS: List[Dict] = [
    {
        "pattern": re.compile(r"ghp_[A-Za-z0-9]{36}"),
        "message": "GitHub Personal Access Token (classic)",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"github_pat_[A-Za-z0-9_]{82}"),
        "message": "GitHub Fine-Grained Personal Access Token",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"gh[ours]_[A-Za-z0-9]{36}"),
        "message": "GitHub OAuth/App Token",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(
            r"(?<![A-Z0-9])(?:AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)"
            r"[A-Z0-9]{16}(?![A-Z0-9])"
        ),
        "message": "AWS Access Key ID",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"AIza[0-9A-Za-z\-_]{35}"),
        "message": "GCP API Key",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"sk_live_[0-9A-Za-z]{24,}"),
        "message": "Stripe Live Secret Key",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"sk_test_[0-9A-Za-z]{24,}"),
        "message": "Stripe Test Secret Key",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"whsec_[A-Za-z0-9]{32,}"),
        "message": "Stripe Webhook Secret",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
        "message": "JWT Token",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        # Telegram Bot API token: numeric bot ID, a colon, then a 35-character
        # secret that BotFather issues starting `AA` (groupwarden#1). Whoever
        # holds it can read and post as the bot in every chat it is in.
        "pattern": re.compile(r"(?<![0-9])[0-9]{8,10}:AA[A-Za-z0-9_-]{33}(?![A-Za-z0-9_-])"),
        "message": "Telegram Bot API token",
        "fix": "Move to the bot's secrets file (gitignored) and read it at runtime",
    },
]

PRIVATE_KEY_PATTERNS: List[Dict] = [
    {
        "pattern": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
        "message": "Private key header detected",
        "fix": "Never commit private keys. Use environment variable or secrets manager.",
    },
    {
        "pattern": re.compile(r"-----BEGIN PGP PRIVATE KEY BLOCK-----"),
        "message": "PGP private key block detected",
        "fix": "Never commit private keys. Use environment variable or secrets manager.",
    },
    {
        # age (filippo.io/age) identity: Bech32, upper case, 58 data characters
        # after the `1` separator (groupwarden#1 encrypts its backups with age).
        "pattern": re.compile(r"AGE-SECRET-KEY-1[QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{58}"),
        "message": "age secret key detected",
        "fix": "Never commit private keys. Keep the age identity off the repo and off the host it protects.",
    },
]

GENERIC_SECRET_PATTERNS: List[Dict] = [
    {
        # Quote-flanking on the keyword closes the JSON-object recall hole
        # (`"password":"dragon"`) per dotfiles#494 Defect 3 — the optional
        # `['"]?` either side of the keyword preserves bare-keyword forms
        # (`password = ...`) while also matching JSON quoted-key forms.
        "pattern": re.compile(
            r"(?i)['\"]?(?:password|passwd|secret|token|api_?key|auth_?key|credential|seller_id|account_id)['\"]?"
            r"\s*[=:]\s*['\"]?[^\s'\"]{4,}"
        ),
        "message": "Generic secret assignment",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    {
        "pattern": re.compile(r"(?i)(?:DB|DATABASE)_(?:PASSWORD|PASS|PWD|SECRET)\s*=\s*.+"),
        "message": "Database password assignment",
        "fix": "Move to .env (gitignored) and reference via environment variable",
    },
    # URI schemes are case-insensitive (RFC 3986), so the scheme group
    # carries a scoped (?i:) -- credentials stay case-exact (Issue #561).
    {
        "pattern": re.compile(r"(?i:postgres(?:ql)?)://[^:]+:[^@]{3,}@[^\s'\"]+"),
        "message": "PostgreSQL connection string with embedded credentials",
        "fix": "Move credentials to .env and construct connection string at runtime",
    },
    {
        "pattern": re.compile(r"(?i:mongodb(?:\+srv)?)://[^:]+:[^@]{3,}@[^\s'\"]+"),
        "message": "MongoDB connection string with embedded credentials",
        "fix": "Move credentials to .env and construct connection string at runtime",
    },
    {
        "pattern": re.compile(r"(?i:redis(?:s)?)://[^:]*:[^@]{3,}@[^\s'\"]+"),
        "message": "Redis connection string with embedded credentials",
        "fix": "Move credentials to .env and construct connection string at runtime",
    },
    {
        "pattern": re.compile(r"(?i:mysql)://[^:]+:[^@]{3,}@[^\s'\"]+"),
        "message": "MySQL connection string with embedded credentials",
        "fix": "Move credentials to .env and construct connection string at runtime",
    },
]

# A Windows path reaches a repo in three separator styles and all three must be
# caught: `\` (copied out of Explorer, the form an operator actually pastes),
# `\\` (the same string after a JSON/Python escape), and `/`. These patterns used
# to match only the escaped and forward-slash forms, so the raw single-backslash
# paste passed the scanner clean on a public repo (Issue #559).
# Windows and cloud-sync filesystems are case-insensitive, so every case spelling
# is the same private path -- these patterns compile with IGNORECASE (Issue #561).
_SEP = r"[\\/]{1,2}"


def _private_path(pattern: str, message: str) -> Dict:
    return {
        "pattern": re.compile(pattern, re.IGNORECASE),
        "message": message,
        "fix": "Use environment variable or relative path",
    }


PRIVATE_PATH_PATTERNS: List[Dict] = [
    _private_path(r"/mnt/[a-z]/Users/", "WSL Windows user path detected"),
    # Any drive letter, not just C: -- a second drive is still the operator's box.
    _private_path(rf"[A-Za-z]:{_SEP}Users{_SEP}", "Windows user path detected"),
    _private_path(rf"My Drive{_SEP}", "Google Drive path detected"),
    _private_path(rf"Google Drive{_SEP}", "Google Drive path detected"),
    _private_path(rf"OneDrive{_SEP}", "OneDrive path detected"),
]

# ---------------------------------------------------------------------------
# PII patterns (hoiboy-uk#56 escalation 2)
#
# Every category above this one is CREDENTIAL-shaped: a token prefix, a PEM
# header, a `keyword=value` assignment, a filesystem path. Personal data was
# never in the threat model, and the omission was not theoretical. On this repo
# the operator's own email local-part was committed into two source comments,
# and a full-tree `--require-public` scan of all 327 files printed
# `PASS: No secrets detected`. A red-team sweep then injected a synthetic
# address, phone number and postal address into seven registers (JS comment,
# Python docstring, Markdown prose, JS string literal, TOML value, YAML value,
# doc prose) across both scan modes: 14 of 14 injections passed clean, while a
# `ghp_` token in the same file was caught — so the scanner was live, just
# blind to this whole class.
#
# Detection is by SHAPE, suppression is by ALLOWLIST, and the default is BLOCK.
# That ordering is the point: an address is structurally indistinguishable from
# a permitted one (`hoiboyuk@gmail.com` and a personal gmail differ in no way a
# regex can see), so the only thing that can separate them is an explicit,
# reviewable per-repo list. Detect-then-allow fails closed on an address nobody
# has vouched for, which is exactly the shape of the incident.
_EMAIL_RE = re.compile(
    r"(?<![A-Za-z0-9._%+'-])"
    r"[A-Za-z0-9](?:[A-Za-z0-9._%+'-]*[A-Za-z0-9])?"
    r"@"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,}"
    r"(?![A-Za-z0-9-])"
)

# Deliberately narrow, and narrowed AGAIN after measurement. A permissive
# digit-run pattern flags version strings, ports, timestamps, row counts and
# truncated hashes, and a gate that cries wolf gets switched off — which
# protects nothing. The first draft of this pattern produced 1411 hits on this
# repo, 1402 of them signed decimals like `+123.45` inside two generated chart
# HTML files. The shape alone cannot separate those from a phone number, so the
# length constraint is enforced in `_valid_phone` below rather than by piling
# more alternation into the regex.
_PHONE_RE = re.compile(
    r"(?<![\w+])"
    r"(?:"
    r"\+\d[\d\s.()-]{8,18}\d"      # international, digit count checked below
    r"|"
    r"0(?:7|1|2)\d[\d\s.()-]{6,14}\d"  # UK mobile / geographic, ditto
    r")"
    r"(?![\w])"
)


def _valid_phone(value: str) -> bool:
    """Is this digit run actually phone-shaped, by length and prefix?

    E.164 caps a full number at 15 digits and no national plan is shorter than
    10 with its country or trunk code. `+123.45` has four digits and is a
    decimal; `+44 7700 900123` has twelve and is a phone number. Nothing about
    the surrounding characters distinguishes them, so the digit count does.
    """
    digits = re.sub(r"\D", "", value)
    if not 10 <= len(digits) <= 15:
        return False
    if value.lstrip().startswith("+"):
        return True
    # UK national form must be a real trunk prefix and exactly 11 digits.
    return len(digits) == 11 and digits.startswith(("07", "01", "02"))

# UK postcode, full form only (outward + inward). The outward-only form (`NW1`)
# is too collision-prone to gate on.
_POSTCODE_RE = re.compile(
    r"(?<![A-Za-z0-9])"
    r"[A-Z]{1,2}[0-9][A-Z0-9]?[ ]?[0-9][A-Z]{2}"
    r"(?![A-Za-z0-9])"
)

# RFC 2606 / RFC 6761 reserved-for-documentation names. These exist precisely so
# examples need no allowlist entry, and every SST3 test fixture already uses
# them. Allowed in every repo, unconditionally.
RESERVED_EMAIL_DOMAINS: frozenset = frozenset({
    "example.com", "example.net", "example.org",
})
RESERVED_EMAIL_SUFFIXES: tuple = (
    ".example", ".invalid", ".test", ".localhost",
)

# WhatsApp address (JID) of a person, a group or a linked ID (groupwarden#1):
# `447700900123@s.whatsapp.net`, `120363000000000000@g.us`,
# `99999000000444@lid`. The first two are also email-shaped, but `@lid` is not,
# and a JID is a phone number or member identifier, not a mailbox, so it gets
# its own kind and message. It is listed BEFORE email so a JID line is reported
# as one. Allowlisting is by exact literal (see is_pii_allowlisted).
_WHATSAPP_JID_RE = re.compile(
    r"(?<![A-Za-z0-9._%+'-])"
    r"[0-9]{5,20}(?:-[0-9]{5,20})?"
    r"@(?:s\.whatsapp\.net|c\.us|g\.us|lid|newsletter|broadcast)"
    r"(?![A-Za-z0-9-])"
)

PII_PATTERNS: List[Dict] = [
    {
        "kind": "whatsapp_jid",
        "pattern": _WHATSAPP_JID_RE,
        "message": "WhatsApp ID (phone number, group or member ID) detected",
        "fix": (
            "Remove it, or add the exact literal to .secret-pii-allowlist if it "
            "is a synthetic fixture. Use Ofcom drama-range numbers "
            "(447700900xxx@s.whatsapp.net) or obviously fake IDs in tests."
        ),
    },
    {
        "kind": "email",
        "pattern": _EMAIL_RE,
        "message": "Email address detected",
        "fix": (
            "If this address is meant to be public, add it (or its domain as "
            "`@domain.tld`) to .secret-pii-allowlist. If it is personal data, "
            "remove it. Use an example.com/.net/.org address in tests and comments."
        ),
    },
    {
        "kind": "phone",
        "pattern": _PHONE_RE,
        "validate": _valid_phone,
        "message": "Phone number detected",
        "fix": (
            "Remove it, or add the literal to .secret-pii-allowlist if it is a "
            "published business number. Use the Ofcom drama range "
            "(+44 7700 900xxx) in examples."
        ),
    },
    {
        "kind": "postcode",
        "pattern": _POSTCODE_RE,
        "message": "UK postcode detected",
        "fix": (
            "Remove it, or add the literal to .secret-pii-allowlist if it is a "
            "published business address."
        ),
    },
]


def is_pii_allowlisted(value: str, kind: str, pii_allowlist: Set[str]) -> bool:
    """Is this matched PII value explicitly permitted in this repo?

    Email entries may be a whole domain (`@hoiboy.uk`) or an exact address.
    Phone and postcode entries are exact literals, compared with separators
    stripped so `+44 7700 900123` and `+447700900123` are the same entry.
    """
    lowered = value.lower()
    if kind == "email":
        domain = lowered.rpartition("@")[2]
        if domain in RESERVED_EMAIL_DOMAINS:
            return True
        if domain.endswith(RESERVED_EMAIL_SUFFIXES):
            return True
        for entry in pii_allowlist:
            entry = entry.lower()
            if entry.startswith("@"):
                if domain == entry[1:]:
                    return True
            elif entry == lowered:
                return True
        return False
    normalised = re.sub(r"[\s.()-]", "", lowered)
    for entry in pii_allowlist:
        if re.sub(r"[\s.()-]", "", entry.lower()) == normalised:
            return True
    return False


# Placeholder values that should NOT trigger GENERIC_SECRET findings
PLACEHOLDER_PATTERNS: List[re.Pattern] = [
    re.compile(r"^your[-_]?\w+", re.IGNORECASE),
    re.compile(r"^changeme$", re.IGNORECASE),
    re.compile(r"^change_me$", re.IGNORECASE),
    re.compile(r"^example$", re.IGNORECASE),
    re.compile(r"^sample$", re.IGNORECASE),
    re.compile(r"^test$", re.IGNORECASE),
    re.compile(r"^dummy$", re.IGNORECASE),
    re.compile(r"^fake$", re.IGNORECASE),
    re.compile(r"^mock$", re.IGNORECASE),
    re.compile(r"^placeholder$", re.IGNORECASE),
    re.compile(r"^x{3,}$", re.IGNORECASE),
    re.compile(r"_x{3,}$", re.IGNORECASE),
    re.compile(r"^\*{3,}$"),
    re.compile(r"^todo$", re.IGNORECASE),
    re.compile(r"^fixme$", re.IGNORECASE),
    re.compile(r"^tbd$", re.IGNORECASE),
    re.compile(r"^none$", re.IGNORECASE),
    re.compile(r"^null$", re.IGNORECASE),
    re.compile(r"^undefined$", re.IGNORECASE),
    re.compile(r"^\$\{.+\}$"),
    re.compile(r"^\{\{.+\}\}$"),
    re.compile(r"^<[^>]+>$"),
]

# Curated NON-SECRET schema/type/meta wordlist used by `is_likely_prose_value`
# to suppress the prose false-positive class (`token: input`, `secret: value`,
# `password: required`, ...). Recall-critical config kept in-source by design
# per dotfiles#494 AC 1.1.1 — readable to reviewers, no hidden-config drift.
# Excludes all secret keyword-words; contains zero strings from the must-flag
# adversarial TP corpus (dragon/monkey/football/qwerty/letmein/hunter2/...).
CURATED_NONSECRET_VALUES: frozenset = frozenset({
    "input", "value", "string", "identifier",
    "integer", "missing", "boolean", "description",
    "header", "column", "parameter", "example",
    "number", "object", "array", "field",
    "type", "enum",
})

# Files/dirs to always skip
IGNORE_PATTERNS: List[str] = [
    "*/node_modules/*",
    "*/.venv/*",
    "*/venv/*",
    "*/__pycache__/*",
    "*.min.js",
    "*.min.css",
    "*.map",
    "*/dist/*",
    "*/build/*",
    "*/.git/*",
    "*/archive/*",
    "*/.pytest_cache/*",
]

# Filenames that are always exempt
EXEMPT_FILENAMES: Set[str] = {
    ".env.example",
    ".env.template",
}

# Extensions to scan
SCAN_EXTENSIONS: List[str] = [
    ".py", ".js", ".jsx", ".ts", ".tsx",
    ".json", ".yaml", ".yml", ".toml",
    ".md", ".txt", ".html", ".css",
    ".sh", ".bash", ".ps1", ".cfg", ".ini", ".conf",
    # Text PEM/PGP private-key containers: without these, a real key committed as
    # a *.pem / *.key / *.asc / *.p8 / *.pk8 path evades the scanner entirely by
    # extension, even though the PRIVATE_KEY patterns would match its body
    # (dotfiles#540). Binary key stores (.p12/.pfx/.der/.cer) are intentionally
    # omitted — they hold no text the patterns could match.
    # Legitimate committed test-fixture keys are suppressed per-repo via
    # .secret-allowlist, not by excluding the extension.
    # Matching is case-folded at every consumer -- KEY.PEM is key.pem on the
    # case-insensitive filesystems this gate guards (Issue #561).
    ".pem", ".key", ".asc", ".p8", ".pk8",
    # Tab-separated copy decks. On hoiboy-uk the five tracked `.tsv` files under
    # scripts/social-cards/ are the literal text burned onto publicly-served
    # 1200x630 PNGs, so anything pasted into a row ships as an image on the
    # site. Without this suffix the guard never opened them (hoiboy-uk#56).
    ".tsv",
    # Go source + module file, SQL migrations and systemd units. groupwarden#1
    # is a public Go service: without these its code, its schema and its deploy
    # units were never opened, so a token pasted into a test fixture or a unit's
    # Environment= line scored CLEAN.
    ".go", ".mod", ".sql", ".service",
]

# Credential-bearing config files that carry NO scannable extension. A suffix
# allowlist alone never opens them, so a live npm auth token in `.npmrc`, an
# `ENV DB_PASSWORD=` line in a `Dockerfile`, or a real `.env.local` scored
# CLEAN — the gate reported them safe rather than declining to judge them.
# EXEMPT_FILENAMES already listed `.env.example` / `.env.template`, which only
# makes sense if such files were believed reachable; they were not, so that
# exemption was dead code until this landed. It is live now.
# Matched case-folded, like SCAN_EXTENSIONS (Issue #561).
SCAN_FILENAMES: Set[str] = {
    ".env", ".envrc", ".netrc", ".npmrc", ".pypirc", ".dockercfg",
    ".htpasswd", ".gitconfig", ".terraformrc",
    ".bashrc", ".zshrc", ".profile", ".bash_profile",
    "dockerfile", "makefile", "procfile",
    # Cloudflare Pages / Netlify conventions: extensionless, tracked, and copied
    # BYTE-FOR-BYTE to the public site root at deploy. `should_scan_file` is a
    # closed allowlist, so with no extension and no entry here they were skipped
    # before any pattern ran -- not even the blocklist (hoiboy-uk#56).
    "_headers", "_redirects",
}

# Families written as `<base>.<variant>`: `.env.local`, `.env.production`,
# `Dockerfile.prod`, `.dev.vars.staging`. A set-membership test alone misses
# every variant, which is the common real-world spelling for the one that holds
# production values.
SCAN_FILENAME_PREFIXES: tuple = (".env.", "dockerfile.", ".dev.vars.")

# Families written the OTHER way round, `<name><suffix>`. Set membership and a
# prefix rule both miss these, because the varying part is on the left:
#   prod.env / staging.env / local.env   an env file NOT named `.env`
#   .dev.vars                            Cloudflare Pages / wrangler local secrets
# Both spellings hold live credentials and both scored CLEAN on the pre-commit
# hook AND the blocking CI scan of a PUBLIC repo. `.gitignore` is commonly blind
# on the identical spellings, so the file is not even untracked-by-default.
# These are suffixes, not extensions, so they cannot live in SCAN_EXTENSIONS:
# `Path("prod.env").suffix` is `.env`, but `Path(".dev.vars").suffix` is
# `.vars`, and matching `.vars` broadly would pull in unrelated data files.
SCAN_FILENAME_SUFFIXES: tuple = (".env", ".dev.vars")


def should_scan_file(file_path: Path) -> bool:
    """Single authority on whether a path enters the scan.

    This gate previously asked the question two different ways: the directory
    walk matched `f.name.lower().endswith(<ext tuple>)` while the staged-only
    path matched `Path(f).suffix.lower() in SCAN_EXTENSIONS`. Two matchers for
    one contract drift apart silently — they already disagreed on a dotfile
    whose whole name is an extension (`Path('.py').suffix` is `''`, so
    staged-only skipped a file the directory walk scanned). Both callers now
    ask this function, so there is one answer and one place to change it.
    """
    name = file_path.name.lower()
    if name in SCAN_FILENAMES:
        return True
    if name.startswith(SCAN_FILENAME_PREFIXES):
        return True
    if name.endswith(SCAN_FILENAME_SUFFIXES):
        return True
    return name.endswith(tuple(ext.lower() for ext in SCAN_EXTENSIONS))


# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------

def _drop_git_ignored(scan_path: Path, candidates: List[Path]) -> List[Path]:
    """Remove candidates git ignores. Returns the input unchanged if it cannot ask.

    One batched `git check-ignore --stdin` rather than a subprocess per file.
    Exit status 0 = some paths matched, 1 = none matched, anything else (not a
    repo, git missing, a candidate beyond a symlink) = cannot answer, in which
    case every candidate is kept. Keeping is the safe direction: this filter
    only ever REMOVES files from a secret scan, so failing to answer must never
    remove anything.

    Paths are resolved to absolute before being handed to git. `-C <scan_path>`
    makes git interpret each line relative to scan_path, while the candidates
    produced by `scan_path.rglob("*")` already carry that prefix — so a
    relative, non-"." scan_path had the prefix applied twice and git matched
    nothing. That failed safe (an ignored file was kept and scanned) but it was
    still wrong, and it silently disabled the filter. Resolving both sides
    removes the ambiguity entirely.
    """
    if not candidates:
        return candidates
    resolved = {}
    for p in candidates:
        try:
            # Resolve the candidate AS GIVEN. Do not join it onto scan_path:
            # these come from `scan_path.rglob("*")`, so they already carry
            # that prefix, and joining would apply it a second time.
            resolved[p] = str(p.resolve())
        except OSError:
            resolved[p] = str(p)
    try:
        result = subprocess.run(
            ["git", "-C", str(scan_path), "check-ignore", "--stdin"],
            input="\n".join(resolved[p] for p in candidates),
            capture_output=True, text=True,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log_event(
            "check-public-repo-secrets", "gitignore_filter_unavailable",
            level="warning", reason=type(exc).__name__, detail=str(exc),
            candidates=len(candidates),
        )
        return candidates
    if result.returncode not in (0, 1):
        # Reachable in the real world: a candidate beyond a symlinked directory
        # makes git exit 128 ("beyond a symbolic link"), and a worktree gets
        # symlinked node_modules/.venv from setup-worktree-deps.sh.
        log_event(
            "check-public-repo-secrets", "gitignore_filter_unavailable",
            level="warning", reason=f"git exit {result.returncode}",
            detail=result.stderr.strip()[:200], candidates=len(candidates),
        )
        return candidates
    ignored = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    if not ignored:
        return candidates
    return [p for p in candidates if resolved[p] not in ignored]


def _git_tracked_abspaths(scan_path: Path) -> Set[str]:
    """Absolute paths of the files git tracks under scan_path (NUL-delimited read).

    A tracked file is published, so the walk never lets IGNORE_PATTERNS drop
    one. Outside a git repo nothing is tracked, the set is empty and the walk
    prunes exactly as it always did; a git failure inside a repo is logged.
    """
    try:
        result = subprocess.run(  # sst3-sec: justified: git argv list, the caller's scan path as the -C operand, no shell
            ["git", "-C", str(scan_path), "ls-files", "-z"],
            capture_output=True,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log_event("check-public-repo-secrets", "tracked_list_unavailable",
                  level="warning", reason=type(exc).__name__, detail=str(exc))
        return set()
    if result.returncode != 0:
        log_event("check-public-repo-secrets", "tracked_list_unavailable",
                  level="warning", reason=f"git exit {result.returncode}",
                  detail=result.stderr.decode("utf-8", "replace").strip()[:200])
        return set()
    return {os.path.abspath(scan_path / os.fsdecode(n))
            for n in result.stdout.split(b"\0") if n}


def is_public_repo(repo_root: Path) -> bool:
    """Check if repo has a .public-repo marker file."""
    return (repo_root / ".public-repo").exists()


_TOKEN_PREFIX = "sha256:"


def _token_lines(lines: Set[str]) -> Set[str]:
    """The opaque-token entries in a blocklist set."""
    return {ln for ln in lines if ln.startswith(_TOKEN_PREFIX)}


def _blocklist_has_tokens(lines: Set[str]) -> bool:
    return bool(_token_lines(lines))


def _resolve_hashes_path(repo_root: Path) -> Optional[Path]:
    """Locate the canonical-only token->literal manifest, or None.

    The original single candidate was `<repo_root>/SST3/scripts/`, which only
    ever resolves inside the dotfiles clone itself. Every mirror -- including
    the ones running this gate on the operator's dev machine, one directory
    away from a dotfiles clone that HAS the manifest -- fell straight through
    to degraded mode. The probe order below is explicit rather than clever:
    an env override first (CI and unusual layouts), then the canonical
    in-repo location, then the conventional sibling clone.
    """
    env = os.environ.get("SST3_BLOCKLIST_HASHES")
    if env:
        candidate = Path(env).expanduser()
        return candidate if candidate.exists() else None
    rel = Path("SST3") / "scripts" / ".secret-blocklist-hashes.json"
    candidates = [
        repo_root / rel,
        repo_root.parent / "dotfiles" / rel,
        Path.home() / "DevProjects" / "dotfiles" / rel,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def _expand_hashed_tokens(
    lines: Set[str], hashes_path: Optional[Path]
) -> tuple[Set[str], Set[str]]:
    """Expand `sha256:<prefix>:<class>` opaque-token lines to their literal forms.

    Reads SST3/scripts/.secret-blocklist-hashes.json (canonical-only, unmirrored
    per drift-manifest:unmirrored_canonical_files; #497 A.2.3) to map each token
    to its underlying literal substrings. Token strings themselves are kept in
    the output set (so the substring scan still flags any document that contains
    a literal token reference) and the literals they cover are added alongside.

    Returns (expanded_set, UNEXPANDED_TOKENS). The second element is what the
    caller's vacuity gate reads, and it is the whole reason this returns a pair.

    The gate used to be `hashes_path is None`, which asked the wrong question:
    whether a FILE was found, not whether the expansion actually happened. Four
    ways to reach identical zero-coverage degradation answered "found" and so
    reported nothing -- the manifest existing but unreadable, holding invalid
    JSON, carrying no `tokens` key, or carrying a `tokens` map that simply does
    not cover the tokens THIS repo's blocklist uses (which is the one that
    survives a rename on either side). Each left every literal behind those
    tokens unscanned while the run printed a clean PASS. Reporting the
    unexpanded tokens instead of the path makes all five cases -- including the
    original absent-file one -- the same observable fact.
    """
    tokens = _token_lines(lines)
    if not hashes_path or not hashes_path.exists():
        return lines, tokens
    try:
        data = json.loads(hashes_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return lines, tokens
    if not isinstance(data, dict):
        return lines, tokens
    token_map = data.get("tokens")
    if not isinstance(token_map, dict):
        return lines, tokens
    expanded: Set[str] = set(lines)
    unexpanded: Set[str] = set()
    for token in tokens:
        entry = token_map.get(token)
        literals = [lit for lit in (entry or {}).get("literals", []) if lit]
        if not literals:
            # Present-but-empty counts as unexpanded: a token whose literal list
            # is missing or blank covers nothing, which is the same coverage hole
            # as a token the manifest never mentions.
            unexpanded.add(token)
            continue
        expanded.update(literals)
    return expanded, unexpanded


def load_file_set(file_path: Optional[Path]) -> Set[str]:
    """Load a text file into a set of non-empty, non-comment lines."""
    result: Set[str] = set()
    if file_path and file_path.exists():
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    result.add(line)
    return result


def decode_for_scan(data: bytes) -> str:
    """Bytes to text for the pattern scan. Never skips a file.

    This replaced `is_binary_file`, which called a file binary when its first
    8 KB held a NUL byte, and also when it could not be opened at all, and the
    caller then skipped it. So one NUL byte hid a whole file, a dangling
    symlink passed, and a UTF-16 PowerShell script (the Windows PowerShell 5
    default for Out-File, where every other byte is a NUL) was never read
    (#577 escalation, class C3 fail-open reader). Every path reaching here
    already passed should_scan_file's text-type test, so there is nothing
    binary left to protect. A UTF-16 BOM decodes as UTF-16; anything else as
    UTF-8 with undecodable bytes replaced, which keeps line numbers intact.
    """
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8", errors="replace")


def is_placeholder_value(value: str) -> bool:
    """Check if a matched secret value is an obvious placeholder."""
    for pattern in PLACEHOLDER_PATTERNS:
        if pattern.search(value):
            return True
    return False


# Three accepted assignment forms feed `is_likely_prose_value`:
#   1) JSON form:        "keyword":"value"   — mandatory JSON quoting, bare-word
#   2) JSON form (sgl):  'keyword':'value'   — single-quoted JSON variant
#   3) Bare form:        keyword=value       — env/yaml unquoted prose
# The Python-literal form `keyword="value"` (bare keyword, quoted value) is
# DELIBERATELY excluded — quoting an otherwise-bare value is a strong
# "developer chose to make this a string literal" signal, so the prose
# discriminator does not suppress it. See dotfiles#494 AC 1.1.2 + research §L2a.
_KEYWORD_ALT = (
    r"password|passwd|secret|token|api_?key|auth_?key|"
    r"credential|seller_id|account_id"
)
_PROSE_CONTEXT_RE = re.compile(
    rf"(?i)(?:"
    rf"\"(?:{_KEYWORD_ALT})\"\s*[=:]\s*\""
    rf"|"
    rf"'(?:{_KEYWORD_ALT})'\s*[=:]\s*'"
    rf"|"
    rf"(?<![\"'])(?:{_KEYWORD_ALT})\s*[=:]\s*(?![\"'])"
    rf")"
)


_LOWERCASE_WORD_RE = re.compile(r"[a-z]+")
_TRAILING_PROSE_RE = re.compile(r"\s+[a-z]+")


def is_likely_prose_value(line: str, value: str) -> bool:
    """Discriminator: True if `value` is benign schema/type/meta prose
    in a bare-word context (env/yaml unquoted OR JSON mandatory-quote form),
    and either appears in `CURATED_NONSECRET_VALUES` or is followed by
    >=1 further lowercase word on the line (multi-word prose run).

    Returns False for any of: digit/uppercase/special in `value`; Python-
    literal explicit-quote context (`keyword="value"` with bare keyword);
    non-curated single-word with no trailing lowercase prose run.

    Connection-string patterns ([2]-[5]) are unaffected — they yield
    `value=None` from `extract_generic_secret_value` and short-circuit
    the caller's `if value and ...: continue` guard before this runs.
    """
    if not _LOWERCASE_WORD_RE.fullmatch(value):
        return False
    m = _PROSE_CONTEXT_RE.search(line)
    if not m:
        return False
    rest = line[m.end():]
    rest_match = re.match(re.escape(value) + r"(.*)", rest)
    if not rest_match:
        return False
    after_value = rest_match.group(1)
    if value in CURATED_NONSECRET_VALUES:
        return True
    return bool(_TRAILING_PROSE_RE.match(after_value))


# Match: trailing `# secret-allow` or `// secret-allow` marker, optionally
# followed by a single `(...)` parenthetical comment. Rejects free-form
# trailing text (sentence-continuation mid-line prose). Live-system shape
# evidence from hoiboy-uk: `# secret-allow (BW retrieval at runtime, ...)`,
# `# secret-allow (placeholder)` — parenthetical-trailer is the common form.
_INLINE_ALLOW_RE = re.compile(
    r"(?:^|\s)(?:#|//)\s*secret-allow(?:\s+\([^)]*\))?\s*$"
)
_PAREN_CONTENT_RE = re.compile(r"\(([^)]*)\)")


def has_inline_allow(line: str) -> bool:
    """Return True when the line ends with a trailing `# secret-allow` /
    `// secret-allow` marker, optionally followed by a single `(...)`
    parenthetical comment. Tightened from the prior naive `in` substring
    test (which let prose mentions of the marker self-exempt entire lines)
    AND from a too-strict bare-trailing variant (which broke legitimate
    `# secret-allow (parenthetical)` usage). dotfiles#494 Defect 2.

    Stage-5 hardening: the parenthetical MUST NOT contain a high-confidence
    PLATFORM_TOKEN shape (ghp_, AKIA, sk_live_, etc.) — otherwise the
    exemption is refused. Closes the parenthetical-bypass regression
    introduced by the 1be455f parenthetical relaxation (the marker was
    absorbing real platform tokens hidden inside `# secret-allow (ghp_...)`).

    Accepted forms (True):
      foo  # secret-allow
      foo  # secret-allow (BW retrieval at runtime, not committed)
      const t = x; // secret-allow (placeholder)

    Rejected forms (False):
      describes the # secret-allow mechanism in prose
      `# secret-allow`                   (markdown-fenced docs)
      foo  # secret-allow trailing-word  (free-form continuation)
      foo  # secret-allow (ghp_<36chars>)            (Stage-5 reject)
      foo  # secret-allow (AKIA<16>)                 (Stage-5 reject)
    """
    stripped = line.rstrip("\r\n")
    match = _INLINE_ALLOW_RE.search(stripped)
    if not match:
        return False
    paren_match = _PAREN_CONTENT_RE.search(match.group(0))
    if paren_match:
        paren_content = paren_match.group(1)
        for pat in PLATFORM_TOKEN_PATTERNS:
            if pat["pattern"].search(paren_content):
                return False
        for pat in PRIVATE_KEY_PATTERNS:
            if pat["pattern"].search(paren_content):
                return False
    return True


def is_file_exempt(file_path: Path) -> bool:
    """Check if file is exempt by name."""
    return file_path.name in EXEMPT_FILENAMES


def _path_matches_entry(file_str: str, allowed_file: str) -> bool:
    """Does this scanned path correspond to this allowlist path entry?

    Matching is on whole path SEGMENTS, anchored at the end. The old test was
    `file_str.endswith(entry) or entry in file_str`, and the `in` half let an
    entry travel: `scripts/import_aam_sql.py` also suppressed
    `vendor/scripts/import_aam_sql.py.bak`, and any entry that happened to be a
    substring of an unrelated path silenced that path too. An allowlist that
    silently covers files nobody listed is indistinguishable from a shorter
    allowlist plus a blind spot.
    """
    allowed = allowed_file.replace("\\", "/").strip("/")
    if not allowed:
        return False
    scanned = file_str.replace("\\", "/").strip("/")
    if scanned == allowed:
        return True
    return scanned.endswith("/" + allowed)


def is_line_allowlisted(
    file_path: Path, line_num: int, allowlist: Set[str]
) -> bool:
    """Check if a specific file, file:line, or file::CATEGORY is allowlisted.

    Three entry forms:
      path/to/file.py:128        one line of one file (preferred -- narrowest)
      path/to/file.py::PII       one category, whole file
      path/to/file.py            whole file, every category (widest -- avoid)

    The `::CATEGORY` form exists because a bare path is a blunt instrument: the
    four bare entries on this repo were each added to silence ONE self-reference
    (a pattern string inside the scanner, a documented example path), and each
    silently disabled all five categories for that whole file as a side effect.
    A live token in such a file was reported clean.
    """
    file_str = str(file_path).replace("\\", "/")
    for entry in allowlist:
        if "::" in entry:
            # Category-scoped; resolved per-finding by is_category_allowlisted,
            # not here. Returning True at this point would widen it back to the
            # whole-file suppression this form exists to avoid.
            continue
        if ":" in entry:
            allowed_file, allowed_line = entry.rsplit(":", 1)
            if allowed_line.isdigit() and int(allowed_line) == line_num:
                if _path_matches_entry(file_str, allowed_file):
                    return True
        else:
            if _path_matches_entry(file_str, entry):
                return True
    return False


def is_category_allowlisted(
    file_path: Path, category: str, allowlist: Set[str]
) -> bool:
    """Whole-file suppression scoped to a single finding category."""
    file_str = str(file_path).replace("\\", "/")
    for entry in allowlist:
        if "::" not in entry:
            continue
        allowed_file, _, allowed_category = entry.partition("::")
        if allowed_category.strip().upper() != category.upper():
            continue
        if _path_matches_entry(file_str, allowed_file):
            return True
    return False


_GENERIC_VALUE_RE = re.compile(
    r"(?i)['\"`]?(?:password|passwd|secret|token|api_?key|auth_?key|credential|seller_id|account_id"
    r"|(?:DB|DATABASE)_(?:PASSWORD|PASS|PWD|SECRET))['\"`]?"
    r"\s*[=:]\s*['\"`]?([^\s'\"`]+)"
)


def extract_generic_secret_value(line: str) -> Optional[str]:
    """Extract the value portion from a generic secret assignment for placeholder checking."""
    match = _GENERIC_VALUE_RE.search(line)
    if match:
        return match.group(1)
    return None


def is_public_value(text: str, public_values: Set[str]) -> bool:
    """True when a matched literal is one this repo publishes ON PURPOSE.

    Value-scoped, not file-scoped, and that is the whole point. A value that
    legitimately ships in the rendered artefact -- an analytics beacon token, a
    public site identifier -- appears in EVERY built page. Suppressing it with
    `file:line` entries would need one entry per page, and every one of them
    would go stale the next time the build renumbers a line. Worse, the natural
    shortcut (a bare whole-file entry) switches off every category for that file.

    So the suppression is attached to the value instead. It stays correct across
    a rebuild, it cannot silently widen to cover a different secret in the same
    file, and it fails in the safe direction: a value nobody listed is still a
    finding. The PII lane already works this way (.secret-pii-allowlist); this
    is the same primitive for the credential categories.

    Substring rather than equality because a pattern's match often carries
    surrounding syntax (`"token": "abc123`), so the listed literal is the token
    itself, not whatever quoting the renderer happened to emit around it.
    """
    if not public_values or not text:
        return False
    return any(value and value in text for value in public_values)


def scan_line(
    line: str,
    line_num: int,
    file_path: Path,
    blocklist: Set[str],
    allowlist: Set[str],
    pii_allowlist: Set[str],
    public_values: Set[str],
) -> List[Finding]:
    """Scan a single line for all secret patterns. Returns findings.

    `pii_allowlist` is REQUIRED and has no default on purpose. A default would
    let a caller that forgot to thread it through silently scan with an empty
    allowlist (noisy but safe) or, worse, a future default of "allow all"
    (silent and unsafe). Making it positional forces every call site to state
    what it is scanning against, and a missed site is a TypeError at import
    time rather than a gate that quietly stops covering a category.
    """
    findings: List[Finding] = []
    stripped = line.strip()

    if not stripped:
        return findings

    if has_inline_allow(line):
        return findings

    if is_line_allowlisted(file_path, line_num, allowlist):
        return findings

    # Categories switched off for this whole file by a `path::CATEGORY` entry.
    # Computed once rather than per-pattern: the allowlist is small, but this
    # runs per line of every scanned file.
    suppressed = {
        cat for cat in ("PLATFORM_TOKEN", "PRIVATE_KEY", "GENERIC_SECRET",
                        "PRIVATE_PATH", "PII", "BLOCKLIST")
        if is_category_allowlisted(file_path, cat, allowlist)
    }

    # PLATFORM_TOKEN — highest confidence, check first
    for pat in [] if "PLATFORM_TOKEN" in suppressed else PLATFORM_TOKEN_PATTERNS:
        match = pat["pattern"].search(line)
        if match:
            if is_public_value(match.group(0), public_values):
                continue
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="PLATFORM_TOKEN",
                message=pat["message"],
                fix=pat["fix"],
            ))
            return findings  # One finding per line

    # PRIVATE_KEY
    for pat in [] if "PRIVATE_KEY" in suppressed else PRIVATE_KEY_PATTERNS:
        match = pat["pattern"].search(line)
        if match:
            if is_public_value(match.group(0), public_values):
                continue
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="PRIVATE_KEY",
                message=pat["message"],
                fix=pat["fix"],
            ))
            return findings

    # GENERIC_SECRET — with placeholder filtering + prose discriminator
    for pat in [] if "GENERIC_SECRET" in suppressed else GENERIC_SECRET_PATTERNS:
        if pat["pattern"].search(line):
            value = extract_generic_secret_value(line)
            if value and is_placeholder_value(value): continue
            if value and is_likely_prose_value(line, value): continue
            if value and is_public_value(value, public_values): continue
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="GENERIC_SECRET",
                message=pat["message"],
                fix=pat["fix"],
            ))
            return findings

    # PRIVATE_PATH
    for pat in [] if "PRIVATE_PATH" in suppressed else PRIVATE_PATH_PATTERNS:
        match = pat["pattern"].search(line)
        if match:
            if is_public_value(match.group(0), public_values):
                continue
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="PRIVATE_PATH",
                message=pat["message"],
                fix=pat["fix"],
            ))
            return findings

    # PII — shape-detected, allowlist-suppressed, default BLOCK.
    # Runs after the credential categories (a line carrying both is reported as
    # the higher-confidence credential finding) and before BLOCKLIST, whose
    # curated literals are a strict subset of what shape detection covers.
    for pat in [] if "PII" in suppressed else PII_PATTERNS:
        for match in pat["pattern"].finditer(line):
            value = match.group(0)
            validate = pat.get("validate")
            if validate and not validate(value):
                continue
            if is_pii_allowlisted(value, pat["kind"], pii_allowlist):
                continue
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="PII",
                message=pat["message"],
                fix=pat["fix"],
            ))
            return findings

    # BLOCKLIST — case-insensitive substring match
    line_lower = line.lower()
    for term in [] if "BLOCKLIST" in suppressed else blocklist:
        if term.lower() in line_lower:
            findings.append(Finding(
                line_num=line_num,
                line=stripped,
                category="BLOCKLIST",
                message=f"Blocked term from .secret-blocklist: {term}",
                fix="Remove business identifier or add to .secret-allowlist if intentional",
            ))
            return findings

    return findings


def scan_file(
    file_path: Path,
    blocklist: Set[str],
    allowlist: Set[str],
    pii_allowlist: Set[str],
    public_values: Set[str],
) -> List[Finding]:
    """Scan a single file for secrets. Returns all findings.

    Raises OSError when the file cannot be read. It used to print a warning
    and return no findings, so an unreadable file passed; the caller now
    counts it and fails the run.
    """
    if is_file_exempt(file_path):
        return []
    return scan_text(file_path, decode_for_scan(file_path.read_bytes()),
                     blocklist, allowlist, pii_allowlist, public_values)


def scan_text(
    file_path: Path,
    text: str,
    blocklist: Set[str],
    allowlist: Set[str],
    pii_allowlist: Set[str],
    public_values: Set[str],
) -> List[Finding]:
    """Scan already-decoded content attributed to file_path.

    Lines split as a text-mode file read splits them (universal newlines), so
    line numbers match what the file-based scan always reported.
    """
    findings: List[Finding] = []
    for line_num, line in enumerate(io.StringIO(text, newline=None), start=1):
        findings.extend(scan_line(
            line, line_num, file_path, blocklist, allowlist, pii_allowlist,
            public_values
        ))
    return findings


def get_staged_blobs(repo_root: Path) -> List[Tuple[str, bytes]]:
    """(path, content) for every non-deleted staged entry, read FROM THE INDEX.

    The staged scan used to take `git diff --cached --name-only
    --diff-filter=ACM` and open each path in the WORKING TREE. That leaked in
    four ways (#577 escalation, classes C1 and C3):
    - no -z, so git C-quoted a name holding `"`, `\\` or a non-ASCII byte,
      the quoted string named no file, and the secret passed;
    - ACM excluded renames, so a secret moved with `git mv` passed;
    - the working-tree copy is not what is committed: stage a secret, remove
      it from the file without re-staging, and the scan saw the clean copy;
    - a staged symlink was opened through its target, and a dangling one
      counted as binary and passed.
    Now the list is -z with renames off (a rename is a delete plus an add,
    and every non-delete is kept), and each entry's blob comes from the index.
    A symlink's blob is its target path, which is what the commit publishes.
    A gitlink (submodule, mode 160000) has no content in this repo.

    Every git call runs from repo_root. `git diff --name-only` prints paths
    from the top level, but `git ls-files` prints them from the cwd and lists
    only the cwd's subtree, so run from a subdirectory the two lists never
    met and a staged secret passed as "0 file(s) scanned" (#577 Ralph r5).
    A staged name the index does not hold is an error, never a skip.
    """
    names = subprocess.run(  # sst3-sec: justified: git with a fixed argument list, no shell
        ["git", "diff", "--cached", "--name-only", "-z", "--no-renames",
         "--diff-filter=d"],
        capture_output=True, check=True, cwd=repo_root,
    ).stdout
    wanted = {n for n in names.split(b"\0") if n}
    if not wanted:
        return []
    index = subprocess.run(  # sst3-sec: justified: git with a fixed argument list, no shell
        ["git", "ls-files", "--stage", "-z"], capture_output=True, check=True,
        cwd=repo_root,
    ).stdout
    entries: List[Tuple[str, str]] = []
    seen: set = set()
    for rec in index.split(b"\0"):
        if not rec:
            continue
        meta, _, path = rec.partition(b"\t")
        mode, oid, _stage = meta.split(b" ")
        if path in wanted:
            seen.add(path)
            if mode != b"160000":
                entries.append((os.fsdecode(path), oid.decode("ascii")))
    missing = wanted - seen
    if missing:
        raise RuntimeError(
            f"{len(missing)} staged name(s) are not in the index, e.g. "
            f"{os.fsdecode(sorted(missing)[0])!r}")
    if not entries:
        return []
    batch = subprocess.run(  # sst3-sec: justified: git with a fixed argument list, no shell
        ["git", "cat-file", "--batch"],
        input="".join(f"{oid}\n" for _, oid in entries).encode("ascii"),
        capture_output=True, check=True, cwd=repo_root,
    ).stdout
    blobs: List[Tuple[str, bytes]] = []
    pos = 0
    for path, oid in entries:
        header_end = batch.index(b"\n", pos)
        header = batch[pos:header_end].split(b" ")
        if len(header) != 3 or header[1] != b"blob":
            raise RuntimeError(f"git cat-file gave {header!r} for {path} ({oid})")
        size = int(header[2])
        start = header_end + 1
        blobs.append((path, batch[start:start + size]))
        pos = start + size + 1
    return blobs


def report_findings(
    all_findings: Dict[Path, List[Finding]],
    scan_root: Path,
    show_evidence: bool = False,
) -> int:
    """Print findings report and return total count.

    Evidence is WITHHELD by default. The two text-scanning lanes
    (--scan-issue-body, --scan-commit-messages) were written under an explicit
    rule -- never echo matched content, because a GitHub Actions log on a public
    repo is world-readable and printing the match amplifies the very leak the
    gate just caught. That rule was never extended to this lane, which is the
    one `ci.yml` actually runs on every push. So at the exact moment the gate
    worked, it republished the secret to a public log.

    Category, file and line NUMBER are always printed -- enough to find and fix
    the line locally. `--show-evidence` restores the excerpt for a local
    terminal; CI must never pass it.
    """
    total = sum(len(f) for f in all_findings.values())

    print()
    print("=" * 65)
    print("  SECRET DETECTION — BLOCKED (check-public-repo-secrets.py)")
    print("=" * 65)
    print()

    for file_path in sorted(all_findings.keys()):
        findings = all_findings[file_path]
        try:
            rel_path = file_path.relative_to(scan_root)
        except ValueError:
            rel_path = file_path

        for finding in findings:
            # `message` interpolates the blocked term for BLOCKLIST findings, so
            # it is withheld alongside the line excerpt -- printing "Blocked term
            # from .secret-blocklist: <term>" leaks the term just as surely as
            # printing the source line does.
            headline = finding.message if show_evidence else finding.category
            print(f"[{finding.category}] {headline}")
            print(f"  File: {rel_path}")
            if show_evidence:
                display_line = finding.line[:80] + ("..." if len(finding.line) > 80 else "")
                print(f"  Line {finding.line_num}: {display_line}")
            else:
                print(f"  Line {finding.line_num}: [evidence withheld]")
            print(f"  Fix: {finding.fix}")
            print()

    if not show_evidence:
        print(
            "  Matched content withheld: this report may be written to a "
            "world-readable CI log. Re-run locally with --show-evidence to see "
            "the matched lines."
        )
        print()

    print("-" * 65)
    print(f"  {total} violation(s) found. Commit blocked.")
    print("  To suppress a false positive:")
    print("    - Add file:line to .secret-allowlist")
    print("    - Add inline comment: # secret-allow")
    print("-" * 65)
    print()

    return total


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def scan_text_content(
    text: str,
    source_label: str,
    blocklist: Set[str],
    allowlist: Set[str],
    pii_allowlist: Set[str],
    public_values: Set[str],
) -> List[Finding]:
    """Scan arbitrary text content (issue body, commit message, etc.) line-by-line."""
    findings: List[Finding] = []
    synthetic_path = Path(source_label)
    for line_num, line in enumerate(text.splitlines(), start=1):
        line_findings = scan_line(
            line, line_num, synthetic_path, blocklist, allowlist, pii_allowlist,
            public_values
        )
        findings.extend(line_findings)
    return findings


def fetch_issue_or_pr_body(repo: str, number: int) -> str:
    """Fetch issue/PR body + comments via gh CLI. Returns concatenated text.

    Failure semantics (load-bearing — keep precise):
    - Issue-body fetch is the only fetch whose failure means "no body": a
      CalledProcessError here = transferred/redirected/deleted/404 issue, so
      the caller skips the scan (an unfetchable body cannot leak from THIS
      repo). It propagates to the caller untouched.
    - Issue-body JSON unparseable despite gh exit 0 = the issue DOES exist but
      we cannot read a body that may carry a leak. Do NOT silently skip and do
      NOT traceback — raise RuntimeError so the caller fails loud (Fail Fast).
    - Comments fetch is BEST-EFFORT: a comments failure after the body was
      fetched must NOT discard the body (that would mask a body-resident
      leak). Warn loudly and scan the body we already have.
    """
    import json as _json
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{number}"],
        capture_output=True, text=True, check=True,
    )
    try:
        issue = _json.loads(result.stdout)
    except _json.JSONDecodeError as e:
        raise RuntimeError(
            f"gh returned malformed JSON for {repo}#{number} issue body: {e}"
        ) from e
    parts = [f"TITLE: {issue.get('title', '')}", f"BODY:\n{issue.get('body', '')}"]
    try:
        comments_result = subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/{number}/comments", "--paginate"],
            capture_output=True, text=True, check=True,
        )
        for comment in _json.loads(comments_result.stdout):
            parts.append(f"COMMENT {comment['id']}:\n{comment.get('body', '')}")
    except (subprocess.CalledProcessError, _json.JSONDecodeError) as e:
        print(
            f"WARNING: could not fetch comments for {repo}#{number} ({e}) — "
            f"scanning issue body only (comments dropped, NOT skipped)",
            file=sys.stderr,
        )
    return "\n\n".join(parts)


def fetch_commit_messages_since(since_sha: str) -> List[tuple[str, str]]:
    """Fetch commit messages from `since_sha` to HEAD. Returns list of (sha, message)."""
    result = subprocess.run(
        ["git", "log", f"{since_sha}..HEAD", "--format=%H%x00%B%x1e"],
        capture_output=True, text=True, check=True,
    )
    commits = []
    for entry in result.stdout.split("\x1e"):
        entry = entry.strip()
        if not entry:
            continue
        sha, _, body = entry.partition("\x00")
        if sha:
            commits.append((sha.strip(), body.strip()))
    return commits


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect secrets and sensitive data in public repos"
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Path to scan (file or directory). Ignored in --scan-issue-body / --scan-commit-messages modes.",
    )
    parser.add_argument(
        "--staged-only",
        action="store_true",
        help="Only scan git staged files (for pre-commit use)",
    )
    parser.add_argument(
        "--allowlist",
        help="Path to .secret-allowlist file",
    )
    parser.add_argument(
        "--scan-issue-body",
        action="store_true",
        help="Scan issue/PR body + comments via gh API. Requires --issue-number.",
    )
    parser.add_argument(
        "--issue-number",
        type=int,
        help="GitHub issue or PR number for --scan-issue-body mode.",
    )
    parser.add_argument(
        "--repo",
        help="Repository in owner/repo format (default: current repo). Used by --scan-issue-body.",
    )
    parser.add_argument(
        "--scan-commit-messages",
        action="store_true",
        help="Scan commit messages in the range <--since>..HEAD. Never prints matched content to stdout.",
    )
    parser.add_argument(
        "--since",
        help="Starting commit SHA for --scan-commit-messages mode (exclusive).",
    )
    parser.add_argument(
        "--allow-degraded-blocklist",
        action="store_true",
        help=(
            "Permit opaque .secret-blocklist tokens to go unexpanded when the "
            "hashes manifest is unreachable. Only correct in a published public "
            "mirror, which cannot hold the operator-private mapping by design. "
            "Anywhere else this hides a total collapse of token coverage."
        ),
    )
    parser.add_argument(
        "--show-evidence",
        action="store_true",
        help=(
            "Print the matched line excerpt and the matched term in the findings "
            "report. Safe in a local terminal; NEVER pass it in CI on a public "
            "repo, where the Actions log is world-readable and the report would "
            "republish the very content it just blocked."
        ),
    )
    parser.add_argument(
        "--require-public",
        action="store_true",
        help=(
            "Assert the target repo IS public: a missing .public-repo marker becomes "
            "a hard failure (exit 2) instead of a silent no-op. Use it from every "
            "caller that scans a known-public repo (its CI job, its pre-commit hook), "
            "so deleting or renaming the marker fails loudly rather than retiring the "
            "leak scan while CI stays green."
        ),
    )
    parser.add_argument(
        "--include-ignored",
        action="store_true",
        help=(
            "Scan files git ignores, instead of dropping them. Required to scan a "
            "BUILD OUTPUT: a generated tree (`public/`, `dist/`, `_site/`) is "
            "gitignored by definition, so the default filter drops every file in "
            "it and the coverage floor then fails the run rather than reporting a "
            "false clean. Use it ONLY with an explicit path argument naming the "
            "build directory. Do NOT combine it with a whole-repo scan on a "
            "developer clone, where it would reach the real `.env` the filter "
            "exists to skip."
        ),
    )
    parser.add_argument(
        "--enforce-on-private",
        action="store_true",
        help=(
            "Enforce blocklist scanning even on private repos (no .public-repo marker). "
            "Default behaviour: exit 0 on private repos (no-op). Used by private-repo "
            "pre-commit hooks that want defence-in-depth blocklist enforcement so "
            "literals do not accumulate locally before an accidental public mirror or "
            "fork. Does NOT enable --scan-commit-messages or --scan-issue-body "
            "amplification protections (those remain public-repo-only by design)."
        ),
    )

    args = parser.parse_args()
    start_time = time.monotonic()

    scan_path = Path(args.path)
    if not (args.scan_issue_body or args.scan_commit_messages) and not scan_path.exists():
        print(f"Error: Path does not exist: {args.path}", file=sys.stderr)
        return 1

    # Resolve repo root
    try:
        repo_root = get_repo_root()
    except (SST3UtilError, FileNotFoundError, subprocess.CalledProcessError):
        if args.staged_only:
            print("Error: --staged-only requires a git repository", file=sys.stderr)
            return 1
        repo_root = scan_path.resolve()

    # Public repo check — exit 0 if not public (no-op by design), unless
    # --enforce-on-private is set for private-repo defence-in-depth (falls
    # through to the FULL scan_file scan — all five categories, not only
    # the blocklist).
    # Note: --scan-commit-messages and --scan-issue-body remain public-only
    # because their threat model (GitHub Actions log amplification) does not
    # apply on private repos.
    if not is_public_repo(repo_root):
        if args.enforce_on_private and not (args.scan_commit_messages or args.scan_issue_body):
            pass  # fall through to the full scan_file scan (all categories)
        elif args.require_public:
            # The caller asserted this repo IS public. A missing marker then means
            # the marker was deleted, renamed, or never checked out -- and the
            # silent `return 0` below would retire the leak scan on a public repo
            # while every CI run stayed green. The caller knows the repo's status;
            # the gate cannot. So the caller declares it and this enforces it.
            print(
                f"[FAIL] [vacuous-gate] check-public-repo-secrets: --require-public "
                f"was passed but {repo_root}/.public-repo does not exist, so this "
                f"scan would have exited 0 without opening a single file. Restore "
                f"the marker, or drop --require-public from the caller if the repo "
                f"is genuinely private now.",
                file=sys.stderr,
            )
            return 2
        else:
            # Announce the no-op. Exiting 0 in silence is indistinguishable in a
            # CI log from a completed clean scan, which is how a gate that stopped
            # running goes unnoticed.
            print(
                f"[SKIP] check-public-repo-secrets: {repo_root} has no .public-repo "
                f"marker; nothing scanned. Pass --enforce-on-private for "
                f"defence-in-depth blocklist scanning on a private repo."
            )
            return 0

    # Load blocklist and allowlist. Expand opaque hashed tokens against the
    # canonical-only hashes manifest (#497 A.2.3) — when the operator-private
    # mapping is present (dev-machine clone of dotfiles), the scanner sees both
    # the tokens AND their underlying literals, so substring scans catch real
    # business identifiers in mirror content. In the public-mirror clone where
    # the mapping is absent, the scanner falls back to verbatim token matching.
    blocklist = load_file_set(repo_root / ".secret-blocklist")
    hashes_path = _resolve_hashes_path(repo_root)
    # Expand FIRST, then gate on what the expansion actually achieved. The
    # earlier order gated on `hashes_path is None` before expanding, which could
    # only see a missing file and passed a manifest that was present but useless.
    blocklist, unexpanded_tokens = _expand_hashed_tokens(blocklist, hashes_path)
    if unexpanded_tokens:
        # Degraded mode used to be silent: tokens stayed unexpanded, every
        # literal they cover went unmatched, and the run still printed
        # `PASS: No secrets detected`. On this repo that was not a corner case
        # but the ONLY mode -- the manifest was looked for at
        # `<repo>/SST3/scripts/`, a directory that exists in dotfiles and in no
        # mirror -- so the whole token section of .secret-blocklist had been
        # inert since the day it was written. A gate whose coverage silently
        # collapses to zero is the exact class this Issue exists to close.
        why = (
            "the hashes manifest was not found"
            if hashes_path is None
            else f"{hashes_path} does not map them (unreadable, not valid JSON, "
            "carrying no `tokens` object, or simply not covering these tokens)"
        )
        if not args.allow_degraded_blocklist:
            print(
                "[FAIL] [vacuous-gate] check-public-repo-secrets: "
                f"{len(unexpanded_tokens)} opaque token(s) in "
                f"{repo_root}/.secret-blocklist could not be expanded because "
                f"{why}. Every literal those tokens cover is therefore UNSCANNED "
                "and a clean result here would not be evidence. Set "
                "SST3_BLOCKLIST_HASHES to the manifest path, or pass "
                "--allow-degraded-blocklist if this clone genuinely cannot hold "
                "the mapping (a published public mirror), which downgrades token "
                "coverage to verbatim-reference matching only.",
                file=sys.stderr,
            )
            return 2
        print(
            f"[DEGRADED] check-public-repo-secrets: {len(unexpanded_tokens)} "
            f"opaque token(s) unexpanded ({why}); token coverage for those is "
            "verbatim-reference matching only."
        )

    allowlist_path = Path(args.allowlist) if args.allowlist else repo_root / ".secret-allowlist"
    allowlist = load_file_set(allowlist_path)
    pii_allowlist = load_file_set(repo_root / ".secret-pii-allowlist")
    # Literals this repo publishes on purpose, suppressed WHEREVER they appear.
    # Needed for a build-output scan: a public identifier is rendered into every
    # page, so file:line suppression would need hundreds of entries and would go
    # stale on the next build. See is_public_value.
    public_values = load_file_set(repo_root / ".secret-public-values")

    # --scan-issue-body mode: fetch issue body + comments, scan text content.
    # Design rule: NEVER print matched content to stdout (would amplify leak
    # publicly via GitHub Actions logs). Print only line numbers + categories.
    if args.scan_issue_body:
        if not args.issue_number:
            print("Error: --scan-issue-body requires --issue-number", file=sys.stderr)
            return 1
        repo = args.repo
        if not repo:
            try:
                r = subprocess.run(
                    ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                    capture_output=True, text=True, check=True,
                )
                repo = r.stdout.strip()
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                print(f"Error: Could not resolve repo (use --repo): {e}", file=sys.stderr)
                return 1
        try:
            body_text = fetch_issue_or_pr_body(repo, args.issue_number)
        except subprocess.CalledProcessError as e:
            # Reaching here means the ISSUE-BODY fetch itself returned non-zero
            # (comments-fetch failures are handled inside fetch_issue_or_pr_body
            # and never propagate here). The real cause is a transferred/
            # redirected/deleted issue (e.g. transferred to a private sibling
            # repo the repo-scoped GITHUB_TOKEN cannot read) or a 404 —
            # genuinely NO body was fetched. Hard-failing CI here is a false
            # positive that turns the workflow permanently red on every
            # transferred-issue edit. Skip loudly (not silently): no body was
            # fetched, so the disjoint real-secret detection path below is
            # never reached — this cannot mask a genuine leak.
            print(
                f"WARNING: could not fetch {repo}#{args.issue_number} "
                f"(transferred/redirected/deleted/404) — skipping issue/PR-body "
                f"secret scan for this ref: {e}",
                file=sys.stderr,
            )
            return 0
        except RuntimeError as e:
            # gh exited 0 but the issue body JSON was unparseable. The issue
            # EXISTS (not a transfer) and may carry a leak we cannot read —
            # do NOT skip, do NOT traceback. Fail loud (Fail Fast).
            print(f"Error: {e}", file=sys.stderr)
            return 1
        except FileNotFoundError as e:
            # gh binary genuinely absent => broken environment, not a
            # transferred issue. Fail loud (Fail Fast); do NOT skip.
            print(f"Error: gh CLI not available, cannot scan issue #{args.issue_number}: {e}", file=sys.stderr)
            return 1
        findings = scan_text_content(
            body_text, f"{repo}#{args.issue_number}", blocklist, allowlist, pii_allowlist,
            public_values
        )
        if findings:
            # Print line numbers + categories ONLY; never echo the matched content.
            print(f"FAIL: {len(findings)} secret-blocklist match(es) in {repo}#{args.issue_number}")
            for f in findings:
                print(f"  line {f.line_num} category={f.category}: {f.message}")
            print("Evidence withheld from this log to prevent public amplification.")
            return 1
        print(f"PASS: No secrets detected in {repo}#{args.issue_number}")
        return 0

    # --scan-commit-messages mode: fetch messages in range, scan each one.
    if args.scan_commit_messages:
        if not args.since:
            print("Error: --scan-commit-messages requires --since <sha>", file=sys.stderr)
            return 1
        try:
            commits = fetch_commit_messages_since(args.since)
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            print(f"Error: Could not fetch commits since {args.since}: {e}", file=sys.stderr)
            return 1
        total_findings = 0
        for sha, message in commits:
            findings = scan_text_content(
                message, sha, blocklist, allowlist, pii_allowlist, public_values
            )
            if findings:
                total_findings += len(findings)
                print(f"FAIL: {len(findings)} secret-blocklist match(es) in commit {sha[:12]}")
                for f in findings:
                    print(f"  line {f.line_num} category={f.category}: {f.message}")
        if total_findings > 0:
            print("Evidence withheld from this log to prevent public amplification.")
            return 1
        print(f"PASS: No secrets detected in {len(commits)} commit message(s) since {args.since[:12]}")
        return 0

    # Collect what to scan: (display path, content bytes or None = read the file).
    #
    # IGNORE_PATTERNS prunes only a FILESYSTEM walk, where a developer clone
    # holds untracked dependency and build trees (node_modules/, .venv/,
    # dist/). It used to be applied to the staged list and to an explicitly
    # named file too, so a secret committed under archive/, build/, dist/ or
    # venv/ passed with "1 file(s) scanned" (#577 escalation, class C4
    # walk-then-filter). What a commit stages, what a caller names, and what
    # git tracks all go public, so none of them is ever pruned.
    targets: List[Tuple[Path, Optional[bytes]]]
    if args.staged_only:
        try:
            staged = get_staged_blobs(repo_root)
        except (subprocess.CalledProcessError, FileNotFoundError, RuntimeError, ValueError) as e:
            print(f"Error: Could not read the staged content: {e}", file=sys.stderr)
            return 1
        targets = [(repo_root / p, data) for p, data in staged if should_scan_file(Path(p))]
    elif scan_path.is_file():
        targets = [(scan_path, None)]
    else:
        # Walked inline rather than through the shared sst3_utils
        # `collect_source_files`: that helper's matching contract is an
        # extension suffix list, which cannot express "this exact filename"
        # (`.npmrc`, `Dockerfile`) or "this family" (`.env.local`). Routing
        # membership through should_scan_file is what keeps the directory walk
        # and the staged-only path on ONE matcher. `should_ignore_path` — the
        # other shared helper — is still reused as-is.
        tracked = _git_tracked_abspaths(scan_path)
        files_to_scan = sorted(
            p for p in scan_path.rglob("*")
            if p.is_file()
            and should_scan_file(p)
            and (not should_ignore_path(p, IGNORE_PATTERNS)
                 or os.path.abspath(p) in tracked)
        )
        # Drop files git already ignores. A directory scan walks the FILESYSTEM,
        # so on a developer clone it reaches the very files secrets are supposed
        # to live in — a gitignored `.env`, or the `.env` symlink a worktree
        # gets from setup-worktree-deps.sh. Those are not public-repo leaks, and
        # firing on them is how a gate teaches people to bypass it. CI scans a
        # fresh checkout where none exist, so this narrows nothing there.
        # Not a git repo, or no git: keep every candidate. Over-reporting is the
        # safe direction for a secret scanner; silently scanning less is not.
        #
        # --include-ignored turns the filter off for the one case where it is
        # wrong: a BUILD OUTPUT. A generated tree is gitignored by definition, so
        # the filter drops all of it and the coverage floor below then fails the
        # run. That failure is correct -- it refuses to call an empty scan clean --
        # but it also means the rendered artefact, the thing actually served to
        # the public, cannot be scanned at all without this flag.
        if not args.include_ignored:
            files_to_scan = _drop_git_ignored(scan_path, files_to_scan)
        targets = [(p, None) for p in files_to_scan]

    # Scan. An unreadable target is counted and fails the run below: it used to
    # count as binary (or print a warning) and pass.
    all_findings: Dict[Path, List[Finding]] = {}
    unreadable: List[str] = []
    scanned = 0
    for file_path, data in targets:
        if is_file_exempt(file_path):
            continue
        try:
            if data is None:
                findings = scan_file(file_path, blocklist, allowlist, pii_allowlist, public_values)
            else:
                findings = scan_text(file_path, decode_for_scan(data), blocklist,
                                     allowlist, pii_allowlist, public_values)
        except OSError as e:
            unreadable.append(f"{file_path}: {e.strerror or e}")
            continue
        scanned += 1
        if findings:
            all_findings[file_path] = findings

    duration_ms = int((time.monotonic() - start_time) * 1000)

    # Report
    if unreadable:
        print(f"[FAIL] [could-not-scan] check-public-repo-secrets: {len(unreadable)} "
              f"file(s) could not be read, so they were not scanned:", file=sys.stderr)
        for entry in unreadable:
            print(f"  {entry}", file=sys.stderr)
        log_event("check-public-repo-secrets", "unreadable_files", level="error",
                  files_scanned=scanned, unreadable=len(unreadable), duration_ms=duration_ms)
    if all_findings:
        total = report_findings(all_findings, scan_path.resolve(), args.show_evidence)
        log_event(
            "check-public-repo-secrets",
            "violations_found",
            level="error",
            files_scanned=scanned,
            violations=total,
            duration_ms=duration_ms,
        )
        return 1
    if unreadable:
        return 2

    # COVERAGE FLOOR. Everything above asserts an absence, and an absence over an
    # empty file set is true for free. A whole-repo scan that collected nothing
    # means the walk broke -- wrong scan_path, a rename that emptied the tree, an
    # over-broad ignore rule -- not that the repo is clean.
    #
    # --staged-only is deliberately exempt: a commit touching only files this gate
    # does not scan (an image, a lockfile) legitimately stages zero candidates, and
    # failing there would train people to bypass the hook, which costs more than it
    # buys. The count is still printed so the zero is visible rather than implied.
    if not targets and not args.staged_only:
        print(
            f"[FAIL] [vacuous-gate] check-public-repo-secrets: collected 0 scannable "
            f"files under {scan_path.resolve()}, so 'no secrets detected' was true of "
            f"nothing. Check the path argument and that the tree is fully checked out.",
            file=sys.stderr,
        )
        return 2

    print(f"PASS: No secrets detected ({scanned} file(s) scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
