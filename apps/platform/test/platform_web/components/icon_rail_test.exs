defmodule PlatformWeb.Components.IconRailTest do
  @moduledoc """
  DOM contract tests for the responsive icon-rail component.

  Stage 1 asserted structural contract (wrappers, clusters, tile count).
  Stage 2 extends those with:

    * hero-icon class presence per destination
    * `.icon-rail-tab--active` applied to the destination matching
      `current_path` (desktop)
    * `.bottom-nav-tab--active` applied to the destination matching
      `current_path` (mobile)
    * `aria-current="page"` on the active tile at both breakpoints
    * `aria-label` on every tile
  """

  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail

  defp render_icon_rail(assigns) do
    assigns =
      Map.merge(
        %{
          current_path: "/chat",
          is_fabrikam_user: false,
          sidebar_collapsed: false
        },
        assigns
      )

    rendered_to_string(~H"""
    <.icon_rail
      current_path={@current_path}
      is_fabrikam_user={@is_fabrikam_user}
      sidebar_collapsed={@sidebar_collapsed}
    />
    """)
  end

  defp render_bottom_rail(assigns) do
    assigns =
      Map.merge(
        %{
          current_path: "/chat",
          is_fabrikam_user: false
        },
        assigns
      )

    rendered_to_string(~H"""
    <.bottom_rail current_path={@current_path} is_fabrikam_user={@is_fabrikam_user} />
    """)
  end

  describe "destinations/1" do
    test "returns 9 destinations for a non-Fabrikam user (Admin + Prompts filtered out)" do
      # Count bumped from 7 → 8 when ADR-0042 stage 5 added the Files
      # destination (working cluster, fabrikam_only?: false), 8 → 9 when
      # task 019fe6ba added Experiments, 9 → 10 when task 019fea0d added
      # Pipeline, and back 10 → 9 when task 019fed1e removed Pipeline again
      # (it moved to an admin-only cog in the Tasks header). Any future
      # destination addition should bump the matching guard below.
      list = destinations(is_fabrikam_user: false)
      assert length(list) == 9
      refute Enum.any?(list, &(&1.key == :admin))
      # Prompts is also fabrikam_only?: true as of 2026-05-20 (admin-only access
      # at the route level; previously rendered for members but redirected
      # on click — bug fixed by filtering fabrikam_only? in all clusters).
      refute Enum.any?(list, &(&1.key == :prompts))
      # Files (ADR-0042 stage 5) is visible to every authenticated user.
      assert Enum.any?(list, &(&1.key == :files))
    end

    test "returns all 11 destinations for a Fabrikam user (Admin + Prompts included)" do
      list = destinations(is_fabrikam_user: true)
      assert length(list) == 11
      assert Enum.any?(list, &(&1.key == :admin))
      assert Enum.any?(list, &(&1.key == :prompts))
      assert Enum.any?(list, &(&1.key == :files))
    end

    test "Experiments is a member-visible destination pointing at /control/experiments" do
      # Reachability guard for task 019fe6ba: `/control/experiments` sits in
      # `live_session :authenticated`, so a NON-admin member must see the nav
      # entry. Asserting against the is_fabrikam_user: false list is the whole
      # point — a fabrikam_only? regression here restores the original defect
      # (the page reachable only by typing the URL).
      dest =
        destinations(is_fabrikam_user: false)
        |> Enum.find(&(&1.key == :experiments))

      assert dest, "Experiments must appear for a non-Fabrikam member"
      assert dest.path == "/control/experiments"
      assert dest.cluster == :working
      refute dest.fabrikam_only?
    end

    test "the rail offers no Pipeline destination at all" do
      # Task 019fed1e REVERSES task 019fea0d's entry: pipeline is a Tasks
      # concern reached from the admin-only cog in the Tasks header, not a
      # shell destination, and its route moved to `/admin/pipeline`.
      #
      # NOTE THE LIST. This asserts against the UNFILTERED
      # `destinations(is_fabrikam_user: true)`. Against the member list a
      # re-added entry marked `fabrikam_only?: true` is filtered out, so the
      # refute would pass while the tile was back in the rail for admins —
      # the filtered list hides exactly the state under test.
      list = destinations(is_fabrikam_user: true)

      assert list != [], "no destinations at all — this guard would be vacuous"
      refute Enum.any?(list, &(&1.key == :pipeline))
      refute Enum.any?(list, &String.contains?(&1.path, "/control/pipeline"))
    end

    test "every /control destination in the rail is member-visible" do
      # The class-level guard rather than one test per page. Both /control
      # surfaces shipped unreachable, one after the other, because "route
      # added" was treated as "shipped". This fails if a future /control tile
      # is added as fabrikam_only? while its route stays in :authenticated.
      #
      # NOTE the list this iterates. Written first against
      # `destinations(is_fabrikam_user: false)`, this test was VACUOUS: setting a
      # /control entry to fabrikam_only?: true filters it OUT of that list, so the
      # loop never saw it and the refute never fired — the guard could not
      # fail for the exact regression it exists to catch. Proven by mutation:
      # flipping :pipeline to fabrikam_only?: true left this test green.
      # It must iterate the UNFILTERED list, where a hidden entry is still
      # present and can be inspected.
      control_dests =
        destinations(is_fabrikam_user: true)
        |> Enum.filter(&String.starts_with?(&1.path, "/control"))

      assert control_dests != [], "no /control destinations found — this guard would be vacuous"

      for dest <- control_dests do
        refute dest.fabrikam_only?,
               "#{dest.key} points at #{dest.path} but is hidden from non-Fabrikam members"
      end
    end

    test "every entry has the required keys" do
      for dest <- destinations(is_fabrikam_user: true) do
        assert is_atom(dest.key)
        assert is_binary(dest.label)
        assert is_binary(dest.path)
        assert is_binary(dest.hero_icon)
        assert String.starts_with?(dest.hero_icon, "hero-")
        assert dest.cluster in [:live, :working, :admin]
        assert is_boolean(dest.fabrikam_only?)
      end
    end

    test "fabrikam_only? entries are Prompts and Admin, in canonical order" do
      # Ordered assertion: if anyone adds another fabrikam_only? entry without
      # updating this list, the test fails immediately. Canonical order is
      # the position in canonical_destinations/0 (Prompts is in the working
      # cluster between Context+Memory and Meetings; Admin is the last entry
      # in the admin cluster).
      fabrikam_only = destinations(is_fabrikam_user: true) |> Enum.filter(& &1.fabrikam_only?)
      assert Enum.map(fabrikam_only, & &1.key) == [:prompts, :admin]
    end

    test "cluster assignment" do
      # Live = Chat / Tasks / Inbox / Activity
      # Working = Skills / Context / Prompts / Meetings (Memory tabs under Context per Marlowe 2026-05-18)
      # Admin = Admin
      by_key =
        destinations(is_fabrikam_user: true)
        |> Enum.into(%{}, fn dest -> {dest.key, dest.cluster} end)

      assert by_key[:chat] == :live
      assert by_key[:tasks] == :live
      assert by_key[:inbox] == :live
      assert by_key[:activity] == :live

      assert by_key[:skills] == :working
      assert by_key[:context] == :working
      assert by_key[:prompts] == :working
      assert by_key[:meetings] == :working

      refute Map.has_key?(by_key, :memory)

      assert by_key[:admin] == :admin
    end
  end

  describe "icon_rail/1 desktop wrapper" do
    test "renders the responsive wrapper with hidden lg:flex flex-col" do
      html = render_icon_rail(%{})
      assert html =~ "hidden lg:flex"
      assert html =~ "flex-col"
      assert html =~ ~s(data-icon-rail)
    end

    test "carries role=navigation and aria-label" do
      html = render_icon_rail(%{})
      assert html =~ ~s(role="navigation")
      assert html =~ ~s(aria-label="Main navigation")
    end

    test "renders Live and Working clusters with group eyebrows (expanded)" do
      html = render_icon_rail(%{})
      assert html =~ ~s(data-cluster="live")
      assert html =~ ~s(data-cluster="working")
      # Stage 4 (task 019f575e): expanded mode labels the groups instead of
      # rendering a bare divider; the hairline only appears collapsed.
      assert html =~ "icon-rail-eyebrow"
      assert html =~ ">Live<"
      assert html =~ ">Working<"
      refute html =~ "icon-rail-divider"
    end

    test "collapsed mode degrades eyebrows to a hairline divider" do
      html = render_icon_rail(%{sidebar_collapsed: true})
      refute html =~ "icon-rail-eyebrow"
      assert html =~ "icon-rail-divider"
    end

    test "omits the Admin cluster tiles when is_fabrikam_user is false" do
      html = render_icon_rail(%{is_fabrikam_user: false})
      # Cluster wrapper still renders (for consistent layout / mt-auto spacer),
      # but no Admin tiles inside it.
      refute html =~ ~s(data-destination="admin")
    end

    test "renders the Admin cluster tile when is_fabrikam_user is true" do
      html = render_icon_rail(%{is_fabrikam_user: true})
      assert html =~ ~s(data-destination="admin")
    end

    test "collapses to lg:w-14 when sidebar_collapsed is true" do
      html = render_icon_rail(%{sidebar_collapsed: true})
      assert html =~ "lg:w-14"
    end

    test "expands to w-56 when sidebar_collapsed is false" do
      html = render_icon_rail(%{sidebar_collapsed: false})
      assert html =~ "w-56"
    end

    test "renders 11 destination tiles for a Fabrikam user (Chat..Meetings + Files + Admin)" do
      # Tile count bumped from 9 → 10 when ADR-0042 stage 5 added Files, and
      # 10 → 11 when task 019fe6ba added Experiments.
      html = render_icon_rail(%{is_fabrikam_user: true})
      assert count_data_destination_matches(html) == 11
    end

    test "renders 9 destination tiles for a non-Fabrikam user (no Admin, no Prompts)" do
      # 7 → 8 when Files (visible to all authenticated users) shipped;
      # 8 → 9 when Experiments shipped (also visible to all).
      html = render_icon_rail(%{is_fabrikam_user: false})
      assert count_data_destination_matches(html) == 9
      assert html =~ ~s(data-destination="experiments")
      assert html =~ "/control/experiments"
    end

    test "Admin slot pins to the bottom of the rail via the mt-auto spacer" do
      html = render_icon_rail(%{is_fabrikam_user: true})
      # A dedicated mt-auto spacer precedes the Admin hairline + cluster,
      # pushing them to the bottom of the flex column. v2 (task 019f575e)
      # dropped the "Admin" eyebrow but kept this mt-auto pinning.
      assert html =~ ~r/mt-auto.*data-cluster="admin"/s
    end
  end

  # v2 (task 019f575e, 2026-07-14): collapsed rail hides the platform logo and
  # renders the expand toggle in the header slot (no standalone toggle row);
  # the Admin group drops its "Admin" eyebrow but keeps a hairline separator.
  # Assert via element extraction (LazyHTML), never attribute-order regex —
  # Phoenix does not guarantee attribute order (see project memory).
  describe "icon_rail/1 — collapsed header toggle + admin label (v2)" do
    test "collapsed mode renders exactly one toggle, inside the header, labelled Expand" do
      doc = render_icon_rail(%{sidebar_collapsed: true}) |> LazyHTML.from_fragment()

      header_buttons = LazyHTML.query(doc, ".icon-rail-header button")
      assert Enum.count(header_buttons) == 1
      assert LazyHTML.attribute(header_buttons, "aria-label") == ["Expand sidebar"]
      assert LazyHTML.attribute(header_buttons, "phx-click") == ["toggle_sidebar"]

      # The v1 standalone toggle row is gone — no toggle lives outside the header.
      all_toggles = LazyHTML.query(doc, ~s(button[phx-click="toggle_sidebar"]))
      assert Enum.count(all_toggles) == 1
    end

    test "collapsed mode hides the platform logo (the toggle takes the header slot)" do
      doc = render_icon_rail(%{sidebar_collapsed: true}) |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query(~s(img[alt="Startup Suite"])) |> Enum.count() == 0
    end

    test "expanded mode keeps logo + wordmark + a single collapse toggle in the header" do
      doc = render_icon_rail(%{sidebar_collapsed: false}) |> LazyHTML.from_fragment()

      assert doc
             |> LazyHTML.query(~s(.icon-rail-header img[alt="Startup Suite"]))
             |> Enum.count() == 1

      header_buttons = LazyHTML.query(doc, ".icon-rail-header button")
      assert Enum.count(header_buttons) == 1
      assert LazyHTML.attribute(header_buttons, "aria-label") == ["Collapse sidebar"]

      all_toggles = LazyHTML.query(doc, ~s(button[phx-click="toggle_sidebar"]))
      assert Enum.count(all_toggles) == 1
    end

    test "no Admin group eyebrow renders for Fabrikam users, in either rail state" do
      for collapsed <- [true, false] do
        doc =
          render_icon_rail(%{is_fabrikam_user: true, sidebar_collapsed: collapsed})
          |> LazyHTML.from_fragment()

        eyebrow_labels =
          doc |> LazyHTML.query(".icon-rail-eyebrow") |> Enum.map(&LazyHTML.text/1)

        refute "Admin" in eyebrow_labels
      end
    end

    test "Admin cluster keeps its tile and a hairline separator (Fabrikam, expanded)" do
      doc =
        render_icon_rail(%{is_fabrikam_user: true, sidebar_collapsed: false})
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(~s([data-destination="admin"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("hr.icon-rail-divider") |> Enum.count() >= 1
    end
  end

  describe "icon_rail/1 — group eyebrows + indent-only child rows (stage 4)" do
    # No canonical destination carries children today (re-parenting is
    # Marlowe's call); the rendering contract is locked in via the
    # `destinations` test seam.
    @stage4_destinations [
      %{
        key: :alpha,
        label: "Alpha",
        path: "/alpha",
        hero_icon: "hero-book-open",
        cluster: :live,
        fabrikam_only?: false,
        children: [%{key: :alpha_child, label: "Alpha Child", path: "/alpha/child"}]
      },
      %{
        key: :beta,
        label: "Beta",
        path: "/beta",
        hero_icon: "hero-inbox",
        cluster: :working,
        fabrikam_only?: false
      }
    ]

    defp render_with_children(assigns) do
      assigns =
        Map.merge(
          %{
            current_path: "/",
            is_fabrikam_user: false,
            sidebar_collapsed: false,
            destinations: @stage4_destinations
          },
          assigns
        )

      rendered_to_string(~H"""
      <.icon_rail
        current_path={@current_path}
        is_fabrikam_user={@is_fabrikam_user}
        sidebar_collapsed={@sidebar_collapsed}
        destinations={@destinations}
      />
      """)
    end

    test "child rows render indent-only (no icon) in expanded mode" do
      html = render_with_children(%{})
      [child_link] = Regex.run(~r/<a[^>]*data-destination="alpha_child".*?<\/a>/s, html)
      assert child_link =~ "icon-rail-tab--child"
      refute child_link =~ "hero-"
      assert child_link =~ "Alpha Child"
    end

    test "child route lights the child with the shared active grammar, not the parent" do
      html = render_with_children(%{current_path: "/alpha/child"})
      assert html =~ ~r/icon-rail-tab--child[^"]*icon-rail-tab--active/
      # Attribute ORDER within a tag is non-deterministic across runs —
      # extract each element, then assert attributes independently.
      [child_link] = Regex.run(~r/<a[^>]*data-destination="alpha_child"[^>]*>/, html)
      assert child_link =~ ~s(aria-current="page")
      [parent_link] = Regex.run(~r/<a[^>]*data-destination="alpha"[^>]*>/, html)
      refute parent_link =~ "aria-current"
    end

    test "collapsed mode drops child rows and lights the parent for a child route" do
      html = render_with_children(%{current_path: "/alpha/child", sidebar_collapsed: true})
      refute html =~ "alpha_child"
      [parent_link] = Regex.run(~r/<a[^>]*data-destination="alpha"[^>]*>/, html)
      assert parent_link =~ "icon-rail-tab--active"
    end
  end

  describe "icon_rail/1 hero icons" do
    test "renders the hero icon class for every visible destination" do
      html = render_icon_rail(%{is_fabrikam_user: true})

      for dest <- destinations(is_fabrikam_user: true) do
        assert html =~ dest.hero_icon,
               "expected hero icon class #{inspect(dest.hero_icon)} for destination #{inspect(dest.key)}"
      end
    end

    test "does not render the Admin hero icon when is_fabrikam_user is false" do
      html = render_icon_rail(%{is_fabrikam_user: false})
      # hero-cog-6-tooth belongs to Admin only — should be absent.
      refute html =~ "hero-cog-6-tooth"
    end
  end

  describe "icon_rail/1 active state" do
    test "applies .icon-rail-tab--active only to the tile whose path matches current_path" do
      html = render_icon_rail(%{current_path: "/tasks"})

      # Active class is paired with the Tasks tile.
      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="tasks"/
      # And NOT paired with any other tile (Chat / Inbox / Activity / Skills / ...).
      refute html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="chat"/
      refute html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="inbox"/
    end

    test "no tile gets the active class when current_path matches nothing" do
      html = render_icon_rail(%{current_path: "/no-such-route"})
      refute html =~ "icon-rail-tab--active"
    end

    test "active tile carries aria-current=page" do
      html = render_icon_rail(%{current_path: "/chat"})
      # Chat tile renders with aria-current="page".
      assert html =~ ~r/data-destination="chat"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="chat"/s
    end

    test "non-active tiles do NOT carry aria-current=page" do
      html = render_icon_rail(%{current_path: "/chat"})
      refute html =~ ~r/data-destination="tasks"[^>]*aria-current="page"/s
    end

    test "every desktop tile carries an aria-label" do
      html = render_icon_rail(%{is_fabrikam_user: true})

      for dest <- destinations(is_fabrikam_user: true) do
        assert html =~ ~s(aria-label="#{dest.label}"),
               "expected aria-label=#{inspect(dest.label)} for destination #{inspect(dest.key)}"
      end
    end
  end

  describe "icon_rail/1 active state — nested-route prefix matching" do
    test "a nested chat route (/chat/:slug) lights the Chat parent tile" do
      html = render_icon_rail(%{current_path: "/chat/some-space"})

      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="chat"/

      assert html =~ ~r/data-destination="chat"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="chat"/s

      # Only Chat — no sibling tile lights up.
      refute html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="tasks"/
    end

    test "a nested task route (/tasks/:id) lights the Tasks parent tile" do
      html = render_icon_rail(%{current_path: "/tasks/019abc"})
      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="tasks"/
    end

    test "a multi-segment glob route (/org_memory/*file_key) lights Org Memory" do
      # The :context destination owns /org_memory; the catch-all file path is a
      # descendant at a segment boundary, so prefix matching must catch it.
      html = render_icon_rail(%{current_path: "/org_memory/org/identity.md"})
      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="context"/
    end

    test "a path that merely shares a prefix (/tasksy) matches NOTHING" do
      # Segment-boundary guard: /tasksy must not be treated as a child of /tasks.
      html = render_icon_rail(%{current_path: "/tasksy"})
      refute html =~ "icon-rail-tab--active"
    end

    test "longest prefix wins: /admin/prompts lights Prompts, not Admin" do
      html = render_icon_rail(%{current_path: "/admin/prompts", is_fabrikam_user: true})

      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="prompts"/
      refute html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="admin"/
    end

    test "exact /admin lights Admin (and not Prompts)" do
      html = render_icon_rail(%{current_path: "/admin", is_fabrikam_user: true})

      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="admin"/
      refute html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="prompts"/
    end
  end

  describe "bottom_rail/1 mobile wrapper" do
    test "renders the bottom-nav wrapper with lg:hidden" do
      html = render_bottom_rail(%{})
      assert html =~ "bottom-nav"
      assert html =~ "lg:hidden"
      assert html =~ ~s(data-bottom-rail)
    end

    test "carries role=navigation and aria-label on the mobile wrapper" do
      html = render_bottom_rail(%{})
      assert html =~ ~s(role="navigation")
      assert html =~ ~s(aria-label="Main navigation")
    end

    test "renders exactly 5 tiles: Chat / Tasks / Inbox / Activity / More" do
      html = render_bottom_rail(%{})
      assert html =~ ~s(data-destination="chat")
      assert html =~ ~s(data-destination="tasks")
      assert html =~ ~s(data-destination="inbox")
      assert html =~ ~s(data-destination="activity")
      assert html =~ ~s(data-destination="more")
    end

    test "More tile is a button firing phx-click=open_more_sheet" do
      html = render_bottom_rail(%{})
      assert html =~ ~s(phx-click="open_more_sheet")
      assert html =~ ~s(aria-label="More surfaces")
    end

    test "tile count is invariant to is_fabrikam_user (Admin lives in More sheet)" do
      fabrikam = render_bottom_rail(%{is_fabrikam_user: true})
      non_fabrikam = render_bottom_rail(%{is_fabrikam_user: false})

      assert count_data_destination_matches(fabrikam) == 5
      assert count_data_destination_matches(non_fabrikam) == 5
    end
  end

  describe "bottom_rail/1 hero icons" do
    test "renders the hero icon class for each of the 5 mobile tiles" do
      html = render_bottom_rail(%{})

      assert html =~ "hero-chat-bubble-left-right"
      assert html =~ "hero-rectangle-stack"
      assert html =~ "hero-inbox"
      assert html =~ "hero-sparkles"
      # More tile uses ellipsis-horizontal.
      assert html =~ "hero-ellipsis-horizontal"
    end
  end

  describe "bottom_rail/1 active state" do
    test "applies .bottom-nav-tab--active only to the tile whose path matches current_path" do
      html = render_bottom_rail(%{current_path: "/tasks"})

      assert html =~ ~r/bottom-nav-tab--active[^"]*"[^>]*data-destination="tasks"/
      refute html =~ ~r/bottom-nav-tab--active[^"]*"[^>]*data-destination="chat"/
    end

    test "active mobile tile carries aria-current=page" do
      html = render_bottom_rail(%{current_path: "/activity"})

      assert html =~ ~r/data-destination="activity"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="activity"/s
    end

    test "every mobile destination tile carries an aria-label" do
      html = render_bottom_rail(%{})

      for label <- ["Chat", "Tasks", "Inbox", "Activity"] do
        assert html =~ ~s(aria-label="#{label}"),
               "expected aria-label=#{inspect(label)} on mobile bottom-rail"
      end
    end

    test "a nested chat route (/chat/:slug) lights the Chat tab" do
      # On mobile this is the user's only 'where am I' cue inside a conversation.
      html = render_bottom_rail(%{current_path: "/chat/some-space"})
      assert html =~ ~r/bottom-nav-tab--active[^"]*"[^>]*data-destination="chat"/
    end

    test "a More-sheet-only surface (/skills) lights NO bottom-rail tile" do
      # Skills lives in the More sheet, not the bar, so nothing in the bar is
      # active — the winner is computed over the 4 primary tiles only.
      html = render_bottom_rail(%{current_path: "/skills"})
      refute html =~ "bottom-nav-tab--active"
    end

    test "the More button never carries aria-current (it is a sheet trigger, not a route)" do
      html = render_bottom_rail(%{current_path: "/chat"})
      refute html =~ ~r/data-destination="more"[^>]*aria-current/s
    end
  end

  defp count_data_destination_matches(html) do
    Regex.scan(~r/data-destination="[^"]+"/, html) |> length()
  end

  # ---------------------------------------------------------------------
  # Inbox unread badge (task 019f904d / M7)
  #
  # `inbox_unread_count` renders an attention pill on the Inbox tile only.
  # 0 omits the badge node entirely (not a transparent/empty pill); 1..99
  # render the integer; >99 renders "99+" (ADR-0022 overflow grammar). The
  # badge is icon-anchored so it survives the collapsed rail, and uses the
  # destructive/accent semantic slot (`badge-error`) — no raw hex.
  # ---------------------------------------------------------------------
  describe "icon_rail/1 inbox unread badge" do
    defp render_rail_with_count(count, opts \\ %{}) do
      assigns =
        Map.merge(
          %{
            current_path: "/chat",
            is_fabrikam_user: false,
            sidebar_collapsed: false,
            inbox_unread_count: count
          },
          opts
        )

      rendered_to_string(~H"""
      <.icon_rail
        current_path={@current_path}
        is_fabrikam_user={@is_fabrikam_user}
        sidebar_collapsed={@sidebar_collapsed}
        inbox_unread_count={@inbox_unread_count}
      />
      """)
    end

    defp inbox_badge_text(doc) do
      doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> LazyHTML.text() |> String.trim()
    end

    test "count 0 renders the Inbox tile with NO badge node present" do
      doc = render_rail_with_count(0) |> LazyHTML.from_fragment()

      # The Inbox tile itself still renders — only the badge node is absent.
      assert doc |> LazyHTML.query(~s([data-destination="inbox"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> Enum.count() == 0
    end

    test "count 3 renders a badge containing \"3\" on the Inbox tile" do
      doc = render_rail_with_count(3) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> Enum.count() == 1
      assert inbox_badge_text(doc) == "3"
    end

    test "count 99 renders \"99\" (no overflow marker at the boundary)" do
      doc = render_rail_with_count(99) |> LazyHTML.from_fragment()
      assert inbox_badge_text(doc) == "99"
    end

    test "count 150 renders \"99+\" (overflow)" do
      doc = render_rail_with_count(150) |> LazyHTML.from_fragment()
      assert inbox_badge_text(doc) == "99+"
    end

    test "the badge attaches ONLY to the Inbox tile — not Chat/Tasks/etc." do
      doc = render_rail_with_count(5) |> LazyHTML.from_fragment()

      # Exactly one badge in the whole rail...
      assert doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> Enum.count() == 1
      # ...nested under the Inbox tile...
      assert doc
             |> LazyHTML.query(~s([data-destination="inbox"] [data-role="inbox-badge"]))
             |> Enum.count() == 1

      # ...and not under any sibling tile.
      assert doc
             |> LazyHTML.query(~s([data-destination="chat"] [data-role="inbox-badge"]))
             |> Enum.count() == 0

      assert doc
             |> LazyHTML.query(~s([data-destination="tasks"] [data-role="inbox-badge"]))
             |> Enum.count() == 0
    end

    test "the badge renders in BOTH collapsed and expanded rail (icon-anchored)" do
      for collapsed <- [true, false] do
        doc =
          render_rail_with_count(4, %{sidebar_collapsed: collapsed}) |> LazyHTML.from_fragment()

        assert doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> Enum.count() == 1,
               "expected an Inbox badge with sidebar_collapsed=#{collapsed}"

        assert inbox_badge_text(doc) == "4"
      end
    end

    # Task 01a00066 stage 4 pins the badge's LOOK as unchanged: the count is
    # filtered upstream (`Inbox.reachable_unread_count/1`), so `badge_text/1`
    # keeps exactly one cap at 99. A second cap introduced for external users
    # would detonate here.
    test "badge_text/1 caps at 99+ and has NO second cap" do
      assert badge_text(99) == "99"
      assert badge_text(100) == "99+"
      assert badge_text(1_000) == "99+"
      assert badge_text(10_000) == "99+"

      # Exactly one threshold in 1..250: the value stops changing after 99.
      distinct = 1..250 |> Enum.map(&badge_text/1) |> Enum.uniq()
      assert Enum.count(distinct) == 100
      assert List.last(distinct) == "99+"

      # Nothing below the cap is rewritten, and 0 still renders no badge.
      assert badge_text(1) == "1"
      assert badge_text(0) == nil
    end

    test "the badge uses the destructive/accent semantic slot (badge-error), no raw hex" do
      doc = render_rail_with_count(3) |> LazyHTML.from_fragment()

      [class] =
        doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> LazyHTML.attribute("class")

      assert class =~ "badge-error"
      refute class =~ ~r/#[0-9a-fA-F]{3,6}/
    end
  end

  # ---------------------------------------------------------------------
  # Notification state is NOT in the rail (task 019ffb7b stage 4, revised).
  #
  # The first cut of this stage put a notification-state bell in the Live
  # cluster, under the Inbox tile. Marlowe rejected the placement on review: the
  # row navigated nowhere, and it collided with the Inbox tile beside it, which
  # is where the actual notifications land. The row now lives on `/inbox` and
  # its behavioural tests moved with it, to `notification_state_test.exs`.
  # What stays here is the guard against the bell coming back: the rail is a
  # list of navigation targets and each tile keeps exactly one behaviour.
  # ---------------------------------------------------------------------
  describe "icon_rail/1 carries no notification state" do
    test "no bell node renders, at either rail width, with or without unread items" do
      for collapsed <- [true, false], count <- [0, 7], fabrikam <- [true, false] do
        doc =
          count
          |> render_rail_with_count(%{sidebar_collapsed: collapsed, is_fabrikam_user: fabrikam})
          |> LazyHTML.from_fragment()

        for selector <- [
              ~s([data-role="notification-bell"]),
              ~s([data-role="notification-bell-trigger"]),
              ~s([data-role="notification-off-dot"]),
              ~s([data-role="notification-popover"]),
              ~s([data-role="notification-state"]),
              ~s([phx-click="toggle_push_popover"]),
              ~s([phx-click="close_push_popover"]),
              ~s([phx-click="enable_notifications"])
            ] do
          assert doc |> LazyHTML.query(selector) |> Enum.count() == 0,
                 "expected no #{selector} in the rail " <>
                   "(collapsed=#{collapsed}, count=#{count}, fabrikam=#{fabrikam})"
        end

        # Positive control: this is a fully rendered rail, so the absences
        # above are about the bell and not about an empty render.
        assert doc |> LazyHTML.query(~s([data-destination="inbox"])) |> Enum.count() == 1
      end
    end

    test "the component no longer accepts a notification-permission state at all" do
      attrs =
        PlatformWeb.Components.IconRail.__components__()
        |> Map.fetch!(:icon_rail)
        |> Map.fetch!(:attrs)
        |> Enum.map(& &1.name)

      refute :push_permission in attrs
      refute :push_popover_open in attrs

      # Positive control: the attr list is real, so the two refutes above are
      # reading a populated list rather than an empty one.
      assert :inbox_unread_count in attrs
    end
  end

  # ---------------------------------------------------------------------
  # Chat unread badge (task 01a01b29 stage 2; cap raised in 01a02491 stage 2)
  #
  # `chat_unread_count` renders an unread pill on the Chat tile only. Same
  # zero contract as Inbox (0 omits the node entirely) and the same
  # icon-anchoring, so it survives the collapsed rail.
  #
  # ONE thing differs from Inbox, and it is a design decision rather than
  # incidental: the fill is `badge-primary` (cyan), NOT `badge-error`. Red is
  # reserved for Inbox, which means "addressed to you". Chat unread is ambient
  # and near-permanently non-zero, and a permanently red rail is one nobody
  # reads.
  #
  # The overflow cap USED to differ too, at 9+, matched to ChatLive's
  # `unread_label/1`. Task 01a02491 stage 2 raised it to 99+, matching
  # `badge_text/1`. The rail total sums every channel, DM and group the viewer
  # participates in, so it was never the same quantity as a single per-channel
  # pill; the badge's real sibling is the Inbox badge two tiles away in the
  # same 56px column. Three glyphs were measured to fit that column, and the
  # geometry is recorded above `badge_spec/3` in icon_rail.ex.
  #
  # `ChatLive.unread_label/1` stays at 9+ on purpose and is out of scope here.
  # ---------------------------------------------------------------------
  describe "icon_rail/1 chat unread badge" do
    # Sibling of render_rail_with_count/2 that passes BOTH counts, so a test
    # can put the two badges in one rail and check they stay distinct.
    defp render_rail_with_counts(chat_count, inbox_count \\ 0, opts \\ %{}) do
      assigns =
        Map.merge(
          %{
            current_path: "/tasks",
            is_fabrikam_user: false,
            sidebar_collapsed: false,
            inbox_unread_count: inbox_count,
            chat_unread_count: chat_count
          },
          opts
        )

      rendered_to_string(~H"""
      <.icon_rail
        current_path={@current_path}
        is_fabrikam_user={@is_fabrikam_user}
        sidebar_collapsed={@sidebar_collapsed}
        inbox_unread_count={@inbox_unread_count}
        chat_unread_count={@chat_unread_count}
      />
      """)
    end

    defp chat_badge_node_text(doc) do
      doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> LazyHTML.text() |> String.trim()
    end

    defp badge_class(doc, role) do
      [class] = doc |> LazyHTML.query(~s([data-role="#{role}"])) |> LazyHTML.attribute("class")
      class
    end

    test "count 0 renders the Chat tile with NO badge node present" do
      doc = render_rail_with_counts(0) |> LazyHTML.from_fragment()

      # The tile half of this assertion is not padding: without it, a typo in
      # the badge selector would pass the absence check against any render at
      # all, including an empty one.
      assert doc |> LazyHTML.query(~s([data-destination="chat"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> Enum.count() == 0
    end

    test "count 3 renders a badge containing \"3\" on the Chat tile" do
      doc = render_rail_with_counts(3) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> Enum.count() == 1
      assert chat_badge_node_text(doc) == "3"

      assert doc
             |> LazyHTML.query(~s([data-destination="chat"] [data-role="chat-badge"]))
             |> Enum.count() == 1
    end

    test "the 99+ cap is pinned on BOTH sides of the boundary" do
      assert render_rail_with_counts(99) |> LazyHTML.from_fragment() |> chat_badge_node_text() ==
               "99"

      assert render_rail_with_counts(100) |> LazyHTML.from_fragment() |> chat_badge_node_text() ==
               "99+"
    end

    test "count 40 renders the exact \"40\", not the old \"9+\" and not \"99+\"" do
      text = render_rail_with_counts(40) |> LazyHTML.from_fragment() |> chat_badge_node_text()

      assert text == "40"
      # The cap this stage removed.
      refute text == "9+"
      # And no premature overflow either: 40 is under the new cap, not at it.
      refute text == "99+"
    end

    test "chat_badge_text/1 caps at 99+ and has NO second cap below it" do
      assert chat_badge_text(0) == nil
      assert chat_badge_text(-1) == nil
      assert chat_badge_text(1) == "1"

      # The old cap's boundary. 9 is an ordinary number now.
      assert chat_badge_text(8) == "8"
      assert chat_badge_text(9) == "9"

      # Mid-range, which is what proves there is no second cap between 9 and 99.
      assert chat_badge_text(40) == "40"

      assert chat_badge_text(99) == "99"
      assert chat_badge_text(100) == "99+"
      assert chat_badge_text(1_000) == "99+"

      # Exactly 100 distinct labels in 1..250: "1".."99" and then "99+".
      distinct = 1..250 |> Enum.map(&chat_badge_text/1) |> Enum.uniq()
      assert Enum.count(distinct) == 100
      assert List.last(distinct) == "99+"
    end

    # Both caps are 99+ from this stage on, so the two functions agree at every
    # input and the obvious next move is to collapse them into one. This test
    # is what stops that refactor moving Inbox by accident: `badge_text/1` is
    # public and ALSO feeds ShellLive's `AppBadge` document-title label, so its
    # contract has to be pinned independently of Chat's. Keep this test whether
    # or not the implementations are ever shared.
    test "badge_text/1 is unmoved at the inputs chat_badge_text/1 just changed on" do
      assert badge_text(0) == nil
      assert badge_text(40) == "40"
      assert badge_text(99) == "99"
      assert badge_text(100) == "99+"
      assert badge_text(150) == "99+"
    end

    test "the badge carries the primary fill and NOT badge-error, with no raw hex" do
      class = render_rail_with_counts(3) |> LazyHTML.from_fragment() |> badge_class("chat-badge")

      assert class =~ "badge-primary"
      # Both halves matter. A node carrying BOTH classes would satisfy the
      # assertion above on its own, and that node is exactly what copying the
      # Inbox markup produces.
      refute class =~ "badge-error"
      refute class =~ ~r/#[0-9a-fA-F]{3,6}/
    end

    test "the aria-label is the only place the word unread appears on the badge" do
      doc = render_rail_with_counts(3) |> LazyHTML.from_fragment()

      [label] =
        doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> LazyHTML.attribute("aria-label")

      assert label == "3 unread messages"
      # The visible glyph is a bare number.
      assert chat_badge_node_text(doc) == "3"
    end

    test "over the cap the aria-label keeps the TRUE count while the glyph caps" do
      doc = render_rail_with_counts(150, 150) |> LazyHTML.from_fragment()

      [chat_label] =
        doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> LazyHTML.attribute("aria-label")

      [inbox_label] =
        doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> LazyHTML.attribute("aria-label")

      inbox_text =
        doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> LazyHTML.text() |> String.trim()

      # A screen reader has no 56px problem, so it gets the count and not the
      # label. Asserted on BOTH badges: on one alone the assertion could pass
      # while the other silently started announcing "99+".
      assert chat_label == "150 unread messages"
      assert inbox_label == "150 unread"

      assert chat_badge_node_text(doc) == "99+"
      assert inbox_text == "99+"
    end

    test "generalising the badge leaves the Inbox badge exactly as it was" do
      doc = render_rail_with_counts(5, 120) |> LazyHTML.from_fragment()

      # Two nodes, one each, on their own tiles.
      assert doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s([data-destination="inbox"] [data-role="inbox-badge"]))
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s([data-destination="chat"] [data-role="inbox-badge"]))
             |> Enum.count() == 0

      assert doc
             |> LazyHTML.query(~s([data-destination="inbox"] [data-role="chat-badge"]))
             |> Enum.count() == 0

      # Inbox keeps its own cap and its own fill.
      inbox_text =
        doc |> LazyHTML.query(~s([data-role="inbox-badge"])) |> LazyHTML.text() |> String.trim()

      assert inbox_text == "99+"
      assert badge_class(doc, "inbox-badge") =~ "badge-error"
      refute badge_class(doc, "inbox-badge") =~ "badge-primary"

      # ...and Chat keeps its own.
      assert chat_badge_node_text(doc) == "5"
      assert badge_class(doc, "chat-badge") =~ "badge-primary"
    end

    test "the badge attaches ONLY to the Chat tile" do
      doc = render_rail_with_counts(4) |> LazyHTML.from_fragment()

      for other <- ~w(tasks inbox activity) do
        assert doc
               |> LazyHTML.query(~s([data-destination="#{other}"] [data-role="chat-badge"]))
               |> Enum.count() == 0,
               ~s(expected no chat badge on the "#{other}" tile)
      end
    end

    test "the badge survives the collapsed rail (icon-anchored, not label-anchored)" do
      for collapsed <- [true, false] do
        doc =
          render_rail_with_counts(6, 0, %{sidebar_collapsed: collapsed})
          |> LazyHTML.from_fragment()

        assert doc |> LazyHTML.query(~s([data-role="chat-badge"])) |> Enum.count() == 1,
               "expected a Chat badge with sidebar_collapsed=#{collapsed}"

        assert chat_badge_node_text(doc) == "6"
      end
    end

    test "icon_rail/1 declares chat_unread_count alongside inbox_unread_count" do
      attrs =
        PlatformWeb.Components.IconRail.__components__()
        |> Map.fetch!(:icon_rail)
        |> Map.fetch!(:attrs)
        |> Enum.map(& &1.name)

      assert :chat_unread_count in attrs
      assert :inbox_unread_count in attrs
    end
  end
end
