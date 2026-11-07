"""Vendor support access on the host (core task 01a1b362 stage 3, ADR 0059).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Covers the manifest's [support] block (validation, env, host files), the
principals command against fixture state files, the repair shell wrapper in
its no-root test mode, `support enable-host` against a staged file tree, and,
where the machine has OpenSSH, a disposable unprivileged sshd that admits a
CA-signed certificate only while the state file allows it.

Key material: every key a test needs is made by ssh-keygen in a temp dir and
deleted with it. The fixture keys in the .toml files are counting bytes,
PUBLIC halves only, with no private half anywhere.
"""

import base64
import contextlib
import copy
import datetime
import gzip
import io
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
sys.path.insert(0, INSTALLER)

from identity_terms import identity_hits

from burrow_install import support, templates
from burrow_install.__main__ import main
from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import validate

RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
STATE_FIXTURES = os.path.join(HERE, "support_fixtures")
SUPPORT_FIXTURE = os.path.join(RENDER_FIXTURES, "do-droplet-support.toml")
DROPLET_FIXTURE = os.path.join(RENDER_FIXTURES, "do-droplet.toml")
REGISTRY_AUTH = os.path.join(RENDER_FIXTURES, "do-droplet-registry-auth.json")
PRINCIPALS = os.path.join(support.SCRIPTS, "burrow-support-principals")
SHELL = os.path.join(support.SCRIPTS, "burrow-support-shell")
SETUP = os.path.join(support.SCRIPTS, "burrow-support-setup.sh")

SID = "01a1b362-0000-7000-8000-000000000001"
PRINCIPAL = "support-burrow-01a0d69d"
CA_LINE = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/ "
    "support-ca-fixture"
)
CA_LINE_2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEBBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f next"
GRANT_KEY = "YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8="
DO_USER_DATA_MAX = 65536


def raw(path=SUPPORT_FIXTURE):
    return load(path)


def valid(manifest_raw):
    errors, normalized = validate(manifest_raw)
    if errors:
        raise AssertionError(f"manifest is invalid: {errors}")
    return normalized


def codes(manifest_raw):
    errors, _ = validate(manifest_raw)
    return [(e.code, e.path) for e in errors]


def render(manifest_raw, **kwargs):
    return build(valid(manifest_raw), registry_auth=REGISTRY_AUTH, **kwargs)


def without_support(manifest_raw):
    out = copy.deepcopy(manifest_raw)
    out.pop("support", None)
    return out


def gz_entries(user_data):
    """{path: decoded text} of every gz+b64 write_files entry."""
    out = {}
    pattern = re.compile(
        r'^  - path: "([^"]+)"\n(?:    [a-z]+: "[^"]*"\n)*?    encoding: "gz\+b64"\n'
        r'    content: "([A-Za-z0-9+/=]+)"$',
        re.MULTILINE,
    )
    for match in pattern.finditer(user_data):
        out[match.group(1)] = gzip.decompress(base64.b64decode(match.group(2))).decode()
    return out


