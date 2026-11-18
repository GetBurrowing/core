import { describe, it, expect, vi } from "vitest"

// Task 01a1e82a remediation, finding 6. "Stay" on the browser's leave-page
// prompt still dropped the call: livekit-client's own beforeunload listener
// (Room option `disconnectOnPageLeave`, default true) disconnected even
// though meeting_presence.js had cancelled the beforeunload. The Room is now
// built with it off; the hook's own pagehide / uncancelled-beforeunload path
// (pinned in meeting_client_unload_order.test.js) is what leaves for real.

const made = vi.hoisted(() => [])

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts) {
      this.opts = opts
      made.push(this)
    }
  }
  return { ...actual, Room }
})

const { default: MeetingClient } = await import("../../js/hooks/meeting_client.js")

describe("the call's Room", () => {
  it("does not let livekit-client disconnect on page leave by itself", () => {
    const room = MeetingClient._newRoom.call(Object.create(MeetingClient))
    expect(room.opts.disconnectOnPageLeave).toBe(false)
    // The rest of the transport setup is unchanged.
    expect(room.opts).toMatchObject({ adaptiveStream: true, dynacast: true, publishDefaults: { simulcast: true } })
  })
})
