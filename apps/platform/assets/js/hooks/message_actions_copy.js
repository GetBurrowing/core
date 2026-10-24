// MessageActionsCopy: the actions sheet's and the desktop popover's 'Copy
// text' and 'Copy link' rows (redesign rung 9 stage 2, task 01a1557a-9406).
//
// Client-side, like the tap pill's Copy: a row carrying
// `data-clipboard-text` and `data-copy-toast` copies the text, shows that
// toast ('Copied' / 'Link copied') for 2s, and marks the message the sheet
// was opened for `data-copied="true"` for 2s. The row's own `phx-click`
// closes the sheet; the clipboard write starts first, inside the click, so
// it still counts as a user gesture.

import { copyText, showCopied } from "./message_gestures"

export function messageRoot(id) {
  if (!id || typeof document === "undefined") return null
  return document.querySelector(`[data-message-id="${id}"][phx-hook="MessageGestures"]`)
}

const MessageActionsCopy = {
  mounted() {
    this._onClick = (e) => {
      const row = e.target && e.target.closest ? e.target.closest("[data-copy-toast]") : null
      if (!row || !this.el.contains(row)) return
      const text = row.dataset.clipboardText || ""
      const toastText = row.dataset.copyToast
      const id = this.el.dataset.actionsMessageId
      copyText(text, () => showCopied(messageRoot(id), toastText))
    }
    this.el.addEventListener("click", this._onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
  },
}

export default MessageActionsCopy
