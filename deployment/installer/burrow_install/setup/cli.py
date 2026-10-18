"""``python3 -m burrow_install setup <command>``: the deterministic setup CLI.

It never prompts on the terminal and is the only thing that mutates install
state. Every command prints exactly ONE JSON document on stdout (contract
version 1, documented in deployment/installer/mac/README.md):

  setup init --from <manifest> [--dir D] [--name N] [--domain HOST]
             [--auth-host HOST] [--livekit-host HOST] [--meetings on|off]
             [--registry PATH | --image-namespace NS (legacy)]
  setup status --json [--dir D]
  setup run <step> [--dir D] [--input NAME=@/path | NAME=env:VAR |
                    NAME=keychain:ITEM | NAME=value (non-secret only)] ...
  setup run migrate [--dir D]   (move a pre-rename install to ~/burrow/<name>)
  setup secret <NAME> [--item ITEM] [--dir D]      (macOS Keychain dialog)
  setup teardown --confirm <install name> [--dir D]

Exit codes: 0 ok; 1 a step failed; 2 refused (usage, secret_in_argv, step
order); 3 blocked on a human (a missing input, awaiting_passkey).

Before anything is printed, every secret value the process knows of
(secrets.env, customer-secrets.env, secrets/*, and every input value it
resolved) is replaced with ``<secret:NAME>``. The steps themselves print no
secret either; the transcript-hygiene test checks both layers.
"""

import argparse
import copy
import json
import os
import sys

from ..manifest import ManifestLoadError, load
from ..secrets import redact
from ..validate import validate
from . import cloudflare, inputs, macos, migrate, steps
from .host import Host
from .state import (
    Install,
    SetupError,
    check_dir_allowed,
    default_root,
    legacy_root,
    now,
    resolve_dir,
)

CONTRACT_VERSION = 1


class Env:
    """Injectable collaborators; tests replace fields."""

    def __init__(self, host=None, keychain=None, environ=None, configure=None, scrub=True):
        self.host = host or Host(environ)
        self.keychain = keychain or macos.MacKeychain(self.host)
        self.environ = dict(os.environ if environ is None else environ)
        self.configure = configure  # callable(ctx) to override URLs in tests
        self.scrub = scrub


def _emit(doc, ctx, out):
    text = json.dumps(doc, indent=2, sort_keys=True)
    if ctx is not None and getattr(ctx, "_scrub", True):
        text = redact(text, ctx.secret_values())
    print(text, file=out)


def _error_doc(exc, step=None):
    doc = {"contract_version": CONTRACT_VERSION, "ok": False, "error_code": exc.code}
    if step:
        doc["step"] = step
    doc["error"] = exc.message
    if exc.remediation:
        doc["remediation"] = exc.remediation
    if exc.outputs:
        doc["outputs"] = exc.outputs
    return doc


def _ctx(install, env):
    state = install.load_state()
    ctx = steps.Ctx(install, state, env.host, env.keychain, env.environ)
    ctx._scrub = env.scrub
    if env.configure:
        env.configure(ctx)
    return ctx


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------


def step_status(ctx):
    m = ctx.manifest
    declared = inputs.declared(m)
    recorded = ctx.state["steps"]
    rows = []
    done = set()
    for step in steps.STEPS:
        applies, why = step.applies(m)
        row = {"name": step.name, "summary": step.summary, "advisory": step.advisory}
        if not applies:
            row.update(state="done", needs=[], skipped=True, note=f"not applicable: {why}")
            done.add(step.name)
            rows.append(row)
            continue
        rec = recorded.get(step.name) or {}
        needs = [
            n for n in step.needs(m) if n not in ctx.state["inputs"] and not declared[n].optional
        ]
        waiting = [d for d in step.after if d not in done]
        row["needs"] = needs
        if rec.get("state") == "done":
            row["state"] = "done"
            done.add(step.name)
        elif needs:
            row["state"] = "pending"
        elif waiting:
            row["state"] = "blocked"
            row["blocked_reason"] = "waiting for " + ", ".join(waiting)
        elif rec.get("state") == "blocked":
            row["state"] = "blocked"
            row["blocked_reason"] = rec.get("blocked_reason")
        else:
            row["state"] = "pending"
        if rec.get("at"):
            row["last_run"] = rec["at"]
        if rec.get("state") == "failed":
            row["last_error"] = rec.get("error_code")
        if step.advisory and rec.get("state") == "blocked":
            # Advisory: recorded human steps never gate anything.
            done.add(step.name)
        rows.append(row)
    return rows


