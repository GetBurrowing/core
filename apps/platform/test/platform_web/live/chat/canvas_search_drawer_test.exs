defmodule PlatformWeb.Chat.CanvasSearchDrawerTest do
  @moduledoc """
  Task `01a07402` stage 5: canvas search in the per-space canvases drawer.

  The drawer (`Conversation.canvases_drawer/1`, heading "Live Canvases") is the
  only canvas-BROWSING surface in core, and until this stage it sorted but did
  not search. These tests drive the real `ChatLive` mount rather than rendering
  the partial in isolation, because three of the four behaviours under test are
  decided by the round trip — `phx-change` reaching
  `CanvasHooks.handle_event/3`, the results assign coming back, and the
  template picking a mode off the same predicate the handler used.

  ## The fixtures are built to be discriminating

  The body-match canvas has a title that does NOT contain the search phrase and
  the title-match canvas has a body that does NOT contain it, so the two
  snippet rules are separable: an implementation that rendered a snippet on
  every row, and one that rendered it on none, each fail exactly one test here
  rather than both passing by luck.

  Nonsense words ("zorbling", "frimsy") are used on purpose. The chat fixtures
  and the drawer's own copy share a lot of ordinary English, and a phrase like
  "canvas" would match the empty-state text as readily as the row under test.

  ## Why the blank-query cases exist (stage 6)

  Stage 5 asserted the partial-index line only after a `search/2` call, and the
  line was rendered inside the results-mode div — so it never appeared in the
  state a reader arrives in and the suite stayed green anyway. Every assertion
  about that line is now made in BOTH query states, and in both directions
  (present while unindexed canvases exist, absent after the backfill).

  ## Selector discipline

  Assertions go through `has_element?/2` where they can. Where the markup
  itself is inspected it is `LazyHTML.query/2`, never `LazyHTML.filter/2` —
  `filter/2` matches only the fragment's ROOT nodes, so a nested element comes
  back `[]` and reads as "not there" when it is present. Every negative
  assertion here is paired with a positive one on the same render, so a
  selector that matches nothing cannot be mistaken for a behaviour that is
  absent.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.CanvasSearchBackfill
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Repo

  @snippet_selector ~s([data-role="canvas-result-snippet"])
  @indexing_selector ~s([data-role="canvas-search-indexing-state"])
  @search_form ~s(form[phx-change="canvas_search"])

  setup do
    # The index write rides the canvas transaction; synchronous so a fixture is
    # searchable the moment `create_canvas/1` returns.
    previous = Application.get_env(:platform, :canvas_persist_sync)
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, previous) end)

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas Search #{n}",
        slug: "canvas-search-#{n}",
        kind: "channel"
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Search Author",
        joined_at: DateTime.utc_now()
      })

    user =
      Repo.insert!(%User{
        email: "canvas-search-#{n}@example.com",
        name: "Canvas Searcher",
        oidc_sub: "oidc-canvas-search-#{n}"
      })

    %{space: space, author: author, user: user}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp text_doc(body) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{"id" => "t1", "type" => "text", "props" => %{"value" => body}, "children" => []}
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp canvas(space, author, title, body) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => title,
        "document" => text_doc(body)
      })

    canvas
  end

  # Strip a canvas's index row, reproducing a canvas the backfill has not
  # reached. Asserted, not assumed — a fixture that silently failed to
  # de-index would make the indexing-state tests pass for the wrong reason.
  defp deindex!(canvas) do
    Repo.delete_all(from(i in CanvasSearchIndex, where: i.canvas_id == ^canvas.id))
    refute Repo.get(CanvasSearchIndex, canvas.id)
    canvas
  end

  # Mount `ChatLive` on the space with the canvases drawer still CLOSED. Split
  # out of `open_drawer/3` so a test can put the first drawer-open after
  # something else — which is the only way to tell the panel-OPEN recompute
  # apart from a panel-close one.
  defp enter_space(conn, user, space) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}", on_error: :warn)
    view
  end

  defp open_drawer(conn, user, space) do
    view = enter_space(conn, user, space)
    render_click(view, "canvas_panel_toggle", %{})
    view
  end

  # Close and reopen the drawer. This is what exercises the panel-open
  # recompute of `:canvas_unindexed_count`; a plain `render/1` deliberately
  # does not, because the count is not computed in the render path. See
  # `CanvasHooks.refresh_unindexed_count/1`.
  defp reopen_drawer(view) do
    render_click(view, "canvas_panel_toggle", %{})
    render_click(view, "canvas_panel_toggle", %{})
  end

  defp search(view, query) do
    view
    |> form(@search_form, %{"query" => query})
    |> render_change()
  end

  # `LazyHTML.query/2` returns a LazyHTML struct, not a list — it is
  # Enumerable, so `== []` on the struct is always false and would make every
  # negative assertion below pass regardless of the markup. Converted to a real
  # list here, once, so no call site can make that mistake.
  defp query_all(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.to_list()
  end

  # ── the search input exists and is wired ──────────────────────────────────

  describe "the search input" do
    test "renders above the list with the attributes the drawer contract names",
         %{conn: conn, user: user, space: space, author: author} do
      canvas(space, author, "Zorbling Ledger", "body text")

      view = open_drawer(conn, user, space)
      html = render(view)

      assert [input] = query_all(html, ~s([data-role="canvas-search-input"]))

      # `attributes/1` returns one attribute list PER NODE, so this is a list
      # of lists even for a single node.
      attrs = LazyHTML.attributes(input) |> List.first() |> Map.new()

      assert attrs["type"] == "search"
      assert attrs["name"] == "query"
      assert attrs["phx-debounce"] == "300"
      assert attrs["aria-label"] == "Search canvases in this channel"
    end
  end

  # ── the two snippet rules ─────────────────────────────────────────────────

  describe "a BODY-phrase query" do
    test "returns the canvas and renders a snippet carrying the phrase inside <mark>",
         %{conn: conn, user: user, space: space, author: author} do
      bodied =
        canvas(
          space,
          author,
          "Quarterly Notes",
          "the rollout requires zorbling before any customer sees it"
        )

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      # The row is here at all.
      assert has_element?(view, ~s([phx-value-canvas-id="#{bodied.id}"]))
      assert html =~ "Quarterly Notes"

      # And it carries a snippet, which carries the phrase, marked.
      assert [snippet] = query_all(html, @snippet_selector)

      snippet_html = LazyHTML.to_html(snippet)

      assert snippet_html =~ "<mark>zorbling</mark>",
             "expected the matched term wrapped in <mark>, got: #{snippet_html}"

      # The <mark> is real markup, not escaped text shown to the reader.
      refute snippet_html =~ "&lt;mark&gt;"

      # One line, truncated — the design's whole argument against a snippet
      # that grows the row.
      classes = LazyHTML.attribute(snippet, "class") |> List.first()
      assert classes =~ "truncate"
      assert classes =~ "min-w-0"
    end
  end

  describe "a TITLE-phrase query" do
    test "renders the row with NO snippet line",
         %{conn: conn, user: user, space: space, author: author} do
      titled = canvas(space, author, "Frimsy Toadlark Review", "nothing relevant in this body")

      view = open_drawer(conn, user, space)
      html = search(view, "frimsy")

      # POSITIVE first: the row IS rendered. Without this the negative below
      # would also pass on an empty result list, which is a different bug.
      assert has_element?(view, ~s([phx-value-canvas-id="#{titled.id}"]))
      assert html =~ "Frimsy Toadlark Review"

      assert query_all(html, @snippet_selector) == [],
             "a title match must not carry a body fragment"
    end

    test "a body match in the SAME result set still shows its snippet",
         %{conn: conn, user: user, space: space, author: author} do
      # Both rows come back for one query, so the split is proven to be
      # per-row rather than a whole-list mode. A snippet-on-every-row
      # implementation and a snippet-on-no-row implementation both fail here.
      titled = canvas(space, author, "Wumberton Ledger", "nothing relevant here")
      bodied = canvas(space, author, "Unrelated Notes", "one mention of wumberton in the prose")

      view = open_drawer(conn, user, space)
      html = search(view, "wumberton")

      assert has_element?(view, ~s([phx-value-canvas-id="#{titled.id}"]))
      assert has_element?(view, ~s([phx-value-canvas-id="#{bodied.id}"]))

      assert [snippet] = query_all(html, @snippet_selector)
      assert LazyHTML.to_html(snippet) =~ "<mark>wumberton</mark>"
    end
  end

  # ── the partial-index line ────────────────────────────────────────────────

  describe "the partial-index line" do
    test "appears while an unindexed canvas exists in the space",
         %{conn: conn, user: user, space: space, author: author} do
      canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      deindex!(canvas(space, author, "Ancient Board", "a canvas the backfill has not reached"))

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      assert [line] = query_all(html, @indexing_selector)

      text = LazyHTML.text(line)
      assert text =~ "still being indexed"

      # Informational, not a warning: --color-neutral, and none of the
      # semantic tokens the design canvas rules out of a result row.
      classes = LazyHTML.attribute(line, "class") |> List.first()
      assert classes =~ "text-neutral"
      refute classes =~ "warning"
      refute classes =~ "error"
      refute classes =~ "success"
    end

    test "is absent once the backfill has run",
         %{conn: conn, user: user, space: space, author: author} do
      canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      stale = deindex!(canvas(space, author, "Ancient Board", "a canvas awaiting the backfill"))

      # The real backfill entry point, so this test tracks what actually
      # clears the count rather than a synthetic row insert.
      assert :ok = CanvasSearchBackfill.index_one(Repo.reload!(stale))
      assert CanvasSearchIndex.unindexed_count([space.id]) == 0

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      # POSITIVE control: we are looking at a rendered results pane, so the
      # missing line is the line being absent and not the pane being absent.
      assert query_all(html, @snippet_selector) != []

      assert query_all(html, @indexing_selector) == []
    end

    # ── THE BLANK-QUERY STATE ───────────────────────────────────────────────
    #
    # The two tests above both call `search/2` first, and for the whole of
    # stage 5 they were the only coverage this line had. The line was rendered
    # inside the results-mode div, i.e. gated on a non-blank query as well as
    # on the count, so it was invisible in the state every reader ARRIVES in —
    # and the suite was fully green over that, because no case ever looked at
    # the drawer without typing into it first. The hole was between the passing
    # cases, not inside one of them.
    #
    # Both directions are asserted below. A "present with a blank query" test
    # alone would be satisfied by a line that is never taken down again, which
    # is the other half of what stage 6 fixed.

    test "appears with a BLANK query, before anyone has typed anything",
         %{conn: conn, user: user, space: space, author: author} do
      canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      deindex!(canvas(space, author, "Ancient Board", "a canvas the backfill has not reached"))

      view = open_drawer(conn, user, space)
      html = render(view)

      # POSITIVE controls on this very render: the drawer is open (the search
      # input is here) and it is in LIST mode (the sort form is list-mode
      # only), so what follows is asserted about the arrival state and not
      # about a pane that failed to render.
      assert query_all(html, ~s([data-role="canvas-search-input"])) != []
      assert has_element?(view, ~s(form[phx-change="canvas_sort"]))
      assert query_all(html, @snippet_selector) == []

      assert [line] = query_all(html, @indexing_selector)
      assert LazyHTML.text(line) =~ "still being indexed"

      # Same contract as in results mode: neutral, and none of the semantic
      # tokens. Restated here because this is a different render path.
      classes = LazyHTML.attribute(line, "class") |> List.first()
      assert classes =~ "text-neutral"
      refute classes =~ "warning"
      refute classes =~ "error"
      refute classes =~ "success"
    end

    test "goes out with a BLANK query once the backfill completes mid-visit",
         %{conn: conn, user: user, space: space, author: author} do
      canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      stale = deindex!(canvas(space, author, "Ancient Board", "a canvas awaiting the backfill"))

      view = open_drawer(conn, user, space)

      # It is lit to begin with, so "absent" below is a state that CHANGED and
      # not a line that was never rendered.
      assert [_line] = query_all(render(view), @indexing_selector)

      # The real backfill entry point, so this tracks what actually clears the
      # count rather than a synthetic index-row insert.
      assert :ok = CanvasSearchBackfill.index_one(Repo.reload!(stale))
      assert CanvasSearchIndex.unindexed_count([space.id]) == 0

      html = reopen_drawer(view)

      # POSITIVE controls again: still open, still list mode.
      assert query_all(html, ~s([data-role="canvas-search-input"])) != []
      assert has_element?(view, ~s(form[phx-change="canvas_sort"]))

      assert query_all(html, @indexing_selector) == [],
             "the panel-open recompute must pick up a backfill that finished " <>
               "while the drawer was open; a stale count keeps the line lit"
    end

    test "is already out on the FIRST drawer open after a backfill",
         %{conn: conn, user: user, space: space, author: author} do
      # This case exists because of a mutant that survived without it: moving
      # the recompute to the CLOSE half of `"canvas_panel_toggle"` passes every
      # other test here, since the test above closes and reopens and either
      # half would then have fired. It is a real difference, and this is the
      # shape it takes — the backfill runs in the background while the reader
      # sits in the space, and most readers open the canvases drawer once or
      # not at all. A close-side recompute shows them a line about an index
      # that finished before they looked.
      canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      stale = deindex!(canvas(space, author, "Ancient Board", "a canvas awaiting the backfill"))

      # In the space, drawer never opened. The count is 1 at this point,
      # assigned by `CanvasHooks.load_for_space/2` on space entry.
      view = enter_space(conn, user, space)

      assert :ok = CanvasSearchBackfill.index_one(Repo.reload!(stale))
      assert CanvasSearchIndex.unindexed_count([space.id]) == 0

      html = render_click(view, "canvas_panel_toggle", %{})

      # POSITIVE control: this first open really did render the drawer.
      assert query_all(html, ~s([data-role="canvas-search-input"])) != []

      assert query_all(html, @indexing_selector) == [],
             "the first drawer open must recompute the count, not inherit the " <>
               "one taken on space entry"
    end
  end

  # ── blank query restores list mode ────────────────────────────────────────

  describe "a blank query" do
    test "restores the unfiltered sorted list",
         %{conn: conn, user: user, space: space, author: author} do
      matching = canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      other = canvas(space, author, "Unrelated Board", "no mention of the search term here")

      view = open_drawer(conn, user, space)

      # Narrow first, so "restored" means something changed back.
      html = search(view, "zorbling")
      assert has_element?(view, ~s([phx-value-canvas-id="#{matching.id}"]))
      refute has_element?(view, ~s([phx-value-canvas-id="#{other.id}"]))
      assert query_all(html, @snippet_selector) != []

      blank = search(view, "")

      # Both canvases are back...
      assert has_element?(view, ~s([phx-value-canvas-id="#{matching.id}"]))
      assert has_element?(view, ~s([phx-value-canvas-id="#{other.id}"]))

      # ...as the LIST, not as a result set: the sort control is list-mode
      # only, and no row carries a snippet.
      assert has_element?(view, ~s(form[phx-change="canvas_sort"]))
      assert query_all(blank, @snippet_selector) == []
    end

    test "a whitespace-only query is blank, not a search for spaces",
         %{conn: conn, user: user, space: space, author: author} do
      matching = canvas(space, author, "Quarterly Notes", "the rollout requires zorbling first")
      other = canvas(space, author, "Unrelated Board", "no mention of the search term here")

      view = open_drawer(conn, user, space)
      _ = search(view, "zorbling")

      spaces = search(view, "   ")

      assert has_element?(view, ~s([phx-value-canvas-id="#{matching.id}"]))
      assert has_element?(view, ~s([phx-value-canvas-id="#{other.id}"]))
      assert has_element?(view, ~s(form[phx-change="canvas_sort"]))
      assert query_all(spaces, @snippet_selector) == []
    end
  end

  # ── no matches ────────────────────────────────────────────────────────────

  describe "a query matching nothing" do
    test "shows the empty state rather than silently falling back to the list",
         %{conn: conn, user: user, space: space, author: author} do
      other = canvas(space, author, "Unrelated Board", "no mention of the search term here")

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      refute has_element?(view, ~s([phx-value-canvas-id="#{other.id}"]))
      assert html =~ "No canvases in this channel match"
    end
  end
end
