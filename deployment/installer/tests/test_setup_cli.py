"""The setup CLI's contract: inputs, refusals, status, init, render idempotence.

Task 01a0d6ab stage 4. Every refusal test has a positive control showing the
accepted form proceeds.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from setup_fakes import (
    MAC,
    MAC_LITE,
    FakeCloudflare,
    FakeHost,
    FakeKeychain,
    run_cli,
    write_secret_file,
)

from suite_install.manifest import load
from suite_install.secrets import parse_env_file
from suite_install.setup import cli, steps
from suite_install.setup.state import dumps_toml

SECRET = "sk-FAKE-01a0d6ab-never-print-me-123456"
CF_TOKEN = "cf-FAKE-01a0d6ab-token-for-render"
REGISTRY_AUTH = json.dumps({"auths": {"https://index.docker.io/v1/": {"auth": "dTpw"}}})


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cli-01a0d6ab-")
        self.dir = os.path.join(self.tmp, "inst")
        self.host = FakeHost(self.tmp)
        self.keychain = FakeKeychain({"OPENAI_API_KEY": SECRET})
        self.env = cli.Env(host=self.host, keychain=self.keychain, environ={"K": SECRET})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def init(self, source=MAC_LITE, *flags):
        code, doc, _ = run_cli(
            self.env, "init", "--from", source, "--dir", self.dir, "--name", "suite-01a0d6ab",
            "--domain", "suite-01a0d6ab.example.com", *flags,
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        return doc

    def state(self):
        with open(os.path.join(self.dir, "state.json"), encoding="utf-8") as handle:
            return json.load(handle)


class SecretInArgvTest(Base):
    def test_literal_secret_is_refused_and_never_echoed_or_stored(self):
        self.init()
        code, doc, text = run_cli(
            self.env, "run", "render", "--dir", self.dir, "--input", f"OPENAI_API_KEY={SECRET}"
        )
        self.assertEqual((code, doc["error_code"]), (2, "secret_in_argv"), doc)
        self.assertNotIn(SECRET, text)
        self.assertNotIn("OPENAI_API_KEY", self.state()["inputs"])
        self.assertIn("setup secret OPENAI_API_KEY", doc["remediation"])

    def test_positive_control_file_env_and_keychain_refs_are_accepted(self):
        self.init()
        path = write_secret_file(self.tmp, "openai", SECRET)
        for ref in (f"@{path}", "env:K", "keychain:OPENAI_API_KEY"):
            _code, doc, text = run_cli(
                self.env, "run", "preflight", "--dir", self.dir, "--input", f"OPENAI_API_KEY={ref}"
            )
            # preflight itself then stops on REGISTRY_AUTH; the input was taken.
            self.assertNotEqual(doc.get("error_code"), "secret_in_argv", doc)
            self.assertEqual(self.state()["inputs"]["OPENAI_API_KEY"], ref if ref[0] != "@" else
                             "@" + os.path.realpath(path))  # fmt: skip
            self.assertNotIn(SECRET, text)

    def test_non_secret_literal_is_accepted(self):
        self.init()
        run_cli(self.env, "run", "preflight", "--dir", self.dir, "--input", "ADMIN_EMAIL=a@b.test")
        self.assertEqual(self.state()["inputs"]["ADMIN_EMAIL"], "a@b.test")

    def test_world_readable_secret_file_is_refused(self):
        self.init()
        path = write_secret_file(self.tmp, "loose", SECRET, mode=0o644)
        code, doc, text = run_cli(
            self.env, "run", "preflight", "--dir", self.dir, "--input", f"OPENAI_API_KEY=@{path}"
        )
        self.assertEqual((code, doc["error_code"]), (2, "secret_file_permissions"), doc)
        self.assertIn(f"chmod 600 {path}", doc["remediation"])
        self.assertNotIn(SECRET, text)

    def test_unknown_input_is_refused(self):
        self.init()
        code, doc, _ = run_cli(
            self.env, "run", "preflight", "--dir", self.dir, "--input", "NOPE=@/x"
        )
        self.assertEqual((code, doc["error_code"]), (2, "unknown_input"))

    def test_usage_error_does_not_echo_the_argument(self):
        self.init()
        code, doc, text = run_cli(self.env, "run", "render", "--dir", self.dir, SECRET)
        self.assertEqual((code, doc["error_code"]), (2, "usage"), doc)
        self.assertNotIn(SECRET, text)


class InitAndStatusTest(Base):
    def test_status_lists_every_step_and_its_needs(self):
        self.init()
        code, doc, _ = run_cli(self.env, "status", "--json", "--dir", self.dir)
        self.assertEqual(code, 0)
        self.assertEqual([r["name"] for r in doc["steps"]], [s.name for s in steps.STEPS])
        rows = {r["name"]: r for r in doc["steps"]}
        self.assertEqual(rows["preflight"]["needs"], ["REGISTRY_AUTH"])
        self.assertEqual(rows["domain"]["needs"], ["CLOUDFLARE_API_TOKEN"])
        self.assertEqual(rows["render"]["needs"], ["OPENAI_API_KEY", "REGISTRY_AUTH"])
        self.assertEqual((rows["up"]["state"], rows["up"]["needs"]), ("pending", ["ADMIN_EMAIL"]))
        self.assertEqual(rows["verify"]["state"], "blocked")
        self.assertIn("waiting for", rows["verify"]["blocked_reason"])
        self.assertTrue(rows["ddns"]["skipped"])  # meetings off
        self.assertTrue(rows["keepalive"]["advisory"])
        self.assertEqual(doc["next_step"], "preflight")
        self.assertFalse(doc["complete"])
        for row in doc["steps"]:
            self.assertIn(row["state"], ("done", "pending", "blocked"))

    def test_step_order_is_enforced(self):
        self.init()
        code, doc, _ = run_cli(self.env, "run", "up", "--dir", self.dir)
        self.assertEqual((code, doc["error_code"]), (2, "step_order"), doc)

    def test_missing_input_is_exit_3_naming_it(self):
        self.init()
        code, doc, _ = run_cli(self.env, "run", "domain", "--dir", self.dir)
        self.assertEqual((code, doc["error_code"]), (3, "input_missing"))
        self.assertIn("CLOUDFLARE_API_TOKEN", doc["error"])

    def test_init_flip_meetings_rewrites_a_valid_manifest(self):
        self.init(MAC)
        doc = self.init(MAC, "--meetings", "off")
        self.assertEqual(doc["changed"], ["services.meetings"])
        self.assertFalse(load(os.path.join(self.dir, "install.toml"))["services"]["meetings"])

    def test_init_image_namespace_flag_sets_the_required_input(self):
        # Task 01a14b9e: images.image_namespace has no default; init sets it.
        self.init(MAC)
        doc = self.init(MAC, "--image-namespace", "acme-images")
        self.assertEqual(doc["changed"], ["images.image_namespace"])
        m = load(os.path.join(self.dir, "install.toml"))
        self.assertEqual(m["images"]["image_namespace"], "acme-images")

    def test_init_refuses_a_manifest_without_an_image_namespace(self):
        raw = load(MAC_LITE)
        del raw["images"]["image_namespace"]
        source = os.path.join(self.tmp, "no-ns.toml")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write(dumps_toml(raw))
        code, doc, _ = run_cli(self.env, "init", "--from", source, "--dir", self.dir)
        self.assertEqual((code, doc["error_code"]), (2, "manifest_invalid"), doc)
        self.assertIn("missing_required at images.image_namespace", doc["error"])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "install.toml")))

    def test_install_dir_inside_git_tree_is_refused(self):
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(repo, ".git"))
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", os.path.join(repo, "inst")
        )
        self.assertEqual((code, doc["error_code"]), (2, "install_dir_inside_git_worktree"))
        self.assertFalse(os.path.exists(os.path.join(repo, "inst")))

    def test_toml_round_trip_of_both_examples(self):
        for path in (MAC, MAC_LITE):
            raw = load(path)
            out = os.path.join(self.tmp, "rt.toml")
            with open(out, "w", encoding="utf-8") as handle:
                handle.write(dumps_toml(raw))
            self.assertEqual(load(out), raw)


class SecretCommandTest(Base):
    def test_secret_stores_in_keychain_and_records_only_the_reference(self):
        self.init()
        code, doc, text = run_cli(self.env, "secret", "OPENAI_API_KEY", "--dir", self.dir)
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["keychain_service"], "suite-install.suite-01a0d6ab")
        self.assertEqual(doc["length"], len(SECRET))
        self.assertEqual(
            self.keychain.items[("suite-install.suite-01a0d6ab", "OPENAI_API_KEY")], SECRET
        )
        self.assertEqual(self.state()["inputs"]["OPENAI_API_KEY"], "keychain:OPENAI_API_KEY")
        self.assertNotIn(SECRET, text)
        with open(os.path.join(self.dir, "state.json"), encoding="utf-8") as handle:
            self.assertNotIn(SECRET, handle.read())


class RenderIdempotenceTest(Base):
    """Two renders: every secrets.env value's sha256 is unchanged."""

    source = MAC_LITE

    def setUp(self):
        super().setUp()
        from suite_install import registry

        self._detectors = dict(registry.MEDIA_IP_DETECTORS)
        registry.MEDIA_IP_DETECTORS["lan"] = lambda: "192.0.2.10"  # RFC 5737
        self.cf = FakeCloudflare(CF_TOKEN)
        self.env.environ.update({"CF": CF_TOKEN, "RA": REGISTRY_AUTH})
        self.env.configure = lambda ctx: setattr(ctx, "cloudflare_api", self.cf.url)
        self.init(
            self.source, "--auth-host", "auth-01a0d6ab.example.com",
            "--livekit-host", "livekit-01a0d6ab.example.com",
        )  # fmt: skip
        state = self.state()
        # preflight is covered elsewhere; mark it done so render may run.
        state["steps"]["preflight"] = {"state": "done", "at": "x"}
        with open(os.path.join(self.dir, "state.json"), "w", encoding="utf-8") as handle:
            json.dump(state, handle)
        for name, extra in (
            ("domain", ["--input", "CLOUDFLARE_API_TOKEN=env:CF"]),
            ("tunnel", []),
        ):
            code, doc, _ = run_cli(self.env, "run", name, "--dir", self.dir, *extra)
            self.assertEqual(code, 0, doc)

    def tearDown(self):
        from suite_install import registry

        registry.MEDIA_IP_DETECTORS.update(self._detectors)
        self.cf.close()
        super().tearDown()

    def render(self):
        code, doc, text = run_cli(
            self.env, "run", "render", "--dir", self.dir,
            "--input", "OPENAI_API_KEY=env:K", "--input", "REGISTRY_AUTH=env:RA",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        self.assertNotIn(SECRET, text)
        values = parse_env_file(os.path.join(self.dir, "secrets.env"))
        return doc, {k: hashlib.sha256(v.encode()).hexdigest() for k, v in values.items()}

    def test_second_render_keeps_every_secret(self):
        first_doc, first = self.render()
        self.assertIn("TUNNEL_TOKEN", first)
        self.assertIn("POSTGRES_PASSWORD", first_doc["outputs"]["secrets_new"])
        second_doc, second = self.render()
        self.assertEqual(first, second)
        self.assertEqual(second_doc["outputs"]["secrets_changed"], [])
        self.assertEqual(second_doc["outputs"]["secrets_new"], [])
        self.assertEqual(os.stat(os.path.join(self.dir, "secrets.env")).st_mode & 0o777, 0o600)
        # Positive control: the sha comparison CAN differ (a fresh install).
        other = os.path.join(self.tmp, "fresh")
        shutil.copytree(self.dir, other, ignore=shutil.ignore_patterns("secrets.env"))
        from suite_install.setup.state import Install

        Install(other).upsert_secret("TUNNEL_TOKEN", self.cf.tunnel_token)
        code, doc, _ = run_cli(self.env, "run", "render", "--dir", other)
        self.assertEqual(code, 0, doc)
        fresh = parse_env_file(os.path.join(other, "secrets.env"))
        self.assertNotEqual(
            hashlib.sha256(fresh["POSTGRES_PASSWORD"].encode()).hexdigest(),
            first["POSTGRES_PASSWORD"],
        )


class InstallDockerConfigTest(RenderIdempotenceTest):
    """The install's DOCKER_CONFIG keeps the credential AND the compose plugin.

    lab-host, 2026-10-05: OrbStack puts docker-compose only in
    ~/.docker/cli-plugins, so a DOCKER_CONFIG holding just the credential
    lost `docker compose` and `up` failed ("unknown flag: --project-directory").
    """

    def test_second_render_keeps_every_secret(self):
        pass  # covered by the parent

    def test_config_carries_the_credential_and_the_user_plugin_dir(self):
        self.render()
        path = os.path.join(self.dir, ".docker", "config.json")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
        self.assertEqual(doc["auths"], json.loads(REGISTRY_AUTH)["auths"])
        home = self.env.host.home()
        self.assertIn(f"{home}/.docker/cli-plugins", doc["cliPluginsExtraDirs"])
        # Positive control: the raw credential alone has no plugin dirs, which
        # is the shape that lost `docker compose` on OrbStack.
        self.assertNotIn("cliPluginsExtraDirs", json.loads(REGISTRY_AUTH))


class MeetingsFlipTest(RenderIdempotenceTest):
    """mac (meetings on) -> meetings off: livekit.yaml goes, secrets stay."""

    source = MAC

    def test_second_render_keeps_every_secret(self):
        pass  # covered by the parent on mac-lite

    def test_flip_off_removes_stale_files_and_keeps_shared_secrets(self):
        _doc, before = self.render()
        self.assertTrue(os.path.exists(os.path.join(self.dir, "livekit.yaml")))  # control
        code, doc, _ = run_cli(self.env, "init", "--dir", self.dir, "--meetings", "off")
        self.assertEqual((code, doc["changed"]), (0, ["services.meetings"]), doc)
        # init reset downstream steps; tunnel re-runs (ingress drops livekit).
        for name in ("domain", "tunnel"):
            code, doc, _ = run_cli(self.env, "run", name, "--dir", self.dir)
            self.assertEqual(code, 0, doc)
        self.assertEqual(doc["outputs"]["ingress"], "updated")
        doc, after = self.render()
        self.assertIn("livekit.yaml", doc["outputs"]["removed"])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "livekit.yaml")))
        shared = set(before) & set(after)
        self.assertIn("POSTGRES_PASSWORD", shared)
        self.assertEqual({k: before[k] for k in shared}, {k: after[k] for k in shared})
        self.assertNotIn("LIVEKIT_API_SECRET", after)


