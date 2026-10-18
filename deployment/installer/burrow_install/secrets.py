"""Secret values for a render: generated, reused or customer-supplied.

Two classes (ADR 0053):

- GENERATED at render time with Python ``secrets`` (``registry.SECRETS``).
  Never committed, never printed. ``--reuse-secrets <secrets.env>`` keeps the
  value a previous render wrote, so a re-render after a knob flip does not
  rotate POSTGRES_PASSWORD under an initialised volume. Only the secrets the
  new render needs are kept; those of services now off are dropped.
- CUSTOMER-SUPPLIED (model API keys and other ``*_ref`` fields) come only from
  ``--customer-secrets <file>`` and are never generated.

Env files here are ``NAME=value`` lines; ``#`` comments and blank lines are
ignored. Values are written unquoted, so generators only emit characters that
need no quoting.
"""

import re

_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_MARKER_RE = re.compile(r"\{(secret|customer):([A-Za-z0-9_]+)\}")
_UNSAFE_VALUE_RE = re.compile(r"[\s\"'$`\\#]")


class SecretsError(Exception):
    def __init__(self, code, path, message):
        super().__init__(message)
        self.code = code
        self.path = path
        self.message = message


def parse_env_file(path):
    """Return ``{name: value}``. Raises SecretsError on a malformed line."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        raise SecretsError("unreadable_file", path, exc.strerror or str(exc)) from exc
    values = {}
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, sep, value = stripped.partition("=")
        if not sep or not _NAME_RE.match(name):
            # Never echo the line: it may hold a value.
            raise SecretsError("invalid_env_file", f"{path}:{number}", "expected NAME=value")
        values[name] = value
    return values


def markers(text):
    """``[(kind, name)]`` for every ``{secret:..}`` / ``{customer:..}`` in text."""
    return _MARKER_RE.findall(text)


def substitute(text, generated, customer):
    def repl(match):
        kind, name = match.groups()
        return generated[name] if kind == "secret" else customer[name]

    return _MARKER_RE.sub(repl, text)


def resolve_generated(needed, reuse):
    """Return ``{name: value}`` for every registry Secret in ``needed``.

    ``reuse`` is a parsed secrets.env or None. A reused value is kept only
    for a secret this render needs.
    """
    values = {}
    for secret in needed:
        if reuse is not None and reuse.get(secret.name):
            values[secret.name] = reuse[secret.name]
        else:
            values[secret.name] = secret.generate()
    return values


def resolve_customer(refs, supplied, generated_names):
    """Return ``{ref: value}`` for every ref the manifest names.

    ``refs`` maps ref name -> manifest path (for error messages).
    """
    values = {}
    for ref, where in sorted(refs.items()):
        if ref in generated_names:
            raise SecretsError(
                "customer_secret_conflict",
                where,
                f"{ref} is a name the renderer generates; pick another ref name",
            )
        if supplied is None or not supplied.get(ref):
            raise SecretsError(
                "customer_secret_missing",
                where,
                f"{ref} must be supplied in --customer-secrets (it is never generated)",
            )
        value = supplied[ref]
        if _UNSAFE_VALUE_RE.search(value):
            raise SecretsError(
                "invalid_value",
                where,
                f"the value of {ref} contains whitespace, a quote, '$', '#' or a backslash",
            )
        values[ref] = value
    return values


def placeholder(name):
    return f"<secret:{name}>"


def redact(text, values):
    """Replace every secret value in ``text`` with ``<secret:NAME>``.

    ``values`` maps name -> value. Longer values are replaced first so a value
    that contains another cannot leave a fragment behind.
    """
    for name, value in sorted(values.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        if value:
            text = text.replace(value, placeholder(name))
    return text
