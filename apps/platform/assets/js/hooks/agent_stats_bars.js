// The living agent page's Stats tab (task 01a1b6ad stage 4): hovering a bar
// in "Shipped per day" writes its title into the tip line, as the comp's
// pointerover handler does. Tapping a bar is a phx-click the server answers
// (the `hl` class and the tip), so this hook only covers hover, which is
// client-only and never a round trip.

// The tip a pointer event over `target` should show: the title of the
// enclosing `.ba-bars i`, or null when the pointer is not over a bar.
export function tipFor(target) {
  if (!target || typeof target.closest !== "function") return null
  const bar = target.closest(".ba-bars i")
  if (!bar) return null
  return bar.getAttribute("title") || null
}

const AgentStatsBars = {
  mounted() {
    this.onOver = (e) => {
      const tip = tipFor(e.target)
      if (tip == null) return
      const out = this.el.querySelector(".ba-bartip")
      if (out) out.textContent = tip
    }
    this.el.addEventListener("pointerover", this.onOver)
  },
  destroyed() {
    if (this.onOver) this.el.removeEventListener("pointerover", this.onOver)
  },
}

export default AgentStatsBars
