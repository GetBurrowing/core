"""Vendor support access on the host (core task 01a1b362 stage 3, ADR 0059).

The manifest's optional ``[support]`` block, passed by the vendor's support
system (never rendered by default), turns on two things:

1. core-platform's env (``core_env``): SUPPORT_ACCESS_DEFAULT,
   SUPPORT_VENDOR_NAME, SUPPORT_VENDOR_KEYS and INSTALL_ID. None is a secret.
2. With ``ssh_user_ca`` set, on target single-host, the host pieces
   (``host_files``): the CA public key, an sshd drop-in that trusts it for the
   ``burrow-support`` user only, the principals command and the repair shell,
   plus ``bin/burrow-support-setup`` that creates the users, sudoers entry and
   state directory, and installs the drop-in only if ``sshd -t`` passes. The
   state directory is bind-mounted into core-platform (``CORE_MOUNT``).

Absent, nothing here is rendered. Key custody: the installer handles PUBLIC
keys only; it never generates, reads or stores either private key.

``enable_host`` is ``burrow_install support enable-host``: the same pieces
rendered onto a RUNNING install (no cloud-init, no full install).
"""

import base64
import binascii
import os
import re
import struct

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(HERE, "support")

SUPPORT_USER = "burrow-support"
CHECK_USER = "burrow-support-check"
CA_PATH = "/etc/ssh/burrow-support-ca.pub"
DROPIN_NAME = "60-burrow-support.conf"
DROPIN_PATH = f"/etc/ssh/sshd_config.d/{DROPIN_NAME}"
# Relative to the install root: staged, installed by burrow-support-setup only
# after `sshd -t` passes.
DROPIN_STAGED = f"support/{DROPIN_NAME}"
PRINCIPALS_BIN = "bin/burrow-support-principals"
SHELL_BIN = "bin/burrow-support-shell"
SETUP_BIN = "bin/burrow-support-setup"
# Written gz+b64 in cloud-init user-data (templates.user_data), for the size cap.
COMPRESSED_FILES = (PRINCIPALS_BIN, SHELL_BIN, SETUP_BIN)
STATE_DIR = "/var/lib/burrow-support"
# Read-write, same path inside core-platform (core's defaults for
# SUPPORT_ACCESS_STATE_PATH and SUPPORT_SHELL_EVENTS_PATH live under it).
CORE_MOUNT = (STATE_DIR, STATE_DIR, False)

ENV_NAMES = ("INSTALL_ID", "SUPPORT_ACCESS_DEFAULT", "SUPPORT_VENDOR_KEYS", "SUPPORT_VENDOR_NAME")

KID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
INSTALL_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_B64_RE = re.compile(r"^[A-Za-z0-9+/_-]+={0,2}$")
_CA_LINE_RE = re.compile(r"^(\S+) ([A-Za-z0-9+/]+={0,2})(?: ([ -~]*))?$")
# A rollover holds the old and the new CA line; never more.
MAX_CA_LINES = 2


def block(manifest):
    """The normalized ``[support]`` block, or None when the manifest has none."""
    return manifest.get("support")


def host_enabled(manifest):
    """True when the host pieces render: a block with ``ssh_user_ca``, on single-host."""
    sup = block(manifest)
    return (
        sup is not None
        and sup.get("ssh_user_ca") is not None
        and manifest["install"]["target"] == "single-host"
    )


# ---------------------------------------------------------------------------
# Validation helpers (validate.py reports the errors).
# ---------------------------------------------------------------------------


def grant_key_bytes(value):
    """The 32 raw bytes of an Ed25519 public key in base64 or base64url, or None.

    Accepts exactly what core's ``SupportAccess.Config.parse_keys`` accepts.
    """
    if not isinstance(value, str) or not _B64_RE.match(value):
        return None
    if any(c in value for c in "-_") and any(c in value for c in "+/"):
        return None
    trimmed = value.rstrip("=")
    padded = trimmed + "=" * (-len(trimmed) % 4)
    try:
        if "-" in trimmed or "_" in trimmed:
            raw = base64.urlsafe_b64decode(padded)
        else:
            raw = base64.b64decode(padded, validate=True)
    except (binascii.Error, ValueError):
        return None
    return raw if len(raw) == 32 else None


