import { defineConfig, devices } from "@playwright/test"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"

const IPHONE_ONLY = /prototype_fullscreen_touch\.spec\.ts/
// Task 01a1389f v2: the drag spec runs under the touch/device projects below
// and its own desktop Chromium project, never under `chromium`, so that
// project's test list is unchanged.
const DRAG_ONLY = /prototype_fullscreen_drag\.spec\.ts/
// Task 01a18834 stage 3: scripted embed versions, history previews and the
// iPhone fullscreen case. WebKit only; the spec makes every context itself
// with an explicit viewport (390x844 touch, or 1280x800).
const EMBED_HISTORY = /scripted_embed_history\.spec\.ts/
// iPadOS Safari's default desktop-class UA: it claims a Mac. The spec adds
// navigator.maxTouchPoints = 5, which is what tells an iPad apart.
const IPADOS_SAFARI_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

export default defineConfig({
  testDir: "./tests",
  timeout: 180_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  // One auto-retry absorbs flakes caused by LiveKit rooms and LV sessions
  // not having fully GC'd between consecutive runs. A persistent failure
  // still reports red.
  retries: 1,
  reporter: [["list"]],
  use: {
    baseURL: BASE_URL,
    trace: "retain-on-failure",
    video: "retain-on-failure",
    launchOptions: {
      args: [
        // Emit synthetic media instead of touching real devices.
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream",
        // Mute the noisy default audio output so tests don't whistle.
        "--autoplay-policy=no-user-gesture-required",
      ],
    },
    permissions: ["microphone", "camera"],
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      // The iPhone touch spec is WebKit-only (task 01a1389f); every other
      // spec keeps running here exactly as before.
      testIgnore: [IPHONE_ONLY, DRAG_ONLY, EMBED_HISTORY],
    },
    {
      // Task 01a1389f: the prototype fullscreen overlay under a held press on
      // an iPhone. WebKit with the iPhone descriptor (hasTouch, isMobile,
      // defaultBrowserType webkit). Scoped by testMatch so no Chromium-only
      // spec ever runs under WebKit. The top-level Chromium media flags and
      // mic/camera grants are reset here: WebKit refuses to launch with them.
      // No retry: the probes are deterministic geometry, a retry only repeats.
      name: "webkit-iphone",
      testMatch: [IPHONE_ONLY, DRAG_ONLY, EMBED_HISTORY],
      retries: 0,
      use: {
        ...devices["iPhone 15"],
        launchOptions: { args: [] },
        permissions: [],
      },
    },
    {
      // Task 01a1389f v2: an iPad, as Burrow iOS or the installed PWA sees
      // it (the spec injects the marker / standalone per case). Drag spec only.
      name: "webkit-ipad",
      testMatch: DRAG_ONLY,
      retries: 0,
      use: {
        ...devices["iPad Pro 11"],
        userAgent: IPADOS_SAFARI_UA,
        launchOptions: { args: [] },
        permissions: [],
      },
    },
    {
      // Task 01a1389f v2: Android Chrome and Burrow Android, native path.
      name: "chromium-android",
      testMatch: DRAG_ONLY,
      retries: 0,
      use: { ...devices["Pixel 7"] },
    },
    {
      // Task 01a1389f v2: desktop Chromium's native path under the drag spec,
      // kept out of `chromium` so that project's test list does not change.
      name: "chromium-desktop",
      testMatch: DRAG_ONLY,
      retries: 0,
      use: { ...devices["Desktop Chrome"] },
    },
  ],
})
