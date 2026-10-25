// The Game view's root (task 01a1557a-efdd stage 3): role="dialog" and
// aria-modal="true" belong to the phone layout only, where the view covers
// the whole window. At lg and up the view sits in the shell's main pane
// beside the rail, which stays usable, so it is not a modal dialog.
//
// The server renders the phone semantics (the no-JS default); this hook
// drops them while the viewport is lg or wider and puts them back below it.
// LiveView re-applies the server's attributes on every patch of the root, so
// `updated()` applies the rule again.
//
// Play's own hook map, not a colocated hook (see game_view_share.js).
export const DESKTOP_QUERY = "(min-width: 64rem)"

export function applyDialogSemantics(el, desktop) {
  if (desktop) {
    el.removeAttribute("role")
    el.removeAttribute("aria-modal")
  } else {
    el.setAttribute("role", "dialog")
    el.setAttribute("aria-modal", "true")
  }
}

const GameViewDialog = {
  mounted() {
    this.media = window.matchMedia(DESKTOP_QUERY)
    this.onChange = () => applyDialogSemantics(this.el, this.media.matches)
    this.media.addEventListener("change", this.onChange)
    this.onChange()
  },
  updated() {
    this.onChange()
  },
  destroyed() {
    this.media.removeEventListener("change", this.onChange)
  },
}

export default GameViewDialog
