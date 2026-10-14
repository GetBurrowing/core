import { describe, it, expect } from "vitest"
import { partitionFiles, runUpload, UploadManager, stagedFiles } from "../../js/hooks/large_upload.js"
import { formatBytes, formatProgress, formatEta } from "../../js/lib/byte_format.js"

/**
 * The LargeUpload hook's offset/resume loop (task 01a120be stage 3), driven
 * with a stubbed fetch. The DOM half (capture listeners, posters,
 * beforeunload) runs in a real browser; what is pinned here is the rule that
 * an upload never restarts from zero.
 */

function fakeFile(size) {
  const bytes = new Uint8Array(size).map((_, i) => i % 251)
  return {
    size,
    bytes,
    slice(start, end) {
      return bytes.slice(start, end)
    },
  }
}

function headers(map) {
  return { get: (k) => (k.toLowerCase() in map ? String(map[k.toLowerCase()]) : null) }
}

// A minimal tus-style server: stores bytes, answers 204/200/409 like
// ChatAttachmentUploadController, and can be told to drop the network.
function fakeServer(size, { failNetworkAt = [] } = {}) {
  const state = { stored: 0, calls: [], netFailures: [...failNetworkAt] }
  const fetch = async (url, opts) => {
    const method = opts.method
    const offset = opts.headers ? parseInt(opts.headers["Upload-Offset"], 10) : null
    state.calls.push({ method, offset })
    if (method === "PATCH" && state.netFailures.length && state.netFailures[0] === state.calls.length) {
      state.netFailures.shift()
      // Half the chunk reached the server before the connection dropped.
      state.stored += Math.floor(opts.body.length / 2)
      throw new TypeError("Failed to fetch")
    }
    if (method === "HEAD") {
      return { ok: true, status: 200, headers: headers({ "upload-offset": state.stored }) }
    }
    if (offset !== state.stored) {
      return { ok: false, status: 409, headers: headers({ "upload-offset": state.stored }) }
    }
    state.stored += opts.body.length
    if (state.stored === size) {
      return {
        ok: true,
        status: 200,
        headers: headers({ "upload-offset": size }),
        json: async () => ({ id: "att", message_id: "msg" }),
      }
    }
    return { ok: true, status: 204, headers: headers({ "upload-offset": state.stored }) }
  }
  return { state, fetch }
}

const deps = (fetch, progress = []) => ({
  fetch,
  onProgress: (sent, status) => progress.push([sent, status]),
  waitForOnline: async () => {},
  sleep: async () => {},
})

describe("partitionFiles", () => {
  it("routes only files over the server's inline cap to the large path", () => {
    const files = [{ size: 10 }, { size: 15_000_000 }, { size: 15_000_001 }]
    const { small, large } = partitionFiles(files, 15_000_000)
    expect(small.map((f) => f.size)).toEqual([10, 15_000_000])
    expect(large.map((f) => f.size)).toEqual([15_000_001])
  })

  it("routes nothing without a server-provided cap", () => {
    const { large } = partitionFiles([{ size: 1e12 }], NaN)
    expect(large).toEqual([])
  })
})

