import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingWhiteboard from "../../js/hooks/meeting_whiteboard.js"

/**
 * Tests for the `MeetingWhiteboard` hook — the `/meetings` center-stage
 * Excalidraw surface.
 *
 * Two invariants carry this stage and both are asserted by COUNT, not by
 * "nothing threw":
 *
 *   1. The ~4.9 MB island is fetched lazily and EXACTLY ONCE. A stub that is
 *      never called would also satisfy "not more than once", so every
 *      once-assertion here is paired with a `toHaveBeenCalledTimes(1)` on the
 *      loader — a silent no-op fails it.
 *   2. The React root is created exactly once per hook lifetime and is never
 *      replaced. `updated()` is compared by REFERENCE against the root
 *      captured after the first activation.
 *
 * Env note: like the other meeting hook tests in this directory, this runs in
 * vitest's default `node` environment (jsdom is not a dependency of this app)
 * against a hand-built fake `el`. The hook is written to only need
 * `classList` + `innerHTML`, which is why it renders its transient states as
 * markup instead of via `document.createElement`.
 */

function fakeEl() {
  return {
    innerHTML: "",
    // Server-rendered attributes. The re-render test mutates these between
    // `updated()` calls so it is genuinely simulating LiveView patching the
    // host (#664: attributes ARE merged onto `phx-update="ignore"` nodes),
    // rather than calling `updated()` against an unchanged DOM — which would
    // be a weaker test that passes for a hook that reads attributes.
    _attrs: {},
    setAttribute(name, value) {
      this._attrs[name] = value
    },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this._attrs, name)
        ? this._attrs[name]
        : null
    },
    // React's container node lives here. `contains` is what the required
    // test uses to prove the Excalidraw surface is still attached after
    // three re-renders.
    _children: [],
    appendChild(node) {
      this._children.push(node)
      return node
    },
    contains(node) {
      return this._children.includes(node)
    },
    classList: {
      _set: new Set(),
      add(c) {
        this._set.add(c)
      },
      remove(c) {
        this._set.delete(c)
      },
      contains(c) {
        return this._set.has(c)
      },
    },
  }
}

function fakeApi(el) {
  const root = { render: vi.fn(), unmount: vi.fn(), __id: "root-1" }
  // Stand-in for the DOM node React mounts into the host. Appended at
  // `createRoot` time so "the host still contains the Excalidraw container"
  // is an assertion about a real object identity, not about markup.
  const container = { __excalidraw_container: true }
  const createRoot = vi.fn(() => {
    if (el) el.appendChild(container)
    return root
  })
  return {
    root,
    container,
    api: {
      createRoot,
      React: { createElement: vi.fn((type, props) => ({ type, props })) },
      Excalidraw: function Excalidraw() {},
      // Mirrors the island's own constant: the hook reads the prop name off
      // the API object rather than spelling it, so the app bundle never
      // contains the token.
      editorApiProp: "excalidrawAPI",
      // Scene-file vocabulary, owned by the island for the same
      // build-guard reason as `editorApiProp`.
      sceneFileType: "excalidraw",
      sceneFileVersion: 2,
      sceneFileExtension: ".excalidraw",
      exportToBlob: vi.fn(() =>
        Promise.resolve(new Blob([new Uint8Array([1, 2, 3, 4])], { type: "image/png" })),
      ),
    },
  }
}