def run_principals(*args, script=PRINCIPALS):
    return subprocess.run(
        [sys.executable, "-I", script, *args],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def elixir_parse_keys(value):
    """Python mirror of core's SupportAccess.Config.parse_keys/1 (stage 1)."""
    out = {}
    for entry in re.split(r"[, \n\t]+", value):
        if not entry:
            continue
        kid, sep, b64 = entry.partition(":")
        if not kid or not sep:
            continue
        trimmed = b64.rstrip("=")
        padded = trimmed + "=" * (-len(trimmed) % 4)
        try:
            key = (
                base64.urlsafe_b64decode(padded)
                if re.fullmatch(r"[A-Za-z0-9_-]*", trimmed)
                else None
            )
        except ValueError:
            key = None
        if key is None:
            try:
                key = base64.b64decode(padded, validate=True)
            except ValueError:
                continue
        if len(key) == 32:
            out[kid] = key
    return out


# ---------------------------------------------------------------------------
# Manifest validation.
# ---------------------------------------------------------------------------


class ValidationTest(unittest.TestCase):
    def test_00_positive_control_the_support_fixture_is_valid(self):
        normalized = valid(raw())
        self.assertEqual(normalized["support"]["ssh_user_ca"], CA_LINE)
        self.assertEqual(len(normalized["support"]["vendor_grant_keys"]), 2)

    def test_absent_block_normalizes_to_none(self):
        self.assertIsNone(valid(raw(DROPLET_FIXTURE))["support"])

    def test_empty_block_takes_the_defaults(self):
        m = without_support(raw())
        m["support"] = {}
        sup = valid(m)["support"]
        self.assertEqual(sup["access_default"], "off")
        self.assertEqual(sup["vendor_grant_keys"], [])
        self.assertIsNone(sup["ssh_user_ca"])

    def set_support(self, **fields):
        m = without_support(raw())
        m["support"] = fields
        return m

    def test_rsa_ca_is_refused(self):
        m = self.set_support(ssh_user_ca="ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB ca")
        self.assertEqual(codes(m), [("invalid_ssh_user_ca", "support.ssh_user_ca")])

    def test_bad_ca_lines_are_refused(self):
        for bad in (
            "",
            "ssh-ed25519",
            "ssh-ed25519 not*base64",
            "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQAB",  # an rsa blob in an ed25519 line
            CA_LINE[:-30],  # truncated key
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY=",
            "cert-authority " + CA_LINE,  # an authorized_keys option, not a key line
            CA_LINE + "\n" + CA_LINE,  # the same line twice
            "\n".join([CA_LINE, CA_LINE_2, CA_LINE.replace("fixture", "third")]),
            CA_LINE + "\n",  # a trailing empty line
            CA_LINE + "\tcomment",
        ):
            with self.subTest(ca=bad):
                self.assertEqual(
                    codes(self.set_support(ssh_user_ca=bad)),
                    [("invalid_ssh_user_ca", "support.ssh_user_ca")],
                )

    def test_rollover_accepts_two_distinct_ca_lines(self):
        m = self.set_support(ssh_user_ca=CA_LINE + "\n" + CA_LINE_2)
        self.assertEqual(codes(m), [])
        files = support.host_files(valid(m), "/opt/burrow", 0o644, 0o755)
        self.assertEqual(files[support.CA_PATH][0], CA_LINE + "\n" + CA_LINE_2 + "\n")

    def test_bad_kid_or_key_is_refused(self):
        cases = {
            "bad kid": ({"kid": "bad kid!", "public_key": GRANT_KEY}, "kid"),
            "colon kid": ({"kid": "a:b", "public_key": GRANT_KEY}, "kid"),
            "long kid": ({"kid": "k" * 65, "public_key": GRANT_KEY}, "kid"),
            "short key": ({"kid": "v1", "public_key": "c2hvcnQ="}, "public_key"),
            "long key": (
                {"kid": "v1", "public_key": base64.b64encode(bytes(33)).decode()},
                "public_key",
            ),
            "not base64": ({"kid": "v1", "public_key": "not base64!"}, "public_key"),
            "mixed alphabets": ({"kid": "v1", "public_key": "-+" + GRANT_KEY[2:]}, "public_key"),
            "separator in key": ({"kid": "v1", "public_key": GRANT_KEY + ",x"}, "public_key"),
        }
        for name, (key, field) in cases.items():
            with self.subTest(case=name):
                m = self.set_support(vendor_grant_keys=[key])
                self.assertEqual(
                    codes(m),
                    [("invalid_support_key", f"support.vendor_grant_keys[0].{field}")],
                )

    def test_duplicate_kid_is_refused(self):
        key = {"kid": "v1", "public_key": GRANT_KEY}
        m = self.set_support(vendor_grant_keys=[key, dict(key)])
        self.assertEqual(codes(m), [("invalid_support_key", "support.vendor_grant_keys[1].kid")])

    def test_a_grant_key_needs_both_fields(self):
        m = self.set_support(vendor_grant_keys=[{"kid": "v1"}])
        self.assertEqual(codes(m), [("missing_required", "support.vendor_grant_keys[0]")])

    def test_base64url_unpadded_grant_key_is_accepted(self):
        key = base64.urlsafe_b64encode(bytes(range(200, 232))).decode().rstrip("=")
        self.assertIn("-", key + "-")  # shape check only
        m = self.set_support(vendor_grant_keys=[{"kid": "v1", "public_key": key}])
        self.assertEqual(codes(m), [])

    def test_vendor_name_and_install_id_shapes(self):
        self.assertEqual(
            codes(self.set_support(vendor_name="Costs $5")),
            [("invalid_value", "support.vendor_name")],
        )
        self.assertEqual(
            codes(self.set_support(install_id="has space")),
            [("invalid_value", "support.install_id")],
        )
        self.assertEqual(codes(self.set_support(access_default="maybe"))[0][0], "invalid_enum")
        self.assertEqual(codes(self.set_support(unknown=True))[0][0], "unknown_key")

    def test_ssh_user_ca_is_single_host_only(self):
        mac = load(os.path.join(os.path.dirname(INSTALLER), "examples", "mac.install.toml"))
        mac["support"] = {"ssh_user_ca": CA_LINE}
        self.assertEqual(codes(mac), [("field_not_applicable", "support.ssh_user_ca")])
        mac["support"] = {"access_default": "on"}
        self.assertEqual(codes(mac), [])


# ---------------------------------------------------------------------------
# Render: env, host files, user-data.
# ---------------------------------------------------------------------------


def core_env(rendered):
    compose = rendered.files["compose.yaml"][0]
    block = compose.split("  core-platform:\n", 1)[1].split("\n  core-postgres:", 1)[0]
    return dict(re.findall(r'^      ([A-Z_]+): "(.*)"$', block, re.MULTILINE)), block


class RenderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.with_ = render(raw())
        cls.without = render(without_support(raw()))

    def test_00_positive_control_support_renders_env_and_host_files(self):
        env, _ = core_env(self.with_)
        self.assertEqual(env["SUPPORT_ACCESS_DEFAULT"], "on")
        self.assertIn("/etc/ssh/burrow-support-ca.pub", self.with_.files["user-data"][0])

    def test_without_the_block_nothing_of_it_renders(self):
        text = "\n".join(t for t, _ in self.without.files.values())
        for needle in (
            "burrow-support",
            "SUPPORT_",
            "INSTALL_ID",
            "/var/lib/burrow-support",
            "sshd_config.d",
            "TrustedUserCAKeys",
        ):
            with self.subTest(needle=needle):
                self.assertNotIn(needle, text)

    def test_env_matches_core_formats(self):
        env, _ = core_env(self.with_)
        self.assertEqual(env["INSTALL_ID"], "burrow-01a0d69d")
        self.assertEqual(env["SUPPORT_VENDOR_NAME"], "Example Vendor Support")
        keys = elixir_parse_keys(env["SUPPORT_VENDOR_KEYS"])
        self.assertEqual(sorted(keys), ["grant-2026-11", "grant-2027-01"])
        self.assertEqual(keys["grant-2026-11"], bytes(range(96, 128)))
        self.assertEqual(keys["grant-2027-01"], bytes(range(128, 160)))
        # None of the support env is a secret: nothing of it is in secrets.env.
        self.assertNotIn("SUPPORT_", self.with_.files["secrets.env"][0])
        self.assertNotIn("INSTALL_ID", self.with_.files["secrets.env"][0])

    def test_install_id_override(self):
        m = raw()
        m["support"]["install_id"] = "inst-42"
        env, _ = core_env(render(m))
        self.assertEqual(env["INSTALL_ID"], "inst-42")

    def test_block_without_ca_renders_env_only(self):
        m = raw()
        del m["support"]["ssh_user_ca"]
        rendered = render(m)
        env, block = core_env(rendered)
        self.assertEqual(env["SUPPORT_ACCESS_DEFAULT"], "on")
        self.assertNotIn("/var/lib/burrow-support", block)
        self.assertNotIn("burrow-support", rendered.files["user-data"][0])

    def test_no_keys_renders_no_vendor_keys_line(self):
        m = raw()
        m["support"]["vendor_grant_keys"] = []
        env, _ = core_env(render(m))
        self.assertNotIn("SUPPORT_VENDOR_KEYS", env)

    def test_state_dir_is_a_read_write_core_mount(self):
        _, block = core_env(self.with_)
        self.assertIn('      - "/var/lib/burrow-support:/var/lib/burrow-support"\n', block)

    def test_compressed_scripts_decode_to_the_shipped_files(self):
        entries = gz_entries(self.with_.files["user-data"][0])
        expected = {
            "/opt/burrow/bin/burrow-support-principals": PRINCIPALS,
            "/opt/burrow/bin/burrow-support-shell": SHELL,
            "/opt/burrow/bin/burrow-support-setup": SETUP,
        }
        self.assertEqual(sorted(entries), sorted(expected))
        for path, source in expected.items():
            with open(source, encoding="utf-8") as handle:
                self.assertEqual(entries[path], handle.read(), path)

    def test_gzip_is_deterministic(self):
        self.assertEqual(templates.gzip_b64("abc\n"), templates.gzip_b64("abc\n"))
        self.assertEqual(gzip.decompress(base64.b64decode(templates.gzip_b64("abc\n"))), b"abc\n")

    def test_scripts_are_root_owned_executables_and_the_ca_is_public(self):
        user_data = self.with_.files["user-data"][0]
        for path, mode in (
            ("/opt/burrow/bin/burrow-support-principals", "0755"),
            ("/opt/burrow/bin/burrow-support-shell", "0755"),
            ("/opt/burrow/bin/burrow-support-setup", "0755"),
            ("/opt/burrow/support/60-burrow-support.conf", "0644"),
            ("/etc/ssh/burrow-support-ca.pub", "0644"),
        ):
            with self.subTest(path=path):
                self.assertIn(
                    f'  - path: "{path}"\n    owner: "root:root"\n    permissions: "{mode}"\n',
                    user_data,
                )
        self.assertNotIn("PRIVATE KEY", "\n".join(t for t, _ in self.with_.files.values()))

    def test_setup_runs_before_the_stack_starts(self):
        user_data = self.with_.files["user-data"][0]
        setup = user_data.index('  - ["/opt/burrow/bin/burrow-support-setup"]')
        start = user_data.index('  - ["systemctl", "start", "--no-block", "burrow-stack.service"]')
        self.assertLess(setup, start)
        self.assertGreater(setup, user_data.index("runcmd:"))

    def test_no_vendor_key_reaches_ssh_authorized_keys(self):
        def keys(rendered):
            tail = rendered.files["user-data"][0].split("ssh_authorized_keys:\n", 1)[1]
            return tail.split("chpasswd:", 1)[0]

        self.assertEqual(keys(self.with_), keys(self.without))
        self.assertNotIn(CA_LINE.split()[1], keys(self.with_))

    def test_only_compose_and_user_data_change(self):
        a, b = self.with_.redacted(), self.without.redacted()
        self.assertEqual(sorted(a), sorted(b))
        changed = sorted(rel for rel in a if a[rel] != b[rel])
        self.assertEqual(changed, ["compose.yaml", "user-data"])

    def test_hosted_install_with_support_fits_the_user_data_cap(self):
        m = raw()
        m["install"]["hosted"] = True
        m.pop("backup")
        rendered = render(m)
        self.assertIn("burrow-backup", rendered.files["user-data"][0])  # positive control
        size = len(rendered.files["user-data"][0].encode())
        self.assertLess(size, DO_USER_DATA_MAX, size)

    def test_render_carries_no_install_identity(self):
        for rel, text in self.with_.redacted().items():
            with self.subTest(file=rel):
                self.assertEqual(identity_hits(text), [])
        for path in (PRINCIPALS, SHELL, SETUP, __file__):
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(identity_hits(handle.read()), [], path)


class DropinTest(unittest.TestCase):
    def setUp(self):
        self.text = support.dropin("/opt/burrow")
        self.lines = self.text.splitlines()

    def test_every_directive_sits_in_the_burrow_support_match(self):
        body = [line for line in self.lines if line and not line.startswith("#")]
        self.assertEqual(body[0], "Match User burrow-support")
        self.assertEqual(body[-1], "Match all")
        inside = [line.strip() for line in body[1:-1]]
        self.assertTrue(all(line.startswith("    ") for line in body[1:-1]), body)
        self.assertEqual(
            inside,
            [
                "TrustedUserCAKeys /etc/ssh/burrow-support-ca.pub",
                "AuthorizedPrincipalsCommand /opt/burrow/bin/burrow-support-principals %u %i",
                "AuthorizedPrincipalsCommandUser burrow-support-check",
                "AuthorizedKeysFile none",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "AllowAgentForwarding no",
                "AllowTcpForwarding no",
                "AllowStreamLocalForwarding no",
                "X11Forwarding no",
                "PermitTTY yes",
                "ExposeAuthInfo yes",
                "ForceCommand /opt/burrow/bin/burrow-support-shell",
            ],
        )


# ---------------------------------------------------------------------------
# The principals command against fixture state files.
# ---------------------------------------------------------------------------


def state_fixture(name):
    return os.path.join(STATE_FIXTURES, name)


class PrincipalsTest(unittest.TestCase):
    def check(self, state, key_id=SID, user=support.SUPPORT_USER, script=PRINCIPALS):
        result = run_principals(user, key_id, state, script=script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_00_on_and_a_matching_unexpired_session_prints_the_principal(self):
        self.assertEqual(self.check(state_fixture("state-on.json")), PRINCIPAL + "\n")

    def test_enabled_false_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-off.json")), "")

    def test_expired_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-expired.json")), "")

    def test_unknown_key_id_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-on.json"), key_id="someone-else"), "")
        self.assertEqual(self.check(state_fixture("state-on.json"), key_id=""), "")

    def test_missing_file_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("no-such-state.json")), "")

    def test_junk_json_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-junk.json")), "")

    def test_version_2_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-version-2.json")), "")

    def test_other_user_prints_nothing(self):
        self.assertEqual(self.check(state_fixture("state-on.json"), user="root"), "")

    def test_without_arguments_prints_nothing(self):
        result = subprocess.run(
            [sys.executable, "-I", PRINCIPALS],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_shapes_that_fail_closed(self):
        far = "2999-01-01T00:00:00Z"
        base = {
            "version": 1,
            "enabled": True,
            "principal": PRINCIPAL,
            "repair_sessions": [{"id": SID, "not_after": far}],
        }
        cases = {
            "version true": dict(base, version=True),
            "version string": dict(base, version="1"),
            "enabled string": dict(base, enabled="true"),
            "enabled 1": dict(base, enabled=1),
            "no principal": {k: v for k, v in base.items() if k != "principal"},
            "principal with newline": dict(base, principal=PRINCIPAL + "\nroot"),
            "principal not support-": dict(base, principal="root"),
            "sessions not a list": dict(base, repair_sessions={"id": SID}),
            "naive not_after": dict(base, repair_sessions=[{"id": SID, "not_after": far[:-1]}]),
            "unix not_after": dict(base, repair_sessions=[{"id": SID, "not_after": 32503680000}]),
            "no not_after": dict(base, repair_sessions=[{"id": SID}]),
            "a list": [base],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            with open(path, "w") as handle:
                json.dump(base, handle)
            self.assertEqual(self.check(path), PRINCIPAL + "\n")  # positive control
            for name, doc in cases.items():
                with self.subTest(case=name):
                    with open(path, "w") as handle:
                        json.dump(doc, handle)
                    self.assertEqual(self.check(path), "")

    def test_not_after_is_compared_to_the_clock(self):
        now = datetime.datetime.now(datetime.UTC)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            for delta, expected in ((120, PRINCIPAL + "\n"), (-120, "")):
                when = (now + datetime.timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ")
                with open(path, "w") as handle:
                    json.dump(
                        {
                            "version": 1,
                            "enabled": True,
                            "principal": PRINCIPAL,
                            "repair_sessions": [
                                {"id": "other", "not_after": "2999-01-01T00:00:00Z"},
                                {"id": SID, "not_after": when},
                            ],
                        },
                        handle,
                    )
                with self.subTest(delta=delta):
                    self.assertEqual(self.check(path), expected)

    def test_unreadable_file_prints_nothing(self):
        if os.geteuid() == 0:
            self.skipTest("root reads a 0000 file")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            shutil.copy(state_fixture("state-on.json"), path)
            os.chmod(path, 0)
            self.assertEqual(self.check(path), "")

    def test_matches_the_state_file_core_writes(self):
        # Stage 1's Platform.SupportAccess.StateFile: DateTime.to_iso8601 at
        # second precision, UTC ("...Z"), and the principal "support-<INSTALL_ID>".
        state_ex = os.path.join(
            os.path.dirname(os.path.dirname(INSTALLER)),
            "apps",
            "platform",
            "lib",
            "platform",
            "support_access",
            "state_file.ex",
        )
        if not os.path.exists(state_ex):
            self.skipTest("core's state_file.ex is not in this checkout")
        with open(state_ex, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn(
            '"not_after" => DateTime.to_iso8601(DateTime.truncate(s.not_after, :second))', source
        )
        self.assertIn("@version 1", source)
        for key in ('"version"', '"enabled"', '"principal"', '"repair_sessions"', '"id"'):
            self.assertIn(key, source)


# ---------------------------------------------------------------------------
# The repair shell wrapper, in its no-root test mode.
# ---------------------------------------------------------------------------


def write_state(path, enabled=True, not_after="2999-01-01T00:00:00Z", sid=SID):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(
            {
                "version": 1,
                "enabled": enabled,
                "principal": PRINCIPAL,
                "repair_sessions": [{"id": sid, "not_after": not_after}] if enabled else [],
            },
            handle,
        )
    os.replace(tmp, path)


def read_events(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle]


@unittest.skipIf(os.geteuid() == 0, "the wrapper's test mode is refused as root")
@unittest.skipUnless(shutil.which("script") and shutil.which("bash"), "needs script(1) and bash")
class ShellWrapperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="burrow-support-shell-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = os.path.join(self.tmp, "state.json")
        self.events = os.path.join(self.tmp, "events.jsonl")
        write_state(self.state)
        self.env = dict(
            os.environ,
            BURROW_SUPPORT_SHELL_TEST_DIR=self.tmp,
            BURROW_SUPPORT_SHELL_CHECK_S="0.3",
        )

    def shell(self, *args, stdin=None, timeout=60):
        return subprocess.run(
            [sys.executable, "-I", SHELL, *args],
            check=False,
            env=self.env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def test_help_says_tamper_evident_not_tamper_proof(self):
        out = self.shell("--help").stdout
        self.assertIn("TAMPER-EVIDENT, NOT TAMPER-PROOF AGAINST ROOT", out)

    def test_00_a_command_session_is_recorded(self):
        result = self.shell("--as-root", SID, "echo repair-hello")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = read_events(self.events)
        self.assertEqual(
            [e["event"] for e in events], ["shell_opened", "shell_command", "shell_closed"]
        )
        self.assertTrue(all(e["session_id"] == SID for e in events))
        self.assertEqual(events[1]["command"], "echo repair-hello")
        self.assertTrue(
            all(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", e["ts"]) for e in events)
        )
        transcript = os.path.join(self.tmp, "log", f"{SID}.log")
        self.assertEqual(stat.S_IMODE(os.stat(transcript).st_mode), 0o600)
        with open(transcript, encoding="utf-8", errors="replace") as handle:
            self.assertIn("repair-hello", handle.read())
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.tmp, "log")).st_mode), 0o700)

    def test_event_lines_have_core_ingest_shape(self):
        self.shell("--as-root", SID, 'echo "quote\\" and \\\\ back"')
        with open(self.events, encoding="utf-8") as handle:
            raw_lines = handle.read().split("\n")
        self.assertEqual(raw_lines[-1], "")  # every line ends in "\n"
        for line in raw_lines[:-1]:
            doc = json.loads(line)
            self.assertIn(doc["event"], ("shell_opened", "shell_command", "shell_closed"))
            self.assertEqual(set(doc) - {"command"}, {"event", "session_id", "ts"})

    def test_interactive_commands_are_logged_through_prompt_command(self):
        result = self.shell("--as-root", SID, stdin="echo first-cmd\necho second-cmd\nexit\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [e["command"] for e in read_events(self.events) if e["event"] == "shell_command"]
        self.assertIn("echo first-cmd", commands)
        self.assertIn("echo second-cmd", commands)

    def test_a_dead_session_is_refused_at_start(self):
        for state in ({"enabled": False}, {"not_after": "2001-01-01T00:00:00Z"}):
            with self.subTest(state=state):
                write_state(self.state, **state)
                result = self.shell("--as-root", SID, "echo should-not-run")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(read_events(self.events), [])
        write_state(self.state)
        self.assertEqual(self.shell("--as-root", "other-session", "true").returncode, 1)

    def test_switching_off_ends_an_open_session(self):
        proc = subprocess.Popen(
            [sys.executable, "-I", SHELL, "--as-root", SID, "sleep 60"],
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        deadline = time.monotonic() + 20
        while not read_events(self.events) and time.monotonic() < deadline:
            time.sleep(0.1)
        time.sleep(1)
        self.assertIsNone(proc.poll(), "the session must be running before the switch flips")
        flipped = time.monotonic()
        write_state(self.state, enabled=False)
        proc.wait(timeout=20)
        self.assertLess(time.monotonic() - flipped, 15)
        self.assertEqual(read_events(self.events)[-1]["event"], "shell_closed")

    def test_ssh_entry_reads_the_key_id_from_expose_auth_info(self):
        if not shutil.which("ssh-keygen"):
            self.skipTest("needs ssh-keygen")
        keys = KeyRig(self.tmp)
        cert = keys.sign(SID)
        with open(cert) as handle:
            key_type, blob = handle.read().split()[:2]
        auth = os.path.join(self.tmp, "auth-info")
        with open(auth, "w") as handle:
            handle.write(f"publickey {key_type} {blob}\n")
        env = dict(self.env, SSH_USER_AUTH=auth, SSH_ORIGINAL_COMMAND="echo via-ssh")
        result = subprocess.run(
            [sys.executable, "-I", SHELL],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        events = read_events(self.events)
        self.assertEqual({e["session_id"] for e in events}, {SID})
        # No certificate: nothing opens.
        with open(auth, "w") as handle:
            handle.write("publickey ssh-ed25519 AAAA\n")
        result = subprocess.run(
            [sys.executable, "-I", SHELL],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 1)


class SetupScriptTest(unittest.TestCase):
    def test_setup_reloads_only_after_sshd_t_and_backs_the_dropin_out(self):
        with open(SETUP, encoding="utf-8") as handle:
            text = handle.read()
        self.assertLess(
            text.index("/usr/sbin/sshd -t"), text.index("systemctl try-reload-or-restart")
        )
        failed = text[text.index("if ! /usr/sbin/sshd -t; then") :].split("\nfi\n", 1)[0]
        self.assertIn('rm -f "$dropin"', failed)
        self.assertIn("exit 1", failed)
        self.assertNotIn("systemctl", failed)
        self.assertIn('visudo -c -q -f "$tmp"', text)
        self.assertIn("install -o root -g root -m 0440", text)
        code = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
        self.assertNotIn("authorized_keys", "\n".join(code))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_setup_parses(self):
        subprocess.run(["bash", "-n", SETUP], check=True)


# ---------------------------------------------------------------------------
# compose.yaml patch and `support enable-host`.
# ---------------------------------------------------------------------------


def patch(text, manifest):
    mount = support.CORE_MOUNT if support.host_enabled(manifest) else None
    return support.patch_compose(
        text, support.core_env(manifest), mount, templates._scalar, templates._key
    )


class ComposePatchTest(unittest.TestCase):
    CASES = (
        os.path.join(RENDER_FIXTURES, "do-droplet.toml"),
        os.path.join(RENDER_FIXTURES, "do-droplet-8gb.toml"),
        os.path.join(RENDER_FIXTURES, "single-host-agents-contained.toml"),
        os.path.join(RENDER_FIXTURES, "single-host-memory-off.toml"),
        os.path.join(os.path.dirname(INSTALLER), "examples", "single-host.install.toml"),
    )

    def test_patching_a_plain_render_equals_a_fresh_support_render(self):
        for path in self.CASES:
            for tls in ("acme", "internal"):
                with self.subTest(case=os.path.basename(path), tls=tls):
                    base = load(path)
                    base["domain"]["tls"] = tls
                    if tls == "internal":
                        base["domain"].pop("acme_email", None)
                    else:
                        base["domain"].setdefault("acme_email", "owner@example.test")
                    plain = build(valid(base), registry_auth=REGISTRY_AUTH)
                    with_ = copy.deepcopy(base)
                    with_["support"] = raw()["support"]
                    m = valid(with_)
                    fresh = build(m, registry_auth=REGISTRY_AUTH).files["compose.yaml"][0]
                    patched = patch(plain.files["compose.yaml"][0], m)
                    self.assertNotEqual(patched, plain.files["compose.yaml"][0])
                    self.assertEqual(patched, fresh)
                    self.assertEqual(patch(patched, m), fresh)  # idempotent

    def test_changed_values_replace_old_ones(self):
        m = valid(raw())
        once = patch(render(without_support(raw())).files["compose.yaml"][0], m)
        changed = raw()
        changed["support"]["access_default"] = "off"
        del changed["support"]["vendor_name"]
        m2 = valid(changed)
        self.assertEqual(patch(once, m2), render(changed).files["compose.yaml"][0])

    def test_unrecognised_compose_is_refused(self):
        for text in ("", "services:\n  other:\n    image: x\n", "services:\n  core-platform:\n"):
            with self.subTest(text=text), self.assertRaises(support.PatchError):
                patch(text, valid(raw()))


class EnableHostTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="burrow-support-host-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.install = os.path.join(self.root, "opt", "burrow")
        os.makedirs(self.install)
        plain = render(without_support(raw()))
        self.plain = plain
        for rel in ("compose.yaml", "secrets.env"):
            text, mode = plain.files[rel]
            with open(os.path.join(self.install, rel), "w") as handle:
                handle.write(text)
            os.chmod(os.path.join(self.install, rel), mode)
        self.secrets = os.path.join(self.install, "secrets.env")
        self.ran = []

    def fake_run(self, argv, cwd=None, check=False):
        self.ran.append((argv, cwd))
        return subprocess.CompletedProcess(argv, 0)

    def enable(self, manifest_raw=None, dry_run=False):
        lines = []
        code = support.enable_host(
            valid(manifest_raw or raw()),
            self.secrets,
            registry_auth=REGISTRY_AUTH,
            fs_root=self.root,
            dry_run=dry_run,
            run=self.fake_run,
            out=lines.append,
        )
        return code, lines

    def tree(self):
        out = {}
        for root, _dirs, names in os.walk(self.root):
            for name in names:
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as handle:
                    out["/" + os.path.relpath(path, self.root)] = (
                        handle.read(),
                        stat.S_IMODE(os.stat(path).st_mode),
                    )
        return out

    def test_00_writes_only_the_support_pieces_and_restarts_core(self):
        before = self.tree()
        code, lines = self.enable()
        self.assertEqual(code, 0)
        after = self.tree()
        added = sorted(set(after) - set(before))
        self.assertEqual(
            added,
            [
                "/etc/ssh/burrow-support-ca.pub",
                "/opt/burrow/bin/burrow-support-principals",
                "/opt/burrow/bin/burrow-support-setup",
                "/opt/burrow/bin/burrow-support-shell",
                "/opt/burrow/support/60-burrow-support.conf",
            ],
        )
        changed = sorted(p for p in before if before[p] != after[p])
        self.assertEqual(changed, ["/opt/burrow/compose.yaml"])
        self.assertEqual(
            after["/opt/burrow/compose.yaml"][0], render(raw()).files["compose.yaml"][0]
        )
        self.assertEqual(after["/opt/burrow/bin/burrow-support-principals"][1], 0o755)
        self.assertEqual(after["/etc/ssh/burrow-support-ca.pub"], (CA_LINE + "\n", 0o644))
        self.assertEqual(
            self.ran,
            [
                (["/opt/burrow/bin/burrow-support-setup"], None),
                (["docker", "compose", "up", "-d", "--no-deps", "core-platform"], "/opt/burrow"),
            ],
        )
        self.assertFalse(any("authorized_keys" in p for p in after))
        self.assertFalse(any(line.startswith("note:") for line in lines), lines)

    def test_second_run_changes_nothing(self):
        self.enable()
        before = self.tree()
        _code, lines = self.enable()
        self.assertEqual(self.tree(), before)
        self.assertTrue(all(not l.startswith("wrote") for l in lines), lines)

    def test_dry_run_writes_and_runs_nothing(self):
        before = self.tree()
        _code, lines = self.enable(dry_run=True)
        self.assertEqual(self.tree(), before)
        self.assertEqual(self.ran, [])
        self.assertIn("would run /opt/burrow/bin/burrow-support-setup", lines)

    def test_refuses_without_a_ca(self):
        m = raw()
        del m["support"]["ssh_user_ca"]
        with self.assertRaises(support.SupportError) as caught:
            self.enable(m)
        self.assertEqual(caught.exception.code, "support_not_configured")
        with self.assertRaises(support.SupportError):
            self.enable(without_support(raw()))
        self.assertEqual(self.ran, [])

    def test_a_failed_setup_stops_before_core_restarts(self):
        def failing(argv, cwd=None, check=False):
            self.ran.append((argv, cwd))
            return subprocess.CompletedProcess(argv, 1)

        with self.assertRaises(support.SupportError) as caught:
            support.enable_host(
                valid(raw()),
                self.secrets,
                registry_auth=REGISTRY_AUTH,
                fs_root=self.root,
                run=failing,
                out=lambda _l: None,
            )
        self.assertEqual(caught.exception.code, "host_command_failed")
        self.assertEqual(len(self.ran), 1)

    def test_drifted_compose_keeps_its_other_lines_and_says_so(self):
        path = os.path.join(self.install, "compose.yaml")
        with open(path) as handle:
            text = handle.read()
        drifted = text.replace(
            '      PORT: "4000"\n', '      PORT: "4000"\n      LEGACY_KNOB: "1"\n'
        )
        self.assertNotEqual(drifted, text)
        with open(path, "w") as handle:
            handle.write(drifted)
        _code, lines = self.enable()
        with open(path) as handle:
            result = handle.read()
        self.assertIn('      LEGACY_KNOB: "1"\n', result)
        self.assertIn('      SUPPORT_ACCESS_DEFAULT: "on"\n', result)
        self.assertTrue(any(line.startswith("note:") for line in lines))

    def test_cli_dry_run(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(
                [
                    "support",
                    "enable-host",
                    "--manifest",
                    SUPPORT_FIXTURE,
                    "--reuse-secrets",
                    self.secrets,
                    "--registry-auth",
                    REGISTRY_AUTH,
                    "--fs-root",
                    self.root,
                    "--dry-run",
                ]
            )
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("would write /etc/ssh/burrow-support-ca.pub 0644", out.getvalue())

    def test_cli_refuses_a_manifest_without_support(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(
                [
                    "support",
                    "enable-host",
                    "--manifest",
                    DROPLET_FIXTURE,
                    "--reuse-secrets",
                    self.secrets,
                    "--registry-auth",
                    REGISTRY_AUTH,
                    "--fs-root",
                    self.root,
                ]
            )
        self.assertEqual(code, 2)
        self.assertTrue(out.getvalue().startswith("error support_not_configured at "))


# ---------------------------------------------------------------------------
# Integration: a disposable unprivileged sshd and a CA-signed certificate.
# ---------------------------------------------------------------------------


class KeyRig:
    """Throwaway CA and user keys in ``tmp`` (deleted with it, never committed)."""

    def __init__(self, tmp):
        self.dir = os.path.join(tmp, "keys")
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        self.ca = os.path.join(self.dir, "ca")
        self.user = os.path.join(self.dir, "user")
        for path in (self.ca, self.user):
            if not os.path.exists(path):
                subprocess.run(
                    ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", path],
                    check=True,
                )

    def sign(self, key_id, principal=PRINCIPAL, validity="+10m"):
        cert = f"{self.user}-cert.pub"
        if os.path.exists(cert):
            os.unlink(cert)
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-s",
                self.ca,
                "-I",
                key_id,
                "-n",
                principal,
                "-V",
                validity,
                f"{self.user}.pub",
            ],
            check=True,
            capture_output=True,
        )
        return cert


def _find_sshd():
    for candidate in (
        os.environ.get("BURROW_SUPPORT_TEST_SSHD"),
        shutil.which("sshd"),
        "/usr/sbin/sshd",
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


def _free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


SSHD = _find_sshd()


@unittest.skipUnless(SSHD and shutil.which("ssh") and shutil.which("ssh-keygen"), "needs OpenSSH")
@unittest.skipIf(os.geteuid() == 0, "the rig runs sshd unprivileged, as the test user")
class SshdIntegrationTest(unittest.TestCase):
    """The rendered principals command and shell wrapper behind a real sshd.

    Unprivileged sshd can only log in its own user, so the copies under test
    have ONE line changed: SUPPORT_USER is the test user instead of
    burrow-support. Everything else is the shipped file.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="burrow-support-sshd-")
        cls.me = (
            os.environ.get("USER")
            or subprocess.run(
                ["id", "-un"], capture_output=True, text=True, check=True
            ).stdout.strip()
        )
        cls.keys = KeyRig(cls.tmp)
        cls.state = os.path.join(cls.tmp, "state.json")
        cls.events = os.path.join(cls.tmp, "events.jsonl")
        bin_dir = os.path.join(cls.tmp, "bin")
        os.makedirs(bin_dir)
        for src in (PRINCIPALS, SHELL):
            with open(src, encoding="utf-8") as handle:
                text = handle.read()
            line = 'SUPPORT_USER = "burrow-support"\n'
            assert text.count(line) == 1, src
            with open(os.path.join(bin_dir, os.path.basename(src)), "w") as handle:
                handle.write(text.replace(line, f'SUPPORT_USER = "{cls.me}"\n'))
        with open(f"{cls.keys.ca}.pub") as handle:
            ca_pub = os.path.join(cls.tmp, "burrow-support-ca.pub")
            with open(ca_pub, "w") as out:
                out.write(handle.read())
        host_key = os.path.join(cls.tmp, "host_ed25519")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", host_key], check=True)
        # sshd runs AuthorizedPrincipalsCommand only from a root-owned path.
        py = next(
            (
                c
                for c in (sys.executable, "/usr/bin/python3")
                if os.path.exists(c) and os.stat(os.path.realpath(c)).st_uid == 0
            ),
            None,
        )
        if py is None:
            shutil.rmtree(cls.tmp, True)
            raise unittest.SkipTest("needs a root-owned python3 for sshd's command checks")
        # The shipped drop-in with this rig's paths and user substituted: the
        # sshd check that the command path is root-owned is met by running the
        # scripts through the (root-owned) python interpreter.
        dropin = support.dropin("/opt/burrow")
        dropin = dropin.replace(f"Match User {support.SUPPORT_USER}", f"Match User {cls.me}")
        dropin = dropin.replace(support.CA_PATH, ca_pub)
        dropin = dropin.replace(
            "/opt/burrow/bin/burrow-support-principals %u %i",
            f"{py} -I {bin_dir}/burrow-support-principals %u %i {cls.state}",
        )
        dropin = dropin.replace(f"CommandUser {support.CHECK_USER}", f"CommandUser {cls.me}")
        dropin = dropin.replace(
            "ForceCommand /opt/burrow/bin/burrow-support-shell",
            f"SetEnv BURROW_SUPPORT_SHELL_TEST_DIR={cls.tmp} BURROW_SUPPORT_SHELL_CHECK_S=1\n"
            f"    ForceCommand {py} -I {bin_dir}/burrow-support-shell",
        )
        dropin_path = os.path.join(cls.tmp, "60-burrow-support.conf")
        with open(dropin_path, "w") as handle:
            handle.write(dropin)
        cls.port = _free_port()
        config = os.path.join(cls.tmp, "sshd_config")
        with open(config, "w") as handle:
            handle.write(
                f"Include {dropin_path}\n"
                f"Port {cls.port}\nListenAddress 127.0.0.1\nHostKey {host_key}\n"
                f"PidFile none\nStrictModes no\nAuthorizedKeysFile none\n"
                f"PasswordAuthentication no\nKbdInteractiveAuthentication no\n"
                f"LogLevel VERBOSE\n"
            )
        check = subprocess.run(
            [SSHD, "-t", "-f", config], check=False, capture_output=True, text=True
        )
        if check.returncode != 0:
            raise AssertionError(f"sshd -t failed: {check.stderr}")
        cls.log = os.path.join(cls.tmp, "sshd.log")
        with open(cls.log, "w") as log:
            cls.sshd = subprocess.Popen(
                [SSHD, "-D", "-e", "-f", config], stdout=subprocess.DEVNULL, stderr=log
            )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            with socket.socket() as sock:
                if sock.connect_ex(("127.0.0.1", cls.port)) == 0:
                    break
            time.sleep(0.1)
        else:
            raise AssertionError("sshd did not start")

    @classmethod
    def tearDownClass(cls):
        cls.sshd.terminate()
        cls.sshd.wait(timeout=10)
        shutil.rmtree(cls.tmp, True)

    def ssh(self, command="echo repair-ok", timeout=60, popen=False):
        argv = [
            "ssh",
            "-F",
            "/dev/null",
            "-p",
            str(self.port),
            "-i",
            self.keys.user,
            "-o",
            f"CertificateFile={self.keys.user}-cert.pub",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "IdentityAgent=none",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "PreferredAuthentications=publickey",
            f"{self.me}@127.0.0.1",
            command,
        ]
        if popen:
            return subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        return subprocess.run(
            argv,
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def test_00_cert_logs_in_while_on(self):
        write_state(self.state)
        self.keys.sign(SID)
        result = self.ssh()
        with open(self.log) as handle:
            self.assertEqual(result.returncode, 0, result.stderr + handle.read()[-2000:])
        self.assertIn("repair-ok", result.stdout)
        self.assertIn(SID, {e["session_id"] for e in read_events(self.events)})

    def test_refused_after_the_switch_turns_off(self):
        write_state(self.state)
        self.keys.sign(SID)
        self.assertEqual(self.ssh().returncode, 0)  # positive control
        write_state(self.state, enabled=False)
        result = self.ssh()
        self.assertEqual(result.returncode, 255, result.stdout)
        self.assertNotIn("repair-ok", result.stdout)

    def test_refused_after_not_after(self):
        past = (datetime.datetime.now(datetime.UTC) - datetime.timedelta(seconds=5)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        write_state(self.state, not_after=past)
        self.keys.sign(SID)  # the certificate itself is still valid
        self.assertEqual(self.ssh().returncode, 255)

    def test_refused_for_an_unknown_key_id_or_a_missing_file(self):
        write_state(self.state)
        self.keys.sign("not-a-session")
        self.assertEqual(self.ssh().returncode, 255)
        self.keys.sign(SID)
        os.unlink(self.state)
        self.assertEqual(self.ssh().returncode, 255)

    def test_open_session_ends_when_the_switch_turns_off(self):
        write_state(self.state)
        self.keys.sign(SID)
        proc = self.ssh("sleep 60", popen=True)
        self.addCleanup(proc.communicate)
        self.addCleanup(proc.kill)
        time.sleep(3)
        self.assertIsNone(proc.poll(), "the session must be open before the switch flips")
        flipped = time.monotonic()
        write_state(self.state, enabled=False)
        proc.wait(timeout=30)
        self.assertLess(time.monotonic() - flipped, 15)

    def test_dropin_scopes_the_ca_to_the_support_user(self):
        config = os.path.join(self.tmp, "sshd_config")

        def effective(user):
            out = subprocess.run(
                [SSHD, "-T", "-f", config, "-C", f"user={user},host=x,addr=127.0.0.1"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.lower()
            return dict(line.split(" ", 1) for line in out.splitlines() if " " in line)

        mine, other = effective(self.me), effective("root")
        self.assertNotEqual(mine["trustedusercakeys"], "none")
        self.assertEqual(other["trustedusercakeys"], "none")
        self.assertEqual(other["authorizedprincipalscommand"], "none")
        self.assertNotIn("forcecommand", {k for k, v in other.items() if v != "none"})
        # "Match all" closes the block: the main config's lines are global.
        self.assertEqual(other["passwordauthentication"], "no")
