defmodule PlatformWeb.OrgMemoryLiveMobileTest do
  @moduledoc """
  Mobile (`lg:hidden`) branch coverage for `PlatformWeb.OrgMemoryLive`
  (task 019f9282 — the /org_memory mobile surface).

  The mobile branch (`PlatformWeb.OrgMemoryLive.MobileShell`) renders in
  the SAME DOM as the desktop three-pane grid — CSS toggles visibility,
  not presence — so these tests assert on the mobile-scoped `data-role`s
  / ids (`mobile-shell`, `mobile-tabs`, `mobile-path-chip`,
  `mobile-search`, `m-org-memory-*`, `#org-memory-tree-drawer`, …) which
  never collide with the desktop panes. The last test guards the
  invariant in the other direction: no `lg:hidden` mobile markup leaks
  INTO the desktop `[data-view-mode]` grid.

  Behaviours covered: segmented tab switches, path chip present per tab /
  ABSENT on Search, tree drawer open + close-on-select, the Pages details
  accordion, the append-only journal composer, the Insights rows, the
  search input + facet chips (dispatch through the `:org_memory_tool_surface`
  seam), and the desktop-guard.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Memory.Insight
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @proj "5f1e7a90-2222-7000-8000-bbbbbbbbbbbb"

  defmodule StubToolSurface do
    @moduledoc false

    def execute("memory_search", args, context) do
      if pid = Application.get_env(:platform, :org_memory_tool_surface_test_pid) do
        send(pid, {:memory_search, args, context})
      end

      {:ok,
       %{
         results: [
           %{
             source: "page",
             id: Ecto.UUID.generate(),
             path: "org/page/identity.md",
             space_id: nil,
             content: "Deployment runbook lives in the identity page.",
             score: 0.0328,
             semantic_rank: 1,
             lexical_rank: 2,
             authored_by: nil,
             date_or_inserted_at: "2026-06-01T12:00:00Z"
           }
         ],
         fusion_constant_k: 60,
         truncated: false
       }}
    end
  end

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(
      Map.merge(
        %{
          email: "org-memory-mobile-#{n}@example.com",
          name: "Org Memory Mobile #{n}",
          oidc_sub: "oidc-org-memory-mobile-#{n}"
        },
        overrides
      )
    )
    |> Repo.insert!()
  end

  defp authed(conn) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => create_user!().id})
  end

  defp seed_pages! do
    Repo.delete_all(WikiPage)

    {:ok, _} =
      Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n\nSee [[memory]].\n"})

    {:ok, _} =
      Wiki.upsert_page("org/page/memory.md", %{
        content: "# Memory\n\nLinks [[org/page/identity.md]].\n"
      })

    {:ok, _} =
      Wiki.upsert_page("project/#{@proj}/page/decisions.md", %{content: "# Decisions\n"})

    :ok
  end

  defp mount_page(conn) do
    seed_pages!()
    live(authed(conn), "/org_memory/org/page/identity.md")
  end

  describe "mobile shell + segmented tabs" do
    test "renders the slim app-bar, menu button and the four segmented tabs", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      assert has_element?(view, ~s([data-role="mobile-shell"]))
      assert has_element?(view, ~s([data-role="mobile-app-bar"]))

      assert has_element?(
               view,
               ~s([data-role="mobile-menu-button"][phx-click="open_tree_drawer"])
             )

      for tab <- ~w(pages journal search insights) do
        assert has_element?(view, ~s([data-role="mobile-tabs"] button[data-mobile-tab="#{tab}"]))
      end

      # Pages is active on mount; the app-bar plus (show_create) shows only on Pages.
      assert has_element?(view, ~s(button[data-mobile-tab="pages"][aria-selected="true"]))
      assert has_element?(view, ~s([data-role="mobile-app-bar-action"][phx-click="show_create"]))
    end

    test "a mobile tab click switches view_mode (reuses switch_tab)", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      view |> element(~s([data-mobile-tab="journal"])) |> render_click()
      assert has_element?(view, ~s(button[data-mobile-tab="journal"][aria-selected="true"]))
      assert has_element?(view, ~s([data-role="mobile-journal"]))
    end
  end

  describe "namespace path chip (present per tab, absent on Search)" do
    test "renders the mono breadcrumb for the selected page on Pages", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      assert has_element?(view, ~s([data-role="mobile-path-chip"]))
      # org/page/identity.md → org › identity (page/ collapsed, .md dropped)
      assert has_element?(view, ~s([data-role="mobile-path-chip"] [data-chip-segment="org"]))
      assert has_element?(view, ~s([data-role="mobile-path-chip"] [data-chip-segment="identity"]))
      # tapping a segment opens the tree drawer
      assert has_element?(
               view,
               ~s([data-role="mobile-path-chip"] button[phx-click="open_tree_drawer"])
             )
    end

    test "present on Journal and Insights, ABSENT on Search", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      view |> element(~s([data-mobile-tab="journal"])) |> render_click()
      assert has_element?(view, ~s([data-role="mobile-path-chip"]))

      view |> element(~s([data-mobile-tab="search"])) |> render_click()
      refute has_element?(view, ~s([data-role="mobile-path-chip"]))
      assert has_element?(view, ~s([data-role="mobile-search"]))

      view |> element(~s([data-mobile-tab="insights"])) |> render_click()
      assert has_element?(view, ~s([data-role="mobile-path-chip"]))
    end
  end

  describe "slide-out tree drawer" do
    test "opens on the menu button and closes on leaf select", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      # closed by default
      assert has_element?(view, ~s(#org-memory-tree-drawer[data-open="false"]))

      view |> element(~s([data-role="mobile-menu-button"])) |> render_click()
      assert has_element?(view, ~s(#org-memory-tree-drawer[data-open="true"]))
      # the drawer body renders the same NamespaceTree (leaves carry data-file-key)
      assert has_element?(view, ~s(#org-memory-tree-drawer [data-file-key="org/page/memory.md"]))

      # selecting a page closes the drawer (close-on-select) + navigates
      render_click(view, "select_page", %{"file_key" => "org/page/memory.md"})
      assert has_element?(view, ~s(#org-memory-tree-drawer[data-open="false"]))
    end
  end

  describe "Pages details accordion" do
    test "renders the collapsed details with backlinks + version metadata", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      assert has_element?(view, ~s([data-role="mobile-details"]))
      assert has_element?(view, ~s([data-role="mobile-page-meta"]))
      # memory.md links to org/page/identity.md → a backlink row renders
      assert has_element?(
               view,
               ~s([data-role="mobile-details"] button[phx-click="select_page"][phx-value-file_key="org/page/memory.md"])
             )
    end
  end

  describe "journal composer + feed (append-only)" do
    test "renders the mobile composer with no delete affordance", %{conn: conn} do
      seed_pages!()

      Journal.append(%{content: "note one", date: Date.utc_today(), authored_by: nil},
        namespace: "org"
      )

      {:ok, view, _html} = live(authed(conn), "/org_memory")
      view |> element(~s([data-mobile-tab="journal"])) |> render_click()

      assert has_element?(view, ~s(#m-org-memory-journal-form textarea[name="content"]))
      assert has_element?(view, ~s(#m-org-memory-journal-form button[type="submit"]))
      # append-only: no delete affordance anywhere in the mobile journal
      refute has_element?(view, ~s([data-role="mobile-journal"] button[phx-click="delete_file"]))
    end
  end

  # Task 01a13867 stage 5: the mobile Insights tab renders the SAME rows as
  # desktop (`InsightsPane` with `surface={:mobile}`), with `m-`-prefixed
  # ids so the two branches never share a DOM id.
  describe "insights rows (mobile)" do
    setup do
      Repo.delete_all(Insight)
      :ok
    end

    test "renders the row with its preview and one primary named for the action, all >=44px",
         %{conn: conn} do
      seed_pages!()
      addressee = Platform.InsightFixtures.person!()

      insight =
        Platform.InsightFixtures.insight!(
          action_type: "question",
          addressee: addressee,
          body: "Who owns the staging bucket?"
        )

      {:ok, view, _html} = live(authed(conn), "/memory/insights")

      row = ~s([data-role="mobile-body"] #m-insight-row-#{insight.id})
      assert has_element?(view, row)
      assert has_element?(view, row <> ~s( [data-role="insight-type-label"]), "QUESTION")
      assert has_element?(view, row <> ~s( [data-role="insight-expiry"]), "d left")
      assert has_element?(view, row <> ~s( [data-role="insight-preview-to"]), addressee.name)

      assert has_element?(
               view,
               row <> ~s( [data-role="insight-primary"].btn-primary.min-h-11),
               "Ask"
             )

      for role <- ~w(insight-reject insight-reroute-button insight-edit-button insight-dismiss) do
        assert has_element?(view, row <> ~s( [data-role="#{role}"].min-h-11))
      end

      # The desktop row is the same insight under its own id.
      assert has_element?(view, ~s(#insight-row-#{insight.id}))
    end

    test "the mobile reject form is id-prefixed and needs a reason", %{conn: conn} do
      seed_pages!()
      insight = Platform.InsightFixtures.insight!(body: "Deploys moved to moon.")

      {:ok, view, _html} = live(authed(conn), "/memory/insights")

      view
      |> element(~s(#m-insight-row-#{insight.id} [data-role="insight-reject"]))
      |> render_click()

      assert has_element?(view, ~s(#m-insight-reject-form-#{insight.id} textarea[name="reason"]))
      assert has_element?(view, ~s(#insight-reject-form-#{insight.id}))

      view
      |> form("#m-insight-reject-form-#{insight.id}", %{"reason" => "Not true."})
      |> render_submit()

      assert %Insight{state: "dismissed"} = Repo.get!(Insight, insight.id)
      refute has_element?(view, ~s(#m-insight-row-#{insight.id}))
    end
  end

  describe "search input + facet chips" do
    setup do
      previous = Application.get_env(:platform, :org_memory_tool_surface)
      Application.put_env(:platform, :org_memory_tool_surface, StubToolSurface)
      Application.put_env(:platform, :org_memory_tool_surface_test_pid, self())

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :org_memory_tool_surface, previous)
        else
          Application.delete_env(:platform, :org_memory_tool_surface)
        end

        Application.delete_env(:platform, :org_memory_tool_surface_test_pid)
      end)

      :ok
    end

    test "renders the persistent input + corpus facet chips (>=44px), no path chip", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)
      view |> element(~s([data-mobile-tab="search"])) |> render_click()

      refute has_element?(view, ~s([data-role="mobile-path-chip"]))
      assert has_element?(view, ~s(#m-org-memory-search-form input[name="query"]))

      for c <- ~w(all page journal message) do
        assert has_element?(
                 view,
                 ~s([data-role="mobile-search-facets"] button[data-facet-corpus="#{c}"])
               )
      end
    end

    test "submitting the input dispatches memory_search and renders result cards", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)
      view |> element(~s([data-mobile-tab="search"])) |> render_click()

      view
      |> form("#m-org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      assert_receive {:memory_search, %{"query" => "deployment"}, _ctx}
      assert has_element?(view, ~s([data-role="mobile-search-result"]))
    end

    test "toggling a corpus facet re-dispatches with the source filter", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)
      view |> element(~s([data-mobile-tab="search"])) |> render_click()

      # establish a query first (facet chips carry the last submitted query)
      view |> form("#m-org-memory-search-form", %{"query" => "deployment"}) |> render_submit()
      assert_receive {:memory_search, _args, _ctx}

      view |> element(~s(button[data-facet-corpus="journal"])) |> render_click()
      assert_receive {:memory_search, args, _ctx}
      assert args["query"] == "deployment"
      assert args["source"] == "journal"
    end
  end

  describe "desktop guard" do
    test "the desktop three-pane grid renders and no mobile markup leaks into it", %{conn: conn} do
      {:ok, view, _html} = mount_page(conn)

      # desktop grid present (data-view-mode lives only on the hidden lg:grid)
      assert has_element?(view, ~s([data-view-mode]))
      assert has_element?(view, ~s([data-role="tab-strip"]))
      assert has_element?(view, ~s([data-role="backlinks"]))

      # NONE of the lg:hidden mobile markup appears inside the desktop grid
      refute has_element?(view, ~s([data-view-mode] [data-role="mobile-shell"]))
      refute has_element?(view, ~s([data-view-mode] [data-role="mobile-app-bar"]))
      refute has_element?(view, ~s([data-view-mode] [data-role="mobile-path-chip"]))
      refute has_element?(view, ~s([data-view-mode] #org-memory-tree-drawer))
      refute has_element?(view, ~s([data-view-mode] [data-role="mobile-details"]))
    end
  end
end
