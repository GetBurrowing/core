// "Download as file" on the shown-once install hand-over (task 01a10315
// stage 3). The file is built in the browser from the values the page is
// showing, and saved through a Blob URL: no server round-trip, no stored file.
//
// The button carries `data-handover-target` naming the hand-over container;
// every `[data-handover-field]` inside it contributes one entry, labelled by
// the attribute and valued by `data-value` (or its text). Multi-line values
// (the SSH private key) are written as a block under their label.

/** The text file for `fields` (`[{label, value}]`), in page order. */
export function handoverText(fields, title = "Your Burrow") {
  const lines = [title, "=".repeat(title.length), ""]
  for (const {label, value} of fields) {
    if (!value) continue
    if (value.includes("\n")) {
      lines.push(`${label}:`, value.replace(/\n+$/, ""), "")
    } else {
      lines.push(`${label}: ${value}`)
    }
  }
  return lines.join("\n").replace(/\n*$/, "\n")
}

/** `[{label, value}]` from the `[data-handover-field]` elements under `root`. */
export function collectFields(root) {
  return Array.from(root.querySelectorAll("[data-handover-field]")).map((el) => ({
    label: el.dataset.handoverField,
    value: el.dataset.value ?? el.textContent.trim(),
  }))
}

/** Save `text` as `filename`. `env` is a test seam (document, URL, Blob). */
export function saveText(text, filename, env = {}) {
  const doc = env.document ?? globalThis.document
  const url = env.URL ?? globalThis.URL
  const BlobCtor = env.Blob ?? globalThis.Blob
  const href = url.createObjectURL(new BlobCtor([text], {type: "text/plain;charset=utf-8"}))
  const a = doc.createElement("a")
  a.href = href
  a.download = filename
  a.rel = "noopener"
  doc.body.appendChild(a)
  a.click()
  a.remove()
  // Revoke after the click has been dispatched, so the download has the URL.
  setTimeout(() => url.revokeObjectURL(href), 0)
  return href
}

const HandoverDownload = {
  mounted() {
    this.el.addEventListener("click", () => {
      const root = document.getElementById(this.el.dataset.handoverTarget)
      if (!root) return
      const filename = this.el.dataset.filename || "burrow-details.txt"
      saveText(handoverText(collectFields(root)), filename)
    })
  },
}

export default HandoverDownload
