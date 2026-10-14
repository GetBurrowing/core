import { defineConfig, devices } from "@playwright/test"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"

const IPHONE_ONLY = /prototype_fullscreen_touch\.spec\.ts/

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
      testIgnore: IPHONE_ONLY,
    },
    {
      // Task 01a1389f: the prototype fullscreen overlay under a held press on
      // an iPhone. WebKit with the iPhone descriptor (hasTouch, isMobile,
      // defaultBrowserType webkit). Scoped by testMatch so no Chromium-only
      // spec ever runs under WebKit. The top-level Chromium media flags and
      // mic/camera grants are reset here: WebKit refuses to launch with them.
      // No retry: the probes are deterministic geometry, a retry only repeats.
      name: "webkit-iphone",
      testMatch: IPHONE_ONLY,
      retries: 0,
      use: {
        ...devices["iPhone 15"],
        launchOptions: { args: [] },
        permissions: [],
      },
    },
  ],
})
