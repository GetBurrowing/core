# core E2E tests

Playwright tests that exercise flows no unit or integration test can — browser
permissions, WebRTC transport, JS-owned DOM subtrees.

## Prereqs

- A running dev server: `cd apps/platform && mix phx.server` (port 4000).
- Dev server must have `MIX_ENV=dev` so `/dev/login` is registered.
- LiveKit creds in the dev server env (`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`).

## Install

```bash
cd e2e
npm install
npm run install-browsers   # one-time: fetches full Chromium
```

The meeting A/V test requires the **full** Chromium build, not the
default `chromium-headless-shell`. `install-browsers` fetches both — the
spec explicitly opts into `channel: "chromium"` so canvas.captureStream
and AudioContext actually emit frames.

## Run

```bash
npm test                   # all tests, headless
npm run test:meeting       # just the meeting A/V test
npm run test:headed        # see the two browser windows
```

## Meeting A/V test

`tests/meeting_av.spec.ts` launches two browser contexts (Alice, Bob), logs each
in through `/dev/login?as=<slug>`, joins the same "general" meeting, enables
camera + mic, and asserts that **each side receives the other's video and audio**
tracks via LiveKit.

This is the test to reach for when someone reports "I joined but the other
person said they couldn't see/hear me" — it pins down whether the break is in
transport (this test fails) or in perception/UX (this test passes).

Chromium is launched with `--use-fake-device-for-media-stream` so the tests
don't touch the host camera/mic; synthetic tracks carry a spinning color wheel
(video) and a tone (audio).

## Tips

- Set `BASE_URL=http://dev-host:4000` to run against a different host.
- Failure traces land in `test-results/`; open the `.zip` with
  `npx playwright show-trace <path>` for step-by-step DOM + network replay.
