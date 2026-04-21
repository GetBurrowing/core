/**
 * Meeting A/V transmission smoke test.
 *
 * Launches two separate browser processes (Alice, Bob), logs each in as a
 * distinct Dev user via `/dev/login?as=<slug>`, joins the same "general"
 * channel meeting, publishes synthetic audio + video tracks on each side,
 * then asserts that the OTHER side actually receives those tracks via
 * LiveKit and attaches them to the DOM.
 *
 * Why synthetic tracks instead of `setCameraEnabled(true)`: in headless
 * Chromium, `getUserMedia` with `--use-fake-device-for-media-stream` hangs
 * under load. A canvas (video) + AudioContext oscillator (audio) produce
 * real `MediaStreamTrack`s via native Web APIs and can be handed directly
 * to `LocalParticipant.publishTrack()` — deterministic, no host hardware.
 *
 * Why separate browser processes instead of contexts: a single Chromium
 * process serializes WebRTC init between contexts under fake-media flags,
 * which stalls the second peer's `room.connect`. Two processes model
 * real-world usage (two people on two machines) and avoid the quirk.
 *
 * This is the test to reach for when someone reports "I joined a meeting
 * but the other side couldn't see/hear me" — it pins down whether the
 * break is in transport (test fails) or perception/UX (test passes).
 */

import {
  test,
  expect,
  Browser,
  Page,
  BrowserContext,
  chromium,
} from "@playwright/test"

const SPACE = "general"

interface Peer {
  name: string
  slug: string
  context: BrowserContext
  page: Page
}

async function login(browser: Browser, slug: string): Promise<Peer> {
  const context = await browser.newContext()
  const page = await context.newPage()

  // Surface pageerror + warnings so any LiveKit transport failure lands
  // in the reporter instead of as a silent timeout.
  page.on("pageerror", (err) => console.log(`[${slug} pageerror] ${err.message}`))

  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 10_000 })
  await page.goto(`/chat/${SPACE}`)
  await expect(page.locator("#meeting-client")).toBeAttached()

  return {
    name: `Dev ${slug.charAt(0).toUpperCase()}${slug.slice(1)}`,
    slug,
    context,
    page,
  }
}

async function clickJoin(peer: Peer) {
  const joinBtn = peer.page.locator('[phx-click="meeting_join"]').first()
  await expect(joinBtn).toBeVisible({ timeout: 5000 })
  await joinBtn.click()

  // Wait for MeetingClient to finish `room.connect`. `_join` exposes the
  // connected room via window.__livekitRoom right after connection.
  await peer.page.waitForFunction(
    () => !!(window as any).__livekitRoom,
    null,
    { timeout: 60_000 },
  )
}

/**
 * Publish a canvas-backed video track + oscillator-backed audio track via
 * `room.localParticipant.publishTrack()`. Returns the local identity so
 * the other peer knows what to look for.
 */
async function publishSyntheticAV(peer: Peer): Promise<string> {
  // _join sets __livekitRoom immediately after room.connect, but then
  // `await setMicrophoneEnabled` on the next line can hang in headless.
  // Wait until the room reports a connected state before publishing.
  await peer.page.waitForFunction(
    () => {
      const r = (window as any).__livekitRoom
      return (
        r &&
        r.localParticipant &&
        r.localParticipant.identity &&
        r.state === "connected"
      )
    },
    null,
    { timeout: 15_000 },
  )

  return await peer.page.evaluate(async () => {
    const room = (window as any).__livekitRoom
    if (!room) throw new Error("no __livekitRoom")

    // synthetic video: animated canvas (color wheel + frame counter)
    const canvas = document.createElement("canvas")
    canvas.width = 320
    canvas.height = 240
    const ctx2d = canvas.getContext("2d")!
    let frame = 0
    const draw = () => {
      const hue = (frame * 3) % 360
      ctx2d.fillStyle = `hsl(${hue}, 70%, 50%)`
      ctx2d.fillRect(0, 0, canvas.width, canvas.height)
      ctx2d.fillStyle = "white"
      ctx2d.font = "32px monospace"
      ctx2d.fillText(`frame ${frame}`, 20, 120)
      frame++
      requestAnimationFrame(draw)
    }
    draw()
    const videoTrack = canvas.captureStream(30).getVideoTracks()[0]

    // synthetic audio: 440 Hz oscillator
    const audioCtx = new AudioContext()
    const osc = audioCtx.createOscillator()
    osc.frequency.value = 440
    const dest = audioCtx.createMediaStreamDestination()
    osc.connect(dest)
    osc.start()
    const audioTrack = dest.stream.getAudioTracks()[0]

    // publishTrack accepts a raw MediaStreamTrack; LiveKit wraps it.
    await room.localParticipant.publishTrack(videoTrack, {
      name: "synthetic-video",
      source: "camera",
    })
    await room.localParticipant.publishTrack(audioTrack, {
      name: "synthetic-audio",
      source: "microphone",
    })

    return room.localParticipant.identity as string
  })
}

