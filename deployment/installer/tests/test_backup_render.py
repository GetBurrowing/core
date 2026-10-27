"""Single-host backup job (core task 01a17b10 stage 5).

A hosted install defaults to a backup target and renders a systemd timer, the
dump and volume steps and retention; `target = none` renders nothing; backup
credentials are secret refs only.
"""

import copy
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from burrow_install.manifest import load  # noqa: E402
from burrow_install.render import build  # noqa: E402
from burrow_install.validate import validate  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
BACKUP_DIR = os.path.join(os.path.dirname(HERE), "backup")

# Distinctive values: they must reach customer-secrets.env and nowhere else.
ACCESS_VALUE = "AKIA-fixture-access-value-7d41"
SECRET_VALUE = "fixture-secret-value-93bb0c5e"
S3 = {
    "target": "s3-compatible",
    "bucket": "example-bucket",
    "endpoint": "https://s3.example.test",
    "region": "r1",
    "access_key_ref": "BACKUP_ACCESS_KEY",
    "secret_key_ref": "BACKUP_SECRET_KEY",
}


def raw_manifest(hosted=False, backup=None):
    raw = copy.deepcopy(load(EXAMPLE))
    raw["install"]["hosted"] = hosted
    if backup is None:
        raw.pop("backup", None)
    else:
        raw["backup"] = backup
    return raw


def valid(raw):
    errors, normalized = validate(raw)
    assert not errors, [e.line() for e in errors]
    return normalized


def render(raw, **kwargs):
    return build(valid(raw), **kwargs)


def user_data(rendered):
    return rendered.files["user-data"][0]


def all_text(rendered):
    return "\n".join(text for text, _mode in rendered.files.values())


class HostedDefault(unittest.TestCase):
    def test_hosted_without_a_backup_table_defaults_to_local_path(self):
        m = valid(raw_manifest(hosted=True))
        self.assertEqual(m["backup"]["target"], "local-path")
        self.assertTrue(m["backup"]["path"].startswith("/"))

    def test_hosted_default_renders_timer_dump_volumes_and_retention(self):
        rendered = render(raw_manifest(hosted=True))
        ud = user_data(rendered)
        self.assertIn("burrow-backup.timer", ud)
        self.assertIn("OnCalendar=", ud)
        self.assertIn("burrow-backup.service", ud)
        self.assertIn("enable", ud)
        conf = rendered.files["backup.conf"][0]
        self.assertIn("TARGET=local-path", conf)
        self.assertIn("KEEP=14", conf)
        self.assertIn("_core-data", conf)
        script = rendered.files["bin/burrow-backup"][0]
        self.assertIn("pg_dump", script)
        self.assertIn("tar", script)
        self.assertIn("oldest_over_keep", script)
        self.assertIn("rotated", script)
        self.assertIn("bin/burrow-restore-drill", rendered.files)
        # The same script is what cloud-init writes.
        self.assertIn("pg_dump", ud)

    def test_hosted_target_none_is_refused(self):
        errors, _ = validate(raw_manifest(hosted=True, backup={"target": "none"}))
        self.assertEqual([e.code for e in errors], ["backup_required_hosted"])

    def test_hosted_opt_out_allows_none_and_renders_nothing(self):
        raw = raw_manifest(hosted=True, backup={"target": "none", "hosted_opt_out": True})
        rendered = render(raw)
        self.assertNotIn("backup.conf", rendered.files)
        self.assertNotIn("burrow-backup", all_text(rendered))

    def test_opt_out_contradicting_a_target_is_refused(self):
        raw = raw_manifest(hosted=True, backup={"target": "local-path", "path": "/b", "hosted_opt_out": True})
        errors, _ = validate(raw)
        self.assertEqual([e.code for e in errors], ["invalid_value"])


class TargetNone(unittest.TestCase):
    def test_not_hosted_default_renders_nothing(self):
        rendered = render(raw_manifest(hosted=False))
        for rel in ("backup.conf", "bin/burrow-backup", "bin/burrow-restore-drill"):
            self.assertNotIn(rel, rendered.files)
        self.assertNotIn("burrow-backup", all_text(rendered))

    def test_explicit_none_renders_nothing(self):
        rendered = render(raw_manifest(backup={"target": "none"}))
        self.assertNotIn("burrow-backup", all_text(rendered))


class S3Credentials(unittest.TestCase):
    def rendered(self):
        with tempfile.TemporaryDirectory() as tmp:
            supplied = os.path.join(tmp, "customer.env")
            with open(supplied, "w", encoding="utf-8") as handle:
                handle.write(f"BACKUP_ACCESS_KEY={ACCESS_VALUE}\nBACKUP_SECRET_KEY={SECRET_VALUE}\n")
            return render(raw_manifest(hosted=True, backup=dict(S3)), customer_secrets=supplied)

    def test_refs_only_in_every_rendered_file_but_the_secret_env(self):
        rendered = self.rendered()
        self.assertIn("ACCESS_KEY_REF=BACKUP_ACCESS_KEY", rendered.files["backup.conf"][0])
        # Positive control: the values do reach the 0600 customer-secrets.env.
        self.assertIn(SECRET_VALUE, rendered.files["customer-secrets.env"][0])
        self.assertEqual(rendered.files["customer-secrets.env"][1], 0o600)
        for rel, (text, _mode) in rendered.files.items():
            if rel in ("customer-secrets.env", "user-data"):
                continue
            self.assertNotIn(ACCESS_VALUE, text, rel)
            self.assertNotIn(SECRET_VALUE, text, rel)
        # user-data carries customer-secrets.env verbatim (it is mode 0600 too);
        # nothing from the backup job itself may hold a value.
        for rel in ("backup.conf", "bin/burrow-backup", "bin/burrow-restore-drill"):
            self.assertNotIn(SECRET_VALUE, rendered.files[rel][0])
        redacted = rendered.redacted()
        for rel, text in redacted.items():
            self.assertNotIn(ACCESS_VALUE, text, rel)
            self.assertNotIn(SECRET_VALUE, text, rel)

    def test_service_reads_the_secret_env_and_script_never_echoes_it(self):
        rendered = self.rendered()
        ud = user_data(rendered)
        self.assertIn("EnvironmentFile=/opt/burrow/customer-secrets.env", ud)
        script = rendered.files["bin/burrow-backup"][0]
        self.assertNotIn("set -x", script.replace("set +x", ""))
        # Credentials travel as `-e NAME`, never `-e NAME=value`.
        self.assertNotIn("AWS_SECRET_ACCESS_KEY=$", script.split("aws_run()")[1].split("}")[0])

    def test_local_path_has_no_secret_environment_file(self):
        ud = user_data(render(raw_manifest(hosted=True)))
        self.assertNotIn("EnvironmentFile=/opt/burrow/customer-secrets.env", ud)


class Scripts(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ("burrow-backup.sh", "burrow-restore-drill.sh"):
            result = subprocess.run(["bash", "-n", os.path.join(BACKUP_DIR, name)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_drill_prints_restored_lines_only(self):
        text = open(os.path.join(BACKUP_DIR, "burrow-restore-drill.sh"), encoding="utf-8").read()
        self.assertIn('echo "restored $name $rows"', text)


if __name__ == "__main__":
    unittest.main()
