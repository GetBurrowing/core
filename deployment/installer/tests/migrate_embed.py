"""The render embeds migrate/suite-to-burrow.sh as bin/burrow-migrate (task 01a14dd8 stage 4).

That script moves an EXISTING pre-rename install off the legacy names, so it
names them, and it names the agent host on every render, agents or not. Render
tests that assert a render carries no legacy name, or no agent literal, scan
the user-data with exactly that body cut out (every other line stays scanned).
test_migrate_scripts.py and the names guard own the script itself.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from burrow_install import templates


def cut_migrate_script(text):
    """``(text without the embedded script body, how many bodies were cut)``."""
    body = "".join(
        ("      " + line if line else line) + "\n"
        for line in templates.migrate_script().splitlines()
    )
    return text.replace(body, ""), text.count(body)
