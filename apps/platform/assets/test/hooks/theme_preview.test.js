import { describe, it, expect, vi } from "vitest"
import {
  ALLOWED_VARS,
  handleMessage,
  safeValue,
  sanitizeVars,
  shouldInstall,
} from "../../js/hooks/theme_preview_receiver.js"
import { deskScale, postPreview, previewMessage } from "../../js/hooks/theme_editor.js"

/**
 * The theme editor's live preview (task 01a1557a-fe9b stage 2): the editor
 * hook posts {type: "burrow-theme", vars, mode} to its frames with the page's
 * own origin, and the receiver in the frame applies only allowlisted custom
 * properties from a same-origin parent. The vitest suite runs in plain node,
 * so the DOM is a stub that records setProperty calls.
 */

const ORIGIN = "http://localhost:4000"

function stubRoot() {
  const set = {}
  const attrs = {}
  return {
    set,
    attrs,
    style: { setProperty: (k, v) => (set[k] = v) },
    setAttribute: (k, v) => (attrs[k] = v),
  }
}

const parent = { name: "parent" }

function event(over = {}) {
  return {
    origin: ORIGIN,
    source: parent,
    data: {
      type: "burrow-theme",
      mode: "dark",
      vars: { "--color-base-200": "#112233", "--subtle": "color-mix(in oklab, var(--color-base-content) 55%, transparent)" },
    },
    ...over,
  }
}

describe("handleMessage", () => {
  it("applies allowlisted vars and the mode from a same-origin parent", () => {
    const root = stubRoot()
    expect(handleMessage(event(), { origin: ORIGIN, root, parent })).toBe(true)
    expect(root.set["--color-base-200"]).toBe("#112233")
    expect(root.set["--subtle"]).toMatch(/^color-mix/)
    expect(root.attrs["data-theme"]).toBe("dark")
  })

  it("ignores a message from another origin", () => {
    const root = stubRoot()
    expect(handleMessage(event({ origin: "https://evil.example" }), { origin: ORIGIN, root, parent })).toBe(false)
    expect(root.set).toEqual({})
    expect(root.attrs).toEqual({})
  })

  it("ignores a message from a window that is not the parent", () => {
    const root = stubRoot()
    expect(handleMessage(event({ source: {} }), { origin: ORIGIN, root, parent })).toBe(false)
    expect(root.set).toEqual({})
  })

  it("ignores another type and an unknown mode", () => {
    const root = stubRoot()
    expect(handleMessage(event({ data: { ...event().data, type: "other" } }), { origin: ORIGIN, root, parent })).toBe(false)
    expect(handleMessage(event({ data: { ...event().data, mode: "sepia" } }), { origin: ORIGIN, root, parent })).toBe(false)
    expect(root.set).toEqual({})
  })

  it("drops names off the allowlist and unsafe values", () => {
    const root = stubRoot()
    const vars = {
      "--color-base-100": "#000000",
      "--evil": "#ffffff",
      "background-image": "url(x)",
      "--color-base-300": "url(https://evil.example/x.png)",
      "--edge": "red; background: red",
      "--font-sans": '"Public Sans", system-ui, sans-serif',
    }
    handleMessage(event({ data: { type: "burrow-theme", mode: "light", vars } }), { origin: ORIGIN, root, parent })
    expect(Object.keys(root.set).sort()).toEqual(["--color-base-100", "--font-sans"])
  })
})

describe("sanitizeVars and safeValue", () => {
  it("allows color-mix() and var() only", () => {
    expect(safeValue("color-mix(in oklab, var(--color-base-content) 40%, transparent)")).toBe(true)
    expect(safeValue("image-set(x)")).toBe(false)
    expect(safeValue("expression(alert(1))")).toBe(false)
    expect(safeValue("12px")).toBe(true)
  })

  it("returns nothing for a non-object", () => {
    expect(sanitizeVars(null)).toEqual([])
    expect(sanitizeVars(["--edge", "#000"])).toEqual([])
  })

  it("covers the agent slots", () => {
    expect(ALLOWED_VARS.has("--ag-lime-text")).toBe(true)
  })
})

describe("shouldInstall", () => {
  const win = (framed, search) => {
    const w = { location: { search } }
    w.parent = framed ? {} : w
    return w
  }

  it("installs only when framed with theme_preview=1", () => {
    expect(shouldInstall(win(true, "?theme_preview=1"))).toBe(true)
    expect(shouldInstall(win(false, "?theme_preview=1"))).toBe(false)
    expect(shouldInstall(win(true, ""))).toBe(false)
    expect(shouldInstall(win(true, "?theme_preview=0"))).toBe(false)
  })
})

describe("theme editor hook", () => {
  it("posts the burrow-theme message with the given origin", () => {
    const postMessage = vi.fn()
    const frame = { contentWindow: { postMessage } }
    const payload = { vars: { "--edge": "#383b42" }, mode: "dark" }

    expect(postPreview(frame, payload, ORIGIN)).toBe(true)
    expect(postMessage).toHaveBeenCalledWith(previewMessage(payload), ORIGIN)
    expect(previewMessage(payload)).toEqual({ type: "burrow-theme", vars: payload.vars, mode: "dark" })
  })

  it("skips a frame with no window", () => {
    expect(postPreview({ contentWindow: null }, { vars: {}, mode: "dark" }, ORIGIN)).toBe(false)
  })

  it("scales the desktop frame like the masters' fitDesk", () => {
    expect(deskScale(902 - 380)).toBeCloseTo(0.35, 5)
    expect(deskScale(900)).toBeCloseTo((900 - 429) / 1280, 5)
    expect(deskScale(5000)).toBe(1)
  })
})
