import { describe, it, expect, beforeEach, afterEach } from "vitest"
import UploadButton from "../../js/hooks/upload_button.js"

const FILE_INPUT_SELECTOR = '#upload-send-form input[type="file"]'

/**
 * The mobile + button: tap -> native picker -> pick -> the staging dialog
 * ("upload_dialog_open") must open. Production bug 2026-10-10 (Android Chrome
 * and the Burrow WebView): the picker opened, the image was picked, and the
 * dialog never appeared. Two causes, both pinned here:
 *
 *   1. LiveView's window `input` listener (LiveUploader.trackFiles) sets
 *      `input.value = null` on a `multiple` file input BEFORE `change` fires,
 *      so the change handler's `input.files.length > 0` guard (added in
 *      #1219) was always false on a fresh page.
 *   2. `live_file_input`'s id is the upload ref, random per LiveView mount,
 *      so a socket rejoin replaces the input element; a listener bound to the
 *      element at mount() never fired again (since #276).
 *
 * vitest runs in the `node` env here, so the DOM is a small fake that
 * dispatches an event to the target's own listeners, then to `document`'s.
 */

function fakeInput() {
  const listeners = {}
  return {
    type: "file",
    files: [],
    clicks: 0,
    matches: (sel) => sel === FILE_INPUT_SELECTOR,
    click() {
      this.clicks += 1
    },
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    _listeners: listeners,
  }
}

function fakeDocument() {
  const listeners = {}
  return {
    current: null,
    querySelector(sel) {
      return sel === FILE_INPUT_SELECTOR ? this.current : null
    },
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    dispatch(target, type) {
      const e = { type, target, stopPropagation() {} }
      for (const fn of [...((target._listeners || {})[type] || [])]) fn(e)
      for (const fn of [...(listeners[type] || [])]) fn(e)
    },
    _listeners: listeners,
  }
}

function mountHook({ coarse = true } = {}) {
  const pushed = []
  const buttonListeners = {}
  const hook = Object.create(UploadButton)
  hook.el = {
    addEventListener(type, fn) {
      ;(buttonListeners[type] ||= []).push(fn)
    },
    removeEventListener(type, fn) {
      buttonListeners[type] = (buttonListeners[type] || []).filter((f) => f !== fn)
    },
  }
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  globalThis.window = { matchMedia: () => ({ matches: coarse }) }
  hook.mounted()
  const tap = () => {
    const e = { stopPropagation() {} }
    for (const fn of buttonListeners.click || []) fn(e)
  }
  return { hook, pushed, tap }
}

describe("UploadButton (mobile + button)", () => {
  let savedDocument, savedWindow
  beforeEach(() => {
    savedDocument = globalThis.document
    savedWindow = globalThis.window
    globalThis.document = fakeDocument()
    globalThis.document.current = fakeInput()
  })
  afterEach(() => {
    globalThis.document = savedDocument
    globalThis.window = savedWindow
  })

  it("opens the dialog after a pick even though LiveView already emptied input.files", () => {
    const { pushed, tap } = mountHook()
    tap()
    expect(document.current.clicks).toBe(1)
    // What a real browser leaves behind by `change`: LiveView's `input`
    // listener took the File and set input.value = null.
    document.current.files = []
    document.dispatch(document.current, "change")
    expect(pushed).toEqual([["upload_dialog_open", {}]])
  })

  it("opens the dialog when the file input was replaced after mount (socket rejoin)", () => {
    const { pushed, tap } = mountHook()
    // Rejoin: new upload ref -> new id -> morphdom swaps the element.
    document.current = fakeInput()
    tap()
    expect(document.current.clicks).toBe(1)
    document.current.files = [{ name: "photo.jpg", size: 2_000_000, type: "image/jpeg" }]
    document.dispatch(document.current, "change")
    expect(pushed).toEqual([["upload_dialog_open", {}]])
  })

  it("ignores change events from other inputs", () => {
    const { pushed } = mountHook()
    const other = { type: "text", matches: () => false }
    document.dispatch(other, "change")
    expect(pushed).toEqual([])
  })

  it("stops listening when destroyed", () => {
    const { hook, pushed } = mountHook()
    hook.destroyed()
    document.dispatch(document.current, "change")
    expect(pushed).toEqual([])
  })

  it("leaves desktop (fine pointer) to phx-click: no change listener", () => {
    const { pushed } = mountHook({ coarse: false })
    document.dispatch(document.current, "change")
    expect(pushed).toEqual([])
  })
})
