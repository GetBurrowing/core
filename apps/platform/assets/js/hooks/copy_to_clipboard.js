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

// Shows the outcome of one copy on the button: the class `copy-copied` only
// when the text reached the clipboard, `copy-failed` otherwise, so a style
// keyed on it (the call rail's guest link turns `success` on `copy-copied`)
// can never claim a copy that did not happen. The success label defaults to
// "Copied!" and a button can name its own with `data-copied-label`. Returns
// the label to restore.
//
// A CLASS, not a `data-` attribute. On a `phx-update="ignore"` element
// LiveView still re-syncs every `data-*` attribute from the server's render
// on each patch and REMOVES the ones the server did not send, so a
// `data-copy-state` written here was wiped by the next unrelated re-render
// (the call rail re-renders every second). Classes on an ignored element
// are left alone. `data-copy-state` is still written for callers that read
// it immediately, but nothing should style or wait on it.
export function showCopyResult(el, ok) {
  const original = el.dataset.copyLabel ?? el.innerText
  el.dataset.copyLabel = original
  el.dataset.copyState = ok ? "copied" : "failed"
  el.classList.remove("copy-copied", "copy-failed")
  el.classList.add(ok ? "copy-copied" : "copy-failed")
  el.innerText = ok ? (el.dataset.copiedLabel || "Copied!") : "Couldn't copy"
  return original
}

export function resetCopyResult(el, original) {
  el.innerText = original
  delete el.dataset.copyState
  el.classList.remove("copy-copied", "copy-failed")
}

const CopyToClipboard = {
  mounted() {
    // A readiness marker for browser tests: a click that lands before the
    // hook has mounted copies nothing, and nothing else in the DOM says when
    // that window has closed.
    this.el.classList.add("copy-ready")
    this.el.addEventListener("click", async () => {
      const ok = await copyText(this.el.dataset.clipboardText || "")
      const original = showCopyResult(this.el, ok)
      clearTimeout(this.timer)
      this.timer = setTimeout(() => resetCopyResult(this.el, original), 2000)
    })
  },
}

export default CopyToClipboard
