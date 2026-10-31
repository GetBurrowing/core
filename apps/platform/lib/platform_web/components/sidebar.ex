defmodule PlatformWeb.Components.Sidebar do
  @moduledoc """
  The desktop shell's sidebar (Burrow redesign 22, stage 1): at `lg` and up
  the shell is sidebar | main. It replaces the desktop icon rail, its
  collapse control and the utility bar at `lg`. Spec: master-desktop.html
  (`#side`, L569-590).

  ## Rows: the v4 rail, then More

  The module rows are prototype 01a178d2 v4's rail
  (`IconRail.desktop_rail_destinations/1`: Chat, Voice, Tasks, Calendar,
  Meetings), then a "More" label, then `IconRail.desktop_more_rows/2`:
  Inbox with its count badge, the extension rows, then the rest of the More
  sheet's order. The phone bar keeps its own four tabs (the product lead's rule, task
  01a18d9f stage 5), so the two lists are split, but they go through the
  same Scope filter and cover the same destinations: a module the actor may
  not open leaves no gap, and an extension's row arrives through
  `Platform.Extensions.rail_items/0` without core naming the extension.
  `rows/2` is that list.

  The current row is `IconRail.more_sheet_current_key/2` over every row, so
  the longest-prefix rule decides (`/control/usage` is Settings, not
  Agents), and Settings is current on `IconRail.settings_paths/0`.

  ## Brand row

  The mark, the install's name and, at the right end, `#cmdk-btn`
  (rung 23 stage 3): a 34px round icon button that pushes `palette_open` to
  the shell's `PlatformWeb.CommandPaletteLive` (`#command-palette`).

  ## Footer

  Settings, the theme mode row (`#mode-toggle`), the "Names masked" chip
  while masked, and the user row, which links `/settings` (where Sign out
  lives). The mode row flips light/dark through the theme picker's own
  path: `window.burrowTheme.apply/1`, then `set_theme` (the `ModeToggle`
  hook). Presets stay in Settings > Appearance, whose Theme row opens the
  picker popover rendered here, beside the mode row. Under the user row, the
  `#sidebar-cmdk-hint` line: "⌘K jump · Esc close".

  ## Paint

  Rest rows are `text-subtle`; hover (`lg:hover:`, the surface is desktop
  only) and current are `bg-base-300 text-base-content`; current also
  carries a 3px `bg-primary` bar at the row's left (`.sidebar-row`'s
  `::before` in app.css). Widths come from `--sidebar-width` (app.css):
  220px, 200px at or below 1100px.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]
  import PlatformWeb.Components.ThemePicker, only: [theme_picker: 1]
  import PlatformWeb.Components.MaskNamesChip, only: [mask_names_chip: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Accounts
  alias PlatformWeb.Components.IconRail

  attr :current_path, :string, default: "/"
  attr :root_user, :boolean, default: false, doc: "legacy filter, used only without a Scope"
  attr :access_scope, :any, default: nil, doc: "the actor's `%Platform.Access.Scope{}`"
  attr :inbox_unread_count, :integer, default: 0
  attr :chat_unread_count, :integer, default: 0
  attr :meeting_active, :boolean, default: false, doc: "true while a call is live"
  attr :brand_name, :string, default: "", doc: "the install's app name; the mark's alt"
  attr :current_user, :any, default: nil, doc: "the viewer's display name"
  attr :user, :any, default: nil, doc: "the viewer's `%User{}` (avatar, theme preference)"
  attr :org_name, :string, default: nil, doc: "the viewer's org; the user row's small line"
  attr :theme_picker_open, :boolean, default: false

  attr :org_themes, :list,
    default: [],
    doc: "the published org themes the viewer can see, for the picker"

  attr :masked?, :boolean, default: false
  attr :mask_until, :any, default: nil
  attr :mask_zone, :string, default: nil
  attr :connected?, :boolean, default: false
  attr :mask_chip_open, :boolean, default: false

  def sidebar(assigns) do
    {tabs, more} = rows(assigns[:access_scope], Map.get(assigns, :root_user, false))
    resolved = resolved_mode(assigns[:user])

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:more, more)
      |> assign(:current_key, IconRail.more_sheet_current_key(tabs ++ more, assigns.current_path))
      |> assign(:chat_badge, IconRail.chat_badge_text(assigns.chat_unread_count))
      |> assign(:inbox_badge, IconRail.badge_text(assigns.inbox_unread_count))
      |> assign(:resolved_mode, resolved)
      |> assign(:name, display_name(assigns[:current_user], assigns[:user]))

    ~H"""
    <aside
      id="sidebar"
      class="sidebar hidden lg:flex w-[var(--sidebar-width)] shrink-0 min-h-0 flex-col gap-0.5 border-r border-edge bg-base-200 px-2 py-3"
      aria-label="Sidebar"
      data-sidebar
    >
      <div
        id="sidebar-brand"
        class="flex h-9 shrink-0 items-center gap-2 px-2 pb-1"
        data-role="sidebar-brand"
      >
        <img src={~p"/images/burrow-mark.svg"} alt={@brand_name} class="size-5 shrink-0" />
        <span class="min-w-0 truncate text-sm font-semibold text-base-content">
          {@brand_name}
        </span>
        <span class="flex-1"></span>
        <%!-- masters #cmdk-btn (L570, .icon-btn L65): opens the palette
             mounted once in the shell (CommandPaletteLive, #command-palette). --%>
        <button
          id="cmdk-btn"
          type="button"
          title="Jump anywhere (⌘K)"
          aria-label="Command palette"
          phx-click={JS.push("palette_open", target: "#command-palette")}
          class="inline-flex size-[34px] shrink-0 items-center justify-center rounded-full text-subtle lg:hover:bg-base-300 lg:hover:text-base-content focus-visible-ring"
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
        </button>
      </div>

      <nav
        id="sidebar-nav"
        class="-mx-2 flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto px-2"
        aria-label="Main navigation"
      >
        <.row
          :for={dest <- @tabs}
          dest={dest}
          icon={IconRail.tab_icon(dest.key, false)}
          current?={dest.key == @current_key}
        >
          <span
            :if={dest.key == :chat and @chat_badge}
            id="chat-badge"
            data-role="chat-badge"
            class="ml-auto inline-flex h-[18px] min-w-[18px] shrink-0 items-center justify-center rounded-full bg-primary px-[5px] text-xs font-bold leading-none tabular-nums text-primary-content"
            aria-label={"#{@chat_unread_count} unread messages"}
          >
            {@chat_badge}
          </span>
          <span
            :if={dest.key == :meetings and @meeting_active}
            data-role="live-call-dot"
            class="ml-auto size-[7px] shrink-0 rounded-full bg-success"
            title="live call"
          >
          </span>
        </.row>

        <div
          :if={@more != []}
          class="px-2 pt-3 pb-1 text-xs font-semibold uppercase tracking-[.08em] text-subtle"
          data-role="sidebar-more-label"
        >
          More
        </div>

        <.row
          :for={dest <- @more}
          dest={dest}
          icon={Map.get(dest, :hero_icon) || "hero-puzzle-piece"}
          current?={dest.key == @current_key}
        >
          <span
            :if={dest.key == :inbox and @inbox_badge}
            id="inbox-badge"
            data-role="inbox-badge"
            class="ml-auto inline-flex h-[18px] min-w-[18px] shrink-0 items-center justify-center rounded-full bg-primary px-[5px] text-xs font-bold leading-none tabular-nums text-primary-content"
            aria-label={"#{@inbox_unread_count} unread"}
          >
            {@inbox_badge}
          </span>
        </.row>
      </nav>

      <div class="flex shrink-0 flex-col gap-0.5 pt-2">
        <.row
          dest={%{key: :settings, label: "Settings", path: ~p"/settings"}}
          icon="hero-cog-6-tooth"
          current?={@current_key == :settings}
        />

        <div class="relative">
          <button
            id="mode-toggle"
            type="button"
            phx-hook="ModeToggle"
            data-resolved={@resolved_mode}
            class="sidebar-row focus-visible-ring text-subtle lg:hover:bg-base-300 lg:hover:text-base-content"
          >
            <%!-- The crescent is masters' own glyph (L588), inline: the
                 heroicon's class name is a token the install-identity guard
                 denies on every rendered page
                 (install_identity_rendered_pages_test.exs). --%>
            <svg
              data-mode-icon="dark"
              class={["size-[18px] shrink-0", @resolved_mode != "dark" && "hidden"]}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M12 3a9 9 0 1 0 9 9c0-.5 0-1-.1-1.4A5.5 5.5 0 0 1 13.4 3.1C13 3 12.5 3 12 3z" />
            </svg>
            <span
              data-mode-icon="light"
              class={["hero-sun size-[18px] shrink-0", @resolved_mode == "dark" && "hidden"]}
              aria-hidden="true"
            >
            </span>
            <span id="mode-label" data-mode-label class="min-w-0 truncate">
              {mode_label(@resolved_mode)}
            </span>
          </button>
          <.theme_picker open={@theme_picker_open} user={@user} org_themes={@org_themes} />
        </div>

        <div :if={@masked?} class="px-1 py-2.5">
          <.mask_names_chip
            id_prefix="sidebar-mask-names"
            popover_class="left-0 bottom-full mb-1"
            masked?={@masked?}
            until={@mask_until}
            zone={@mask_zone}
            connected?={@connected?}
            open={@mask_chip_open}
          />
        </div>

        <.link
          id="sidebar-user"
          navigate={~p"/settings"}
          class="flex items-center gap-2 rounded-field p-2 text-sm text-base-content lg:hover:bg-base-300 focus-visible-ring"
          data-nav-label="Settings"
        >
          <.human_avatar
            name={@name}
            avatar_url={Map.get(@user || %{}, :avatar_url)}
            seed={Map.get(@user || %{}, :id) || @name}
            size="sm"
          />
          <span class="min-w-0">
            <b class="block truncate font-semibold" data-role="sidebar-user-name">{@name}</b>
            <small
              :if={is_binary(@org_name) and @org_name != ""}
              class="block truncate text-xs text-subtle"
              data-role="sidebar-user-org"
            >
              {@org_name}
            </small>
          </span>
        </.link>

        <%!-- masters .side .ck (L590, CSS L46; kbd CSS L25). The kbd is
             text-xs, not masters' 11px: subtle text under 12px is frozen
             (subtle_text_ratchet_test.exs, ADR 0050). --%>
        <div
          id="sidebar-cmdk-hint"
          data-role="sidebar-cmdk-hint"
          class="flex items-center gap-1.5 px-2 py-1 text-xs text-subtle"
        >
          <kbd class={kbd_class()}>⌘K</kbd> jump · <kbd class={kbd_class()}>Esc</kbd> close
        </div>
      </div>
    </aside>
    """
  end

  defp kbd_class, do: "rounded border border-edge px-[5px] font-mono text-xs text-subtle"

  attr :dest, :map, required: true
  attr :icon, :string, required: true
  attr :current?, :boolean, default: false
  slot :inner_block

  defp row(assigns) do
    ~H"""
    <.link
      navigate={@dest.path}
      class={[
        "sidebar-row focus-visible-ring",
        if(@current?,
          do: "sidebar-row--current bg-base-300 text-base-content",
          else: "text-subtle lg:hover:bg-base-300 lg:hover:text-base-content"
        )
      ]}
      data-destination={@dest.key}
      data-module-id={@dest.key}
      data-nav-label={@dest.label}
      aria-current={if @current?, do: "page"}
    >
      <.icon name={@icon} class="size-[18px] shrink-0" />
      <span class="min-w-0 truncate">{@dest.label}</span>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  The sidebar's rows for an actor: `{rail_rows, more_rows}`. Rail rows are
  `IconRail.desktop_rail_destinations/1`; More rows are
  `IconRail.desktop_more_rows/2`. With a Scope both are filtered through it;
  without one the rail rows are unfiltered and the More rows use the legacy
  `root_user` filter, as the phone does.
  """
  @spec rows(Platform.Access.Scope.t() | nil, boolean()) :: {[map()], [map()]}
  def rows(scope, root_user) do
    {IconRail.desktop_rail_destinations(scope), IconRail.desktop_more_rows(scope, root_user)}
  end

  @doc "The keys `rows/2` renders, in order (rail rows, then More rows)."
  @spec row_keys(Platform.Access.Scope.t() | nil, boolean()) :: [atom()]
  def row_keys(scope, root_user) do
    {tabs, more} = rows(scope, root_user)
    Enum.map(tabs ++ more, & &1.key)
  end

  @doc """
  The mode row's label for a resolved mode: it names the mode a click turns
  ON, so a dark page reads "Light mode".
  """
  @spec mode_label(String.t()) :: String.t()
  def mode_label("light"), do: "Dark mode"
  def mode_label(_dark), do: "Light mode"

  # The server cannot resolve "system"; it paints as dark, as the picker's
  # first frame does, and the ModeToggle hook repaints from the page's
  # resolved theme on mount and after every patch.
  @doc "The mode the server paints first: \"light\" or \"dark\" (system paints dark)."
  @spec resolved_mode(term()) :: String.t()
  def resolved_mode(user) do
    # Only the mode is read, and the mode never depends on which org presets
    # are visible, so no visible set is fetched (an empty one is passed).
    case Accounts.theme_preference(user, []) do
      %{"mode" => "light"} -> "light"
      _ -> "dark"
    end
  end

  defp display_name(name, _user) when is_binary(name) and name != "", do: name
  defp display_name(_, %{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_, _), do: "Account"
end
