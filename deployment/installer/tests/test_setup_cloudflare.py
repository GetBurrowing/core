"""Cloudflare steps against a stdlib http.server fake (task 01a0d6ab stage 4).

- Re-running ``tunnel`` makes ZERO POSTs (and no PUT or PATCH) the second
  time; the first run's POST count is the positive control.
- ``hostname_too_deep`` fires for a host two labels below the zone and not for
  one label below, in both directions, and its remediation names the flat name.
- A DNS record the CLI did not create is never overwritten.
"""

import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from setup_fakes import MAC, MAC_LITE, FakeCloudflare, FakeHost, FakeKeychain, run_cli

from burrow_install.secrets import parse_env_file
from burrow_install.setup import cli
from burrow_install.setup.cloudflare import depth_errors

TOKEN = "cf-FAKE-01a0d6ab-token-abcdef123456"


class CloudflareBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cf-01a0d6ab-")
        self.dir = os.path.join(self.tmp, "inst")
        self.cf = FakeCloudflare(TOKEN)
        self.env = cli.Env(
            host=FakeHost(self.tmp),
            keychain=FakeKeychain({"CLOUDFLARE_API_TOKEN": TOKEN}),
            environ={"CF_01A0D6AB": TOKEN},
            configure=lambda ctx: setattr(ctx, "cloudflare_api", self.cf.url),
        )

    def tearDown(self):
        self.cf.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def init(self, *flags):
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", self.dir, "--name", "suite-01a0d6ab",
            *flags,
        )  # fmt: skip
        self.assertEqual(code, 0, doc)

    def run_step(self, name, *extra):
        return run_cli(self.env, "run", name, "--dir", self.dir, *extra)


class TunnelIdempotenceTest(CloudflareBase):
    def test_second_run_makes_no_post(self):
        self.init("--domain", "suite-01a0d6ab.example.com", "--auth-host",
                  "auth-01a0d6ab.example.com")  # fmt: skip
        code, doc, _ = self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        self.assertEqual(code, 0, doc)
        code, doc, _ = self.run_step("tunnel")
        self.assertEqual(code, 0, doc)
        first_posts = self.cf.count("POST")
        # Positive control: the first run did create things (tunnel + 2 CNAMEs).
        self.assertEqual(first_posts, 3)
        self.assertEqual(doc["outputs"]["tunnel"], "created")
        self.assertEqual(
            sorted(r["name"] for r in self.cf.records),
            ["auth-01a0d6ab.example.com", "suite-01a0d6ab.example.com"],
        )
        self.assertTrue(all(r["proxied"] for r in self.cf.records))
        tunnel_id = doc["outputs"]["tunnel_id"]
        self.assertEqual({r["content"] for r in self.cf.records}, {f"{tunnel_id}.cfargotunnel.com"})
        ingress = self.cf.configs[tunnel_id]["ingress"]
        self.assertEqual(ingress[-1], {"service": "http_status:404"})
        self.assertEqual({r.get("service") for r in ingress[:-1]}, {"http://caddy:80"})
        secrets = parse_env_file(os.path.join(self.dir, "secrets.env"))
        self.assertEqual(secrets["TUNNEL_TOKEN"], self.cf.tunnel_token)

        mutating_before = sum(self.cf.count(m) for m in ("POST", "PUT", "PATCH", "DELETE"))
        code, doc, _ = self.run_step("tunnel")
        self.assertEqual(code, 0, doc)
        self.assertEqual(self.cf.count("POST"), first_posts, "second run POSTed")
        self.assertEqual(
            sum(self.cf.count(m) for m in ("POST", "PUT", "PATCH", "DELETE")), mutating_before
        )
        self.assertEqual(doc["outputs"]["tunnel"], "present")
        self.assertEqual(doc["outputs"]["ingress"], "unchanged")
        self.assertEqual(set(doc["outputs"]["dns"].values()), {"present"})
        self.assertEqual(doc["outputs"]["tunnel_token"], "unchanged")

    def test_foreign_record_is_never_overwritten(self):
        self.init("--domain", "suite-01a0d6ab.example.com", "--auth-host",
                  "auth-01a0d6ab.example.com")  # fmt: skip
        self.cf.records.append(
            {"id": "f" * 32, "type": "A", "name": "suite-01a0d6ab.example.com",
             "content": "192.0.2.7", "proxied": False}
        )  # fmt: skip
        self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        code, doc, _ = self.run_step("tunnel")
        self.assertEqual((code, doc["error_code"]), (1, "dns_record_conflict"), doc)
        self.assertIn({"id": "f" * 32, "type": "A", "name": "suite-01a0d6ab.example.com",
                       "content": "192.0.2.7", "proxied": False}, self.cf.records)  # fmt: skip

    def test_teardown_deletes_only_this_tunnels_records(self):
        self.init("--domain", "suite-01a0d6ab.example.com", "--auth-host",
                  "auth-01a0d6ab.example.com")  # fmt: skip
        self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        self.run_step("tunnel")
        other = {"id": "e" * 32, "type": "CNAME", "name": "other.example.com",
                 "content": "x.cfargotunnel.com", "proxied": True}  # fmt: skip
        self.cf.records.append(other)
        self.assertEqual(len(self.cf.tunnels), 1)
        code, doc, _ = run_cli(self.env, "teardown", "--confirm", "suite-01a0d6ab", "--dir",
                               self.dir)  # fmt: skip
        self.assertEqual(code, 0, doc)
        self.assertEqual(self.cf.tunnels, [])
        self.assertEqual(self.cf.records, [other])


