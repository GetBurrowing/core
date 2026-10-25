/**
 * RowContextMenu hook: right-click a list row on desktop to open its menu
 * (Burrow redesign 22 stage 2; master-desktop.html L715, the list rows'
 * `contextmenu` listener).
 *
 * Mounted once on the list's root (`#chat-list`), not per row: a row link
 * already carries `RowLongPress`, and an element holds one hook. The
 * `contextmenu` event bubbles up to here from the row.
 *
 * Generic over data attributes, like `RowLongPress`:
 *
 *   data-context-event   on the hook element: the event pushed
 *                        (the Chat list uses "open_row_actions")
 *   data-long-press-space-id
 *                        on the row: the space the menu acts on. Only rows
 *                        that offer the phone's long-press sheet carry it
 *                        (not the Agents row, pinned tasks, Archived or
 *                        search results), so the desktop menu is offered on
 *                        exactly the rows the phone offers its sheet on.
 *
 * Desktop only: below 1024px the event is left alone, because there a
 * long-press opens the phone's row sheet instead and `RowLongPress` already
 * prevents the platform callout. On a row it prevents the browser's own
 * menu and pushes `{space_id}`; anywhere else it does nothing.
 */

export const DESKTOP_QUERY = "(min-width: 1024px)"

export const isDesktop = () =>
  typeof window !== "undefined" &&
  typeof window.matchMedia === "function" &&
  window.matchMedia(DESKTOP_QUERY).matches

export function rowSpaceId(target) {
  if (!target || typeof target.closest !== "function") return null
  const row = target.closest("[data-long-press-space-id]")
  return row ? row.getAttribute("data-long-press-space-id") : null
}

const RowContextMenu = {
  mounted() {
    this.handleContextMenu = (event) => {
      if (!isDesktop()) return
      const spaceId = rowSpaceId(event.target)
      if (!spaceId) return

      event.preventDefault()
      const name = this.el.getAttribute("data-context-event") || "open_row_actions"
      this.pushEvent(name, {space_id: spaceId})
    }

    this.el.addEventListener("contextmenu", this.handleContextMenu)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.handleContextMenu)
  },
}

export default RowContextMenu
