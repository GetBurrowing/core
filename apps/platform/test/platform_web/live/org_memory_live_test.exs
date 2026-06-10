defmodule PlatformWeb.OrgMemoryLiveTest do
  @moduledoc """
  T7 stages 2–4 (task 019e41da-3610-7972-8573-54121ea1f3f5) — verifies:

    * `GET /org_memory` mounts `PlatformWeb.OrgMemoryLive`.
    * `GET /org-context` returns a 301 redirect to `/org_memory`.
    * `GET /org-context/:file_key` returns a 301 redirect to
      `/org_memory/:file_key`, preserving the deep-link segment.
    * Stage 3: the namespace tree renders all top-level namespaces
      (`org/`, `project/<uuid>/`, `space/<uuid>/`) grouped from
      `Wiki.list_pages/1`, and clicking a leaf push-patches to
      `/org_memory/<file_key>` and loads the page into the main pane.
    * Stage 4: wikilink rendering in the page viewer (resolved `<a
      class="wikilink">`, dangling `<span class="wikilink-dangling">`),
      the frontmatter editor's `preamble` checkbox round-trip, and the
      agent read-only gate on `"save_page"`.
    * Stage 5: the right pane's backlinks list (entries from
      `Wiki.backlinks/2` over the `org_wiki_links` rows materialized by
      `Wiki.upsert_page/3`, clickable via `"select_page"`) and its
      "No backlinks yet" empty state.
    * Stage 6: the top-bar tab strip (Pages / Journal / Search) — tab
      switches preserve the tree + selection (the critical invariant),
      the right pane hides off `:pages`, the journal pane's append-only
      contract (form creates a `WikiJournalEntry`, no delete
      affordances), and the search pane's dispatch through the
      `:org_memory_tool_surface` seam (args / context shape + rendered
      source tags + click-throughs).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @stub_space_id "0196b9a1-0000-7000-8000-000000000abc"

  defmodule StubToolSurface do
    @moduledoc false
    # Recorder stub for the :org_memory_tool_surface seam — records the
    # exact args/context the LiveView dispatched (sent to the test pid
    # registered under :org_memory_tool_surface_test_pid) and returns a
    # canned three-corpus envelope shaped like
    # `Platform.Org.Wiki.Search.search/2`.
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
             path: "org/identity.md",
             space_id: nil,
             content: "Deployment runbook lives in the identity page.",
             score: 0.0328,
             semantic_rank: 1,
             lexical_rank: 2,
             authored_by: nil,
             date_or_inserted_at: "2026-06-01T12:00:00Z"
           },
           %{
             source: "journal",
             id: Ecto.UUID.generate(),
             path: "org/journal/2026-06-08.md",
             space_id: nil,
             content: "Deployed v2 to staging.",
             score: 0.0164,
             semantic_rank: nil,
             lexical_rank: 1,
             authored_by: nil,
             date_or_inserted_at: "2026-06-08"
           },
           %{
             source: "message",
             id: Ecto.UUID.generate(),
             path: nil,
             space_id: "0196b9a1-0000-7000-8000-000000000abc",
             content: "deployment failed on node 2",
             score: 0.0161,
             semantic_rank: 2,
             lexical_rank: nil,
             authored_by: nil,
             date_or_inserted_at: "2026-06-07T09:30:00Z"
           }
         ],
         fusion_constant_k: 60,
         truncated: false
       }}
    end
  end

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "org-memory-#{n}@example.com",
          name: "Org Memory Test #{n}",
          oidc_sub: "oidc-org-memory-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  describe "GET /org_memory" do
    test "renders 200 and mounts OrgMemoryLive", %{conn: conn} do
      user = create_user!()

      {:ok, view, html} = conn |> authenticated_conn(user) |> live(~p"/org_memory")

      # The LV mounted — confirm it's the OrgMemoryLive module and the
      # page chrome rendered.
      assert view.module == PlatformWeb.OrgMemoryLive
      # The renamed user-visible heading appears in the empty main pane
      # (no page selected on first mount).
      assert html =~ "Org Memory"
    end
  end

  describe "GET /org-context (legacy path) 301 redirects" do
    test "/org-context responds 301 with location: /org_memory", %{conn: conn} do
      conn = get(conn, "/org-context")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/org_memory"]
    end

    test "/org-context/:file_key responds 301 with the file_key preserved", %{conn: conn} do
      conn = get(conn, "/org-context/ORG_IDENTITY.md")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/org_memory/ORG_IDENTITY.md"]
    end

    test "/org-context deep link with a path-style (multi-segment) file_key is preserved",
         %{conn: conn} do
      conn = get(conn, "/org-context/org/identity.md")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/org_memory/org/identity.md"]
    end
  end

  describe "glob route: path-style file_keys (multi-segment)" do
    test "GET /org_memory/org/identity.md loads the page directly", %{conn: conn} do
      Repo.delete_all(WikiPage)
      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity Direct\n"})

      conn = authenticated_conn(conn, create_user!())
      {:ok, _view, html} = live(conn, "/org_memory/org/identity.md")

      assert html =~ "Identity Direct"
    end
  end

  describe "namespace tree (stage 3)" do
    # Start from a clean wiki table — migration-seeded org defaults would
    # otherwise blur what the tree is grouping.
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      project_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity Alpha\n"})

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/decisions.md", %{content: "# Decisions\n"})

      {:ok, _} = Wiki.upsert_page("space/#{space_id}/playbook.md", %{content: "# Playbook\n"})

      conn = authenticated_conn(conn, create_user!())

      {:ok, conn: conn, project_id: project_id, space_id: space_id}
    end

    test "renders all three top-level namespaces", %{
      conn: conn,
      project_id: project_id,
      space_id: space_id
    } do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      assert has_element?(view, ~s(button[data-namespace-prefix="org/"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="project/"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="space/"]))

      # Top-level namespaces are expanded by default: the org/ leaf and
      # the second-level folders are visible...
      assert has_element?(view, ~s(button[data-file-key="org/identity.md"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="project/#{project_id}/"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="space/#{space_id}/"]))

      # ...but deeper folders start collapsed, so their leaves are not.
      refute has_element?(
               view,
               ~s(button[data-file-key="project/#{project_id}/decisions.md"])
             )
    end

    test "clicking a tree leaf push-patches to /org_memory/<file_key> and loads the page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view
      |> element(~s(button[data-file-key="org/identity.md"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/identity.md"

      # @selected_page drives the main pane: toolbar heading shows the
      # file_key, rendered markdown body shows the page content, and the
      # tree leaf picks up the selected styling.
      assert has_element?(view, "h1", "org/identity.md")
      assert render(view) =~ "Identity Alpha"
      assert has_element?(view, ~s(button[data-file-key="org/identity.md"].text-primary))
    end

    test "expanding a collapsed deeper folder reveals its leaf, which selects via patch",
         %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      file_key = "project/#{project_id}/decisions.md"

      view
      |> element(~s(button[data-namespace-prefix="project/#{project_id}/"]))
      |> render_click()

      assert has_element?(view, ~s(button[data-file-key="#{file_key}"]))

      view
      |> element(~s(button[data-file-key="#{file_key}"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/#{file_key}"
      assert has_element?(view, "h1", file_key)
    end
  end

  describe "page viewer wikilinks (stage 4)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity\n"})

      {:ok, _} =
        Wiki.upsert_page("org/linker.md", %{
          content: "# Linker\n\nSee [[org/identity.md]] and [[ghost]].\n"
        })

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "wikilink to an existing page renders an <a class=\"wikilink\">", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> URI.encode_www_form("org/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/org/identity.md"]))
      assert render(view) =~ ~s(class="wikilink">org/identity.md</a>)
    end

    test "wikilink with no matching page or alias renders a dangling span", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> URI.encode_www_form("org/linker.md"))

      assert has_element?(view, "span.wikilink-dangling", "ghost")
      refute has_element?(view, ~s(a.wikilink[href="/org_memory/ghost"]))
    end
  end

  describe "frontmatter editor (stage 4)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      content = """
      ---
      preamble: false
      title: "Org identity"
      ---
      # Identity

      Body text.
      """

      {:ok, page} = Wiki.upsert_page("org/identity.md", %{content: content})

      {:ok, conn: authenticated_conn(conn, create_user!()), page: page}
    end

    test "preamble checkbox toggles and round-trips through save", %{conn: conn, page: page} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> URI.encode_www_form("org/identity.md"))

      view
      |> element(~s(button[phx-click="start_edit"]))
      |> render_click()

      # The flat frontmatter renders as a form with a preamble checkbox
      # (unchecked — the page starts at `preamble: false`) and a text
      # row for the other scalar key.
      assert has_element?(
               view,
               ~s(#org-memory-frontmatter-form input[type="checkbox"][name="frontmatter[preamble]"])
             )

      refute has_element?(
               view,
               ~s(#org-memory-frontmatter-form input[type="checkbox"][name="frontmatter[preamble]"][checked])
             )

      assert has_element?(
               view,
               ~s(#org-memory-frontmatter-form input[name="frontmatter[title]"])
             )

      # Toggle the checkbox on and save via the form's phx-submit.
      view
      |> form("#org-memory-frontmatter-form", %{
        "frontmatter" => %{"preamble" => "true", "title" => "Org identity"}
      })
      |> render_submit()

      # Round trip: the rebuilt YAML block parsed back into a boolean
      # frontmatter value, the body survived, and the version advanced.
      assert %WikiPage{frontmatter: %{"preamble" => true} = frontmatter, content: content} =
               updated = Wiki.get_page("org/identity.md")

      assert frontmatter["title"] == "Org identity"
      assert updated.version == page.version + 1
      assert content =~ "# Identity"
      assert content =~ "Body text."
    end
  end

  describe "right pane backlinks (stage 5)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      # `Wiki.upsert_page/3` parses wikilinks out of the content and
      # materializes them into `org_wiki_links` (source_id +
      # target_path), which is what `Wiki.backlinks/2` queries — so
      # seeding the backlink is just upserting a page whose body
      # carries a `[[...]]` link to the target's file_key.
      {:ok, _} = Wiki.upsert_page("org/target.md", %{content: "# Target\n"})

      {:ok, _} =
        Wiki.upsert_page("org/source.md", %{
          content: "# Source\n\nLinks to [[org/target.md]].\n"
        })

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "page with an inbound wikilink lists the source as a clickable backlink",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/target.md")

      # The backlink row is a select_page button carrying the source
      # page's file_key (full key in the tooltip, namespace badge
      # alongside).
      assert has_element?(
               view,
               ~s([data-role="backlinks"] button[data-backlink="org/source.md"][phx-click="select_page"])
             )

      assert has_element?(
               view,
               ~s(button[data-backlink="org/source.md"][title="org/source.md"])
             )

      assert view
             |> element(~s(button[data-backlink="org/source.md"]))
             |> render() =~ "org"

      refute render(view) =~ "No backlinks yet"
    end

    test "clicking a backlink push-patches to the source page and updates @selected_page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/target.md")

      view
      |> element(~s(button[data-backlink="org/source.md"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/source.md"

      # @selected_page now drives the main pane with the source page.
      assert has_element?(view, "h1", "org/source.md")
      assert render(view) =~ "Links to"
    end

    test "page with no inbound links renders the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/source.md")

      assert has_element?(view, ~s([data-role="backlinks"]), "No backlinks yet")
      refute has_element?(view, "button[data-backlink]")
    end
  end

  describe "agent read-only gate (stage 4)" do
    test "Agent-shaped current_user fails closed: error flash, no version bump" do
      Repo.delete_all(WikiPage)

      {:ok, page} = Wiki.upsert_page("org/identity.md", %{content: "# Identity\n"})

      agent = %Agent{id: Ecto.UUID.generate(), slug: "historian", name: "Historian"}

      # The gate fires on `current_user` shape before any domain call,
      # so the handler is exercised directly with an Agent-shaped
      # socket (the browser session path can only produce User-shaped
      # principals, by construction — design lock §6).
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_user_record: agent,
          current_user_id: agent.id,
          selected_page: page,
          editor_content: page.content,
          fm_form: nil
        }
      }

      {:noreply, socket} =
        PlatformWeb.OrgMemoryLive.handle_event(
          "save_page",
          %{"content" => "# Hijacked by agent\n"},
          socket
        )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Agents must propose changes via memory_create. UI editing is for humans only."

      # upsert_page was never called: version and content are untouched.
      assert %WikiPage{version: 1, content: "# Identity\n"} = Wiki.get_page("org/identity.md")
    end
  end

  describe "tab strip (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      project_id = Ecto.UUID.generate()

      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity Alpha\n"})

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/decisions.md", %{content: "# Decisions\n"})

      {:ok, conn: authenticated_conn(conn, create_user!()), project_id: project_id}
    end

    test "renders the three tabs with Pages selected by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="pages"]), "Pages")
      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="journal"]), "Journal")
      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="search"]), "Search")
      assert has_element?(view, ~s(button[data-tab="pages"][aria-selected="true"]))
      assert has_element?(view, ~s(button[data-tab="search"][aria-selected="false"]))
    end

    test "tab switches preserve the namespace tree, expansion, and selected page (critical invariant)",
         %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live(conn, "/org_memory/org/identity.md")

      # Expand a deeper folder so we can verify expansion survives.
      view
      |> element(~s(button[data-namespace-prefix="project/#{project_id}/"]))
      |> render_click()

      assert has_element?(view, ~s(button[data-file-key="project/#{project_id}/decisions.md"]))

      # :pages → :search → :journal → :pages, no patch in between.
      view |> element(~s(button[data-tab="search"])) |> render_click()

      # Tree (and the expanded deep folder) stay mounted on every tab.
      assert has_element?(view, ~s(button[data-namespace-prefix="org/"]))
      assert has_element?(view, ~s(button[data-file-key="project/#{project_id}/decisions.md"]))

      view |> element(~s(button[data-tab="journal"])) |> render_click()
      assert has_element?(view, ~s(button[data-file-key="project/#{project_id}/decisions.md"]))

      view |> element(~s(button[data-tab="pages"])) |> render_click()

      # Same selected page, no re-fetch / no navigation: the viewer
      # heading and the tree's selected styling are intact.
      assert has_element?(view, "h1", "org/identity.md")
      assert render(view) =~ "Identity Alpha"
      assert has_element?(view, ~s(button[data-file-key="org/identity.md"].text-primary))
    end

    test "right pane renders on :pages only — hidden on :journal and :search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/identity.md")

      assert has_element?(view, "h2", "Page Details")
      assert has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s(button[data-tab="journal"])) |> render_click()
      refute has_element?(view, "h2", "Page Details")
      refute has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s(button[data-tab="search"])) |> render_click()
      refute has_element?(view, "h2", "Page Details")
      refute has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s(button[data-tab="pages"])) |> render_click()
      assert has_element?(view, ~s([data-role="backlinks"]))
    end
  end

  describe "journal pane (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity\n"})

      user = create_user!()

      {:ok, conn: authenticated_conn(conn, user), user: user}
    end

    test "journal is append-only: renders with no delete affordance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="journal"])) |> render_click()
      html = render(view)

      assert html =~ "Journal"
      assert has_element?(view, ~s([data-role="journal-pane"] form#org-memory-journal-form))

      # The append-only contract: no journal-delete affordance anywhere.
      refute html =~ ~s(data-action="delete-journal")
      refute html =~ ~s(phx-click="delete_journal")
    end

    test "append form submission creates a WikiJournalEntry row and re-renders the feed",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="journal"])) |> render_click()

      view
      |> form("#org-memory-journal-form", %{"content" => "Shipped the wiki tabs."})
      |> render_submit()

      # Row exists, attributed to the current user, namespace-tagged
      # with the journal default (no page selected → "org").
      assert [entry] =
               Journal.list_recent(days_back: 1, limit: 10)
               |> Enum.filter(&(&1.content == "Shipped the wiki tabs."))

      assert entry.date == Date.utc_today()
      assert entry.authored_by == user.id
      assert entry.metadata["namespace"] == "org"

      # The feed re-rendered with the new entry under today's group.
      assert has_element?(view, ~s(#journal-day-#{Date.to_iso8601(Date.utc_today())}))
      assert render(view) =~ "Shipped the wiki tabs."
    end

    test "blank submission appends nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="journal"])) |> render_click()

      view
      |> form("#org-memory-journal-form", %{"content" => "   "})
      |> render_submit()

      assert Journal.list_recent(days_back: 1, limit: 10) == []
    end

    test "append namespace derives from the selected page", %{conn: conn} do
      project_id = Ecto.UUID.generate()

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/decisions.md", %{content: "# Decisions\n"})

      {:ok, view, _html} = live(conn, "/org_memory/project/#{project_id}/decisions.md")

      view |> element(~s(button[data-tab="journal"])) |> render_click()

      view
      |> form("#org-memory-journal-form", %{"content" => "Project-scoped note."})
      |> render_submit()

      assert [entry] =
               Journal.list_recent(days_back: 1, limit: 10, namespace: "project/#{project_id}")

      assert entry.content == "Project-scoped note."
      assert entry.metadata["namespace"] == "project/#{project_id}"
    end
  end

  describe "search pane (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/identity.md", %{content: "# Identity Alpha\n"})

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

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "submit dispatches memory_search through the tool surface with the right args",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{
        "query" => "deployment",
        "corpus" => "all",
        "namespace" => "all"
      })
      |> render_submit()

      # "all" filters are dropped — only the query reaches the tool;
      # the context is the anonymous human/UI caller shape.
      assert_receive {:memory_search, args, context}
      assert args == %{"query" => "deployment"}
      assert context == %{agent: nil}
    end

    test "corpus + namespace filters pass through as source/namespace args", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{
        "query" => "deployment",
        "corpus" => "journal",
        "namespace" => "org"
      })
      |> render_submit()

      assert_receive {:memory_search, args, _context}
      assert args == %{"query" => "deployment", "source" => "journal", "namespace" => "org"}
    end

    test "results render with visible source tags, score, and rank info", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      assert has_element?(view, ~s([data-search-result][data-source-tag="page"]), "PAGE")
      assert has_element?(view, ~s([data-search-result][data-source-tag="journal"]), "JOURNAL")
      assert has_element?(view, ~s([data-search-result][data-source-tag="message"]), "MESSAGE")

      html = render(view)
      assert html =~ "0.0328"
      assert html =~ "sem #1"
      assert html =~ "lex #2"
    end

    test "page hit click-through patches back to :pages on the hit's path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      view
      |> element(~s([data-source-tag="page"] button[phx-click="open_result_page"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/identity.md"

      # Back on the Pages tab with the hit selected (right pane returns).
      assert has_element?(view, ~s(button[data-tab="pages"][aria-selected="true"]))
      assert has_element?(view, "h1", "org/identity.md")
      assert has_element?(view, ~s([data-role="backlinks"]))
    end

    test "journal hit click-through switches to :journal focused on the hit's date",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      view
      |> element(~s([data-source-tag="journal"] button[phx-click="open_result_journal"]))
      |> render_click()

      assert has_element?(view, ~s(button[data-tab="journal"][aria-selected="true"]))
      assert has_element?(view, ~s([data-role="journal-pane"]))
    end

    test "message hit links to the chat space", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      assert has_element?(
               view,
               ~s([data-source-tag="message"] a[href="/chat/#{@stub_space_id}"])
             )
    end

    test "blank query clears results without dispatching", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s(button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "   "})
      |> render_submit()

      refute_receive {:memory_search, _args, _context}
      refute has_element?(view, ~s([data-search-result]))
    end
  end
end
