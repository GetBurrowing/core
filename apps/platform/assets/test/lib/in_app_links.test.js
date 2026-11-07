import {describe, it, expect, vi} from "vitest"
import {installInAppLinks} from "../../js/lib/in_app_links.js"

function setup(href, kind = "path", attrs = {}, img = null) {
  let click
  const doc = {addEventListener: vi.fn((_, fn) => { click = fn }), removeEventListener: vi.fn()}
  const win = {location: {href: "https://app.example.test/chat/general", origin: "https://app.example.test", assign: vi.fn()}}
  const anchor = {getAttribute: key => key === "href" ? href : (attrs[key] ?? null), hasAttribute: key => key in attrs,
    querySelector: sel => sel === "img" ? img : null}
  const event = {button: 0, target: {closest: selector => selector === "a[href]" || kind === "path" ? anchor : null}, preventDefault: vi.fn(), stopPropagation: vi.fn()}
  const socket = {historyRedirect: vi.fn()}
  const openImageLayer = vi.fn()
  const remove = installInAppLinks(socket, doc, win, {openImageLayer})
  return {doc, win, socket, event, anchor, openImageLayer, click: () => click(event), remove}
}

describe("shared in-app link delegation", () => {
  it.each(["/tasks/abc", "/chat/general?thread=abc#reply"])("navigates relative or alias-rewritten path %s through LiveView", href => {
    // Alias rewriting is performed by ContentRenderer before this DOM handler.
    const t = setup(href)
    t.click()
    expect(t.event.preventDefault).toHaveBeenCalledOnce()
    expect(t.event.stopPropagation).toHaveBeenCalledOnce()
    expect(t.socket.historyRedirect).toHaveBeenCalledWith(t.event, href, "push", null, t.anchor)
    expect(t.win.location.assign).not.toHaveBeenCalled()
  })
  it("leaves external _blank links untouched, including a misleading marker", () => {
    const t = setup("https://example.org/tasks/abc", "path", {target: "_blank"})
    t.click()
    expect(t.event.preventDefault).not.toHaveBeenCalled()
    expect(t.socket.historyRedirect).not.toHaveBeenCalled()
  })
  it.each(["metaKey", "ctrlKey", "shiftKey", "altKey"])("preserves %s", key => {
    const t = setup("/tasks/abc")
    t.event[key] = true
    t.click()
    expect(t.event.preventDefault).not.toHaveBeenCalled()
  })
  it.each(["canvas", "prototype", null])("leaves %s links to their existing handlers", kind => {
    const t = setup("/canvases/abc", kind)
    t.click()
    expect(t.event.preventDefault).not.toHaveBeenCalled()
  })
  it("falls back in the current window without LiveView", () => {
    const t = setup("/tasks/abc")
    t.socket.historyRedirect = undefined
    t.click()
    expect(t.win.location.assign).toHaveBeenCalledWith("/tasks/abc")
  })
  it("leaves downloads and secondary or handled clicks alone", () => {
    for (const configure of [t => { t.event.button = 1 }, t => { t.event.defaultPrevented = true }]) {
      const t = setup("/tasks/abc"); configure(t); t.click()
      expect(t.event.preventDefault).not.toHaveBeenCalled()
    }
    for (const t of [setup("/files/abc", "path", {download: ""})]) {
      t.click(); expect(t.event.preventDefault).not.toHaveBeenCalled()
    }
  })
  it.each(["#blocked", "#blocked:alert(1)"])("prevents sanitized unsafe link %s from opening a tab", href => {
    const t = setup(href, null, {target: "_blank"})
    t.click()
    expect(t.event.preventDefault).toHaveBeenCalledOnce()
    expect(t.event.stopPropagation).toHaveBeenCalledOnce()
    expect(t.socket.historyRedirect).not.toHaveBeenCalled()
    expect(t.win.location.assign).not.toHaveBeenCalled()
  })
  it("installs one document listener and provides cleanup", () => {
    const t = setup("/tasks/abc")
    expect(t.doc.addEventListener).toHaveBeenCalledOnce()
    t.remove()
    expect(t.doc.removeEventListener).toHaveBeenCalledWith("click", expect.any(Function))
  })

  describe("raw assets never navigate the app", () => {
    const UUID = "01a1b67d-073f-7000-af1c-29cb60de81e4"

    it("a data-image-viewer /chat/attachments/<uuid> anchor opens an image layer, not a navigation", () => {
      const t = setup(`/chat/attachments/${UUID}`, "path", {"data-image-viewer": ""})
      t.click()
      expect(t.event.preventDefault).toHaveBeenCalledOnce()
      expect(t.socket.historyRedirect).not.toHaveBeenCalled()
      expect(t.win.location.assign).not.toHaveBeenCalled()
      expect(t.openImageLayer).toHaveBeenCalledOnce()
      expect(t.openImageLayer.mock.calls[0][0]).toMatchObject({
        href: `/chat/attachments/${UUID}`, mode: "image", returnFocusTo: t.anchor,
      })
    })

    it("an anchor wrapping an <img> is an image anchor too", () => {
      const img = {getAttribute: k => (k === "alt" ? "a screenshot" : null)}
      const t = setup(`/chat/attachments/${UUID}`, "path", {}, img)
      t.click()
      expect(t.socket.historyRedirect).not.toHaveBeenCalled()
      expect(t.openImageLayer.mock.calls[0][0]).toMatchObject({mode: "image", alt: "a screenshot"})
    })

    it("a non-image raw attachment opens the layer in file mode", () => {
      const t = setup(`/chat/attachments/${UUID}`, "path", {"data-filename": "spec.pdf"})
      t.click()
      expect(t.socket.historyRedirect).not.toHaveBeenCalled()
      expect(t.openImageLayer.mock.calls[0][0]).toMatchObject({mode: "file", filename: "spec.pdf"})
    })

    it("a /files/blob/<id> anchor does not navigate", () => {
      const t = setup("/files/blob/abc123")
      t.click()
      expect(t.event.preventDefault).toHaveBeenCalledOnce()
      expect(t.socket.historyRedirect).not.toHaveBeenCalled()
      expect(t.win.location.assign).not.toHaveBeenCalled()
      expect(t.openImageLayer).toHaveBeenCalledOnce()
    })

    it("without LiveView a raw asset still never goes through location.assign", () => {
      const t = setup(`https://app.example.test/chat/attachments/${UUID}`, "path", {"data-image-viewer": ""})
      t.socket.historyRedirect = undefined
      t.click()
      expect(t.win.location.assign).not.toHaveBeenCalled()
      expect(t.openImageLayer).toHaveBeenCalledOnce()
    })

    it("an ordinary same-install page link still goes through historyRedirect", () => {
      const t = setup("/chat/general")
      t.click()
      expect(t.socket.historyRedirect).toHaveBeenCalledOnce()
      expect(t.openImageLayer).not.toHaveBeenCalled()
    })
  })
})
