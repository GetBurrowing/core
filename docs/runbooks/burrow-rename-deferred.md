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
| real install hostnames | Android sources and tests | Owned by A3 (01a14b9e) and A3b (01a14dce). A3 replaced them with placeholders, except for the former default hosts in `InstallStoreTest.kt`, which it kept on purpose as the preimages of its shipped digest list. `ProductNameGuardTest` skips those lines through its A3-owned hash list. This stage renames only `suite`-shaped placeholders. | A3b's digest seam lands, then the guard's A3 skip is removed. |

### Android names kept by stage 4

Stage 4 applied one token map to every tracked file under `clients/android`, except the two files listed below (`push_seal_v1.json` and `InstallStoreTest.kt`): `SuiteNativePlugin` -> `BurrowNativePlugin` (class and file), the iOS type mentions `SuiteAPIClient` / `SuiteBridgeViewController` / `SuiteWidgets` -> `Burrow*`, `suite-a.localhost` / `suite-b.localhost` -> `burrow-a.localhost` / `burrow-b.localhost`, `suite.example.{com,net,org,test}` -> `burrow.example.*` (with the upper- and mixed-case forms that the host-normalisation tests use), and `This Suite` -> `This Burrow`. **Stage 5 must use the same Burrow names for the iOS types**, because the Android comments and README already point at them. After the map, `ProductNameGuardTest` scans `clients/android/**/*.{kt,xml,gradle,kts}`.

