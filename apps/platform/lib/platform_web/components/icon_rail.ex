defmodule PlatformWeb.Components.IconRail do
  @moduledoc """
  Responsive icon-rail primitive — Phase 5 redesign.

  Two render functions, one canonical destination list:

    * `icon_rail/1`  — desktop vertical rail (≥`lg` breakpoint).
                       56px collapsed / 224px expanded, `hidden lg:flex flex-col`.
                       Two clusters (Live, Working) separated by a divider,
                       with an `mt-auto` Admin slot pinned to the bottom.
    * `bottom_rail/1` — mobile tab bar (<`lg` breakpoint). Link tabs from
                       `mobile_tab_keys/0` (Chat, Tasks, Meetings, filtered
                       by Scope) plus a More button that fires
                       `phx-click="open_more_sheet"` (`close_more_sheet`
                       while the sheet is open). Inbox and Activity are
                       not in the bar (task 01a1557a-7a71 stage 2): Inbox
                       is the More sheet's first row, and its unread signal
                       is a dot on More.

  Stage 2 adds:

    * Hero icons on every destination, rendered via `<.icon name="hero-…" />`.
    * Active-state styling at both breakpoints:
        * Desktop: `.icon-rail-tab--active` (3px LEFT-bar accent via `::before`,
          plus the existing `bg-base-300 text-primary` pill treatment.
        * Mobile: `.bottom-nav-tab--active` (primary ink, medium label, and
          the solid icon; the top bar was retired by task 01a1557a-7a71).
    * `aria-current="page"` on the single active tile. Active state uses
      segment-boundary longest-prefix matching against `current_path`, so a
      nested route (`/chat/:slug`, `/tasks/:id`, `/org_memory/*file_key`) lights
      its parent tile; among overlapping prefixes the longest path wins
      (`/admin/prompts` → Prompts, not Admin). See `active_destination_key/2`.
    * `aria-label` on every tile.

  Stage 3 still owns:

    * Wiring `<.link>` / navigation (Stage 2 keeps tiles as `<div>`/`<button>`).
    * Reconciling destinations whose `:path` doesn't yet have a route.

  Task 019ffb7b stage 4 first added a notification-state bell here, in the Live
  cluster directly under the Inbox tile. The designer rejected that placement on
  review and it was removed: a rail row whose only behaviour was opening a
  hover panel collided with the Inbox tile beside it, which is where the actual
  activity notifications live, and a rail is a set of navigation targets. The
  durable notification-state row now lives on `/inbox`, rendered by
  `PlatformWeb.Components.NotificationState`. Settings was considered and ruled
  out: there was no `/settings` route then (`PlatformWeb.SettingsLive` arrived
  later, in task 01a1557a-807f), and the rail's bottom gear is Admin,
  `root_only?: true`, so it could never host a feature that has to reach
  external users. The rail therefore carries no `push_permission` state at all;
  `ShellLive`'s `:push_permission` assign feeds `/inbox` and the chat banner.

  ## Single-source-of-truth architecture

  Both desktop and mobile views consume the same `destinations/1` list.
  The list carries the hero icon name, label, path, cluster, and a
  `root_only?` flag. Admin and Prompts are `root_only?: true` today (as of
  2026-05-20); consumers filter on the flag via `root_user`.
  Future destinations (e.g. Inbox, Context, Memory, Prompts) may not yet
  have routes; their `:path` values are noted in the entry but the actual
  link wiring is deferred to Stage 3.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Access
  alias Platform.Access.Scope

  attr(:current_path, :string,
    default: "/",
    doc: "current request path; used for active-state styling and aria-current"
  )

  attr(:root_user, :boolean,
    default: false,
    doc: "when true, the Admin slot renders; otherwise it is omitted from the DOM entirely"
  )

  attr(:access_scope, :any,
    default: nil,
    doc:
      "the actor's `%Platform.Access.Scope{}` (LiveAuth's `:access_scope`). When set, every " <>
        "cluster is filtered through `Platform.Access.module_access?/3` and `root_user` is not " <>
        "consulted (task 01a1386d-fb6e stage 1). nil keeps the legacy `root_user` filter."
  )

  attr(:sidebar_collapsed, :boolean,
    default: false,
    doc: "when true, rail collapses to icon-only (56px); when false, expands to 224px with labels"
  )

  attr(:inbox_unread_count, :integer,
    default: 0,
    doc:
      "current user's non-dismissed inbox count; renders an attention badge on the Inbox tile. " <>
        "0 omits the badge node entirely. Desktop icon_rail/1; the mobile bar carries the " <>
        "same count as a dot on More (bottom_rail/1)."
  )

  attr(:chat_unread_count, :integer,
    default: 0,
    doc:
      "current user's total unread chat messages across the channels they participate in " <>
        "(Platform.Chat.total_unread_for_viewer/1); renders an unread badge on the Chat tile. " <>
        "0 omits the badge node entirely. Desktop icon_rail/1 only — the mobile bottom_rail " <>
        "badge is a separate future stage."
  )

  attr(:destinations, :list,
    default: nil,
    doc:
      "test/preview seam — overrides the canonical destination list. Entries may carry " <>
        ":children (indent-only rows, task 019f575e stage 4); production always uses the " <>
        "canonical list (nil)."
  )

  attr(:brand_name, :string,
    default: "",
    doc:
      "the install's app name (Platform.Branding.app_name/0, assigned once per mount by " <>
        "ShellLive) — the alt text of the Burrow mark and the label text in the rail header " <>
        "(task 01a120c5 stages 2 and 3). Never a compiled " <>
        "product name; empty (decorative) only when a caller renders the rail without one."
  )

  @doc """
  Desktop vertical icon-rail. Hidden below the `lg` breakpoint.

  Each tile renders a hero icon glyph plus (when expanded) a text label.
  The tile whose `:path` is the longest matching prefix of `current_path`
  gets `.icon-rail-tab--active` and `aria-current="page"`.
  """
  def icon_rail(assigns) do
    root_user = Map.get(assigns, :root_user, false)
    filter = rail_filter(assigns[:access_scope], root_user)
    current_path = Map.get(assigns, :current_path, "/")
    collapsed = Map.get(assigns, :sidebar_collapsed, false)
    all = assigns[:destinations] || canonical_destinations()

    # The desktop rail draws exactly `desktop_clusters/0`, by name; the
    # More-sheet-only `:sheet` cluster is not among them.
    live = cluster_destinations(all, :live, filter)
    working = cluster_destinations(all, :working, filter)
    admin = cluster_destinations(all, :admin, filter)

    visible = live ++ working ++ admin

    # Single winner computed across every VISIBLE desktop destination so the
    # CSS active class and aria-current can never disagree, and so a
    # root-filtered tile never lights up. Children join the pool only when
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
      |> assign(:show_admin, show_admin?(filter, admin))
      |> assign(:show_working, show_working?(filter, working))
      |> assign(:active_key, active_destination_key(pool, current_path))

    ~H"""
    <nav
      id="shell-sidebar"
      class={[
        "icon-rail hidden lg:flex flex-col gap-2 border-r border-edge bg-base-200 pb-4 px-2 transition-[width] duration-[var(--duration-base)] ease-[var(--ease-standard)]",
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
      <div class="icon-rail-header -mx-2 flex h-12 flex-shrink-0 items-center border-b border-edge px-2">
        <div
          :if={!@sidebar_collapsed}
          class="flex size-10 flex-shrink-0 items-center justify-center"
        >
          <img src={~p"/images/burrow-mark.svg"} alt={@brand_name} class="size-5" />
        </div>
        <span :if={!@sidebar_collapsed} class="icon-rail-label text-sm font-semibold">
          {@brand_name}
        </span>
        <button
          :if={!@sidebar_collapsed}
          type="button"
          class="ml-auto flex size-8 flex-shrink-0 items-center justify-center rounded-lg text-subtle transition-colors hover:bg-base-300 hover:text-base-content"
          phx-click="toggle_sidebar"
          title="Collapse sidebar"
          aria-label="Collapse sidebar"
        >
          <.icon name="hero-chevron-double-left" class="size-4" />
        </button>
        <button
          :if={@sidebar_collapsed}
          type="button"
          class="mx-auto flex size-10 flex-shrink-0 items-center justify-center rounded-lg text-subtle transition-colors hover:bg-base-300 hover:text-base-content"
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
        chat_unread_count={@chat_unread_count}
      />

      <.rail_eyebrow
        :if={@show_working}
        label="Working"
        sidebar_collapsed={@sidebar_collapsed}
      />
      <.rail_cluster
        destinations={@working_destinations}
        cluster="working"
        active_key={@active_key}
        sidebar_collapsed={@sidebar_collapsed}
        inbox_unread_count={@inbox_unread_count}
        chat_unread_count={@chat_unread_count}
      />

      <div class="mt-auto" aria-hidden="true"></div>
      <%= if @show_admin do %>
        <%!-- Admin cluster keeps its pinned-bottom position and a hairline
             separator in both rail states, but no "Admin" eyebrow label
             (task 019f575e v2, 2026-07-14). --%>
        <hr class="icon-rail-divider border-edge my-2" aria-hidden="true" />
        <.rail_cluster
          destinations={@admin_destinations}
          cluster="admin"
          active_key={@active_key}
          sidebar_collapsed={@sidebar_collapsed}
          inbox_unread_count={@inbox_unread_count}
          chat_unread_count={@chat_unread_count}
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
      class="icon-rail-divider border-edge my-2"
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
  attr(:chat_unread_count, :integer, default: 0)

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
          <%!-- Icon wrapped in a relative anchor so an unread badge can pin to
               its top-right corner. The badge is icon-anchored (not
               label-anchored) so it survives the collapsed rail. Hidden at 0:
               badge_spec/3 returns nil, so rail_badge/1's `:if` drops the node
               from the DOM entirely rather than rendering an empty or
               transparent pill. Which tiles carry one, and why they differ,
               lives in badge_spec/3 — not here. --%>
          <span class="relative flex-shrink-0">
            <.icon name={dest.hero_icon} class="icon-rail-icon size-5" />
            <.rail_badge badge={badge_spec(dest.key, @inbox_unread_count, @chat_unread_count)} />
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

  # One unread badge, pinned to a tile's icon. `nil` renders nothing at all:
  # the `:if` drops the node from the DOM rather than leaving an empty or
  # transparent pill, which is badge_text/1's and chat_badge_text/1's zero
  # contract and the reason a quiet rail looks exactly as it did before this
  # feature existed.
  #
  # Everything except the fill lives here rather than in badge_spec/3, and that
  # is the design call, not a shortcut: the Inbox and Chat pills sit two tiles
  # apart in one 56px column, so COLOUR is the only difference they are allowed
  # to have. Two pills in the same column with different geometry, type or halo
  # would read as a rendering fault instead of as a distinction.
  attr(:badge, :map, default: nil)

  defp rail_badge(assigns) do
    ~H"""
    <span
      :if={@badge}
      class={[
        "icon-rail-badge badge badge-xs absolute -top-1.5 -right-1.5 min-w-[1rem] px-1",
        "leading-none tabular-nums pointer-events-none",
        @badge.class
      ]}
      data-role={@badge.role}
      aria-label={@badge.aria}
    >
      {@badge.text}
    </span>
    """
  end

  @doc """
  Mobile tab bar. Hidden at the `lg` breakpoint and above.

  Link tabs for `mobile_tab_keys/0` (Chat, Tasks, Meetings; a Scope that does
  not admit one drops its cell, and the rest stay equal width), then a More
  button. Admin and the long tail live in the More sheet, never in the bar.

  Active state (task 01a1557a-7a71 stage 2, Saru rules 3 and 4): the winner
  is computed over the link tabs by `current_path`. More is active instead
  when `more_open` is true, or when no link tab matches and `current_path`
  is on a destination the More sheet lists (`more_sheet_destinations/2`).
  Active tabs render the `-solid` icon; inactive tabs the outline one.

  When `inbox_unread_count` is above 0, More carries a dot
  (`data-role="more-unread-dot"`, no count) and its aria-label reads
  "More, unread in Inbox". At 0 the dot is absent from the DOM.
  """
  attr(:current_path, :string, default: "/")
  attr(:root_user, :boolean, default: false)

  attr(:access_scope, :any,
    default: nil,
    doc: "the actor's Scope; when set the link tabs and the More test are filtered through it"
  )

  attr(:more_open, :boolean,
    default: false,
    doc: "true while the More sheet is open; lights More and nothing else"
  )

  attr(:inbox_unread_count, :integer,
    default: 0,
    doc: "the viewer's unread inbox count; above 0 puts the unread dot on More"
  )

  def bottom_rail(assigns) do
    current_path = Map.get(assigns, :current_path, "/")
    scope = assigns[:access_scope]
    primary = mobile_primary_destinations(scope)
    link_winner = active_destination_key(primary, current_path)

    more_active? =
      assigns[:more_open] == true or
        (link_winner == nil and
           more_sheet_destinations(scope, Map.get(assigns, :root_user, false))
           |> active_destination_key(current_path) != nil)

    unread? = is_integer(assigns[:inbox_unread_count]) and assigns[:inbox_unread_count] > 0

    assigns =
      assigns
      |> assign(:mobile_destinations, primary)
      |> assign(:active_key, if(more_active?, do: :more, else: link_winner))
      |> assign(:more_active?, more_active?)
      |> assign(:more_unread?, unread?)

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
        <.icon
          name={tab_icon(dest.key, dest.key == @active_key)}
          class="bottom-nav-icon size-5"
        />
        <span class="bottom-nav-label">{dest.label}</span>
      </.link>

      <button
        type="button"
        phx-click={if @more_open, do: "close_more_sheet", else: "open_more_sheet"}
        class={["bottom-nav-tab", @more_active? && "bottom-nav-tab--active"]}
        data-destination="more"
        aria-label={if @more_unread?, do: "More, unread in Inbox", else: "More"}
        aria-expanded={to_string(@more_open)}
        aria-haspopup="dialog"
      >
        <.icon name={tab_icon(:more, @more_active?)} class="bottom-nav-icon size-5" />
        <span class="bottom-nav-label">More</span>
        <span :if={@more_unread?} class="bottom-nav-dot" data-role="more-unread-dot"></span>
      </button>
    </nav>
    """
  end

  @doc """
  The bar's link-tab keys, in order (task 01a1557a-7a71 stage 2; the product lead:
  chat, voice, tasks, meetings, more). An ordered key list a later rung
  extends: Voice joins between Chat and Tasks in rung 20. More is not a key
  here; it is the button after the links.
  """
  @spec mobile_tab_keys() :: [atom()]
  def mobile_tab_keys, do: [:chat, :tasks, :meetings]

  # Bar-only icon mapping (task 01a1557a-7a71 stage 2): outline at rest,
  # `-solid` when active (Saru rule 3). Chosen against the masters'
  # master-mobile.html v3 glyphs; the shared destinations' `hero_icon` (the
  # desktop rail's) is deliberately not touched. Literal class names, so the
  # heroicons plugin generates every one of them.
  #   chat     round speech bubble with three dots -> chat-bubble-oval-left-ellipsis
  #   tasks    three check-mark rows                -> list-bullet (Heroicons has no
  #            checklist-rows glyph; three rows is the nearer half of the shape)
  #   meetings video camera                         -> video-camera
  #   more     three dots                           -> ellipsis-horizontal
  @tab_icons %{
    chat: {"hero-chat-bubble-oval-left-ellipsis", "hero-chat-bubble-oval-left-ellipsis-solid"},
    tasks: {"hero-list-bullet", "hero-list-bullet-solid"},
    meetings: {"hero-video-camera", "hero-video-camera-solid"},
    more: {"hero-ellipsis-horizontal", "hero-ellipsis-horizontal-solid"}
  }

  @doc false
  def tab_icon(key, active?) do
    {outline, solid} = Map.fetch!(@tab_icons, key)
    if active?, do: solid, else: outline
  end

  # The More sheet's module rows, in order (task 01a1557a-807f stage 2;
  # coverage row 5, master-mobile.html v3 :727-736). ONE list: a key with no
  # destination yet (Canvases and Games, until rungs 16 and 21 add a page),
  # or one the actor may not see, is skipped and leaves no gap.
  @more_sheet_order [
    :inbox,
    :email,
    :files,
    :canvases,
    :games,
    :skills,
    :context,
    :agents,
    :experiments,
    :changelog
  ]

  # The Settings row is pinned in the sheet's footer, not in the list. It is
  # current on /settings and on the pages it now carries (Usage, Admin and
  # everything under it, Prompts), so those paths join the same longest-prefix
  # match as the rows: /control/usage resolves to Settings, not to Agents'
  # /control, and /control/experiments still resolves to Experiments.
  # `/access` joined with the Settings Admin sheet (task 01a1557a-e538 stage
  # 3), which links it; `/tasks/pipeline`, also in that sheet, stays under
  # Tasks by the same longest-prefix rule.
  @settings_paths ["/settings", "/control/usage", "/admin", "/admin/prompts", "/access"]

  @doc """
  The clusters the desktop rail (`icon_rail/1`) renders, in order. A
  destination in any other cluster (`:sheet`, task 01a1557a-807f stage 2) is
  listed only by the mobile More sheet.
  """
  @spec desktop_clusters() :: [atom()]
  def desktop_clusters, do: [:live, :working, :admin]

  @doc "The More sheet's module-row key order (see `more_sheet_rows/2`)."
  @spec more_sheet_order() :: [atom()]
  def more_sheet_order, do: @more_sheet_order

  @doc "The paths on which the More sheet's pinned Settings row is current."
  @spec settings_paths() :: [String.t()]
  def settings_paths, do: @settings_paths

  @doc """
  The mobile More sheet's module rows, for an actor (task 01a1557a-807f
  stage 2): the destinations for `more_sheet_order/0`, in that order, then
  every `Platform.Extensions.rail_items/0` item the actor may see, in
  rail_items order, after Changelog.

  Every row goes through the same `rail_filter/2` and `enabled?/1` as the
  rails (via `destinations/1`), so a module the actor may not open, or one
  switched off (Email with Mail off), is absent. Admin, Prompts and sign out
  are not rows: they live on `/settings`, reached from the sheet's pinned
  Settings row.
  """
  @spec more_sheet_rows(Scope.t() | nil, boolean()) :: [map()]
  def more_sheet_rows(scope, root_user) do
    visible = scope |> rail_filter(root_user) |> destinations()
    by_key = Map.new(visible, &{&1.key, &1})
    extension_keys = Enum.map(Platform.Extensions.rail_items(), & &1.key)

    Enum.flat_map(@more_sheet_order, &List.wrap(Map.get(by_key, &1))) ++
      Enum.filter(visible, &(&1.key in extension_keys))
  end

  @doc """
  Every path the More sheet answers for: its module rows plus the Settings
  row's paths (`settings_paths/0`), as `%{key, path}` entries. The bar lights
  More on any of them (`bottom_rail/1`).
  """
  @spec more_sheet_destinations(Scope.t() | nil, boolean()) :: [map()]
  def more_sheet_destinations(scope, root_user) do
    more_sheet_rows(scope, root_user) ++ settings_destinations()
  end

  @doc """
  The More sheet row that is current for `current_path`: a row key, `:settings`,
  or nil. The rails' own matcher (`active_destination_key/2`, longest prefix
  at a segment boundary) over the rows plus the Settings paths.
  """
  @spec more_sheet_current_key([map()], String.t() | nil) :: atom() | nil
  def more_sheet_current_key(rows, current_path) when is_binary(current_path),
    do: active_destination_key(rows ++ settings_destinations(), current_path)

  def more_sheet_current_key(_rows, _current_path), do: nil

  defp settings_destinations, do: Enum.map(@settings_paths, &%{key: :settings, path: &1})

  @doc """
  Returns the canonical destination list for the icon rail.

  Each entry has:

    * `:key` — atom slug, unique
    * `:label` — display text
    * `:path` — string nav target (some destinations don't have routes
      yet; those are flagged with a TODO in the source. Stage 3 wires
      navigation and will reconcile any missing routes.)
    * `:hero_icon` — heroicon class name (rendered in Stage 2)
    * `:cluster` — `:live | :working | :admin | :sheet` (`:sheet` is listed
      only by the mobile More sheet; the desktop rail never renders it)
    * `:root_only?` — boolean; today `:admin` and `:prompts` are `true`

  With `opts[:scope]` (a `%Platform.Access.Scope{}`, task 01a1386d-fb6e
  stage 1) an entry is kept when `Platform.Access.module_access?/3` admits
  its key for that scope, and `root_only?` is not consulted: the registry's
  install-level and module-admin rail permissions replace it. An entry whose
  key no registry rail entry declares is dropped (fail closed).

  Without `:scope`, the legacy path: when `opts[:root_user]` is `false`
  (default), all `root_only?: true` entries are omitted from the returned
  list. Production callers pick the path through `rail_filter/2`.
  """
  def destinations(opts \\ []) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} ->
        canonical_destinations()
        |> Enum.filter(&Access.module_access?(scope, &1.key))
        |> Enum.filter(&enabled?/1)

      :error ->
        root_user = Keyword.get(opts, :root_user, false)

        canonical_destinations()
        |> Enum.reject(fn dest -> dest.root_only? and not root_user end)
        |> Enum.filter(&enabled?/1)
    end
  end

  @doc """
  The `destinations/1` options for a render: `[scope: scope]` when the
  caller has the actor's `%Platform.Access.Scope{}`, else the legacy
  `[root_user: root_user]` (task 01a1386d-fb6e stage 1). The one place the
  desktop rail, the bottom rail and the More sheet choose between the two,
  so they cannot disagree. The shell always assigns a Scope
  (`PlatformWeb.LiveAuth.on_mount(:default)`, pinned for every `:shell`
  live_session by `icon_rail_scope_test.exs`); the legacy path remains for
  component renders that pass only `root_user`.
  """
  @spec rail_filter(Scope.t() | nil, term()) :: keyword()
  def rail_filter(%Scope{} = scope, _root_user), do: [scope: scope]
  def rail_filter(_scope, root_user), do: [root_user: root_user]

  @doc """
  Is this destination switched on right now?

  An entry may carry `:enabled?`, a zero-arity predicate for an env-gated
  module (Email reads `Platform.Mail.Config.enabled?/0`, task 01a0cf21
  stage 4). An entry without one is always on. Applied in `destinations/1`
  and at the `icon_rail/1` cluster boundary, so the desktop rail, the mobile
  bottom rail and the More sheet (which reads `destinations/1`) all drop a
  disabled module from one place — DOM-absent, not hidden.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(dest) do
    case Map.get(dest, :enabled?) do
      nil -> true
      fun when is_function(fun, 0) -> fun.() == true
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp cluster_destinations(all, cluster, filter) do
    all
    |> Enum.filter(&(&1.cluster == cluster))
    |> filter_visible(filter)
    |> Enum.filter(&enabled?/1)
  end

  # With a Scope, the module decision is `Platform.Access.module_access?/3`
  # alone (task 01a1386d-fb6e stage 1); without one, the legacy root_only?
  # filter below, unchanged.
  defp filter_visible(destinations, scope: scope),
    do: Enum.filter(destinations, &Access.module_access?(scope, &1.key))

  defp filter_visible(destinations, root_user: root_user),
    do: filter_root_only(destinations, root_user)

  # The Admin cluster's divider renders with the cluster: legacy keys it off
  # `root_user`, the Scope path off whether any admin tile survived.
  defp show_admin?([scope: _scope], admin), do: admin != []
  defp show_admin?([root_user: root_user], _admin), do: root_user

  # The Working eyebrow: a guest's Scope admits no Working tile, so the Scope
  # path drops the label over an empty cluster. Legacy always renders it.
  defp show_working?([scope: _scope], working), do: working != []
  defp show_working?([root_user: _root_user], _working), do: true

  # Apply the root_only? filter against a per-render root_user flag.
  # Used at the icon_rail/1 render boundary so EVERY cluster (live /
  # working / admin) honors root_only? consistently. Previously only the
  # admin cluster had a `:if={@root_user}` template gate, which meant
  # a root_only?:true tile in the working cluster (e.g. Prompts) still
  # rendered for members. Fixed 2026-05-20.
  defp filter_root_only(destinations, root_user) do
    Enum.reject(destinations, fn dest -> dest.root_only? and not root_user end)
  end

  defp mobile_primary_destinations(access_scope) do
    # The link tabs, in mobile_tab_keys/0 order (not the canonical list's
    # order); More is rendered separately because it is a button. With a
    # Scope they are filtered through it (task 01a1386d-fb6e stage 1);
    # without one they render unfiltered, as before.
    by_key = Map.new(canonical_destinations(), &{&1.key, &1})

    primary =
      mobile_tab_keys()
      |> Enum.flat_map(&List.wrap(Map.get(by_key, &1)))
      |> Enum.filter(&enabled?/1)

    case access_scope do
      %Scope{} = scope -> Enum.filter(primary, &Access.module_access?(scope, &1.key))
      _ -> primary
    end
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
  @doc false
  def active_destination_key(destinations, current_path) do
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

  # Active-state classes — desktop uses the icon-rail variant (a 3px left bar
  # via `::before`), mobile the bottom-nav variant (no bar since task
  # 01a1557a-7a71; ink, weight and the solid icon carry it). The active tile is
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

  @doc """
  Inbox unread-badge label.

  Returns nil at 0 (badge node omitted from the DOM), the integer as a
  string for 1..99, and "99+" for anything above 99 (ADR-0022 DM-badge
  overflow grammar). Non-integer inputs are treated as 0.

  Public because the rail is no longer the only surface showing this count:
  `PlatformWeb.ShellLive` pushes the same label to the `AppBadge` JS hook
  for the document-title prefix (task 019ffb7b stage 6). One definition of
  the cap, so the rail pill and the title prefix cannot disagree.
  """
  @spec badge_text(term()) :: String.t() | nil
  def badge_text(count) when is_integer(count) do
    cond do
      count <= 0 -> nil
      count > 99 -> "99+"
      true -> Integer.to_string(count)
    end
  end

  def badge_text(_), do: nil

  @doc """
  Chat unread-badge label.

  Returns nil at or below 0 (badge node omitted from the DOM), the integer as
  a string for 1..99, and "99+" above 99. Same overflow grammar as
  `badge_text/1`, which is the point of task 01a02491 stage 2.

  The cap used to be 9+, matched to `ChatLive`'s `unread_label/1` on the
  reasoning that the rail total and a per-channel pill were one quantity seen
  at two zoom levels. They are not the same quantity. The rail total is a sum
  over every channel, DM and group the viewer participates in, so it is not
  equal to any single pill, and stage 1 narrowed the summed set to exactly
  those three kinds, which makes the mismatch explicit. The badge's real
  sibling is the Inbox badge two tiles away in the same 56px column. Two
  badges in one column with two different overflow grammars read as a
  rendering fault rather than as a distinction.

  Three glyphs fit; measured, not assumed. See the geometry note above
  `badge_spec/3`.

  `ChatLive.unread_label/1` deliberately stays at 9+. A per-channel pill
  counts a different thing from the rail total and is allowed its own
  grammar; changing it would be a change to the Chat sidebar, not to this
  rail.

  Kept as its own function rather than delegating to `badge_text/1`, even
  though the two bodies now agree. `badge_text/1` is public and also feeds
  ShellLive's `AppBadge` document-title label, so a later change to the Chat
  cap must not be able to move the Inbox pill and the browser tab with it.
  The two caps agreeing is a design decision, not a shared implementation.
  """
  @spec chat_badge_text(term()) :: String.t() | nil
  def chat_badge_text(count) when is_integer(count) do
    cond do
      count <= 0 -> nil
      count > 99 -> "99+"
      true -> Integer.to_string(count)
    end
  end

  def chat_badge_text(_), do: nil

  # Which tiles carry an unread badge, and what is different about each.
  #
  # One function with a `dest.key` case, not a second copy of the markup
  # block: the geometry, type, halo and overflow grammar are all shared, and
  # the FILL is the only thing that is per-destination. Returns nil for every
  # other key, and nil at a zero count, so an absent badge is an absent DOM
  # node.
  #
  # Inbox is `badge-error` (red) and Chat is `badge-primary` (cyan), and the
  # split is the whole design decision here. Red is severity: something is
  # addressed to you and you are expected to clear it. Chat unread is ambient
  # and near-permanently non-zero, so copying `badge-error` onto it, one line
  # away and the obvious move, would leave the rail permanently red, and a
  # permanently red rail is one nobody reads. That takes the Inbox badge down
  # with it. Cyan is also what the per-channel pills inside Chat use
  # (`.channel-row-unread-pill`, app.css), so the rail total and a pill read
  # as one family. They are not one quantity, which is why they no longer
  # share an overflow cap: see `chat_badge_text/1`.
  #
  # COLLAPSED-RAIL GEOMETRY, measured rather than assumed (task 01a02491
  # stage 2, Chrome 151, `lg:w-14`, both themes, at a count of 150):
  #
  #   rail           0.00 .. 56.00
  #   tile           8.00 .. 47.00   (the nav's px-2)
  #   icon          16.00 .. 36.00   (size-5)
  #   badge "1"     25.00 .. 42.00   (17.00 wide)
  #   badge "99"    18.00 .. 42.00   (24.00 wide)
  #   badge "99+"   12.11 .. 42.00   (29.89 wide)
  #
  # The pill is anchored by its RIGHT edge (`-right-1.5` in rail_badge/1), so
  # a wider label grows LEFTWARD across the icon and the right edge does not
  # move: 42.00 at all three labels, 5px inside the tile and 14px inside the
  # rail. Three glyphs fit with no truncation and no horizontal overflow
  # (`documentElement.scrollWidth` stayed at the viewport width). Raising the
  # Chat cap to 99+ therefore needed no anchoring change, and the halo stays a
  # box-shadow for the reason recorded at app.css.
  #
  # The `data-role` values differ so the two nodes are separable in tests and
  # in devtools. "inbox-badge" is load-bearing: existing tests query it.
  defp badge_spec(:inbox, inbox_count, _chat_count) do
    case badge_text(inbox_count) do
      nil ->
        nil

      text ->
        %{
          text: text,
          class: "badge-error",
          role: "inbox-badge",
          aria: "#{inbox_count} unread"
        }
    end
  end

  defp badge_spec(:chat, _inbox_count, chat_count) do
    case chat_badge_text(chat_count) do
      nil ->
        nil

      text ->
        # The aria-label is the only place the word "unread" appears on this
        # surface; the visible badge is a bare number. It reports the true
        # count, not the capped label, because a screen reader has no 56px
        # problem.
        %{
          text: text,
          class: "badge-primary",
          role: "chat-badge",
          aria: "#{chat_count} unread messages"
        }
    end
  end

  defp badge_spec(_key, _inbox_count, _chat_count), do: nil

  # Canonical destination list: core's 11 entries, then every build-time
  # module's (`Platform.Extensions.rail_items/0`, ADR 0055 section 5, read per
  # call). Order within a cluster determines render order in the rail, and an
  # extension's item goes through the same `root_only?` and `enabled?`
  # filters as a core item.
  defp canonical_destinations do
    core_destinations() ++ Platform.Extensions.rail_items()
  end

  defp core_destinations do
    [
      # Live cluster — high-frequency, real-time surfaces
      %{
        key: :chat,
        label: "Chat",
        path: "/chat",
        hero_icon: "hero-chat-bubble-left-right",
        cluster: :live,
        root_only?: false
      },
      %{
        key: :tasks,
        label: "Tasks",
        path: "/tasks",
        hero_icon: "hero-rectangle-stack",
        cluster: :live,
        root_only?: false
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
        root_only?: false
      },

      # Working cluster — reference / configuration surfaces
      %{
        key: :agents,
        label: "Agents",
        path: "/control",
        hero_icon: "hero-cpu-chip",
        cluster: :working,
        root_only?: false
      },
      %{
        key: :skills,
        label: "Skills",
        path: "/skills",
        hero_icon: "hero-book-open",
        cluster: :working,
        root_only?: false
      },
      %{
        # ADR-0042 stage 5: project-scoped document store (FilesLive).
        # Lives next to Skills/Memory in the Working cluster; available
        # to every authenticated user (not root-gated).
        key: :files,
        label: "Files",
        path: "/files",
        hero_icon: "hero-document-text",
        cluster: :working,
        root_only?: false
      },
      %{
        # T7 stage 2 (2026-05-20): renamed surface from "Context + Memory"
        # to "Org Memory" and route from `/org-context` to `/org_memory`.
        # The OrgMemoryLive LiveView owns both the Files and Memory tabs.
        # Old `/org-context[/:file_key]` paths 301-redirect to the new
        # canonical paths via PageController.
        key: :context,
        label: "Org memory",
        path: "/org_memory",
        hero_icon: "hero-building-library",
        cluster: :working,
        root_only?: false
      },
      %{
        key: :prompts,
        # Prompts is admin-only per the route gate (live_session :admin /
        # ensure_admin). Rail entry was previously root_only?: false which
        # rendered the tile for members but redirected on click — fixed
        # 2026-05-20. Kept in working cluster (vs admin cluster) because
        # Prompts is the most-frequently-used admin surface for admins.
        label: "Prompts",
        path: "/admin/prompts",
        hero_icon: "hero-command-line",
        cluster: :working,
        root_only?: true
      },
      %{
        # Task 019fe6ba / ADR-0048: the experiments surface at
        # `/control/experiments`. Deliberately NOT root_only? — the routes
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
        root_only?: false
      },
      %{
        key: :meetings,
        label: "Meetings",
        path: "/meetings",
        hero_icon: "hero-video-camera",
        cluster: :working,
        root_only?: false
      },
      %{
        # Task 01a0cf21 stage 4: the Email module. Its own module in the
        # Working cluster (not an admin screen), gated by MAIL_ENABLED
        # through `Platform.Mail.Config.enabled?/0` — the only env-gated
        # destination, hence the `:enabled?` predicate. Account management
        # inside it is org-admin-only, enforced in `Platform.Mail`.
        key: :email,
        label: "Email",
        path: "/email",
        hero_icon: "hero-envelope",
        cluster: :working,
        root_only?: false,
        enabled?: &Platform.Mail.Config.enabled?/0
      },
      %{
        # Task 01a1557a-807f stage 2: a More-sheet-only destination. The
        # `:sheet` cluster is one `icon_rail/1` never renders (it draws
        # `:live`, `:working` and `:admin` by name), so the desktop rail does
        # not show it. Its registry rail entry sits in the `activity` module
        # with `activity.read`, which is exactly what ModuleGate asks of
        # ChangelogLive.
        key: :changelog,
        label: "Changelog",
        path: "/changelog",
        hero_icon: "hero-newspaper",
        cluster: :sheet,
        root_only?: false
      },

      # Admin cluster — root-admin-only, gated by `root_user`
      %{
        key: :admin,
        label: "Admin",
        path: "/admin",
        hero_icon: "hero-cog-6-tooth",
        cluster: :admin,
        root_only?: true
      }
    ]
  end
end
