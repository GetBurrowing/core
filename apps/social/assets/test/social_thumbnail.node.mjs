import test from "node:test"
import assert from "node:assert/strict"
import Hooks from "../js/extension.js"
const SocialThumbnail = Hooks.SocialThumbnail

function mount(tagName, state = {}) {
  assert.equal(typeof SocialThumbnail?.mounted, "function", "thumbnail hook is registered")
  const media = Object.assign(new EventTarget(), { tagName, complete: false, naturalWidth: 0, error: null }, state)
  const button = { style: {} }
  const el = { style: {}, querySelector: () => media, parentElement: button }
  const hook = { ...SocialThumbnail, el }
  hook.mounted()
  return { hook, media, el, button }
}

for (const tagName of ["IMG", "VIDEO"]) {
  test(`${tagName} request/decode errors collapse the thumbnail without hiding its button`, () => {
    const { media, el, button } = mount(tagName)
    assert.equal(el.style.display, undefined)
    media.dispatchEvent(new Event("error"))
    assert.equal(el.style.display, "none")
    assert.equal(button.style.display, undefined)
  })
}

test("an image that failed before hook mount is collapsed", () => {
  const { el } = mount("IMG", { complete: true, naturalWidth: 0 })
  assert.equal(el.style.display, "none")
})

test("a decoded cached image remains visible", () => {
  const { el } = mount("IMG", { complete: true, naturalWidth: 72 })
  assert.equal(el.style.display, undefined)
})

test("a video that failed before hook mount is collapsed", () => {
  const { el } = mount("VIDEO", { error: { code: 4 } })
  assert.equal(el.style.display, "none")
})

test("destroy removes the listener", () => {
  const { hook, media, el } = mount("IMG")
  hook.destroyed()
  media.dispatchEvent(new Event("error"))
  assert.equal(el.style.display, undefined)
})
