"""The installer's identity check is the Elixir guard's digest rule (core task 01a14b9e stage 5).

Run: python3 -m unittest discover -s deployment/installer/tests -v
"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from identity_terms import DIGESTS, SCANNER, identity_hits, load_digests, planted_term


class IdentityTermsTest(unittest.TestCase):
    def test_digests_are_the_elixir_scanners_whole_list(self):
        with open(SCANNER, encoding="utf-8") as handle:
            source = handle.read()
        block = re.search(r"@digests MapSet\.new\(\[(.*?)\]\)", source, re.DOTALL).group(1)
        # count digest entries, not lines: the block carries comment lines
        # (A3c 01a14dd9 added one above its tenant and client digests)
        entries = re.findall(r'"([0-9a-f]{64})"', block)
        self.assertEqual(len(entries), 29)
        self.assertEqual(len(DIGESTS), 29)
        self.assertEqual(load_digests(), DIGESTS)

    def test_a_planted_term_is_named_in_every_shape(self):
        term = planted_term()
        self.assertEqual(identity_hits(f"runs on {term} today"), [term])
        self.assertEqual(identity_hits(f"runs on {term.upper()} today"), [term.upper()])
        camel = term.capitalize() + "Admin"
        self.assertEqual(identity_hits(f"class {camel}"), [term.capitalize()])
        # a host: its token and its dot-suffix compounds that are terms
        self.assertEqual(identity_hits(f"https://chat.{term}.example/x"), [term])

    def test_whole_tokens_only(self):
        term = planted_term()
        self.assertEqual(identity_hits(f"{term}ish and x{term}"), [])
        self.assertEqual(identity_hits("honeymoon rockets beehive"), [])

    def test_lan_address_is_literal(self):
        # assembled so this file does not carry the address it tests
        address = "192." + "168.4.20"
        self.assertEqual(identity_hits(f"at {address} now"), [address])
        self.assertEqual(identity_hits("at 192.0.2.20 now"), [])

    def test_the_identity_modules_carry_no_term(self):
        here = os.path.dirname(os.path.abspath(__file__))
        for name in ("identity_terms.py", "test_identity_terms.py"):
            with (
                open(os.path.join(here, name), encoding="utf-8") as handle,
                self.subTest(file=name),
            ):
                self.assertEqual(identity_hits(handle.read()), [])


if __name__ == "__main__":
    unittest.main()
