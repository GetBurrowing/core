"""Hosted cloud-init user-data stays under DigitalOcean's cap (core task 01a1b362 stage 3).

DigitalOcean refuses a droplet create whose user_data is over 64 KiB (65,536
bytes). The rendered user-data is sent as is, so the next host-file addition
should fail here in CI, not at droplet create.

Measured rendered ``user-data`` bytes at cc14c7fa (gz+b64 entries encoded, as
sent; the golden files show them decoded, so they are larger on disk):

    plan                                                     bytes
    do-droplet-support + hosted + s3-compatible backup      62,920  <- guarded
    do-droplet-support + hosted + local-path backup         62,196
    do-droplet + hosted + s3-compatible backup              51,345
    do-droplet-support golden as-is (not hosted, no backup) 50,872  <- guarded
    do-droplet / do-droplet-8gb golden                      39,297

The limit is 63.5 KiB, not 60: the worst real hosted plan is already 62,920
bytes, so 60 KiB would fail today. Getting it under 60 KiB means cutting about
1.5 KB first.
"""

import copy
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import validate

RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
SUPPORT_FIXTURE = os.path.join(RENDER_FIXTURES, "do-droplet-support.toml")
REGISTRY_AUTH = os.path.join(RENDER_FIXTURES, "do-droplet-registry-auth.json")

DO_CAP = 64 * 1024
# ~512 B of headroom under the DigitalOcean cap.
LIMIT = DO_CAP - 512

S3 = {
    "target": "s3-compatible",
    "bucket": "example-bucket",
    "endpoint": "https://s3.example.test",
    "region": "r1",
    "access_key_ref": "BACKUP_ACCESS_KEY",
    "secret_key_ref": "BACKUP_SECRET_KEY",
}
# Fixture values, not anyone's credentials.
CUSTOMER_SECRETS = (
    "BACKUP_ACCESS_KEY=AKIA-fixture-access-value-7d41\n"
    "BACKUP_SECRET_KEY=fixture-secret-value-93bb0c5e\n"
)


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError([e.line() for e in errors])
    return normalized


def user_data_bytes(raw, customer_secrets=None):
    rendered = build(valid(raw), registry_auth=REGISTRY_AUTH, customer_secrets=customer_secrets)
    return len(rendered.files["user-data"][0].encode())


class HostedUserDataSize(unittest.TestCase):
    def assert_fits(self, plan, size):
        # Positive control: an empty or truncated render must not pass as "small".
        self.assertGreater(size, 32 * 1024, f"{plan}: user-data implausibly small")
        self.assertLessEqual(
            size,
            LIMIT,
            f"{plan}: rendered user-data is {size:,} bytes, over the {LIMIT:,}-byte guard "
            f"(DigitalOcean caps user_data at 64 KiB = {DO_CAP:,} bytes; headroom is ~512 B). "
            "The next host-file addition must compress more (templates.user_data gz+b64) "
            "or move content out of user-data.",
        )

    def test_worst_hosted_plan_support_and_s3_backup(self):
        raw = copy.deepcopy(load(SUPPORT_FIXTURE))
        raw["install"]["hosted"] = True
        raw["backup"] = dict(S3)
        with tempfile.TemporaryDirectory() as tmp:
            supplied = os.path.join(tmp, "customer.env")
            with open(supplied, "w", encoding="utf-8") as handle:
                handle.write(CUSTOMER_SECRETS)
            size = user_data_bytes(raw, customer_secrets=supplied)
        self.assert_fits("do-droplet-support + hosted + s3-compatible backup", size)

    def test_support_golden_as_is(self):
        self.assert_fits("do-droplet-support golden", user_data_bytes(load(SUPPORT_FIXTURE)))


if __name__ == "__main__":
    unittest.main()