def status_doc(ctx):
    m = ctx.manifest
    rows = step_status(ctx)
    declared = inputs.declared(m)
    next_step = next(
        (
            r["name"]
            for r in rows
            if r["state"] != "done" and not r["advisory"] and r.get("blocked_reason") is None
        ),
        None,
    )
    return {
        "contract_version": CONTRACT_VERSION,
        "ok": True,
        "install_dir": ctx.install.path,
        "install_name": m["install"]["name"],
        "target": m["install"]["target"],
        "primary": m["domain"]["primary"],
        "steps": rows,
        "next_step": next_step,
        "complete": all(r["state"] == "done" for r in rows if not r["advisory"]),
        "inputs": {
            name: {
                "secret": item.secret,
                "optional": item.optional,
                "provided": name in ctx.state["inputs"],
                "kind": inputs.kind(ctx.state["inputs"][name])
                if name in ctx.state["inputs"]
                else None,
                "description": item.description,
            }
            for name, item in sorted(declared.items())
        },
        "keychain_service": macos.keychain_service(m["install"]["name"]),
    }


# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------


def run_step(ctx, name, specs):
    if name not in steps.BY_NAME:
        raise SetupError(
            "unknown_step",
            f"no step {name!r}",
            "steps: " + ", ".join(s.name for s in steps.STEPS),
            exit_code=2,
        )
    step = steps.BY_NAME[name]
    m = ctx.manifest
    declared = inputs.declared(m)
    for spec in specs:
        input_name, ref = inputs.parse(spec, declared)
        ctx.state["inputs"][input_name] = ref
    ctx.install.save_state(ctx.state)

    applies, why = step.applies(m)
    if not applies:
        ctx.state["steps"][name] = {"state": "done", "at": now(), "skipped": True}
        return {"step": name, "ok": True, "skipped": True, "note": f"not applicable: {why}"}, 0
    rows = {r["name"]: r for r in step_status(ctx)}
    waiting = [
        d for d in step.after if rows[d]["state"] != "done" and not (steps.BY_NAME[d].advisory)
    ]
    if waiting:
        raise SetupError(
            "step_order",
            f"{name} runs after {', '.join(waiting)}",
            "run `setup run " + waiting[0] + "` first",
            exit_code=2,
        )
    missing = [n for n in step.needs(m) if n not in ctx.state["inputs"]]
    if missing:
        raise SetupError(
            "input_missing",
            f"{name} needs {', '.join(missing)}",
            " / ".join(
                f"`setup secret {n}` or --input {n}=@/path"
                if declared[n].secret
                else f"--input {n}=<value>"
                for n in missing
            ),
            exit_code=3,
        )

    result = step.run(ctx)
    human = []
    if isinstance(result, tuple):
        result, human = result
    doc = {"step": name, "ok": True, "outputs": result}
    record = {"state": "done", "at": now()}
    if human:
        doc["human_steps"] = human
        if step.advisory:
            record = {"state": "blocked", "at": now(), "blocked_reason": "human_steps_pending"}
            doc["advisory"] = True
    ctx.state["steps"][name] = record
    return doc, 0


def _migrate(install, env, out):
    """``setup run migrate``: not a STEPS entry, so status never waits on it."""
    ctx = None
    try:
        outputs, ctx = migrate.run(install, lambda i: _ctx(i, env))
    except SetupError as exc:
        _emit(_error_doc(exc, "migrate"), ctx, out)
        return exc.exit_code
    doc = {"contract_version": CONTRACT_VERSION, "step": "migrate", "ok": True, "outputs": outputs}
    _emit(doc, ctx, out)
    return 0


def _run(args, env, out):
    install = Install(resolve_dir(args.dir, env.environ))
    if not install.exists():
        raise SetupError(
            "install_dir_missing",
            f"no install.toml in {install.path}",
            "run `setup init --from <manifest>`",
            exit_code=2,
        )
    check_dir_allowed(install.path)
    if args.step == migrate.STEP:
        return _migrate(install, env, out)
    ctx = _ctx(install, env)
    try:
        doc, code = run_step(ctx, args.step, args.input or [])
    except SetupError as exc:
        if exc.code == "awaiting_passkey" or exc.exit_code == 3:
            ctx.state["steps"][args.step] = {
                "state": "blocked",
                "at": now(),
                "blocked_reason": exc.code,
            }
        elif args.step in steps.BY_NAME and exc.exit_code == 1:
            ctx.state["steps"][args.step] = {
                "state": "failed",
                "at": now(),
                "error_code": exc.code,
            }
        install.save_state(ctx.state)
        _emit(_error_doc(exc, args.step), ctx, out)
        return exc.exit_code
    install.save_state(ctx.state)
    doc["contract_version"] = CONTRACT_VERSION
    _emit(doc, ctx, out)
    return code


# ---------------------------------------------------------------------------
# init / secret / teardown
# ---------------------------------------------------------------------------