describe("runUpload", () => {
  it("PATCHes chunk-sized slices with Upload-Offset until the server answers 200", async () => {
    const { state, fetch } = fakeServer(250)
    const out = await runUpload({ file: fakeFile(250), url: "/u", offset: 0, chunkBytes: 100 }, deps(fetch))
    expect(out).toEqual({ status: "done", result: { id: "att", message_id: "msg" } })
    expect(state.calls.map((c) => [c.method, c.offset])).toEqual([
      ["PATCH", 0],
      ["PATCH", 100],
      ["PATCH", 200],
    ])
  })

  it("after a network drop it pauses, HEADs the offset and resumes there, never from zero", async () => {
    const { state, fetch } = fakeServer(300, { failNetworkAt: [2] })
    const progress = []
    const out = await runUpload(
      { file: fakeFile(300), url: "/u", offset: 0, chunkBytes: 100 },
      deps(fetch, progress),
    )
    expect(out.status).toBe("done")
    expect(progress.some(([, s]) => s === "paused")).toBe(true)
    // PATCH 0 ok, PATCH 100 drops after 50 bytes, HEAD reads 150, PATCH 150 ...
    expect(state.calls.map((c) => [c.method, c.offset])).toEqual([
      ["PATCH", 0],
      ["PATCH", 100],
      ["HEAD", null],
      ["PATCH", 150],
      ["PATCH", 250],
    ])
    expect(state.calls.filter((c) => c.method === "PATCH" && c.offset === 0)).toHaveLength(1)
  })

  it("adopts the server offset on 409", async () => {
    const { state, fetch } = fakeServer(200)
    state.stored = 120 // a previous tab already sent 120 bytes
    const out = await runUpload({ file: fakeFile(200), url: "/u", offset: 0, chunkBytes: 100 }, deps(fetch))
    expect(out.status).toBe("done")
    expect(state.calls.map((c) => [c.method, c.offset])).toEqual([
      ["PATCH", 0],
      ["PATCH", 120],
    ])
  })

  it("stops as failed on a 4xx it cannot recover from, keeping the offset", async () => {
    const fetch = async () => ({ ok: false, status: 403, headers: headers({}) })
    const out = await runUpload({ file: fakeFile(10), url: "/u", offset: 0, chunkBytes: 5 }, deps(fetch))
    expect(out).toEqual({ status: "failed", offset: 0, httpStatus: 403 })
  })

  for (const code of [404, 410]) {
    it(`reports ${code} on PATCH as an expired reservation`, async () => {
      const fetch = async () => ({ ok: false, status: code, headers: headers({}) })
      const out = await runUpload({ file: fakeFile(10), url: "/u", offset: 0, chunkBytes: 5 }, deps(fetch))
      expect(out).toEqual({ status: "expired", offset: 0, httpStatus: code })
    })

    it(`reports ${code} on the resume HEAD as an expired reservation`, async () => {
      const fetch = async (_url, opts) => {
        expect(opts.method).toBe("HEAD")
        return { ok: false, status: code, headers: headers({}) }
      }
      const out = await runUpload(
        { file: fakeFile(10), url: "/u", offset: 4, chunkBytes: 5, resume: true },
        deps(fetch),
      )
      expect(out.status).toBe("expired")
    })
  }

  it("an aborted in-flight PATCH (offline) pauses and resumes from HEAD, not zero", async () => {
    const { state, fetch: inner } = fakeServer(200)
    let first = true
    const fetch = async (url, opts) => {
      if (opts.method === "PATCH" && opts.offset !== 0 && first && state.stored === 100) {
        first = false
        state.calls.push({ method: "PATCH", offset: parseInt(opts.headers["Upload-Offset"], 10) })
        expect(opts.signal).toBeDefined()
        throw new DOMException("aborted", "AbortError")
      }
      return inner(url, opts)
    }
    const progress = []
    const out = await runUpload({ file: fakeFile(200), url: "/u", offset: 0, chunkBytes: 100 }, deps(fetch, progress))
    expect(out.status).toBe("done")
    expect(progress.some(([, s]) => s === "paused")).toBe(true)
    expect(state.calls.map((c) => [c.method, c.offset])).toEqual([
      ["PATCH", 0],
      ["PATCH", 100],
      ["HEAD", null],
      ["PATCH", 100],
    ])
  })

  it("a cancelled upload stops without pausing", async () => {
    const u = { file: fakeFile(200), url: "/u", offset: 0, chunkBytes: 100 }
    const fetch = async () => {
      u.aborted = true
      throw new DOMException("aborted", "AbortError")
    }
    const out = await runUpload(u, deps(fetch))
    expect(out).toEqual({ status: "aborted", offset: 0 })
  })

  it("a retry starts with HEAD", async () => {
    const { state, fetch } = fakeServer(100)
    state.stored = 60
    const out = await runUpload(
      { file: fakeFile(100), url: "/u", offset: 0, chunkBytes: 100, resume: true },
      deps(fetch),
    )
    expect(out.status).toBe("done")
    expect(state.calls[0]).toEqual({ method: "HEAD", offset: null })
    expect(state.calls[1]).toEqual({ method: "PATCH", offset: 60 })
  })
})

