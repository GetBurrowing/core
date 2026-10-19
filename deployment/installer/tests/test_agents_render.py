"""Native agents' capability profiles in the install manifest (core task 01a10322 stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

What is pinned here, each check with a positive control:

- ``[agents] profile`` validates as ``full_machine | contained | off``; a
  manifest WITHOUT the table is ``off`` and renders byte-identically to one
  that says ``off`` (and the pre-existing goldens, in test_render.py, stay
  byte-unchanged).
- ``full_machine`` puts the agent host on the HOST: the sudoers file (mode
  0440, accepted by ``visudo -cf`` where visudo exists), both units, the setup
  unit and the CLI pins are in cloud-init user-data, and no agent-host
  container is in compose.
- ``contained`` puts it in a container on the agents network ONLY, with
  core-platform the one service on both networks, its own env file holding
  only AGENT_HOST_TOKEN, and NO sudoers file or agent-host unit on the host.
- The installer's embedded packaging texts equal services/agent-host's files
  byte for byte (the image ships those files).

The network reach itself (agent host -> core-platform yes, -> Postgres no) is a
property of podman/docker, not of this renderer, and is measured on test-host by
services/agent-host/test/contained/reachability.sh.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
MAC = os.path.join(REPO, "deployment", "examples", "mac.install.toml")
FIXTURES = os.path.join(HERE, "render_fixtures")
FULL = os.path.join(FIXTURES, "single-host-agents-full.toml")
CONTAINED = os.path.join(FIXTURES, "single-host-agents-contained.toml")
AGENT_HOST_DIR = os.path.join(REPO, "services", "agent-host")
CI_WORKFLOW = os.path.join(REPO, ".github", "workflows", "ci.yml")

sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from migrate_embed import cut_migrate_script

from burrow_install import agents
from burrow_install.manifest import load
from burrow_install.render import RenderError, build
from burrow_install.validate import validate


def manifest_from(path):
    errors, normalized = validate(load(path))
    if errors:
        raise AssertionError(f"fixture {path} is invalid: {errors}")
    return normalized


def with_agents(path, table):
    raw = load(path)
    if table is None:
        raw.pop("agents", None)
    else:
        raw["agents"] = table
    return raw


def write_files(user_data):
    """{path: (permissions, content)} from our YAML writer's write_files list."""
    out = {}
    entries = re.split(r"^  - path: ", user_data, flags=re.MULTILINE)[1:]
    for entry in entries:
        lines = entry.split("\n")
        path = lines[0].strip('"')
        perms = re.search(r'^    permissions: "(\d+)"$', entry, flags=re.MULTILINE).group(1)
        start = lines.index("    content: |") + 1
        body = []
        for line in lines[start:]:
            if line.startswith("      "):
                body.append(line[6:])
            elif line == "":
                body.append("")
            else:
                break
        while body and body[-1] == "":
            body.pop()
        out[path] = (perms, "\n".join(body) + "\n")
    return out


def compose_services(compose):
    """{service: block text} from compose.yaml (services at two-space indent)."""
    body = compose.split("\nservices:\n", 1)[1]
    body = re.split(r"^\S", body, maxsplit=1, flags=re.MULTILINE)[0]
    blocks = re.split(r"^  (?=[a-z][a-z0-9-]*:$)", body, flags=re.MULTILINE)
    return {b.split(":", 1)[0]: b for b in blocks if b.strip()}


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


class PositiveControl(unittest.TestCase):
    """The readers find what they look for in a render that has it."""

    def test_readers_find_the_stack_unit_and_core_platform(self):
        rendered = build(manifest_from(EXAMPLE))
        files = write_files(rendered.files["user-data"][0])
        self.assertIn("/etc/systemd/system/burrow-stack.service", files)
        self.assertEqual(files["/opt/burrow/secrets.env"][0], "0600")
        self.assertEqual(files["/opt/burrow/compose.yaml"][1], rendered.files["compose.yaml"][0])
        services = compose_services(rendered.files["compose.yaml"][0])
        self.assertIn("core-platform", services)
        self.assertIn("core-postgres", services)