INIT_HEADER = [
    "Install manifest written by `burrow_install setup init` (ADR 0053, task 01a0d6ab).",
    "Change it with `setup init` flags, not by hand; every write is validated.",
]


def _flatten(table, prefix=""):
    out = {}
    for key, value in table.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            out.update(_flatten(value, path + "."))
        else:
            out[path] = value
    return out


def _diff_keys(old, new):
    a, b = _flatten(old), _flatten(new)
    return sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))


def _init(args, env, out):
    install_dir = args.dir
    existing = None
    if install_dir:
        existing = Install(os.path.abspath(os.path.expanduser(install_dir)))
        if not existing.exists():
            existing = None
    if args.source:
        try:
            raw = load(args.source)
        except ManifestLoadError as exc:
            raise SetupError(exc.code, f"{args.source}: {exc.message}", None, exit_code=2) from exc
    elif existing:
        raw = existing.raw_manifest()
    else:
        raise SetupError(
            "invalid_input",
            "--from <manifest> is required for a new install",
            "e.g. --from deployment/examples/mac-lite.install.toml",
            exit_code=2,
        )
    raw = copy.deepcopy(raw)
    changed = []

    def put(path, value):
        table = raw
        for key in path[:-1]:
            table = table.setdefault(key, {})
        if table.get(path[-1]) != value:
            table[path[-1]] = value
            changed.append(".".join(path))

    def drop(path):
        table = raw
        for key in path[:-1]:
            table = table.get(key, {})
        if path[-1] in table:
            del table[path[-1]]
            changed.append(".".join(path))

    if args.name:
        put(["install", "name"], args.name)
    if args.domain:
        put(["domain", "primary"], args.domain)
    if args.auth_host:
        put(["domain", "auth_host"], args.auth_host)
    if args.livekit_host:
        put(["domain", "livekit_host"], args.livekit_host)
    if args.meetings:
        put(["services", "meetings"], args.meetings == "on")
    # Exactly one image source: a flag for one drops the other from the manifest.
    if args.registry:
        put(["images", "registry"], args.registry)
        drop(["images", "image_namespace"])
    if args.image_namespace:
        put(["images", "image_namespace"], args.image_namespace)
        drop(["images", "registry"])
    errors, normalized = validate(raw)
    if errors:
        raise SetupError(
            "manifest_invalid",
            "; ".join(e.line() for e in errors),
            "adjust the flags (or the --from manifest) and re-run init",
            exit_code=2,
        )
    name = normalized["install"]["name"]
    if install_dir:
        path = os.path.abspath(os.path.expanduser(install_dir))
    else:
        path = os.path.join(default_root(), name)
        legacy = os.path.join(legacy_root(), name)
        # A Mac that has not migrated keeps its install where it is.
        if not Install(path).exists() and Install(legacy).exists():
            path = legacy
    check_dir_allowed(path)
    install = Install(path)
    if install.exists():
        # Report what changed against the install, not against --from.
        changed = _diff_keys(install.raw_manifest(), raw)
    if not install.exists() or changed:
        install.write_manifest(raw, INIT_HEADER)
    state = install.load_state()
    if changed:
        # Hostnames or knobs moved: everything downstream re-runs (idempotent).
        keep = {"preflight", "keepalive", "pocket-id"}
        state["steps"] = {k: v for k, v in state["steps"].items() if k in keep}
    install.save_state(state)
    doc = {
        "contract_version": CONTRACT_VERSION,
        "ok": True,
        "install_dir": path,
        "install_name": name,
        "changed": changed,
        "next": "setup status --json",
    }
    _emit(doc, None, out)
    return 0


def _secret(args, env, out):
    install = Install(resolve_dir(args.dir, env.environ))
    if not install.exists():
        raise SetupError(
            "install_dir_missing",
            f"no install.toml in {install.path}",
            "run `setup init --from <manifest>`",
            exit_code=2,
        )
    ctx = _ctx(install, env)
    declared = inputs.declared(ctx.manifest)
    if args.name not in declared:
        raise SetupError(
            "unknown_input",
            f"{args.name} is not an input of this install",
            "known inputs: " + ", ".join(sorted(declared)),
            exit_code=2,
        )
    item = args.item or args.name
    macos.check_item(item)
    service = macos.keychain_service(ctx.install_name)
    value = env.keychain.prompt(args.name, ctx.install_name)
    if args.name == inputs.REGISTRY_AUTH:
        try:
            value = json.dumps(json.loads(value), separators=(",", ":"))
        except ValueError as exc:
            raise SetupError(
                "registry_auth_invalid",
                "the pasted value is not JSON",
                "paste the docker config.json content",
                exit_code=2,
            ) from exc
    ctx.seen_secrets[args.name] = value
    env.keychain.store(service, item, value)
    ctx.state["inputs"][args.name] = f"keychain:{item}"
    install.save_state(ctx.state)
    _emit(
        {
            "contract_version": CONTRACT_VERSION,
            "ok": True,
            "input": args.name,
            "stored": "keychain",
            "keychain_service": service,
            "keychain_item": item,
            "length": len(value),
        },
        ctx,
        out,
    )
    return 0


