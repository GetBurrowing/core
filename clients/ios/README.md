# Burrow: the iOS app (Capacitor shell)

Burrow (listed under its publisher's name in App Store Connect) is a native shell around the
Burrow web UI (task 01a10882). The web UI runs in a
WKWebView pointed at the install the person picked; native code exists only
where the web cannot reach: sign-in, push, the install picker and the Home
Screen quick action.

**Out of scope for v1:** native meetings (LiveKit Swift SDK, CallKit, PushKit
VoIP, PushToTalk), native game streaming, Apple Watch, Siri / App Intents.

**The seam:** every native capability the web UI calls goes through ONE
Capacitor plugin, `SuiteNative` (`ios/App/App/Plugins/BurrowNativePlugin.swift`,
JS name `SuiteNative`). A v2 meetings plugin registers beside it in
`BurrowBridgeViewController.capacitorDidLoad`; it does not grow this one.

## Layout

| Path | What |
| --- | --- |
| `package.json`, `capacitor.config.ts` | Capacitor 8 (`com.kobo-ai.burrow`, `Burrow`, `webDir: www`, no `server.url`) |
| `www/index.html` | Bundled boot page; the shell replaces it with the selected install |
| `ios/App/project.yml` | xcodegen spec. The `.xcodeproj` is generated from it; commit both |
| `ios/App/CapApp-SPM` | Capacitor's SPM glue (managed by `cap sync`) |
| `ios/App/App/BurrowBridgeViewController.swift` | Edge-to-edge web view, navigation policy, pull-to-refresh, status bar |
| `ios/Shared/` | Compiled into the app AND both extensions: `InstallStore` (installs + selection in App Group `group.com.kobo-ai.burrow`), `KeychainTokenStore`, `BurrowAPIClient`, `SlabState`, the share sheet model, colour slots (`Colors.xcassets`) |
| `ios/ShareExtension/` | Share to Burrow (`com.kobo-ai.burrow.share`), see Share sheet below |
| `ios/BurrowWidgets/` | My approvals / My tasks widgets (`com.kobo-ai.burrow.widgets`, iOS 17+), see Widgets below |
| `ios/App/App/InstallPickerView.swift` | SwiftUI picker (canvas 01a10887) |
| `ios/App/App/AuthSession.swift` | PKCE S256 + ASWebAuthenticationSession + `POST /api/app/session` |
| `ios/Shared/KeychainTokenStore.swift` | Bearer per install host, Keychain only, access group `$(AppIdentifierPrefix)com.kobo-ai.burrow.shared` |
| `ios/App/App/NavigationPolicy.swift` | Install host stays in view, every other host opens in Safari |
| `ios/App/AppTests` | XCTest unit tests (the App scheme) |
| `ios/App/EvidenceUITests` | Screenshot driver (the Evidence scheme), not an assertion suite |
| `ios/App/ExtensionRenderTests` | Renders the share sheet and widgets to PNGs (the Render scheme, `TEST_RUNNER_BURROW_RENDER_DIR=<dir>`; the legacy `TEST_RUNNER_SUITE_RENDER_DIR` still works), not an assertion suite |
| `scripts/generate_assets.py` | Regenerates colour sets and the launch mark (from the committed icons) |
| `scripts/testflight.sh`, `scripts/set_testflight_notes.py`, `ExportOptions.plist`, `WHATSNEW.md` | TestFlight build, see TestFlight below |

## Build and test (mac-host only)

```bash
cd clients/ios
npm ci
npx cap sync ios              # copies www into ios/App/App/public (gitignored)
security unlock-keychain -p "$(cat ~/.config/cloudplay-tv-build/passphrase)" ~/Library/Keychains/login.keychain-db
xcodebuild test -project ios/App/App.xcodeproj -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ~/Dev/build/suite-ios/DerivedData
```

macOS has no `timeout(1)`; wrap long runs with a perl `alarm` wrapper or run
them in the background. Never run `xcodebuild -runFirstLaunch`. No CocoaPods.

After adding or moving a Swift file: `cd ios/App && xcodegen generate`.

The app is universal (iPhone and iPad, iOS 17+). Run the App scheme on both
`name=iPhone 17` and `name=iPad Pro 13-inch (M5)`. Lint a Swift file you
create or edit with `xcrun swift-format lint --strict <file>` from
`clients/ios` (config: `.swift-format`, 4-space indent, 160 columns); do not
reformat files you did not touch.

## Native tab bar

The app's bottom tabs (Chat, Voice, Tasks, Meetings, More) are the system's
own `UITabBar` over the web view, so iOS 26+ draws real Liquid Glass (task
01a1557b; design direction canvas 01a1724a). Code: `ios/App/App/NativeTabBar.swift`.
The web drives it through `SuiteNative.tabBarState`, and taps come back as the
window event `burrowNativeTab`.

**Contract (stage 2).**

- Web to native: `SuiteNative.tabBarState({items, selected, more_dot, visible})`.
  `items` is the list of tab keys in the web bar's order. Native holds only
  a key to {label, SF Symbol pair} map for `chat`, `voice`, `tasks`,
  `meetings` and `more`. It draws exactly the keys sent, in order, drops
  unknown or repeated keys, and keeps the first five (logging the cut), so
  iOS never adds its own More. A missing or empty `items`, or one with no
  known key, keeps the previous items. Native never invents a tab: with no
  items yet, the bar stays hidden. `selected` is a key or `null`; `more_dot`
  shows the system red dot (badge `""`) on More; `visible` slides the bar
  out and back. A missing or wrong-typed field leaves that field as it was.
  The method's existence is the web's feature test; old builds keep the web bar.
- Native to web: window event `burrowNativeTab`, `detail: {key, reselect}`.
  `reselect` is true when the tapped key is the selected one. A tap never
  moves the selection; the web's next state does.
- Document start: a main-frame `WKUserScript` per install host sets
  `<html data-native-tab-bar>` and `--native-tab-bar-height` (the bar's
  height above the bottom safe area, 49px on an iPhone 18 Pro on iOS 27:
  the glass platter is 62pt but floats down into the safe area). The shell
  updates the variable on layout and rotation. The same script pings native
  (`burrowNativeDocument`) on every new document; a document that sends no
  state within 2.5s of didFinish hides the bar.
- Minimise on scroll is not wired: a standalone `UITabBar` has no
  minimise behaviour (that API is on `UITabBarController`).

**Web side (stage 3).** `apps/platform/assets/js/hooks/native_tab_bar.js`
(the `NativeTabBar` hook) mounts on `#native-tab-bridge`, a hidden span in
the web bar (`IconRail.bottom_rail/1`). The items are
`IconRail.mobile_tab_keys/0 ++ [:more]` (`chat,voice,tasks,meetings,more`),
sent from the span's `data-items`; `data-active-key` and
`data-more-unread` give `selected` and `more_dot`. A tap clicks the
matching `#bottom-nav [data-destination]` element, so it reuses the web
bar's links and the More button. A reselect scrolls the page to the top,
or at the top goes to the tab's root; More always toggles its sheet.
In the app, `app.css` hides the web bar under `:root[data-native-tab-bar]`
and pads the page with `--native-tab-bar-height`.

- Hide predicate: `visible` is false wherever the web bar itself would be
  hidden (a focused `ComposeInput`, a full-screen viewer, the in-call room),
  at `(min-width: 1024px)` (Tailwind `lg`, where the web shows its desktop
  rail instead: a 13-inch iPad in portrait, any iPad in landscape), and
  while a sheet other than More is open (a native bar cannot be covered).
  Leaving the page sends `visible: false` after a 300ms grace that a new
  mount cancels, so switching tabs never blinks the bar.
- Old builds: the hook is active only when `Capacitor.isNativePlatform()`,
  the plugin has `tabBarState`, and `<html data-native-tab-bar>` is set.
  A browser, a PWA and an app build from before the native bar fail that
  test, so the hook does nothing and the web bar shows as before.
- Contract tests, one per side, so a rename on either side fails CI:
  `ios/App/AppTests/NativeTabBarContractTests.swift` reads the hook,
  `app.css` and `icon_rail.ex` from the checkout;
  `apps/platform/assets/test/hooks/native_tab_bar_contract.test.js` reads
  `NativeTabBar.swift`, `BurrowBridgeViewController.swift` and
  `Plugins/BurrowNativePlugin.swift`. The hook's behaviour is in
  `apps/platform/assets/test/hooks/native_tab_bar.test.js`.

**Fixture (Debug only).** `-BurrowTabBarFixture YES` loads the bundled
`www/tabbar-fixture.html` in place of an install: a fake web side whose
buttons send `tabBarState` and which lists every `burrowNativeTab` it gets.
`-BurrowTabBarFixtureAppearance light|dark` pins the appearance. Release
builds compile the seam out (the page itself is still bundled but nothing
loads it). `TabBarUITests` (App scheme) drives it and writes PNGs to
`TEST_RUNNER_EVIDENCE_DIR`.

**Hosting: measured 2026-10-25, stage 1 spike.** The spike ran on the CI
simulator, an iPhone 18 Pro on iOS 27.0 (Xcode 27.1), in light and dark. It
compared a standalone `UITabBar` pinned to the bottom of the web view with a
`UITabBarController` child (five empty clear pages in a touch-passthrough
container). Both drew the same floating glass platter with nothing set:
`_UITabBarItemPlatterView` 360x62 inset 21pt from each side, with a
`_UILiquidLensView` under the selected tab. The standalone bar was kept
because:

- it stays a bottom bar at every width. On the image's iOS 27.1 foldable
  (iPhone Duo, regular width) the controller became a trailing sidebar;
- it can show no selection (`selected: null`), while the controller always
  holds one;
- it needs no child view controller, dummy pages or hit-test passthrough
  over the web view.

Neither hosting minimised on scroll. iOS can only minimise a bar that
tracks a scroll view, and neither tracks the web view's. The behaviour is
left at the system default and not asserted. On iOS 17 to 25,
`NativeTabBarMaterial` gives both bar appearances the system default
background (a bar with no tracked scroll view would otherwise use its
transparent scroll-edge look). That is still the stock material.
`NativeTabBarTests` covers both branches. No pre-26 runtime has been
screenshotted.

**Inks and contrast: measured 2026-10-27, task 01a174e8 stage 3.** The
web resolves the two tab inks from the token layer in `app.css`
(`--native-tab-selected`, `--native-tab-unselected`) and sends them as
`#rrggbbaa`; native paints them as `tintColor` and
`unselectedItemTintColor` and never holds a colour of its own. The first
measurement sent the web bar's own inks (`--color-primary`, and `--tab-ink`
= base-content at 55%). The light selected label measured 4.22:1 on its lens
over white, and the unselected ink failed over the opposite backdrop. Under
the design direction's substitution rules the token layer then moved light
selected to `--color-interactive` (dark keeps `--color-primary`) and
unselected to opaque `--color-base-content`. The web bar itself is
unchanged.

