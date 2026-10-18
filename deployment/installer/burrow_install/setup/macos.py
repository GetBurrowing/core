"""macOS specifics: the login Keychain, power settings, FileVault and launchd.

Mac-only by nature. Everything here runs through a ``Host`` so tests on Linux
exercise it with a recording fake; one test (skipped off Darwin) round-trips a
real Keychain item.

Keychain contract (task 01a0d6ab, product decision 2026-09-25):
- items live in the login Keychain under service ``suite-install.<install.name>``,
  account = the item name the CLI was given (``keychain:<item>``);
- a value is WRITTEN through ``security -i`` reading its command from stdin,
  with the value hex-encoded (``-X``), so it never appears in any process's
  argv and needs no quoting;
- a value is READ with ``security find-generic-password ... -w`` into the
  CLI's memory only; nothing prints it;
- the hidden-input dialog is ``osascript`` reading its script from stdin; the
  typed value comes back on osascript's stdout, captured by the CLI.
"""

import json
import os
import plistlib
import re

from .state import SetupError

ITEM_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
SERVICE_PREFIX = "suite-install"
# `security` exits 44 when no item matches (errSecItemNotFound).
SECURITY_NOT_FOUND = 44


def keychain_service(install_name):
    return f"{SERVICE_PREFIX}.{install_name}"


def check_item(item):
    if not ITEM_RE.match(item or ""):
        raise SetupError(
            "invalid_keychain_item",
            "a Keychain item name is 1-128 of A-Z a-z 0-9 _ . -",
            "use the input's own name, e.g. keychain:CLOUDFLARE_API_TOKEN",
            exit_code=2,
        )


def _storable(value):
    return bool(value) and all(32 <= ord(c) < 127 for c in value)


def _applescript_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


class MacKeychain:
    """The login Keychain via ``security`` and ``osascript``."""

    def __init__(self, host):
        self.host = host

    def available(self):
        return self.host.platform == "darwin"

    def _require(self):
        if not self.available():
            raise SetupError(
                "keychain_unavailable",
                "the macOS Keychain is only available on macOS",
                "pass the input as a file (NAME=@/path, mode 0600) or env (NAME=env:VAR)",
            )

    def read(self, service, item):
        self._require()
        check_item(item)
        result = self.host.run(
            ["security", "find-generic-password", "-s", service, "-a", item, "-w"], timeout=30
        )
        if result.returncode == SECURITY_NOT_FOUND:
            return None
        if not result.ok:
            raise SetupError(
                "keychain_read_failed",
                f"security find-generic-password exited {result.returncode}",
                "unlock the login Keychain (or allow access when macOS asks) and re-run",
            )
        return result.stdout.rstrip("\n")

    def store(self, service, item, value):
        self._require()
        check_item(item)
        if not _storable(value):
            raise SetupError(
                "keychain_value_unsupported",
                "the value is empty or has a character outside printable ASCII",
                "store it in a 0600 file instead and pass NAME=@/path",
            )
        command = (
            f"add-generic-password -U -s {service} -a {item} "
            f"-l {service}.{item} -X {value.encode('ascii').hex()}\n"
        )
        result = self.host.run(["security", "-i"], input=command, timeout=30)
        if not result.ok or "error" in (result.stderr or "").lower():
            raise SetupError(
                "keychain_store_failed",
                f"security add-generic-password exited {result.returncode}",
                "unlock the login Keychain and re-run `setup secret`",
            )
        if self.read(service, item) != value:
            raise SetupError(
                "keychain_store_failed",
                "the item did not read back equal to what was stored",
                "re-run `setup secret`; if it repeats, use a 0600 file instead",
            )

    def delete(self, service, item):
        self._require()
        check_item(item)
        self.host.run(["security", "delete-generic-password", "-s", service, "-a", item])

    def prompt(self, name, install_name):
        """Ask the human for a value in a native hidden-input dialog."""
        self._require()
        message = (
            f"Paste the value for {name} (Burrow install {install_name}). "
            "It is saved to your login Keychain and never shown to the agent."
        )
        script = (
            f"set r to display dialog {_applescript_string(message)} "
            'default answer "" with hidden answer with title "Burrow install" '
            'buttons {"Cancel", "Save"} default button "Save" cancel button "Cancel"\n'
            "return text returned of r\n"
        )
        result = self.host.run(["osascript", "-"], input=script, timeout=600)
        if not result.ok:
            if "-128" in (result.stderr or ""):
                raise SetupError(
                    "keychain_prompt_cancelled",
                    "the dialog was cancelled",
                    f"re-run `setup secret {name}` when ready, or use a 0600 file",
                )
            raise SetupError(
                "keychain_prompt_failed",
                f"osascript exited {result.returncode}",
                "run the CLI from a logged-in macOS session (not over ssh), or use a 0600 file",
            )
        return result.stdout.rstrip("\n")


