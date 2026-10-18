"""Agent-driven install setup (task 01a0d6ab stage 4).

``python3 -m burrow_install setup ...`` is a deterministic CLI over the
renderer: it never prompts on the terminal, prints one JSON document per
command, and is the only thing that mutates install state. A harness-agnostic
skill (deployment/installer/skill/SKILL.md) drives it; a future desktop app
(task 01a0d6b9) wraps the same JSON contract.

Modules:
- ``cli``        commands and the JSON contract;
- ``state``      the install directory, state.json, secrets.env;
- ``inputs``     input references (file, env, Keychain) and secret_in_argv;
- ``steps``      the step registry and the generic steps;
- ``cloudflare`` zone, depth rule, tunnel, DNS (mac, cloudflare-tunnel);
- ``pocketid``   first admin and OIDC client via pocket-id's API (any target);
- ``macos``      Keychain, pmset/FileVault, launchd (mac);
- ``host``, ``web`` the subprocess and HTTP doors, replaced by fakes in tests.
"""
