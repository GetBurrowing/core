import { describe, it, expect } from "vitest"
import { installDeadViewTabBar } from "../../js/lib/dead_view_tab_bar.js"

// The gaming shell (/play, /games/*) renders the workspace's phone tab bar on
// a dead view; its TabPill and NativeTabBar hooks are mounted by hand.

const el = inLiveView => ({
  dataset: {},
  closest: sel => (sel === "[data-phx-session]" && inLiveView ? {} : null)
})

describe("installDeadViewTabBar", () => {
  it("mounts each named hook on its elements outside a LiveView, once each", () => {
    const calls = []
    const hook = name => ({
      mounted() {
        calls.push([name, this.el])
      }
    })
    const bar = el(false)
    const bridge = el(false)
    const liveBar = el(true)
    const doc = {
      querySelectorAll: sel =>
        ({
          "[phx-hook='TabPill']": [bar, liveBar],
          "[phx-hook='NativeTabBar']": [bridge]
        })[sel] || []
    }
    const hooks = { TabPill: hook("TabPill"), NativeTabBar: hook("NativeTabBar") }

    installDeadViewTabBar(doc, hooks)
    installDeadViewTabBar(doc, hooks)

    expect(calls).toEqual([
      ["TabPill", bar],
      ["NativeTabBar", bridge]
    ])
  })

  it("does nothing without a document", () => {
    expect(installDeadViewTabBar(undefined)).toEqual([])
  })
})
