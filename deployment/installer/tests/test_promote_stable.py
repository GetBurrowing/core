"""deployment/release/promote_stable.py and the release-channel tags in CI
(task 01a1b7b6 stage 2).

The promoter runs in a subprocess with PROMOTE_GIT, PROMOTE_CURL and
PROMOTE_IMAGETOOLS pointed at one fake (written to a tmp dir) that keeps the
"remote" refs, the local tags, the image registry and an argv log in a JSON
state file. No real git, curl or docker runs.
"""

import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SCRIPT = os.path.join(REPO, "deployment", "release", "promote_stable.py")
CI_WORKFLOW = os.path.join(REPO, ".github", "workflows", "ci.yml")
PROMOTE_WORKFLOW = os.path.join(REPO, ".github", "workflows", "promote-stable.yml")
IMG = "ghcr.io/getburrowing/core"

S = "a" * 40
T = "b" * 40
OLD = "c" * 40
NOW = dt.datetime(2026, 11, 7, 21, 30, tzinfo=dt.UTC)
HOUR = "20261107T21Z"

FAKE = textwrap.dedent(
    r"""
    import json, os, sys
    state_path = os.environ["FAKE_STATE"]
    with open(state_path) as f:
        st = json.load(f)
    tool, args = sys.argv[1], sys.argv[2:]
    st["log"].append([tool, *args])
    rc, out = 0, ""

    def save():
        with open(state_path, "w") as f:
            json.dump(st, f)

    if tool == "git":
        if args[:2] == ["ls-remote", "--refs"]:
            out = "".join(f"{sha}\t{ref}\n" for ref, sha in sorted(st["remote"].items()))
        elif args[:2] == ["cat-file", "-e"]:
            rc = 0 if args[2].split("^")[0] in st["commits"] else 1
        elif args[0] == "push":
            if st.get("push_fail"):
                rc = 1
            else:
                for spec in [a for a in args[1:] if a not in ("--atomic", "origin")]:
                    if spec.startswith(":"):
                        st["remote"].pop(spec[1:], None)
                    elif ":" in spec:
                        src, dst = spec.split(":", 1)
                        st["remote"][dst] = src
                    else:
                        name = spec[len("refs/tags/"):]
                        st["remote"][spec] = st["tags"][name]["sha"]
        elif args[:2] == ["tag", "-a"]:
            st["tags"][args[2]] = {"msg": args[4], "sha": args[5]}
        elif args[0] == "show":
            if args[1] in st["files"]:
                out = st["files"][args[1]]
            else:
                rc = 128
        else:
            rc = 2
    elif tool == "curl":
        resp = st["health"].get(args[-1])
        if resp is None or resp.get("rc", 0) != 0:
            rc = 22
        else:
            out = resp["body"] if isinstance(resp["body"], str) else json.dumps(resp["body"])
    elif tool == "imagetools":
        if args[0] == "inspect":
            ref = args[1]
            if ref not in st["images"]:
                rc = 1
            elif "--format" in args:
                rev = st["images"][ref]
                out = json.dumps({
                    "linux/amd64": {"config": {"Labels": {
                        "org.opencontainers.image.revision": rev}}},
                })
        elif args[:2] == ["create", "-t"]:
            dst, src = args[2], args[3]
            if src in st["images"]:
                st["images"][dst] = st["images"][src]
            else:
                rc = 1
        else:
            rc = 2
    save()
    sys.stdout.write(out)
    sys.exit(rc)
    """
)


def soak_refs(sha, hours_back, now=NOW):
    """refs/soak/<sha>/<hour> for each of `hours_back` hours before now."""
    return {
        f"refs/soak/{sha}/{(now - dt.timedelta(hours=h)).strftime('%Y%m%dT%HZ')}": sha
        for h in hours_back
    }


class PromoteHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = os.path.join(self.tmp.name, "fake.py")
        with open(self.fake, "w") as f:
            f.write(FAKE)
        self.state_path = os.path.join(self.tmp.name, "state.json")
        self.state = {
            "remote": {},
            "commits": [S, T, OLD],
            "tags": {},
            "files": {},
            "health": {
                "prod-health": {"body": {"status": "ok", "commit": S}},
                "canary-health": {"body": {"status": "ok", "commit": S}},
            },
            "images": {
                f"{IMG}:core-{S}": S,
                f"{IMG}:play-{S}": S,
                f"{IMG}:core-{T}": T,
                f"{IMG}:core-{OLD}": OLD,
                f"{IMG}:core-stable": OLD,
            },
            "log": [],
        }
        self.env = {
            "PATH": os.environ.get("PATH", ""),
            "FAKE_STATE": self.state_path,
            "PROMOTE_GIT": f"{shlex.quote(sys.executable)} {shlex.quote(self.fake)} git",
            "PROMOTE_CURL": f"{shlex.quote(sys.executable)} {shlex.quote(self.fake)} curl",
            "PROMOTE_IMAGETOOLS": (
                f"{shlex.quote(sys.executable)} {shlex.quote(self.fake)} imagetools"
            ),
            "PROMOTE_NOW": NOW.isoformat(),
            "STABLE_PROD_HEALTH_URL": "prod-health",
            "STABLE_CANARY_HEALTH_URL": "canary-health",
            "STABLE_SOAK_HOURS": "24",
        }

    def run_promote(self, **env):
        with open(self.state_path, "w") as f:
            json.dump(self.state, f)
        full = dict(self.env)
        for key, value in env.items():
            if value is None:
                full.pop(key, None)
            else:
                full[key] = value
        proc = subprocess.run(
            [sys.executable, SCRIPT], env=full, capture_output=True, text=True, check=False
        )
        with open(self.state_path) as f:
            self.state = json.load(f)
        self.output = proc.stdout + proc.stderr
        return proc.returncode

    def calls(self, tool):
        return [entry[1:] for entry in self.state["log"] if entry[0] == tool]

    def creates(self):
        return [c for c in self.calls("imagetools") if c[:1] == ["create"]]

    def remote_refs(self, prefix):
        return sorted(r for r in self.state["remote"] if r.startswith(prefix))


class HoldAndConfigTest(PromoteHarness):
    def test_hold_exits_zero_and_touches_nothing(self):
        self.state["remote"].update(soak_refs(S, range(1, 30)))
        self.assertEqual(self.run_promote(STABLE_HOLD="true"), 0)
        self.assertEqual(self.state["log"], [])
        self.assertIn("hold", self.output.lower())

    def test_hold_beats_force(self):
        self.assertEqual(
            self.run_promote(STABLE_HOLD="true", PROMOTE_FORCE="true", PROMOTE_SHA=S), 0
        )
        self.assertEqual(self.state["log"], [])

    def test_unconfigured_is_red_and_promotes_nothing(self):
        self.state["remote"].update(soak_refs(S, range(1, 30)))
        for missing in ("STABLE_PROD_HEALTH_URL", "STABLE_CANARY_HEALTH_URL"):
            with self.subTest(missing=missing):
                self.assertEqual(self.run_promote(**{missing: None}), 1)
                self.assertIn("not configured", self.output)
                self.assertEqual(self.creates(), [])
                self.assertEqual(self.calls("curl"), [])

    def test_empty_url_is_unconfigured(self):
        self.assertEqual(self.run_promote(STABLE_CANARY_HEALTH_URL=""), 1)
        self.assertEqual(self.creates(), [])

    def test_both_urls_are_probed(self):
        self.run_promote()
        self.assertEqual([c[-1] for c in self.calls("curl")], ["prod-health", "canary-health"])


class ObservationTest(PromoteHarness):
    def test_both_ok_same_commit_writes_a_soak_ref(self):
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.state["remote"][f"refs/soak/{S}/{HOUR}"], S)
        self.assertEqual(self.remote_refs("refs/soak-fail/"), [])
        self.assertEqual(self.state["remote"]["refs/soak-seen/prod"], S)

    def test_mismatched_commits_write_no_soak_ref(self):
        self.state["health"]["canary-health"]["body"]["commit"] = T
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.remote_refs("refs/soak/"), [])
        self.assertEqual(self.remote_refs("refs/soak-fail/"), [])
        self.assertIn("mismatched", self.output)

    def test_a_failed_probe_blames_the_commit_last_reported(self):
        self.state["remote"]["refs/soak-seen/canary"] = T
        self.state["health"]["canary-health"] = {"rc": 7}
        self.run_promote()
        self.assertEqual(self.remote_refs("refs/soak/"), [])
        self.assertEqual(self.remote_refs("refs/soak-fail/"), [f"refs/soak-fail/{T}/{HOUR}"])

    def test_a_non_ok_status_blames_its_commit(self):
        self.state["health"]["prod-health"]["body"]["status"] = "degraded"
        self.run_promote()
        self.assertEqual(self.remote_refs("refs/soak/"), [])
        self.assertEqual(self.remote_refs("refs/soak-fail/"), [f"refs/soak-fail/{S}/{HOUR}"])

    def test_the_canary_rollback_marks_the_rolled_from_commit(self):
        self.state["health"]["canary-health"]["body"]["update"] = {
            "last_rollback": {"at": "2026-11-07T20:00:00Z", "from": T, "to": S}
        }
        self.run_promote()
        self.assertIn(f"refs/soak-fail/{T}/{HOUR}", self.state["remote"])

    def test_an_unknown_commit_writes_no_ref(self):
        unknown = "d" * 40
        for url in ("prod-health", "canary-health"):
            self.state["health"][url]["body"]["commit"] = unknown
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.remote_refs("refs/soak"), [])

    def test_push_failure_is_red(self):
        self.state["push_fail"] = True
        self.assertEqual(self.run_promote(), 1)
        self.assertEqual(self.creates(), [])