class YamlTest(unittest.TestCase):
    def test_both_profiles_render_compose_and_user_data_that_parse(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed (stdlib-only CI container)")
        for path in (FULL, CONTAINED):
            with self.subTest(fixture=os.path.basename(path)):
                rendered = build(manifest_from(path))
                compose = yaml.safe_load(rendered.files["compose.yaml"][0])
                user_data = yaml.safe_load(rendered.files["user-data"][0])
                by_path = {w["path"]: w for w in user_data["write_files"]}
                # The reader this file uses agrees with a real YAML parser.
                for wpath, (perms, content) in write_files(rendered.files["user-data"][0]).items():
                    self.assertEqual(by_path[wpath]["permissions"], perms, wpath)
                    self.assertEqual(by_path[wpath]["content"], content, wpath)
                self.assertEqual(len(by_path), len(write_files(rendered.files["user-data"][0])))
                if path == CONTAINED:
                    ah = compose["services"]["agent-host"]
                    self.assertEqual(list(ah["networks"]), ["agents"])
                    self.assertEqual(
                        list(compose["services"]["core-platform"]["networks"]),
                        ["default", "agents"],
                    )
                    self.assertEqual(list(compose["networks"]), ["agents"])
                else:
                    self.assertNotIn("agent-host", compose["services"])
                    self.assertEqual(by_path[agents.SUDOERS_PATH]["permissions"], "0440")


class ValidateTest(unittest.TestCase):
    def test_each_profile_is_accepted(self):
        for profile in ("full_machine", "contained", "off"):
            with self.subTest(profile=profile):
                errors, m = validate(with_agents(EXAMPLE, {"profile": profile}))
                self.assertEqual(errors, [])
                self.assertEqual(m["agents"]["profile"], profile)

    def test_unknown_profile_is_one_invalid_enum(self):
        errors, m = validate(with_agents(EXAMPLE, {"profile": "full-machine"}))
        self.assertIsNone(m)
        self.assertEqual([(e.code, e.path) for e in errors], [("invalid_enum", "agents.profile")])

    def test_unknown_key_in_the_table_is_refused(self):
        errors, _m = validate(with_agents(EXAMPLE, {"profile": "contained", "sudo": False}))
        self.assertEqual([(e.code, e.path) for e in errors], [("unknown_key", "agents.sudo")])

    def test_absent_table_is_off_and_an_empty_one_is_full_machine(self):
        _e, absent = validate(with_agents(EXAMPLE, None))
        _e, empty = validate(with_agents(EXAMPLE, {}))
        self.assertEqual(absent["agents"]["profile"], "off")
        self.assertEqual(empty["agents"]["profile"], "full_machine")

    def test_mac_refuses_an_agents_profile_but_accepts_off_or_none(self):
        for table, ok in (
            (None, True),
            ({"profile": "off"}, True),
            ({"profile": "full_machine"}, False),
            ({"profile": "contained"}, False),
            ({}, False),
        ):
            with self.subTest(table=table):
                errors, _m = validate(with_agents(MAC, table))
                codes = [(e.code, e.path) for e in errors]
                self.assertEqual(codes, [] if ok else [("field_not_applicable", "agents.profile")])


class OffTest(unittest.TestCase):
    def test_absent_and_explicit_off_render_byte_identical_files(self):
        absent = build(manifest_from(EXAMPLE)).redacted()
        _e, off = validate(with_agents(EXAMPLE, {"profile": "off"}))
        explicit = build(off).redacted()
        self.assertEqual(sorted(absent), sorted(explicit))
        for rel in absent:
            self.assertEqual(absent[rel], explicit[rel], rel)

    def test_off_renders_no_agent_literal(self):
        # bin/burrow-migrate names the agent host on every render (migrate_embed.py).
        text, cut = cut_migrate_script("\n".join(build(manifest_from(EXAMPLE)).redacted().values()))
        self.assertEqual(cut, 1)
        for literal in ("AGENT_HOST", "agent-host", "burrow-agent", "sudoers", "agents"):
            self.assertNotIn(literal, text)
        # Positive control: the same search hits a full_machine render.
        full = "\n".join(build(manifest_from(FULL)).redacted().values())
        for literal in ("AGENT_HOST", "agent-host", "burrow-agent", "sudoers"):
            self.assertIn(literal, full)


class FullMachineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = build(manifest_from(FULL))
        cls.user_data = cls.rendered.files["user-data"][0]
        cls.files = write_files(cls.user_data)

    def test_sudoers_is_0440_and_exactly_the_group_grant(self):
        perms, text = self.files[agents.SUDOERS_PATH]
        self.assertEqual(perms, "0440")
        self.assertEqual(text, agents.SUDOERS)
        grants = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
        self.assertEqual(grants, ["%burrow-agents ALL=(ALL) NOPASSWD:ALL"])
        self.assertEqual(agents.SUDOERS_PATH, "/etc/sudoers.d/burrow-agents")

    def test_sudoers_passes_visudo(self):
        visudo = shutil.which("visudo") or (
            "/usr/sbin/visudo" if os.path.exists("/usr/sbin/visudo") else None
        )
        if visudo is None:
            self.skipTest("visudo not installed here (the agent-host image build runs it too)")
        with tempfile.TemporaryDirectory(prefix="sudoers-01a10322-") as tmp:
            good = os.path.join(tmp, "burrow-agents")
            with open(good, "w", encoding="utf-8") as handle:
                handle.write(self.files[agents.SUDOERS_PATH][1])
            ok = subprocess.run([visudo, "-cf", good], capture_output=True, text=True, check=False)
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            # Positive control: visudo really rejects a broken file.
            bad = os.path.join(tmp, "broken")
            with open(bad, "w", encoding="utf-8") as handle:
                handle.write("%burrow-agents ALL=(ALL NOPASSWD:ALL\n")
            ko = subprocess.run([visudo, "-cf", bad], capture_output=True, text=True, check=False)
            self.assertNotEqual(ko.returncode, 0)

    def test_both_units_and_the_setup_unit_are_written(self):
        self.assertEqual(
            self.files["/etc/systemd/system/burrow-agent-host.service"],
            ("0644", agents.HOST_UNIT),
        )
        self.assertEqual(
            self.files["/etc/systemd/system/burrow-agent@.service"],
            ("0644", agents.AGENT_TEMPLATE_UNIT),
        )
        setup = self.files["/etc/systemd/system/burrow-agent-host-setup.service"][1]
        self.assertIn("ExecStart=/opt/burrow/bin/burrow-agent-host-setup", setup)
        dropin = self.files["/etc/systemd/system/burrow-agent-host.service.d/10-full-machine.conf"]
        self.assertIn("Requires=burrow-agent-host-setup.service", dropin[1])
        self.assertIn("After=burrow-agent-host-setup.service burrow-stack.service", dropin[1])
        self.assertIn(
            '["systemctl", "enable", "burrow-agent-host-setup.service", "burrow-agent-host.service"]',
            self.user_data,
        )
        self.assertIn(
            "Wants=burrow-agent-host.service",
            self.files["/etc/systemd/system/burrow-stack.service"][1],
        )
        env = self.files["/etc/burrow-agent-host.env"]
        self.assertEqual(env[0], "0600")
        self.assertIn("Read by burrow-agent-host.service only.", env[1])
        self.assertIn("/etc/burrow-agent-host/versions.env", self.files)

    def test_the_cli_pins_are_the_ones_in_versions_env(self):
        pins = [
            ln
            for ln in read(os.path.join(AGENT_HOST_DIR, "versions.env")).splitlines()
            if ln and not ln.startswith("#")
        ]
        self.assertEqual(
            sorted(p.split("=")[0] for p in pins),
            [
                "BUN_VERSION",
                "BURROW_CLI_REF",
                "CLAUDE_CODE_VERSION",
                "CODEX_VERSION",
                "NODE_VERSION",
                "SUITE_CLI_REF",
            ],
        )
        perms, text = self.files[agents.VERSIONS_PATH]
        self.assertEqual(perms, "0644")
        for pin in pins:
            self.assertIn(pin, text.splitlines())
        script = self.files["/opt/burrow/bin/burrow-agent-host-setup"][1]
        self.assertIn(f'install-tools.sh" {agents.VERSIONS_PATH}', script)

    def test_setup_script_uses_the_burrow_group_and_daemon_path(self):
        # services/agent-host/src/ids.ts AGENTS_GROUP and the image's WORKDIR.
        script = self.files["/opt/burrow/bin/burrow-agent-host-setup"][1]
        self.assertIn("groupadd --system burrow-agents", script)
        self.assertIn('docker cp "$ctr:/opt/burrow/agent-host" "$dest.incoming"', script)
        self.assertIn("dest=/opt/burrow/agent-host", script)
        ids = read(os.path.join(AGENT_HOST_DIR, "src", "ids.ts"))
        self.assertIn(f'"{agents.AGENTS_GROUP}"', ids)

    def test_agent_host_env_is_0600_and_carries_the_same_token_as_core(self):
        perms, text = self.files[agents.HOST_ENV_PATH]
        self.assertEqual(perms, "0600")
        token = self.rendered.generated["AGENT_HOST_TOKEN"]
        self.assertIn(f"AGENT_HOST_TOKEN={token}\n", text)
        self.assertIn(f"AGENT_HOST_TOKEN={token}\n", self.rendered.files["secrets.env"][0])
        self.assertIn("AGENT_HOST_PROFILE=full_machine\n", text)
        self.assertIn(
            "BURROW_CORE_URL=https://burrow-01a0d69d.test\n"
            "SUITE_CORE_URL=https://burrow-01a0d69d.test\n",
            text,
        )
        # Only that: no other secret of the install reaches the host daemon.
        others = [v for k, v in self.rendered.generated.items() if k != "AGENT_HOST_TOKEN"]
        self.assertTrue(others)
        self.assertFalse([v for v in others if v in text])

    def test_no_agent_host_container_and_core_sends_no_internal_url(self):
        services = compose_services(self.rendered.files["compose.yaml"][0])
        self.assertNotIn("agent-host", services)
        self.assertNotIn("networks:", services["core-platform"])
        self.assertNotIn("AGENT_HOST_CORE_URL", self.rendered.files["compose.yaml"][0])

    def test_internal_tls_root_is_trusted_by_the_host(self):
        script = self.files["/opt/burrow/bin/burrow-agent-host-setup"][1]
        self.assertIn("update-ca-certificates", script)
        # Positive control: an acme install has no internal root to trust.
        raw = load(FULL)
        raw["domain"] = {"primary": "burrow.example.com", "tls": "acme", "acme_email": "a@b.co"}
        _e, m = validate(raw)
        acme = write_files(build(m).files["user-data"][0])[
            "/opt/burrow/bin/burrow-agent-host-setup"
        ]
        self.assertNotIn("update-ca-certificates", acme[1])

    def test_host_packages_are_added_only_for_full_machine(self):
        for pkg in agents.FULL_MACHINE_PACKAGES:
            self.assertIn(f'  - "{pkg}"', self.user_data)
        plain = build(manifest_from(EXAMPLE)).files["user-data"][0]
        self.assertNotIn('  - "tmux"', plain)

    def test_registry_source_needs_registry_auth_for_the_agent_host_image(self):
        raw = load(FULL)
        raw["images"] = {
            "registry": "ghcr.io/example",
            "source": "registry",
            "refs": {"core-platform": "registry.example.com/core:1"},
        }
        _e, m = validate(raw)
        with self.assertRaises(RenderError) as ctx:
            build(m)
        self.assertEqual(ctx.exception.code, "registry_auth_required")
        self.assertIn("agent-host", ctx.exception.message)


class ContainedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = build(manifest_from(CONTAINED))
        cls.compose = cls.rendered.files["compose.yaml"][0]
        cls.services = compose_services(cls.compose)
        cls.files = write_files(cls.rendered.files["user-data"][0])

    def test_agent_host_is_on_the_agents_network_only(self):
        block = self.services["agent-host"]
        self.assertIn("    networks:\n      agents: {}\n", block)
        self.assertNotIn("default", block)
        self.assertIn("\nnetworks:\n  agents: {}\n", self.compose)

    def test_core_platform_is_the_only_service_on_both_networks(self):
        self.assertIn(
            "    networks:\n      default: {}\n      agents: {}\n", self.services["core-platform"]
        )
        on_agents = sorted(s for s, b in self.services.items() if "      agents: {}" in b)
        self.assertEqual(on_agents, ["agent-host", "core-platform"])
        # Postgres stays on the default network only.
        self.assertNotIn("networks:", self.services["core-postgres"])

    def test_agent_host_reads_only_its_own_env_file(self):
        block = self.services["agent-host"]
        self.assertIn('    env_file:\n      - "agent-host.env"\n', block)
        self.assertNotIn("secrets.env", block)
        own = self.rendered.files["agent-host.env"]
        self.assertEqual(own[1], 0o600)
        token = self.rendered.generated["AGENT_HOST_TOKEN"]
        self.assertIn(f"AGENT_HOST_TOKEN={token}\n", own[0])
        others = [v for k, v in self.rendered.generated.items() if k != "AGENT_HOST_TOKEN"]
        self.assertTrue(others)
        self.assertFalse([v for v in others if v in own[0]])
        # core-platform still reads the token from secrets.env.
        self.assertIn(f"AGENT_HOST_TOKEN={token}\n", self.rendered.files["secrets.env"][0])

    def test_agents_reach_core_on_the_agents_network(self):
        self.assertIn(
            'AGENT_HOST_CORE_URL: "http://core-platform:4000"', self.services["core-platform"]
        )
        block = self.services["agent-host"]
        self.assertIn('BURROW_CORE_URL: "http://core-platform:4000"', block)
        self.assertIn('SUITE_CORE_URL: "http://core-platform:4000"', block)
        self.assertLess(block.index("BURROW_CORE_URL"), block.index("SUITE_CORE_URL"))
        self.assertIn('AGENT_HOST_PROFILE: "contained"', self.services["agent-host"])

    def test_agent_host_runs_systemd_with_persistent_homes(self):
        block = self.services["agent-host"]
        self.assertIn('image: "ghcr.io/example/burrow-agent-host:latest"', block)
        self.assertIn('stop_signal: "SIGRTMIN+3"', block)
        self.assertIn('- "agent-homes:/home"', block)
        self.assertIn('- "/run"', block)

    def test_no_sudoers_and_no_agent_host_unit_on_the_host(self):
        self.assertTrue(self.files)  # positive control: the reader found write_files
        for path in self.files:
            self.assertNotIn("sudoers", path)
            self.assertNotIn("burrow-agent", path)
        user_data, cut = cut_migrate_script(self.rendered.files["user-data"][0])
        self.assertEqual(cut, 1)  # bin/burrow-migrate (migrate_embed.py)
        self.assertNotIn("sudoers", user_data)
        self.assertNotIn("NOPASSWD", user_data)


class PackagingTest(unittest.TestCase):
    """The installer's copies are the files the agent-host image ships."""

    def test_embedded_texts_equal_the_agent_host_files(self):
        for name, path in (
            ("VERSIONS_ENV", "versions.env"),
            ("SUDOERS", "packaging/sudoers-burrow-agents"),
            ("HOST_UNIT", "packaging/burrow-agent-host.service"),
            ("AGENT_TEMPLATE_UNIT", "packaging/burrow-agent@.service"),
        ):
            with self.subTest(name=name):
                self.assertEqual(getattr(agents, name), read(os.path.join(AGENT_HOST_DIR, path)))

    def test_the_image_installs_the_same_files_and_checks_the_sudoers(self):
        dockerfile = read(os.path.join(AGENT_HOST_DIR, "Dockerfile"))
        self.assertIn(
            "install -m 0440 packaging/sudoers-burrow-agents /etc/sudoers.d/burrow-agents",
            dockerfile,
        )
        self.assertIn("visudo -cf /etc/sudoers.d/burrow-agents", dockerfile)
        # The setup script copies the daemon from where the image puts it.
        self.assertIn(f"WORKDIR {agents.INSTALL_ROOT}/agent-host", dockerfile)
        self.assertIn("RUN sh ./packaging/install-tools.sh ./versions.env", dockerfile)
        self.assertIn('CMD ["/sbin/init"]', dockerfile)

    def test_ci_pushes_the_image_only_when_services_agent_host_changes(self):
        text = read(CI_WORKFLOW)
        job = text.split("\n  build-and-push-agent-host:\n", 1)[1]
        job = re.split(r"^  [a-z#]", job, maxsplit=1, flags=re.MULTILINE)[0]
        self.assertIn('git diff --quiet "$BEFORE" "$GITHUB_SHA" -- services/agent-host', job)
        push = job.split("- name: Build and push agent-host\n", 1)[1]
        self.assertIn("if: steps.changed.outputs.agent_host == 'true'", push)
        # The registry default (task 01a14dd8) and the pre-rename name, both on
        # GHCR. Docker Hub is no longer a publish target (task 01a14afe), so a
        # legacy image_namespace install's agent-host image stays frozen.
        for repo in (
            "ghcr.io/startup-suite/burrow-agent-host",
            "ghcr.io/startup-suite/suite-agent-host",
        ):
            self.assertIn(f"{repo}:latest", push)
            self.assertIn(f"{repo}:${{{{ github.sha }}}}", push)
        tags = push.split("tags: |\n", 1)[1]
        self.assertIn("ghcr.io/startup-suite/", tags)
        self.assertNotIn("docker.io", tags)
        self.assertIn("if: github.event_name == 'push' && github.ref == 'refs/heads/main'", job)


if __name__ == "__main__":
    unittest.main()
