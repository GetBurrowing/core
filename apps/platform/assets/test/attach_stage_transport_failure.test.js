import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

/**
 * Transport failure in the composer's staged tray (redesign rung 11, task
 * 01a1557a-9de3 stage 4). A socket drop takes the LiveView process and
 * every upload entry with it. On reconnect, a file that was MID-UPLOAD
 * must come back as a failed thumbnail with "Retry <name>" (reported as
 * `attach_transport_failed`), a file that had finished is staged again
 * quietly, and retrying a failed one stages the same File again.
 *
 * Plain node (no jsdom): a minimal `document` stub answers the tray query.
 */

vi.mock("../js/hooks/large_upload", async (importOriginal) => {
  const actual = await importOriginal()
  return { ...actual, routeFiles: vi.fn(() => []), inlineMaxFromDom: () => 15_000_000 }
})

import {
  dropBufferedProgress,
  forgetTrackedFiles,
  leaveUploadChannels,
  markInterrupted,
  failedFiles,
  rememberFiles,
  restage,
  retry,
  snapshotTray,
} from "../js/attach_stage.js"

function li({ ref, failedId, state, id, retryGlyph = false }) {
  const attrs = { "data-ref": ref, "data-failed-id": failedId, "data-state": state }
  return {
    id: id || (ref ? `staged-${ref}` : `staged-failed-${failedId}`),
    getAttribute: (k) => attrs[k] ?? null,
    querySelector: (sel) => (sel === "[data-attach-retry]" && retryGlyph ? {} : null),
  }
}

function stubTray(items) {
  vi.stubGlobal("document", {
    querySelectorAll: () => items,
    querySelector: () => (items.length > 0 ? items[0] : null),
    getElementById: () => ({ id: "compose-form" }),
  })
}

function png(name, ref) {
  const f = new File(["x"], name, { type: "image/png" })
  f._phxRef = ref
  return f
}

beforeEach(() => {
  failedFiles.clear()
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("snapshot at a socket drop", () => {
  it("splits the tray: mid-upload -> failed, finished -> restage", () => {
    const busy = png("busy.png", "r-busy")
    const done = png("done.png", "r-done")
    rememberFiles([busy, done])
    stubTray([li({ ref: "r-busy", state: "uploading" }), li({ ref: "r-done", state: "done" })])

    const snap = snapshotTray()

    expect(snap.failed).toEqual([{ id: "r-busy", file: busy }])
    expect(snap.restage).toEqual([done])
  })

  it("keeps an already transport-failed item failed across a second drop", () => {
    const f = png("again.png", "r-x")
    failedFiles.set("old-id", f)
    stubTray([li({ failedId: "old-id", state: "failed" })])
    expect(snapshotTray().failed).toEqual([{ id: "old-id", file: f }])
  })
})

describe("restage after reconnect", () => {
  it("reports the interrupted file as failed and stages only the finished one", () => {
    const busy = png("busy.png", "r-busy")
    const done = png("done.png", "r-done")
    stubTray([]) // the rejoin rendered an empty tray
    const hook = { pushEvent: vi.fn(), uploadTo: vi.fn() }

    restage(hook, { restage: [done], failed: [{ id: "r-busy", file: busy }] })
    vi.runAllTimers()

    expect(hook.pushEvent).toHaveBeenCalledWith("attach_transport_failed", {
      files: [{ id: "r-busy", name: "busy.png", size: busy.size, type: "image/png" }],
    })
    expect(hook.uploadTo).toHaveBeenCalledTimes(1)
    expect(hook.uploadTo.mock.calls[0][2].map((f) => f.name)).toEqual(["done.png"])
    expect(failedFiles.get("r-busy")).toBe(busy)
  })

  it("retry on a transport-failed item drops it and stages the same bytes again", () => {
    const busy = png("busy.png", "r-busy")
    failedFiles.set("r-busy", busy)
    stubTray([])
    const hook = { pushEvent: vi.fn(), uploadTo: vi.fn() }

    expect(retry(hook, "r-busy")).toBe(true)
    vi.runAllTimers()

    expect(hook.pushEvent).toHaveBeenCalledWith("attach_failed_remove", { id: "r-busy" })
    expect(hook.uploadTo).toHaveBeenCalledTimes(1)
    const [staged] = hook.uploadTo.mock.calls[0][2]
    expect(staged.name).toBe("busy.png")
    expect(staged).not.toBe(busy) // a fresh File gets a fresh LiveView ref
    expect(failedFiles.has("r-busy")).toBe(false)
  })

  it("an unknown ref is not retried (positive control)", () => {
    stubTray([])
    const hook = { pushEvent: vi.fn(), uploadTo: vi.fn() }
    expect(retry(hook, "nope")).toBe(false)
    expect(hook.pushEvent).not.toHaveBeenCalled()
  })
})

describe("buffered progress across a socket drop", () => {
  it("drops buffered `progress` pushes (they would crash the NEW LiveView) and keeps the rest", () => {
    const keep = { event: "event" }
    const channel = { pushBuffer: [{ event: "progress" }, keep, { event: "progress" }] }
    expect(dropBufferedProgress(channel)).toBe(2)
    expect(channel.pushBuffer).toEqual([keep])
  })

  it("is a no-op without a channel or buffer", () => {
    expect(dropBufferedProgress(null)).toBe(0)
    expect(dropBufferedProgress({})).toBe(0)
  })
})

describe("while the socket is down", () => {
  it("shows an interrupted thumbnail failed at once: state, outline, no frozen ring", () => {
    const attrs = { "data-state": "uploading" }
    const classes = new Set()
    const ring = { remove: vi.fn() }
    const frame = { classList: { add: (...c) => c.forEach((x) => classes.add(x)) } }
    const img = { parentElement: frame }
    const liEl = {
      setAttribute: (k, v) => (attrs[k] = v),
      querySelector: (sel) => (sel === "[data-role=upload-ring]" ? ring : sel === "img" ? img : null),
    }
    vi.stubGlobal("document", { getElementById: (id) => (id === "staged-r-busy" ? liEl : null) })

    expect(markInterrupted({ restage: [], failed: [{ id: "r-busy" }, { id: "gone" }] })).toBe(1)
    expect(attrs["data-state"]).toBe("failed")
    expect(ring.remove).toHaveBeenCalled()
    expect(classes.has("outline-error")).toBe(true)
  })
})

describe("in-flight upload channels at a socket drop", () => {
  it("leaves every lvu: channel and no other", () => {
    const up = { topic: "lvu:3", leave: vi.fn() }
    const lv = { topic: "lv:phx-abc", leave: vi.fn() }
    expect(leaveUploadChannels({ channels: [up, lv] })).toBe(1)
    expect(up.leave).toHaveBeenCalledTimes(1)
    expect(lv.leave).not.toHaveBeenCalled()
    expect(leaveUploadChannels(null)).toBe(0)
  })
})

describe("LiveView form recovery after the rejoin", () => {
  it("forgets the Files the live file input tracks, so the replay re-stages nothing", () => {
    const input = { phxPrivate: { files: [png("a.png", "1"), png("b.png", "2")] }, value: "x" }
    const form = { querySelectorAll: () => [input] }
    expect(forgetTrackedFiles(form)).toBe(2)
    expect(input.phxPrivate.files).toEqual([])
    expect(input.value).toBe(null)
    expect(forgetTrackedFiles(null)).toBe(0)
  })
})
