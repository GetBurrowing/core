// The review can be below the list on a phone or in a scrolled desktop pane.
// Focus the review only when it opens, never when its form is patched.
function focusReview(el) {
  el.focus({ preventScroll: true })
  el.scrollIntoView({ block: "start", inline: "nearest" })
}

export default {
  mounted() {
    focusReview(this.el)
    this.handleEvent("studio:focus_detail", ({ id }) => {
      if (this.el.dataset.postId === id) focusReview(this.el)
    })
  },
}
