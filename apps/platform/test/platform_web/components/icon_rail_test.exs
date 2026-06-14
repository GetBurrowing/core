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
    test "returns 7 destinations for a non-Fabrikam user (Admin + Prompts filtered out)" do
      list = destinations(is_fabrikam_user: false)
      assert length(list) == 7
      refute Enum.any?(list, &(&1.key == :admin))
      # Prompts is also fabrikam_only?: true as of 2026-05-20 (admin-only access
      # at the route level; previously rendered for members but redirected
      # on click — bug fixed by filtering fabrikam_only? in all clusters).
      refute Enum.any?(list, &(&1.key == :prompts))
    end

    test "returns all 9 destinations for a Fabrikam user (Admin + Prompts included)" do
      list = destinations(is_fabrikam_user: true)
      assert length(list) == 9
      assert Enum.any?(list, &(&1.key == :admin))
      assert Enum.any?(list, &(&1.key == :prompts))
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

    test "renders Live and Working clusters with a divider" do
      html = render_icon_rail(%{})
      assert html =~ ~s(data-cluster="live")
      assert html =~ ~s(data-cluster="working")
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

    test "renders 10 destination tiles for a Fabrikam user (Chat..Meetings + Admin)" do
      html = render_icon_rail(%{is_fabrikam_user: true})
      assert count_data_destination_matches(html) == 9
    end

    test "renders 7 destination tiles for a non-Fabrikam user (no Admin, no Prompts)" do
      html = render_icon_rail(%{is_fabrikam_user: false})
      assert count_data_destination_matches(html) == 7
    end

    test "Admin slot uses mt-auto so it pins to the bottom of the rail" do
      html = render_icon_rail(%{is_fabrikam_user: true})
      # The Admin cluster wrapper carries the mt-auto class, which pushes it
      # to the bottom of the flex column above the collapse toggle.
      assert html =~ ~r/class="mt-auto[^"]*icon-rail-cluster--admin/ or
               html =~ ~r/mt-auto[^"]*data-cluster="admin"/s
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
end
