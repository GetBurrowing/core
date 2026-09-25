"""Tests for the throwaway-VM proof scripts (ADR 0053, task 01a0d69d stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

These run no VM and need no podman: they check that every script parses
(``bash -n``) and that ``--dry-run`` prints command lines that keep the naming
and loopback-only rules. The real boot is recorded in the ADR's Proof section.
"""

import os
import re
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROOF = os.path.join(os.path.dirname(HERE), "proof")
SCRIPTS = ("lib.sh", "vm-up.sh", "vm-down.sh", "vm-exec.sh", "preload.sh")

NAME = "t3st-01a0d69d"
WORKDIR = f"/nonexistent/{NAME}-vm"
HTTPS, SSH = "18443", "18022"

BASH = shutil.which("bash")


def run(script, *args):
    return subprocess.run(
        [BASH, os.path.join(PROOF, script), *args],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def vm_up_dry(name=NAME, workdir=WORKDIR):
    return run(
        "vm-up.sh",
        "--name",
        name,
        "--workdir",
        workdir,
        "--render",
        "/nonexistent/render",
        "--https-port",
        HTTPS,
        "--ssh-port",
        SSH,
        "--dry-run",
    )


@unittest.skipIf(BASH is None, "bash not installed")
class SyntaxTest(unittest.TestCase):
    def test_script_set_is_exactly_the_shipped_files(self):
        shipped = sorted(f for f in os.listdir(PROOF) if f.endswith(".sh"))
        self.assertEqual(shipped, sorted(SCRIPTS))

    def test_every_script_parses(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                result = subprocess.run(
                    [BASH, "-n", os.path.join(PROOF, script)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_runnable_scripts_use_strict_mode(self):
        for script in SCRIPTS:
            if script == "lib.sh":
                continue
            with self.subTest(script=script), open(os.path.join(PROOF, script)) as fh:
                self.assertIn("\nset -euo pipefail\n", fh.read())


@unittest.skipIf(BASH is None, "bash not installed")
class VmUpDryRunTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Positive control: the dry run succeeds and prints commands at all.
        cls.result = vm_up_dry()
        cls.commands = [line for line in cls.result.stdout.splitlines() if line.startswith("+ ")]

    def test_dry_run_succeeds_and_prints_commands(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        self.assertEqual(len(self.commands), 4, self.result.stdout)

    def test_every_created_name_carries_the_id(self):
        run_line = next(c for c in self.commands if c.startswith("+ podman run -d "))
        self.assertIn(f"--name vm-{NAME} ", run_line)
        self.assertIn(f"localhost/vmhost-{NAME} ", run_line)
        build = next(c for c in self.commands if c.startswith("+ podman build "))
        self.assertIn(f"-t localhost/vmhost-{NAME} ", build)
        prep = next(c for c in self.commands if c.startswith("+ podman run --rm "))
        self.assertIn(f"--name vmprep-{NAME} ", prep)
        for created in re.findall(r"(disk-\S+\.qcow2|seed-\S+\.iso)", self.result.stdout):
            self.assertIn(NAME, created)

    def test_ports_publish_on_loopback_only(self):
        run_line = next(c for c in self.commands if c.startswith("+ podman run -d "))
        published = re.findall(r" -p (\S+)", run_line)
        self.assertEqual(published, [f"127.0.0.1:{HTTPS}:{HTTPS}", f"127.0.0.1:{SSH}:{SSH}"])
        for command in self.commands:
            self.assertNotIn("0.0.0.0", command)

    def test_kvm_and_cpu_cap(self):
        run_line = next(c for c in self.commands if c.startswith("+ podman run -d "))
        self.assertIn("--device /dev/kvm ", run_line)
        self.assertIn("--cpus 4 ", run_line)
        self.assertIn(" -accel kvm ", run_line)
        self.assertIn(" -smp 4 ", run_line)
        self.assertIn(f"hostfwd=tcp::{SSH}-:22,hostfwd=tcp::{HTTPS}-:443", run_line)

    def test_dry_run_creates_nothing(self):
        self.assertFalse(os.path.exists(WORKDIR))


@unittest.skipIf(BASH is None, "bash not installed")
class ArgumentGuardTest(unittest.TestCase):
    def test_positive_control_valid_arguments_pass(self):
        self.assertEqual(vm_up_dry().returncode, 0)

    def test_workdir_must_contain_the_name(self):
        result = vm_up_dry(workdir="/nonexistent/some-vm")
        self.assertEqual(result.returncode, 2)
        self.assertIn("must contain the --name id", result.stderr)

    def test_bad_name_is_refused(self):
        result = vm_up_dry(name="Bad Name", workdir="/nonexistent/Bad Name")
        self.assertEqual(result.returncode, 2)

    def test_vm_down_refuses_a_workdir_without_the_name(self):
        ok = run("vm-down.sh", "--name", NAME, "--workdir", WORKDIR, "--dry-run")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn(f"rm -rf -- {WORKDIR}", ok.stdout)
        bad = run("vm-down.sh", "--name", NAME, "--workdir", "/srv/dev", "--dry-run")
        self.assertEqual(bad.returncode, 2)
        self.assertNotIn("rm -rf", bad.stdout)


if __name__ == "__main__":
    unittest.main()
