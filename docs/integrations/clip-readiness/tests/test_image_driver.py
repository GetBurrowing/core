import hashlib
import json

import pytest

from rebind_image_driver import rebind


def fixture(tmp_path, pin=None):
    helper = tmp_path / "helper.py"
    helper.write_text('VERSION = "0.7.0"\n')
    old = hashlib.sha256(helper.read_bytes()).hexdigest()
    driver = tmp_path / "driver.py"
    driver.write_text(f'HELPER_SHA256 = "{pin or old}"\n# preserve startup and polling\nvalue = 42\n')
    replacement = tmp_path / "new.py"
    replacement.write_text('VERSION = "0.9.2"\n')
    new = hashlib.sha256(replacement.read_bytes()).hexdigest()
    receipt = tmp_path / "receipt.json"
    receipt.write_text(json.dumps({"helper_sha256": new}))
    return driver, helper, replacement, receipt, hashlib.sha256(driver.read_bytes()).hexdigest(), old


def test_rebind_preserves_driver_except_verified_pin(tmp_path):
    args = fixture(tmp_path)
    before = args[0].read_text()
    new = rebind(*args)
    assert args[0].read_text() == before.replace(args[-1], new)
    assert args[1].read_bytes() == args[2].read_bytes()


@pytest.mark.parametrize("mutation,expected", [
    ("driver", "driver digest"), ("helper", "previous helper digest"),
    ("replacement", "replacement helper digest")])
def test_changed_image_inputs_fail_without_mutation(tmp_path, mutation, expected):
    args = fixture(tmp_path)
    index = {"driver": 0, "helper": 1, "replacement": 2}[mutation]
    args[index].write_text(args[index].read_text() + "# changed\n")
    before = [p.read_bytes() for p in args[:4]]
    with pytest.raises(RuntimeError, match=expected):
        rebind(*args)
    assert [p.read_bytes() for p in args[:4]] == before


def test_unknown_driver_pin_contract_is_refused(tmp_path):
    args = fixture(tmp_path, pin="different")
    with pytest.raises(RuntimeError, match="pin contract"):
        rebind(*args)


def test_image_source_helper_and_version_label_are_updated_together(tmp_path):
    args = list(fixture(tmp_path))
    args[0].write_text(args[0].read_text() + 'label = "helper sha256 ok (0.7.0)"\n')
    args[4] = hashlib.sha256(args[0].read_bytes()).hexdigest()
    twin = tmp_path / "source_helper.py"
    twin.write_bytes(args[1].read_bytes())
    rebind(*args, source_helper=twin)
    assert twin.read_bytes() == args[1].read_bytes() == args[2].read_bytes()
    assert 'label = "helper sha256 ok (0.9.2)"' in args[0].read_text()


def test_changed_source_copy_refuses_before_any_replacement(tmp_path):
    args = fixture(tmp_path)
    twin = tmp_path / "source_helper.py"
    twin.write_bytes(b"different source copy")
    before = [p.read_bytes() for p in args[:4]]
    with pytest.raises(RuntimeError, match="source helper digest"):
        rebind(*args, source_helper=twin)
    assert [p.read_bytes() for p in args[:4]] == before
