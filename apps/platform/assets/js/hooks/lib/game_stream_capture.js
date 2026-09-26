/**
 * The capture state machine for the `game_stream` canvas (task 01a0db5f
 * stage 4). Pure: it takes the current state and one event, and returns the
 * next state plus the side effects the hook must perform. The hook
 * (`../game_stream.js`) owns the DOM, the data channels and the fullscreen
 * API; this module only decides.
 *
 * The rules, from design canvas 01a0db60:
 *
 *   - Capture starts ONLY on an explicit click or tap in a live frame, never
 *     on load and never on a key.
 *   - Esc releases capture, like browser pointer lock. Inside fullscreen the
 *     first Esc exits fullscreen and a second Esc releases.
 *   - Window blur, the page going hidden, and focus moving into an editable
 *     element (the chat composer) all release, and every release tells the
 *     game to let go of whatever is held (`release_all`), so a key that was
 *     down when the window lost focus is not stuck down in the game.
 *   - Esc is reserved: it is never forwarded to the game in v1
 *     (`forwardable/1`).
 *
 * Events:  {type: "click", live}  {type: "key", code}  {type: "blur"}
 *          {type: "hidden"}  {type: "focus_editable"}  {type: "not_live"}
 *          {type: "fullscreen", on}
 * Actions: "capture"  "release"  "release_all"  "exit_fullscreen"
 */

export const ESCAPE = "Escape"

export function initialCapture() {
  return { captured: false, fullscreen: false }
}

/** Is a KeyboardEvent.code ever sent to the game? Esc never is. */
export function forwardable(code) {
  return typeof code === "string" && code !== "" && code !== ESCAPE
}

function release(state) {
  if (!state.captured) return { state, actions: [] }
  return { state: { ...state, captured: false }, actions: ["release", "release_all"] }
}

export function captureReduce(state, event) {
  switch (event && event.type) {
    case "click":
      if (event.live && !state.captured) {
        return { state: { ...state, captured: true }, actions: ["capture"] }
      }
      return { state, actions: [] }

    case "key":
      if (event.code !== ESCAPE) return { state, actions: [] }
      // First Esc in fullscreen leaves fullscreen and keeps capture. The
      // browser may exit fullscreen itself on that Esc and never deliver the
      // key; the `fullscreen` event below then records the same result.
      if (state.fullscreen) {
        return { state: { ...state, fullscreen: false }, actions: ["exit_fullscreen"] }
      }
      return release(state)

    case "blur":
    case "hidden":
    case "focus_editable":
    case "not_live":
      return release(state)

    case "fullscreen":
      return { state: { ...state, fullscreen: !!event.on }, actions: [] }

    default:
      return { state, actions: [] }
  }
}
