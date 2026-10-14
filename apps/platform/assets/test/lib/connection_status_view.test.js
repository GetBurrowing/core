import { describe, it, expect, beforeEach } from "vitest"
import {
  createConnectionStatusView,
  fingerprint,
  PILL_TEXT,
} from "../../js/lib/connection_status_view.js"

/**
 * The onState-to-DOM mapping of the quiet reconnect slot (task 01a12b10
 * stage 2). There is no DOM environment, so a tiny fake document holds fake
 * elements; execJS is recorded instead of run.
 */

function fakeEl({ dataset = {}, hidden = false, text = "", children = {} } = {}) {
  const attrs = new Set(hidden ? ["hidden"] : [])
  const classes = new Set()
  return {
    dataset: { ...dataset },
    textContent: text,
    childElementCount: Object.keys(children).length,
    offsetWidth: 0,
    hasAttribute: (name) => attrs.has(name),
    setHidden(v) {
      v ? attrs.add("hidden") : attrs.delete("hidden")
    },
    querySelector: (sel) => children[sel] || null,
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
  }
}

function setup() {
  const label = fakeEl()
  const slot = fakeEl({
    dataset: { state: "idle" },
    children: { "[data-connection-status-text]": label },
  })
  const client = fakeEl({ dataset: { escalate: "ESC-C", clear: "CLR-C" }, hidden: true })
  const server = fakeEl({ dataset: { escalate: "ESC-S", clear: "CLR-S" }, hidden: true })
  const main = fakeEl({ text: "hello", children: { a: {}, b: {} } })
  const els = {
    "#connection-status": slot,
    "#client-error": client,
    "#server-error": server,
    "[data-scroll-container]": main,
  }
  const doc = { querySelector: (sel) => els[sel] || null }
  const calls = []
  // Mirror what the JS commands do to the hidden attribute.
  const execJS = (el, cmd) => {
    calls.push(cmd)
    el.setHidden(cmd.startsWith("CLR"))
  }
  const view = createConnectionStatusView({ doc, execJS })
  return { view, slot, label, client, server, main, calls, els, doc }
}

describe("connection status view", () => {
  let t
  beforeEach(() => {
    t = setup()
  })

  it("reconnecting sets data-state and the pill text, and touches no toast", () => {
    t.view.render({ state: "reconnecting", kind: "client" })
    expect(t.slot.dataset.state).toBe("reconnecting")
    expect(t.label.textContent).toBe("Reconnecting…")
    expect(t.calls).toEqual([])
  })

  it("up_to_date reads Up to date", () => {
    t.view.render({ state: "reconnecting", kind: "client" })
    t.view.render({ state: "up_to_date", kind: null })
    expect(t.slot.dataset.state).toBe("up_to_date")
    expect(t.label.textContent).toBe(PILL_TEXT.up_to_date)
  })

  it("idle and pending keep the last text (no extra announcement) and set the state", () => {
    t.view.render({ state: "up_to_date" })
    t.view.render({ state: "idle" })
    expect(t.slot.dataset.state).toBe("idle")
    expect(t.label.textContent).toBe("Up to date")
    t.view.render({ state: "pending", kind: "client" })
    expect(t.slot.dataset.state).toBe("pending")
  })

  it("escalated client runs data-escalate on #client-error only", () => {
    t.view.render({ state: "escalated", kind: "client" })
    expect(t.calls).toEqual(["ESC-C"])
    expect(t.client.hasAttribute("hidden")).toBe(false)
    expect(t.server.hasAttribute("hidden")).toBe(true)
    expect(t.slot.dataset.state).toBe("escalated")
  })

  it("escalated server runs data-escalate on #server-error only", () => {
    t.view.render({ state: "escalated", kind: "server" })
    expect(t.calls).toEqual(["ESC-S"])
  })

  it("a kind change while escalated swaps the toast, never shows both", () => {
    t.view.render({ state: "escalated", kind: "server" })
    t.view.render({ state: "escalated", kind: "client" })
    expect(t.calls).toEqual(["ESC-S", "ESC-C", "CLR-S"])
    expect(t.client.hasAttribute("hidden")).toBe(false)
    expect(t.server.hasAttribute("hidden")).toBe(true)
  })

  it("leaving escalated runs data-clear on the shown toast", () => {
    t.view.render({ state: "escalated", kind: "client" })
    t.view.render({ state: "up_to_date" })
    expect(t.calls).toEqual(["ESC-C", "CLR-C"])
    expect(t.client.hasAttribute("hidden")).toBe(true)
  })

  it("non-escalated states never run a clear on an already hidden toast", () => {
    t.view.render({ state: "reconnecting", kind: "client" })
    t.view.render({ state: "up_to_date" })
    t.view.render({ state: "idle" })
    expect(t.calls).toEqual([])
  })

  it("reassert puts back a data-state the server patch overwrote", () => {
    t.view.render({ state: "up_to_date" })
    t.slot.dataset.state = "idle" // what LiveView's mergeAttrs does on a patch
    expect(t.view.reassert()).toBe(true)
    expect(t.slot.dataset.state).toBe("up_to_date")
    expect(t.view.reassert()).toBe(false)
  })

  it("survives a page with no slot or toasts", () => {
    const view = createConnectionStatusView({ doc: { querySelector: () => null }, execJS: () => {} })
    expect(() => view.render({ state: "escalated", kind: "client" })).not.toThrow()
    expect(view.reassert()).toBe(false)
  })

  it("settle adds the settle class to the refreshed region", () => {
    t.view.settle()
    expect(t.main.classList.contains("reconnect-settle")).toBe(true)
  })

  it("fingerprint is text length plus child count, null without a region", () => {
    expect(fingerprint(t.doc)).toBe("5:2")
    expect(fingerprint({ querySelector: () => null })).toBe(null)
  })
})
