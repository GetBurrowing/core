import { defineConfig, devices } from "@playwright/test"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"

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
    },
  ],
})