// ── The one shared size rule (fix-common.md table) ─────────────────────

describe("formatBytes / formatProgress: the shared decimal rule", () => {
  const table = [
    [1_000_000_000, "1 GB"],
    [1_073_741_824, "1.1 GB"],
    [899_109_076, "899.1 MB"],
    [900_000_000, "900 MB"],
    [1_153_433_600, "1.2 GB"],
    [8_000_000, "8 MB"],
    [33_554_432, "33.6 MB"],
    [999_960_000, "1 GB"],
    [512, "512 bytes"],
  ]
  for (const [bytes, label] of table) {
    it(`format(${bytes}) is "${label}"`, () => {
      expect(formatBytes(bytes)).toBe(label)
    })
  }

  it('progress(412_000_000, 900_000_000) is "412 of 900 MB"', () => {
    expect(formatProgress(412_000_000, 900_000_000)).toBe("412 of 900 MB")
  })

  it('progress(416_000_000, 899_109_076) is "416 of 899.1 MB"', () => {
    expect(formatProgress(416_000_000, 899_109_076)).toBe("416 of 899.1 MB")
  })

  it("progress clamps sent to total and takes the unit from total", () => {
    expect(formatProgress(2_000_000_000, 1_000_000_000)).toBe("1 of 1 GB")
    expect(formatProgress(500_000_000, 999_960_000)).toBe("0.5 of 1 GB")
    expect(formatProgress(0, 900_000_000)).toBe("0 of 900 MB")
  })

  it("the counter line with an ETA", () => {
    expect(`${formatProgress(412_000_000, 900_000_000)}${formatEta(120)}`).toBe(
      "412 of 900 MB · about 2 min",
    )
    expect(formatEta(null)).toBe("")
  })
})

// ── The registry: expiry, re-reservation, failure ───────────────────────

function managerWith({ fetch, rereserve }) {
  const pushes = []
  const changes = []
  const m = new UploadManager({
    fetch,
    waitForOnline: async () => {},
    sleep: async () => {},
    now: () => 0,
    isConnected: () => true,
    pushTimeoutMs: 1000,
  })
  m.attachHook({
    pushEvent(event, payload, cb) {
      pushes.push([event, payload])
      if (event === "large_upload_rereserve") cb(rereserve(payload))
      else cb({ ok: true })
    },
  })
  m.addView(() => {
    for (const u of m.uploads.values()) changes.push([u.status, u.notice, u.offset])
  })
  // No DOM in this suite: a done upload is dropped straight away.
  m.awaitMessage = (u) => m.uploads.delete(u.key)
  return { m, pushes, changes }
}

const meta = (ref, extra = {}) => ({
  ref,
  id: "res-1",
  upload_url: "/u/1",
  chunk_bytes: 100,
  offset: 0,
  filename: "clip.mov",
  content_type: "video/quicktime",
  space_id: "space-1",
  participant_id: "part-1",
  content: "caption",
  ...extra,
})

