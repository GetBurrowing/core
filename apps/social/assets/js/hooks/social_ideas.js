// The Ideas tab's hook: it only moves focus when the server says so; it never
// decides what is shown and it never touches the address bar or history.
//
// The view controls are ordinary links (a full page load), so Back, Forward and
// reload belong to the browser. An earlier version pushed history entries and
// listened to popstate here; that raced LiveView's own history handling and Back
// left the page on a different view than the address.
//
//   * "ideas:focus" {id}   focuses that element after the patch.

export default {
  mounted() {
    this.handleEvent("ideas:focus", ({ id }) => {
      requestAnimationFrame(() => {
        const el = document.getElementById(id)
        if (el) el.focus()
      })
    })
  },
}
