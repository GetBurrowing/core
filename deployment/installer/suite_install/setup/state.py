"""The install directory: its manifest, its non-secret state and its secrets file.

Layout of ``<install dir>`` (default ``~/suite/<install.name>/``):

- ``install.toml``   the effective manifest (written by ``setup init``).
- ``state.json``     NON-SECRET progress: step states, ids (zone, account,
                     tunnel, pocket-id user), hostnames and input REFERENCES
                     (``@/path``, ``env:VAR``, ``keychain:item``). Never a value.
- ``secrets.env``    0600, written by the renderer, plus ``TUNNEL_TOKEN`` from
                     the ``tunnel`` step.
- the rest of the render (compose.yaml, Caddyfile, ...), and ``.setup/``
  (0700) for short-lived staging files.

The directory is refused inside a git work tree, for the same reason the
renderer refuses one: a rendered secret must never be one ``git add`` away.
"""

import datetime
import json
import os
import tempfile

from .. import envcompat
from .. import render as render_mod
from ..manifest import ManifestLoadError, load
from ..validate import validate

STATE_FILE = "state.json"
MANIFEST_FILE = "install.toml"
SECRETS_FILE = "secrets.env"
SETUP_DIR = ".setup"
STATE_VERSION = 1


class SetupError(Exception):
    """A step failure with a stable ``code`` and a human ``remediation``.

    ``message`` and ``remediation`` must never carry a secret value.
    """

    def __init__(self, code, message, remediation=None, exit_code=1, outputs=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation
        self.exit_code = exit_code
        self.outputs = outputs or {}


def now():
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_root():
    return os.path.join(os.path.expanduser("~"), "suite")


def resolve_dir(explicit=None, environ=None):
    """``--dir``, else ``$BURROW_INSTALL_DIR`` (legacy ``$SUITE_INSTALL_DIR``),
    else the single install under ~/suite."""
    environ = os.environ if environ is None else environ
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    env_dir = envcompat.get("BURROW_INSTALL_DIR", "SUITE_INSTALL_DIR", environ=environ)
    if env_dir:
        return os.path.abspath(os.path.expanduser(env_dir))
    root = default_root()
    found = []
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            if os.path.exists(os.path.join(root, name, MANIFEST_FILE)):
                found.append(os.path.join(root, name))
    if len(found) == 1:
        return found[0]
    if not found:
        raise SetupError(
            "install_dir_missing",
            f"no install under {root}",
            "run `setup init --from <manifest> --domain <hostname>` first",
            exit_code=2,
        )
    raise SetupError(
        "install_dir_ambiguous",
        f"{len(found)} installs under {root}",
        "pass --dir <install dir> (or set BURROW_INSTALL_DIR)",
        exit_code=2,
    )


def check_dir_allowed(path):
    if render_mod.inside_git_worktree(path):
        raise SetupError(
            "install_dir_inside_git_worktree",
            f"{path} is inside a git work tree",
            "pick an install directory outside any repository (the default is ~/suite/<name>)",
            exit_code=2,
        )


# ---------------------------------------------------------------------------
# TOML writing. The stdlib reads TOML (tomllib) but cannot write it; manifests
# are plain tables of strings/bools/ints plus one array of tables, so a small
# emitter is enough. ``write_manifest`` re-reads what it wrote and refuses a
# mismatch, so an emitter bug cannot silently change a knob.
# ---------------------------------------------------------------------------


def _toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int | float):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list) and all(not isinstance(v, dict) for v in value):
        return "[" + ", ".join(_toml_value(v) for v in value) + "]"
    raise TypeError(f"cannot write {type(value).__name__} to TOML")


def _toml_key(key):
    if key and all(c.isalnum() or c in "-_" for c in key):
        return key
    return json.dumps(key)


