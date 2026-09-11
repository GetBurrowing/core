defmodule PlatformWeb.Components.Sheet do
  @moduledoc """
  Mobile bottom-sheet, desktop side-panel. One `:open` state replaces the
  drawer-flag duplication called out by audit anchors `1B-USE-4` and the
  drawer/sidebar/nav/menu naming drift in `1A-IA-DRIFT-5`.

  Spec: `~/projects/core/docs/design-system/components/sheet.md`.

  v1 ships with backdrop-tap + Escape-to-close + focus management.
  Drag-to-dismiss is deferred to v2 per spec §7.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :id, :string,
    required: true,
    doc: "Unique DOM id. Required for focus-management hook + aria-controls wiring."

  attr :open, :boolean, default: false

  attr :placement, :atom,
    default: :bottom,
    values: [:bottom, :right, :left, :top],
    doc: "Mobile uses :bottom regardless; placement applies to desktop side-panel."

  attr :on_close, :string,
    default: "close_sheet",
    doc: "phx-click event fired when backdrop tapped, ESC pressed, or close-button clicked."

  attr :on_close_target, :any,
    default: nil,
    doc:
      "phx-target for `on_close`. Pass a LiveComponent's `@myself` (or a selector) when the sheet is rendered INSIDE a LiveComponent — without it the close event escapes to the parent LiveView, which no longer has a handler for it. Task 01a008f6 stage 2."

  attr :class, :string,
    default: nil,
    doc:
      "Extra classes appended to the root element. Use for visibility modifiers like `lg:hidden` or per-instance overrides."

  attr :handle_label, :string,
    default: nil,
    doc:
      "Accessible name for the handle row. Only consulted when the `:handle` slot is filled — the plain decorative bar stays `aria-hidden`."

  attr :rest, :global,
    doc:
      "Spread onto the root element. Lets a caller stamp `data-*` state on the sheet without the component learning what it means (FE-17: `data-sheet`)."

  slot :title
  slot :inner_block, required: true
  slot :actions, doc: "Bottom action bar. Typically Cancel + primary CTA."

  slot :handle,
    doc:
      "Optional content rendered INSIDE the bottom-sheet handle row, replacing the plain grab bar. On a phone the shut sheet is the only place a live countdown is visible, so the handle stops being a pure affordance and carries status. When this slot is empty the handle markup is byte-identical to the decorative bar and stays `aria-hidden=\"true\"`."

  def sheet(assigns) do
    # Twelve existing call sites pass no `:handle`. They must keep rendering the
    # decorative grab bar byte-for-byte, so the bare branch is a single flag and
    # its markup is untouched from before the slot existed.
    assigns =
      assign(assigns, :bare_handle?, assigns.placement == :bottom and assigns.handle == [])

    ~H"""
    <div
      id={@id}
      class={[
        "sheet",
        "sheet-#{@placement}",
        @open && "sheet-open",
        @class
      ]}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-hook="Sheet"
      data-open={to_string(@open)}
      data-on-close={@on_close}
      data-on-close-target={close_target_selector(@on_close_target, @id)}
      {@rest}
    >
      <div class="sheet-backdrop" phx-click={@on_close} phx-target={@on_close_target}></div>
      <div class="sheet-panel">
        <div :if={@bare_handle?} class="sheet-handle" aria-hidden="true"></div>
        <div
          :if={@placement == :bottom and @handle != []}
          id={"#{@id}-handle"}
          class="sheet-handle sheet-handle--status"
          role="status"
          aria-label={@handle_label}
        >
          {render_slot(@handle)}
        </div>

        <header class="sheet-header">
          <h2 id={"#{@id}-title"} class="sheet-title">
            {render_slot(@title)}
          </h2>
          <button
            type="button"
            aria-label="Close"
            phx-click={@on_close}
            phx-target={@on_close_target}
            class="sheet-close-button rounded-full p-1 text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <div class="sheet-body">
          {render_slot(@inner_block)}
        </div>

        <footer :if={@actions != []} class="sheet-actions">
          {render_slot(@actions)}
        </footer>
      </div>
    </div>
    """
  end

  # The Sheet JS hook pushes `on_close` on Escape. `pushEvent` always lands on
  # the LiveView, so the hook needs a SELECTOR it can hand to `pushEventTo`.
  # `@myself` renders as the component's cid, which is not a selector — but a
  # LiveComponent always carries its `id` on a DOM element, so `[data-phx-component]`
  # is not needed: the sheet is rendered inside the component's own tree, and
  # `phx-target` on the markup covers click/tap. For Escape we resolve the
  # nearest enclosing component via the sheet's own id, which the caller can
  # override by passing a selector string instead of `@myself`.
  defp close_target_selector(nil, _id), do: nil
  defp close_target_selector(target, _id) when is_binary(target), do: target
  defp close_target_selector(_target, id), do: "##{id}"
end