class BackupScriptTest(unittest.TestCase):
    """backup.sh against a stub `docker` on PATH: dumps, verification lines, rotation."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bk-01a0d6ab-")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        stub = os.path.join(self.bin, "docker")
        with open(stub, "w") as handle:
            handle.write(
                "#!/bin/bash\n"
                'case "$*" in\n'
                '  *psql*) printf "core_platform\\nmemory\\npocketid\\n" ;;\n'
                '  *pg_dump*) printf "PGDMP-fake" ;;\n'
                '  *"pg_restore --list"*) cat >/dev/null; printf ";\\n; header\\n1; a\\n2; b\\n" ;;\n'
                "esac\n"
            )
        os.chmod(stub, 0o755)
        self.out = os.path.join(self.tmp, "backups")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_backup(self, keep="2"):
        script = os.path.join(INSTALLER, "mac", "backup.sh")
        return subprocess.run(
            ["bash", script, self.tmp, self.out, keep],
            env={"PATH": f"{self.bin}:/usr/bin:/bin"},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_dumps_each_database_and_verifies(self):
        proc = self.run_backup()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        verified = [ln.split() for ln in proc.stdout.splitlines() if ln.startswith("verified")]
        self.assertEqual(
            sorted((v[1], v[2]) for v in verified),
            [("core_platform", "2"), ("memory", "2"), ("pocketid", "2")],
        )
        self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o700)

    def test_rotation_keeps_the_newest(self):
        os.makedirs(self.out)
        for stamp in ("20200101T000000Z", "20200102T000000Z", "20200103T000000Z"):
            open(os.path.join(self.out, f"memory-{stamp}.dump"), "w").close()
        proc = self.run_backup(keep="2")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        memory = sorted(f for f in os.listdir(self.out) if f.startswith("memory-"))
        self.assertEqual(len(memory), 2)
        self.assertNotIn("memory-20200101T000000Z.dump", memory)
        self.assertNotIn("memory-20200102T000000Z.dump", memory)


if __name__ == "__main__":
    unittest.main()
