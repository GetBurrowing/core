// Match the inline player's error handling for decorative card previews.
// Keep the card's open button usable, but collapse a failed preview entirely.
export default {
  mounted() {
    this.media = this.el.querySelector("img, video")
    if (!this.media) return
    this.onError = () => { this.el.style.display = "none" }
    this.media.addEventListener("error", this.onError)
    if (this.media.error ||
        (this.media.tagName === "IMG" && this.media.complete && this.media.naturalWidth === 0)) {
      this.onError()
    }
  },
  destroyed() {
    if (this.media) this.media.removeEventListener("error", this.onError)
  },
}
