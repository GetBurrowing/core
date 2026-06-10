import { describe, it, expect, beforeEach, afterEach } from "vitest"
import EmbedCanvasScale from "../../js/hooks/embed_canvas_scale.js"

/**
 * Tests for the `EmbedCanvasScale` hook's `updated()` live-update path.
 *
 * Bug fixed: after PR #424 made canvas panes live-refresh on the
 * `:canvas_patched` PubSub, patching an `embed`-kind canvas's `srcdoc`
 * stopped propagating to the iframe. The wrapper carries
 * `phx-update="ignore"` so morphdom doesn't recurse into the iframe child;
 * the wrapper's `data-srcdoc` attribute updates fine but the iframe stays
 * frozen on the old content. The hook's `updated()` must copy the new
 * `dataset.srcdoc` onto the iframe's `srcdoc` PROPERTY (forcing the
 * browser to reload it), and gate duplicate writes so non-srcdoc patches
 * don't needlessly reload the iframe.
 *
 * The hook runs in vitest's default `node` env (no jsdom), so we build a
 * minimal fake wrapper + iframe. Recording every srcdoc write lets us
 * assert (a) the new srcdoc IS written on a real change, and (b) the
 * iframe is NOT rewritten when only non-srcdoc dataset values change.
 */

// ── Fakes ──────────────────────────────────────────────────────────────

function fakeIframe(initialSrcdoc = "") {
  const iframe = {
    style: {},
    _srcdocWrites: [],
    get srcdoc() {
      return this._srcdoc
    },
    set srcdoc(v) {
      this._srcdoc = v
      this._srcdocWrites.push(v)
    },
  }
  iframe._srcdoc = initialSrcdoc
  return iframe
}

function fakeWrapper({ srcdoc = "", width = 600, height = 400, minScale } = {}) {
  const wrapper = {
    dataset: {
      srcdoc,
      declaredWidth: String(width),
      declaredHeight: String(height),
    },
    style: {},
    clientWidth: 800,
    _iframe: null,
    _expandBtn: null,
    querySelector(sel) {
      if (sel === "iframe") return this._iframe
      if (sel === "[data-embed-expand]") return this._expandBtn
      return null
    },
  }
  if (minScale !== undefined) wrapper.dataset.minScale = String(minScale)
  return wrapper
}

function buildHook(el) {
  const hook = Object.create(EmbedCanvasScale)
  hook.el = el
  return hook
}

// ── Tests ──────────────────────────────────────────────────────────────

describe("EmbedCanvasScale — updated() propagates srcdoc to iframe", () => {
  let priorRO
  let priorWindow

  beforeEach(() => {
    // Hook prefers ResizeObserver; provide a no-op so the resize branch
    // doesn't try to add a window listener that pulls in globalThis.window.
    priorRO = globalThis.ResizeObserver
    globalThis.ResizeObserver = class {
      observe() {}
      disconnect() {}
    }
    priorWindow = globalThis.window
    globalThis.window = priorWindow || {}
  })

  afterEach(() => {
    globalThis.ResizeObserver = priorRO
    globalThis.window = priorWindow
  })

  it("writes the new srcdoc to iframe.srcdoc on dataset change", () => {
    const srcA = "<!doctype html><html><body style=background:red>v1</body></html>"
    const srcB = "<!doctype html><html><body style=background:blue>v2</body></html>"

    const wrapper = fakeWrapper({ srcdoc: srcA })
    const iframe = fakeIframe(srcA)
    wrapper._iframe = iframe

    const hook = buildHook(wrapper)
    hook.mounted()

    // After mount, the hook has only queried srcdoc — no writes yet.
    expect(iframe._srcdocWrites).toEqual([])

    // The server re-renders with new srcdoc — morphdom patches dataset
    // but leaves the iframe alone (phx-update=ignore wrapper).
    wrapper.dataset.srcdoc = srcB
    hook.updated()

    expect(iframe._srcdocWrites).toEqual([srcB])
    expect(iframe.srcdoc).toBe(srcB)
  })

  it("does NOT rewrite iframe.srcdoc when dataset.srcdoc is unchanged", () => {
    const src = "<!doctype html><html><body>same</body></html>"
    const wrapper = fakeWrapper({ srcdoc: src })
    const iframe = fakeIframe(src)
    wrapper._iframe = iframe

    const hook = buildHook(wrapper)
    hook.mounted()

    // A patch arrives that changes width but NOT srcdoc (e.g. someone
    // resized the embed node's declared dims). The iframe must not be
    // reloaded — that would flash a blank frame for no reason.
    wrapper.dataset.declaredWidth = "900"
    hook.updated()

    expect(iframe._srcdocWrites).toEqual([])
  })

  it("refreshes cached dims so a subsequent applyScale sees the new size", () => {
    const wrapper = fakeWrapper({ srcdoc: "x", width: 600, height: 400 })
    const iframe = fakeIframe("x")
    wrapper._iframe = iframe
    wrapper.clientWidth = 600

    const hook = buildHook(wrapper)
    hook.mounted()
    expect(hook.declaredWidth).toBe(600)

    // Embed-node props patched: declared width grew to 1200.
    wrapper.dataset.declaredWidth = "1200"
    wrapper.dataset.declaredHeight = "800"
    hook.updated()

    expect(hook.declaredWidth).toBe(1200)
    expect(hook.declaredHeight).toBe(800)
    // applyScale ran with the new dims — scale = clientWidth(600)/1200 = 0.5
    expect(iframe.style.width).toBe("1200px")
    expect(iframe.style.transform).toBe("scale(0.5)")
  })

  it("no-ops cleanly when the iframe is missing", () => {
    const wrapper = fakeWrapper({ srcdoc: "x" })
    wrapper._iframe = null

    const hook = buildHook(wrapper)
    // Hook's mounted() returns early when iframe is null and never sets
    // up cached state. Calling updated() in that pathological case must
    // not throw.
    hook.mounted()

    wrapper.dataset.srcdoc = "y"
    expect(() => hook.updated()).not.toThrow()
  })

  it("survives back-to-back srcdoc patches without dropping writes", () => {
    const wrapper = fakeWrapper({ srcdoc: "A" })
    const iframe = fakeIframe("A")
    wrapper._iframe = iframe

    const hook = buildHook(wrapper)
    hook.mounted()

    wrapper.dataset.srcdoc = "B"
    hook.updated()
    wrapper.dataset.srcdoc = "C"
    hook.updated()
    // A second updated with no change must not produce another write.
    hook.updated()

    expect(iframe._srcdocWrites).toEqual(["B", "C"])
  })
})