def _ssh_string(blob, offset):
    if offset + 4 > len(blob):
        raise ValueError("truncated")
    (length,) = struct.unpack(">I", blob[offset : offset + 4])
    end = offset + 4 + length
    if end > len(blob):
        raise ValueError("truncated")
    return blob[offset + 4 : end], end


def ca_line_problem(line):
    """None for one ``ssh-ed25519 <base64> [comment]`` line, else why not."""
    match = _CA_LINE_RE.match(line)
    if not match:
        return "is not an OpenSSH public key line"
    key_type, b64 = match.group(1), match.group(2)
    if key_type != "ssh-ed25519":
        return f"{key_type} is refused: the support CA must be ssh-ed25519"
    try:
        blob = base64.b64decode(b64, validate=True)
        inner_type, offset = _ssh_string(blob, 0)
        key, offset = _ssh_string(blob, offset)
    except (binascii.Error, ValueError):
        return "its base64 is not an ssh-ed25519 public key"
    if inner_type != b"ssh-ed25519" or len(key) != 32 or offset != len(blob):
        return "its base64 is not an ssh-ed25519 public key"
    return None


def ca_lines(value):
    return value.split("\n")


# ---------------------------------------------------------------------------
# Env (registry._core_env).
# ---------------------------------------------------------------------------


def install_id(manifest):
    sup = block(manifest)
    return sup.get("install_id") or manifest["install"]["name"]


def vendor_keys_env(keys):
    """Core's SUPPORT_VENDOR_KEYS: ``kid:base64`` pairs joined by commas."""
    return ",".join(f"{k['kid']}:{k['public_key']}" for k in keys)


def core_env(manifest):
    """{env name: value} for core-platform; {} without a ``[support]`` block."""
    sup = block(manifest)
    if sup is None:
        return {}
    env = {
        "INSTALL_ID": install_id(manifest),
        "SUPPORT_ACCESS_DEFAULT": sup["access_default"],
    }
    if sup["vendor_grant_keys"]:
        env["SUPPORT_VENDOR_KEYS"] = vendor_keys_env(sup["vendor_grant_keys"])
    if sup["vendor_name"] is not None:
        env["SUPPORT_VENDOR_NAME"] = sup["vendor_name"]
    return env


# ---------------------------------------------------------------------------
# Host files.
# ---------------------------------------------------------------------------


def _read_script(name):
    with open(os.path.join(SCRIPTS, name), encoding="utf-8") as handle:
        return handle.read()


def dropin(install_root):
    """The sshd drop-in. Everything sits under ``Match User burrow-support``.

    TrustedUserCAKeys is INSIDE the Match block on purpose: trusted globally,
    the CA would admit a certificate naming any other user (root included) as
    its principal, with no principals command and no switch in the way,
    because sshd's default for a user without AuthorizedPrincipals* is "the
    user name must be a certificate principal".
    """
    bin_dir = f"{install_root}/bin"
    lines = [
        "# Vendor support repair access (ADR 0059). Rendered by burrow_install; do not edit.",
        "# Installed by bin/burrow-support-setup only after `sshd -t` passes.",
        f"Match User {SUPPORT_USER}",
        f"    TrustedUserCAKeys {CA_PATH}",
        f"    AuthorizedPrincipalsCommand {bin_dir}/burrow-support-principals %u %i",
        f"    AuthorizedPrincipalsCommandUser {CHECK_USER}",
        "    AuthorizedKeysFile none",
        "    PasswordAuthentication no",
        "    KbdInteractiveAuthentication no",
        "    AllowAgentForwarding no",
        "    AllowTcpForwarding no",
        "    AllowStreamLocalForwarding no",
        "    X11Forwarding no",
        "    PermitTTY yes",
        "    ExposeAuthInfo yes",
        f"    ForceCommand {bin_dir}/burrow-support-shell",
        # Back to global context for whatever sshd reads after this file.
        "Match all",
    ]
    return "\n".join(lines) + "\n"


