# Releasing Burrow

A merge to `main` publishes new container images to `ghcr.io/getburrowing`. CI ends at the registry: no workflow in this repo deploys anything. A merge moves the published tags, so it is a release for any install that follows them.

## What triggers a build

[`ci.yml`](.github/workflows/ci.yml) runs on a push or pull request to `main`, `feat/**` and `stack/**`. It has no `paths:` filter, so a docs-only merge still builds and publishes images. Pull requests run the tests and publish nothing, because every publish job runs only on a push.

## What gates publishing

`build-and-push` has `needs: [test, test-with-play, test-with-social]`. The `test` job itself needs `test-checks` and `test-shard`, and goes red when either does. Jobs outside that chain, such as `installer` and `meeting-voice-agent`, do not hold back an image.

Publishing then runs in order: `build-and-push`, `publish-manifest`, `build-and-push-play`. Each job needs the one before it.

## What gets published on main

All images below are in `ghcr.io/getburrowing`.

| Job | Image | Architectures | Tags |
|---|---|---|---|
| `publish-manifest` | `core`, without modules | amd64, arm64 | `core:core`, `core:core-<sha>`, `core:core-<short>` |
| `build-and-push-play` | `core`, with Play | amd64 | `core:play`, `core:play-<sha>`, `core:play-<short>`, `core:latest`, `core:<sha>`, `core:<short>` |
| `build-and-push-agent-host` | `burrow-agent-host` | Not set in the job | `burrow-agent-host:latest`, `burrow-agent-host:<sha>` |

`latest` is the with-Play image and the last tag to move. If `build-and-push-play` fails, the `core-*` tags already point at the new commit and `latest` still points at the previous one.

`build-and-push-agent-host` runs only on a push to `main` and publishes only when that push changes `services/agent-host/**`. It does not depend on `test`: its own typecheck and unit tests gate the push. It also pushes the pre-rename image name, for hosts installed before the rename.

A push to `feat/**` or `stack/**` publishes commit tags and branch tags such as `core:core-<branch>` and `core:play-<branch>`, with `/` in the branch name replaced by `-`. It does not move `core`, `play` or `latest`.

No workflow publishes the `files-service`, `memory-service` or `meeting-transcriber` images that an [install manifest](deployment/schema/install-manifest.md) can name.

## Other workflows and client apps

[`mirror-images.yml`](.github/workflows/mirror-images.yml) copies pinned third-party base images to the registry weekly, on a push to `main` that edits the workflow, or by hand. It releases no product code.

[`ios.yml`](.github/workflows/ios.yml) builds and tests the iOS app, unsigned. It uploads nothing to a store, and no workflow builds an Android release. Client releases are scripts run by hand:

- iOS: `clients/ios/scripts/testflight.sh`, documented in the [iOS README](clients/ios/README.md#testflight-mac-host-only).
- Android: `clients/android/scripts/release.sh`, documented in the [Android README](clients/android/README.md#release).

## How a running install changes

This repo ships no automatic update for an install rendered by the installer. The rendered `core-platform` service names the flavour tag `core` or `play`, chosen by `install.modules`, and never `latest`. The golden renders for all eight fixtures in `deployment/installer/tests/golden` contain no `docker pull`, `compose pull`, `AutoUpdate=` or timer. The only scheduled jobs the installer can add are backups and, on a Mac with public meeting media, an address check. `day2.upgrade_channel` is validated but not acted on ([install manifest](deployment/schema/install-manifest.md), [ADR 0053](docs/decisions/0053-install-manifest-and-renderers.md) section 6).

To change what a rendered install runs, change its manifest, render again with its current secrets, and deploy the output ([install modules](deployment/schema/install-modules.md)):

```sh
PYTHONPATH=deployment/installer python3 -m burrow_install render <manifest> \
  --reuse-secrets <current secrets.env> --out <new dir>
```

The installer needs Python 3.11 or newer. This repo documents no other update command for a rendered install.

An operator can instead configure a host to follow a moving tag. [ADR 0055](docs/decisions/0055-extension-contract-and-build-time-modules.md) section 9 shows installs on `latest` with `AutoUpdate=registry`, and that configuration lives outside this repo. Such a unit follows the tag named on its `Image=` line, so a merge to `main` reaches it without further action in this repo.

## Pinning a build

To run one specific build of a rendered install, set `images.refs.core-platform` in the manifest:

```toml
[images]
registry = "<registry>"
refs = { core-platform = "<registry>/core:play-<sha>" }
```

Rendering a play install with this ref changes one line of `compose.yaml`, the `core-platform` image. The ref must be a build of the same flavour as `install.modules`.

Both image flavours run `Platform.Release.migrate()` on boot, and that call only migrates up. Pinning an older build does not reverse migrations a newer build has already applied.

## Checking what is running

`GET /health` returns the commit the image was built from:

```json
{"status": "ok", "commit": "<sha>"}
```

CI passes the commit into the image as the `GIT_SHA` build argument. The response is `200` whatever the commit is, so compare the `commit` value with the merge you expect. The value is `unknown` when the image carries no build commit.
