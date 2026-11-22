import test from "node:test"
import assert from "node:assert/strict"
import SocialIdeas from "../js/hooks/social_ideas.js"

function mount() {
  const handlers = {}
  const hook = { handleEvent: (name, fn) => { handlers[name] = fn } }
  return { hook, handlers }
}

test("ideas:focus focuses the element by id", () => {
  const focused = []
  globalThis.requestAnimationFrame = (fn) => fn()
  globalThis.document = { getElementById: (id) => (id === "idea-unselect-1" ? { focus: () => focused.push(id) } : null) }
  const { hook, handlers } = mount()
  SocialIdeas.mounted.call(hook)

  handlers["ideas:focus"]({ id: "idea-unselect-1" })
  handlers["ideas:focus"]({ id: "missing" })
  assert.deepEqual(focused, ["idea-unselect-1"])
})

test("the hook owns no address: no ideas:url handler, no popstate listener, no history call", () => {
  const listened = []
  const history = []
  globalThis.requestAnimationFrame = (fn) => fn()
  globalThis.window = {
    history: { pushState: (...a) => history.push(["pushState", a]), replaceState: (...a) => history.push(["replaceState", a]) },
    addEventListener: (name) => listened.push(name),
    removeEventListener: (name) => listened.push(name),
  }
  const { hook, handlers } = mount()
  SocialIdeas.mounted.call(hook)

  assert.deepEqual(Object.keys(handlers), ["ideas:focus"])
  assert.deepEqual(listened, [])
  assert.deepEqual(history, [])
  assert.equal(SocialIdeas.destroyed, undefined)
  assert.equal(SocialIdeas.ideasUrl, undefined)
})
