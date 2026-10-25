defmodule PlatformWeb.Components.ThemePicker do
  @moduledoc """
  The theme picker (task 01a1557a, Burrow redesign 2, stage 4). It replaced
  the dark/light toggle in the old utility bar.

  Opened by Settings > Appearance > Theme (`toggle_theme_picker`). Burrow
  redesign 22 stage 1 deleted the utility bar's swatch trigger: at `lg` the
  sidebar's mode row (`#mode-toggle`) flips light/dark in one click, and the
  presets live behind Settings > Appearance.

  Two function components:

    * `theme_picker/1`: at `lg` and above, a popover. The desktop sidebar
      renders it inside the mode row's positioned wrapper, so it opens above
      that row.
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
    * "Your themes" (task 01a1557a-fe9b stage 3): after the Theme group, a
      `text-subtle` section label (the masters' Appearance label) and a
      second `role="radiogroup"` with one row per published org theme the
      person can see (`org_themes`, from `Platform.Theming.list_published_for_user/1`),
      in the same row markup as a preset (`preset_row/1`): a chip carrying
      `data-preset="org-<id>"` + `data-theme`, painted by the root layout's
      `<style id="org-themes">`, then the name and the check. Nothing at all
      renders when the list is empty. The rows use `data-theme-option="preset"`,
      so the ThemePicker hook needs no change: it checks, paints and applies
      them like any preset (the boot script accepts the id because the root
      layout added it to `data-presets`), and its arrow keys move across both
      preset groups as one list.
    * Newly published themes reach the picker on the next full page load
      (ShellLive reads them per mount; the root layout that paints their
      chips is not re-rendered on live navigation).
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
  alias Platform.Theming.OrgTheme

  @mode_labels %{"light" => "Light", "dark" => "Dark", "system" => "System"}

  attr :open, :boolean, default: false
  attr :user, :any, default: nil, doc: "the signed-in `%User{}`, for the first-frame state"

  attr :org_themes, :list,
    default: [],
    doc: "the published `OrgTheme`s the person can see, for \"Your themes\""

  def theme_picker(assigns) do
    assigns = assign_pref(assigns)

    ~H"""
    <div id="theme-picker" class="max-lg:hidden">
      <div
        id="theme-picker-popover"
        role="dialog"
        aria-label="Theme"
        class={[
          "absolute left-0 bottom-full mb-1 z-50 w-72 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-3 shadow-lg",
          if(@open, do: "hidden lg:block", else: "hidden")
        ]}
        phx-click-away={@open && "close_theme_picker"}
        phx-window-keydown={@open && "close_theme_picker"}
        phx-key={@open && "Escape"}
      >
        <.picker_body id="theme-picker-popover-body" pref={@pref} org_themes={@org_themes} />
      </div>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :user, :any, default: nil, doc: "the signed-in `%User{}`, for the first-frame state"

  attr :org_themes, :list,
    default: [],
    doc: "the published `OrgTheme`s the person can see, for \"Your themes\""

  def theme_picker_sheet(assigns) do
    assigns = assign_pref(assigns)

    ~H"""
    <.sheet
      id="theme-picker-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_theme_picker"
      class="lg:hidden"
    >
      <:title>Theme</:title>
      <.picker_body id="theme-picker-sheet-body" pref={@pref} org_themes={@org_themes} />
    </.sheet>
    """
  end

  defp assign_pref(assigns) do
    visible = Enum.map(assigns.org_themes, &OrgTheme.preset_id/1)
    assign(assigns, :pref, Accounts.theme_preference(assigns.user, visible))
  end

  attr :id, :string, required: true
  attr :pref, :map, required: true
  attr :org_themes, :list, default: []

  defp picker_body(assigns) do
    pref = assigns.pref
    # The server cannot resolve "system"; the hook repaints on mount.
    resolved = if pref["mode"] in ["light", "dark"], do: pref["mode"], else: "dark"

    assigns =
      assigns
      |> assign(:presets, ThemePreference.presets())
      |> assign(
        :org_rows,
        Enum.map(assigns.org_themes, &%{id: OrgTheme.preset_id(&1), name: &1.name})
      )
      |> assign(:modes, ThemePreference.modes())
      |> assign(:mode_labels, @mode_labels)
      |> assign(:resolved, resolved)

    ~H"""
    <div id={@id} phx-hook="ThemePicker" phx-update="ignore" class="theme-picker flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <p id={"#{@id}-mode-label"} class="text-xs font-medium text-base-content">Mode</p>
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
            class="rounded-field px-2 py-1 text-sm text-base-content hover:text-base-content aria-checked:bg-base-100 aria-checked:text-base-content aria-checked:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            {Map.fetch!(@mode_labels, mode)}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-1.5">
        <p id={"#{@id}-preset-label"} class="text-xs font-medium text-base-content">Theme</p>
        <div
          role="radiogroup"
          aria-labelledby={"#{@id}-preset-label"}
          data-theme-group="preset"
          class="flex flex-col gap-0.5"
        >
          <.preset_row :for={preset <- @presets} preset={preset} pref={@pref} resolved={@resolved} />
        </div>
      </div>

      <div :if={@org_rows != []} class="flex flex-col gap-1.5" data-role="your-themes">
        <p
          id={"#{@id}-org-label"}
          data-role="your-themes-label"
          class="text-xs font-semibold uppercase tracking-[.08em] text-subtle"
        >
          Your themes
        </p>
        <div
          role="radiogroup"
          aria-labelledby={"#{@id}-org-label"}
          data-theme-group="preset"
          data-role="your-themes-rows"
          class="flex flex-col gap-0.5"
        >
          <.preset_row :for={preset <- @org_rows} preset={preset} pref={@pref} resolved={@resolved} />
        </div>
      </div>
    </div>
    """
  end

  # One preset row: a shipped preset or a published org theme, the same
  # markup for both (task 01a1557a-fe9b stage 3 lifted it out of the loop).
  # The chip carries the preset's `data-preset` and the resolved
  # `data-theme`, so its own block (theme_presets.css, or the root layout's
  # org-themes style) paints it.
  attr :preset, :map, required: true
  attr :pref, :map, required: true
  attr :resolved, :string, required: true

  defp preset_row(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      data-theme-option="preset"
      data-value={@preset.id}
      aria-checked={to_string(@preset.id == @pref["preset"])}
      tabindex={if @preset.id == @pref["preset"], do: "0", else: "-1"}
      class="flex items-center gap-3 rounded-field px-2 py-1.5 text-left text-sm text-base-content lg:hover:bg-base-200 aria-checked:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    >
      <span
        class="theme-chip flex h-10 w-16 shrink-0 items-center gap-1.5 overflow-hidden rounded-box border border-edge bg-base-100 px-2"
        data-theme-chip
        data-preset={@preset.id}
        data-theme={@resolved}
        aria-hidden="true"
      >
        <span class="size-3 shrink-0 rounded-full bg-primary"></span>
        <span class="theme-chip-sample text-sm leading-none text-base-content">Aa</span>
      </span>
      <span class="flex-1">{@preset.name}</span>
      <span
        data-theme-check
        class={[
          "hero-check size-4 shrink-0 text-primary",
          @preset.id != @pref["preset"] && "invisible"
        ]}
        aria-hidden="true"
      >
      </span>
    </button>
    """
  end
end
