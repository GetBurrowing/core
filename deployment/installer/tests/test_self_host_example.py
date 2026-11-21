"""The stranger-facing self-host guide and its example manifest (core task 01a1fe69).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

docs/self-hosting.md tells a stranger to copy
deployment/examples/self-host.install.toml, validate it, render it with no
registry credential and boot the result on a fresh server that pulls the
public images. These tests pin each of those promises, and pin every
``burrow_install <command>`` the guide's command blocks name to a command
``__main__.py`` actually dispatches, so the guide cannot drift from the CLI.

No test prints a secret: renders go to a temp dir that is removed, and only
compose.yaml (which holds no secret literal) is read.
"""

import contextlib
import io
import os
import re
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLE_REL = "deployment/examples/self-host.install.toml"
EXAMPLE = os.path.join(REPO, EXAMPLE_REL)
GUIDE = os.path.join(REPO, "docs", "self-hosting.md")
MAIN = os.path.join(INSTALLER, "burrow_install", "__main__.py")

sys.path.insert(0, INSTALLER)

from burrow_install import registry  # noqa: E402
from burrow_install.__main__ import main  # noqa: E402
from burrow_install.manifest import load  # noqa: E402
from burrow_install.validate import validate, warnings  # noqa: E402

PUBLIC_REGISTRY = "ghcr.io/getburrowing/"
# Containers whose image comes from [images] registry (Burrow's own builds).
BURROW_CONTAINERS = frozenset(registry.IMAGE_CONTAINERS.values())

FENCE = re.compile(r"^```[a-z]*\n(.*?)^```", re.M | re.S)
SUBCOMMAND = re.compile(r"\bburrow_install\s+([a-z][a-z0-9-]*)")