async function expectRemoteAV(peer: Peer, remoteIdentity: string) {
  // Remote tile exists.
  await peer.page.waitForFunction(
    (id) => !!document.querySelector(`[data-participant="${id}"]`),
    remoteIdentity,
    { timeout: 20_000 },
  )

  // Remote video attached with non-zero resolution — first hurdle.
  await peer.page.waitForFunction(
    (id) => {
      const v = document.querySelector(
        `[data-participant="${id}"] .meeting-tile-video video`,
      ) as HTMLVideoElement | null
      return !!v && v.videoWidth > 0 && v.readyState >= 2
    },
    remoteIdentity,
    { timeout: 30_000 },
  )

  // Stronger proof: frames are actually *advancing*. Wait for the first
  // rendered frame, then count N additional decoded frames. This avoids
  // counting the ramp-up window (negotiation → first keyframe → decoder
  // warmup) against the fps threshold.
  const frames = await peer.page.evaluate(
    async ({ id, targetFrames, hardMaxMs }) => {
      const v = document.querySelector(
        `[data-participant="${id}"] .meeting-tile-video video`,
      ) as HTMLVideoElement | null
      if (!v) return 0
      if (!("requestVideoFrameCallback" in v)) {
        // Fallback: sample currentTime. Advancing → frames playing.
        const t0 = v.currentTime
        await new Promise((r) => setTimeout(r, 1500))
        return v.currentTime > t0 ? 999 : 0
      }
      return await new Promise<number>((resolve) => {
        let count = 0
        const start = performance.now()
        const tick = () => {
          count++
          if (count < targetFrames && performance.now() - start < hardMaxMs) {
            ;(v as any).requestVideoFrameCallback(tick)
          } else {
            resolve(count)
          }
        }
        ;(v as any).requestVideoFrameCallback(tick)
        // Hard ceiling so a frozen stream doesn't hang the test.
        setTimeout(() => resolve(count), hardMaxMs)
      })
    },
    { id: remoteIdentity, targetFrames: 10, hardMaxMs: 8000 },
  )
  console.log(`[${peer.slug}] decoded ${frames} frames from ${remoteIdentity}`)
  expect(
    frames,
    `remote video should decode ≥10 frames within 8s (got ${frames})`,
  ).toBeGreaterThanOrEqual(10)

  // Remote audio element attached under #meeting-media with a live
  // MediaStreamTrack. We don't assert `readyState >= 2` — in headless
  // Chromium, synthetic oscillator audio decodes lazily; the presence
  // of an un-paused element with a live track is enough to prove the
  // subscription + DOM attachment path worked.
  await peer.page.waitForFunction(
    () => {
      const audios = document.querySelectorAll(
        "#meeting-media audio",
      ) as NodeListOf<HTMLAudioElement>
      for (const a of audios) {
        const src = a.srcObject as MediaStream | null
        if (!src) continue
        const live = src.getAudioTracks().some((t) => t.readyState === "live")
        if (!a.paused && live) return true
      }
      return false
    },
    null,
    { timeout: 20_000 },
  )
}

async function leaveMeeting(peer: Peer) {
  const leaveBtn = peer.page.locator('[phx-click="meeting_leave"]').first()
  if (await leaveBtn.isVisible().catch(() => false)) {
    await leaveBtn.click()
  }
}

test("two participants can see and hear each other", async () => {
  const launchArgs = ["--autoplay-policy=no-user-gesture-required"]
  // The default "chromium" channel uses `chromium-headless-shell`, a
  // trimmed build whose canvas.captureStream and AudioContext pipelines
  // are stubbed — synthetic tracks silently emit no frames. Force the
  // full Chromium for the media paths to work.
  const browserAlice = await chromium.launch({ args: launchArgs, channel: "chromium" })
  const browserBob = await chromium.launch({ args: launchArgs, channel: "chromium" })
  const alice = await login(browserAlice, "alice")
  const bob = await login(browserBob, "bob")

  try {
    await clickJoin(alice)
    await alice.page.waitForTimeout(1000)
    await clickJoin(bob)

    const [aliceId, bobId] = await Promise.all([
      publishSyntheticAV(alice),
      publishSyntheticAV(bob),
    ])

    expect(aliceId).toMatch(/^user:/)
    expect(bobId).toMatch(/^user:/)
    expect(aliceId).not.toBe(bobId)

    await Promise.all([
      expectRemoteAV(alice, bobId),
      expectRemoteAV(bob, aliceId),
    ])
  } finally {
    await leaveMeeting(alice).catch(() => {})
    await leaveMeeting(bob).catch(() => {})
    await browserAlice.close()
    await browserBob.close()
  }
})