def ca_file(manifest):
    return "\n".join(ca_lines(block(manifest)["ssh_user_ca"])) + "\n"


def host_files(manifest, install_root, file_mode, exec_mode):
    """{path (absolute, or relative to the install root): (text, mode)}, or {}."""
    if not host_enabled(manifest):
        return {}
    return {
        CA_PATH: (ca_file(manifest), file_mode),
        DROPIN_STAGED: (dropin(install_root), file_mode),
        PRINCIPALS_BIN: (_read_script("burrow-support-principals"), exec_mode),
        SHELL_BIN: (_read_script("burrow-support-shell"), exec_mode),
        SETUP_BIN: (_read_script("burrow-support-setup.sh"), exec_mode),
    }


# ---------------------------------------------------------------------------
# compose.yaml: the core-platform env lines and the state mount, on a live file.
# ---------------------------------------------------------------------------


class PatchError(Exception):
    pass


def _block_end(lines, start, indent):
    """Index after the last line of the block opened at ``start``."""
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and len(line) - len(line.lstrip(" ")) <= indent:
            break
        end += 1
    return end


def _find(lines, start, end, text):
    for i in range(start, end):
        if lines[i] == text:
            return i
    return None


def patch_compose(text, env, mount, scalar, key):
    """Return ``text`` (a compose.yaml this renderer wrote) with core-platform's
    ``env`` lines set (support names not in ``env`` removed) and ``mount`` in
    its volumes (or removed, when ``mount`` is None). Nothing else changes.

    ``scalar`` / ``key``: the renderer's YAML scalar and key writers, so the
    result is byte-identical to a fresh render with the same manifest.
    """
    lines = text.split("\n")
    services = _find(lines, 0, len(lines), "services:")
    if services is None:
        raise PatchError("no services: mapping")
    svc = _find(lines, services, len(lines), "  core-platform:")
    if svc is None:
        raise PatchError("no core-platform service")
    svc_end = _block_end(lines, svc, 2)

    env_at = _find(lines, svc, svc_end, "    environment:")
    if env_at is None:
        raise PatchError("core-platform has no environment: mapping")
    env_end = _block_end(lines, env_at, 4)
    entries = {}
    for line in lines[env_at + 1 : env_end]:
        name, sep, _value = line.strip().partition(": ")
        if not sep:
            raise PatchError(f"unexpected environment line {line!r}")
        entries[name.strip('"')] = line
    for name in ENV_NAMES:
        entries.pop(name, None)
    for name, value in env.items():
        entries[name] = f"      {key(name)}: {scalar(value)}"
    lines[env_at + 1 : env_end] = [entries[name] for name in sorted(entries)]

    svc_end = _block_end(lines, svc, 2)
    vol_at = _find(lines, svc, svc_end, "    volumes:")
    wanted = None if mount is None else f"{mount[0]}:{mount[1]}{':ro' if mount[2] else ''}"
    if vol_at is None:
        if wanted is None:
            return "\n".join(lines)
        raise PatchError("core-platform has no volumes: list")
    vol_end = _block_end(lines, vol_at, 4)
    named, host = [], []
    for line in lines[vol_at + 1 : vol_end]:
        if not line.startswith("      - "):
            raise PatchError(f"unexpected volumes line {line!r}")
        item = line[len("      - ") :]
        spec = item.strip('"')
        if spec.startswith(f"{STATE_DIR}:"):
            continue
        (host if spec.startswith(("/", "./")) else named).append(item)
    if wanted is not None:
        host.append(scalar(wanted))

    def host_key(item):
        # The renderer sorts host mounts by their install-relative host path.
        spec = item.strip('"')
        return spec.removeprefix("./")

    host.sort(key=host_key)
    lines[vol_at + 1 : vol_end] = [f"      - {item}" for item in named + host]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# `burrow_install support enable-host`: the same pieces onto a RUNNING install.
# ---------------------------------------------------------------------------


