"""The render embeds migrate/suite-to-burrow.sh as bin/burrow-migrate (task 01a14dd8 stage 4).

That script moves an EXISTING pre-rename install off the legacy names, so it
names them, and it names the agent host on every render, agents or not. Render
tests that assert a render carries no legacy name, or no agent literal, scan
the user-data with exactly that body cut out (every other line stays scanned).
test_migrate_scripts.py and the names guard own the script itself.
"""

import base64
import gzip
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from burrow_install import templates

# One compressed write_files entry (templates.COMPRESSED_FILES): the encoding
# line, then the content as one quoted base64 scalar.
_COMPRESSED = re.compile(
    r'^    encoding: "gz\+b64"\n    content: "([A-Za-z0-9+/=]+)"$', re.MULTILINE
)


def expand_compressed(text):
    """``text`` with every gz+b64 entry rewritten as the literal block it decodes to.

    So a scan over the user-data reads the compressed scripts as plain text
    and compression cannot hide a name from it.
    """

    def literal(match):
        decoded = gzip.decompress(base64.b64decode(match.group(1))).decode("utf-8")
        lines = ("      " + line if line else line for line in decoded[:-1].split("\n"))
        return "    content: |\n" + "\n".join(lines)

    return _COMPRESSED.sub(literal, text)


def cut_migrate_script(text):
    """``(text without the embedded script body, how many bodies were cut)``.

    Compressed entries are expanded first (``expand_compressed``).
    """
    text = expand_compressed(text)
    body = "".join(
        ("      " + line if line else line) + "\n"
        for line in templates.migrate_script().splitlines()
    )
    return text.replace(body, ""), text.count(body)