def run_cli(*argv):
    """``(exit code, stdout, stderr)`` of the CLI, in process."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = main(list(argv))
        except SystemExit as exc:  # argparse refusals
            code = exc.code
    return code, out.getvalue(), err.getvalue()


def dispatched_commands(source):
    """The subcommands ``__main__.py`` dispatches, read from its source."""
    early = set(re.findall(r'argv\[0\] == "([a-z][a-z0-9-]*)"', source))
    parsed = set(re.findall(r'add_parser\(\s*"([a-z][a-z0-9-]*)"', source))
    looped = set(re.findall(r'\(\s*"([a-z][a-z0-9-]*)",\s*"[^"]*"\s*\)', source))
    return early | parsed | looped


def guide_subcommands(text):
    """Every ``burrow_install <command>`` named inside a fenced command block."""
    names = []
    for block in FENCE.findall(text):
        names += SUBCOMMAND.findall(block.replace("\\\n", " "))
    return names


def compose_images(compose_text):
    """``{service: image}`` from a rendered compose.yaml."""
    images, service = {}, None
    for line in compose_text.splitlines():
        head = re.match(r"^  ([a-z][a-z0-9-]*):\s*$", line)
        if head:
            service = head.group(1)
            continue
        image = re.match(r'^\s+image:\s*"?([^"\s]+)"?\s*$', line)
        if image and service:
            images[service] = image.group(1)
    return images


class SelfHostRender(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="burrow-self-host-01a1fe69-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def render(self, manifest_path, name="render"):
        out = os.path.join(self.tmp, name)
        code, stdout, _err = run_cli("render", manifest_path, "--out", out)
        self.assertEqual(code, 0, stdout)
        return out


class ExampleManifestTest(SelfHostRender):
    def test_validates_with_no_error_and_no_deprecation_warning(self):
        errors, normalized = validate(load(EXAMPLE))
        self.assertEqual(errors, [])
        self.assertIsNotNone(normalized)
        self.assertEqual(list(warnings(normalized)), [])
        code, stdout, stderr = run_cli("validate", EXAMPLE)
        self.assertEqual((code, stdout.strip(), stderr), (0, "ok", ""))

    def test_declares_the_public_registry_and_the_documented_defaults(self):
        raw = load(EXAMPLE)
        self.assertEqual(
            raw["images"],
            {"registry": "ghcr.io/getburrowing", "public": True, "source": "registry"},
        )
        self.assertEqual(raw["domain"]["tls"], "acme")
        self.assertEqual(raw["domain"]["primary"], "burrow.example.com")
        self.assertEqual(raw["domain"]["acme_email"], "you@example.com")
        self.assertEqual(raw["auth"]["mode"], "bundled-pocket-id")
        self.assertEqual(raw["backup"]["target"], "none")
        self.assertEqual(raw["day2"]["upgrade_channel"], "stable")

    def test_renders_without_registry_auth_and_writes_no_credential(self):
        out = self.render(EXAMPLE)
        self.assertTrue(os.path.isfile(os.path.join(out, "user-data")))
        self.assertTrue(os.path.isfile(os.path.join(out, "compose.yaml")))
        self.assertFalse(os.path.exists(os.path.join(out, "registry-auth.json")))

    def assert_public_images(self, out):
        with open(os.path.join(out, "compose.yaml"), encoding="utf-8") as handle:
            images = compose_images(handle.read())
        # Positive control: core is a Burrow image, so the loop below checks something.
        self.assertIn("core-platform", images)
        for service, image in images.items():
            self.assertNotIn("/suite-", image, service)
            if service in BURROW_CONTAINERS:
                self.assertTrue(image.startswith(PUBLIC_REGISTRY), f"{service}: {image}")
            else:
                # Third-party images (caddy, postgres, pocket-id, llama.cpp) are
                # public upstream; none may come from another Burrow registry.
                self.assertNotIn("getburrowing", image.replace(PUBLIC_REGISTRY, ""), service)
        return images

    def test_every_burrow_image_is_on_the_public_registry(self):
        self.assert_public_images(self.render(EXAMPLE))

    def test_turning_memory_on_as_the_comment_says_still_renders_publicly(self):
        with open(EXAMPLE, encoding="utf-8") as handle:
            text = handle.read()
        for knob in ("files", "memory", "embeddings"):
            self.assertIn(f"\n{knob} = false\n", text)
            text = text.replace(f"\n{knob} = false\n", f"\n{knob} = true\n")
        path = os.path.join(self.tmp, "memory-on.install.toml")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        code, stdout, stderr = run_cli("validate", path)
        self.assertEqual((code, stdout.strip(), stderr), (0, "ok", ""))
        images = self.assert_public_images(self.render(path))
        self.assertTrue(images["memory-service"].startswith(PUBLIC_REGISTRY))
        self.assertTrue(images["files-service"].startswith(PUBLIC_REGISTRY))


class GuideTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(GUIDE, encoding="utf-8") as handle:
            cls.text = handle.read()
        with open(MAIN, encoding="utf-8") as handle:
            cls.dispatched = dispatched_commands(handle.read())

    def test_dispatch_reader_sees_the_cli(self):
        # Positive control for the drift check: the reader finds known commands.
        for name in ("validate", "services", "render", "redact", "bootstrap-admin", "setup"):
            self.assertIn(name, self.dispatched)

    def test_every_guide_command_is_dispatched(self):
        named = guide_subcommands(self.text)
        self.assertIn("validate", named)
        self.assertIn("render", named)
        self.assertIn("bootstrap-admin", named)
        for name in named:
            self.assertIn(name, self.dispatched, f"the guide names burrow_install {name}")

    def test_guide_points_at_the_example_and_it_exists(self):
        self.assertIn(EXAMPLE_REL, self.text)
        self.assertTrue(os.path.isfile(EXAMPLE))

    def test_guide_clones_the_public_repository(self):
        self.assertIn("git clone https://github.com/GetBurrowing/core.git", self.text)


if __name__ == "__main__":
    unittest.main()
