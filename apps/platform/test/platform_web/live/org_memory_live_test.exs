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

  This file is the home for all subsequent T7 LiveView tests (right
  pane, top-bar tabs).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

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
end