class LivekitRecordLifecycleTest(CloudflareBase):
    """lab-host, 2026-10-05: the livekit CNAME outlived the meetings-off flip and teardown."""

    HOSTS = frozenset(
        {
            "suite-01a0d6ab.example.com",
            "auth-01a0d6ab.example.com",
            "livekit-01a0d6ab.example.com",
        }
    )

    def setUp(self):
        super().setUp()
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC, "--dir", self.dir, "--name", "suite-01a0d6ab",
            "--domain", "suite-01a0d6ab.example.com", "--auth-host", "auth-01a0d6ab.example.com",
            "--livekit-host", "livekit-01a0d6ab.example.com",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        code, doc, _ = self.run_step("tunnel")
        self.assertEqual(code, 0, doc)
        # Positive control: with meetings on, all three records exist.
        self.assertEqual({r["name"] for r in self.cf.records}, self.HOSTS)

    def flip_off(self):
        code, doc, _ = run_cli(self.env, "init", "--dir", self.dir, "--meetings", "off")
        self.assertEqual(code, 0, doc)

    def test_meetings_off_tunnel_run_deletes_the_livekit_record(self):
        self.flip_off()
        self.run_step("domain")
        code, doc, _ = self.run_step("tunnel")
        self.assertEqual(code, 0, doc)
        self.assertEqual(
            doc["outputs"]["dns"]["livekit-01a0d6ab.example.com"], "deleted (no longer routed)"
        )
        self.assertEqual(
            {r["name"] for r in self.cf.records}, self.HOSTS - {"livekit-01a0d6ab.example.com"}
        )

    def test_teardown_after_the_flip_deletes_every_record(self):
        self.flip_off()
        code, doc, _ = run_cli(self.env, "teardown", "--confirm", "suite-01a0d6ab", "--dir",
                               self.dir)  # fmt: skip
        self.assertEqual(code, 0, doc)
        self.assertEqual(self.cf.records, [])
        self.assertEqual(set(doc["outputs"]["cloudflare"]["dns_deleted"]), self.HOSTS)


class DepthRuleTest(CloudflareBase):
    def test_two_labels_below_the_zone_is_refused(self):
        # auth_host defaults to auth.<primary> = auth.suite.example.com (2 labels).
        self.init("--domain", "suite.example.com")
        code, doc, _ = self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        self.assertEqual((code, doc["error_code"]), (1, "hostname_too_deep"), doc)
        self.assertIn("auth.suite.example.com", doc["error"])
        self.assertIn("--auth-host auth-suite.example.com", doc["remediation"])
        self.assertNotIn("zone_id", doc.get("outputs", {}))

    def test_one_label_below_the_zone_passes(self):
        self.init("--domain", "suite.example.com", "--auth-host", "auth-suite.example.com")
        code, doc, _ = self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["outputs"]["zone"], "example.com")
        self.assertEqual(doc["outputs"]["account_id"], "a" * 32)

    def test_rule_directly_both_directions(self):
        hosts = [("--domain", "example.com"), ("--domain", "suite.example.com"),
                 ("--auth-host", "auth.suite.example.com"), ("--x", "a.b.c.example.com"),
                 ("--y", "elsewhere.test")]  # fmt: skip
        found = {(flag, host, flat, why) for flag, host, flat, why in depth_errors(
            "example.com", hosts)}  # fmt: skip
        self.assertEqual(
            found,
            {
                ("--auth-host", "auth.suite.example.com", "auth-suite.example.com", "deep"),
                ("--x", "a.b.c.example.com", "a-b-c.example.com", "deep"),
                ("--y", "elsewhere.test", None, "outside"),
            },
        )

    def test_wrong_token_is_named(self):
        self.init("--domain", "suite-01a0d6ab.example.com", "--auth-host",
                  "auth-01a0d6ab.example.com")  # fmt: skip
        self.env.environ["CF_01A0D6AB"] = "cf-FAKE-wrong-token-01a0d6ab"
        code, doc, text = self.run_step("domain", "--input", "CLOUDFLARE_API_TOKEN=env:CF_01A0D6AB")
        self.assertEqual((code, doc["error_code"]), (1, "cloudflare_auth_failed"), doc)
        self.assertIn("DNS:Edit", doc["remediation"])
        self.assertNotIn("cf-FAKE-wrong-token-01a0d6ab", text)


if __name__ == "__main__":
    unittest.main()