def _teardown(args, env, out):
    install = Install(resolve_dir(args.dir, env.environ))
    ctx = _ctx(install, env)
    name = ctx.install_name
    if args.confirm != name:
        raise SetupError(
            "confirmation_required",
            "teardown deletes this install's data",
            f"re-run with --confirm {name}",
            exit_code=2,
        )
    outputs = {}
    if os.path.exists(install.file("compose.yaml")):
        result = ctx.compose("down", "-v", "--remove-orphans", timeout=600)
        outputs["compose_down"] = "ok" if result.ok else f"exit {result.returncode}"
    agents = []
    if ctx.host.platform == "darwin":
        # The legacy labels too: an install made before task 01a14dd8 has those.
        for job in ("backup", "ip-watch"):
            for label in (macos.agent_label(name, job), macos.legacy_agent_label(name, job)):
                if macos.remove_agent(ctx.host, label):
                    agents.append(label)
    outputs["launch_agents_removed"] = agents
    if ctx.state["ids"].get("tunnel_id") and inputs.CLOUDFLARE_API_TOKEN in ctx.state["inputs"]:
        outputs["cloudflare"] = cloudflare.teardown(ctx, ctx.value(inputs.CLOUDFLARE_API_TOKEN))
    ctx.state["steps"] = {}
    install.save_state(ctx.state)
    outputs["left_in_place"] = [install.path, "backups under ~/BurrowBackups"]
    _emit({"contract_version": CONTRACT_VERSION, "ok": True, "outputs": outputs}, ctx, out)
    return 0


def _status(args, env, out):
    install = Install(resolve_dir(args.dir, env.environ))
    if not install.exists():
        raise SetupError(
            "install_dir_missing",
            f"no install.toml in {install.path}",
            "run `setup init --from <manifest>`",
            exit_code=2,
        )
    ctx = _ctx(install, env)
    _emit(status_doc(ctx), ctx, out)
    return 0


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse quotes the offending argument; it may be a secret someone
        # typed in the wrong place, so only the reason before the colon is kept.
        reason = message.split(":", 1)[0]
        raise SetupError(
            "usage", f"{reason} (the argument is not repeated here)", "see `setup --help`", 2
        )


def parser():
    p = _Parser(prog="burrow_install setup", description="deterministic install setup")
    sub = p.add_subparsers(dest="command", required=True, parser_class=_Parser)

    c = sub.add_parser("init", help="create or change the install's manifest")
    c.add_argument("--from", dest="source")
    c.add_argument("--dir")
    c.add_argument("--name")
    c.add_argument("--domain")
    c.add_argument("--auth-host")
    c.add_argument("--livekit-host")
    c.add_argument("--meetings", choices=("on", "off"))
    c.add_argument(
        "--registry",
        help="registry path of the Burrow images, e.g. ghcr.io/<owner> (images.registry; "
        "required unless the --from manifest sets an image source)",
    )
    c.add_argument(
        "--image-namespace",
        help="LEGACY, deprecated: Docker Hub namespace of the old images "
        "(images.image_namespace); replaces images.registry",
    )

    c = sub.add_parser("status", help="every step's state as JSON")
    c.add_argument("--json", action="store_true", help="accepted for clarity; output is JSON")
    c.add_argument("--dir")

    c = sub.add_parser("run", help="run one step")
    c.add_argument("step", choices=[s.name for s in steps.STEPS] + [migrate.STEP])
    c.add_argument("--dir")
    c.add_argument("--input", action="append", metavar="NAME=REF")

    c = sub.add_parser("secret", help="store a secret input in the macOS Keychain via a dialog")
    c.add_argument("name")
    c.add_argument("--item")
    c.add_argument("--dir")

    c = sub.add_parser("teardown", help="compose down -v, remove LaunchAgents, tunnel and DNS")
    c.add_argument("--confirm", required=True)
    c.add_argument("--dir")
    return p


COMMANDS = {"init": _init, "status": _status, "run": _run, "secret": _secret, "teardown": _teardown}


def main(argv=None, env=None, out=None):
    out = out or sys.stdout
    env = env or Env()
    try:
        args = parser().parse_args(argv)
        return COMMANDS[args.command](args, env, out)
    except SetupError as exc:
        _emit(_error_doc(exc), None, out)
        return exc.exit_code
