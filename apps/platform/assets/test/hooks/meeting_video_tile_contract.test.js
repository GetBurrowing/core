import { describe, it, expect } from "vitest"
import { RemoteVideoTrack } from "livekit-client"

/**
 * SDK-contract guard for the custom `StableTileElementInfo` fix (task 019f8153).
 *
 * The stage-1 fix in js/hooks/meeting_video_tile.js pre-registers our own
 * ElementInfo via `track.observeElementInfo(info)` (and tears it down with
 * `track.stopObservingElementInfo(info)`) so the SDK's default, false-negative
 * HTMLElementInfo watcher is never installed. `_attach` also gates on the
 * `isAdaptiveStream` getter before doing any of that.
 *
 * Those two methods are marked `@internal` in the installed SDK's typings
 * (node_modules/livekit-client/dist/src/room/track/RemoteVideoTrack.d.ts:19-34):
 * they exist in the runtime dist but are NOT part of the public typed surface.
 * A `livekit-client` version bump could therefore rename or remove the seam the
 * fix depends on with ZERO type-check warning. This test trips on exactly that.
 *
 * Verified against livekit-client 2.18.1 (declared range ^2.18.1 in
 * package.json). See the load-bearing ElementInfo / phx-update="ignore" contract
 * note in lib/platform_web/components/meeting/video_tile.ex (added in stage 5),
 * and the behavioral harness in test/hooks/meeting_video_tile_adaptive.test.js.
 *
 * How to prove this guard actually bites (do NOT commit the fixture): temporarily
 * repoint the import above at a local fixture module whose `RemoteVideoTrack`
 * renames `observeElementInfo` to something else, re-run only this file, and
 * confirm it fails with "expected 'undefined' to be 'function'". Revert the
 * import and delete the fixture before committing.
 */

describe("livekit-client RemoteVideoTrack SDK contract", () => {
  it("exposes the observeElementInfo seam the custom ElementInfo fix depends on", () => {
    expect(typeof RemoteVideoTrack.prototype.observeElementInfo).toBe(
      "function",
    )
  })

  it("exposes the stopObservingElementInfo teardown seam", () => {
    expect(typeof RemoteVideoTrack.prototype.stopObservingElementInfo).toBe(
      "function",
    )
  })

  it("exposes the isAdaptiveStream getter that _attach gates on", () => {
    expect("isAdaptiveStream" in RemoteVideoTrack.prototype).toBe(true)
  })
})
