"""Adversarial checks for generated-value-only identity scan redaction."""

from types import SimpleNamespace
import unittest

from identity_terms import identity_hits, planted_term
from render_identity_scan import identity_scan_text


class RenderIdentityScanTest(unittest.TestCase):
    def test_repeated_overlapping_and_empty_generated_values(self):
        term = planted_term()
        short = "safe_" + term.capitalize() + "_key"
        long = short + "_" + term.capitalize() + "_tail"
        rendered = SimpleNamespace(
            # Short is deliberately inserted first: replacement must sort by length.
            generated={"SHORT": short, "LONG": long, "EMPTY": ""},
            files={
                "secrets.env": (f"SHORT={short}\nLONG={long}\nEMPTY=\n", 0o600),
                "secrets/key": (long + "\n" + short, 0o600),
                "config.json": ('{"key":"' + long + '"}', 0o644),
            },
        )
        self.assertTrue(identity_hits(long))
        self.assertEqual(
            identity_scan_text(rendered),
            'SHORT=<secret:SHORT>\nLONG=<secret:LONG>\nEMPTY=\n\n'
            '<secret:LONG>\n<secret:SHORT>\n{"key":"<secret:LONG>"}',
        )
        self.assertEqual(identity_hits(identity_scan_text(rendered)), [])

    def test_only_generated_values_are_excluded(self):
        term = planted_term()
        secret = "safe_" + term.capitalize() + "_key"
        rendered = SimpleNamespace(
            generated={"GENERATED": secret},
            customer={"CUSTOMER": term},
            files={
                "secrets.env": ("GENERATED=" + secret, 0o600),
                "customer.env": ("CUSTOMER=" + term, 0o600),
                "endpoint.conf": ("https://" + term + ".example/v1", 0o644),
                "random.conf": ("random_" + term + "_looking", 0o644),
            },
        )
        final = identity_scan_text(rendered)
        self.assertIn("GENERATED=<secret:GENERATED>", final)
        for path in ("customer.env", "endpoint.conf", "random.conf"):
            self.assertIn(rendered.files[path][0], final)
            self.assertTrue(identity_hits(rendered.files[path][0]))
        self.assertTrue(identity_hits(final))

    def test_ordinary_text_without_collisions_is_preserved(self):
        rendered = SimpleNamespace(
            generated={"KEY": "safe_random_value", "EMPTY": ""},
            files={"config": ("service=example\nKEY=safe_random_value", 0o644)},
        )
        self.assertEqual(identity_scan_text(rendered), "service=example\nKEY=<secret:KEY>")
        self.assertEqual(identity_hits(identity_scan_text(rendered)), [])
