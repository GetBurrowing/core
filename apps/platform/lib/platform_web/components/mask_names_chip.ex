defmodule PlatformWeb.Components.MaskNamesChip do
  @moduledoc """
  The shell header's "Names masked" chip (task 01a1600d stage 2), from the
  designer's direction canvas 01a1616c. It tells the person who turned on
  screen-share name masking, on whichever page they are looking at, that
  names are hidden and when that ends.

  Two function components, mirroring `PlatformWeb.Components.ThemePicker`:

    * `mask_names_chip/1`: the chip, plus at `lg` and above a popover
      anchored to it. The shell renders it in the phone top strip's right
      cluster (below lg) and in the desktop sidebar's footer (at lg, with
      `id_prefix="sidebar-mask-names"` and the popover opening upward).
    * `mask_names_chip_sheet/1`: below `lg`, the same body in a bottom
      `<.sheet>`. It carries `lg:hidden`. Render it outside the header so the
      sheet's `position: fixed` is not trapped.

  ## Chip and page agree

  Both render NOTHING unless `masked?`, and the shell passes `@mask_names?`:
  the same assign the page reads (ShellLive seeds it on every page; ChatLive,
  `Tasks.MaskHooks` and SettingsLive keep it current through their own
  handlers). There is no clock in render, so the chip never disappears on a
  timer while the page, seeded at mount, is still masked.

  ## A tap never unmasks

  The chip only opens the confirm (`toggle_mask_chip`). "Turn off" in the
  confirm sends `toggle_mask_names` with `masked=false`, which ShellLive
  routes to the page's own handler on Chat and Tasks and writes itself
  elsewhere, so the one writer runs and the page unmasks in the same round
  trip. Turn off pushes with `JS.push/2` rather than a bare-string
  `phx-click="toggle_mask_names"`: several existing tests find the rails' own
  toggle by that exact attribute selector, page-wide, and a second match in
  the shell would make them ambiguous. The event and its `masked` param are
  the same. "Mask names settings" is a plain navigate link with no `phx-click`
  (a `phx-click` on a navigate link throws on the client); navigation
  remounts the shell, which closes the confirm.

  ## Hit area

  The pill is 28px (`h-7`, a 1px border, so its padding box is 26px) in the
  44px `#phone-top-bar` (`h-11`, including its 1px bottom border, so the
  pill's top sits 7.5px below the viewport top). The `before:` box is positioned from the
  pill's padding box: 8.5px above it and 9.5px below, so it runs from the
  top of the viewport to the bottom of the bar, 44px, entirely inside the
  bar. Nothing outside the bar is covered, so no control in the page header
  below loses a tap. The root still carries `z-30`: Chrome hit-tests the
  positioned `<main>` that follows the bar from y=43.05 (its box starts at
  44), so without it the bar's last pixel row went to the page; `z-30`
  clears `#tasks-page-header`'s sticky `z-20`.

  Measured at stage 4 (elementFromPoint down the chip's centre line): with
  the bar at 40px, a symmetric 8px box reached only 40px (its top was above
  the viewport and its bottom under the page header). Keeping 40px and
  raising the chip could not work either: `#tasks-page-header` is sticky
  `z-20` and painted over it, and on /chat and /meetings at 375 the box
  would have covered `chat-list-search` and a link starting at y=42.
  `MaskNamesChipTest` pins this geometry.

  ## Colour

  Text is `text-base-content` or `text-subtle` only, on base-200 (chip and
  Turn off) or base-100 (popover and sheet). No status colour: masking is a
  choice the person made, not a fault. No `hover:` utility: the phone has no
  hover, and the desktop hover is plain CSS in a later stage.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet

  alias Phoenix.LiveView.JS
  alias PlatformWeb.MaskNamesLabel

  attr :masked?, :boolean, default: false
  attr :until, :any, default: nil, doc: "the stored end, `Accounts.mask_names_until/1`"
  attr :zone, :string, default: nil, doc: "the viewer's resolved IANA zone, or nil"
  attr :connected?, :boolean, default: false
  attr :open, :boolean, default: false

  attr :id_prefix, :string,
    default: "mask-names",
    doc:
      "prefix for the chip's ids. The shell renders the chip twice (the phone top strip " <>
        "below lg, the desktop sidebar at lg), so the sidebar passes its own prefix and " <>
        "the two never share a DOM id"

  attr :popover_class, :string,
    default: "right-0 top-full mt-1",
    doc: "where the lg popover sits against the chip; the sidebar opens it upward"

  def mask_names_chip(assigns) do
    assigns = assign(assigns, :until_text, until_text(assigns))

    ~H"""
    <div :if={@masked?} id={"#{@id_prefix}-chip-root"} class="relative z-30 shrink-0">
      <%!-- While the popover is open the chip pushes nothing: the popover's
            click-away closes it, and a toggle here would reopen it in the
            same click. Below lg the sheet's backdrop covers the chip. The
            `before:` box widens the 28px pill to a 44px-tall hit area: see
            "Hit area" in the moduledoc for why it is asymmetric. --%>
      <button
        type="button"
        id={"#{@id_prefix}-chip"}
        data-role="mask-names-chip"
        phx-click={!@open && "toggle_mask_chip"}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open)}
        aria-controls={"#{@id_prefix}-popover"}
        aria-label={accessible_name(@until_text)}
        class="relative flex h-7 items-center gap-1.5 rounded-selector border border-edge bg-base-200 px-2.5 active:bg-base-100 focus-visible-ring before:absolute before:-inset-x-1 before:-top-[8.5px] before:-bottom-[9.5px]"
      >
        <span class="hero-eye-slash size-4 shrink-0 text-base-content" aria-hidden="true"></span>
        <span
          data-role="mask-chip-label"
          class="text-xs font-medium text-base-content whitespace-nowrap"
        >
          Names masked
        </span>
        <span
          :if={@until_text}
          data-role="mask-chip-until"
          class="text-xs text-subtle whitespace-nowrap max-lg:hidden"
          aria-hidden="true"
        >
          · {@until_text}
        </span>
      </button>

      <div
        id={"#{@id_prefix}-popover"}
        role="dialog"
        aria-label="Names masked"
        class={[
          "absolute z-50 w-72 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-3 shadow-lg",
          @popover_class,
          if(@open, do: "hidden lg:block", else: "hidden")
        ]}
        phx-click-away={@open && "close_mask_chip"}
        phx-window-keydown={@open && "close_mask_chip"}
        phx-key={@open && "Escape"}
      >
        <.confirm_body id={"#{@id_prefix}-popover-body"} until_text={@until_text} />
      </div>
    </div>
    """
  end

  attr :masked?, :boolean, default: false
  attr :until, :any, default: nil
  attr :zone, :string, default: nil
  attr :connected?, :boolean, default: false
  attr :open, :boolean, default: false

  def mask_names_chip_sheet(assigns) do
    assigns = assign(assigns, :until_text, until_text(assigns))

    ~H"""
    <.sheet
      :if={@masked?}
      id="mask-names-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_mask_chip"
      swipe_dismiss
      handle_close
      class="lg:hidden"
    >
      <:title>Names masked</:title>
      <.confirm_body id="mask-names-sheet-body" until_text={@until_text} />
    </.sheet>
    """
  end

  attr :id, :string, required: true
  attr :until_text, :string, default: nil

  defp confirm_body(assigns) do
    ~H"""
    <div id={@id} data-role="mask-chip-body" class="flex flex-col gap-3">
      <p class="text-sm text-base-content">
        Names are masked in Chat and Tasks on all your devices<span :if={!@until_text}>.</span>
        <span :if={@until_text} class="text-subtle">{@until_text}.</span>
      </p>
      <button
        type="button"
        data-role="mask-chip-turn-off"
        phx-click={JS.push("toggle_mask_names", value: %{masked: "false"})}
        class="flex min-h-11 w-full items-center justify-center rounded-field bg-base-200 px-4 text-sm font-semibold text-base-content active:bg-base-100 focus-visible-ring"
      >
        Turn off
      </button>
      <.link
        navigate="/settings"
        data-role="mask-chip-settings"
        class="flex min-h-11 items-center justify-between gap-2 rounded-field px-1 text-sm text-base-content active:bg-base-200 focus-visible-ring"
      >
        Mask names settings
        <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
      </.link>
    </div>
    """
  end

  @doc """
  The chip's accessible name, constant across widths and the collapsed
  state: "Names masked until 9:41 pm. Open mask settings", or "Names masked.
  Open mask settings" when no time is shown.
  """
  @spec accessible_name(String.t() | nil) :: String.t()
  def accessible_name(nil), do: "Names masked. Open mask settings"
  def accessible_name(until_text), do: "Names masked #{until_text}. Open mask settings"

  @doc """
  Whether the layout's LiveView socket is connected. The shell layout passes
  its assigns; a render without a LiveView socket reads as not connected.
  """
  @spec shell_connected?(map()) :: boolean()
  def shell_connected?(%{socket: %Phoenix.LiveView.Socket{} = socket}),
    do: Phoenix.LiveView.connected?(socket)

  def shell_connected?(_assigns), do: false

  # The end time renders only once the socket is connected: the dead render
  # has no `timezone` connect param, so it would flash a UTC time that the
  # connected render then replaces. Connected with an unresolvable zone shows
  # the UTC time and says so (Settings' rule, `MaskNamesLabel.clock/2`).
  defp until_text(%{connected?: true, until: until, zone: zone}),
    do: MaskNamesLabel.until_text(until, zone, DateTime.utc_now())

  defp until_text(_assigns), do: nil
end
