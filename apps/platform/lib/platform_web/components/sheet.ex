defmodule PlatformWeb.Components.Sheet do
  @moduledoc """
  Mobile bottom-sheet, desktop side-panel. One `:open` state replaces the
  drawer-flag duplication called out by audit anchors `1B-USE-4` and the
  drawer/sidebar/nav/menu naming drift in `1A-IA-DRIFT-5`.

  Spec: `~/projects/core/docs/design-system/components/sheet.md`.

  Ships with backdrop-tap + Escape-to-close + focus management. Swipe
  dismissal is opt-in via `swipe_dismiss`, which requires `handle_close`
  (see the attr doc: `sheet/1` raises without it).
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

  attr :handle_close, :boolean,
    default: false,
    doc:
      "Opt-in (task 01a1557a-807f stage 4). The bottom handle renders as a real Close button (`aria-label=\"Close\"`, firing `on_close`), the header X button is omitted and the title is visually hidden (it still names the dialog). Default false: every other call site keeps the decorative handle, the X and a visible title."

  attr :swipe_dismiss, :boolean,
    default: false,
    doc:
      "Opt-in (task 01a1557a-807f stage 4). Stamps `data-swipe-dismiss=\"true\"` so the Sheet hook closes the sheet on a downward drag past 60px from the handle, or from the panel while its body is scrolled to the top. Default false: the hook ignores pointer drags. REQUIRES the handle Close button (`.sheet-handle-button`, `touch-action: none`), which renders only with `handle_close`, `placement: :bottom` and an empty `:handle` slot; a bare `.sheet-handle` has `touch-action: auto`, so a real touch drag on it gets `pointercancel` and never closes. `sheet/1` raises `ArgumentError` at render otherwise (task 01a161c4). Because `handle_close` visually hides the title, render a visible `aria-hidden` title line in the body."

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

    validate_swipe_dismiss!(assigns)

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
      data-swipe-dismiss={@swipe_dismiss && "true"}
      {@rest}
    >
      <div class="sheet-backdrop" phx-click={@on_close} phx-target={@on_close_target}></div>
      <div class="sheet-panel">
        <div :if={@bare_handle? and !@handle_close} class="sheet-handle" aria-hidden="true"></div>
        <button
          :if={@bare_handle? and @handle_close}
          type="button"
          class="sheet-handle-button press-hold focus-visible-ring"
          aria-label="Close"
          phx-click={@on_close}
          phx-target={@on_close_target}
        >
          <span class="sheet-handle" aria-hidden="true"></span>
        </button>
        <div
          :if={@placement == :bottom and @handle != []}
          id={"#{@id}-handle"}
          class="sheet-handle sheet-handle--status"
          role="status"
          aria-label={@handle_label}
        >
          {render_slot(@handle)}
        </div>

        <header class={if @handle_close, do: "sheet-header sr-only", else: "sheet-header"}>
          <h2
            id={"#{@id}-title"}
            class={if @handle_close, do: "sheet-title sr-only", else: "sheet-title"}
          >
            {render_slot(@title)}
          </h2>
          <button
            :if={not @handle_close}
            type="button"
            aria-label="Close"
            phx-click={@on_close}
            phx-target={@on_close_target}
            class="sheet-close-button press-hold rounded-full p-1 text-subtle active:bg-base-200 phx-click-loading:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
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
  # The invariant is "swipe_dismiss implies the handle Close button renders":
  # that button is the only touch-action:none start point the hook has, so a
  # non-bottom placement or a filled `:handle` slot fails it as surely as a
  # missing `handle_close`. Raising (rather than implying `handle_close`) keeps
  # the title-hiding side effect explicit at the call site: an implied flag
  # would sr-only the title and drop the X with nothing to tell the author.
  defp validate_swipe_dismiss!(%{swipe_dismiss: true} = assigns) do
    unless assigns.bare_handle? and assigns.handle_close do
      raise ArgumentError, """
      Sheet id="#{assigns.id}" sets swipe_dismiss without the handle Close button.

      swipe_dismiss needs the `.sheet-handle-button` (touch-action: none) as its drag
      start point; a bare `.sheet-handle` has touch-action: auto, so a real touch drag
      gets pointercancel and the sheet never closes. That button renders only with
      handle_close, placement: :bottom and an empty :handle slot
      (got handle_close: #{inspect(assigns.handle_close)}, placement: #{inspect(assigns.placement)}, \
      :handle slot filled: #{assigns.handle != []}).

      Add handle_close. It visually hides the title (it still names the dialog) and
      drops the header X, so also render a visible aria-hidden title line in the body.
      """
    end

    :ok
  end

  defp validate_swipe_dismiss!(_assigns), do: :ok

  defp close_target_selector(nil, _id), do: nil
  defp close_target_selector(target, _id) when is_binary(target), do: target
  defp close_target_selector(_target, id), do: "##{id}"
end
