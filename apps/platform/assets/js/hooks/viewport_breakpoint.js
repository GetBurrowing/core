/**
 * ViewportBreakpoint hook — tells the server which side of a CSS
 * breakpoint the viewport is on (task 01a07410 / FE-17 stage 3).
 *
 * ## Why the server needs to know
 *
 * `/meetings`' call rail is ONE DOM node (a nested chat LiveView, the
 * transcript hook, the candidate buttons — all mount-once). At `lg` it is
 * an in-flow column; below `lg` it lives inside a bottom sheet. Those two
 * wrappers cannot both be in the document gated by CSS, because the sheet
 * is `role="dialog" aria-modal="true"` and a modal dialog that exists at
 * desktop tells a screen reader the rest of the page is inert. So the
 * server renders exactly one wrapper, and this hook is how it chooses.
 *
 * ## What it reports, and when
 *
 * `{ below: boolean }` to the event named in `data-event`, for the
 * `min-width` in `data-breakpoint` (px; default 1024, Tailwind's `lg`).
 * Once at mount, again on every crossing (`matchMedia` `change`, which
 * fires only on the transition and never on same-side resizes), and again
 * on `reconnected()` — a reconnect remounts the LiveView with the assign
 * back at its default, and a phone that reconnected must not be left
 * looking at the desktop wrapper.
 *
 * ## What it does NOT do
 *
 * It does not report a width. A width is a fact the server has no use
 * for and would tempt it into layout decisions that belong in CSS; the
 * one decision it needs is a side of one line, and that is the whole
 * payload.
 */
const ViewportBreakpoint = {
  mounted() {
    const px = parseInt(this.el.dataset.breakpoint, 10) || 1024
    this._query = window.matchMedia(`(min-width: ${px}px)`)
    this._report = () =>
      this.pushEvent(this.el.dataset.event, { below: !this._query.matches })

    this._query.addEventListener("change", this._report)
    this._report()
  },

  reconnected() {
    this._report()
  },

  destroyed() {
    if (this._query) this._query.removeEventListener("change", this._report)
  },
}

export default ViewportBreakpoint
