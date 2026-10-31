"""Command line: ``python3 -m burrow_install <command> ...``.

Commands:
  validate <manifest>   print ``ok`` and exit 0, or one ``error <code> at <path>: <msg>``
                        line per problem and exit 2. A valid manifest that uses a
                        deprecated input also prints ``warning deprecated at <path>: <msg>``
                        to stderr (every command that reads a manifest does).
  services <manifest>   print the enabled container set, one name per line, sorted
                        (exit 2 with the same error lines if the manifest is invalid).
  render <manifest> --out <dir> [--target <install.target>] [--reuse-secrets <secrets.env>]
         [--customer-secrets <file>] [--registry-auth <config.json>]
                        write the install files; print the file list and the secret
                        NAMES (never a value).
  setup <command> ...   the agent-driven setup CLI (init, status, run, secret,
                        teardown); see burrow_install/setup/cli.py and
                        deployment/installer/mac/README.md.
  proof <command> ...   data-plane proof of a Mac install (init, ports, ram, arch,
                        memory, files, meetings, livekit, grep-transcript); see
                        burrow_install/proof_mac.py and deployment/installer/mac/proof.sh.
  bootstrap-admin --base https://<auth host> --api-key-file <0600 file> --email <addr>
         [--username <u>] --link-file <path>
                        create (or find) the first pocket-id admin and write a fresh
                        one-time sign-in link to --link-file (0600); print one JSON
                        document, never the link or the key. Exit 0 ok, 1 pocket-id
                        unreachable or erroring, 2 usage. See burrow_install/bootstrap.py.
  redact <render-dir> --out <dir>
                        copy a render with every secret value replaced by
                        ``<secret:NAME>``, so two renders can be diffed safely.
"""

import argparse
import sys

from . import registry
from .manifest import ManifestLoadError, load
from .render import DEFAULT_TARGET, TARGETS, RenderError, redact_dir, render
from .validate import validate, warnings

EXIT_OK = 0
EXIT_INVALID = 2


def _load_valid(path, out):
    try:
        raw = load(path)
    except ManifestLoadError as exc:
        print(f"error {exc.code} at {path}: {exc.message}", file=out)
        return None
    errors, normalized = validate(raw)
    for error in errors:
        print(error.line(), file=out)
    if normalized is not None:
        # stderr, so stdout keeps its one-line `ok` / file-list contract.
        for warning in warnings(normalized):
            print(warning.line(), file=sys.stderr)
    return normalized


def _parser():
    parser = argparse.ArgumentParser(prog="burrow_install", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (
        ("validate", "check a manifest against schema v1"),
        ("services", "print the enabled container set"),
    ):
        cmd = sub.add_parser(name, help=help_text)
        cmd.add_argument("manifest")

    cmd = sub.add_parser("render", help="write the install files for one target")
    cmd.add_argument("manifest")
    cmd.add_argument("--out", required=True, help="new or empty directory outside any git tree")
    cmd.add_argument(
        "--target",
        choices=sorted(TARGETS),
        default=None,
        help=f"optional check: must equal the manifest's install.target (default {DEFAULT_TARGET})",
    )
    cmd.add_argument("--reuse-secrets", metavar="SECRETS_ENV")
    cmd.add_argument("--customer-secrets", metavar="FILE")
    cmd.add_argument("--registry-auth", metavar="CONFIG_JSON")

    cmd = sub.add_parser("redact", help="copy a render with secret values replaced")
    cmd.add_argument("render_dir")
    cmd.add_argument("--out", required=True)
    return parser


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv and argv[0] == "setup":
        from .setup.cli import main as setup_main

        return setup_main(argv[1:])
    if argv and argv[0] == "bootstrap-admin":
        from .bootstrap import main as bootstrap_main

        return bootstrap_main(argv[1:])
    if argv and argv[0] == "proof":
        from .proof_mac import main as proof_main

        return proof_main(argv[1:])
    args = _parser().parse_args(argv)

    if args.command == "redact":
        try:
            redact_dir(args.render_dir, args.out)
        except RenderError as exc:
            print(exc.line())
            return EXIT_INVALID
        print(f"redacted {args.render_dir} -> {args.out}")
        return EXIT_OK

    manifest = _load_valid(args.manifest, sys.stdout)
    if manifest is None:
        return EXIT_INVALID
    if args.command == "validate":
        print("ok")
    elif args.command == "services":
        for container in registry.enabled_containers(manifest):
            print(container)
    else:
        try:
            rendered = render(
                manifest,
                args.out,
                target=args.target,
                reuse_secrets=args.reuse_secrets,
                customer_secrets=args.customer_secrets,
                registry_auth=args.registry_auth,
            )
        except RenderError as exc:
            print(exc.line())
            return EXIT_INVALID
        print(f"rendered target {manifest['install']['target']} into {args.out}")
        for rel, (_text, mode) in sorted(rendered.files.items()):
            print(f"file {rel} {mode:04o}")
        for name in sorted(rendered.generated):
            print(f"secret generated-or-reused {name}")
        for name in sorted(rendered.customer):
            print(f"secret customer {name}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
