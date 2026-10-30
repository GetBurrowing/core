// The variable import prevents the eager IIFE app build from inlining the island.
const island = "/assets/js/clip_players.js"
let ready
const load = () => ready ||= import(island).catch(error => { ready = null; throw error })

export function lazyClipHook(name, loader = load) {
  return {
    mounted() {
      this.clipIslandDestroyed = false
      loader().then(module => {
        if (this.clipIslandDestroyed) return
        const hook = module[name]
        this.clipIslandHook = hook
        for (const [key, value] of Object.entries(hook)) {
          if (!["mounted", "updated", "destroyed"].includes(key)) this[key] = value
        }
        hook.mounted.call(this)
      }).catch(() => {
        if (this.clipIslandDestroyed) return
        const status = this.el.querySelector('[data-role="closing-media-error"]')
        if (status) {
          this.el.querySelector("video")?.setAttribute("hidden", "")
          status.hidden = false
        }
      })
    },
    updated() { this.clipIslandHook?.updated?.call(this) },
    destroyed() {
      this.clipIslandDestroyed = true
      this.clipIslandHook?.destroyed?.call(this)
    }
  }
}
