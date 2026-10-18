"""BURROW_* environment names with a SUITE_* fallback (task 01a14b9e stage 3).

The product is being renamed, so every legacy SUITE_ environment name the
installer reads now has a BURROW_ twin with the same suffix:

- The BURROW_ name is read first. If it is set to a non-empty value it wins,
  and no line is printed, even when the SUITE_ name is also set.
- Otherwise the SUITE_ name is read. If that is set to a non-empty value it is
  used, and ``deprecated: <suite name> is set; rename it to <burrow name>`` is
  printed to stderr once per name per process.
- An empty string counts as unset, because systemd ``Environment=X=`` and
  compose ``X: ""`` produce "" and treating it as set would mask a real value.

Call sites name both full literals, e.g.
``envcompat.get("BURROW_INSTALL_DIR", "SUITE_INSTALL_DIR")``. Never build a
name from a suffix: the repository guard that checks every SUITE_ name is
paired with its BURROW_ twin is a text scan, and cannot see a built name.
"""

import os
import sys

_warned = set()


def _stderr(line):
    sys.stderr.write(line + "\n")


def get(burrow, suite, environ=None, default=None, warn=None):
    """Return BURROW ``burrow``, else SUITE ``suite``, else ``default``."""
    environ = os.environ if environ is None else environ
    warn = _stderr if warn is None else warn
    value = environ.get(burrow)
    if value:
        return value
    value = environ.get(suite)
    if value:
        if suite not in _warned:
            _warned.add(suite)
            warn(f"deprecated: {suite} is set; rename it to {burrow}")
        return value
    return default
