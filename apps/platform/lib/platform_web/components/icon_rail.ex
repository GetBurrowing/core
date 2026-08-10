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
    * `aria-current="page"` on the single active tile. Active state uses
      segment-boundary longest-prefix matching against `current_path`, so a
      nested route (`/chat/:slug`, `/tasks/:id`, `/org_memory/*file_key`) lights
      its parent tile; among overlapping prefixes the longest path wins
      (`/admin/prompts` → Prompts, not Admin). See `active_destination_key/2`.
    * `aria-label` on every tile.

  Stage 3 still owns:

    * Wiring `<.link>` / navigation (Stage 2 keeps tiles as `<div>`/`<button>`).
    * Reconciling destinations whose `:path` doesn't yet have a route.

  ## Single-source-of-truth architecture

  Both desktop and mobile views consume the same `destinations/1` list.
  The list carries the hero icon name, label, path, cluster, and a
  `fabrikam_only?` flag. Admin and Prompts are `fabrikam_only?: true` today (as of
  2026-05-20); consumers filter on the flag via `is_fabrikam_user`.
  Future destinations (e.g. Inbox, Context, Memory, Prompts) may not yet
  have routes; their `:path` values are noted in the entry but the actual
  link wiring is deferred to Stage 3.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

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

  attr(:inbox_unread_count, :integer,
    default: 0,
    doc:
      "current user's non-dismissed inbox count; renders an attention badge on the Inbox tile. " <>
        "0 omits the badge node entirely. Desktop icon_rail/1 only — the mobile bottom_rail " <>
        "Inbox badge is a separate future stage."
  )

  attr(:destinations, :list,
    default: nil,
    doc:
      "test/preview seam — overrides the canonical destination list. Entries may carry " <>
        ":children (indent-only rows, task 019f575e stage 4); production always uses the " <>
        "canonical list (nil)."
  )

  @doc """
  Desktop vertical icon-rail. Hidden below the `lg` breakpoint.

  Each tile renders a hero icon glyph plus (when expanded) a text label.
  The tile whose `:path` is the longest matching prefix of `current_path`
  gets `.icon-rail-tab--active` and `aria-current="page"`.
  """
  def icon_rail(assigns) do
    is_fabrikam_user = Map.get(assigns, :is_fabrikam_user, false)
    current_path = Map.get(assigns, :current_path, "/")
    collapsed = Map.get(assigns, :sidebar_collapsed, false)
    all = assigns[:destinations] || canonical_destinations()

    live = cluster_destinations(all, :live, is_fabrikam_user)
    working = cluster_destinations(all, :working, is_fabrikam_user)
    admin = cluster_destinations(all, :admin, is_fabrikam_user)

    visible = live ++ working ++ admin

    # Single winner computed across every VISIBLE desktop destination so the
    # CSS active class and aria-current can never disagree, and so a
    # fabrikam-filtered tile never lights up. Children join the pool only when
    # expanded: collapsed mode doesn't render child rows, and the parent's
    # shorter prefix then wins the match so the iconed parent lights up.
    # See active_destination_key/2.
    pool =
      if collapsed do
        visible
      else
        visible ++ Enum.flat_map(visible, &Map.get(&1, :children, []))
      end

    assigns =
      assigns
      |> assign(:live_destinations, live)
      |> assign(:working_destinations, working)
      |> assign(:admin_destinations, admin)
      |> assign(:active_key, active_destination_key(pool, current_path))

    ~H"""
    <nav
      id="shell-sidebar"
      class={[
        "icon-rail hidden lg:flex flex-col gap-2 border-r border-base-300 bg-base-200 pb-4 px-2 transition-[width] duration-[var(--duration-base)] ease-[var(--ease-standard)]",
        if(@sidebar_collapsed, do: "lg:w-14", else: "w-56")
      ]}
      role="navigation"
      aria-label="Main navigation"
      data-icon-rail
    >
      <%!-- Brand header (task 019f575e). Expanded: logo mark + wordmark +
           right-aligned collapse toggle. Collapsed (v2, 2026-07-14): the logo
           is hidden and the expand toggle takes the 40px header slot — always
           visible, no separate row below — so the control stays at header level
           and never drops into the icon column to read as a nav destination.
           -mx-2/px-2 lets the hairline span the full rail width despite the
           nav's px-2 inset. --%>
      <div class="icon-rail-header -mx-2 flex h-12 flex-shrink-0 items-center border-b border-base-300 px-2">
        <div
          :if={!@sidebar_collapsed}
          class="flex size-10 flex-shrink-0 items-center justify-center"
        >
          <img src={~p"/images/logo.svg"} alt="Startup Suite" class="size-5" />
        </div>
        <span :if={!@sidebar_collapsed} class="icon-rail-label text-sm font-semibold">
          Startup Suite
        </span>
        <button
          :if={!@sidebar_collapsed}
          type="button"
          class="ml-auto flex size-8 flex-shrink-0 items-center justify-center rounded-lg text-base-content/40 transition-colors hover:bg-base-300 hover:text-base-content"
          phx-click="toggle_sidebar"
          title="Collapse sidebar"
          aria-label="Collapse sidebar"
        >
          <.icon name="hero-chevron-double-left" class="size-4" />
        </button>
        <button
          :if={@sidebar_collapsed}
          type="button"
          class="mx-auto flex size-10 flex-shrink-0 items-center justify-center rounded-lg text-base-content/40 transition-colors hover:bg-base-300 hover:text-base-content"
          phx-click="toggle_sidebar"
          title="Expand sidebar"
          aria-label="Expand sidebar"
        >
          <.icon name="hero-chevron-double-right" class="size-5" />
        </button>
      </div>

      <%!-- Group eyebrows (task 019f575e stage 4): the cluster names carry
           real meaning — Live = real-time surfaces, Working = reference —
           so expanded mode labels them instead of a bare divider. Collapsed
           mode degrades each eyebrow to a hairline (except Live, whose
           upper boundary is the header hairline). --%>
      <.rail_eyebrow
        label="Live"
        sidebar_collapsed={@sidebar_collapsed}
        collapsed_divider={false}
      />
      <.rail_cluster
        destinations={@live_destinations}
        cluster="live"
        active_key={@active_key}
        sidebar_collapsed={@sidebar_collapsed}
        inbox_unread_count={@inbox_unread_count}
      />

      <.rail_eyebrow label="Working" sidebar_collapsed={@sidebar_collapsed} />
      <.rail_cluster
        destinations={@working_destinations}
        cluster="working"
        active_key={@active_key}
        sidebar_collapsed={@sidebar_collapsed}
        inbox_unread_count={@inbox_unread_count}
      />

      <div class="mt-auto" aria-hidden="true"></div>
      <%= if @is_fabrikam_user do %>
        <%!-- Admin cluster keeps its pinned-bottom position and a hairline
             separator in both rail states, but no "Admin" eyebrow label
             (task 019f575e v2, 2026-07-14). --%>
        <hr class="icon-rail-divider border-base-300 my-2" aria-hidden="true" />
        <.rail_cluster
          destinations={@admin_destinations}
          cluster="admin"
          active_key={@active_key}
          sidebar_collapsed={@sidebar_collapsed}
          inbox_unread_count={@inbox_unread_count}
        />
      <% end %>
    </nav>
    """
  end

  # Group eyebrow (expanded) with hairline fallback (collapsed). The Live
  # cluster opts out of the fallback — its upper boundary when collapsed is
  # the brand header's hairline, and stacking two rules reads as a glitch.
  attr(:label, :string, required: true)
  attr(:sidebar_collapsed, :boolean, default: false)
  attr(:collapsed_divider, :boolean, default: true)

  defp rail_eyebrow(assigns) do
    ~H"""
    <div :if={!@sidebar_collapsed} class="icon-rail-eyebrow">{@label}</div>
    <hr
      :if={@sidebar_collapsed and @collapsed_divider}
      class="icon-rail-divider border-base-300 my-2"
    />
    """
  end

  # One cluster of destinations. Child entries (dest.children) render as
  # indent-only rows — no icon, text aligned with the parent label, same
  # hover pill and active grammar as parents (Console "Managed Agents"
  # pattern, task 019f575e stage 4). Children never render collapsed; the
  # active pool in icon_rail/1 lets the parent light up instead.
  attr(:destinations, :list, required: true)
  attr(:cluster, :string, required: true)
  attr(:active_key, :atom, default: nil)
  attr(:sidebar_collapsed, :boolean, default: false)
  attr(:inbox_unread_count, :integer, default: 0)

  defp rail_cluster(assigns) do
    ~H"""
    <div class={"icon-rail-cluster icon-rail-cluster--#{@cluster}"} data-cluster={@cluster}>
      <%= for dest <- @destinations do %>
        <.link
          navigate={dest.path}
          class={["icon-rail-tab", desktop_active_class(dest, @active_key)]}
          data-destination={dest.key}
          data-module-id={dest.key}
          aria-label={dest.label}
          aria-current={aria_current_for(dest, @active_key)}
          title={dest.label}
        >
          <%!-- Icon wrapped in a relative anchor so the Inbox unread badge can
               pin to its top-right corner. The badge is icon-anchored (not
               label-anchored) so it survives the collapsed rail. Hidden at 0:
               badge_text/1 returns nil, so the `:if` drops the node from the
               DOM entirely rather than rendering an empty/transparent pill. --%>
          <span class="relative flex-shrink-0">
            <.icon name={dest.hero_icon} class="icon-rail-icon size-5" />
            <span
              :if={dest.key == :inbox && badge_text(@inbox_unread_count)}
              class="badge badge-error badge-xs absolute -top-1.5 -right-1.5 min-w-[1rem] px-1 leading-none tabular-nums pointer-events-none"
              data-role="inbox-badge"
              aria-label={"#{@inbox_unread_count} unread"}
            >
              {badge_text(@inbox_unread_count)}
            </span>
          </span>
          <span :if={!@sidebar_collapsed} class="icon-rail-label">{dest.label}</span>
        </.link>
        <.link
          :for={child <- Map.get(dest, :children, [])}
          :if={!@sidebar_collapsed}
          navigate={child.path}
          class={["icon-rail-tab icon-rail-tab--child", desktop_active_class(child, @active_key)]}
          data-destination={child.key}
          data-module-id={child.key}
          aria-label={child.label}
          aria-current={aria_current_for(child, @active_key)}
          title={child.label}
        >
          <span class="icon-rail-label">{child.label}</span>
        </.link>
      <% end %>
    </div>
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
    current_path = Map.get(assigns, :current_path, "/")
    primary = mobile_primary_destinations()

    assigns =
      assigns
      |> assign(:mobile_destinations, primary)
      # Winner computed over the 4 primary tiles only — a More-sheet-only
      # surface (Skills, Org Memory, Meetings, Admin) lights nothing in the bar.
      |> assign(:active_key, active_destination_key(primary, current_path))

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
        class={["bottom-nav-tab", mobile_active_class(dest, @active_key)]}
        data-destination={dest.key}
        data-module-id={dest.key}
        aria-label={dest.label}
        aria-current={aria_current_for(dest, @active_key)}
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
    * `:fabrikam_only?` — boolean; today `:admin` and `:prompts` are `true`

  When `opts[:is_fabrikam_user]` is `false` (default), all `fabrikam_only?: true`
  entries are omitted from the returned list.
  """
  def destinations(opts \\ []) do
    is_fabrikam_user = Keyword.get(opts, :is_fabrikam_user, false)

    canonical_destinations()
    |> Enum.reject(fn dest -> dest.fabrikam_only? and not is_fabrikam_user end)
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp cluster_destinations(all, cluster, is_fabrikam_user) do
    all
    |> Enum.filter(&(&1.cluster == cluster))
    |> filter_fabrikam_only(is_fabrikam_user)
  end

  # Apply the fabrikam_only? filter against a per-render is_fabrikam_user flag.
  # Used at the icon_rail/1 render boundary so EVERY cluster (live /
  # working / admin) honors fabrikam_only? consistently. Previously only the
  # admin cluster had a `:if={@is_fabrikam_user}` template gate, which meant
  # a fabrikam_only?:true tile in the working cluster (e.g. Prompts) still
  # rendered for members. Fixed 2026-05-20.
  defp filter_fabrikam_only(destinations, is_fabrikam_user) do
    Enum.reject(destinations, fn dest -> dest.fabrikam_only? and not is_fabrikam_user end)
  end

  defp mobile_primary_destinations do
    # Chat / Tasks / Inbox / Activity — 4 surfaces; More is the 5th tile,
    # rendered separately because it's a button (phx-click), not a link.
    canonical_destinations()
    |> Enum.filter(&(&1.key in [:chat, :tasks, :inbox, :activity]))
  end

  # Resolve the single active destination for a path. A destination matches
  # when current_path is the destination path itself OR a descendant of it at a
  # segment boundary (current_path starts with `path <> "/"`). Among matches the
  # longest path wins, so `/admin/prompts` activates Prompts rather than its
  # `/admin` prefix. Returns the winning `:key`, or nil when nothing matches.
  #
  # Why segment-boundary (`path <> "/"`) rather than a bare String.starts_with?:
  # a bare prefix would let `/tasksy` match `/tasks`. Why longest-wins rather
  # than first-match: the canonical list order must not silently decide
  # overlapping prefixes.
  defp active_destination_key(destinations, current_path) do
    destinations
    |> Enum.filter(&path_matches?(&1.path, current_path))
    |> Enum.sort_by(&String.length(&1.path), :desc)
    |> case do
      [winner | _] -> winner.key
      [] -> nil
    end
  end

  defp path_matches?(path, current_path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end

  # Active-state classes — desktop uses the icon-rail variant, mobile reuses
  # the existing bottom-nav variant (Phase-4 chrome). Both attach a 3px bar
  # accent via `::before` (left for desktop, top for mobile). The active tile is
  # the precomputed `active_key` winner (see active_destination_key/2), so these
  # only do a cheap key comparison and never re-derive the match per tile.
  defp desktop_active_class(dest, active_key) do
    if dest.key == active_key do
      "icon-rail-tab--active bg-base-300 text-primary"
    else
      nil
    end
  end

  defp mobile_active_class(dest, active_key) do
    if dest.key == active_key, do: "bottom-nav-tab--active", else: nil
  end

  defp aria_current_for(dest, active_key) do
    if dest.key == active_key, do: "page", else: nil
  end

  # Inbox unread-badge label. Returns nil at 0 (badge node omitted from the
  # DOM), the integer as a string for 1..99, and "99+" for anything above 99
  # (ADR-0022 DM-badge overflow grammar). Non-integer inputs are treated as 0.
  defp badge_text(count) when is_integer(count) do
    cond do
      count <= 0 -> nil
      count > 99 -> "99+"
      true -> Integer.to_string(count)
    end
  end

  defp badge_text(_), do: nil

  # Canonical 11-entry destination list. Order within a cluster determines
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
        # ADR-0042 stage 5: project-scoped document store (FilesLive).
        # Lives next to Skills/Memory in the Working cluster; available
        # to every authenticated user (not Fabrikam-gated).
        key: :files,
        label: "Files",
        path: "/files",
        hero_icon: "hero-document-text",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        # T7 stage 2 (2026-05-20): renamed surface from "Context + Memory"
        # to "Org Memory" and route from `/org-context` to `/org_memory`.
        # The OrgMemoryLive LiveView owns both the Files and Memory tabs.
        # Old `/org-context[/:file_key]` paths 301-redirect to the new
        # canonical paths via PageController.
        key: :context,
        label: "Org Memory",
        path: "/org_memory",
        hero_icon: "hero-building-library",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        key: :prompts,
        # Prompts is admin-only per the route gate (live_session :admin /
        # ensure_admin). Rail entry was previously fabrikam_only?: false which
        # rendered the tile for members but redirected on click — fixed
        # 2026-05-20. Kept in working cluster (vs admin cluster) because
        # Prompts is the most-frequently-used admin surface for admins.
        label: "Prompts",
        path: "/admin/prompts",
        hero_icon: "hero-command-line",
        cluster: :working,
        fabrikam_only?: true
      },
      %{
        # Task 019fe6ba / ADR-0048: the experiments surface at
        # `/control/experiments`. Deliberately NOT fabrikam_only? — the routes
        # sit in `live_session :authenticated`, so reads are member-visible
        # and the tile must be too. Writes (start/stop/conclude) stay
        # admin-gated server-side inside the LiveView, which is where the
        # asymmetry belongs; hiding the tile would make an approved
        # member-readable surface unreachable, which is exactly the defect
        # this entry fixes.
        key: :experiments,
        label: "Experiments",
        path: "/control/experiments",
        hero_icon: "hero-beaker",
        cluster: :working,
        fabrikam_only?: false
      },
      %{
        # Task 019fea0d / ADR-0048: the pipeline health surface at
        # `/control/pipeline`. It shipped with routes and tests but no nav
        # entry anywhere, so it was reachable only by typing the URL — the
        # same defect the Experiments entry above fixes, found while fixing
        # that one. Like Experiments it sits in `live_session :authenticated`,
        # so it is member-visible and NOT fabrikam_only?.
        key: :pipeline,
        label: "Pipeline",
        path: "/control/pipeline",
        hero_icon: "hero-chart-bar",
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
        path: "/admin",
        hero_icon: "hero-cog-6-tooth",
        cluster: :admin,
        fabrikam_only?: true
      }
    ]
  end
end
