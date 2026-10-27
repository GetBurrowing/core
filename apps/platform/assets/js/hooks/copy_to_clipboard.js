// Copies `data-clipboard-text` on click and says so on the button for 2 seconds.
//
// `navigator.clipboard.writeText` rejects when the page is not focused or the
// context is not secure; a rejection used to leave the label untouched and the
// click looked dead. It now falls back to a hidden textarea and `execCommand`,
// and if that fails too the label says "Couldn't copy" instead of staying silent.

/** Resolves true when the text reached the clipboard. `env` is a test seam. */
export async function copyText(text, env = {}) {
  const clipboard = env.clipboard ?? globalThis.navigator?.clipboard
  try {
    await clipboard.writeText(text)
    return true
  } catch {
    return (env.fallback ?? execCommandCopy)(text)
  }
}

function execCommandCopy(text) {
  try {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.select()
    const ok = document.execCommand("copy")
    ta.remove()
    return ok
  } catch {
    return false
  }
}

const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const ok = await copyText(this.el.dataset.clipboardText || "")
      const original = this.el.dataset.copyLabel ?? this.el.innerText
      this.el.dataset.copyLabel = original
      this.el.innerText = ok ? "Copied!" : "Couldn't copy"
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.el.innerText = original
      }, 2000)
    })
  },
}

export default CopyToClipboard
