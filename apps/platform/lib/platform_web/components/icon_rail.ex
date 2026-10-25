defmodule PlatformWeb.Components.IconRail do
  @moduledoc """
  The shell's canonical destination list and the phone tab bar.

  One render function and the list every navigation surface reads:

    * `bottom_rail/1` — mobile tab bar (<`lg` breakpoint). Link tabs from
                       `mobile_tab_keys/0` (Chat, Voice, Tasks, Meetings,
                       filtered by Scope) plus a More button that fires
                       `phx-click="open_more_sheet"` (`close_more_sheet`
                       while the sheet is open). Inbox and Activity are
                       not in the bar (task 01a1557a-7a71 stage 2): Inbox
                       is the More sheet's first row, and its unread signal
                       is a dot on More.
    * `tab_destinations/1` and `more_sheet_rows/2` — the bar's link tabs and
      the More sheet's rows. The desktop sidebar
      (`PlatformWeb.Components.Sidebar`, Burrow redesign 22) renders exactly
      these two lists, so phone and desktop list the same destinations in
      the same order. The desktop icon rail that used to draw its own
      clusters from this module was deleted with that rung.

  Active state uses segment-boundary longest-prefix matching against
  `current_path` (`active_destination_key/2`), so a nested route
  (`/chat/:slug`, `/tasks/:id`, `/org_memory/*file_key`) lights its parent;
  among overlapping prefixes the longest path wins (`/admin/prompts` is
  Prompts, not Admin).

  No navigation surface carries `push_permission` state: `ShellLive`'s
  `:push_permission` assign feeds `/inbox` (`PlatformWeb.Components.NotificationState`)
  and the chat banner.

  ## Single-source-of-truth architecture

  Every surface consumes the same `destinations/1` list. The list carries the
  hero icon name, label, path, cluster, and a `root_only?` flag. Admin and
  Prompts are `root_only?: true`; consumers filter through `rail_filter/2`.
  `:cluster` is descriptive data an extension's rail item also carries
  (`Platform.Extension`); no render reads it since the icon rail went.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Access
  alias Platform.Access.Scope

  @doc """
  Mobile tab bar. Hidden at the `lg` breakpoint and above.

  Link tabs for `mobile_tab_keys/0` (Chat, Voice, Tasks, Meetings; a Scope that does
  not admit one drops its cell, and the rest stay equal width), then a More
  button. Admin and the long tail live in the More sheet, never in the bar.

  Active state (task 01a1557a-7a71 stage 2, Saru rules 3 and 4): the winner
  is computed over the link tabs by `current_path`. More is active instead
  when `more_open` is true, or when no link tab matches and `current_path`
  is on a destination the More sheet lists (`more_sheet_destinations/2`).
  Active tabs render the `-solid` icon; inactive tabs the outline one.

  A tinted pill sits behind the current tab and slides when it changes
  (the `TabPill` hook, `assets/js/hooks/tab_pill.js`; prototype t1). Its
  layer is `phx-update="ignore"` so a patch keeps the hook's geometry.

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
    primary = tab_destinations(scope)
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
      id="bottom-nav"
      class="bottom-nav lg:hidden"
      role="navigation"
      aria-label="Main navigation"
      data-bottom-rail
      phx-hook="TabPill"
    >
      <div
        id="bottom-nav-pill-layer"
        class="bottom-nav-pill-layer"
        phx-update="ignore"
        aria-hidden="true"
      >
        <span class="bottom-nav-pill" data-tab-pill></span>
      </div>
      <.link
        :for={dest <- @mobile_destinations}
        navigate={dest.path}
        class={["bottom-nav-tab", mobile_active_class(dest, @active_key)]}
        data-destination={dest.key}
        data-module-id={dest.key}
        data-nav-label={dest.label}
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
        class={["bottom-nav-tab press-hold", @more_active? && "bottom-nav-tab--active"]}
        data-destination="more"
        aria-label={if @more_unread?, do: "More, unread in Inbox", else: "More"}
        aria-expanded={to_string(@more_open)}
        aria-haspopup="dialog"
      >
        <.icon name={tab_icon(:more, @more_active?)} class="bottom-nav-icon size-5" />
        <span class="bottom-nav-label">More</span>
        <span :if={@more_unread?} class="bottom-nav-dot" data-role="more-unread-dot"></span>
      </button>

      <%!-- Bridge to the iOS app's native tab bar (task 01a1557b stage 3, the
           NativeTabBar hook). Inert outside a native build that has the bar.
           data-items is the bar's own tab keys in order, More last, so native
           draws exactly what this bar draws. --%>
      <span
        id="native-tab-bridge"
        phx-hook="NativeTabBar"
        hidden
        data-items={Enum.map_join(@mobile_destinations, ",", &to_string(&1.key)) <> ",more"}
        data-active-key={@active_key}
        data-more-unread={to_string(@more_unread?)}
        data-more-open={to_string(@more_open)}
      >
      </span>
    </nav>
    """
  end

  @doc """
  The bar's link-tab keys, in order (task 01a1557a-7a71 stage 2; the product lead:
  chat, voice, tasks, meetings, more). Voice joined between Chat and Tasks
  in rung 20 (task 01a1557a-eab7 stage 2). More is not a key here; it is the
  button after the links.
  """
  @spec mobile_tab_keys() :: [atom()]
  def mobile_tab_keys, do: [:chat, :voice, :tasks, :meetings]

  # Bar-only icon mapping (task 01a1557a-7a71 stage 2): outline at rest,
  # `-solid` when active (Saru rule 3). Chosen against the masters'
  # master-mobile.html v3 glyphs; the shared destinations' `hero_icon` (the
  # More sheet's) is deliberately not touched. The desktop sidebar's module
  # rows use the outline set too. Literal class names, so the
  # heroicons plugin generates every one of them.
  #   chat     round speech bubble with three dots -> chat-bubble-oval-left-ellipsis
  #   voice    microphone                           -> microphone
  #   tasks    three check-mark rows                -> list-bullet (Heroicons has no
  #            checklist-rows glyph; three rows is the nearer half of the shape)
  #   meetings video camera                         -> video-camera
  #   more     three dots                           -> ellipsis-horizontal
  @tab_icons %{
    chat: {"hero-chat-bubble-oval-left-ellipsis", "hero-chat-bubble-oval-left-ellipsis-solid"},
    voice: {"hero-microphone", "hero-microphone-solid"},
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
  # coverage row 5, master-mobile.html v3 :727-736). ONE list: a key the
  # actor may not see, or one switched off, is skipped and leaves no gap.
  # Canvases opens the Files browser filtered to canvases (rung 16); Games
  # opens it filtered to games (rung 21), and only while the game_stream
  # kind is registered.
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

  @doc "The More sheet's module-row key order (see `more_sheet_rows/2`)."
  @spec more_sheet_order() :: [atom()]
  def more_sheet_order, do: @more_sheet_order

  @doc "The paths on which the More sheet's pinned Settings row is current."
  @spec settings_paths() :: [String.t()]
  def settings_paths, do: @settings_paths

  @doc """
  The mobile More sheet's module rows, for an actor (task 01a1557a-807f
  stage 2): the destinations for `more_sheet_order/0`, in that order, with
  every `Platform.Extensions.rail_items/0` item the actor may see placed
  right after Inbox, in rail_items order.

  Extension rows lead the long tail rather than trailing it. The list is
  taller than the sheet on a phone browser (at 390x664, Safari's visible
  viewport on a 390x844 phone, the last rows sit below the fold), and
  a module appended after Changelog was the row nobody scrolled to: Social
  read as missing on mobile. Inbox stays first.

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

    {inbox, rest} =
      @more_sheet_order
      |> Enum.flat_map(&List.wrap(Map.get(by_key, &1)))
      |> Enum.split_while(&(&1.key == :inbox))

    inbox ++ Enum.filter(visible, &(&1.key in extension_keys)) ++ rest
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
    * `:cluster` — `:live | :working | :admin | :sheet`, descriptive only
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
  bottom rail, the More sheet and the desktop sidebar choose between the two,
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
  and `tab_destinations/1`, so the bottom rail, the More sheet and the
  desktop sidebar all drop a disabled module from one place — DOM-absent,
  not hidden.
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

  @doc """
  The tab bar's link tabs for an actor, in `mobile_tab_keys/0` order (not the
  canonical list's order). With a Scope they are filtered through it (task
  01a1386d-fb6e stage 1); without one they render unfiltered. The phone tab
  bar (`bottom_rail/1`) and the desktop sidebar's module rows
  (`PlatformWeb.Components.Sidebar`) both read this, so they cannot disagree.
  """
  @spec tab_destinations(Scope.t() | nil) :: [map()]
  def tab_destinations(access_scope) do
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

  # A destination whose path carries a query (More > Canvases,
  # `/files?tab=browse&type=canvas`) matches only that exact URL; FilesLive
  # passes it through as `:current_path` in one canonical form. Every other
  # destination is compared against the path with any query dropped, at a
  # segment boundary, so `/files?tab=browse&type=canvas` still matches Files
  # and the longer Canvases path wins.
  defp path_matches?(path, current_path) do
    if String.contains?(path, "?") do
      current_path == path
    else
      bare = current_path |> String.split("?", parts: 2) |> hd()
      bare == path or String.starts_with?(bare, path <> "/")
    end
  end

  # Active-state class for the bottom bar's tabs (no bar since task
  # 01a1557a-7a71; ink, weight and the solid icon carry it). The active tab is
  # the precomputed `active_key` winner (see active_destination_key/2).
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
  sibling is the Inbox badge in the same sidebar column. Two badges in one
  column with two different overflow grammars read as a rendering fault
  rather than as a distinction.

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

  # Canonical destination list: core's entries, then every build-time
  # module's (`Platform.Extensions.rail_items/0`, ADR 0055 section 5, read per
  # call). An
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
        # The Voice tab (task 01a1557a-eab7 stage 2): a 1:1 hold-to-talk
        # conversation with an agent. Gated with Meetings (`meetings.join`):
        # it rides the same LiveKit + transcription pipeline.
        key: :voice,
        label: "Voice",
        path: "/voice",
        hero_icon: "hero-microphone",
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
        # More > Canvases (rung 16, task 01a1557a-b5f9 stage 3): the Files
        # browser at All, filtered to canvases. The More sheet (and the
        # desktop sidebar's More group) lists it after Files.
        # Its path carries a query, which `path_matches?/2` compares whole.
        key: :canvases,
        label: "Canvases",
        path: "/files?tab=browse&type=canvas",
        hero_icon: "hero-rectangle-group",
        cluster: :sheet,
        root_only?: false
      },
      %{
        # More > Games (rung 21, task 01a1557a-efdd stage 1): the Files
        # browser at All, filtered to games, listed after Canvases. Present only while an extension registers
        # the game_stream kind; core never names that extension.
        key: :games,
        label: "Games",
        path: "/files?tab=browse&type=game",
        hero_icon: "hero-puzzle-piece",
        cluster: :sheet,
        root_only?: false,
        enabled?: &Platform.Files.Browser.games_enabled?/0
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
        # Task 01a1557a-807f stage 2: a More-sheet destination (and so a
        # row in the desktop sidebar's More group). Its registry rail entry sits in the `activity` module
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
