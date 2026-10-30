"""Install only a measured, quiescent helper; never modify runner state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from clip_runner import runner_lock


def install(state_dir: Path, target: Path, expected_current: str) -> str:
    root = Path(__file__).resolve().parent
    source = (root / "clip_runner.py").read_bytes()
    expected_new = json.loads((root / "source-receipt.json").read_text())["helper_sha256"]
    if hashlib.sha256(source).hexdigest() != expected_new:
        raise RuntimeError("source digest mismatch")
    if target.is_symlink() or not target.is_file():
        raise RuntimeError("target must be an existing regular helper")
    with runner_lock(state_dir) as acquired:
        if not acquired:
            raise RuntimeError("runner busy; leave live helper unchanged")
        previous = target.read_bytes()
        digest = hashlib.sha256(previous).hexdigest()
        if digest != expected_current:
            raise RuntimeError("installed helper changed; measure again")
        backup = target.with_name(target.name + ".backup-" + digest)
        # Exclusive creation: an existing backup is accepted only if identical.
        try:
            with backup.open("xb") as stream:
                stream.write(previous)
            shutil.copymode(target, backup)
        except FileExistsError:
            if backup.read_bytes() != previous:
                raise RuntimeError("backup mismatch") from None
        fd, name = tempfile.mkstemp(prefix=".clip-runner-install-", dir=target.parent)
        temporary = Path(name)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(source)
                stream.flush()
                os.fsync(stream.fileno())
            shutil.copymode(target, temporary)
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    return expected_new


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--helper-path", required=True, type=Path)
    parser.add_argument("--expected-current-sha256", required=True)
    args = parser.parse_args()
    print(json.dumps({"helper_sha256": install(args.state_dir, args.helper_path,
                                               args.expected_current_sha256),
                      "host_qualified": False}))