| name | where | why it stays | removal condition |
|---|---|---|---|
| `"install_host": "suite-b.localhost"` | `clients/android/android/app/src/test/resources/push_seal_v1.json` | The fixture is sealed: the host is the HPKE AAD. Its copies in core (`apps/platform/test/support/fixtures/`) and iOS must stay byte-identical (`seal_fixture_parity_test.exs`), and the core push tests also use the `suite-a`/`suite-b` hosts. Resealing it means changing all three copies together. | A core-and-iOS change reseals all three copies with a `burrow-b.localhost` host (the way A3's c12a1cc9b did) and renames the core push test hosts. |
| `"suite.example.com"` (3 lines) | `clients/android/android/app/src/test/java/com/koboai/burrow/InstallStoreTest.kt` | `InstallIdentityGuardTest` pins the whole file by sha256 in its `@deferred` list for A3b, so any edit here is a stale pin. Allowlisted in `ProductNameGuardTest`. | A3b rewrites the file, and its new content takes the `burrow.example.com` placeholder. |
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
| UserDefaults keys `suite.installs.v1`, `suite.installs.selected.v1`, `suite.installs.confirmed.v1`, `suite.installs.defaults_checked.v1`, `suite.app_install_id.v1` | `clients/ios/ios/Shared/InstallStore.swift` | Persisted on users' devices. Renaming any of them silently drops the installs list, the selected install and the app install id on upgrade, and so the person's sign-ins. No iOS test can run here to prove a migration. The guard allowlists each by its exact code form, so renaming the constant fails the guard. | Migrate in a release with a device-tested migration that reads the old key, writes the new one, and is covered by AppTests. |
| UserDefaults keys and prefixes `suite.recent_calls.v1`, `suite.counts.v1.`, `suite.unread.v1.`, `suite.widget.arm.v1`, `suite.widget.rows.v1`, `suite.approvals.v1.`, `suite.shortcuts.digest.v1.`, `suite.shortcuts.dirty.v1`, `suite.shortcuts.refreshed-at.v1`, `suite.share.last_space.v1.`, `suite.intents.last-meeting-space.v1.` | `RecentCalls.swift`, `CountsCache.swift`, `InstallUnreadStore.swift`, `ApprovalsWidgetModel.swift`, `ShortcutParameterRefresh.swift` (and its test's `hasPrefix`), `ShareSheetModel.swift`, `IntentSupport.swift` | Same as above: persisted state (recent calls, cached counts and unread, widget state, Shortcuts digests, the last share space, the last meeting space). | Same as above. |
| `UserDefaults(suiteName:)` and the `suiteName` variables passed to it | iOS sources and tests | Apple's API parameter name, not the brand. | None. |
| Capacitor `jsName = "SuiteNative"` / `"SuiteMeetings"` and the backticked mentions of them in comments | `BurrowNativePlugin.swift`, `BurrowMeetingsPlugin.swift` and the comments listed in `ProductNameGuardTest` | The JS-facing wire names (see "Capacitor plugin wire names" above). The plugin `identifier` and `@objc` name were renamed: Capacitor's bridge keys a registered instance by `jsName` (`registerPluginInstance`: `plugins[pluginInstance.jsName]`), so neither is on the wire. | As above: flip once every install runs core JS with the stage 4 fallback. |
| `SUITE_*` push category ids (`SUITE_MENTION`, `SUITE_OPEN`, `SUITE_RING_WAITING`, `SUITE_REPLY`, `SUITE_OPEN_ACTION`), and `SUITE_MESSAGE` in one test | `BurrowNativePlugin.swift`, `PushContentPreparer.swift`, tests | A1b's dual registration: older cores and devices still send them. | A1b's removal gate. |
| env fallbacks `SUITE_RENDER_DIR` / `TEST_RUNNER_SUITE_RENDER_DIR` (beside `BURROW_RENDER_DIR` / `TEST_RUNNER_BURROW_RENDER_DIR`) and `SUITE_MEETING_PROBE_URL`, `SUITE_MEETING_PROBE_TOKEN`, `SUITE_MEETING_PROBE_ROOM`, `SUITE_MEETING_PROBE_NAME`, `SUITE_MEETING_PROBE_CALLKIT` (beside `BURROW_MEETING_PROBE_URL`, `BURROW_MEETING_PROBE_TOKEN`, `BURROW_MEETING_PROBE_ROOM`, `BURROW_MEETING_PROBE_NAME`, `BURROW_MEETING_PROBE_CALLKIT`) | `ExtensionRenderTests.swift`, `BurrowBridgeViewController.swift` | Already deprecated fallbacks beside the `BURROW_*` names. Each logs a deprecation line when used. | When no rig script sets the old names. |
| `"install_host": "suite-b.localhost"` and the two `SUITE-B` expectations derived from it | `AppTests/Fixtures/push_seal_v1.json`, `AppTests/PushRelayTests.swift` (two lines) | The fixture is sealed (the host is the HPKE AAD) and byte-identical to its core and Android copies (`seal_fixture_parity_test.exs`). The expected labels are derived from its host. One other assertion now derives the host prefix from the fixture (`f.host`) instead of spelling it. | Reseal all three copies together with a `burrow-b.localhost` host (see the Android row above), then rename these two lines. |
| `InstallStoreTests.swift`, whole file (its `suite.example.com`, `Suite.Example.com`, `name: "Suite"` and `suite.installs.*` literals) | `clients/ios/ios/App/AppTests/InstallStoreTests.swift` | `InstallIdentityGuardTest` pins the file by sha256 for A3b, so any edit is a stale pin. Allowlisted in `ProductNameGuardTest`. | A3b rewrites the file. |
| Capacitor `ios.scheme: "Suite"` | `clients/ios/capacitor.config.ts` | A Capacitor CLI setting (the Xcode scheme `npx cap run` uses), not shipped code. The project's schemes are `App`, `Evidence`, `Render` and `IntentsSystem`, so it already names no scheme; changing it changes nothing verifiable here. | The next change that runs `npx cap run ios` on a Mac sets it to `App` and checks it. |
| `~/.config/suite-ios-build/`, `~/Dev/build/suite-ios/`, `Suite-<n>.xcarchive`, TestFlight group "Suite internal", App Store Connect app name in an error message | `clients/ios/scripts/testflight.sh`, `scripts/set_testflight_notes.py`, README release section | Paths on the release build host and names of App Store Connect objects, outside this repo. Renaming them here would break the release scripts. | Rename on the build host and in App Store Connect first, then here. |
| npm package `suite-ios` and its description | `clients/ios/package.json`, `package-lock.json` | Not product copy; the package is never published. | Any later cleanup; renaming it regenerates the lockfile. |
| "the Suite iPhone app" and "match Suite" | `clients/ios/WHATSNEW.md` | Release notes of an already-shipped build (history). | None. |
| "Suite iOS colour assets", "Suite web tokens" | `clients/ios/scripts/generate_assets.py` docstring | Out of the guard's scope and of this stage's file set (a build-host script). | Any later cleanup. |
| the published bundle ids, README history of the old bundle id and URL scheme, real install hostnames | project files, README | Excluded by the plan: published store ids (A3's `@published_ids`), history, and A3/A3b's hosts. | None planned / A3b. |