class SupportError(Exception):
    def __init__(self, code, path, message):
        super().__init__(message)
        self.code = code
        self.path = path
        self.message = message

    def line(self):
        return f"error {self.code} at {self.path}: {self.message}"


def _on_disk(fs_root, path):
    return os.path.join(fs_root, path.lstrip("/"))


def _write_if_changed(path, text, mode, dry_run):
    """Atomically write ``text`` (mode ``mode``) unless the file already holds it."""
    try:
        with open(path, encoding="utf-8") as handle:
            if handle.read() == text and (os.stat(path).st_mode & 0o7777) == mode:
                return False
    except FileNotFoundError:
        pass
    if dry_run:
        return True
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    tmp = f"{path}.burrow-tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True


def enable_host(
    manifest,
    reuse_secrets,
    registry_auth=None,
    install_root="/opt/burrow",
    fs_root="/",
    dry_run=False,
    run=None,
    out=print,
):
    """Render ONLY the support env and host files onto a running install.

    Writes the CA public key, the staged sshd drop-in and the three scripts,
    sets core-platform's support env lines and state mount in the live
    compose.yaml (every other line is kept as it is), then runs
    bin/burrow-support-setup and recreates core-platform. Idempotent. It never
    reruns cloud-init, never writes secrets.env, and never touches
    host.ssh_authorized_key or any authorized_keys file.
    """
    import subprocess

    from . import render, templates

    if block(manifest) is None or block(manifest)["ssh_user_ca"] is None:
        raise SupportError(
            "support_not_configured",
            "support.ssh_user_ca",
            "the manifest has no [support] ssh_user_ca; there is nothing to enable",
        )
    if not host_enabled(manifest):
        raise SupportError(
            "field_not_applicable", "install.target", 'only target = "single-host" has the host'
        )
    if fs_root == "/" and not dry_run and os.geteuid() != 0:
        raise SupportError("needs_root", "enable-host", "run as root on the install's host")
    try:
        rendered = render.build(manifest, reuse_secrets=reuse_secrets, registry_auth=registry_auth)
    except render.RenderError as exc:
        raise SupportError(exc.code, exc.path, exc.message) from exc

    compose_path = _on_disk(fs_root, f"{install_root}/compose.yaml")
    try:
        with open(compose_path, encoding="utf-8") as handle:
            live = handle.read()
    except OSError as exc:
        raise SupportError("unreadable_file", compose_path, exc.strerror or str(exc)) from exc
    try:
        patched = patch_compose(
            live, core_env(manifest), CORE_MOUNT, templates._scalar, templates._key
        )
    except PatchError as exc:
        raise SupportError("compose_unrecognised", compose_path, str(exc)) from exc

    files = host_files(manifest, install_root, templates.FILE_MODE, templates.EXEC_MODE)
    verb = "would write" if dry_run else "wrote"
    for rel, (text, mode) in sorted(files.items()):
        path = rel if rel.startswith("/") else f"{install_root}/{rel}"
        changed = _write_if_changed(_on_disk(fs_root, path), text, mode, dry_run)
        out(f"{verb if changed else 'unchanged'} {path} {mode:04o}")
    changed = _write_if_changed(compose_path, patched, templates.FILE_MODE, dry_run)
    out(
        f"{verb if changed else 'unchanged'} {install_root}/compose.yaml (core-platform support env)"
    )
    if patched != rendered.files["compose.yaml"][0]:
        out(
            "note: the live compose.yaml differs from a fresh render outside the support "
            "lines (an earlier installer wrote it); those lines were left as they are"
        )

    commands = [
        ([f"{install_root}/{SETUP_BIN}"], None),
        (["docker", "compose", "up", "-d", "--no-deps", "core-platform"], install_root),
    ]
    for argv, cwd in commands:
        if dry_run:
            out(f"would run {' '.join(argv)}")
            continue
        out(f"run {' '.join(argv)}")
        result = (run or subprocess.run)(argv, cwd=cwd, check=False)
        if result.returncode != 0:
            raise SupportError(
                "host_command_failed", argv[0], f"{' '.join(argv)} exited {result.returncode}"
            )
    return 0
