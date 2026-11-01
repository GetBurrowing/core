"""Meetings on the small single-host tier fit the 4 GB droplet (core task 01a19505 stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

The table (registry.MEETINGS_PROFILES) holds MEASURED peaks; the compose
mem_limits are derived from them (ceil(1.2 x peak)). The budget is read from
the registry's own tables, never from literals here, so a re-measured peak
moves the sums and can turn the test red.
"""

import math
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
FIXTURES = os.path.join(HERE, "render_fixtures")
DO_MEETINGS = os.path.join(FIXTURES, "do-droplet-meetings.toml")
DO_MEETINGS_CUSTOMER = os.path.join(FIXTURES, "do-droplet-meetings-customer.env")
DO_AUTH = os.path.join(FIXTURES, "do-droplet-registry-auth.json")
DO_8GB = os.path.join(FIXTURES, "do-droplet-8gb.toml")
MAC = os.path.join(REPO, "deployment", "examples", "mac.install.toml")
MAC_CUSTOMER = os.path.join(FIXTURES, "mac-customer.env")
MAC_AUTH = os.path.join(FIXTURES, "mac-registry-auth.json")
GOLDEN = os.path.join(HERE, "golden")

sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from test_droplet import block_list, compose_blocks

from burrow_install import registry
from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import validate


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError(f"manifest is invalid: {errors}")
    return normalized


def meetings_compose(tier):
    raw = load(DO_MEETINGS)
    raw["install"]["size_tier"] = tier
    rendered = build(valid(raw), registry_auth=DO_AUTH, customer_secrets=DO_MEETINGS_CUSTOMER)
    return compose_blocks(rendered.files["compose.yaml"][0])


def scalar(block, key):
    for line in block.splitlines():
        if line.startswith(f"    {key}: "):
            return line.split(": ", 1)[1].strip('"')
    return None


def budget(tier):
    """(limit sum, peak sum, host MemTotal) for `tier`, from the registry's tables."""
    emb = registry.EMBEDDINGS_PROFILES.get(
        tier, registry.EMBEDDINGS_PROFILES[registry.EMBEDDINGS_FALLBACK_TIER]
    )
    meet = registry.MEETINGS_PROFILES.get(
        tier, registry.MEETINGS_PROFILES[registry.MEETINGS_FALLBACK_TIER]
    )
    limits = registry.meetings_mem_limits(meet)
    limit_sum = (
        emb["siblings_peak_mb"]
        + emb["mem_limit"]
        + limits["livekit"]
        + limits[registry.TRANSCRIBER]
    )
    peak_sum = (
        emb["siblings_peak_mb"]
        + emb["embeddings_peak_mb"]
        + meet["livekit_peak_mb"]
        + meet["transcriber_peak_mb"]
    )
    return limit_sum, peak_sum, emb["host_ram_mb"]


class MeetingsProfileTest(unittest.TestCase):
    def test_small_tier_renders_mem_limit_for_livekit_and_transcriber(self):
        row = registry.MEETINGS_PROFILES["small"]
        limits = registry.meetings_mem_limits(row)
        blocks = meetings_compose("small")
        self.assertEqual(scalar(blocks["livekit"], "mem_limit"), f"{limits['livekit']}m")
        self.assertEqual(
            scalar(blocks["meeting-transcriber"], "mem_limit"),
            f"{limits[registry.TRANSCRIBER]}m",
        )
        self.assertIn(
            f'NUM_IDLE_PROCESSES: "{row["transcriber_idle_processes"]}"',
            blocks["meeting-transcriber"],
        )
        self.assertEqual(scalar(blocks["embeddings"], "mem_limit"), "1251m")
        self.assertIn("3072", block_list(blocks["embeddings"], "command"))

    def test_limits_are_1_2_x_the_measured_peaks(self):
        for tier, row in registry.MEETINGS_PROFILES.items():
            with self.subTest(tier=tier):
                limits = registry.meetings_mem_limits(row)
                self.assertEqual(limits["livekit"], math.ceil(1.2 * row["livekit_peak_mb"]))
                self.assertEqual(
                    limits[registry.TRANSCRIBER], math.ceil(1.2 * row["transcriber_peak_mb"])
                )
                idle = row["transcriber_idle_processes"]
                self.assertIn(idle, registry.TRANSCRIBER_MEASURED_PEAKS)  # a measured setting
                self.assertEqual(
                    row["transcriber_peak_mb"], registry.TRANSCRIBER_MEASURED_PEAKS[idle][1]
                )

    def test_small_tier_meetings_budget_fits_host_ram(self):
        limit_sum, peak_sum, host = budget("small")
        limits_line = registry.MEETINGS_LIMITS_LINE * host
        peaks_line = registry.MEETINGS_PEAKS_LINE * host
        # Both recorded, both checked: the LIMITS at Dalton's 90% line (3524 of
        # 3915, until the review droplet measures the hosted siblings), the
        # measured PEAKS under the 85% line (3327).
        self.assertLessEqual(
            limit_sum, limits_line, f"limit sum {limit_sum} MiB > {limits_line:.0f} MiB"
        )
        self.assertLess(peak_sum, peaks_line, f"peak sum {peak_sum} MiB >= {peaks_line:.0f} MiB")
        self.assertLessEqual(peak_sum, limit_sum)
        self.assertEqual(host, 3915)
        self.assertEqual(
            (registry.MEETINGS_LIMITS_LINE, registry.MEETINGS_PEAKS_LINE), (0.90, 0.85)
        )

    def test_medium_tier_unchanged(self):
        # The do-droplet-8gb golden (test_render.GoldenTest) pins the whole
        # render; here, its embeddings row is today's, not the small tier's.
        medium = registry.EMBEDDINGS_PROFILES["medium"]
        self.assertEqual((medium["ctx"], medium["mem_limit"]), (8192, 1974))
        raw = load(DO_8GB)
        self.assertEqual(raw["install"]["size_tier"], "medium")
        self.assertFalse(raw["services"].get("meetings", False))
        rendered = build(valid(raw), registry_auth=DO_AUTH).redacted()
        golden_dir = os.path.join(GOLDEN, "do-droplet-8gb")
        for rel, text in rendered.items():
            with (
                self.subTest(file=rel),
                open(os.path.join(golden_dir, rel), encoding="utf-8") as handle,
            ):
                self.assertEqual(text, handle.read())

    def test_mac_renders_no_meetings_mem_limit_or_idle_setting(self):
        raw = load(MAC)
        rendered = build(valid(raw), customer_secrets=MAC_CUSTOMER, registry_auth=MAC_AUTH)
        blocks = compose_blocks(rendered.files["compose.yaml"][0])
        self.assertIn("livekit", blocks)  # positive control: meetings are on
        for name in ("livekit", "meeting-transcriber"):
            self.assertIsNone(scalar(blocks[name], "mem_limit"))
        self.assertNotIn("NUM_IDLE_PROCESSES", blocks["meeting-transcriber"])


if __name__ == "__main__":
    unittest.main()
