"""Inputs: what the human supplies, and how a value travels without being seen.

A step names the inputs it needs. An input is supplied ONCE as a reference,
and ``state.json`` keeps the reference, never the value:

- ``NAME=@/abs/path``     a file (for a secret: mode 0600, owned by you);
- ``NAME=env:VAR``        an environment variable of the CLI process;
- ``NAME=keychain:ITEM``  login-Keychain item ITEM under service
                          ``suite-install.<install.name>`` (see ``setup secret``);
- ``NAME=value``          a literal, ONLY for a non-secret input (ADMIN_EMAIL).
                          For a secret input it is refused as ``secret_in_argv``.

``secret_in_argv`` cannot un-send a value that was already typed on a command
line (it is in the shell history and the agent's transcript by then); what it
does is refuse to USE it, so the habit never works, and the remediation names
the safe forms. The refusal message never repeats the value.
"""

import os
import stat

from .. import render as render_mod
from .macos import check_item, keychain_service
from .state import SetupError


class Input:
    def __init__(self, name, secret, description, optional=False):
        self.name = name
        self.secret = secret
        self.description = description
        self.optional = optional


CLOUDFLARE_API_TOKEN = "CLOUDFLARE_API_TOKEN"
REGISTRY_AUTH = "REGISTRY_AUTH"
ADMIN_EMAIL = "ADMIN_EMAIL"
ADMIN_USERNAME = "ADMIN_USERNAME"
# Refs the setup CLI produces itself rather than asking for.
PRODUCED_REFS = {"TUNNEL_TOKEN"}


def private_images(manifest):
    from .. import registry

    if manifest["images"]["source"] != "registry":
        return []
    return [
        c
        for c in registry.enabled_containers(manifest)
        if registry.SERVICES[c].private_image and not manifest["images"]["refs"].get(c)
    ]


def customer_refs(manifest):
    """Customer-supplied secret refs the renderer needs, minus the ones setup produces."""
    refs = render_mod._customer_refs(manifest)
    access = manifest["access"]
    produced = set()
    if manifest["install"]["target"] == "mac" and access["mode"] == "cloudflare-tunnel":
        produced.add(access["tunnel_token_ref"])
    return {ref: where for ref, where in sorted(refs.items()) if ref not in produced}


def declared(manifest):
    """``{name: Input}`` for this manifest."""
    out = {}
    mac = manifest["install"]["target"] == "mac"
    if mac and manifest["access"]["mode"] == "cloudflare-tunnel":
        out[CLOUDFLARE_API_TOKEN] = Input(
            CLOUDFLARE_API_TOKEN,
            True,
            "Cloudflare API token with Zone:Read, DNS:Edit and Account: Cloudflare Tunnel:Edit",
        )
    if private_images(manifest):
        out[REGISTRY_AUTH] = Input(
            REGISTRY_AUTH,
            True,
            "a docker config.json with a Docker Hub read credential for the private "
            "suite-* images under images.image_namespace (anonymous pulls return 401)",
        )
    for ref, where in customer_refs(manifest).items():
        out[ref] = Input(ref, True, f"customer secret named by {where}")
    if manifest["auth"]["mode"] == "bundled-pocket-id":
        out[ADMIN_EMAIL] = Input(ADMIN_EMAIL, False, "email of the first Burrow admin")
        out[ADMIN_USERNAME] = Input(
            ADMIN_USERNAME,
            False,
            "username of the first admin (default: the part of ADMIN_EMAIL before @)",
            optional=True,
        )
    return out


def parse(spec, inputs):
    """``NAME=<ref>`` -> ``(name, stored_ref)``. Never echoes a literal value."""
    name, sep, ref = spec.partition("=")
    name = name.strip()
    if not sep or not name:
        raise SetupError(
            "invalid_input",
            "an input is NAME=@/path, NAME=env:VAR, NAME=keychain:ITEM or NAME=value",
            None,
            exit_code=2,
        )
    if name not in inputs:
        raise SetupError(
            "unknown_input",
            f"{name} is not an input of this install",
            "known inputs: " + ", ".join(sorted(inputs)),
            exit_code=2,
        )
    item = inputs[name]
    if ref.startswith("@"):
        path = os.path.abspath(os.path.expanduser(ref[1:]))
        if not os.path.isfile(path):
            raise SetupError(
                "input_file_missing", f"{name}: no file at {path}", "check the path", exit_code=2
            )
        if item.secret:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            if mode & 0o077:
                raise SetupError(
                    "secret_file_permissions",
                    f"{name}: {path} is mode {mode:04o}; a secret file must not be readable "
                    "by group or others",
                    f"chmod 600 {path}",
                    exit_code=2,
                )
        return name, "@" + path
    if ref.startswith("env:"):
        var = ref[4:]
        if not var:
            raise SetupError("invalid_input", f"{name}: env: needs a variable name", None, 2)
        return name, "env:" + var
    if ref.startswith("keychain:"):
        check_item(ref[9:])
        return name, ref
    if item.secret:
        raise SetupError(
            "secret_in_argv",
            f"{name} is a secret and was given as a literal value on the command line; "
            "it was NOT used or stored",
            f"run `setup secret {name}` (macOS Keychain dialog), or write it to a 0600 file "
            f"and pass {name}=@/path, or export it and pass {name}=env:VAR. Treat the value "
            "you typed as exposed (shell history) and rotate it.",
            exit_code=2,
        )
    return name, ref


def kind(ref):
    if ref.startswith("@"):
        return "file"
    if ref.startswith("env:"):
        return "env"
    if ref.startswith("keychain:"):
        return "keychain"
    return "literal"


def resolve(ctx, name, required=True):
    """The value of input ``name`` (in memory only), or None when optional and absent."""
    ref = ctx.state["inputs"].get(name)
    if ref is None:
        if required:
            raise SetupError(
                "input_missing",
                f"{name} has not been supplied",
                f"run `setup secret {name}` or pass --input {name}=@/path",
                exit_code=3,
            )
        return None
    k = kind(ref)
    if k == "file":
        try:
            with open(ref[1:], encoding="utf-8") as handle:
                value = handle.read()
        except OSError as exc:
            raise SetupError(
                "input_unreadable", f"{name}: {exc.strerror}", "re-supply the input", exit_code=3
            ) from exc
        return value.strip() if name != REGISTRY_AUTH else value
    if k == "env":
        value = ctx.environ.get(ref[4:])
        if not value:
            raise SetupError(
                "input_env_unset",
                f"{name}: environment variable {ref[4:]} is empty in this process",
                f"export {ref[4:]} before running, or re-supply {name} as a file or Keychain item",
                exit_code=3,
            )
        return value
    if k == "keychain":
        service = keychain_service(ctx.install_name)
        value = ctx.keychain.read(service, ref[9:])
        if value is None:
            raise SetupError(
                "keychain_item_missing",
                f"{name}: no Keychain item {ref[9:]} under service {service}",
                f"run `setup secret {name}`",
                exit_code=3,
            )
        return value
    return ref
