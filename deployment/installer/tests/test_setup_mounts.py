"""`setup run up` recreates a service whose bind-mounted config went stale.

lab-host proof, 2026-10-05: the meetings flip re-rendered the Caddyfile with the
livekit host block, but caddy kept serving its first Caddyfile (a single-file
bind mount pins the replaced inode) and `docker compose up -d` left the
unchanged service running, so https://livekit-<tag>.<zone>/ returned 404.
"""

import os
import shutil
import tempfile
import unittest

from burrow_install.setup import steps
from burrow_install.setup.host import Result

CADDYFILE = "http://burrow.example.test {\n\treverse_proxy core-platform:4000\n}\n"


class _Install:
    def __init__(self, path):
        self.path = path

    def file(self, *parts):
        return os.path.join(self.path, *parts)


class _Ctx:
    """Just enough of setup.steps.Ctx: files on disk and a scripted compose."""

    def __init__(self, path, container_files, running=("caddy",)):
        self.install = _Install(path)
        self.container_files = container_files  # {(service, path): text}
        self.running = set(running)
        self.calls = []

    def compose(self, *args, env=None, timeout=600):
        self.calls.append(args)
        if args[:2] == ("exec", "-T"):
            service, path = args[2], args[4]
            if service not in self.running:
                return Result(1, "", f"service {service!r} is not running")
            text = self.container_files.get((service, path))
            if text is None:
                return Result(1, "", f"cat: can't open '{path}': No such file or directory")
            return Result(0, text, "")
        return Result(0, "", "")


class StaleMountTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="mounts-01a0d6ab-")
        with open(os.path.join(self.dir, "Caddyfile"), "w", encoding="utf-8") as handle:
            handle.write(CADDYFILE)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def recreations(self, ctx):
        return [c for c in ctx.calls if c[:4] == ("up", "-d", "--no-deps", "--force-recreate")]

    def test_matching_config_is_left_alone(self):
        # Positive control for the two cases below: same bytes, no recreate.
        ctx = _Ctx(self.dir, {("caddy", "/etc/caddy/Caddyfile"): CADDYFILE})
        self.assertEqual(steps._recreate_stale_mounts(ctx), [])
        self.assertEqual(self.recreations(ctx), [])

    def test_changed_config_recreates_the_service(self):
        old = CADDYFILE.replace("burrow.example.test", "old.example.test")
        ctx = _Ctx(self.dir, {("caddy", "/etc/caddy/Caddyfile"): old})
        self.assertEqual(steps._recreate_stale_mounts(ctx), ["caddy"])
        self.assertEqual(
            self.recreations(ctx), [("up", "-d", "--no-deps", "--force-recreate", "caddy")]
        )

    def test_stale_mount_that_reads_as_missing_recreates(self):
        # What lab-host showed: the replaced file is gone from the container's view.
        ctx = _Ctx(self.dir, {})
        self.assertEqual(steps._recreate_stale_mounts(ctx), ["caddy"])

    def test_a_service_that_is_not_running_is_skipped(self):
        ctx = _Ctx(self.dir, {}, running=())
        self.assertEqual(steps._recreate_stale_mounts(ctx), [])

    def test_unrendered_config_is_not_checked(self):
        # mac-lite renders no livekit.yaml, so livekit is never exec'd.
        ctx = _Ctx(self.dir, {("caddy", "/etc/caddy/Caddyfile"): CADDYFILE})
        steps._recreate_stale_mounts(ctx)
        self.assertNotIn("livekit", [c[2] for c in ctx.calls if c[:2] == ("exec", "-T")])


if __name__ == "__main__":
    unittest.main()
