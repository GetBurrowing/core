# Burrow rename: Suite names deliberately kept

The ledger of every `suite`-named identifier that the Burrow rename (task 01a14ba9, "A2b")
deliberately does NOT rename yet. Release task E reads this file. Each entry gives the name,
where it lives, why it stays, and the condition under which it can go. Later stages of 01a14ba9
append to this file. `docs/runbooks` is not scanned by `ProductNameGuardTest`, so this file may
name the old ids.

## Federation protocol v1 (stage 2)

Background: ADR 0054, section "Protocol versions".

| name | where | why it stays | removal condition |
|---|---|---|---|
| protocol id `suite-federation/1`, signing prefix `"suite-federation/1\n"` | `Platform.Federation.Peers.Envelope` (`@protocol_v1`, `@prefix`) | The id is inside the signed bytes. An install running core from before 01a14ba9 can verify only this, and every install still sends it by default (`PEER_FEDERATION_SIGNING_PROTOCOL` unset). | Every known install sends v2, and `Platform.Federation.Peers.protocol_readiness/0` on every install shows no v1-only peer. |
| header `suite-federation-signature` | `Envelope` (`@signature_header`), the verifier's v1 arm | Same as the id: it is the v1 wire format. | Same as above. |
| descriptor `"protocol": "suite-federation/1"` | `PlatformWeb.FederationWellKnownController` | Older clients accept a descriptor only when `protocol` is `suite-federation/1`. | Same as above. |
| path `/.well-known/suite-federation` (served, and fetched by `Client.fetch_descriptor/1`) | router, `Platform.Federation.Peers.Client` (`@descriptor_path`) | An install on older core serves only this path, so the client must keep fetching it. `/.well-known/burrow-federation` is already served beside it. | Same as above. In that release, also switch the client's fetch path to `/.well-known/burrow-federation`. |
| env `PEER_FEDERATION_SIGNING_PROTOCOL` | `Platform.Federation.Peers.Config.signing_protocol/0` | This is the switch for the transition, not a Suite name. Listed here so it is removed along with v1. | When v1 is retired, v2 becomes unconditional and the variable goes. |

## Doctor report signing prefix (stage 2)

| name | where | why it stays | removal condition |
|---|---|---|---|
| `"suite-doctor/1\n"` | ADR 0056 section B.3, text only | It is not implemented anywhere in code, so renaming it would change no behaviour. Nothing signs or verifies with it yet. | When the doctor key is implemented, name the prefix `burrow-doctor/1` from the start, and update ADR 0056 in the same change. |

## Release host `apps/suite_release` (stage 3)

Stage 3 renamed the directory to `apps/burrow_release` and the Mix project to
`BurrowRelease.MixProject` / `:burrow_release`. The OTP release inside it is still named
`platform`, so `/app/bin/platform`, the image names and the tags did not change. The only lines
that still say `suite_release` are dated measurement records. They describe the tree as it was
when it was measured, so renaming them would make them false.

| name | where | why it stays | removal condition |
|---|---|---|---|
| `suite_release` | `apps/platform/notes/2026-10-02-elixir-1.20.4-module-definition.md` (line 124) | Dated measurement record (2026-10-02) of the tree as it was then. A3 (01a14b9e) has since moved the other 2026-10-02 note out of the tree. | None. It is history. |
| `suite_release` | ADR 0055: the S9 bullet in section 1 (line 110) and the `## Proof` section (lines 689, 699, 716, 718, 719, 856, 869, 875) | These lines quote measurements taken 2026-09-29 to 2026-10-02. The ADR's current-state lines (83, 119, 264, 455) now say `burrow_release`. | None. It is history. |

## Capacitor plugin wire names (stage 4)

Core JS (stage 4) reads `Capacitor.Plugins.BurrowNative || Capacitor.Plugins.SuiteNative` at
`assets/js/hooks/push_subscribe.js`, `assets/js/hooks/native_install_switch.js` and
`assets/js/native_donations.js`. It reads `BurrowMeetings || SuiteMeetings` at
`assets/js/hooks/meeting_client.js`. Burrow wins when both are present. The app side keeps
registering the Suite names. An app build that registered only the Burrow names would lose push,
badges, install switching and donations whenever it signed in to an install whose core JS is
older than stage 4.

