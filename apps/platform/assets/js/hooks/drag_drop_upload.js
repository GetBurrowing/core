// DragDropUpload hook — drop files on the conversation to attach them
// (redesign rung 11, task 01a1557a-9de3; master-desktop `#drop`).
//
// On `#chat-drop-zone`. A drag carrying Files shows the 'Drop to attach'
// target over the conversation; a drop stages EVERY file, of any type, into
// the composer's tray through the one shared staging function
// (../attach_stage.js `stageFiles`), which also routes files over the inline
// cap to the chunked large-file path. Pasting is the composer's own
// (compose_input.js).
//
// The overlay (`#chat-drop-target`) is server-rendered; this hook only
// toggles it. It is counter-based: dragenter/dragleave fire for every child
// the pointer crosses, so it hides only when the count returns to 0, on a
// drop, or on Escape. A drag without Files (selected text, a link) never
// shows it. Desktop only: `hidden lg:flex`, and a phone has no drag.
import { stageFiles } from "../attach_stage"

export function hasFiles(dataTransfer) {
  const types = dataTransfer && dataTransfer.types
  if (!types) return false
  return Array.from(types).includes("Files")
}

const VISIBLE = "lg:flex"

const DragDropUpload = {
  mounted() {
    this._dragCounter = 0
    // Server-rendered (`Partials.Attach.drop_target/1`, phx-update="ignore"):
    // an element appended here by JS would be dropped by the next patch.
    // Looked up at event time, so a remounted target is always the one shown.
    this._overlay = () => this.el.querySelector("[data-role=drop-target]")

    // The target is `fixed` and placed over this element's box when shown:
    // a `position` written onto #chat-drop-zone from here would be undone by
    // the next patch (the server renders no style there).
    this._show = () => {
      const o = this._overlay()
      if (!o) return
      const r = this.el.getBoundingClientRect()
      o.style.top = `${r.top}px`
      o.style.left = `${r.left}px`
      o.style.width = `${r.width}px`
      o.style.height = `${r.height}px`
      o.classList.add(VISIBLE)
    }
    this._hide = () => {
      this._dragCounter = 0
      const o = this._overlay()
      if (o) o.classList.remove(VISIBLE)
    }

    this._onDragEnter = (e) => {
      if (!hasFiles(e.dataTransfer)) return
      e.preventDefault()
      this._dragCounter++
      if (this._dragCounter === 1) this._show()
    }

    this._onDragOver = (e) => {
      if (!hasFiles(e.dataTransfer)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
    }

    this._onDragLeave = (e) => {
      if (!hasFiles(e.dataTransfer)) return
      e.preventDefault()
      this._dragCounter--
      if (this._dragCounter <= 0) this._hide()
    }

    this._onDrop = (e) => {
      if (!hasFiles(e.dataTransfer)) return
      e.preventDefault()
      this._hide()
      const files = Array.from(e.dataTransfer.files || [])
      if (files.length > 0) stageFiles(this, files)
    }

    this._onKeyDown = (e) => {
      if (e.key === "Escape" && this._dragCounter > 0) this._hide()
    }

    this.el.addEventListener("dragenter", this._onDragEnter)
    this.el.addEventListener("dragover", this._onDragOver)
    this.el.addEventListener("dragleave", this._onDragLeave)
    this.el.addEventListener("drop", this._onDrop)
    window.addEventListener("keydown", this._onKeyDown)
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this._onDragEnter)
    this.el.removeEventListener("dragover", this._onDragOver)
    this.el.removeEventListener("dragleave", this._onDragLeave)
    this.el.removeEventListener("drop", this._onDrop)
    window.removeEventListener("keydown", this._onKeyDown)
  },
}

export default DragDropUpload