def dumps_toml(data, header=None):
    lines = [f"# {line}" if line else "#" for line in (header or [])]
    if lines:
        lines.append("")

    def scalars(table):
        return [
            (k, v)
            for k, v in table.items()
            if not isinstance(v, dict)
            and not (isinstance(v, list) and v and all(isinstance(i, dict) for i in v))
        ]

    def emit(table, path):
        for key, value in scalars(table):
            lines.append(f"{_toml_key(key)} = {_toml_value(value)}")
        for key, value in table.items():
            sub = path + [_toml_key(key)]
            if isinstance(value, dict):
                lines.append("")
                lines.append(f"[{'.'.join(sub)}]")
                emit(value, sub)
            elif isinstance(value, list) and value and all(isinstance(i, dict) for i in value):
                for item in value:
                    lines.append("")
                    lines.append(f"[[{'.'.join(sub)}]]")
                    emit(item, sub)

    emit(data, [])
    return "\n".join(lines).strip("\n") + "\n"


def _atomic_write(path, text, mode):
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class Install:
    """One install directory."""

    def __init__(self, path):
        self.path = path

    # -- paths ------------------------------------------------------------
    def file(self, *parts):
        return os.path.join(self.path, *parts)

    @property
    def manifest_path(self):
        return self.file(MANIFEST_FILE)

    @property
    def secrets_path(self):
        return self.file(SECRETS_FILE)

    def exists(self):
        return os.path.exists(self.manifest_path)

    def setup_dir(self):
        path = self.file(SETUP_DIR)
        os.makedirs(path, mode=0o700, exist_ok=True)
        os.chmod(path, 0o700)
        return path

    # -- manifest ---------------------------------------------------------
    def raw_manifest(self):
        try:
            return load(self.manifest_path)
        except ManifestLoadError as exc:
            raise SetupError(
                exc.code,
                f"{self.manifest_path}: {exc.message}",
                "re-run `setup init --from <manifest>`",
            ) from exc

    def manifest(self):
        """The normalized manifest; a manifest that stopped validating is an error."""
        errors, normalized = validate(self.raw_manifest())
        if errors:
            raise SetupError(
                "manifest_invalid",
                "; ".join(e.line() for e in errors),
                "fix it with `setup init` flags (never by hand)",
            )
        return normalized

    def write_manifest(self, raw, header=None):
        text = dumps_toml(raw, header)
        os.makedirs(self.path, mode=0o700, exist_ok=True)
        _atomic_write(self.manifest_path, text, 0o644)
        if load(self.manifest_path) != raw:
            raise SetupError(
                "manifest_write_mismatch",
                "install.toml did not read back equal to what was written",
                "report this as a bug; the previous install.toml was replaced",
            )

    # -- state ------------------------------------------------------------
    def load_state(self):
        path = self.file(STATE_FILE)
        if not os.path.exists(path):
            return {"version": STATE_VERSION, "steps": {}, "inputs": {}, "ids": {}}
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
        state.setdefault("steps", {})
        state.setdefault("inputs", {})
        state.setdefault("ids", {})
        return state

    def save_state(self, state):
        os.makedirs(self.path, mode=0o700, exist_ok=True)
        _atomic_write(
            self.file(STATE_FILE), json.dumps(state, indent=2, sort_keys=True) + "\n", 0o600
        )

    # -- secrets.env ------------------------------------------------------
    def read_secret(self, name):
        from ..secrets import SecretsError, parse_env_file

        if not os.path.exists(self.secrets_path):
            return None
        try:
            return parse_env_file(self.secrets_path).get(name)
        except SecretsError as exc:
            raise SetupError(exc.code, f"{exc.path}: {exc.message}", None) from exc

    def upsert_secret(self, name, value):
        """Set ``name=value`` in secrets.env (created 0600), keeping every other line."""
        lines = []
        if os.path.exists(self.secrets_path):
            with open(self.secrets_path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        out, replaced = [], False
        for line in lines:
            if line.split("=", 1)[0].strip() == name and not line.lstrip().startswith("#"):
                if not replaced:
                    out.append(f"{name}={value}")
                replaced = True
                continue
            out.append(line)
        if not replaced:
            out.append(f"{name}={value}")
        os.makedirs(self.path, mode=0o700, exist_ok=True)
        _atomic_write(self.secrets_path, "\n".join(out) + "\n", 0o600)