`TabBarUITests.testContrastOverBackdrops` loads the fixture with
`?backdrop=white` or `?backdrop=black` (a flat page behind the bar). It
selects each tab with the More dot on, takes XCUIScreen shots, and for each
item frame (`native-tab-<key>`) separates the ink pixels from the glass. It
then composites the sent ink over every glass pixel around the label and
the glyph, and asserts the 5th-percentile WCAG 2.x ratio: label >= 4.5,
glyph >= 3. Everything goes to `contrast.json` in the artifact's `shots/`.
iOS 26 glass draws its own vibrant ink for unselected items when the tint
has alpha. Those cells are then measured with the ink the system drew; with
the opaque base-content ink, drawn and sent agree. Results on the CI iPhone
(iOS 27), after the substitution (run 40434027232; the iPad leg agrees to
within 0.2):

- light over white: selected 5.89 label / 6.17 glyph, unselected 18.3 / 19.4. Passes.
- dark over black: selected 6.73 / 6.90, unselected 12.0 / 13.3. Passes.
- light over black: selected 1.25 / 1.23. FAILS. Unselected 5.10 / 5.39.
- dark over white: selected 1.16 / 1.16, unselected 1.67 / 1.71. FAILS.

The failing cells are glass, not ink. Over the opposite extreme the glass
shifts toward the backdrop: light glass over black reads #636363 under the
lens and #858585 elsewhere, and dark glass over white reads #8f8f8f and
#b9b9b9. Meanwhile the bar's
inks stay pinned to the web's scheme (`overrideUserInterfaceStyle`). No
orange reaches 4.5:1 on that mid grey, so these cells are open, and the
thresholds were not lowered.

