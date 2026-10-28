import {describe, it, expect, vi} from "vitest"
import {installInAppLinks} from "../../js/lib/in_app_links.js"

function setup(href, kind = "path", attrs = {}) {
  let click
  const doc = {addEventListener: vi.fn((_, fn) => { click = fn }), removeEventListener: vi.fn()}
  const win = {location: {href: "https://app.example.test/chat/general", origin: "https://app.example.test", assign: vi.fn()}}
  const anchor = {getAttribute: key => key === "href" ? href : attrs[key], hasAttribute: key => key in attrs}
  const event = {button: 0, target: {closest: selector => kind === "path" ? anchor : null}, preventDefault: vi.fn(), stopPropagation: vi.fn()}
  const socket = {historyRedirect: vi.fn()}
  const remove = installInAppLinks(socket, doc, win)
  return {doc, win, socket, event, anchor, click: () => click(event), remove}
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
    const t = setup("/chat/attachments/abc")
    t.socket.historyRedirect = undefined
    t.click()
    expect(t.win.location.assign).toHaveBeenCalledWith("/chat/attachments/abc")
  })
  it("leaves blocked links, downloads, and secondary or handled clicks alone", () => {
    for (const configure of [t => { t.event.button = 1 }, t => { t.event.defaultPrevented = true }]) {
      const t = setup("/tasks/abc"); configure(t); t.click()
      expect(t.event.preventDefault).not.toHaveBeenCalled()
    }
    for (const t of [setup("#blocked"), setup("/files/abc", "path", {download: ""})]) {
      t.click(); expect(t.event.preventDefault).not.toHaveBeenCalled()
    }
  })
  it("installs one document listener and provides cleanup", () => {
    const t = setup("/tasks/abc")
    expect(t.doc.addEventListener).toHaveBeenCalledOnce()
    t.remove()
    expect(t.doc.removeEventListener).toHaveBeenCalledWith("click", expect.any(Function))
  })
})
