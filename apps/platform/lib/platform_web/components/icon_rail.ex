defmodule PlatformWeb.Components.IconRail do
  @moduledoc """
  Responsive icon-rail primitive — Phase 5 redesign.

  Two render functions, one canonical destination list:

    * `icon_rail/1`  — desktop vertical rail (≥`lg` breakpoint).
                       56px collapsed / 224px expanded, `hidden lg:flex flex-col`.
                       Two clusters (Live, Working) separated by a divider,
                       with an `mt-auto` Admin slot pinned to the bottom.
    * `bottom_rail/1` — mobile bottom-nav (<`lg` breakpoint). Exactly 5
                       tiles: Chat / Tasks / Inbox / Activity / More. The
                       More tile fires `phx-click="open_more_sheet"` and
                       lives outside `bottom_rail` semantically only — the
                       button is rendered inline here for thumb reach.

  Stage 2 adds:

    * Hero icons on every destination, rendered via `<.icon name="hero-…" />`.
    * Active-state styling at both breakpoints:
        * Desktop: `.icon-rail-tab--active` (3px LEFT-bar accent via `::before`,
          mirroring the mobile TOP-bar accent on `.bottom-nav-tab--active`)
          plus the existing `bg-base-300 text-primary` pill treatment.
        * Mobile: reuses `.bottom-nav-tab--active` verbatim.
    * `aria-current="page"` on the tile whose `path` matches `current_path`.
    * `aria-label` on every tile.

  Stage 3 still owns:

    * Wiring `<.link>` / navigation (Stage 2 keeps tiles as `<div>`/`<button>`).
    * Reconciling destinations whose `:path` doesn't yet have a route.

  ## Single-source-of-truth architecture

  Both desktop and mobile views consume the same `destinations/1` list.
  The list carries the hero icon name, label, path, cluster, and a
  `fabrikam_only?` flag — the Admin entry is the only `fabrikam_only?: true`
  destination today, and consumers filter on it via `is_fabrikam_user`.
  Future destinations (e.g. Inbox, Context, Memory, Prompts) may not yet
  have routes; their `:path` values are noted in the entry but the actual
  link wiring is deferred to Stage 3.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr(:current_path, :string,
    default: "/",
    doc: "current request path; used for active-state styling and aria-current"
  )

  attr(:is_fabrikam_user, :boolean,
    default: false,
    doc: "when true, the Admin slot renders; otherwise it is omitted from the DOM entirely"
  )

  attr(:sidebar_collapsed, :boolean,
    default: false,
    doc: "when true, rail collapses to icon-only (56px); when false, expands to 224px with labels"
  )

  @doc """
  Desktop vertical icon-rail. Hidden below the `lg` breakpoint.

  Each tile renders a hero icon glyph plus (when expanded) a text label.
  The tile whose `:path` matches `current_path` gets `.icon-rail-tab--active`
  and `aria-current="page"`.
  """
  def icon_rail(assigns) do
    assigns =
      assigns
      |> assign(:live_destinations, destinations_for(:live))
      |> assign(:working_destinations, destinations_for(:working))
      |> assign(:admin_destinations, destinations_for(:admin))

    ~H"""
    <nav
      id="shell-sidebar"
      class={[
        "icon-rail hidden lg:flex flex-col gap-2 border-r border-base-300 bg-base-200 py-4 px-2 transition-all duration-200 ease-in-out",
        if(@sidebar_collapsed, do: "lg:w-14", else: "w-56")
      ]}
      role="navigation"
      aria-label="Main navigation"
      data-icon-rail
    >
      <div class="icon-rail-cluster icon-rail-cluster--live" data-cluster="live">
        <.link
          :for={dest <- @live_destinations}
          id={tile_id(dest)}
          navigate={dest.path}
          phx-hook={tile_hook(dest)}
          data-default-chat-path={if dest.key == :chat, do: "/chat"}
          class={["icon-rail-tab", desktop_active_class(dest, @current_path)]}
          data-destination={dest.key}
          aria-label={dest.label}
          aria-current={aria_current_for(dest, @current_path)}
          title={dest.label}
        >
          <.icon name={dest.hero_icon} class="icon-rail-icon size-5 flex-shrink-0" />
          <span :if={!@sidebar_collapsed} class="icon-rail-label">{dest.label}</span>
        </.link>
      </div>

      <hr class="icon-rail-divider border-base-300 my-2" />

      <div class="icon-rail-cluster icon-rail-cluster--working" data-cluster="working">
        <.link
          :for={dest <- @working_destinations}
          navigate={dest.path}
          class={["icon-rail-tab", desktop_active_class(dest, @current_path)]}
          data-destination={dest.key}
          aria-label={dest.label}
          aria-current={aria_current_for(dest, @current_path)}
          title={dest.label}
        >
          <.icon name={dest.hero_icon} class="icon-rail-icon size-5 flex-shrink-0" />
          <span :if={!@sidebar_collapsed} class="icon-rail-label">{dest.label}</span>
        </.link>
      </div>

      <div class="mt-auto icon-rail-cluster icon-rail-cluster--admin" data-cluster="admin">
        <.link
          :for={dest <- @admin_destinations}
          :if={@is_fabrikam_user}
          navigate={dest.path}
          class={["icon-rail-tab", desktop_active_class(dest, @current_path)]}
          data-destination={dest.key}
          aria-label={dest.label}
          aria-current={aria_current_for(dest, @current_path)}
          title={dest.label}
        >
          <.icon name={dest.hero_icon} class="icon-rail-icon size-5 flex-shrink-0" />
          <span :if={!@sidebar_collapsed} class="icon-rail-label">{dest.label}</span>
        </.link>
      </div>

      <%!-- Collapse toggle (desktop only). Lives at the bottom of the rail
           via the Admin cluster's mt-auto pushing the divider below it.
           Wrapped in its own flex slot so it sits flush at the bottom even
           when Admin is hidden for non-Fabrikam users. --%>
      <button
        type="button"
        class="hidden lg:flex items-center justify-center rounded-lg p-1 text-base-content/40 hover:bg-base-300 hover:text-base-content transition-colors"
        phx-click="toggle_sidebar"
        title={if @sidebar_collapsed, do: "Expand sidebar", else: "Collapse sidebar"}
        aria-label={if @sidebar_collapsed, do: "Expand sidebar", else: "Collapse sidebar"}
      >
        <.icon
          name={if @sidebar_collapsed, do: "hero-chevron-right", else: "hero-chevron-left"}
          class="size-5"
        />
      </button>
    </nav>
    """
  end

  @doc """
  Mobile bottom-nav. Hidden at the `lg` breakpoint and above.

  Renders exactly 5 tiles: Chat / Tasks / Inbox / Activity / More. The
  Admin destination lives in the More sheet on mobile, never in the bar
  — `is_fabrikam_user` does not change the tile count here.
  """
  attr(:current_path, :string, default: "/")
  attr(:is_fabrikam_user, :boolean, default: false)

  def bottom_rail(assigns) do
    assigns = assign(assigns, :mobile_destinations, mobile_primary_destinations())

    ~H"""
    <nav
      class="bottom-nav lg:hidden"
      role="navigation"
      aria-label="Main navigation"
      data-bottom-rail
    >
      <.link
        :for={dest <- @mobile_destinations}
        navigate={dest.path}
        class={["bottom-nav-tab", mobile_active_class(dest, @current_path)]}
        data-destination={dest.key}
        aria-label={dest.label}
        aria-current={aria_current_for(dest, @current_path)}
      >
        <.icon name={dest.hero_icon} class="bottom-nav-icon size-5" />
        <span class="bottom-nav-label">{dest.label}</span>
      </.link>

      <button
        type="button"
        phx-click="open_more_sheet"
        class="bottom-nav-tab"
        data-destination="more"
        aria-label="More surfaces"
      >
        <.icon name="hero-ellipsis-horizontal" class="bottom-nav-icon size-5" />
        <span class="bottom-nav-label">More</span>
      </button>
    </nav>
    """
  end

  @doc """
  Returns the canonical destination list for the icon rail.

  Each entry has:

    * `:key` — atom slug, unique
    * `:label` — display text
    * `:path` — string nav target (some destinations don't have routes
      yet; those are flagged with a TODO in the source. Stage 3 wires
      navigation and will reconcile any missing routes.)
    * `:hero_icon` — heroicon class name (rendered in Stage 2)
    * `:cluster` — `:live | :working | :admin`
    * `:fabrikam_only?` — boolean; today only `:admin` is `true`

  When `opts[:is_fabrikam_user]` is `false` (default), the `:admin` cluster
  is omitted from the returned list.
  """
  def destinations(opts \\ []) do
    is_fabrikam_user = Keyword.get(opts, :is_fabrikam_user, false)

    canonical_destinations()
    |> Enum.reject(fn dest -> dest.fabrikam_only? and not is_fabrikam_user end)
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp destinations_for(cluster) do
    canonical_destinations()
    |> Enum.filter(&(&1.cluster == cluster))
  end

  defp mobile_primary_destinations do
    # Chat / Tasks / Inbox / Activity — 4 surfaces; More is the 5th tile,
    # rendered separately because it's a button (phx-click), not a link.
    canonical_destinations()
    |> Enum.filter(&(&1.key in [:chat, :tasks, :inbox, :activity]))
  end

  # Active-state classes — desktop uses the icon-rail variant, mobile reuses
  # the existing bottom-nav variant (Phase-4 chrome). Both attach a 3px bar
  # accent via `::before` (left for desktop, top for mobile).
  defp desktop_active_class(dest, current_path) do
    if dest.path == current_path do
      "icon-rail-tab--active bg-base-300 text-primary"
    else
      nil
    end
  end

  defp mobile_active_class(dest, current_path) do
    if dest.path == current_path, do: "bottom-nav-tab--active", else: nil
  end

  defp aria_current_for(dest, current_path) do
    if dest.path == current_path, do: "page", else: nil
  end

  # The Chat tile carries the LastChatLink JS hook so the link target gets
  # rewritten to the user's most recently visited chat space on the client.
  # Other tiles don't need an id at all.
  defp tile_id(%{key: :chat}), do: "shell-chat-link"
  defp tile_id(_), do: nil

  defp tile_hook(%{key: :chat}), do: "LastChatLink"
  defp tile_hook(_), do: nil

  # Canonical 10-entry destination list. Order within a cluster determines
  # render order in the rail. Paths marked `# TODO` don't have routes yet
  # — Stage 3 wires navigation and will reconcile.
  defp canonical_destinations do
    [
      # Live cluster — high-frequency, real-time surfaces
      %{
        key: :chat,
        label: "Chat",
        path: "/chat",
        hero_icon: "hero-chat-bubble-left-right",
        cluster: :live,
        fabrikam_only?: false
      },
      %{
        key: :tasks,
        label: "Tasks",
        path: "/tasks",
        hero_icon: "hero-rectangle-stack",
        cluster: :live,
        fabrikam_only?: false
      },
      %{
        # Inbox is a future "My Notifications" surface (stack 019e389b-53b9-...).
        # Today the route renders a "Coming Soon" placeholder LV so the tile
        # doesn't 404.
        key: :inbox,
        label: "Inbox",
        path: "/inbox",
        hero_icon: "hero-inbox",
        cluster: :live,
        fabrikam_only?: false
      },
      %{
        key: :activity,
        label: "Activity",
        path: "/activity",
        hero_icon: "hero-sparkles",
        cluster: :live,
        fabrikam_only?: false
      },

      # Working cluster — reference / configuration surfaces
      %{
        key: :skills,
        label: "Skills",
        path: "/skills",
        hero_icon: "hero-book-open",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        # Memory is a TAB within the Context surface (Marlowe 2026-05-18),
        # not a standalone destination. The /org-context LiveView owns
        # both the Context and Memory tabs. Label includes "+ Memory" so
        # users know the page contains both tabs.
        key: :context,
        label: "Context + Memory",
        path: "/org-context",
        hero_icon: "hero-building-library",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        key: :prompts,
        # TODO: closest existing route is /admin/prompts; Stage 3 reconciles.
        label: "Prompts",
        path: "/admin/prompts",
        hero_icon: "hero-command-line",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        key: :meetings,
        label: "Meetings",
        path: "/meetings",
        hero_icon: "hero-video-camera",
        cluster: :working,
        fabrikam_only?: false
      },

      # Admin cluster — Fabrikam-only, gated by `is_fabrikam_user`
      %{
        key: :admin,
        label: "Admin",
        path: "/admin/prompts",
        hero_icon: "hero-cog-6-tooth",
        cluster: :admin,
        fabrikam_only?: true
      }
    ]
  end
end
