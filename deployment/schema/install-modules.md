# Adding a build-time module to an install

This is the one procedure [ADR 0055 § 10](../../docs/decisions/0055-extension-contract-and-build-time-modules.md#10-how-to-add-a-module-to-an-install)
points at. A build-time module (today only **Play**, `apps/game_stream`) is
compiled into the core image. An install therefore gets a module by running
the image **flavour** that contains it. It is never a container, a migration
step or a SQL script.

## Flavours

CI publishes one image per supported module set (`.github/workflows/ci.yml`,
`build-and-push`), all in `docker.io/example/suite-core`:

| Module set | Built from | Moving tag | Pinned tags |
|---|---|---|---|
| none | `apps/platform/Dockerfile` | `core` | `core-<sha>`, `core-<short_sha>` |
| `play` | `apps/burrow_release/Dockerfile` | `play` | `play-<sha>`, `play-<short_sha>` |

`latest`, `<sha>` and `<short_sha>` are the **with-Play** image. They stay on
that image only so that the three hand-maintained test-host installs keep their
behaviour until they are repointed (below). Do not point a new install at
`latest`: it names a flavour by accident of history, not by choice.

`deployment/installer/suite_install/registry.py` (`IMAGE_FLAVOURS`) is the
source of the mapping the renderer uses. A test in
`deployment/installer/tests/test_render.py` fails if CI stops publishing any
tag listed there.

## An install rendered from a manifest

1. Add the module to `[install]` in the install's manifest. This is the one
   config line:

   ```toml
   [install]
   name = "acme"
   modules = ["play"]
   ```

2. Re-render, keeping the install's secrets, and deploy the output as usual:

   ```sh
   PYTHONPATH=deployment/installer python3 -m suite_install render acme.install.toml \
     --reuse-secrets <current secrets.env> --out <new dir>
   ```

   The render differs from the previous one in two lines only: the
   core-platform image becomes `suite-core:play`, and core-platform gains
   `GAME_STREAM_ENABLED=true` (see "The transitional gate" below). The
   renderer test `test_selecting_play_changes_only_the_core_image_and_its_gate`
   holds that.

3. Nothing else. On boot the image runs `Platform.Release.migrate()`, which
   runs core's migrations path and then the module's. A database that predates
   the module gets the module's migrations then, even though their versions are
   older than core's newest (ADR 0055 § 6). No manual SQL, no flag and no
   second step. `scripts/module-enable-later-rig.sh enable-later` proves this
   on test-host against the real images.

**Removing a module** is the same edit in reverse (`modules = []`, which
renders `suite-core:core`). Its tables and its `play` bundle grants stay in the
database untouched (ADR 0055 § 6, § 7), so enabling it again later loses
nothing.

## The hand-maintained test-host installs

Install A (`core-platform`), Install B (`core-platform-b`) and Install C
(`core-platform-c`) are not rendered from a manifest. Each one's
quadlet in core-ops (`~/.config/containers/systemd/<name>.container` on test-host)
has an `Image=` line, and that line is the module selection:

```ini
Image=docker.io/example/suite-core:play   # with Play
Image=docker.io/example/suite-core:core   # without modules
```

Change it, then `systemctl --user daemon-reload` and restart the unit. With
`AutoUpdate=registry`, the unit follows that tag from then on. Read the
quadlet before changing it: an install's current behaviour on `latest`
depends on whether it sets `GAME_STREAM_ENABLED`.

Measured 2026-10-02 (read-only): all three pull `suite-core:latest`. Install A sets
`GAME_STREAM_ENABLED=true`, while Install B and Install C leave it unset. ADR 0055
§ 9 records the repoint that keeps each one's behaviour: Install A to `play`, and
Install B and Install C to `core`.

## The transitional gate

Until ADR 0055 follow-up 1 lands, Play still checks `GAME_STREAM_ENABLED`
inside the module. That is why it is set by `MODULE_CORE_ENV` in the
registry, and why a with-Play image with it unset behaves exactly as main did
with the flag unset. After every install runs an explicit flavour tag, the
follow-up deletes the gate, which is one file inside `apps/game_stream`. It
also deletes the registry entry, and selecting the flavour is then the whole
procedure.
