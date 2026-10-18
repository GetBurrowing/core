"""SKILL.md holds no logic the CLI lacks (task 01a0d6ab stage 4).

- every `setup <command>` SKILL.md cites is a real CLI command;
- every `setup run <step>` it cites is in the step registry;
- every step in the registry is cited as `setup run <step>` (the skill cannot
  silently skip one);
- every input it tells the user about is one the CLI declares;
- it carries Agent Skills frontmatter (name, description) and no literal
  at-mention token.

Positive control: the same extractor, run on a planted text naming a step the
registry lacks, reports it.
"""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
sys.path.insert(0, INSTALLER)

from suite_install.manifest import load
from suite_install.setup import cli, inputs, steps
from suite_install.validate import validate

SKILL = os.path.join(INSTALLER, "skill", "SKILL.md")
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLES = os.path.join(REPO, "deployment", "examples")

COMMAND_RE = re.compile(r"\bsetup (init|status|run|secret|teardown|[a-z][a-z-]+)\b")
RUN_RE = re.compile(r"\bsetup run ([a-z][a-z-]*|<[a-z_]+>)")
INPUT_RE = re.compile(r"`([A-Z][A-Z0-9_]{3,})`")


def extract(text):
    commands = set(COMMAND_RE.findall(text))
    runs = {r for r in RUN_RE.findall(text) if not r.startswith("<")}
    return commands, runs


class SkillTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SKILL, encoding="utf-8") as handle:
            cls.text = handle.read()
        cls.commands, cls.runs = extract(cls.text)

    def test_positive_control_extractor_reports_an_unknown_step(self):
        commands, runs = extract("run `suite-install setup run frobnicate` then `setup zap`")
        self.assertEqual(runs - set(steps.BY_NAME), {"frobnicate"})
        self.assertEqual(commands - set(cli.COMMANDS), {"zap"})

    def test_every_cited_command_exists(self):
        self.assertTrue(self.commands)
        self.assertEqual(self.commands - set(cli.COMMANDS), set())

    def test_every_cited_step_exists(self):
        self.assertEqual(self.runs - set(steps.BY_NAME), set())

    def test_every_step_is_cited(self):
        self.assertEqual(set(steps.BY_NAME) - self.runs, set())

    def test_every_command_is_cited(self):
        self.assertEqual(set(cli.COMMANDS) - self.commands, set())

    def test_inputs_named_are_declared(self):
        declared = set()
        for name in ("mac.install.toml", "mac-lite.install.toml"):
            _errors, manifest = validate(load(os.path.join(EXAMPLES, name)))
            declared |= set(inputs.declared(manifest))
        named = set(INPUT_RE.findall(self.text)) & {
            n for n in INPUT_RE.findall(self.text) if n.isupper() and "_" in n
        }
        self.assertIn("CLOUDFLARE_API_TOKEN", named)
        self.assertEqual(named - declared, set())

    def test_frontmatter_and_no_at_mention(self):
        self.assertTrue(self.text.startswith("---\nname: "))
        head = self.text.split("---")[1]
        self.assertIn("\nname: ", "\n" + head)
        self.assertIn("\ndescription: ", head)
        self.assertNotIn("@[", self.text)

    def test_offer_comes_first(self):
        body = self.text.split("---", 2)[2]
        self.assertLess(body.index("Want me to set up Burrow"), body.index("## Rules"))


if __name__ == "__main__":
    unittest.main()
