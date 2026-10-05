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
| `ios/App/ExtensionRenderTests` | Renders the share sheet and widgets to PNGs (the Render scheme, `TEST_RUNNER_SUITE_RENDER_DIR=<dir>`), not an assertion suite |
| `scripts/generate_assets.py` | Regenerates colour sets, placeholder icon and launch mark |
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
Source tokens: `apps/platform/assets/css/app.css` on `origin/main`, read
2026-10-04. `scripts/generate_assets.py` holds the sRGB values.

| Slot | Web token | Light | Dark |
| --- | --- | --- | --- |
| `primary` | `primary` | oklch(82% 0.12 207) = #4EDAEB | #06D5ED |
| `onPrimary` | `primary-content` | black | black |
| `accent` | `accent` | #06D5ED | #06D5ED |
| `surface` | `base-100` | #FFFFFF | #171b25 |
| `surfaceMuted` | `base-200` | #F2F2F2 | #000306 |
| `onSurface` | `base-content` | black | #EEEEEE |
| `muted` | neutral secondary text | oklch(45% 0.01 0) = #5A5355 (7.49:1 on #FFFFFF) | #958D8F, measured 5.32:1 on #171b25 (at least 4.5:1 required) |
| `border` | `edge` | oklch(88% 0 0) = #D7D7D7 | #232A38 |
| `destructive` | `error` | oklch(63% 0.22 25) = #F1383E | #F1383E |

Note: on `origin/main` the light theme's `--color-primary` is the literal
#06D5ED, not oklch(82% 0.12 207). The light `primary` slot follows the stage
specification (oklch(82% 0.12 207)); align it if the web token is meant to win.
Contrast ratios are WCAG 2.x relative luminance, computed from the sRGB values.

The launch screen is the `surface` colour with the placeholder mark tinted
`onSurface` (no cyan). The icon is a placeholder (canvas Q1): primary field, black "Suite"
wordmark. Type is Public Sans (OFL, bundled), scaled with Dynamic Type via
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

Categories: `SUITE_MENTION` (text-input Reply + Open) and `SUITE_OPEN` (Open).
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
`POST /api/app/spaces/:id/messages` multipart, body written to a temp file
and uploaded from it. **Cap: 8_000_000 bytes for the whole body** (Plug's
default multipart length; the server does not raise it, so chat's 15 MB does
not apply). Past it the sheet says so before sending. HEIC photos are
re-encoded as JPEG. States and copy follow canvas 01a10887.

## Widgets

`GET /api/app/counts`, 15-minute timeline, plus the app refreshing the App
Group counts and calling `WidgetCenter.shared.reloadAllTimelines()` on every
foreground. `slabState(count:fetchedAt:now:signedIn:)`: primary fill ONLY for
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
