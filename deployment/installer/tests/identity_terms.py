"""Install-identity check for the installer tests (core task 01a14b9e stage 5).

The installer's forbidden-word tests must not spell the install and personal
identity they forbid (an operator's org, domains, hosts, people): a test that
spells a term is itself the trace the guard exists to remove. So this module
uses the SAME digest rule as core's Elixir guard,
apps/platform/test/support/install_identity_scanner.ex: the denylist is the
sha256 hex digests of lowercase terms, read from that file's `@digests`
block, so there is one list and the two checks cannot drift.

Digests keep the terms out of grep and casual reading. They do not stop
someone who already guesses a term from confirming it.

What counts as a hit, as in the Elixir scanner:
  * tokens: every [A-Za-z0-9]+ run, split at camelCase boundaries and
    lowercased; whole tokens only;
  * compounds: every maximal [a-z0-9]+([.-][a-z0-9]+)+ run of the lowercased
    text (taken with "/" as a separator and again with "/" read as "."), and
    each of its dot-suffixes;
  * the literal 192.168/16 address regex.
The Elixir scanner's published app-store id exemption is not needed here:
installer output never carries an app-store id.
"""

import hashlib
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SCANNER = os.path.join(REPO, "apps", "platform", "test", "support", "install_identity_scanner.ex")

_TOKEN = re.compile(r"[A-Za-z0-9]+")
_CAMEL = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+[0-9]*")
_COMPOUND = re.compile(r"[a-z0-9]+(?:[.\-][a-z0-9]+)+")
_LAN = re.compile(r"\b192\.168\.\d{1,3}\.\d{1,3}\b")


def load_digests(path=SCANNER):
    """The sha256 hex digests in the Elixir scanner's `@digests` block."""
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    block = re.search(r"@digests MapSet\.new\(\[(.*?)\]\)", source, re.DOTALL)
    if block is None:
        raise AssertionError(f"no @digests block in {path}")
    digests = frozenset(re.findall(r'"([0-9a-f]{64})"', block.group(1)))
    if not digests:
        raise AssertionError(f"@digests block in {path} holds no digest")
    return digests


DIGESTS = load_digests()


def planted_term(path=SCANNER):
    """A real denylisted term to plant in positive controls, taken from the
    shipped Android package id the Elixir scanner lists LITERALLY in
    `@published_ids` (its org label), so no test file spells one."""
    with open(path, encoding="utf-8") as handle:
        match = re.search(r'\{"com\.([a-z]+)\.[a-z]+", :namespace', handle.read())
    if match is None or not denied(match.group(1)):
        raise AssertionError(f"no denylisted org label in the published ids of {path}")
    return match.group(1)


def digest(term):
    return hashlib.sha256(term.encode("utf-8")).hexdigest()


def denied(candidate):
    return digest(candidate) in DIGESTS


def identity_hits(text):
    """Every identity hit in `text`, as the matched strings in text order."""
    spans = set()
    for run in _TOKEN.finditer(text):
        for piece in _CAMEL.finditer(run.group()):
            start = run.start() + piece.start()
            if denied(piece.group().lower()):
                spans.add((start, len(piece.group())))
    low = text.lower()
    # Taken twice, as in the Elixir scanner: once with "/" as a separator and
    # once with "/" read as "." (paths and package names).
    for form in (low, low.replace("/", ".")):
        for run in _COMPOUND.finditer(form):
            word = run.group()
            starts = [0] + [i + 1 for i, ch in enumerate(word) if ch == "."]
            for offset in starts:
                if denied(word[offset:]):
                    spans.add((run.start() + offset, len(word) - offset))
    for match in _LAN.finditer(text):
        spans.add((match.start(), match.end() - match.start()))
    return [text[start : start + length] for start, length in sorted(spans)]