describe("UploadManager", () => {
  it("re-reserves after a 410 and starts again from 0, saying so", async () => {
    // First reservation: 100 bytes land, then it has expired.
    const calls = []
    const servers = { "/u/1": { stored: 0, expired: false }, "/u/2": { stored: 0, expired: false } }
    const fetch = async (url, opts) => {
      const s = servers[url]
      const offset = opts.headers ? parseInt(opts.headers["Upload-Offset"], 10) : null
      calls.push([url, opts.method, offset])
      if (s.expired) return { ok: false, status: 410, headers: headers({}) }
      s.stored += opts.body.length
      if (url === "/u/1" && s.stored === 100) s.expired = true
      if (s.stored === 300) return { ok: true, status: 200, headers: headers({}), json: async () => ({ message_id: "m" }) }
      return { ok: true, status: 204, headers: headers({ "upload-offset": s.stored }) }
    }
    const { m, pushes, changes } = managerWith({
      fetch,
      rereserve: () => ({ ok: true, id: "res-2", upload_url: "/u/2", chunk_bytes: 100, offset: 0 }),
    })
    stagedFiles.set("k1", fakeFile(300))
    const u = m.begin(meta("k1"))
    await new Promise((r) => setTimeout(r, 0))
    while (m.isBusy()) await new Promise((r) => setTimeout(r, 0))

    const rereserve = pushes.find(([e]) => e === "large_upload_rereserve")
    expect(rereserve[1]).toMatchObject({
      expired_id: "res-1",
      space_id: "space-1",
      participant_id: "part-1",
      filename: "clip.mov",
      byte_size: 300,
      content: "caption",
    })
    expect(calls).toEqual([
      ["/u/1", "PATCH", 0],
      ["/u/1", "PATCH", 100],
      ["/u/2", "PATCH", 0],
      ["/u/2", "PATCH", 100],
      ["/u/2", "PATCH", 200],
    ])
    expect(changes).toContainEqual(["reserving", "expired", 0])
    expect(u.status).toBe("done")
    expect(m.uploads.size).toBe(0)
  })

  it("a failed re-reservation is a visible failure with Try again, never a silent removal", async () => {
    const fetch = async () => ({ ok: false, status: 404, headers: headers({}) })
    let answer = { ok: false, error: "space_archived" }
    const { m } = managerWith({ fetch, rereserve: () => answer })
    stagedFiles.set("k2", fakeFile(300))
    const u = m.begin(meta("k2"))
    while (m.isBusy()) await new Promise((r) => setTimeout(r, 0))

    expect(u.status).toBe("failed")
    expect(u.failure).toBe("reserve")
    expect(m.uploads.get("k2")).toBe(u)

    // Try again: this time the server reserves, and the upload finishes.
    answer = { ok: true, id: "res-3", upload_url: "/u/3", chunk_bytes: 300, offset: 0 }
    m.env.fetch = async () => ({ ok: true, status: 200, headers: headers({}), json: async () => ({ message_id: "m" }) })
    m.retry("k2")
    await new Promise((r) => setTimeout(r, 0))
    while (m.isBusy()) await new Promise((r) => setTimeout(r, 0))
    expect(u.status).toBe("done")
  })

  it("isBusy is true while an upload holds its File, false once it is done", async () => {
    let release
    const gate = new Promise((r) => (release = r))
    const fetch = async () => {
      await gate
      return { ok: true, status: 200, headers: headers({}), json: async () => ({}) }
    }
    const { m } = managerWith({ fetch, rereserve: () => ({ ok: false }) })
    stagedFiles.set("k3", fakeFile(10))
    m.begin(meta("k3", { chunk_bytes: 10 }))
    expect(m.isBusy()).toBe(true)
    release()
    while (m.isBusy()) await new Promise((r) => setTimeout(r, 0))
    expect(m.isBusy()).toBe(false)
  })
})

describe("UploadManager ETA", () => {
  it("measures the rate since the resume, not across the time offline", () => {
    let t = 0
    const m = new UploadManager({ now: () => t, waitForOnline: async () => {}, sleep: async () => {} })
    const u = { byteSize: 1000, offset: 0, status: "uploading", samples: [[0, 0]] }
    t = 10_000
    m.progress(u, 400, "uploading") // 40 bytes/s
    expect(u.etaS).toBe(15)
    t = 70_000
    m.progress(u, 400, "paused")
    t = 71_000
    m.progress(u, 400, "uploading") // back online: a fresh window
    t = 81_000
    m.progress(u, 800, "uploading") // 40 bytes/s again
    expect(u.etaS).toBe(5)
  })
})
