defmodule PlatformWeb.OrgMemoryLiveT7E2ETest do
  @moduledoc """
  T7 stage 8 (task 019e41da-3610-7972-8573-54121ea1f3f5) — faithful
  replays of the five task-level e2e behavioral scripts against
  `PlatformWeb.OrgMemoryLive`:

    1. agent read-only gate (save fails closed before the domain layer)
    2. journal no-delete (append-only surface, no delete route)
    3. wikilink rendering (resolved anchor vs dangling span + CSS rule)
    4. preamble round-trip (checkbox → frontmatter → Context.build_preamble)
    5. search via the REAL tool surface (recorder delegating to
       `Platform.Federation.ToolSurface`)

  Where a script step can't be replayed literally under the
  LiveViewTest harness, the closest faithful equivalent is asserted and
  the delta documented inline.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiPage
  alias Platform.Repo

  defmodule RecordingToolSurface do
    @moduledoc false
    # Script 5 seam: records the exact (tool, args, context) the
    # LiveView dispatched, then DELEGATES to the real
    # `Platform.Federation.ToolSurface` — the real gate + Wiki.Search
    # code path runs; the recorder only makes the invocation assertable.
    def execute(tool, args, context) do
      if pid = Application.get_env(:platform, :t7_e2e_tool_surface_pid) do
        send(pid, {:tool_surface_call, tool, args, context})
      end

      Platform.Federation.ToolSurface.execute(tool, args, context)
    end
  end

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "t7-e2e-#{n}@example.com",
          name: "T7 E2E Test #{n}",
          oidc_sub: "oidc-t7-e2e-#{n}"
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

  # ── Script 1 ─────────────────────────────────────────────────────────────

  @tag :t7_e2e
  test "e2e 1: agent read-only gate — save fails closed before the domain layer",
       %{conn: conn} do
    Repo.delete_all(WikiPage)

    {:ok, page} =
      Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n\nWe are Acme.\n"})

    assert page.version == 1

    # Script navigation steps, exercised with a real human User first:
    # mount → /org_memory/org/page/identity.md → click Edit → modify the
    # textarea. DELTA from the literal script: a browser-session mount
    # can only mint User-shaped principals (by construction — design
    # lock §6), so the *agent-driven* part of the script is replayed
    # below by driving `handle_event/3` directly with an Agent-shaped
    # socket, exactly like the stage-4 gate test. The human flow here
    # deliberately stops short of saving so the page stays at v1.
    conn = authenticated_conn(conn, create_user!())
    {:ok, view, _html} = live(conn, "/org_memory/org/page/identity.md")

    view
    |> element(~s([data-view-mode] button[phx-click="start_edit"]))
    |> render_click()

    # Modify the textarea contents — the MarkdownEditor hook pushes
    # "update_preview" with the draft content as the user types.
    view
    |> element("#org-memory-editor")
    |> render_hook("update_preview", %{"content" => "# Identity (edited draft)\n"})

    assert render(view) =~ "Editing org/page/identity.md"

    # Agent-driven save: submit the save form (phx-submit="save_page")
    # as an %Platform.Agents.Agent{} principal via handle_event/3.
    agent = %Agent{id: Ecto.UUID.generate(), slug: "historian", name: "Historian"}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user_record: agent,
        current_user_id: agent.id,
        selected_page: Wiki.get_page("org/page/identity.md"),
        editor_content: "# Hijacked by agent\n",
        fm_form: nil
      }
    }

    {:noreply, socket} =
      PlatformWeb.OrgMemoryLive.handle_event(
        "save_page",
        %{"content" => "# Hijacked by agent\n"},
        socket
      )

    # Flash error matches the script regex.
    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~
             ~r/Agents must propose changes via memory_create/

    # The UI failed closed BEFORE reaching the domain layer: version
    # still 1, content untouched.
    assert %WikiPage{version: 1, content: "# Identity\n\nWe are Acme.\n"} =
             Wiki.get_page("org/page/identity.md")
  end

  # ── Script 2 ─────────────────────────────────────────────────────────────

  @tag :t7_e2e
  test "e2e 2: journal no-delete — append form is the only interaction surface",
       %{conn: conn} do
    Repo.delete_all(WikiPage)

    # Three entries with distinct content. Default namespace "org" —
    # with no page selected the journal pane's feed loads exactly that
    # namespace (see `OrgMemoryLive.journal_namespace/1`), so all three
    # must appear.
    {:ok, entry1} =
      Journal.append(%{content: "First: standup notes captured.", date: Date.utc_today()})

    {:ok, _entry2} =
      Journal.append(%{content: "Second: retro follow-ups filed.", date: Date.utc_today()})

    {:ok, _entry3} =
      Journal.append(%{content: "Third: deploy checklist drafted.", date: Date.utc_today()})

    user = create_user!()
    {:ok, view, _html} = conn |> authenticated_conn(user) |> live(~p"/org_memory")

    view |> element(~s(button[data-tab="journal"])) |> render_click()

    pane_html = view |> element(~s([data-role="journal-pane"])) |> render()

    # All three seeded entries render in the feed.
    assert pane_html =~ "First: standup notes captured."
    assert pane_html =~ "Second: retro follow-ups filed."
    assert pane_html =~ "Third: deploy checklist drafted."

    # No delete affordance of any shape in the journal pane DOM.
    refute pane_html =~ "delete_journal"
    refute pane_html =~ ~s(data-action="delete")
    refute pane_html =~ "hero-trash"

    # The append form is the only journal interaction surface: exactly
    # one form (the append form) and exactly one button (its submit).
    assert [{"form", form_attrs, _}] =
             pane_html |> LazyHTML.from_fragment() |> LazyHTML.query("form") |> LazyHTML.to_tree()

    assert {"id", "org-memory-journal-form"} in form_attrs
    assert {"phx-submit", "append_journal"} in form_attrs

    assert [{"button", button_attrs, _}] =
             pane_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("button")
             |> LazyHTML.to_tree()

    assert {"type", "submit"} in button_attrs

    # HTTP DELETE against a journal-shaped route: no such route exists
    # anywhere in the router (the /org_memory live routes are GET-only).
    # DELTA from the literal script: under this endpoint setup the
    # no-route 404 is rendered as a plain "Not Found" response rather
    # than re-raised (so neither `assert_error_sent` nor a rescued
    # Phoenix.Router.NoRouteError fires) — the response status + body
    # are asserted directly instead.
    conn =
      Phoenix.ConnTest.build_conn()
      |> authenticated_conn(user)
      |> delete("/org_memory/journal/#{entry1.id}")

    assert conn.status == 404
    assert conn.resp_body =~ "Not Found"
  end

  # ── Script 3 ─────────────────────────────────────────────────────────────

  @tag :t7_e2e
  test "e2e 3: wikilink rendering — resolved anchor vs dangling span", %{conn: conn} do
    Repo.delete_all(WikiPage)

    {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "# Identity\n\nWe are Acme."})

    # 2026-06-11 amendment: the script's original [[identity]] form is
    # now replayable LITERALLY — basename resolution landed in the
    # domain (`Wiki.resolve_basename/2`, unique-basename fallback after
    # exact key + alias), so the earlier delta (full file_key form) is
    # retired along with the flat-key seeds (page grammar since the
    # 20260611120000 key migration).
    {:ok, _} =
      Wiki.upsert_page("org/page/notes.md", %{
        content: "Read [[identity]] first; then check [[nonexistent-page]] for context."
      })

    # Nothing seeded at org/page/nonexistent-page.md.
    assert Wiki.get_page("org/page/nonexistent-page.md") == nil

    conn = authenticated_conn(conn, create_user!())
    {:ok, view, _html} = live(conn, "/org_memory/org/page/notes.md")

    # Resolved token: [[identity]] basename-resolves to the unique
    # org/page/identity.md → <a class="wikilink">.
    assert has_element?(
             view,
             ~s(a.wikilink[href="/org_memory/org/page/identity.md"]),
             "identity"
           )

    # Unresolved token: dangling span with the title tooltip.
    assert has_element?(
             view,
             ~s(span.wikilink-dangling[title="Dangling — page does not exist"]),
             "nonexistent-page"
           )

    refute has_element?(view, ~s(a.wikilink[href="/org_memory/nonexistent-page"]))

    # The CSS rule for .wikilink-dangling exists in assets/css/app.css.
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    assert css =~ ".wikilink-dangling {"
  end

  # ── Script 4 ─────────────────────────────────────────────────────────────

  @tag :t7_e2e
  test "e2e 4: preamble round-trip — checkbox toggle reaches build_preamble", %{conn: conn} do
    Repo.delete_all(WikiPage)

    {:ok, page} =
      Wiki.upsert_page("org/page/playbook.md", %{
        content: "---\npreamble: false\n---\n# Playbook\n\nBody.\n"
      })

    assert page.version == 1

    # Before the toggle the page is not preamble-eligible.
    refute Map.has_key?(Platform.Org.Wiki.Context.build_preamble([]), "org/page/playbook.md")

    conn = authenticated_conn(conn, create_user!())
    {:ok, view, _html} = live(conn, "/org_memory/org/page/playbook.md")

    view |> element(~s([data-view-mode] button[phx-click="start_edit"])) |> render_click()

    # Checkbox starts unticked (preamble: false).
    assert has_element?(
             view,
             ~s(#org-memory-frontmatter-form input[type="checkbox"][name="frontmatter[preamble]"])
           )

    refute has_element?(
             view,
             ~s(#org-memory-frontmatter-form input[type="checkbox"][name="frontmatter[preamble]"][checked])
           )

    # Tick the preamble checkbox to true and submit the form.
    view
    |> form("#org-memory-frontmatter-form", %{"frontmatter" => %{"preamble" => "true"}})
    |> render_submit()

    # Domain round-trip: frontmatter boolean true, version bumped to 2.
    assert %WikiPage{frontmatter: %{"preamble" => true}, version: 2} =
             Wiki.get_page("org/page/playbook.md")

    # Reload (fresh re-mount of the same URL — the script's "reload"):
    # the frontmatter editor now shows preamble: true (checked box).
    {:ok, view2, _html} = live(conn, "/org_memory/org/page/playbook.md")
    view2 |> element(~s([data-view-mode] button[phx-click="start_edit"])) |> render_click()

    assert has_element?(
             view2,
             ~s(#org-memory-frontmatter-form input[type="checkbox"][name="frontmatter[preamble]"][checked])
           )

    # Platform.Org.Wiki.Context.build_preamble/1 (arity 1, keyword opts;
    # [] = org-only scope) now includes org/page/playbook.md.
    preamble = Platform.Org.Wiki.Context.build_preamble([])
    assert Map.has_key?(preamble, "org/page/playbook.md")
    assert preamble["org/page/playbook.md"] =~ "# Playbook"
  end

  # ── Script 5 ─────────────────────────────────────────────────────────────

  @tag :t7_e2e
  test "e2e 5: search via tool surface — PAGE + JOURNAL hits through the real gate",
       %{conn: conn} do
    Repo.delete_all(WikiPage)

    # DELTA from the literal script: the script seeds org/deployment.md
    # and expects a PAGE hit, but through the REAL tool surface that
    # key can never surface — `Wiki.Search` hydration post-filters page
    # hits through `Routing.gate_read/2`, whose path grammar only
    # recognises `<ns>/page/<rest>` page keys (design lock §2).
    # `org/deployment.md` classifies as :unknown → :rejected_namespace
    # → the hit is silently dropped. The closest faithful equivalent
    # seeds the gate-recognised key org/page/deployment.md; the
    # script-literal key is also seeded and asserted ABSENT below to
    # pin this domain behavior down explicitly.
    #
    # 2026-06-11 note: the UI create path now NORMALIZES flat keys to
    # the page grammar (`OrgMemoryLive.normalize_page_key/1`), so a
    # human can no longer create this shape through the create panel —
    # but the DOMAIN stays free-form, this seed goes through
    # `Wiki.upsert_page/3` directly, and the gate still drops the flat
    # key. The pin below remains valid and intentionally kept.
    {:ok, _} = Wiki.upsert_page("org/deployment.md", %{content: "Deploy via gh release.\n"})

    {:ok, _} =
      Wiki.upsert_page("org/page/deployment.md", %{content: "Deploy via gh release.\n"})

    {:ok, _} =
      Journal.append(%{
        content: "Discussed deployment cadence in standup.",
        date: Date.utc_today()
      })

    # The seam gets a recorder that DELEGATES to the real
    # Platform.Federation.ToolSurface — the real gate + Wiki.Search run;
    # only the invocation args become assertable. In test env no
    # memory-service is configured (Memory provider is Noop), so
    # Wiki.Search degrades to its lexical (tsvector/ilike) channels —
    # which is exactly the graceful-degradation path the script allows.
    #
    # Install that Noop explicitly rather than inheriting whatever the
    # global :memory_service env holds when this test runs (task 01a0feff:
    # a leaked sleeping stub made the semantic channel time out, so
    # memory_search answered degraded and no PAGE rendered).
    previous_memory_service = Application.fetch_env(:platform, :memory_service)

    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

    on_exit(fn ->
      case previous_memory_service do
        {:ok, value} -> Application.put_env(:platform, :memory_service, value)
        :error -> Application.delete_env(:platform, :memory_service)
      end
    end)

    previous = Application.get_env(:platform, :org_memory_tool_surface)
    Application.put_env(:platform, :org_memory_tool_surface, RecordingToolSurface)
    Application.put_env(:platform, :t7_e2e_tool_surface_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :org_memory_tool_surface, previous)
      else
        Application.delete_env(:platform, :org_memory_tool_surface)
      end

      Application.delete_env(:platform, :t7_e2e_tool_surface_pid)
    end)

    conn = authenticated_conn(conn, create_user!())
    {:ok, view, _html} = live(conn, ~p"/org_memory")

    view |> element(~s(button[data-tab="search"])) |> render_click()

    view
    |> form("#org-memory-search-form", %{
      "query" => "deployment",
      "corpus" => "all",
      "namespace" => "all"
    })
    |> render_submit()

    # ToolSurface.execute("memory_search", args, ctx) was invoked with
    # args["query"] == "deployment" ("all" filters are dropped).
    assert_receive {:tool_surface_call, "memory_search", args, context}
    assert args["query"] == "deployment"
    assert context == %{agent: nil}

    # At least two hits: one PAGE (org/page/deployment.md — see the
    # seeding delta above), one JOURNAL (today's entry, surfaced under
    # its virtual journal file_key). The JOURNAL hit ranks via the
    # lexical (tsvector) channel — no embeddings/memory-service needed.
    assert has_element?(view, ~s([data-search-result][data-source-tag="page"]), "PAGE")

    assert has_element?(
             view,
             ~s([data-search-result][data-source-tag="page"]),
             "org/page/deployment.md"
           )

    # Pinned delta: the script-literal UI-style key is dropped by the
    # real gate, so exactly one PAGE hit renders.
    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s([data-search-result][data-source-tag="page"]))
           |> LazyHTML.to_tree()
           |> length() == 1

    assert has_element?(view, ~s([data-search-result][data-source-tag="journal"]), "JOURNAL")

    assert has_element?(
             view,
             ~s([data-search-result][data-source-tag="journal"]),
             "Discussed deployment cadence in standup."
           )

    # Each result row displays source tag, score, and a click target.
    page_row = view |> element(~s([data-search-result][data-source-tag="page"])) |> render()
    assert page_row =~ "PAGE"
    assert page_row =~ "score 0."
    assert page_row =~ ~s(phx-click="open_result_page")

    journal_row =
      view |> element(~s([data-search-result][data-source-tag="journal"])) |> render()

    assert journal_row =~ "JOURNAL"
    assert journal_row =~ "score 0."
    assert journal_row =~ ~s(phx-click="open_result_journal")

    # Clicking the PAGE hit patches to the hit's page (the
    # gate-recognised key — see the seeding delta above).
    view
    |> element(~s([data-source-tag="page"] button[phx-click="open_result_page"]))
    |> render_click()

    path = assert_patch(view)
    assert URI.decode(path) == "/org_memory/org/page/deployment.md"
    assert has_element?(view, "h1", "org/page/deployment.md")
  end
end
