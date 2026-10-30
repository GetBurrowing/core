"""Extract the versioned canonical skill's exact helper/tests into a new directory."""

import argparse
import hashlib
import re
from pathlib import Path

SKILL_SHA256 = "800c59e2a010a2683046e4dadb93792cc56ca7fdba4db98d75879d330e5b541d"
HELPER_SHA256 = "2aee11721000b2505a0e660b3d9355d88e31c93c9c2246a7042cd6fd985813a1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    skill = Path(__file__).with_name("canonical-runner-0.10.0.md").read_bytes()
    if hashlib.sha256(skill).hexdigest() != SKILL_SHA256:
        raise SystemExit("Canonical skill digest mismatch")
    if args.output.exists():
        raise SystemExit("Output exists; choose a new directory")
    blocks = re.findall(
        r"### `([^`]+)`\n\n````python\n(.*?)\n````", skill.decode(), re.DOTALL
    )
    for name, _ in blocks:
        if not re.fullmatch(r"clip_runner\.py|tests/[a-z0-9_]+\.py", name):
            raise SystemExit("Unexpected code block path")
    args.output.mkdir(mode=0o700, parents=True)
    for name, source in blocks:
        path = args.output / name
        path.parent.mkdir(exist_ok=True, parents=True)
        path.write_text(source + "\n")
    helper = args.output / "clip_runner.py"
    if hashlib.sha256(helper.read_bytes()).hexdigest() != HELPER_SHA256:
        raise SystemExit("Helper digest mismatch")
    helper.chmod(0o700)
    print(f"Materialized canonical helper and {len(blocks) - 1} test files")


if __name__ == "__main__":
    main()
