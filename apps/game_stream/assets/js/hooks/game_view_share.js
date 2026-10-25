// The Game view's share buttons (task 01a1557a-efdd stage 2): copy the build
// link (data-share-url, the absolute /m/games?canvas=<id> URL, never the
// return path) and tell the server, which shows the "Build link copied"
// toast. A refused clipboard write shows nothing rather than a false toast.
//
// Play's own hook map, not a colocated hook: a colocated hook in this Mix
// project is never imported by core's bundle (only `@extensions` is).
const GameViewShare = {
  mounted() {
    this.onClick = () => copy(this.el.dataset.shareUrl, navigator.clipboard, () =>
      this.pushEvent("game_link_copied", {}),
    )
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}

export function copy(url, clipboard, done) {
  if (!url || !clipboard || typeof clipboard.writeText !== "function") return Promise.resolve(false)
  return clipboard.writeText(url).then(
    () => {
      done()
      return true
    },
    () => false,
  )
}

export default GameViewShare