class PromotionTest(PromoteHarness):
    def test_fewer_observations_than_soak_hours_do_not_promote(self):
        self.state["remote"].update(soak_refs(S, range(1, 23)))  # 22 + this hour = 23
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.creates(), [])

    def test_tag_age_is_not_observation_count(self):
        # Two observations 30 hours apart: old enough, but 2 observed hours.
        self.state["remote"].update(soak_refs(S, [30]))
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(len(self.remote_refs(f"refs/soak/{S}/")), 2)
        self.assertEqual(self.creates(), [])

    def test_soak_hours_reached_promotes_with_the_exact_imagetools_argv(self):
        self.state["remote"].update(soak_refs(S, range(1, 24)))  # 23 + this hour = 24
        self.state["files"] = {
            f"{S}:deployment/release/irreversible-migrations.txt": "# h\n20261108000000\n",
            f"{OLD}:deployment/release/irreversible-migrations.txt": "# h\n",
        }
        self.assertEqual(self.run_promote(), 0, self.output)
        self.assertEqual(
            self.creates(),
            [
                ["create", "-t", f"{IMG}:core-stable", f"{IMG}:core-{S}"],
                ["create", "-t", f"{IMG}:play-stable", f"{IMG}:play-{S}"],
            ],
        )
        tag = f"stable/20261107T2130Z-{S[:7]}"
        self.assertEqual(self.state["tags"][tag]["sha"], S)
        self.assertIn("20261108000000", self.state["tags"][tag]["msg"])
        self.assertEqual(self.state["remote"][f"refs/tags/{tag}"], S)

    def test_no_play_image_moves_core_only(self):
        del self.state["images"][f"{IMG}:play-{S}"]
        self.state["remote"].update(soak_refs(S, range(1, 24)))
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(
            self.creates(), [["create", "-t", f"{IMG}:core-stable", f"{IMG}:core-{S}"]]
        )

    def test_soak_fail_for_s_blocks_it(self):
        self.state["remote"].update(soak_refs(S, range(1, 30)))
        self.state["remote"][f"refs/soak-fail/{S}/20261107T05Z"] = S
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.creates(), [])

    def test_a_canary_rollback_from_s_blocks_it(self):
        self.state["remote"].update(soak_refs(S, range(1, 30)))
        # The canary rolled back from S and now runs OLD.
        self.state["health"]["canary-health"]["body"] = {
            "status": "ok",
            "commit": OLD,
            "update": {"last_rollback": {"at": "x", "from": S, "to": OLD}},
        }
        self.assertEqual(self.run_promote(), 0)
        self.assertIn(f"refs/soak-fail/{S}/{HOUR}", self.state["remote"])
        self.assertEqual(self.creates(), [])

    def test_soak_fail_on_a_different_commit_does_not_block_s(self):
        self.state["remote"].update(soak_refs(S, range(1, 24)))
        self.state["remote"][f"refs/soak-fail/{T}/20261107T05Z"] = T
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(
            self.creates()[0], ["create", "-t", f"{IMG}:core-stable", f"{IMG}:core-{S}"]
        )

    def test_current_stable_is_a_no_op(self):
        self.state["images"][f"{IMG}:core-stable"] = S
        self.state["remote"].update(soak_refs(S, range(1, 30)))
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.creates(), [])

    def test_the_newest_eligible_commit_wins(self):
        self.state["health"]["prod-health"]["body"]["commit"] = T
        self.state["health"]["canary-health"]["body"]["commit"] = T
        self.state["remote"].update(soak_refs(S, range(30, 60)))
        self.state["remote"].update(soak_refs(T, range(1, 24)))
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.creates()[0][-1], f"{IMG}:core-{T}")

    def test_a_commit_last_seen_before_the_previous_promotion_never_flips_back(self):
        # OLD is stable now; S soaked fully but entirely before OLD's promotion.
        self.state["health"]["prod-health"]["body"]["commit"] = OLD
        self.state["health"]["canary-health"]["body"]["commit"] = T
        self.state["remote"].update(soak_refs(S, range(50, 80)))
        self.state["remote"][f"refs/tags/stable/20261106T0000Z-{OLD[:7]}"] = OLD
        self.assertEqual(self.run_promote(), 0)
        self.assertEqual(self.creates(), [])

    def test_force_skips_the_soak_count(self):
        self.state["health"]["prod-health"] = {"rc": 7}  # still probed, still recorded
        self.assertEqual(self.run_promote(PROMOTE_FORCE="true", PROMOTE_SHA=T), 0, self.output)
        self.assertEqual(
            self.creates(), [["create", "-t", f"{IMG}:core-stable", f"{IMG}:core-{T}"]]
        )
        self.assertEqual(len(self.calls("curl")), 2)

    def test_force_needs_a_full_sha(self):
        self.assertEqual(self.run_promote(PROMOTE_FORCE="true", PROMOTE_SHA="abc123"), 1)
        self.assertEqual(self.creates(), [])

    def test_force_of_the_current_stable_is_a_no_op(self):
        self.assertEqual(self.run_promote(PROMOTE_FORCE="true", PROMOTE_SHA=OLD), 0)
        self.assertEqual(self.creates(), [])

    def test_force_false_with_a_sha_is_an_ordinary_run(self):
        self.assertEqual(self.run_promote(PROMOTE_FORCE="false", PROMOTE_SHA=T), 0)
        self.assertEqual(self.creates(), [])

    def test_failed_core_create_is_red_and_writes_no_tag(self):
        del self.state["images"][f"{IMG}:core-{S}"]
        self.state["remote"].update(soak_refs(S, range(1, 24)))
        self.assertEqual(self.run_promote(), 1)
        self.assertEqual(self.state["tags"], {})