function buildHook() {
  const el = fakeEl()
  const handlers = {}
  const { api, root, container } = fakeApi(el)
  const loader = vi.fn(() => Promise.resolve(api))
  const pushEvent = vi.fn()
  const excalidrawAPI = { updateScene: vi.fn() }
  // Upload seam. Records (url, init) per POST so the two artefacts can be
  // asserted by content type and by count, not by "something was sent".
  const uploads = []
  const fetchImpl = vi.fn((url, init) => {
    uploads.push({ url, init })
    return Promise.resolve({ ok: true, status: 200 })
  })

  const hook = Object.assign(Object.create(MeetingWhiteboard), {
    el,
    handleEvent(name, cb) {
      handlers[name] = cb
    },
    pushEvent,
    _loadIsland: loader,
    _fetch: fetchImpl,
  })

  // Props of the single `React.createElement(Excalidraw, …)` call.
  const props = () => api.React.createElement.mock.calls[0][1]

  return {
    hook,
    el,
    api,
    root,
    container,
    loader,
    pushEvent,
    excalidrawAPI,
    uploads,
    fetchImpl,
    props,
    setMode: (mode) => handlers["meeting_stage_mode_changed"]({ mode }),
    send: (name, payload) => handlers[name](payload),
    hasHandler: (name) => typeof handlers[name] === "function",
    // React invokes `excalidrawAPI` when the editor is ready; nothing else
    // does, so the test drives it explicitly.
    attachApi: () => props()[api.editorApiProp](excalidrawAPI),
    draw: (elements, appState) => props().onChange(elements, appState || {}, {}),
  }
}

// An element array whose members are distinguishable, so "all five are still
// there" can be asserted by content rather than by length alone.
function elements(n) {
  return Array.from({ length: n }, (_, i) => ({ id: `el-${i}`, type: "line" }))
}

// Bring a hook all the way to "board is live and restore has resolved":
// mounted, whiteboard active, island resolved, Excalidraw API attached, and
// the server's (empty) stored scene delivered. The save gate is open only
// after that last step.
async function activate(ctx, { scene = {}, version = 0 } = {}) {
  ctx.setMode("whiteboard")
  await flush()
  ctx.attachApi()
  ctx.send("whiteboard_loaded", { scene, scene_version: version })
}

// The hook awaits the loader promise, so drain the microtask queue.
const flush = () => Promise.resolve().then(() => Promise.resolve())