# ---------------------------------------------------------------------------
# Power, FileVault, automatic login, runtime start-at-login.
# ---------------------------------------------------------------------------

PMSET_KEYS = ("sleep", "disksleep", "autorestart")


def parse_pmset(text):
    """``{"sleep": "1", ...}`` from ``pmset -g`` (first token after the key)."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] in PMSET_KEYS and parts[0] not in out:
            out[parts[0]] = parts[1]
    return out


def filevault_on(text):
    if "FileVault is On" in text:
        return True
    if "FileVault is Off" in text:
        return False
    return None


DOCKER_SETTINGS = (
    "Library/Group Containers/group.com.docker/settings-store.json",
    "Library/Group Containers/group.com.docker/settings.json",
)
AUTOSTART_KEYS = ("AutoStart", "autoStart")


def docker_desktop_autostart(home):
    """``(path, key, value)`` of Docker Desktop's start-at-login setting, or None.

    Only a key that already exists is reported (and later set): the CLI never
    invents a settings key it has not seen in the file.
    """
    for rel in DOCKER_SETTINGS:
        path = os.path.join(home, rel)
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        for key in AUTOSTART_KEYS:
            if key in data:
                return path, key, data[key]
    return None


def set_json_key(path, key, value):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    data[key] = value
    tmp = path + ".burrow-install.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# launchd (user LaunchAgents; never a LaunchDaemon, never sudo).
# ---------------------------------------------------------------------------


# Same reverse-DNS root as the desktop app's bundle id.
LABEL_ROOT = "io.github.getburrowing.install"
# Installs made before task 01a14dd8 loaded their jobs under this root.
LEGACY_LABEL_ROOT = "org.startupsuite.install"


def agent_label(install_name, job):
    return f"{LABEL_ROOT}.{install_name}.{job}"


def legacy_agent_label(install_name, job):
    return f"{LEGACY_LABEL_ROOT}.{install_name}.{job}"


def remove_agent(host, label):
    """Boot out and delete ``~/Library/LaunchAgents/<label>.plist``; True if it existed."""
    path = os.path.join(host.home(), "Library", "LaunchAgents", f"{label}.plist")
    if not os.path.exists(path):
        return False
    host.run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], timeout=30)
    os.unlink(path)
    return True


def agent_plist(label, program_arguments, log_path, calendar=None, interval=None):
    doc = {
        "Label": label,
        "ProgramArguments": list(program_arguments),
        "StandardOutPath": log_path,
        "StandardErrorPath": log_path,
        "RunAtLoad": False,
        "EnvironmentVariables": {
            # launchd starts jobs with a bare PATH; these are where Docker
            # Desktop, OrbStack and Homebrew put docker and curl.
            "PATH": ":".join(
                (
                    "/usr/local/bin",
                    "/opt/homebrew/bin",
                    "/Applications/Docker.app/Contents/Resources/bin",
                    os.path.expanduser("~/.orbstack/bin"),
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                )
            )
        },
    }
    if calendar:
        doc["StartCalendarInterval"] = calendar
    if interval:
        doc["StartInterval"] = interval
    return plistlib.dumps(doc)


def install_agent(host, label, plist_bytes):
    """Write ``~/Library/LaunchAgents/<label>.plist`` and (re)load it."""
    directory = os.path.join(host.home(), "Library", "LaunchAgents")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{label}.plist")
    with open(path, "wb") as handle:
        handle.write(plist_bytes)
    domain = f"gui/{os.getuid()}"
    host.run(["launchctl", "bootout", f"{domain}/{label}"], timeout=30)
    result = host.run(["launchctl", "bootstrap", domain, path], timeout=30)
    if not result.ok:
        raise SetupError(
            "launchd_load_failed",
            f"launchctl bootstrap exited {result.returncode}: {result.stderr.strip()[:200]}",
            f"load it by hand: launchctl bootstrap {domain} {path}",
        )
    return path