| name | where | why it stays | removal condition |
|---|---|---|---|
| Capacitor plugin name `SuiteNative` | Android: `@CapacitorPlugin(name = "SuiteNative")` and `NativeBridgeExposure.PLUGIN_IDS`. iOS: the plugin's `jsName` | This is the JS-facing wire name. Installed core JS older than stage 4 looks up only `SuiteNative`. | Every install runs core JS that carries the stage 4 fallback. The app release that follows then flips the registration to `BurrowNative`. |
| Capacitor plugin name `SuiteMeetings` | iOS: the meetings plugin's `jsName` (there is no Android meetings plugin) | Same as `SuiteNative`. | Same, with `BurrowMeetings`. |
| `plugins.SuiteNative` / `plugins.SuiteMeetings` fallback | the four core JS sites above | It keeps app builds that register only the Suite names working. | Drop it once no supported app build registers only the Suite names, which is one app release after the flip above. |

Why the Android app does not register both names: in Capacitor 8.5.2 (`Bridge.registerPlugin`,
`PluginHandle`, `Plugin.notifyListeners`), every registration builds its own `PluginHandle` and
`Plugin` instance, keyed by the class's `@CapacitorPlugin(name)`. One class carries one name, so a
second name needs a second class. `eventListeners` is a per-instance field, and `notifyListeners`
walks only that instance's map. A listener added through one name is therefore never notified by
the other name's instance. The Android plugin does not call `notifyListeners` today, because badges
travel as a window event through `bridge.triggerWindowJSEvent`. Dual registration would still give
the app two independent plugin instances with separate state, so it is not done.

### Excluded from the stage 4 Android rename

