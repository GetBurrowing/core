import hashlib
from pathlib import Path

import pytest

from clip_runner import runner_lock
from install_helper import install


def target(tmp_path):
    helper = tmp_path / "clip_runner.py"
    helper.write_bytes(b"measured previous helper\n")
    helper.chmod(0o700)
    return helper, hashlib.sha256(helper.read_bytes()).hexdigest()


def test_install_preserves_state_and_backup(tmp_path):
    helper, previous = target(tmp_path)
    state = tmp_path / "state"
    state.mkdir()
    mapping = state / "state.json"
    mapping.write_bytes(b'{"clips":{"original":"unchanged"}}')
    before = mapping.read_bytes()
    digest = install(state, helper, previous)
    assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
    assert helper.read_bytes() == (Path(__file__).parents[1] / "clip_runner.py").read_bytes()
    assert mapping.read_bytes() == before
    assert helper.with_name("clip_runner.py.backup-" + previous).read_bytes() == b"measured previous helper\n"
    assert helper.stat().st_mode & 0o777 == 0o700


def test_busy_runner_is_never_overwritten(tmp_path):
    helper, previous = target(tmp_path)
    state = tmp_path / "state"
    with runner_lock(state) as acquired:
        assert acquired
        with pytest.raises(RuntimeError, match="runner busy"):
            install(state, helper, previous)
    assert helper.read_bytes() == b"measured previous helper\n"
    assert not list(tmp_path.glob("*.backup-*"))


def test_changed_installed_helper_is_never_overwritten(tmp_path):
    helper, previous = target(tmp_path)
    helper.write_bytes(b"different helper\n")
    with pytest.raises(RuntimeError, match="installed helper changed"):
        install(tmp_path / "state", helper, previous)
    assert helper.read_bytes() == b"different helper\n"


def test_symlink_is_never_overwritten(tmp_path):
    helper, previous = target(tmp_path)
    link = tmp_path / "linked.py"
    link.symlink_to(helper)
    with pytest.raises(RuntimeError, match="regular helper"):
        install(tmp_path / "state", link, previous)
    assert helper.read_bytes() == b"measured previous helper\n"
