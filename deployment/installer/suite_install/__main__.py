"""``python3 -m suite_install <command> ...``: the old entry point of burrow_install."""

import sys

from burrow_install.__main__ import main

DEPRECATION = "suite_install is now burrow_install"

if __name__ == "__main__":
    print(DEPRECATION, file=sys.stderr)
    sys.exit(main(sys.argv[1:]))
