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

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Memory.MemoryProposal
  alias Platform.Memory.Proposals
  alias Platform.MemoryFeedback.Entry, as: FeedbackEntry
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

      # Keyed off the query string so every pre-existing test keeps the
      # healthy envelope untouched (task 01a0941e stage 3).
      case Map.get(args, "query") do
        "degraded-with-hits" -> degraded_with_hits()
        "degraded-no-hits" -> degraded_no_hits()
        _ -> healthy()
      end
    end

    # Degraded WITH surviving hits: no `results` key at all — the hits are
    # reachable only through `partial_results` (stage 1 envelope).
    defp degraded_with_hits do
      {:ok,
       %{
         partial_results: [
           %{
             source: "page",
             id: Ecto.UUID.generate(),
             path: "org/page/identity.md",
             space_id: nil,
             content: "Partial hit from the surviving channel.",
             score: 0.0164,
             semantic_rank: nil,
             lexical_rank: 1,
             authored_by: nil,
             date_or_inserted_at: "2026-06-01T12:00:00Z"
           }
         ],
         retrieval_status: "degraded",
         truncated: true,
         dead_channels: [["semantic", "all"]],
         degraded: %{
           dead_channels: [["semantic", "all"]],
           channels_down: ["semantic"],
           implication: "Semantic recall is missing from these results."
         },
         fusion_constant_k: 60
       }}
    end

    # Degraded with ZERO surviving hits: an error, never an empty list.
    defp degraded_no_hits do
      {:error,
       %{
         error: "memory_search ran degraded: the semantic channel(s) did not answer",
         code: :search_degraded,
         recoverable: true,
         suggestion: "Retry; if it stays degraded, report the absence as unestablished.",
         dead_channels: [["semantic", "all"]]
       }}
    end

    defp healthy do
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
    test "GET /org_memory/org/page/identity.md loads the page directly", %{conn: conn} do
      Repo.delete_all(WikiPage)
      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity Direct\n"})

      conn = authenticated_conn(conn, create_user!())
      {:ok, _view, html} = live(conn, "/org_memory/org/page/identity.md")

      assert html =~ "Identity Direct"
    end
  end

  describe "create panel page-grammar normalization (2026-06-11)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)
      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "user-entered flat key gets the page/ segment inserted after the namespace",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-view-mode] button[phx-click="show_create"])) |> render_click()
      render_click(view, "create_file", %{"file_key" => "org/custom.md"})

      # The page lands on the gate-recognised key; the flat key was
      # never written. The patch + flash surface the normalized key.
      assert %WikiPage{} = Wiki.get_page("org/page/custom.md")
      assert Wiki.get_page("org/custom.md") == nil

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/page/custom.md"
      assert render(view) =~ "Created org/page/custom.md"
      assert has_element?(view, "h1", "org/page/custom.md")
    end

    test "keys already under page/ or journal/ or private/ pass through unchanged",
         %{conn: conn} do
      space_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-view-mode] button[phx-click="show_create"])) |> render_click()
      render_click(view, "create_file", %{"file_key" => "org/page/already.md"})
      assert %WikiPage{} = Wiki.get_page("org/page/already.md")
      assert Wiki.get_page("org/page/page/already.md") == nil

      render_click(view, "create_file", %{
        "file_key" => "space/#{space_id}/private/#{Ecto.UUID.generate()}/scratch.md"
      })

      refute Wiki.list_pages() |> Enum.any?(&String.contains?(&1.file_key, "/page/private/"))
    end

    test "keys outside the namespace grammar are left as-is (domain stays free-form)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-view-mode] button[phx-click="show_create"])) |> render_click()
      render_click(view, "create_file", %{"file_key" => "project/not-a-uuid/notes.md"})

      assert %WikiPage{} = Wiki.get_page("project/not-a-uuid/notes.md")
      assert Wiki.get_page("project/not-a-uuid/page/notes.md") == nil
    end
  end

  describe "namespace tree (stage 3)" do
    # Start from a clean wiki table — migration-seeded org defaults would
    # otherwise blur what the tree is grouping.
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      project_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      # Page-grammar keys (`<ns>/page/<rest>`) — the canonical form
      # since the 2026-06-11 key migration. The tree hides the `page`
      # segment but data-file-key attributes keep the full keys.
      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity Alpha\n"})

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/page/decisions.md", %{content: "# Decisions\n"})

      {:ok, _} =
        Wiki.upsert_page("space/#{space_id}/page/playbook.md", %{content: "# Playbook\n"})

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

      # Top-level namespaces are expanded by default: the org/ leaf
      # (hoisted out of its `page/` folder, full key preserved on the
      # data attribute) and the second-level folders are visible...
      assert has_element?(view, ~s(button[data-file-key="org/page/identity.md"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="project/#{project_id}/"]))
      assert has_element?(view, ~s(button[data-namespace-prefix="space/#{space_id}/"]))

      # The interposed `page` folder itself is never rendered.
      refute has_element?(view, ~s(button[data-namespace-prefix="org/page/"]))

      # ...but deeper folders start collapsed, so their leaves are not.
      refute has_element?(
               view,
               ~s(button[data-file-key="project/#{project_id}/page/decisions.md"])
             )
    end

    test "clicking a tree leaf push-patches to /org_memory/<file_key> and loads the page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view
      |> element(~s([data-view-mode] button[data-file-key="org/page/identity.md"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/page/identity.md"

      # @selected_page drives the main pane: toolbar heading shows the
      # file_key, rendered markdown body shows the page content, and the
      # tree leaf picks up the selected styling.
      assert has_element?(view, "h1", "org/page/identity.md")
      assert render(view) =~ "Identity Alpha"
      assert has_element?(view, ~s(button[data-file-key="org/page/identity.md"].text-primary))
    end

    test "expanding a collapsed deeper folder reveals its leaf, which selects via patch",
         %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      file_key = "project/#{project_id}/page/decisions.md"

      view
      |> element(~s([data-view-mode] button[data-namespace-prefix="project/#{project_id}/"]))
      |> render_click()

      assert has_element?(view, ~s(button[data-file-key="#{file_key}"]))

      view
      |> element(~s([data-view-mode] button[data-file-key="#{file_key}"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/#{file_key}"
      assert has_element?(view, "h1", file_key)
    end
  end

  describe "page viewer wikilinks (stage 4)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n"})

      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{
          content: "# Linker\n\nSee [[org/page/identity.md]] and [[ghost]].\n"
        })

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "wikilink to an existing page renders an <a class=\"wikilink\">", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
      assert render(view) =~ ~s(class="wikilink">org/page/identity.md</a>)
    end

    test "wikilink with no matching page or alias renders a dangling span", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, "span.wikilink-dangling", "ghost")
      refute has_element?(view, ~s(a.wikilink[href="/org_memory/ghost"]))
    end
  end

  describe "basename wikilink resolution (2026-06-11)" do
    # `Wiki.resolve_basename/2` is the LAST fallback in the LiveView's
    # wikilink lookup builder: exact key, then alias, then unique
    # basename. Ambiguous or zero basename matches stay dangling.
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n"})

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "[[identity]] (.md-less) resolves to the unique org/page/identity.md", %{conn: conn} do
      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{content: "See [[identity]].\n"})

      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
      assert render(view) =~ ~s(class="wikilink">identity</a>)
      refute has_element?(view, "span.wikilink-dangling", "identity")
    end

    test "[[identity.md]] (.md-full) resolves to the unique basename match", %{conn: conn} do
      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{content: "See [[identity.md]].\n"})

      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
      assert render(view) =~ ~s(class="wikilink">identity.md</a>)
    end

    test "ambiguous basename (two namespaces share it) stays dangling", %{conn: conn} do
      space_id = Ecto.UUID.generate()

      {:ok, _} =
        Wiki.upsert_page("space/#{space_id}/page/identity.md", %{content: "# Space Identity\n"})

      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{content: "See [[identity]].\n"})

      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, "span.wikilink-dangling", "identity")
      refute has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
    end

    test "exact key takes precedence over a basename collision", %{conn: conn} do
      # A page whose FULL key happens to equal another page's basename
      # form: exact-key resolution wins; basename never runs.
      {:ok, _} = Wiki.upsert_page("identity.md", %{content: "# Root-level page\n"})

      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{content: "See [[identity.md]].\n"})

      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/identity.md"]))
      refute has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
    end

    test "alias takes precedence over basename resolution", %{conn: conn} do
      # Alias ORG_IDENTITY.md → org/page/identity.md, plus a DIFFERENT
      # page whose basename is ORG_IDENTITY — the alias must win.
      page = Wiki.get_page("org/page/identity.md")

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at) " <>
          "VALUES ($1, $2, $3, now()) ON CONFLICT (workspace_id, old_path) DO NOTHING",
        [
          Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000"),
          "ORG_IDENTITY.md",
          Ecto.UUID.dump!(page.id)
        ]
      )

      {:ok, decoy} = Wiki.upsert_page("org/page/decoys/ORG_IDENTITY.md", %{content: "# Decoy\n"})

      {:ok, _} =
        Wiki.upsert_page("org/page/linker.md", %{content: "See [[ORG_IDENTITY.md]].\n"})

      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/linker.md"))

      assert has_element?(view, ~s(a.wikilink[href="/org_memory/org/page/identity.md"]))
      refute has_element?(view, ~s(a.wikilink[href="/org_memory/#{decoy.file_key}"]))
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

      {:ok, page} = Wiki.upsert_page("org/page/identity.md", %{content: content})

      {:ok, conn: authenticated_conn(conn, create_user!()), page: page}
    end

    test "preamble checkbox toggles and round-trips through save", %{conn: conn, page: page} do
      {:ok, view, _html} =
        live(conn, "/org_memory/" <> URI.encode_www_form("org/page/identity.md"))

      view
      |> element(~s([data-view-mode] button[phx-click="start_edit"]))
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
               updated = Wiki.get_page("org/page/identity.md")

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
      {:ok, _} = Wiki.upsert_page("org/page/target.md", %{content: "# Target\n"})

      {:ok, _} =
        Wiki.upsert_page("org/page/source.md", %{
          content: "# Source\n\nLinks to [[org/page/target.md]].\n"
        })

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    test "page with an inbound wikilink lists the source as a clickable backlink",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/page/target.md")

      # The backlink row is a select_page button carrying the source
      # page's file_key (full key in the tooltip, namespace badge
      # alongside).
      assert has_element?(
               view,
               ~s([data-role="backlinks"] button[data-backlink="org/page/source.md"][phx-click="select_page"])
             )

      assert has_element?(
               view,
               ~s(button[data-backlink="org/page/source.md"][title="org/page/source.md"])
             )

      assert view
             |> element(~s(button[data-backlink="org/page/source.md"]))
             |> render() =~ "org"

      refute render(view) =~ "No backlinks yet"
    end

    test "clicking a backlink push-patches to the source page and updates @selected_page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/page/target.md")

      view
      |> element(~s(button[data-backlink="org/page/source.md"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/page/source.md"

      # @selected_page now drives the main pane with the source page.
      assert has_element?(view, "h1", "org/page/source.md")
      assert render(view) =~ "Links to"
    end

    test "page with no inbound links renders the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/page/source.md")

      assert has_element?(view, ~s([data-role="backlinks"]), "No backlinks yet")
      refute has_element?(view, "button[data-backlink]")
    end
  end

  describe "agent read-only gate (stage 4)" do
    test "Agent-shaped current_user fails closed: error flash, no version bump" do
      Repo.delete_all(WikiPage)

      {:ok, page} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n"})

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
      assert %WikiPage{version: 1, content: "# Identity\n"} =
               Wiki.get_page("org/page/identity.md")
    end
  end

  describe "tab strip (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      project_id = Ecto.UUID.generate()

      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity Alpha\n"})

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/page/decisions.md", %{content: "# Decisions\n"})

      {:ok, conn: authenticated_conn(conn, create_user!()), project_id: project_id}
    end

    test "renders the three tabs with Pages selected by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="pages"]), "Pages")
      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="journal"]), "Journal")
      assert has_element?(view, ~s([data-role="tab-strip"] button[data-tab="search"]), "Search")

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="pages"][aria-selected="true"])
             )

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="search"][aria-selected="false"])
             )
    end

    test "tab switches preserve the namespace tree, expansion, and selected page (critical invariant)",
         %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live(conn, "/org_memory/org/page/identity.md")

      # Expand a deeper folder so we can verify expansion survives.
      view
      |> element(~s([data-view-mode] button[data-namespace-prefix="project/#{project_id}/"]))
      |> render_click()

      assert has_element?(
               view,
               ~s(button[data-file-key="project/#{project_id}/page/decisions.md"])
             )

      # :pages → :search → :journal → :pages, no patch in between.
      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

      # Tree (and the expanded deep folder) stay mounted on every tab.
      assert has_element?(view, ~s(button[data-namespace-prefix="org/"]))

      assert has_element?(
               view,
               ~s(button[data-file-key="project/#{project_id}/page/decisions.md"])
             )

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()

      assert has_element?(
               view,
               ~s(button[data-file-key="project/#{project_id}/page/decisions.md"])
             )

      view |> element(~s([data-role="tab-strip"] button[data-tab="pages"])) |> render_click()

      # Same selected page, no re-fetch / no navigation: the viewer
      # heading and the tree's selected styling are intact.
      assert has_element?(view, "h1", "org/page/identity.md")
      assert render(view) =~ "Identity Alpha"
      assert has_element?(view, ~s(button[data-file-key="org/page/identity.md"].text-primary))
    end

    test "right pane renders on :pages only — hidden on :journal and :search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/org/page/identity.md")

      assert has_element?(view, "h2", "Page Details")
      assert has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()
      refute has_element?(view, "h2", "Page Details")
      refute has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()
      refute has_element?(view, "h2", "Page Details")
      refute has_element?(view, ~s([data-role="backlinks"]))

      view |> element(~s([data-role="tab-strip"] button[data-tab="pages"])) |> render_click()
      assert has_element?(view, ~s([data-role="backlinks"]))
    end
  end

  describe "journal pane (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n"})

      user = create_user!()

      {:ok, conn: authenticated_conn(conn, user), user: user}
    end

    test "journal is append-only: renders with no delete affordance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()
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

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()

      view
      |> form("#org-memory-journal-form", %{"content" => "   "})
      |> render_submit()

      assert Journal.list_recent(days_back: 1, limit: 10) == []
    end

    test "append namespace derives from the selected page", %{conn: conn} do
      project_id = Ecto.UUID.generate()

      {:ok, _} =
        Wiki.upsert_page("project/#{project_id}/page/decisions.md", %{content: "# Decisions\n"})

      {:ok, view, _html} = live(conn, "/org_memory/project/#{project_id}/page/decisions.md")

      view |> element(~s([data-role="tab-strip"] button[data-tab="journal"])) |> render_click()

      view
      |> form("#org-memory-journal-form", %{"content" => "Project-scoped note."})
      |> render_submit()

      assert [entry] =
               Journal.list_recent(days_back: 1, limit: 10, namespace: "project/#{project_id}")

      assert entry.content == "Project-scoped note."
      assert entry.metadata["namespace"] == "project/#{project_id}"
    end
  end

  # Degraded-search helpers (task 01a0941e stage 3). ExUnit forbids `defp`
  # inside a `describe` block, so they live at module level.
  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_search(conn) do
    {:ok, view, _html} = live(conn, ~p"/org_memory")
    view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()
    view
  end

  defp submit_search(view, query) do
    view |> form("#org-memory-search-form", %{"query" => query}) |> render_submit()
    view
  end

  describe "search pane (stage 6)" do
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)

      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity Alpha\n"})

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      view
      |> element(~s([data-source-tag="page"] button[phx-click="open_result_page"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode(path) == "/org_memory/org/page/identity.md"

      # Back on the Pages tab with the hit selected (right pane returns).
      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="pages"][aria-selected="true"])
             )

      assert has_element?(view, "h1", "org/page/identity.md")
      assert has_element?(view, ~s([data-role="backlinks"]))
    end

    test "journal hit click-through switches to :journal focused on the hit's date",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "deployment"})
      |> render_submit()

      view
      |> element(~s([data-source-tag="journal"] button[phx-click="open_result_journal"]))
      |> render_click()

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="journal"][aria-selected="true"])
             )

      assert has_element?(view, ~s([data-role="journal-pane"]))
    end

    test "message hit links to the chat space", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

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

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

      view
      |> form("#org-memory-search-form", %{"query" => "   "})
      |> render_submit()

      refute_receive {:memory_search, _args, _context}
      refute has_element?(view, ~s([data-search-result]))
    end

    # ── Degraded search (task 01a0941e stage 3) ───────────────────────────
    #
    # Stage 1 made a degraded `memory_search` unreachable except through a
    # degraded-shaped envelope. This LiveView is the only in-tree consumer
    # whose behaviour changes on that flip, so these four pin the human
    # side of it: partial hits arrive UNREVEALED, the degraded error does
    # not land in the red error line, a healthy search clears the state,
    # and a fresh search re-arms the gate.
    test "a degraded envelope with hits assigns partial hits unrevealed and leaves search_error nil",
         %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-with-hits")

      assigns = assigns_of(view)

      assert length(assigns.search_results) == 1
      assert assigns.search_degraded == true
      assert assigns.search_dead_channels == [["semantic", "all"]]
      assert assigns.search_results_revealed == false
      assert assigns.search_error == nil
      assert assigns.search_performed == true

      refute has_element?(view, ~s([data-role="search-error"]))
    end

    test "a :search_degraded error does not render the red error line", %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-no-hits")

      assigns = assigns_of(view)

      assert assigns.search_results == []
      assert assigns.search_degraded == true
      assert assigns.search_dead_channels == [["semantic", "all"]]
      assert assigns.search_error == nil

      # `--color-error` stays reserved for a genuine search error; a
      # degraded search is a failed measurement, not one.
      refute has_element?(view, ~s([data-role="search-error"]))
    end

    test "a healthy envelope leaves search_degraded false and reveals results", %{conn: conn} do
      view = conn |> open_search() |> submit_search("deployment")

      assigns = assigns_of(view)

      assert assigns.search_degraded == false
      assert assigns.search_dead_channels == []
      assert assigns.search_results_revealed == true
      assert length(assigns.search_results) == 3
    end

    test "a fresh search resets search_results_revealed to false", %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-with-hits")

      render_click(view, "reveal_degraded_results", %{})
      assert assigns_of(view).search_results_revealed == true

      # A second degraded search must re-arm the gate — a reveal that
      # survived into the next search would render the next degraded
      # result set directly, which is this defect one search later.
      submit_search(view, "degraded-with-hits")
      assert assigns_of(view).search_results_revealed == false

      # And the blank-query reset path resets it too.
      render_click(view, "reveal_degraded_results", %{})
      assert assigns_of(view).search_results_revealed == true
      submit_search(view, "   ")
      assert assigns_of(view).search_results_revealed == false
    end

    # ── Stage 4: the rendered degraded surface ──────────────────────────
    #
    # Stage 3 pinned the ASSIGNS. These pin the MARKUP, which is where the
    # guarantee actually lives: a reader cannot be protected by an assign
    # they never see.

    test "the degraded result list does not auto-render", %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-with-hits")

      # Hits exist and are on the socket...
      assert length(assigns_of(view).search_results) == 1

      # ...and are NOT in the DOM, in EITHER viewport. Both panes render
      # into the same document, so a desktop-only gate would leave the
      # mobile list sitting there — visible to a 375px reader and to no
      # desktop screenshot. This is the whole stage: a degraded search
      # renders what did not run, not a list that reads as an answer.
      refute has_element?(view, "[data-search-result]")
      refute has_element?(view, ~s([data-role="mobile-search-result"]))

      assert has_element?(view, ~s([data-role="search-degraded-partial"]))
      assert has_element?(view, ~s([data-role="reveal-partial-results"]))
    end

    test "clicking the reveal control renders the partial hits", %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-with-hits")

      refute has_element?(view, "[data-search-result]")
      refute has_element?(view, ~s([data-role="mobile-search-result"]))

      # Both viewports render into the same DOM (they are hidden from each
      # other by CSS, not by the server), so the bare role selector matches
      # twice. Scope the click to the desktop pane — and then assert the
      # MOBILE list revealed too, which is what proves the reveal is server
      # state shared by both panes rather than a per-pane toggle.
      view
      |> element(~s([data-role="search-pane"] [data-role="reveal-partial-results"]))
      |> render_click()

      assert has_element?(view, "[data-search-result]")
      assert has_element?(view, ~s([data-role="mobile-search-result"]))

      # The reveal control is spent: the sentence stays, the button does not.
      refute has_element?(view, ~s([data-role="reveal-partial-results"]))
      assert has_element?(view, ~s([data-role="search-degraded-partial"]))
    end

    test "the degraded empty state does not contain the string 'No results'", %{conn: conn} do
      view = conn |> open_search() |> submit_search("degraded-no-hits")

      html = render(view)

      assert has_element?(view, ~s([data-role="search-degraded-empty"]))

      # In an empty state the headline is the only line reliably read, so a
      # caveat under a confident headline is still a clean empty result with
      # a footnote. The confident headline must not be on the page at all.
      refute html =~ "No results"
      assert html =~ "absence is not established"
    end

    test "the channel strip renders on a healthy search as well as a degraded one",
         %{conn: conn} do
      view = conn |> open_search() |> submit_search("deployment")

      # Healthy: both chips live. If this ever renders only when degraded,
      # the strip has become a banner and its ABSENCE carries the signal —
      # which is the failure mode the always-present property exists to stop.
      assert has_element?(view, ~s([data-role="channel-strip"]))

      assert has_element?(
               view,
               ~s([data-role="channel-chip"][data-channel="semantic"][data-state="live"])
             )

      assert has_element?(
               view,
               ~s([data-role="channel-chip"][data-channel="lexical"][data-state="live"])
             )

      submit_search(view, "degraded-with-hits")

      assert has_element?(view, ~s([data-role="channel-strip"]))

      assert has_element?(
               view,
               ~s([data-role="channel-chip"][data-channel="semantic"][data-state="down"])
             )

      assert has_element?(
               view,
               ~s([data-role="channel-chip"][data-channel="lexical"][data-state="live"])
             )
    end
  end

  describe "delete via LiveView captures memory feedback (019f6381 validation 2 gap)" do
    # Regression coverage for the stage-2 gap: the `delete_file` event
    # was going through `Wiki.delete_page/2` (plain Repo.delete, no
    # capture). It now routes through `Context.delete_file/2` so the
    # `org_memory_feedback` ledger records the delete with editor_id
    # attribution. See task 019f6381 stage 6 hotfix commit for context.
    setup %{conn: conn} do
      Repo.delete_all(WikiPage)
      Repo.delete_all(FeedbackEntry)

      author = create_user!()
      deleter = create_user!()

      {:ok, page} =
        Wiki.upsert_page("org/page/identity.md", %{
          content: "# Identity\n\nContent that will be deleted.",
          updated_by: author.id
        })

      {:ok, conn: authenticated_conn(conn, deleter), page: page, deleter: deleter, author: author}
    end

    test "confirm+delete removes the page and writes a delete-shaped feedback row",
         %{conn: conn, page: page, deleter: deleter, author: author} do
      baseline = Repo.aggregate(FeedbackEntry, :count, :id)
      {:ok, view, _html} = live(conn, ~p"/org_memory/org/page/identity.md")

      # Trigger the confirm dialog then the delete itself. The UI's
      # confirm button fires phx-click="delete_file" carrying the key.
      render_click(view, "confirm_delete", %{"key" => "org/page/identity.md"})
      render_click(view, "delete_file", %{"key" => "org/page/identity.md"})

      # Underlying WikiPage row is gone.
      assert Wiki.get_page("org/page/identity.md") == nil

      # Exactly one delete-shaped feedback row landed with the current
      # user attributed as the editor and the pre-delete content
      # captured verbatim.
      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline + 1

      row =
        Repo.one(
          from(r in FeedbackEntry,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 1
          )
        )

      assert row.feedback_kind == "delete"
      assert row.path == "org/page/identity.md"
      assert row.namespace == "org_context"
      assert row.original_content == page.content
      assert is_nil(row.edited_content)
      assert row.editor_id == deleter.id
      assert row.original_author_id == author.id
    end

    test "delete of a missing key surfaces an error flash and writes no feedback row",
         %{conn: conn} do
      baseline = Repo.aggregate(FeedbackEntry, :count, :id)
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      html = render_click(view, "delete_file", %{"key" => "org/page/does-not-exist.md"})

      assert html =~ "Failed to delete org/page/does-not-exist.md"
      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline
    end
  end

  # ── Proposals tab (stage 4 — task 019f70e9) ─────────────────────────────

  describe "proposals tab & /memory/proposals route (stage 4)" do
    setup %{conn: conn} do
      Repo.delete_all(MemoryProposal)
      Repo.delete_all(WikiPage)

      {:ok, conn: authenticated_conn(conn, create_user!())}
    end

    defp insert_proposal!(attrs) do
      base_body = Map.get(attrs, :body, "Some proposal body")

      %MemoryProposal{}
      |> MemoryProposal.changeset(
        Map.merge(
          %{
            journal_path: "org/journal/2026-07-17.md",
            block_hash:
              :crypto.hash(:sha256, base_body <> Ecto.UUID.generate())
              |> Base.encode16(case: :lower),
            category: "recurring-theme",
            confidence: "high",
            body: base_body,
            evidence: "Rowan flagged pricing anchors drifting 3x this week."
          },
          Map.drop(attrs, [:body])
        )
      )
      |> Repo.insert!()
    end

    test "GET /memory/proposals mounts OrgMemoryLive with the proposals tab selected",
         %{conn: conn} do
      insert_proposal!(%{category: "recurring-theme", confidence: "high", body: "Body A"})

      {:ok, view, html} = live(conn, "/memory/proposals")

      assert view.module == PlatformWeb.OrgMemoryLive
      # Tab strip shows Proposals as the selected tab.
      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="proposals"][aria-selected="true"])
             )

      # Pane rendered — table + row present.
      assert has_element?(view, ~s([data-role="proposals-pane"]))
      assert has_element?(view, ~s([data-role="proposals-table"]))
      # Right-pane collapsed off :proposals.
      refute has_element?(view, ~s([data-role="backlinks"]))
      # Category + confidence badges surface.
      assert html =~ "recurring-theme"
      assert html =~ "high"
    end

    test "renders 3 pending rows + tab-strip count badge; hides badge at 0",
         %{conn: conn} do
      _p1 = insert_proposal!(%{category: "strategic-insight", confidence: "medium", body: "B1"})
      _p2 = insert_proposal!(%{category: "emerging-risk", confidence: "low", body: "B2"})
      _p3 = insert_proposal!(%{category: "cross-project-pattern", confidence: "high", body: "B3"})

      {:ok, view, html} = live(conn, "/memory/proposals")

      # Three data-proposal-id rows in the stream tbody.
      assert length(Regex.scan(~r/data-proposal-id="/, html)) == 3

      # Count badge shows "3" in the tab strip.
      assert has_element?(view, ~s([data-role="proposals-tab-count"]), "3")

      # Header "N pending" pill visible.
      assert render(view) =~ "3 pending"
    end

    test "approve_proposal → status:approved + row removed from stream",
         %{conn: conn} do
      proposal = insert_proposal!(%{category: "recurring-theme", body: "To approve"})

      {:ok, view, _html} = live(conn, "/memory/proposals")

      assert has_element?(view, ~s([data-proposal-id="#{proposal.id}"]))

      render_click(view, "approve_proposal", %{"id" => proposal.id})

      # DB row flipped.
      assert %MemoryProposal{status: "approved"} = Repo.get(MemoryProposal, proposal.id)

      # Row is gone from the stream (client-side stream_delete drops the node).
      html = render(view)
      refute html =~ ~s(data-proposal-id="#{proposal.id}")

      # Flash confirms.
      assert html =~ "Approved"
    end

    test "reject_proposal → status:rejected + feedback captured",
         %{conn: conn} do
      proposal = insert_proposal!(%{category: "unresolved-question", body: "To reject"})

      {:ok, view, _html} = live(conn, "/memory/proposals")

      # Open the inline reject form.
      render_click(view, "show_reject_form", %{"id" => proposal.id})
      assert has_element?(view, ~s([data-role="reject-form-row"]))

      # The id travels in a hidden input named `_id`, NOT `id` — an input named
      # `id` overrides the DOM id of its own form element (LiveView warns about
      # it at compile time). Assert the wire key rather than supplying it here,
      # so the proposal can only be resolved by the value the FORM rendered.
      assert has_element?(
               view,
               ~s(#proposal-reject-form-#{proposal.id} input[type="hidden"][name="_id"][value="#{proposal.id}"])
             )

      refute has_element?(
               view,
               ~s(#proposal-reject-form-#{proposal.id} input[name="id"])
             )

      # Submit the form with feedback text only; the id comes off the hidden
      # input the template rendered.
      view
      |> form("#proposal-reject-form-#{proposal.id}", %{
        "feedback" => "Already captured in org/page/pricing.md — not novel."
      })
      |> render_submit()

      row = Repo.get(MemoryProposal, proposal.id)
      assert row.status == "rejected"
      assert row.feedback == "Already captured in org/page/pricing.md — not novel."

      # Row dropped from stream + form collapsed.
      html = render(view)
      refute html =~ ~s(data-proposal-id="#{proposal.id}")
      refute html =~ ~s(id="proposal-reject-form-#{proposal.id}")
    end

    test "cancel_reject collapses the inline expansion row without touching DB",
         %{conn: conn} do
      proposal = insert_proposal!(%{body: "To keep pending"})

      {:ok, view, _html} = live(conn, "/memory/proposals")

      render_click(view, "show_reject_form", %{"id" => proposal.id})
      assert has_element?(view, ~s([data-role="reject-form-row"]))

      render_click(view, "cancel_reject", %{"id" => proposal.id})
      refute has_element?(view, ~s([data-role="reject-form-row"]))

      # Row still in the stream + still pending in DB.
      assert has_element?(view, ~s([data-proposal-id="#{proposal.id}"]))
      assert %MemoryProposal{status: "pending"} = Repo.get(MemoryProposal, proposal.id)
    end

    test "expired proposals do not appear in the list", %{conn: conn} do
      _fresh = insert_proposal!(%{evidence: "Fresh-evidence-marker", body: "Fresh"})

      # Insert an expired one (expires_at in the past). Evidence
      # differs from the fresh row so we can test presence/absence in
      # the rendered HTML (evidence IS surfaced in the table; body is
      # not — body promotes to page content in stage 8).
      _expired =
        insert_proposal!(%{
          evidence: "Stale-evidence-marker",
          body: "Stale",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, _view, html} = live(conn, "/memory/proposals")

      assert html =~ "Fresh-evidence-marker"
      refute html =~ "Stale-evidence-marker"

      # Sanity: `list_pending/1` agrees (the LiveView query source).
      assert [%{body: "Fresh"}] = Proposals.list_pending(workspace_id: nil)
    end

    test "empty pending state renders the friendly card + no count badge",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/proposals")

      assert has_element?(view, ~s([data-role="proposals-empty-state"]))
      # The apostrophe HTML-encodes to `&#39;` so we match on the
      # apostrophe-free suffix.
      assert render(view) =~ "dreaming is quiet"

      # No count badge in the tab strip when count == 0.
      refute has_element?(view, ~s([data-role="proposals-tab-count"]))
      # No table rendered at all.
      refute has_element?(view, ~s([data-role="proposals-table"]))
    end

    test "evidence column has the truncate class and title fallback for hover-reveal",
         %{conn: conn} do
      long_evidence =
        "Very long evidence: Rowan noted three times this week that the pricing anchors keep " <>
          "drifting between quotes, causing SXI members to ask for clarification. Similar drift " <>
          "observed on the Orion proposal last month."

      insert_proposal!(%{evidence: long_evidence, body: "Long-evidence proposal"})

      {:ok, view, html} = live(conn, "/memory/proposals")

      # Evidence cell has truncate class so mobile viewports collapse it.
      assert has_element?(view, ~s(td[data-role="evidence-cell"].truncate))
      # And the full text is preserved in the title attribute for hover reveal.
      assert html =~ Phoenix.HTML.html_escape(long_evidence) |> Phoenix.HTML.safe_to_string()
    end

    test "switch_tab preserves the tree + selection when landing on :proposals",
         %{conn: conn} do
      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n"})
      insert_proposal!(%{body: "Toggleable"})

      {:ok, view, _html} = live(conn, "/org_memory/org/page/identity.md")

      view |> element(~s([data-role="tab-strip"] button[data-tab="proposals"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="proposals"][aria-selected="true"])
             )

      # Tree survives the tab switch.
      assert has_element?(view, ~s(button[data-namespace-prefix="org/"]))

      # Return to pages: selection is intact, no navigation happened.
      view |> element(~s([data-role="tab-strip"] button[data-tab="pages"])) |> render_click()
      assert has_element?(view, "h1", "org/page/identity.md")
    end
  end
end