describe("MeetingWhiteboard", () => {
  let ctx

  beforeEach(() => {
    ctx = buildHook()
    ctx.hook.mounted()
  })

  it("does not request the island on mount, and starts hidden", () => {
    expect(ctx.loader).toHaveBeenCalledTimes(0)
    expect(ctx.el.classList.contains("hidden")).toBe(true)
    expect(ctx.hasHandler("meeting_stage_mode_changed")).toBe(true)
  })

  it("requests the island on the first switch to whiteboard mode", async () => {
    ctx.setMode("whiteboard")
    expect(ctx.loader).toHaveBeenCalledTimes(1)
    expect(ctx.el.classList.contains("hidden")).toBe(false)

    await flush()
    expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
    expect(ctx.api.createRoot).toHaveBeenCalledWith(ctx.el)
    expect(ctx.root.render).toHaveBeenCalledTimes(1)
  })

  it("never requests the island for a non-whiteboard mode", async () => {
    ctx.setMode("gallery")
    ctx.setMode("screen")
    ctx.setMode("canvas")
    await flush()

    expect(ctx.loader).toHaveBeenCalledTimes(0)
    expect(ctx.api.createRoot).toHaveBeenCalledTimes(0)
  })

  it("requests the island exactly once across three mode flips", async () => {
    ctx.setMode("whiteboard")
    await flush()
    ctx.setMode("gallery")
    ctx.setMode("whiteboard")
    await flush()
    ctx.setMode("screen")
    ctx.setMode("whiteboard")
    await flush()

    // Count assertions, not "at most once": a loader that was never called
    // would pass an at-most check while proving nothing.
    expect(ctx.loader).toHaveBeenCalledTimes(1)
    expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
    expect(ctx.root.render).toHaveBeenCalledTimes(1)
  })

  it("coalesces flips that happen while the island is still in flight", async () => {
    ctx.setMode("whiteboard")
    ctx.setMode("gallery")
    ctx.setMode("whiteboard")
    expect(ctx.loader).toHaveBeenCalledTimes(1)

    await flush()
    expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
  })

  it("updated() never re-creates the React root", async () => {
    ctx.setMode("whiteboard")
    await flush()
    const rootAfterMount = ctx.hook._root
    expect(rootAfterMount).toBe(ctx.root)

    ctx.hook.updated()
    ctx.hook.updated()
    ctx.hook.updated()
    await flush()

    // Identity, not "no error": the root object must be the SAME object.
    expect(ctx.hook._root).toBe(rootAfterMount)
    expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
    expect(ctx.root.render).toHaveBeenCalledTimes(1)
    expect(ctx.root.unmount).toHaveBeenCalledTimes(0)
    expect(ctx.loader).toHaveBeenCalledTimes(1)
  })

  it("updated() re-asserts visibility from client-side truth, not the DOM", async () => {
    ctx.setMode("whiteboard")
    await flush()

    // Simulate LiveView stamping `hidden` back on (the #664 attribute-merge
    // hazard). `updated()` must restore the hook's own truth.
    ctx.el.classList.add("hidden")
    ctx.hook.updated()
    expect(ctx.el.classList.contains("hidden")).toBe(false)
  })

  it("switching to gallery hides the board but does not unmount it", async () => {
    ctx.setMode("whiteboard")
    await flush()

    ctx.setMode("gallery")
    await flush()

    expect(ctx.el.classList.contains("hidden")).toBe(true)
    expect(ctx.root.unmount).toHaveBeenCalledTimes(0)
    expect(ctx.hook._root).toBe(ctx.root)
  })

  it("destroyed() unmounts the root and drops the cached scene", async () => {
    ctx.setMode("whiteboard")
    await flush()
    ctx.hook._scene = { elements: [] }

    ctx.hook.destroyed()

    expect(ctx.root.unmount).toHaveBeenCalledTimes(1)
    expect(ctx.hook._root).toBe(null)
    expect(ctx.hook._scene).toBe(null)
  })

  it("renders an error state and allows a later retry when the island fails", async () => {
    const failing = buildHook()
    failing.hook.mounted()
    failing.hook._loadIsland = vi
      .fn()
      .mockRejectedValueOnce(new Error("boom"))
      .mockResolvedValue(failing.api)
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {})

    failing.setMode("whiteboard")
    await flush()
    expect(failing.hook.el.innerHTML).toContain('data-whiteboard-state="error"')
    expect(failing.api.createRoot).toHaveBeenCalledTimes(0)

    failing.setMode("gallery")
    failing.setMode("whiteboard")
    await flush()
    expect(failing.hook._loadIsland).toHaveBeenCalledTimes(2)
    expect(failing.api.createRoot).toHaveBeenCalledTimes(1)

    consoleError.mockRestore()
  })

  it("passes single-editor Excalidraw options (langCode, no collab handler)", async () => {
    ctx.setMode("whiteboard")
    await flush()

    const [, props] = ctx.api.React.createElement.mock.calls[0]
    expect(props.langCode).toBe("en")
    expect(["light", "dark"]).toContain(props.theme)
    expect(props.UIOptions.canvasActions.saveToActiveFile).toBe(false)
    // v1 is single-editor: no collaboration callback of any kind.
    expect(props.onCollabButtonClick).toBeUndefined()
    expect(props.isCollaborating).toBeUndefined()
  })

  // ── Persistence (stage 4) ─────────────────────────────────────────────

  describe("re-render durability", () => {
    /**
     * THE required case: "toggle another meeting control mid-drawing and lose
     * nothing." Five elements are fed through `onChange` and the debounce is
     * deliberately NOT allowed to fire, so the only copy of the drawing is
     * the one in the hook and in the React root. Then the server re-renders
     * the page three times — captions toggled, mic toggled, presence changed
     * — each time patching DIFFERENT attribute values onto the host, which is
     * what LiveView actually does to a `phx-update="ignore"` node (#664).
     */
    it("survives three re-renders mid-drawing with mutated host attributes", async () => {
      vi.useFakeTimers()
      try {
        const ctx = buildHook()
        ctx.hook.mounted()
        ctx.setMode("whiteboard")
        await vi.runAllTimersAsync()
        ctx.attachApi()
        ctx.send("whiteboard_loaded", { scene: {}, scene_version: 0 })

        const rootAfterMount = ctx.hook._root
        const drawn = elements(5)
        ctx.draw(drawn)

        // The debounce has NOT fired: nothing has been persisted, so the
        // in-memory array is the only copy of these strokes.
        expect(ctx.pushEvent).not.toHaveBeenCalledWith(
          "whiteboard_save",
          expect.anything(),
        )

        for (const [i, attrs] of [
          { "data-captions": "true" },
          { "data-mic": "muted" },
          { "data-presence": "3" },
        ].entries()) {
          for (const [k, v] of Object.entries(attrs)) {
            ctx.el.setAttribute(k, `${v}-${i}`)
          }
          ctx.hook.updated()
        }

        expect(ctx.hook._root).toBe(rootAfterMount)
        expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
        expect(ctx.excalidrawAPI.updateScene).not.toHaveBeenCalled()
        expect(ctx.el.contains(ctx.container)).toBe(true)
        // All five, by content — not merely "non-empty".
        expect(ctx.hook._elements).toHaveLength(5)
        expect(ctx.hook._elements.map((e) => e.id)).toEqual([
          "el-0",
          "el-1",
          "el-2",
          "el-3",
          "el-4",
        ])
      } finally {
        vi.useRealTimers()
      }
    })

    it("whiteboard → gallery → whiteboard keeps the elements and the root", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      await activate(ctx)
      const rootAfterMount = ctx.hook._root
      ctx.draw(elements(5))

      ctx.setMode("gallery")
      await flush()
      ctx.setMode("whiteboard")
      await flush()

      expect(ctx.hook._root).toBe(rootAfterMount)
      expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
      expect(ctx.hook._elements).toHaveLength(5)
      expect(ctx.el.contains(ctx.container)).toBe(true)
    })
  })

  describe("save path", () => {
    beforeEach(() => vi.useFakeTimers())
    afterEach(() => vi.useRealTimers())

    it("debounces to one save carrying the scene and the held version", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      ctx.setMode("whiteboard")
      await vi.runAllTimersAsync()
      ctx.attachApi()
      ctx.send("whiteboard_loaded", { scene: {}, scene_version: 7 })

      ctx.draw(elements(1))
      ctx.draw(elements(2))
      ctx.draw(elements(3))
      expect(saves(ctx)).toHaveLength(0)

      await vi.advanceTimersByTimeAsync(1600)

      const calls = saves(ctx)
      expect(calls).toHaveLength(1)
      expect(calls[0][1].expected_version).toBe(7)
      expect(calls[0][1].scene.elements).toHaveLength(3)
    })

    it("does not save before the stored scene has been restored", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      ctx.setMode("whiteboard")
      await vi.runAllTimersAsync()
      ctx.attachApi()

      // No `whiteboard_loaded` yet. A save here would write an empty board
      // over the stored one.
      ctx.draw(elements(2))
      await vi.advanceTimersByTimeAsync(5000)

      expect(saves(ctx)).toHaveLength(0)
    })

    it("advances expected_version only from the server's ack", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      ctx.setMode("whiteboard")
      await vi.runAllTimersAsync()
      ctx.attachApi()
      ctx.send("whiteboard_loaded", { scene: {}, scene_version: 1 })

      ctx.draw(elements(1))
      await vi.advanceTimersByTimeAsync(1600)
      // Still 1: the client never increments the counter itself.
      expect(saves(ctx)[0][1].expected_version).toBe(1)

      ctx.send("whiteboard_saved", { scene_version: 2 })
      ctx.draw(elements(2))
      await vi.advanceTimersByTimeAsync(1600)
      expect(saves(ctx)[1][1].expected_version).toBe(2)
    })
  })

  describe("stale path", () => {
    // The hook builds the stale notice with `document.createElement`, so the
    // test installs a minimal fake `document` rather than asserting only a
    // boolean flag — a flag alone would stay green for a hook that tells the
    // user nothing.
    let priorDocument

    beforeEach(() => {
      priorDocument = globalThis.document
      globalThis.document = {
        createElement: () => ({
          _attrs: {},
          className: "",
          innerHTML: "",
          setAttribute(n, v) {
            this._attrs[n] = v
          },
          getAttribute(n) {
            return this._attrs[n] ?? null
          },
          // Selector-aware: each distinct selector gets its own stub node,
          // memoized, and only if that selector's attribute actually appears
          // in the markup the hook wrote. A blanket `() => ({...})` hands
          // back a live-looking node for a control that was never rendered —
          // which is precisely the defect this file now guards against.
          _q: {},
          querySelector(sel) {
            const attr = sel.replace(/^\[|\]$/g, "").split("=")[0]
            if (!this.innerHTML.includes(attr)) return null
            this._q[sel] = this._q[sel] || {
              _listeners: {},
              addEventListener(ev, fn) {
                this._listeners[ev] = fn
              },
              click() {
                if (this._listeners.click) this._listeners.click()
              },
            }
            return this._q[sel]
          },
          remove: vi.fn(),
        }),
        documentElement: { getAttribute: () => "light" },
      }
    })

    afterEach(() => {
      globalThis.document = priorDocument
    })

    it("leaves local elements untouched and raises the notice", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      await activate(ctx)

      const drawn = elements(5)
      ctx.draw(drawn)
      ctx.send("whiteboard_stale", { scene_version: 9 })

      // The whole point of the counter: the loser of the race keeps their
      // strokes. Nothing is re-applied, nothing is discarded.
      expect(ctx.hook._elements).toHaveLength(5)
      expect(ctx.hook._elements.map((e) => e.id)).toEqual(
        drawn.map((e) => e.id),
      )
      expect(ctx.excalidrawAPI.updateScene).not.toHaveBeenCalled()
      expect(ctx.hook._stale).toBe(true)
      expect(ctx.hook._root).toBe(ctx.root)
      // The notice is ADDED to the host — the React container is still
      // there beside it, not replaced by it.
      expect(ctx.el.contains(ctx.container)).toBe(true)
      const notice = ctx.hook._staleNotice
      expect(ctx.el.contains(notice)).toBe(true)
      expect(notice.getAttribute("data-whiteboard-notice")).toBe("stale")
      expect(notice.innerHTML).toContain("This board was changed elsewhere")
      expect(notice.innerHTML).toContain("save a copy")
    })

    // The e2e "stale-version conflict, two users" case failed on exactly this
    // clause: the losing window was told the board had moved but given no way
    // to act on it.
    //
    // Asserted on the ELEMENT, never on the word "Reload" — the message
    // string itself reads "...Reload to see the latest...", so a text match
    // passes against a notice carrying no control at all and proves nothing.
    it("offers a reload control that actually reloads the page", async () => {
      const priorWindow = globalThis.window
      const reload = vi.fn()
      globalThis.window = { location: { reload } }

      try {
        const ctx = buildHook()
        ctx.hook.mounted()
        await activate(ctx)
        ctx.draw(elements(5))
        ctx.send("whiteboard_stale", { scene_version: 9 })

        const notice = ctx.hook._staleNotice
        const reloadEl = notice.querySelector(
          '[data-action="whiteboard-reload"]',
        )
        expect(reloadEl).not.toBe(null)
        expect(notice.innerHTML).toContain('data-action="whiteboard-reload"')

        expect(reload).not.toHaveBeenCalled()
        reloadEl.click()
        expect(reload).toHaveBeenCalledTimes(1)

        // Reloading is the user's choice and nothing else: the click must not
        // have discarded their strokes on the way out.
        expect(ctx.hook._elements).toHaveLength(5)
      } finally {
        globalThis.window = priorWindow
      }
    })

    it("raises at most one notice and dismisses it without touching elements", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      await activate(ctx)
      ctx.draw(elements(5))

      ctx.send("whiteboard_stale", { scene_version: 9 })
      const first = ctx.hook._staleNotice
      ctx.send("whiteboard_stale", { scene_version: 10 })
      expect(ctx.hook._staleNotice).toBe(first)

      ctx.hook._dismissStaleNotice()
      expect(ctx.hook._staleNotice).toBe(null)
      expect(ctx.hook._elements).toHaveLength(5)
    })
  })

  describe("restore path", () => {
    it("asks for the stored scene once and applies it exactly once", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      ctx.setMode("whiteboard")
      await flush()
      ctx.attachApi()

      const loads = ctx.pushEvent.mock.calls.filter(
        ([name]) => name === "whiteboard_load",
      )
      expect(loads).toHaveLength(1)

      ctx.send("whiteboard_loaded", {
        scene: { elements: elements(4), appState_subset: { gridSize: 20 } },
        scene_version: 12,
      })

      expect(ctx.excalidrawAPI.updateScene).toHaveBeenCalledTimes(1)
      expect(
        ctx.excalidrawAPI.updateScene.mock.calls[0][0].elements,
      ).toHaveLength(4)
      expect(ctx.hook._version).toBe(12)

      // A second activation must not re-request or re-apply.
      ctx.setMode("gallery")
      ctx.setMode("whiteboard")
      await flush()
      expect(
        ctx.pushEvent.mock.calls.filter(([n]) => n === "whiteboard_load"),
      ).toHaveLength(1)
      expect(ctx.excalidrawAPI.updateScene).toHaveBeenCalledTimes(1)
    })

    it("starts blank on an empty stored scene without calling updateScene", async () => {
      const ctx = buildHook()
      ctx.hook.mounted()
      await activate(ctx, { scene: { elements: [] }, version: 0 })

      expect(ctx.excalidrawAPI.updateScene).not.toHaveBeenCalled()
      // The save gate is still opened — a brand-new board must be savable.
      expect(ctx.hook._restored).toBe(true)
    })

    it("does not echo the restored scene straight back as a save", async () => {
      vi.useFakeTimers()
      try {
        const ctx = buildHook()
        ctx.hook.mounted()
        ctx.setMode("whiteboard")
        await vi.runAllTimersAsync()
        ctx.attachApi()
        ctx.send("whiteboard_loaded", {
          scene: { elements: elements(3) },
          scene_version: 5,
        })
        // Excalidraw fires `onChange` for the scene we just applied.
        ctx.draw(elements(3))
        await vi.advanceTimersByTimeAsync(3000)

        expect(saves(ctx)).toHaveLength(0)
      } finally {
        vi.useRealTimers()
      }
    })
  })

  describe("export to canvas (stage 5)", () => {
    // Drive the server's half of the chain: authorise, then hand back the two
    // presigned URLs the server reserved.
    const reserved = {
      png: { id: "png-id", upload_url: "/chat/attachments/upload/png-token" },
      json: { id: "json-id", upload_url: "/chat/attachments/upload/json-token" },
    }

    async function exportBoard(ctx, reservation = reserved) {
      ctx.send("whiteboard_export_begin", {})
      await flush()
      await flush()
      ctx.send("whiteboard_export_reserved", reservation)
      await flush()
      await flush()
    }

    it("uploads TWO blobs, the PNG and the scene JSON, with correct types", async () => {
      await activate(ctx)
      ctx.draw(elements(3))
      await exportBoard(ctx)

      // Count first: one artefact is the failure mode this stage exists to
      // prevent — a board that becomes a picture of a board.
      expect(ctx.uploads).toHaveLength(2)
      expect(ctx.uploads.map((u) => u.init.headers["content-type"])).toEqual([
        "image/png",
        "application/json",
      ])
      expect(ctx.uploads.map((u) => u.url)).toEqual([
        reserved.png.upload_url,
        reserved.json.upload_url,
      ])
      expect(ctx.uploads.every((u) => u.init.method === "POST")).toBe(true)

      // The JSON body is the authoritative scene, not a stub: it carries the
      // elements that were on the board.
      const scene = JSON.parse(await ctx.uploads[1].init.body.text())
      expect(scene.type).toBe(ctx.api.sceneFileType)
      expect(scene.elements).toHaveLength(3)
      expect(scene.elements.map((e) => e.id)).toEqual(["el-0", "el-1", "el-2"])

      // Sizes are reported to the server BEFORE the upload — that is what it
      // presigns against.
      const [[, payload]] = ctx.pushEvent.mock.calls.filter(
        ([name]) => name === "whiteboard_export",
      )
      expect(payload.png_byte_size).toBeGreaterThan(0)
      expect(payload.json_byte_size).toBeGreaterThan(0)

      expect(uploadedPushes(ctx)).toHaveLength(1)
      expect(uploadedPushes(ctx)[0][1]).toEqual({
        png_attachment_id: "png-id",
        json_attachment_id: "json-id",
      })
    })

    it("does not report an upload the server would turn into a canvas node when the PNG fails", async () => {
      ctx.hook._fetch = vi.fn((url, init) => {
        ctx.uploads.push({ url, init })
        // The PNG is first; a 500 there must stop the whole chain.
        return Promise.resolve({ ok: false, status: 500 })
      })

      await activate(ctx)
      ctx.draw(elements(2))
      await exportBoard(ctx)

      // No `whiteboard_export_uploaded` means the server writes no card. A
      // card whose image 404s is worse than no card.
      expect(uploadedPushes(ctx)).toHaveLength(0)
      // And it stopped at the PNG rather than uploading the JSON anyway.
      expect(ctx.uploads).toHaveLength(1)
    })

    it("does not report an upload when the scene JSON fails", async () => {
      let call = 0
      ctx.hook._fetch = vi.fn((url, init) => {
        ctx.uploads.push({ url, init })
        call += 1
        return Promise.resolve(call === 1 ? { ok: true, status: 200 } : { ok: false, status: 500 })
      })

      await activate(ctx)
      ctx.draw(elements(2))
      await exportBoard(ctx)

      expect(ctx.uploads).toHaveLength(2)
      expect(uploadedPushes(ctx)).toHaveLength(0)
    })

    it("exporting does not re-create the React root", async () => {
      await activate(ctx)
      ctx.draw(elements(2))
      const rootBefore = ctx.hook._root

      // The click that starts an export IS a LiveView re-render (#664/#665):
      // the server re-renders the page, so `updated()` fires on the ignored
      // host. Neither that nor the export itself may touch the root.
      ctx.hook.updated()
      await exportBoard(ctx)
      ctx.hook.updated()

      expect(ctx.hook._root).toBe(rootBefore)
      expect(ctx.api.createRoot).toHaveBeenCalledTimes(1)
      expect(ctx.root.render).toHaveBeenCalledTimes(1)
      expect(ctx.el.contains(ctx.container)).toBe(true)
      expect(ctx.excalidrawAPI.updateScene).not.toHaveBeenCalled()
    })

    it("exports nothing when the board was never opened", async () => {
      // No island, no pixels. Not an error — just nothing to send.
      ctx.send("whiteboard_export_begin", {})
      await flush()

      expect(ctx.api.exportToBlob).not.toHaveBeenCalled()
      expect(
        ctx.pushEvent.mock.calls.filter(([name]) => name === "whiteboard_export"),
      ).toHaveLength(0)
    })
  })
})

function uploadedPushes(ctx) {
  return ctx.pushEvent.mock.calls.filter(
    ([name]) => name === "whiteboard_export_uploaded",
  )
}

function saves(ctx) {
  return ctx.pushEvent.mock.calls.filter(([name]) => name === "whiteboard_save")
}
