import test from "node:test"
import assert from "node:assert/strict"
import StudioPostFocus from "../js/hooks/studio_post_focus.js"

test("focuses and scrolls the detail on mount and a repeated targeted open", () => {
  const calls = []
  let callback
  const hook = {
    el: {
      dataset: { postId: "post-1" },
      focus: (options) => calls.push(["focus", options]),
      scrollIntoView: (options) => calls.push(["scroll", options]),
    },
    handleEvent: (name, handler) => { assert.equal(name, "studio:focus_detail"); callback = handler },
  }
  StudioPostFocus.mounted.call(hook)
  assert.deepEqual(calls, [["focus", { preventScroll: true }], ["scroll", { block: "start", inline: "nearest" }]])
  calls.length = 0
  callback({ id: "other" })
  assert.deepEqual(calls, [])
  callback({ id: "post-1" })
  assert.equal(calls.length, 2)
})
