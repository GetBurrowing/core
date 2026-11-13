import { describe, it, expect } from "vitest"
import { layoutVariant } from "../../js/hooks/install_switch_web.js"
import { installDeadViewInstallSwitch } from "../../js/lib/dead_view_install_switch.js"

// The gaming shell's brand switcher (`data-variant="play"`) on the Console
// Glass dead views (/play, /games/*).

const button = variant => ({ getAttribute: n => (n === "data-variant" ? variant : null) })
const win = matches => ({ matchMedia: q => ({ matches: q === "(min-width: 768px)" && matches }) })

describe("layoutVariant", () => {
  it("keeps the phone and sidebar buttons as they were", () => {
    expect(layoutVariant(button("sidebar"), win(false))).toBe("sidebar")
    expect(layoutVariant(button("phone"), win(true))).toBe("phone")
  })

  it("lays the play brand out as the sidebar on desktop and the top bar on a phone", () => {
    expect(layoutVariant(button("play"), win(true))).toBe("sidebar")
    expect(layoutVariant(button("play"), win(false))).toBe("phone")
    expect(layoutVariant(button("play"), {})).toBe("phone")
  })
})

describe("installDeadViewInstallSwitch", () => {
  const switchEl = inLiveView => ({
    dataset: {},
    closest: sel => (sel === "[data-phx-session]" && inLiveView ? {} : null)
  })

  const docWith = els => ({
    querySelectorAll: sel => (sel === "[phx-hook='NativeInstallSwitch']" ? els : [])
  })

  it("mounts the hook on switches outside a LiveView, once each", () => {
    const calls = []
    const hook = {
      mounted() {
        calls.push(this.el)
      }
    }
    const dead = switchEl(false)
    const live = switchEl(true)
    const doc = docWith([dead, live])

    installDeadViewInstallSwitch(doc, hook)
    installDeadViewInstallSwitch(doc, hook)

    expect(calls).toEqual([dead])
  })

  it("does nothing without a document", () => {
    expect(installDeadViewInstallSwitch(undefined)).toEqual([])
  })
})