class PruneTest(PromoteHarness):
    def test_refs_older_than_14_days_are_pruned(self):
        old_hour = (NOW - dt.timedelta(days=15)).strftime("%Y%m%dT%HZ")
        fresh_hour = (NOW - dt.timedelta(days=13)).strftime("%Y%m%dT%HZ")
        self.state["remote"].update(
            {
                f"refs/soak/{T}/{old_hour}": T,
                f"refs/soak/{T}/{fresh_hour}": T,
                f"refs/soak-fail/{T}/{old_hour}": T,
            }
        )
        self.assertEqual(self.run_promote(), 0)
        self.assertNotIn(f"refs/soak/{T}/{old_hour}", self.state["remote"])
        self.assertNotIn(f"refs/soak-fail/{T}/{old_hour}", self.state["remote"])
        self.assertIn(f"refs/soak/{T}/{fresh_hour}", self.state["remote"])
        pushes = [c for c in self.calls("git") if c[:1] == ["push"]]
        self.assertIn(f":refs/soak/{T}/{old_hour}", pushes[0])


class WorkflowTextTest(unittest.TestCase):
    """The channel tags and the branch refusal in ci.yml; promote-stable.yml's shape."""

    @classmethod
    def setUpClass(cls):
        with open(CI_WORKFLOW, encoding="utf-8") as f:
            cls.ci = f.read()
        with open(PROMOTE_WORKFLOW, encoding="utf-8") as f:
            cls.promote = f.read()

    def step(self, name):
        steps = re.split(r"^(?=      - name: )", self.ci, flags=re.MULTILINE)
        found = [s for s in steps if s.startswith(f"      - name: {name}\n")]
        self.assertEqual(len(found), 1, name)
        return found[0]

    def derive_steps(self):
        steps = re.split(r"^(?=      - name: )", self.ci, flags=re.MULTILINE)
        return [s for s in steps if s.startswith("      - name: Derive image tags\n")]

    def test_main_publishes_core_edge_and_play_edge(self):
        core = self.step("Create manifest list (main)")
        self.assertRegex(core, r"(?m)^\s+-t ghcr\.io/getburrowing/core:core-edge \\$")
        play = self.step("Tag verified Play (main)")
        self.assertRegex(play, r"(?m)^\s+-t ghcr\.io/getburrowing/core:play-edge \\$")

    def test_feature_steps_publish_no_channel_tag(self):
        for name in (
            "Create manifest list (feature branch)",
            "Tag verified Play (feature branch)",
        ):
            with self.subTest(step=name):
                self.assertNotRegex(self.step(name), r"core:(core-|play-)?(edge|stable)\b")

    def test_no_ci_step_publishes_stable(self):
        self.assertNotRegex(self.ci, r"core:(core-|play-)?stable\b")

    def test_both_branch_tag_derivations_refuse_channel_names(self):
        steps = self.derive_steps()
        self.assertEqual(len(steps), 2, "expected two `Derive image tags` steps")
        for step in steps:
            with self.subTest(step=step[:200]):
                self.assertIn(
                    '[[ "$BRANCH_TAG" =~ ^(core-|play-)?(stable|edge|candidate)$ ]]', step
                )
                self.assertIn('[[ "$BRANCH_TAG" =~ ^(core-|play-)?(soak-|stable-) ]]', step)
                refuse = step.index('BRANCH_TAG" =~ ^(core-|play-)?(stable')
                self.assertLess(refuse, step.index('echo "branch_tag='))
                self.assertIn("exit 1", step[refuse : step.index('echo "branch_tag=')])

    def test_the_refusal_behaves(self):
        # Run each derivation's shell (with GITHUB_OUTPUT a tmp file) on a
        # set of refs: channel names fail, ordinary branches pass.
        for step in self.derive_steps():
            body = step.split("run: |\n", 1)[1]
            lines = []
            for line in body.splitlines():
                if line.strip() and not line.startswith(" " * 10):
                    break  # the run block ends at the first shallower line
                lines.append(line)
            script = textwrap.dedent("\n".join(lines))
            self.assertIn('echo "branch_tag=', script)
            for ref, ok in (
                ("refs/heads/feat/reskin", True),
                ("refs/heads/stack/x", True),
                ("refs/heads/main", True),
                ("refs/heads/edge", False),
                ("refs/heads/stable", False),
                ("refs/heads/core-stable", False),
                ("refs/heads/play-edge", False),
                ("refs/heads/candidate", False),
                ("refs/heads/soak-x", False),
                ("refs/heads/stable/x", False),
                ("refs/heads/feat/stable", True),
            ):
                with self.subTest(ref=ref), tempfile.NamedTemporaryFile() as out:
                    env = {
                        "PATH": os.environ.get("PATH", ""),
                        "GITHUB_REF": ref,
                        "GITHUB_SHA": "f" * 40,
                        "GITHUB_OUTPUT": out.name,
                    }
                    proc = subprocess.run(
                        ["bash", "-e", "-c", script], env=env, capture_output=True, check=False
                    )
                    self.assertEqual(proc.returncode == 0, ok, proc.stdout + proc.stderr)

    def test_promote_workflow_triggers_and_permissions(self):
        text = self.promote
        self.assertRegex(text, r"(?m)^  schedule:\n    - cron: \"\d+ \* \* \* \*\"$")
        self.assertRegex(text, r"(?m)^  workflow_dispatch:$")
        self.assertRegex(text, r"(?m)^      sha:$")
        self.assertRegex(text, r"(?m)^      force:$")
        self.assertRegex(text, r"(?m)^  contents: write$")
        self.assertRegex(text, r"(?m)^  packages: write$")
        self.assertRegex(text, r"(?m)^    runs-on: ubuntu-latest$")
        for var in (
            "STABLE_PROD_HEALTH_URL",
            "STABLE_CANARY_HEALTH_URL",
            "STABLE_SOAK_HOURS",
            "STABLE_HOLD",
        ):
            self.assertIn(f"{var}: ${{{{ vars.{var} }}}}", text)
        self.assertIn("python3 deployment/release/promote_stable.py", text)

    def test_no_url_in_the_promotion_files(self):
        with open(SCRIPT, encoding="utf-8") as f:
            script = f.read()
        for name, text in (("promote_stable.py", script), ("promote-stable.yml", self.promote)):
            with self.subTest(file=name):
                self.assertNotRegex(text, r"https?://")


if __name__ == "__main__":
    unittest.main()
