// The meeting-only renderer is an island, so ordinary pages pay only for
// this loader. A destroyed LiveView hook must never mount a late download.
let ready
function loadFace() {
  if (window.__burrowCohostFace) return Promise.resolve(window.__burrowCohostFace)
  if (ready) return ready
  ready = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "/assets/js/cohost_face_island.js"
    script.async = true
    script.onload = () => window.__burrowCohostFace ? resolve(window.__burrowCohostFace) : reject()
    script.onerror = reject
    document.head.appendChild(script)
  }).catch(error => { ready = null; throw error })
  return ready
}
export default {
  mounted() {
    loadFace().then(runtime => {
      if (this.faceGone) return
      this.faceRuntime = runtime
      for (const key of Object.keys(runtime)) {
        if (key !== "mounted" && key !== "destroyed") this[key] = runtime[key]
      }
      runtime.mounted.call(this)
    }).catch(() => {
      if (this.faceGone) return
      this.el.querySelector("[data-face-open]").textContent = "Face unavailable — reload"
    })
  },
  destroyed() {
    this.faceGone = true
    this.faceRuntime?.destroyed.call(this)
  }
}
