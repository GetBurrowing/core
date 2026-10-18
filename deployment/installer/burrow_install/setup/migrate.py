"""``setup run migrate``: move a Mac install from the legacy root to ``~/burrow/<name>``.

Task 01a14dd8 stage 4. An install made before the Burrow rename lives under
the legacy root (``state.legacy_root()``) and runs LaunchAgents under the legacy labels. Discovery
already finds it there (state.resolve_dir), so migrating is optional. This step
makes the move in place:

1. ``docker compose down`` (no ``-v``) from the old directory. Named volumes are
   keyed by the compose project ``name:`` (install.name), and compose.yaml is
   moved byte for byte, so the stack comes back on the same volumes.
2. Move the directory to ``~/burrow/<name>``.
3. ``docker compose up -d`` from the new directory.
4. For each job with a plist under a legacy label, write the same job under the
   new label, with paths in the old directory rewritten to the new one, new
   backups going to ``~/BurrowBackups/<name>`` and the log named as the steps
   name it. Bootstrap it, then boot out and delete the legacy plist.
5. Leave the old backup directory where it is and record it in state.json
   (``ids.legacy_backup_dir``) as the read path for backups taken before the move.

Idempotent: with the install already under ``~/burrow`` it moves nothing and
only finishes a label swap a stopped run left behind. It refuses (exit 2) when
both directories exist, and moves nothing in that case.
"""

import os
import plistlib

from . import macos
from .state import Install, SetupError, default_root, legacy_root, now

STEP = "migrate"
JOBS = ("backup", "ip-watch")
# Where backups went before task 01a14dd8. Left in place, never written again.
LEGACY_BACKUP_ROOT = "SuiteBackups"
BACKUP_ROOT = "BurrowBackups"


def _legacy_plists(host, name):
    directory = os.path.join(host.home(), "Library", "LaunchAgents")
    found = []
    for job in JOBS:
        label = macos.legacy_agent_label(name, job)
        path = os.path.join(directory, f"{label}.plist")
        if os.path.exists(path):
            found.append((job, label, path))
    return found


def _rewrite(doc, job, name, old_dir, new_dir, home):
    """The legacy job's plist dict, moved onto the new label and paths."""
    old_backups = os.path.join(home, LEGACY_BACKUP_ROOT, name)
    new_backups = os.path.join(home, BACKUP_ROOT, name)

    def path(value):
        if value == old_dir or value.startswith(old_dir + os.sep):
            return new_dir + value[len(old_dir) :]
        if value == old_backups:
            os.makedirs(new_backups, mode=0o700, exist_ok=True)
            return new_backups
        return value

    doc = dict(doc)
    doc["Label"] = macos.agent_label(name, job)
    doc["ProgramArguments"] = [path(a) for a in doc.get("ProgramArguments", [])]
    for key in ("StandardOutPath", "StandardErrorPath"):
        if key in doc:
            doc[key] = os.path.join(os.path.dirname(doc[key]), f"burrow-install-{name}-{job}.log")
    return doc


def _swap_labels(host, name, old_dir, new_dir):
    swapped = []
    if host.platform != "darwin":
        return swapped
    for job, legacy_label, legacy_path in _legacy_plists(host, name):
        with open(legacy_path, "rb") as handle:
            doc = plistlib.load(handle)
        doc = _rewrite(doc, job, name, old_dir, new_dir, host.home())
        macos.install_agent(host, doc["Label"], plistlib.dumps(doc))
        macos.remove_agent(host, legacy_label)
        swapped.append({"from": legacy_label, "to": doc["Label"]})
    return swapped


def run(install, make_ctx):
    """Migrate ``install``. ``make_ctx(install)`` builds a steps.Ctx. Returns the outputs."""
    ctx = make_ctx(install)
    name = ctx.install_name
    host = ctx.host
    old = Install(os.path.join(legacy_root(), name))
    new = Install(os.path.join(default_root(), name))
    old_there = os.path.lexists(old.path)
    new_there = os.path.lexists(new.path)

    if old_there and new_there:
        raise SetupError(
            "migrate_both_exist",
            f"both {old.path} and {new.path} exist",
            "keep the one this install runs from and move the other aside, then re-run; "
            "nothing was changed",
            exit_code=2,
        )
    if os.path.realpath(install.path) not in (
        os.path.realpath(old.path),
        os.path.realpath(new.path),
    ):
        raise SetupError(
            "migrate_not_default_location",
            f"{install.path} is neither {old.path} nor {new.path}",
            "migrate moves only the default location; this install stays where it is",
            exit_code=2,
        )

    outputs = {"install_dir": new.path, "compose_project": name}
    if not old_there:
        # Already moved: finish a label swap a stopped run left behind, if any.
        outputs["moved"] = False
        outputs["launch_agents_swapped"] = _swap_labels(host, name, old.path, new.path)
    else:
        if os.path.exists(old.file("compose.yaml")):
            down = ctx.compose("down", timeout=600)
            if not down.ok:
                raise SetupError(
                    "migrate_compose_down_failed",
                    f"docker compose down exited {down.returncode}",
                    "nothing was moved; check `docker compose ls` and re-run",
                )
        os.makedirs(default_root(), mode=0o700, exist_ok=True)
        os.rename(old.path, new.path)
        outputs["moved"] = True
        outputs["moved_from"] = old.path
        ctx = make_ctx(new)
        if os.path.exists(new.file("compose.yaml")):
            up = ctx.compose("up", "-d", timeout=900)
            if not up.ok:
                raise SetupError(
                    "migrate_compose_up_failed",
                    f"docker compose up -d exited {up.returncode} after the move",
                    f"the install now lives in {new.path}; run `setup run up` there",
                    outputs=outputs,
                )
        outputs["launch_agents_swapped"] = _swap_labels(host, name, old.path, new.path)

    legacy_backups = os.path.join(host.home(), LEGACY_BACKUP_ROOT, name)
    if os.path.isdir(legacy_backups):
        outputs["legacy_backup_dir"] = legacy_backups
        ctx.state["ids"]["legacy_backup_dir"] = legacy_backups
    if outputs["moved"]:
        ctx.state["ids"]["migrated_from"] = old.path
    ctx.state["steps"][STEP] = {"state": "done", "at": now()}
    new.save_state(ctx.state)
    return outputs, ctx