| name | where | why it stays | removal condition |
|---|---|---|---|
| legacy `SUITE_*` push category handling | Android push code, from A1b's dual scheme | A1b registers both `SUITE_*` and `BURROW_*` categories and sends the right one per device scheme, so older app builds keep their notification actions. | A1b's own removal gate: no supported app build registers only `SUITE_*`. |
| published `applicationId` | `clients/android/android/app/build.gradle` | It is the published store id. Changing it ships a different app (A3's `@published_ids`). | None planned. |
| real install hostnames | Android sources and tests | Owned by A3 (01a14b9e) and A3b (01a14dce). A3 replaced them with placeholders, except for the former default hosts in `InstallStoreTest.kt`, which it kept on purpose as the preimages of its shipped digest list. `ProductNameGuardTest` skipped those lines through an A3-owned hash list. This stage renames only `suite`-shaped placeholders. A3b stage 3 landed the digest seam: both `InstallStore` tests now use `example.com` stand-ins (and `burrow.example.com` for their non-legacy host), and the preimage check moved to a private core-ops script. The skip then excused no scanned line, and A3b stage 4 removed it. | Done (A3b stage 4): the guard has no A3 skip. |

### Android names kept by stage 4

Stage 4 applied one token map to every tracked file under `clients/android`, except the two files listed below (`push_seal_v1.json` and `InstallStoreTest.kt`): `SuiteNativePlugin` -> `BurrowNativePlugin` (class and file), the iOS type mentions `SuiteAPIClient` / `SuiteBridgeViewController` / `SuiteWidgets` -> `Burrow*`, `suite-a.localhost` / `suite-b.localhost` -> `burrow-a.localhost` / `burrow-b.localhost`, `suite.example.{com,net,org,test}` -> `burrow.example.*` (with the upper- and mixed-case forms that the host-normalisation tests use), and `This Suite` -> `This Burrow`. **Stage 5 must use the same Burrow names for the iOS types**, because the Android comments and README already point at them. After the map, `ProductNameGuardTest` scans `clients/android/**/*.{kt,xml,gradle,kts}`.

| name | where | why it stays | removal condition |
|---|---|---|---|
| `"install_host": "suite-b.localhost"` | `clients/android/android/app/src/test/resources/push_seal_v1.json` | The fixture is sealed: the host is the HPKE AAD. Its copies in core (`apps/platform/test/support/fixtures/`) and iOS must stay byte-identical (`seal_fixture_parity_test.exs`), and the core push tests also use the `suite-a`/`suite-b` hosts. Resealing it means changing all three copies together. | A core-and-iOS change reseals all three copies with a `burrow-b.localhost` host (the way A3's c12a1cc9b did) and renames the core push test hosts. |
| `~/.config/suite-android-build/` | `clients/android/README.md`, release section | It is a path on the release build host, outside the repo. Renaming it in the README would make the instructions wrong. | Rename it on the build host first, then in the README. |
| `` `SuiteNative` `` in comments | `BurrowNativePlugin.kt`, `NativeBridgeExposure.kt`, `ConversationNoter.kt`, `DonateDispatchTest.kt`, README | These comments name the JS wire name, which is unchanged (see above). The guard allowlists each one by its exact quoted or backticked form, so a bare `SuiteNativePlugin` cannot hide behind it. | Flipping the wire name. |

## iOS client (stage 5)

Stage 5 applied one explicit token map to every tracked file under `clients/ios`, except the files listed in the tables below. It renamed the Swift types to `Burrow*` (`BurrowColor`, `BurrowFont`, `BurrowRadius`, `BurrowLayout`, `BurrowAPIClient`, `BurrowAPI`, `BurrowBridgeViewController`, `BurrowCounts`, `BurrowApproval`, `BurrowSpace`, `BurrowTask`, `BurrowPerson`, `BurrowOrg`, `BurrowAgent`, `BurrowMessage`, `BurrowMeeting`, `BurrowProject(s)`, `BurrowNativePlugin`, `BurrowMeetingsPlugin`, `BurrowNotificationCategory`, `BurrowButton` and the approve/reject chrome and button styles). It renamed the `SuiteWidgets` target, directory and files to `BurrowWidgets`, and the Swift files `BurrowNativePlugin.swift`, `BurrowMeetingsPlugin.swift`, `BurrowBridgeViewController.swift`, `BurrowAPIClient.swift`, `BurrowAPIClientTests.swift` and `BurrowMeetingsPluginTests.swift`. It renamed the Info.plist keys `BurrowKeychainAccessGroup` / `BurrowPushEnvironment` in every target together with their readers, the launch arguments (`-BurrowEvidence*`, `-BurrowDebug*`, `-BurrowInjectVoIP`, `-BurrowLoginProbe`, `-BurrowExtraInstall`, `-BurrowRequestPush`, `-BurrowAddInstallProbe`) together with the UI tests that pass them, the background-task names, the multipart boundary prefix, the share temp directory, the `suite`-shaped placeholder test hosts, and the copy ("This Burrow accepts files ...").

`project.yml` and `App.xcodeproj/project.pbxproj` were both edited as text, because xcodegen cannot run off a Mac. After the edit, every file reference and group path in the pbxproj resolves to a file on disk, except the three that `npx cap sync` generates (`App/capacitor.config.json`, `App/public`, `App/config.xml`, all gitignored and equally absent at the base). Every build-setting path (Info.plist, entitlements) resolves too.

**Verification, stated honestly.** No iOS build and no XCTest ran for this stage: there is no iOS CI and no macOS on the Linux rigs, and no Mac was used. swift-format lint ran in a Linux Swift toolchain container, which checks format and syntax only and is not a compile. **The first compile of this rename is TestFlight's** (or the next Mac build before it). Whoever builds it should run `xcodegen generate` in `clients/ios/ios/App` first and expect an empty diff against the committed pbxproj, then run the App scheme's AppTests.

Rig scripts outside this repo that pass the old launch arguments (`-SuiteEvidenceReset` and the rest) must switch to the `-Burrow*` names. The app no longer reads the `Suite*` forms.

### iOS names kept by stage 5

| name | where | why it stays | removal condition |
|---|---|---|---|
| UserDefaults keys `suite.installs.v1`, `suite.installs.selected.v1`, `suite.installs.confirmed.v1`, `suite.installs.defaults_checked.v1`, `suite.app_install_id.v1` | `clients/ios/ios/Shared/InstallStore.swift` (and the first three in `AppTests/InstallStoreTests.swift`) | Persisted on users' devices. Renaming any of them silently drops the installs list, the selected install and the app install id on upgrade, and so the person's sign-ins. No iOS test can run here to prove a migration. The guard allowlists each by its exact code form, so renaming the constant fails the guard. | Migrate in a release with a device-tested migration that reads the old key, writes the new one, and is covered by AppTests. |
| UserDefaults keys and prefixes `suite.recent_calls.v1`, `suite.counts.v1.`, `suite.unread.v1.`, `suite.widget.arm.v1`, `suite.widget.rows.v1`, `suite.approvals.v1.`, `suite.shortcuts.digest.v1.`, `suite.shortcuts.dirty.v1`, `suite.shortcuts.refreshed-at.v1`, `suite.share.last_space.v1.`, `suite.intents.last-meeting-space.v1.` | `RecentCalls.swift`, `CountsCache.swift`, `InstallUnreadStore.swift`, `ApprovalsWidgetModel.swift`, `ShortcutParameterRefresh.swift` (and its test's `hasPrefix`), `ShareSheetModel.swift`, `IntentSupport.swift` | Same as above: persisted state (recent calls, cached counts and unread, widget state, Shortcuts digests, the last share space, the last meeting space). | Same as above. |
| `UserDefaults(suiteName:)` and the `suiteName` variables passed to it | iOS sources and tests | Apple's API parameter name, not the brand. | None. |
| Capacitor `jsName = "SuiteNative"` / `"SuiteMeetings"` and the backticked mentions of them in comments | `BurrowNativePlugin.swift`, `BurrowMeetingsPlugin.swift` and the comments listed in `ProductNameGuardTest` | The JS-facing wire names (see "Capacitor plugin wire names" above). The plugin `identifier` and `@objc` name were renamed: Capacitor's bridge keys a registered instance by `jsName` (`registerPluginInstance`: `plugins[pluginInstance.jsName]`), so neither is on the wire. | As above: flip once every install runs core JS with the stage 4 fallback. |
| `SUITE_*` push category ids (`SUITE_MENTION`, `SUITE_OPEN`, `SUITE_RING_WAITING`, `SUITE_REPLY`, `SUITE_OPEN_ACTION`), and `SUITE_MESSAGE` in one test | `BurrowNativePlugin.swift`, `PushContentPreparer.swift`, tests | A1b's dual registration: older cores and devices still send them. | A1b's removal gate. |
| env fallbacks `SUITE_RENDER_DIR` / `TEST_RUNNER_SUITE_RENDER_DIR` (beside `BURROW_RENDER_DIR` / `TEST_RUNNER_BURROW_RENDER_DIR`) and `SUITE_MEETING_PROBE_URL`, `SUITE_MEETING_PROBE_TOKEN`, `SUITE_MEETING_PROBE_ROOM`, `SUITE_MEETING_PROBE_NAME`, `SUITE_MEETING_PROBE_CALLKIT` (beside `BURROW_MEETING_PROBE_URL`, `BURROW_MEETING_PROBE_TOKEN`, `BURROW_MEETING_PROBE_ROOM`, `BURROW_MEETING_PROBE_NAME`, `BURROW_MEETING_PROBE_CALLKIT`) | `ExtensionRenderTests.swift`, `BurrowBridgeViewController.swift` | Already deprecated fallbacks beside the `BURROW_*` names. Each logs a deprecation line when used. | When no rig script sets the old names. |
| `"install_host": "suite-b.localhost"` and the two `SUITE-B` expectations derived from it | `AppTests/Fixtures/push_seal_v1.json`, `AppTests/PushRelayTests.swift` (two lines) | The fixture is sealed (the host is the HPKE AAD) and byte-identical to its core and Android copies (`seal_fixture_parity_test.exs`). The expected labels are derived from its host. One other assertion now derives the host prefix from the fixture (`f.host`) instead of spelling it. | Reseal all three copies together with a `burrow-b.localhost` host (see the Android row above), then rename these two lines. |
| Capacitor `ios.scheme: "Suite"` | `clients/ios/capacitor.config.ts` | A Capacitor CLI setting (the Xcode scheme `npx cap run` uses), not shipped code. The project's schemes are `App`, `Evidence`, `Render` and `IntentsSystem`, so it already names no scheme; changing it changes nothing verifiable here. | The next change that runs `npx cap run ios` on a Mac sets it to `App` and checks it. |
| `~/.config/suite-ios-build/`, `~/Dev/build/suite-ios/`, `Suite-<n>.xcarchive`, TestFlight group "Suite internal", App Store Connect app name in an error message | `clients/ios/scripts/testflight.sh`, `scripts/set_testflight_notes.py`, README release section | Paths on the release build host and names of App Store Connect objects, outside this repo. Renaming them here would break the release scripts. | Rename on the build host and in App Store Connect first, then here. |
| npm package `suite-ios` and its description | `clients/ios/package.json`, `package-lock.json` | Not product copy; the package is never published. | Any later cleanup; renaming it regenerates the lockfile. |
| "the Suite iPhone app" and "match Suite" | `clients/ios/WHATSNEW.md` | Release notes of an already-shipped build (history). | None. |
| "Suite iOS colour assets", "Suite web tokens" | `clients/ios/scripts/generate_assets.py` docstring | Out of the guard's scope and of this stage's file set (a build-host script). | Any later cleanup. |
| the published bundle ids, README history of the old bundle id and URL scheme, real install hostnames | project files, README | Excluded by the plan: published store ids (A3's `@published_ids`), history, and A3/A3b's hosts. | None planned / A3b. |

## Installer and agent host (A2c)

Task 01a14dd8 moved the installer's fresh renders onto Burrow names. A new single-host install
lives under `/opt/burrow` and runs `burrow-stack.service`, `burrow-agent-host.service` and
`burrow-agent@<id>`. A new Mac install lives under `~/burrow/<name>` and runs LaunchAgents
labelled `io.github.getburrowing.install.<name>.<job>`. Images come from `[images] registry`.
The names below stay because an install that already exists depends on them. Each entry says
where the name lives, why it stays, how an existing install moves off it, and when the name can go.

### Upgrading an install made before the rename

**Linux single host.** Run `burrow-migrate` as root on the host. The repo copy of the script is
`deployment/installer/migrate/suite-to-burrow.sh`. Every render since stage 4 of 01a14dd8 also
writes it into the install as `bin/burrow-migrate`. An old host has no such file, so copy it from
a checkout at the release you are upgrading to, and check the hash on both ends:

```bash
sha256sum deployment/installer/migrate/suite-to-burrow.sh deployment/installer/migrate/burrow-to-suite-rollback.sh
scp deployment/installer/migrate/suite-to-burrow.sh root@host.example.com:/usr/local/sbin/burrow-migrate
scp deployment/installer/migrate/burrow-to-suite-rollback.sh root@host.example.com:/usr/local/sbin/burrow-migrate-rollback
ssh root@host.example.com 'chmod 0755 /usr/local/sbin/burrow-migrate*; sha256sum /usr/local/sbin/burrow-migrate*'
```

1. Native-agent hosts (`[agents] profile = "full_machine"`) first need the Burrow agent-host image
   on the host. That is the post-rename build, which carries the daemon at
   `/opt/burrow/agent-host`. Use `docker pull`, or `docker load` it on a preloaded install. If it
   is not under the ref in the old setup script, pass `--agent-host-image <ref>`. The script
   refuses (and changes nothing) when the image holds only the pre-rename daemon.
2. `burrow-migrate` checks first and changes nothing when a check fails: the old root is a real
   directory, the old stack unit exists, and `/opt/burrow` is absent or empty. It then records
   `/var/lib/burrow-migrate/<UTC stamp>/` (the old unit files, the agent host's env, versions
   and sudoers files, the old daemon, `docker compose ls`, `docker volume ls` and the image of
   every running container). It stops the stack with `compose down` (no `-v`), moves the
   directory to `/opt/burrow`, leaves a symlink at the old path, and starts
   `burrow-stack.service`. On a native-agent host it also renames the agents group (the gid is
   kept), and renames the env, versions and sudoers files (the sudoers file is checked with
   `visudo -c` first). Then it copies the new daemon out of the image, installs the
   `burrow-agent-host` units and starts them. The daemon adopts every old agent unit as
   `burrow-agent@<id>`, and the script then removes the old agent template.
3. A second run prints the state and exits 0 without changing anything. Exit 3 means the move is
   done but the daemon has not adopted every agent yet. Check `journalctl -u burrow-agent-host`
   and run it again.
4. To undo it, run `burrow-migrate-rollback <stamp>` (the stamp is printed at the end of step 2).

**Migrate before you re-render.** Stage 3 made the paths unconditional. A legacy
`[images] image_namespace` manifest also renders under `/opt/burrow` with `burrow-*` units, and
only its image refs stay `docker.io/<ns>/suite-*`. Applying such a render to an old host before
migrating writes a second install root beside the live one. `burrow-migrate` then refuses
because `/opt/burrow` is not empty, and nothing has been stopped or moved. To recover, move the
rendered `/opt/burrow` aside, run `burrow-migrate`, then apply the render again. Keep
`install.name` unchanged in the manifest: the compose project name is `install.name`, and the
named volumes (the database among them) are keyed by it.

**Do not refresh the agent-host image on an old host without migrating it.** CI still pushes the
pre-rename tags, but they are now built from the post-rename Dockerfile, so their daemon lives at
`/opt/burrow/agent-host`. The old setup unit copies the daemon from the old path. On an old host
that pulls the new build under the old tag, that copy fails at the next boot, and the agent host
does not start until the host is migrated.

**Mac.** Run `mac/burrow-install setup run migrate`. It finds the install under `~/suite/<name>`
and runs `docker compose down` there (no `-v`). It moves the directory to `~/burrow/<name>` and
runs `compose up -d` there. compose.yaml is unchanged, so the project name and the volumes are
the same. Each LaunchAgent under an old label is rewritten under the new label and bootstrapped,
then the old one is booted out. It points at the new directory and sends new backups to
`~/BurrowBackups/<name>`. `~/SuiteBackups/<name>` is left in place and recorded in state.json as
`ids.legacy_backup_dir`, the read path for backups taken before the move. The step prints one
JSON document like every other setup command. A second run moves nothing, and the step refuses
(exit 2) when both directories exist.

### Names kept or bridged

| name | where | why it stays | upgrade path | removal condition |
|---|---|---|---|---|
| `/opt/suite` symlink to `/opt/burrow` | migrated single hosts (made by `burrow-migrate`) | The old `bin/suite-*` helper scripts the migration keeps (e.g. the CA bundle step `burrow-stack.service` runs before start) and any hand-written cron or ops script still name the old path. | None needed; it is the bridge. | The host has had a post-rename render applied. Then `grep -rs /opt/suite /etc/systemd/system /etc/cron* /opt/burrow/bin` returns nothing, and the link is deleted by hand. |
| old unit, env and sudoers names (`suite-stack.service`, the old agent host and agent units, the old env file, versions dir and sudoers file) | `deployment/installer/migrate/suite-to-burrow.sh` and `burrow-to-suite-rollback.sh`, each defined once on a line marked `# legacy name, kept by burrow-migrate`; also embedded in every render as `bin/burrow-migrate` | The scripts have to name what they move. `tests/test_burrow_names.py` allows them only on the marked lines. | `burrow-migrate`, above. | No supported install predates the rename, in the release that drops the old names from core too. |
| `suite_install` module shim and `mac/suite-install` | `deployment/installer/suite_install/`, `deployment/installer/mac/suite-install` | Older docs, scripts and the Mac app call the old names. Both still run and print a deprecation line (stage 1). | Call `burrow_install` / `mac/burrow-install`. | The Mac app and every doc call the new names, one release after that. |
| Keychain service prefix `suite-install.<name>` | `burrow_install/setup/macos.py`, `inputs.py` | Renaming it loses every secret an existing Mac install stored in the Keychain. | None. Moving it needs a read-old, write-new migration of each item. | A Keychain migration step lands and is run on every Mac install. |
| legacy `[images] image_namespace` and the `docker.io/<ns>/suite-*` refs | `burrow_install/registry.py` (`LEGACY_HUB_IMAGES`), `deployment/examples/mac.install.toml` | Existing manifests set it. CI still pushes those refs. meeting-transcriber has no registry build, so a manifest that runs it under `[images] registry` must pin `images.refs.meeting-transcriber`, and the mac example stays on the legacy key. | `setup init --registry <path>` (or set `[images] registry`), then pull and re-render. | meeting-transcriber publishes a registry build, every known manifest uses `[images] registry`, and CI stops the Docker Hub pushes (backlog task 01a14afe item 1). |
| GHCR `suite-agent-host` tags | `.github/workflows/ci.yml` (pushed beside `burrow-agent-host`; `ci_build_identity_test.exs` pins both lists) | Hosts set up before the rename pull this name, and so does any deployment outside the installer that was written against it (ci.yml's own note). The installer itself never rendered this GHCR ref, because before stage 3 it rendered only Docker Hub refs. | `burrow-migrate --agent-host-image <registry>/burrow-agent-host:<tag>`, or a re-render after migrating. | No install's setup script names the old ref. |
| OIDC client id `suite-core` | `burrow_install/registry.py` (core's `OIDC_CLIENT_ID`), `burrow_install/setup/pocketid.py` (`CLIENT_ID`), the pocket-id client on each install | The client is registered under this id in each install's pocket-id. Renaming it in the render breaks sign-in until the client is re-registered. | A step that registers a new client id and switches core to it in one restart. | That step ships and has run on every install. |
| Cloudflare tunnel name `suite-<install.name>` | `burrow_install/setup/cloudflare.py` (tunnel name), the remotely managed tunnel on each Mac install with a tunnel | The tunnel step finds its tunnel by this name. A new name would make it create a second tunnel and repoint the DNS records, which leaves the old one orphaned. | A step that renames the tunnel in place through the Cloudflare API, keeping its id. | That step ships and has run on every tunnelled install. |
| LiveKit API key `suite` | `burrow_install/registry.py` (`LIVEKIT_API_KEY`) | LiveKit and core must agree on the key name, and it is part of each install's `LIVEKIT_KEYS` secret. | Re-render with a new key name and restart LiveKit and core together. | Any release that does that restart; nothing outside the install reads the name. |
| legacy LaunchAgent labels `org.startupsuite.install.<name>.<job>` | `burrow_install/setup/macos.py` (`LEGACY_LABEL_ROOT`), used by teardown, the job steps and `setup run migrate` | Pre-rename Macs run their jobs under these labels. Without the bootout, a job would run twice. | `setup run migrate`, or re-running the job's step. | No supported Mac install predates the rename. |
| `~/suite/<name>` discovery and `~/SuiteBackups` | `burrow_install/setup/state.py` (`legacy_root`), `burrow_install/setup/migrate.py` | A Mac that has not migrated keeps working: discovery reads the old root and never writes it. Old backups stay where they were taken. | `setup run migrate`. | Discovery: no supported Mac install predates the rename. Backups: the owner deletes `~/SuiteBackups` once the backups there are no longer needed. |
| suite-cli-owned names: tmux session `suite-agent`, `~/.config/suite/agents/`, `~/.local/state/suite/sessions/`, the `suite` command | `services/agent-host/src/ids.ts` (`SESSION`, `statusFile`), `src/agents.ts`, `src/runner.ts`, the `burrow-agent@.service` template | suite-cli owns these names. The agent host runs the CLI it pins (`BURROW_CLI_REF` in versions.env) and has to use that CLI's names. | Core pins a 0.9 CLI (suite-cli task 01a14cc3) and the agent host switches to its names, reading the old paths as a fallback. | That CLI is pinned on every install's agent host. |
