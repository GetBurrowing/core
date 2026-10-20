defmodule PlatformWeb.Components.ThemePicker do
  @moduledoc """
  The utility bar's theme picker (task 01a1557a, Burrow redesign 2, stage 4).
  It replaces the dark/light toggle that sat in the same place.

  Two function components, both self-contained so a later surface (Settings >
  Appearance, the desktop shell) can move them without editing this module:

    * `theme_picker/1`: the trigger plus, at `lg` and above, a popover
      anchored under it.
    * `theme_picker_sheet/1`: below `lg`, the same body in a bottom
      `<.sheet>`. It carries `lg:hidden`, so at `lg` it is `display: none`
      even while the shared `open` flag is true. Render it outside any
      positioned header so the sheet's `position: fixed` is not trapped.

  Contents, from direction canvas 01a1585a:

    * "Mode": Light | Dark | System, one `role="radiogroup"`.
    * "Theme": one row per `Platform.Accounts.ThemePreference.presets/0`
      entry, in registry order, also a `role="radiogroup"`.
    * Each row's chip carries `data-preset` and `data-theme`, so the preset
      blocks in `theme_presets.css` paint the chip with that preset's own
      surface, accent, font and radius. Only the chips paint other presets;
      the picker chrome follows the active theme.
    * A click applies at once. There is no Save button.
    * The canvas's footer link "More in Settings > Appearance" is NOT
      rendered: no settings route exists yet (rung 19 builds it), and a link
      to nothing is worse than none. Known gap.

  The `ThemePicker` JS hook (`assets/js/hooks/theme_picker.js`) owns the
  chips' `data-theme`, the checked row and `aria-checked` after mount. The
  body is `phx-update="ignore"`, so a LiveView patch cannot reset them. The
  server render below is only the first frame: the stored preference, with a
  `system` mode painted as dark until the hook resolves it.

  Selecting calls `window.burrowTheme.apply/1` (the root layout's boot
  script) and then pushes `set_theme`, which `PlatformWeb.ShellLive`'s
  `:drawer_events` hook persists through `Platform.Accounts.put_theme_preference/2`.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet

  alias Platform.Accounts
  alias Platform.Accounts.ThemePreference

  @mode_labels %{"light" => "Light", "dark" => "Dark", "system" => "System"}

  attr :open, :boolean, default: false
  attr :user, :any, default: nil, doc: "the signed-in `%User{}`, for the first-frame state"

  def theme_picker(assigns) do
    assigns = assign(assigns, :pref, Accounts.theme_preference(assigns.user))

    ~H"""
    <div id="theme-picker" class="relative">
      <%!-- While the popover is open the trigger pushes nothing: the
            popover's click-away closes it, and a toggle here would reopen it
            in the same click. Below lg the sheet's backdrop covers the
            trigger. --%>
      <button
        id="theme-picker-trigger"
        type="button"
        phx-click={!@open && "toggle_theme_picker"}
        class="rounded-lg p-1 text-base-content/60 hover:bg-base-300 hover:text-base-content transition-colors"
        aria-label="Theme"
        title="Theme"
        aria-haspopup="dialog"
        aria-expanded={to_string(@open)}
        aria-controls="theme-picker-popover"
      >
        <span class="hero-swatch size-4 align-middle" aria-hidden="true"></span>
      </button>

      <div
        id="theme-picker-popover"
        role="dialog"
        aria-label="Theme"
        class={[
          "absolute right-0 top-full mt-1 z-50 w-72 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-3 shadow-lg",
          if(@open, do: "hidden lg:block", else: "hidden")
        ]}
        phx-click-away={@open && "close_theme_picker"}
        phx-window-keydown={@open && "close_theme_picker"}
        phx-key={@open && "Escape"}
      >
        <.picker_body id="theme-picker-popover-body" pref={@pref} />
      </div>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :user, :any, default: nil, doc: "the signed-in `%User{}`, for the first-frame state"

  def theme_picker_sheet(assigns) do
    assigns = assign(assigns, :pref, Accounts.theme_preference(assigns.user))

    ~H"""
    <.sheet
      id="theme-picker-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_theme_picker"
      class="lg:hidden"
    >
      <:title>Theme</:title>
      <.picker_body id="theme-picker-sheet-body" pref={@pref} />
    </.sheet>
    """
  end

  attr :id, :string, required: true
  attr :pref, :map, required: true

  defp picker_body(assigns) do
    pref = assigns.pref
    # The server cannot resolve "system"; the hook repaints on mount.
    resolved = if pref["mode"] in ["light", "dark"], do: pref["mode"], else: "dark"

    assigns =
      assigns
      |> assign(:presets, ThemePreference.presets())
      |> assign(:modes, ThemePreference.modes())
      |> assign(:mode_labels, @mode_labels)
      |> assign(:resolved, resolved)

    ~H"""
    <div id={@id} phx-hook="ThemePicker" phx-update="ignore" class="theme-picker flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <p id={"#{@id}-mode-label"} class="text-xs font-medium text-base-content/70">Mode</p>
        <div
          role="radiogroup"
          aria-labelledby={"#{@id}-mode-label"}
          data-theme-group="mode"
          class="grid grid-cols-3 gap-1 rounded-field bg-base-200 p-1"
        >
          <button
            :for={mode <- @modes}
            type="button"
            role="radio"
            data-theme-option="mode"
            data-value={mode}
            aria-checked={to_string(mode == @pref["mode"])}
            tabindex={if mode == @pref["mode"], do: "0", else: "-1"}
            class="rounded-field px-2 py-1 text-sm text-base-content/70 hover:text-base-content aria-checked:bg-base-100 aria-checked:text-base-content aria-checked:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            {Map.fetch!(@mode_labels, mode)}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-1.5">
        <p id={"#{@id}-preset-label"} class="text-xs font-medium text-base-content/70">Theme</p>
        <div
          role="radiogroup"
          aria-labelledby={"#{@id}-preset-label"}
          data-theme-group="preset"
          class="flex flex-col gap-0.5"
        >
          <button
            :for={preset <- @presets}
            type="button"
            role="radio"
            data-theme-option="preset"
            data-value={preset.id}
            aria-checked={to_string(preset.id == @pref["preset"])}
            tabindex={if preset.id == @pref["preset"], do: "0", else: "-1"}
            class="flex items-center gap-3 rounded-field px-2 py-1.5 text-left text-sm text-base-content hover:bg-base-200 aria-checked:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            <span
              class="theme-chip flex h-10 w-16 shrink-0 items-center gap-1.5 overflow-hidden rounded-box border border-edge bg-base-100 px-2"
              data-theme-chip
              data-preset={preset.id}
              data-theme={@resolved}
              aria-hidden="true"
            >
              <span class="size-3 shrink-0 rounded-full bg-primary"></span>
              <span class="theme-chip-sample text-sm leading-none text-base-content">Aa</span>
            </span>
            <span class="flex-1">{preset.name}</span>
            <span
              data-theme-check
              class={[
                "hero-check size-4 shrink-0 text-primary",
                preset.id != @pref["preset"] && "invisible"
              ]}
              aria-hidden="true"
            >
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
