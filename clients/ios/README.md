# Burrow: the Suite iOS app (Capacitor shell)

Burrow ("Burrow by Fabrikam" in App Store Connect) is a native shell around the
Suite web UI (task 01a10882). The web UI runs in a
WKWebView pointed at the install the person picked; native code exists only
where the web cannot reach: sign-in, push, the install picker and the Home
Screen quick action.

**Out of scope for v1:** native meetings (LiveKit Swift SDK, CallKit, PushKit
VoIP, PushToTalk), native game streaming, Apple Watch, Siri / App Intents.

**The seam:** every native capability the web UI calls goes through ONE
Capacitor plugin, `SuiteNative` (`ios/App/App/Plugins/SuiteNativePlugin.swift`,
JS name `SuiteNative`). A v2 meetings plugin registers beside it in
`SuiteBridgeViewController.capacitorDidLoad`; it does not grow this one.

## Layout

| Path | What |
| --- | --- |
| `package.json`, `capacitor.config.ts` | Capacitor 8 (`com.kobo-ai.burrow`, `Burrow`, `webDir: www`, no `server.url`) |
| `www/index.html` | Bundled boot page; the shell replaces it with the selected install |
| `ios/App/project.yml` | xcodegen spec. The `.xcodeproj` is generated from it; commit both |
| `ios/App/CapApp-SPM` | Capacitor's SPM glue (managed by `cap sync`) |
| `ios/App/App/SuiteBridgeViewController.swift` | Edge-to-edge web view, navigation policy, pull-to-refresh, status bar |
| `ios/Shared/` | Compiled into the app AND both extensions: `InstallStore` (installs + selection in App Group `group.com.kobo-ai.burrow`), `KeychainTokenStore`, `SuiteAPIClient`, `SlabState`, the share sheet model, colour slots (`Colors.xcassets`) |
| `ios/ShareExtension/` | Share to Burrow (`com.kobo-ai.burrow.share`), see Share sheet below |
| `ios/SuiteWidgets/` | My approvals / My tasks widgets (`com.kobo-ai.burrow.widgets`, iOS 17+), see Widgets below |
| `ios/App/App/InstallPickerView.swift` | SwiftUI picker (canvas 01a10887) |
| `ios/App/App/AuthSession.swift` | PKCE S256 + ASWebAuthenticationSession + `POST /api/app/session` |
| `ios/Shared/KeychainTokenStore.swift` | Bearer per install host, Keychain only, access group `$(AppIdentifierPrefix)com.kobo-ai.burrow.shared` |
| `ios/App/App/NavigationPolicy.swift` | Install host stays in view, every other host opens in Safari |
| `ios/App/AppTests` | XCTest unit tests (the App scheme) |
| `ios/App/EvidenceUITests` | Screenshot driver (the Evidence scheme), not an assertion suite |
| `ios/App/ExtensionRenderTests` | Renders the share sheet and widgets to PNGs (the Render scheme, `TEST_RUNNER_BURROW_RENDER_DIR=<dir>`; the legacy `TEST_RUNNER_SUITE_RENDER_DIR` still works), not an assertion suite |
| `scripts/generate_assets.py` | Regenerates colour sets and the launch mark (from the committed icons) |
| `scripts/testflight.sh`, `scripts/set_testflight_notes.py`, `ExportOptions.plist`, `WHATSNEW.md` | TestFlight build, see TestFlight below |

## Build and test (rock only)

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

## TestFlight (rock only)

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
`~/private_keys/AuthKey_<id>.p8`). rock has no Apple Distribution certificate,
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

**Measured 2026-10-05 on rock:** archive fails on every target with
`PLA Update available: You currently don't have access to this membership
resource. To resolve this issue, your team's Account Holder, Rowan Ellis,
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

**Measured 2026-10-04** on rock, iPhone 17 simulator (iOS 26.3), Debug build
with `-SuiteLoginProbe suite.example.com` (loads `/auth/login` with no
navigation policy), driven by `EvidenceUITests.test2LoginProbe`:

1. `/auth/login` redirected to pocket-id, and its "Sign in to Suite" page
   rendered in the WKWebView ("Do you want to sign in to Suite with your Fabrikam
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

Defaults: `suite.example.com` (selected), `suite.example.com`,
`suite.milv.life`. Add probes `/health` and `/manifest.json`; swipe to remove.
Switch install is the long-press Home Screen quick action (canvas Q7).

## Shared Keychain

The bearer for each install lives in ONE Keychain item: service
`com.kobo-ai.burrow.session`, account = install host, access group
`$(AppIdentifierPrefix)com.kobo-ai.burrow.shared` (each target's
`keychain-access-groups` entitlement, passed to Swift through the
`SuiteKeychainAccessGroup` Info.plist key). Never UserDefaults, never the App
Group container, never logged. `SuiteAPIClient.authorizedRequest` is the only
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
  server's label: "<name> is 1.2 GB. This Suite accepts files up to 1 GB."
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
open in SuiteBridgeViewController. StaticConfiguration only, SF Pro Heavy
numeral, no bundled font in the widget.

## History: the Burrow rename

Before stage 6 (task 01a10882) the app shipped under bundle ID
`technology.ellis.suite` (extensions `.share`, `.widgets`), App Group
`group.technology.ellis.suite`, Keychain group
`$(AppIdentifierPrefix)technology.ellis.suite.shared` and URL scheme
`suiteapp://`. All of them became `com.kobo-ai.burrow` / `burrow://`, on the
server too (AuthController's hard-coded app callback). Nothing migrates
Keychain items or App Group data from the old IDs: sign in again.