Reduce Transparency is measured, not computed: the test switches it on in
Settings, and the fill reads the same over both backdrops (#ffffff and
#fafafa light, #141414 dark). All four combinations pass. Light: selected
6.20 / 6.58 over white and 6.12 / 6.17 over black, unselected 17.8 or
better. Dark: selected 6.41 / 6.41 over white and 7.29 / 7.35 over black,
unselected 14.0 or better. `contrast.json` also keeps the values
computed against `UITabBarAppearance`'s opaque fill (light 7.71 selected,
21 unselected; dark 7.51 and 18.3) for comparison.

At the largest text size (`-UIPreferredContentSizeCategoryName
UICTContentSizeCategoryAccessibilityXXXL`, the category's raw value), the
labels draw in Public Sans 13 (the cap) and the probe's `truncated=none`
holds for all five. A device check of the bar in light and dark follows on
TestFlight.

**CI.** `.github/workflows/ios.yml` runs on GitHub's `xcode-27` macOS image
for pushes to `main` and `task/**` that touch `clients/ios/**`. It runs
`npm ci`, `npx cap sync ios` and `xcodegen generate`, then runs `xcodebuild
test -scheme App` (AppTests + TabBarUITests) twice, as a matrix: on an iPhone
Pro and on a 13-inch iPad Pro simulator, each created on the newest iOS
runtime that has one. On the iPad, `testViewportAgainstTheDesktopBreakpoint`
asserts the web view is at least 1024px wide, so the web's desktop rail
shows and the hook keeps the native bar hidden. The xcresult, the summaries, the
PNGs and the generated `project.pbxproj` are uploaded as the run's artifact.
It is unsigned (`CODE_SIGNING_ALLOWED=NO`, placeholder
`AppIdentifierPrefix`), so these tests need a real Keychain access group or
the team prefix and are skipped there. Run them on the mac host:

- `KeychainTokenStoreTests`: `testAccessGroupIsTheTeamPrefixedSharedGroup`,
  `testOneSessionPerHost`, `testStoringATokenWritesNothingToTheAppGroupDefaults`
- `InstallSessionTests`: `testHandoffOnAnotherHostIsRefused`,
  `testRevokedBearerFallsBackToSignInAndIsRemoved`,
  `testSignOutDeletesTheDeviceThenTheSessionAndForgetsTheBearer`,
  `testSignOutForgetsTheBearerEvenWhenTheServerFails`,
  `testStoredBearerLoadsTheHandoffWithoutTheAuthSession`
- `PushRelayTests`: `testNativeSignOutForgetsThePushKey`,
  `testOneKeyPerHostInTheSharedKeychainAndSignOutDeletesIt`

`project.yml` sets `settingPresets: none`, so CI's Homebrew xcodegen and the
mac host's preset-less one generate the same project.

## TestFlight (mac-host only)

```bash
clients/ios/scripts/testflight.sh                 # archive, upload, What to Test, group
clients/ios/scripts/testflight.sh --archive-only
```

Adapted from cloudplay's `apple-tv/scripts/` (archive, altool upload, notes).
The script unlocks the keychain, regenerates the xcodeproj, increments
`~/.config/suite-ios-build/buildnumber` (CFBundleVersion; the marketing
version stays at project.yml's `1.0`), archives to
`~/Dev/build/suite-ios/Suite-<n>.xcarchive`, and exports with
`ExportOptions.plist` (`app-store-connect`, destination `upload`, so the export
IS the upload). Archive and export authenticate with the ASC API key in
`~/.config/suite-ios-build/asc.env` (mode 600, names only:
`ASC_API_KEY_ID`, `ASC_API_ISSUER`; the key is
`~/private_keys/AuthKey_<id>.p8`). mac-host has no Apple Distribution certificate,
so distribution signing is cloud-managed and `-allowProvisioningUpdates`
registers the App, share and widgets bundle IDs with Push Notifications and App
Groups. That needs an Admin-role key and an in-effect Program License
Agreement.

`set_testflight_notes.py` then waits (up to 30 min) for the build to finish
processing, sets the en-US What to Test from `WHATSNEW.md`'s top `## v<version>`
section, and adds the build to the internal group `Burrow internal` (created if
missing). It needs `/usr/bin/python3` (pyjwt); Homebrew's python3 lacks it.
`--check <version>` validates WHATSNEW.md offline; the build runs it before
spending a build number.

**Measured 2026-10-05 on mac-host:** archive fails on every target with
`PLA Update available: You currently don't have access to this membership
resource. To resolve this issue, your team's Account Holder, the product owner,
must agree to the latest Program License Agreement.`, followed by
`Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the
App Groups capability` (and Push Notifications on App). The ASC API returns 403
`FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` on `/v1/apps` and
`/v1/bundleIds`. Nothing reached Apple; the counter was reset to 0.

## Colour slots

Named colour assets only (Any + Dark); no hex or RGB literal in Swift.
Values are the Burrow palette (project page `design/burrow-redesign.md`: dark
decided 2026-10-03, light step 2026-10-05), the same values Android uses.
`scripts/generate_assets.py` holds the sRGB values.

| Slot | Burrow token | Light | Dark |
| --- | --- | --- | --- |
| `primary` | orange (primary actions only) | #AD4B07 | #F47721 |
| `onPrimary` | label on a filled accent | #FBFAF9 | #202124 |
| `accent` | follows primary | #AD4B07 | #F47721 |
| `info` | info (teal-cyan): the live widget count ONLY | #0E7382 | #22D3EE |
| `onInfo` | label on info | #FBFAF9 | #202124 |
| `surface` | surface / base-100 | #FBFAF9 | #191B20 |
| `surfaceMuted` | ground / base-200 | #F6F4F1 | #111214 |
| `onSurface` | ink / base-content | #221F1B | #EEEFF1 |
| `muted` | muted text | #635B53 | #A9ABB2 |
| `border` | edge | #D9D3C9 | #383B42 |
| `destructive` | error, unchanged | #F1383E | #F1383E |
| tab bar selected ink (not an asset; sent by the web in `tabBarState.ink`) | `--native-tab-selected`: `--color-interactive` light, `--color-primary` dark | #8B3B04 | #F47721 |
| tab bar unselected ink (same) | `--native-tab-unselected`: `--color-base-content`, opaque | #000000 | #EEEFF1 |

Cyan still means live: the count slab and the approvals widget's header
count fill with `info` only when `slabState` is `.live`. Approve is the only
`primary` colour in a widget row. The web app's `app.css` on `origin/main`
is still cyan primary; the native slots follow the Burrow palette, as
Android's do.
Contrast ratios are WCAG 2.x relative luminance, computed from the sRGB values.

The icon is the Burrow arch: cream on an orange gradient (Any), orange on
charcoal (Dark), white on black (Tinted), committed as finished art. The launch
screen is the `surface` colour with the arch in its orange gradient, cut from
those icons by `generate_assets.py` (no cyan). Type is Public Sans (OFL, bundled), scaled with Dynamic Type via
`relativeTo:`. Appearance follows the system (canvas Q8).

## Login

**The web view does NOT sign in by itself.** pocket-id is passkey-first, and a
WKWebView inside a third-party app cannot complete WebAuthn for a relying party
the app has no associated domain for.

**Measured 2026-10-04** on mac-host, iPhone 17 simulator (iOS 26.3), Debug build
with `-BurrowLoginProbe burrow.example.com` (loads `/auth/login` with no
navigation policy), driven by `EvidenceUITests.test2LoginProbe`:

1. `/auth/login` redirected to pocket-id, and its "Sign in to Burrow" page
   rendered in the WKWebView ("Do you want to sign in to Burrow with your <install>
   account?", Sign in / Cancel / Sign in with login code).
2. Tapping **Sign in** produced no passkey sheet. Within 8 s pocket-id showed
   **"The operation was not allowed or timed out."** with a Try again button,
   which is WebAuthn's `NotAllowedError`. No system alert appeared.

Only the simulator was measured, not a device. The "Sign in with login code"
path was not tried.

So the shell signs in natively:

1. `ASWebAuthenticationSession` opens
   `https://<host>/auth/login?app_challenge=<S256>` with callback scheme
   `burrow` (Safari's cookie jar, where passkeys work);
2. the server redirects to `burrow://auth/callback?code=...`;
3. `POST /api/app/session` with `code`, `code_verifier`, `app_install_id`,
   `device_name` returns `{token, handoff_url}`;
4. the bearer goes to the Keychain (service `com.kobo-ai.burrow.session`,
   account = host, access group = the App Group) and the web view loads
   `handoff_url` as returned (`GET /auth/app/handoff?code=...`).

A main-frame load of the install's own `/auth/login` (the web app asking for a
sign-in) is cancelled by `NavigationPolicy` and runs the native flow instead.

Never logged anywhere: the APNs device token, the bearer, login codes, the
PKCE verifier.

## Push

`SuiteNative.enablePush()` asks for permission, registers with APNs and POSTs
`/api/app/devices` (`environment` = `sandbox` for Debug, `production` for
Release, matching the `aps-environment` entitlement). It resolves
`{registered: true}` ONLY when that POST succeeded; `push_subscribe.js` reports
granted only on that.

Categories: `SUITE_MENTION` / `BURROW_MENTION` (text-input Reply + Open),
`SUITE_OPEN` / `BURROW_OPEN` (Open) and `SUITE_RING_WAITING` /
`BURROW_RING_WAITING` (no actions; the in-call invite banner). Both sets are
registered; the app reports `push_category_scheme: "burrow"` when it registers
its device, and the server sends SUITE_* to any device that did not.
Reply posts `/api/app/spaces/:space_id/messages` with `reply_to`, using the
bearer for the payload's `install_host`, without foregrounding. Open and a tap
switch to `install_host` and load `url` (a URL on any other host falls back to
the install root).

Simulator push:

```bash
xcrun simctl push <device> com.kobo-ai.burrow payload.apns
```

## Install picker

No built-in installs: add yours by URL (a list made only of the old
built-in hosts is cleared once). Add probes `/health` and `/manifest.json`; swipe to remove.
Switch install is the long-press Home Screen quick action (canvas Q7).

## Shared Keychain

The bearer for each install lives in ONE Keychain item: service
`com.kobo-ai.burrow.session`, account = install host, access group
`$(AppIdentifierPrefix)com.kobo-ai.burrow.shared` (each target's
`keychain-access-groups` entitlement, passed to Swift through the
`BurrowKeychainAccessGroup` Info.plist key). Never UserDefaults, never the App
Group container, never logged. `BurrowAPIClient.authorizedRequest` is the only
place a bearer is attached, looked up by the host the request is built for;
a host with no token fails before any request exists.

## Share sheet

Activation: one image, one file, one web URL, or text. The sheet uses the
install selected in the app and its Keychain bearer, never web-view cookies.
Two paths, chosen from the server's `GET /api/app/upload_config`
(`max_upload_bytes`, `max_upload_label`, `chunk_bytes`,
`multipart_max_bytes`); the client holds no per-file limit of its own
(task 01a120be):

- **Multipart body at or under `multipart_max_bytes` (8_000_000):** today's
  `POST /api/app/spaces/:id/messages` multipart, body written to a temp file
  and uploaded from it. The threshold is the WHOLE request body (Plug's
  multipart `:length`), so routing measures the body, not just the file.
- **Larger, up to `max_upload_bytes` (1 GB by default, per install):**
  `POST /api/app/spaces/:id/uploads` reserves the file (the message text and
  agent ride along). While the sheet is still in the foreground,
  `BackgroundUploader` cuts the file into one slice file per `chunk_bytes`
  chunk in the App Group and queues an `uploadTask(with:fromFile:)` PATCH for
  EVERY chunk at once (`Upload-Offset = i * chunk_bytes`, exactly
  `min(chunk_bytes, total - offset)` bytes) on a background URLSession shared
  with the App Group; the server accepts aligned chunks out of order. Tasks
  created later by a suspended, relaunched app are rate-limited by iOS (the
  review saw gaps of 70 s doubling to 962 s, past the server's 900 s
  reservation TTL), so nothing waits on that. A slice is deleted on its 2xx;
  only a chunk whose task failed is re-created. After a relaunch the app
  rebuilds which chunks have live tasks from the session's task list, HEADs
  for the contiguous offset and queues only missing chunks at or past it.
  The server posts the message on the PATCH that completes coverage (200),
  and the device shows "Sent to #<space>"; if every chunk is acknowledged but
  that 200 was lost, a zero-length PATCH at `total` fetches it. A 404 or 410 (reservation
  expired) cancels the rest and shows "Couldn't send <file> to #<space>: the
  upload expired after the connection was lost too long. Share it again.";
  any other terminal failure also notifies.
- **Over `max_upload_bytes`:** refused before any byte moves, with the
  server's label: "<name> is 1.2 GB. This Burrow accepts files up to 1 GB."
  Sizes everywhere use one decimal rule (`ByteLabel`): 1 MB = 1_000_000 bytes.

Against a server without `upload_config`, only the multipart path exists and
its 8_000_000 cap applies. HEIC photos are re-encoded as JPEG. States and copy
follow canvases 01a10887 and 01a120be-f336.

## Widgets

`GET /api/app/counts`, 15-minute timeline, plus the app refreshing the App
Group counts and calling `WidgetCenter.shared.reloadAllTimelines()` on every
foreground. `slabState(count:fetchedAt:now:signedIn:)`: info fill ONLY for
`.live`; zero and stale (older than 30 minutes, measured on the device clock)
use `surfaceMuted`. Each timeline carries a second entry at the stale
boundary, so a widget that cannot refresh still loses its cyan on time. Deep
links `burrow://open?host=<host>&path=/inbox|/tasks` (allow-listed paths)
open in BurrowBridgeViewController. StaticConfiguration only, SF Pro Heavy
numeral, no bundled font in the widget.

## History: the Burrow rename

Before stage 6 (task 01a10882) the app shipped under an earlier
reverse-domain bundle ID (with `.share` and `.widgets` extensions), a matching
App Group and Keychain group, and URL scheme `suiteapp://`. All of them became `com.kobo-ai.burrow` / `burrow://`, on the
server too (AuthController's hard-coded app callback). Nothing migrates
Keychain items or App Group data from the old IDs: sign in again.
