defmodule PlatformWeb.Components.InstallSwitch do
  @moduledoc """
  The install switcher button, ONE component for both places it shows (task
  01a1ccd4 stage 3; design canvas 01a1cd29-e313):

    * `variant={:phone}`, id `native-install-switch`, in the phone top bar.
      Rendered `hidden` exactly as task 01a1261e stage 3 shipped it; the
      `NativeInstallSwitch` hook reveals it (inside the Burrow app on its
      native path, in a browser on the web path).
    * `variant={:sidebar}`, id `sidebar-install-switch`, in the desktop
      sidebar's `#sidebar-brand` row, replacing the bare mark and name. It
      renders visible (the mark and name were always there) and the same hook
      attaches.

  Both carry the unread dot (`bg-primary`, never a number) and a sibling
  `#<id>-menu` container that is `phx-update="ignore"`: the hook draws the
  dropdown into it, so a LiveView patch never wipes an open dropdown.

  The phone button keeps the classes 01a1261e shipped, plus
  `aria-expanded:bg-base-300` (the canvas's open fill), which only the web
  path ever triggers: the native path never sets `aria-expanded`.

  `data-install-name` and `data-current-unread` hand the hook this install's
  name and its own unread (shown beside the check on the current row).

    * `variant={:play}`, the Console Glass brand (the burrow mark and the PLAY
      pill) in the gaming shell's `.cg-side`, on /play and /games/*. Rendered
      `hidden` like the phone button, with `data-variant="play"`: the web path
      lays its dropdown out as `:sidebar` at desktop widths and as `:phone`
      below 768px, where `.cg-side` is the phone top bar. Those pages are dead
      views, so `app.js` mounts the same hook on them by hand. The gaming
      shell keeps a plain `/play` link beside it for when nothing reveals it.

  `menu={false}` leaves out the `#<id>-menu` container so the caller can put
  it with `install_switch_menu/1` somewhere a fixed-position dropdown is not
  trapped (the gaming shell's `.cg-side` has a `backdrop-filter`, which makes
  it the containing block for fixed descendants and clips them).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  attr :id, :string, required: true
  attr :variant, :atom, values: [:phone, :sidebar, :play], required: true
  attr :brand_name, :string, required: true
  attr :current_unread, :integer, default: 0
  attr :menu, :boolean, default: true, doc: "render the sibling `#<id>-menu` container"

  def install_switch(%{variant: :phone} = assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-role="native-install-switch"
      data-variant="phone"
      data-install-name={@brand_name}
      data-current-unread={@current_unread}
      phx-hook="NativeInstallSwitch"
      aria-label={"Switch install, current: #{@brand_name}"}
      class="hidden -ml-1 shrink-0 items-center gap-1.5 rounded-md px-1 py-0.5 hover:bg-base-300/60 aria-expanded:bg-base-300"
    >
      <img
        src="/branding/current/apple_touch"
        alt=""
        class="size-5 shrink-0 rounded"
        data-role="install-logo"
      />
      <span class="max-w-[7rem] truncate text-sm font-semibold">{@brand_name}</span>
      <span class="hero-chevron-down size-4 shrink-0 text-subtle" aria-hidden="true"></span>
      <span
        data-role="install-unread-dot"
        class="hidden size-2 shrink-0 rounded-full bg-primary"
        aria-hidden="true"
      >
      </span>
    </button>
    <.install_switch_menu :if={@menu} id={@id} />
    """
  end

  def install_switch(%{variant: :sidebar} = assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-role="sidebar-install-switch"
      data-variant="sidebar"
      data-install-name={@brand_name}
      data-current-unread={@current_unread}
      phx-hook="NativeInstallSwitch"
      aria-label={"Switch install, current: #{@brand_name}"}
      class="flex min-w-0 shrink items-center gap-2 rounded-md px-1.5 py-1 -ml-1.5 text-base-content lg:hover:bg-base-300 aria-expanded:bg-base-300 focus-visible-ring"
    >
      <img src={~p"/images/burrow-mark.svg"} alt={@brand_name} class="size-5 shrink-0" />
      <span class="min-w-0 truncate text-sm font-semibold text-base-content">{@brand_name}</span>
      <span class="hero-chevron-down size-4 shrink-0 text-subtle" aria-hidden="true"></span>
      <span
        data-role="install-unread-dot"
        class="hidden size-2 shrink-0 rounded-full bg-primary"
        aria-hidden="true"
      >
      </span>
    </button>
    <.install_switch_menu :if={@menu} id={@id} />
    """
  end

  def install_switch(%{variant: :play} = assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-role="play-install-switch"
      data-variant="play"
      data-install-name={@brand_name}
      data-current-unread={@current_unread}
      phx-hook="NativeInstallSwitch"
      aria-label={"Switch install, current: #{@brand_name}"}
      class="hidden cg-brand cg-brand-switch"
    >
      <img src={~p"/images/burrow-mark.svg"} alt="" /><span>PLAY</span>
      <span class="hero-chevron-down cg-brand-chevron" aria-hidden="true"></span>
      <span data-role="install-unread-dot" class="hidden cg-brand-dot" aria-hidden="true"></span>
    </button>
    <.install_switch_menu :if={@menu} id={@id} />
    """
  end

  attr :id, :string, required: true, doc: "the switch button's id; the container is `<id>-menu`"

  @doc "The dropdown container the hook draws into, `phx-update=\"ignore\"`."
  def install_switch_menu(assigns) do
    ~H"""
    <div id={"#{@id}-menu"} data-role="install-switch-menu" phx-update="ignore"></div>
    """
  end
end
