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

// Shows the outcome of one copy on the button. `data-copy-state` is
// "copied" only when the text reached the clipboard and "failed" otherwise,
// so a style keyed on it (the call rail's guest link turns `success` on
// "copied") can never claim a copy that did not happen. The success label
// defaults to "Copied!" and a button can name its own with
// `data-copied-label`. Returns the label to restore.
export function showCopyResult(el, ok) {
  const original = el.dataset.copyLabel ?? el.innerText
  el.dataset.copyLabel = original
  el.dataset.copyState = ok ? "copied" : "failed"
  el.innerText = ok ? (el.dataset.copiedLabel || "Copied!") : "Couldn't copy"
  return original
}

export function resetCopyResult(el, original) {
  el.innerText = original
  delete el.dataset.copyState
}

const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const ok = await copyText(this.el.dataset.clipboardText || "")
      const original = showCopyResult(this.el, ok)
      clearTimeout(this.timer)
      this.timer = setTimeout(() => resetCopyResult(this.el, original), 2000)
    })
  },
}

export default CopyToClipboard
