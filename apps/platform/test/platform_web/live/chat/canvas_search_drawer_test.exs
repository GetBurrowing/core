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
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments

  @snippet_selector ~s([data-role="canvas-result-snippet"])
  @leading_selector ~s([data-role="canvas-result-snippet-leading"])
  @match_selector ~s([data-role="canvas-result-snippet-match"])
  @trailing_selector ~s([data-role="canvas-result-snippet-trailing"])
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

  # The text of the ONE element matching `selector`, and a failure naming the
  # count when there is not exactly one. A `.first()` here would silently
  # measure whichever copy the parser happened to yield, which is the same
  # ambiguity the browser-geometry helpers raise on.
  defp one!(html, selector) do
    case query_all(html, selector) do
      [element] -> element
      other -> flunk("expected exactly one #{selector}, got #{length(other)}")
    end
  end

  defp text_of(html, selector), do: html |> one!(selector) |> LazyHTML.text()

  defp class_of(html, selector) do
    html |> one!(selector) |> LazyHTML.attribute("class") |> List.first() || ""
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
      # "across your spaces", not "in this channel": stage 3 made the query
      # multi-space, and a label naming one channel would misdescribe where the
      # results below can come from.
      assert attrs["aria-label"] == "Search canvases across your spaces"
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

      assert snippet_html =~ "<mark data-role=\"canvas-result-snippet-match\"",
             "expected the matched term in the protected match role, got: #{snippet_html}"

      assert text_of(html, @match_selector) == "zorbling"

      # The <mark> is real markup, not escaped text shown to the reader.
      refute snippet_html =~ "&lt;mark&gt;"
    end

    test "partitions the fragment into leading context, the match, and trailing context",
         %{conn: conn, user: user, space: space, author: author} do
      # THE RULE THIS REPLACED, and why. Until task 01a077e6 the snippet was
      # ONE `min-w-0 truncate` element and this test asserted those two classes
      # on it. That rule is overturned: a single right-truncating string clips
      # the match off the right edge at 375px (measured: box right edge x=286,
      # the <mark> at x=317-377, entirely outside), which leaves a phone reader
      # context without the word they searched for — and the row exists
      # precisely because the title above it cannot disambiguate.
      #
      # The replacement is the brand rule that the last thing allowed to
      # truncate is the most meaningful: the match is protected at `shrink-0
      # whitespace-nowrap` and the two context runs yield around it at `min-w-0
      # truncate`. The one-line guarantee this test carried is still owed and
      # is still asserted, now across four elements instead of one.
      #
      # WHAT THIS CANNOT PROVE, stated because a green run here reads like
      # proof and is not: `Phoenix.LiveViewTest` does no layout. Every
      # assertion below would also pass on a build whose CSS never loaded. It
      # pins which characters land in which span. Whether the match is actually
      # on screen at 375px is a browser measurement and belongs to stage 2.
      canvas(
        space,
        author,
        "Quarterly Notes",
        "the rollout requires zorbling before any customer sees it"
      )

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      # The three parts are all present, and each appears exactly once.
      assert [_] = query_all(html, @leading_selector)
      assert [_] = query_all(html, @match_selector)
      assert [_] = query_all(html, @trailing_selector)

      # THE TEXT IS SPLIT AT THE MARK, not duplicated across the runs and not
      # dropped between them. `ts_headline` picks the window, so the runs are
      # matched on their ends rather than on a whole string this test would be
      # re-deriving from the query planner.
      leading = text_of(html, @leading_selector)
      trailing = text_of(html, @trailing_selector)

      assert String.ends_with?(leading, "rollout requires ")
      assert String.starts_with?(trailing, " before any customer sees")
      refute leading =~ "zorbling"
      refute trailing =~ "zorbling"

      # The literal "… " that `Chat.ellipsised_headline/2` prepends belongs to
      # the LEADING run, so under left-side clipping it is the first thing to
      # scroll away and the CSS ellipsis takes its place. Landing it in the
      # match instead would make the protected fragment wider than the match.
      assert String.starts_with?(leading, "… ")

      # STILL ONE LINE, which is what the overturned assertion was protecting.
      # The container clips, both context runs may shrink and truncate, and the
      # match may not shrink at all.
      container = class_of(html, @snippet_selector)
      assert container =~ "flex"
      assert container =~ "min-w-0"
      assert container =~ "overflow-hidden"

      for role <- [@leading_selector, @trailing_selector] do
        classes = class_of(html, role)
        assert classes =~ "min-w-0", "#{role} must be allowed to shrink"
        assert classes =~ "truncate", "#{role} must truncate, not wrap"
      end

      match_classes = class_of(html, @match_selector)
      assert match_classes =~ "shrink-0", "the match must not shrink"
      assert match_classes =~ "whitespace-nowrap", "the match must not wrap"
      refute match_classes =~ "min-w-0"
    end

    test "protects only the FIRST mark and leaves later ones in the trailing run",
         %{conn: conn, user: user, space: space, author: author} do
      # `MaxFragments=1` bounds fragments, not marks: one fragment can carry
      # several <mark> pairs. Protecting all of them would make the row's
      # unshrinkable width the sum of every match and put the overflow back.
      # This is the case that separates "protect the first" from "protect
      # every one", and both pass the single-match test above.
      canvas(
        space,
        author,
        "Repeat Notes",
        "zorbling early and then zorbling again inside one short line"
      )

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      # Exactly one element holds the protected role, whatever the mark count.
      assert [_] = query_all(html, @match_selector)

      marks = query_all(html, "#{@snippet_selector} mark")

      assert length(marks) >= 2,
             "fixture no longer produces a multi-mark fragment, so this case " <>
               "is not exercising the rule it names — got #{length(marks)} mark(s)"

      # The second mark is inside the run that truncates, not a second
      # protected sibling of the container.
      assert [_] = query_all(html, "#{@trailing_selector} mark")
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

      # Read the title through the DOM, not off the raw HTML. Since task
      # 01a0740d stage 3 the explorer marks the matched substring, so this
      # title's markup is `<mark>Frimsy</mark> Toadlark Review` and the
      # untouched string no longer appears anywhere in `html` — the assertion
      # this replaced failed on a row that was rendering perfectly.
      # `LazyHTML.text/1` reassembles across the element boundary.
      assert text_of(html, ~s([data-role="canvas-explorer-row-title"])) ==
               "Frimsy Toadlark Review"

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

      assert [_snippet] = query_all(html, @snippet_selector)
      assert text_of(html, @match_selector) == "wumberton"
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

      # Informational, not a warning: none of the semantic tokens the design
      # canvas rules out of a result row.
      #
      # `text-neutral` is what LIGHT renders. In DARK it is overridden, as of
      # task 01a0792c, by an unlayered rule in `app.css` scoped to this
      # element: `--color-base-content` at 55%, because `--color-neutral`
      # measured 2.23:1 on the drawer's box against a 4.5:1 floor. The utility
      # stays in the markup, which is why this assertion is unchanged.
      #
      # Nothing here is a contrast check. This reads a class attribute and
      # would pass identically against the colour that failed. The guard that
      # recomputes both themes out of the stylesheet is
      # `Platform.Design.CanvasSearchSnippetContrastTest`.
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

      # Same contract as in results mode, and the same limit: the utility is
      # LIGHT's colour, DARK comes from the scoped `app.css` rule task
      # 01a0792c added, and contrast for both is guarded by
      # `Platform.Design.CanvasSearchSnippetContrastTest`, not here. Restated
      # because this is a different render path.
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

  # ── the closed-drawer canvas_create path (task 01a078a1) ──────────────────
  #
  # `CanvasHooks.show_panel/1` is a SECOND drawer-open entry point, reached
  # only by the `"canvas_create"` handler in `chat_live.ex` when a canvas is
  # created while the drawer is still closed. `open_drawer/3` above (and
  # `reopen_drawer/1`) drive the drawer through `"canvas_panel_toggle"`,
  # which already recomputes `:canvas_unindexed_count` itself — a test built
  # on either of those cannot tell a fixed `show_panel/1` from one that never
  # refreshes the count, because both produce identical output. These two
  # tests drive `"canvas_create"` directly via `render_submit/3` on a view
  # whose `:show_canvases` is still false, and never touch `#new-canvas-form`
  # (which only exists in the DOM once the drawer is already open).

  defp create_canvas_closed_drawer(view) do
    render_submit(view, "canvas_create", %{
      "canvas" => %{"title" => "Closed-drawer canvas #{System.unique_integer([:positive])}"}
    })
  end

  describe "show_panel/1 via the closed-drawer canvas_create path" do
    test "the count RISES to non-zero between space entry and the create, and the create picks it up",
         %{conn: conn, user: user, space: space, author: author} do
      # Indexed at seed time (`canvas_persist_sync` is true in setup), so
      # `load_for_space/2` computes 0 on entry.
      seed = canvas(space, author, "Quarterly Notes", "an already-indexed canvas")

      view = enter_space(conn, user, space)

      # Sanity: the drawer really is closed at this point, so the assertions
      # below are about the closed-drawer path and not a drawer already open.
      refute has_element?(view, ~s([data-role="canvas-search-input"]))

      # The count changes AFTER space entry.
      deindex!(seed)
      assert CanvasSearchIndex.unindexed_count([space.id]) == 1

      html = create_canvas_closed_drawer(view)

      assert query_all(html, @indexing_selector) != [],
             "show_panel/1 must recompute :canvas_unindexed_count on the " <>
               "closed-drawer canvas_create path; a stale (zero) count " <>
               "leaves the line dark when it should warn"
    end

    test "the count FALLS to zero between space entry and the create, and the create picks it up",
         %{conn: conn, user: user, space: space, author: author} do
      # Unindexed at entry, so `load_for_space/2` computes 1.
      stale = deindex!(canvas(space, author, "Ancient Board", "awaiting the backfill"))

      view = enter_space(conn, user, space)

      refute has_element?(view, ~s([data-role="canvas-search-input"]))

      # The real backfill entry point, so this tracks what actually clears the
      # count rather than a synthetic index-row insert.
      assert :ok = CanvasSearchBackfill.index_one(Repo.reload!(stale))
      assert CanvasSearchIndex.unindexed_count([space.id]) == 0

      html = create_canvas_closed_drawer(view)

      assert query_all(html, @indexing_selector) == [],
             "show_panel/1 must recompute :canvas_unindexed_count on the " <>
               "closed-drawer canvas_create path; a stale (non-zero) count " <>
               "leaves the line lit after the backfill already finished"
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

      # The explorer owns the no-results line now, and it is a DIFFERENT line
      # from the drawer's old one: the archive is not empty, the filter is, and
      # the component keeps `canvas-explorer-empty` for the other case.
      assert [line] = query_all(html, ~s([data-role="canvas-explorer-no-matches"]))
      assert LazyHTML.text(line) =~ "Nothing matched"

      assert query_all(html, ~s([data-role="canvas-explorer-empty"])) == [],
             "the archive holds a canvas, so this is an empty FILTER, not an empty archive"
    end
  end

  # ── the explorer's groups (task 01a0740d stage 3) ─────────────────────────
  #
  # These drive the real `ChatLive` mount, like everything above, because all
  # three behaviours are decided by the round trip: `CanvasHooks` resolving the
  # pinned groups, the multi-space id list reaching `Chat.search_canvases/3`,
  # and the component picking its expansion off the rows it was handed.
  #
  # ASSERTION SHAPE. Every count here is a NUMBER, and every row assertion is
  # SCOPED to the group it must be inside — `[data-group-key=…]
  # [data-role="canvas-explorer-row"]`. Two reasons, both of them bugs this
  # epic has already produced: "a row exists somewhere in the document" passes
  # against a row rendered in the wrong group, and "a row is missing" passes
  # against an explorer that rendered nothing at all.

  defp group_rows(html, key) do
    html
    |> query_all(~s([data-group-key="#{key}"] [data-role="canvas-explorer-row-title"]))
    |> Enum.map(&LazyHTML.text/1)
  end

  defp group_count_text(html, key) do
    html
    |> text_of(~s([data-group-key="#{key}"] [data-role="canvas-explorer-group-count"]))
    |> String.replace(["·", " "], " ")
    |> String.trim()
  end

  defp group_keys(html) do
    html
    |> query_all(~s([data-role="canvas-explorer-group"]))
    |> Enum.map(&(&1 |> LazyHTML.attribute("data-group-key") |> List.first()))
  end

  # An execution space whose metadata names a task, with THREE canvases attached
  # to that task and ONE of the three soft-deleted — the stale attachment row.
  # `task_canvas_attachments.canvas_id` has no foreign key, which is exactly why
  # this state is reachable in production.
  defp execution_space_with_task(author_name \\ "Exec Bot") do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Explorer Fixture Project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Explorer fixture task #{n}",
        status: "backlog"
      })

    {:ok, space} =
      Chat.create_space(%{
        name: "Execution #{n}",
        slug: "explorer-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: author_name,
        joined_at: DateTime.utc_now()
      })

    canvases =
      for title <- ["Stage 1 evidence", "Stage 2 evidence", "Stage 3 evidence"] do
        canvas(space, participant, title, "body for #{title}")
      end

    attacher = %{kind: "agent", id: Ecto.UUID.generate()}

    for c <- canvases do
      {:ok, _} =
        CanvasAttachments.attach_canvas(Platform.Access.Scope.system(), task.id, c.id,
          attached_by: attacher
        )
    end

    doomed = List.last(canvases)

    {:ok, _} =
      doomed
      |> Platform.Chat.Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    # Asserted, not assumed. A fixture whose soft delete silently failed would
    # make the stale-row test pass by there being no stale row to skip.
    entries = CanvasAttachments.list_task_canvases(task.id)
    assert length(entries) == 3, "expected 3 attachment rows, got #{length(entries)}"

    assert Enum.count(entries, &is_nil(&1.canvas)) == 1,
           "expected exactly ONE stale attachment (canvas: nil), got " <>
             inspect(Enum.map(entries, & &1.canvas))

    %{space: space, task: task, project: project, canvases: canvases, doomed: doomed}
  end

  describe "the pinned On this task group" do
    test "renders 2 rows and a header count of 2 for 3 attachments whose third canvas was deleted",
         %{conn: conn, user: user} do
      %{space: space, canvases: canvases, doomed: doomed} = execution_space_with_task()

      view = open_drawer(conn, user, space)
      html = render(view)

      # THE ROWS. Scoped to the pinned group, so a row rendered into the space
      # group instead would not satisfy this.
      assert group_rows(html, "task") == ["Stage 1 evidence", "Stage 2 evidence"]

      # THE NUMBER, not "a row is missing". A count taken from `length(entries)`
      # rather than from the surviving rows reads 3 here.
      assert group_count_text(html, "task") == "2"

      # And the stale row leaves NOTHING behind: no ghost, no blank-titled row,
      # no error state. Checked against the deleted canvas's own id, anywhere in
      # the document.
      assert query_all(html, ~s([data-canvas-id="#{doomed.id}"])) == [],
             "the soft-deleted canvas must not render a row anywhere"

      # The positive half of the pair: the two live attachments ARE reachable,
      # so the assertions above cannot be satisfied by an explorer that failed
      # to render the group at all.
      for live <- Enum.take(canvases, 2) do
        assert has_element?(view, ~s([phx-value-canvas-id="#{live.id}"]))
      end
    end

    test "sits above the space groups, after In this meeting, when a meeting is live",
         %{conn: conn, user: user} do
      %{space: space, project: project} = execution_space_with_task()

      # A live meeting bound to THIS space, written directly: `create_meeting/1`
      # mints its own backing chat space, and this meeting has to be bound to
      # the execution space for `get_live_meeting_for_space/1` to find it.
      {:ok, _meeting} =
        %Meeting{}
        |> Meeting.changeset(%{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "explorer-meeting-#{System.unique_integer([:positive])}",
          name: "Explorer fixture standup",
          status: "live",
          livekit_room_name: "space-#{space.id}",
          started_at: DateTime.utc_now()
        })
        |> Repo.insert()

      assert Meetings.get_live_meeting_for_space(space.id), "fixture meeting is not live"

      view = open_drawer(conn, user, space)
      html = render(view)

      # ORDER is the assertion, not mere presence: the pinned pair first, in
      # this sequence, then the space groups.
      assert group_keys(html) == ["meeting", "task", "space:" <> space.id]

      assert text_of(
               html,
               ~s([data-group-key="meeting"] [data-role="canvas-explorer-group-label"])
             ) ==
               "In this meeting"

      assert text_of(html, ~s([data-group-key="task"] [data-role="canvas-explorer-group-label"])) ==
               "On this task"
    end

    test "is absent entirely in a plain channel, which names no task", %{
      conn: conn,
      user: user,
      space: space,
      author: author
    } do
      # The negative half. Without it, a drawer that rendered an "On this task"
      # group unconditionally — empty, in every channel — would satisfy every
      # assertion in the first test.
      canvas(space, author, "Ordinary Board", "body")

      view = open_drawer(conn, user, space)
      html = render(view)

      assert group_keys(html) == ["space:" <> space.id]
      assert query_all(html, ~s([data-group-key="task"])) == []
      assert query_all(html, ~s([data-group-key="meeting"])) == []
    end
  end

  describe "searching across spaces" do
    test "finds a match in ANOTHER space the viewer participates in, inside that space's own group",
         %{conn: conn, user: user, space: space, author: author} do
      n = System.unique_integer([:positive])

      # The space the viewer is STANDING IN.
      here = canvas(space, author, "Zorbling Here", "body")

      # A second space the viewer PARTICIPATES IN but is not looking at.
      # `Chat.list_user_conversations/2` reads participant rows, so the
      # participant row is what puts this space in the explorer's scope.
      {:ok, elsewhere_space} =
        Chat.create_space(%{
          name: "Elsewhere #{n}",
          slug: "explorer-elsewhere-#{n}",
          kind: "channel"
        })

      {:ok, _member} =
        Chat.add_participant(elsewhere_space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Canvas Searcher",
          joined_at: DateTime.utc_now()
        })

      {:ok, elsewhere_author} =
        Chat.add_participant(elsewhere_space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Elsewhere Author",
          joined_at: DateTime.utc_now()
        })

      there = canvas(elsewhere_space, elsewhere_author, "Zorbling Elsewhere", "body")

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      # THE CROSS-SPACE HALF: the far match is rendered, and rendered INSIDE the
      # far space's own group rather than merged into the active space's.
      assert group_rows(html, "space:" <> elsewhere_space.id) == ["Zorbling Elsewhere"]
      assert has_element?(view, ~s([phx-value-canvas-id="#{there.id}"]))

      # THE POSITIVE PAIR: the active space's match still appears. Without this,
      # a single-space revert that returned NOTHING would satisfy nothing here,
      # but a search that silently broke altogether could still look like a
      # scoping change rather than a failure.
      assert group_rows(html, "space:" <> space.id) == ["Zorbling Here"]
      assert has_element?(view, ~s([phx-value-canvas-id="#{here.id}"]))

      # Both groups are open BECAUSE they hold matches, and both header counts
      # read against their space's real size.
      assert group_count_text(html, "space:" <> space.id) == "1 of 1"
      assert group_count_text(html, "space:" <> elsewhere_space.id) == "1 of 1"
    end

    test "leaves a participating space with NO match collapsed and rendering no rows", %{
      conn: conn,
      user: user,
      space: space,
      author: author
    } do
      n = System.unique_integer([:positive])
      canvas(space, author, "Zorbling Here", "body")

      {:ok, quiet_space} =
        Chat.create_space(%{
          name: "Quiet #{n}",
          slug: "explorer-quiet-#{n}",
          kind: "channel"
        })

      {:ok, _member} =
        Chat.add_participant(quiet_space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Canvas Searcher",
          joined_at: DateTime.utc_now()
        })

      {:ok, quiet_author} =
        Chat.add_participant(quiet_space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Quiet Author",
          joined_at: DateTime.utc_now()
        })

      canvas(quiet_space, quiet_author, "Nothing To See", "no mention of the term")

      view = open_drawer(conn, user, space)
      html = search(view, "zorbling")

      quiet_key = "space:" <> quiet_space.id

      # The group is still LISTED — dropping it would make a space holding no
      # match indistinguishable from a space the viewer is not in — and it reads
      # its miss as a number against its real size.
      assert quiet_key in group_keys(html)
      assert group_count_text(html, quiet_key) == "0 of 1"

      # COLLAPSED means it rendered no rows, not that it carries a class saying
      # so. The row count IS the behaviour.
      assert group_rows(html, quiet_key) == []

      assert query_all(
               html,
               ~s([data-group-key="#{quiet_key}"] [data-role="canvas-explorer-group-rows"])
             ) ==
               [],
             "a collapsed group must render no rows container at all"

      # Paired with the space that DID match, on the same render, so a selector
      # that matches nothing cannot be read as a group that collapsed.
      assert group_rows(html, "space:" <> space.id) == ["Zorbling Here"]
    end
  end
end
