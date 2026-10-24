defmodule PlatformWeb.Components.Canvases.CanvasExplorerTest do
  @moduledoc """
  The canvas explorer component (task `01a0740d-b081`, stage 2).

  ## The assertion shape this file refuses

  Testing that a class or an attribute is PRESENT is not testing the
  behaviour it is supposed to produce. `class="hidden"` present is not "the
  group is collapsed"; a `data-role` present is not "the dot is visible".
  So the behaviour assertions here are about rendered STRUCTURE and
  CONTENT: which rows exist inside which group, how many came out, and
  what a header or a second line actually reads. The handful of class
  assertions live in their own `describe` block, are labelled as token
  pins, and no behaviour claim rests on them.

  `LazyHTML.query/2` throughout, never `LazyHTML.filter/2`: `query/2`
  descends the whole tree, while `filter/2` matches only the fragment's
  ROOT nodes, so every nested element would come back as `[]` and read as
  "not there".
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Canvases.CanvasExplorer

  @creator "Robin Park"

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp row(overrides) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      title: "A canvas",
      space_id: Ecto.UUID.generate(),
      updated_at: DateTime.add(now, -3600, :second),
      inserted_at: DateTime.add(now, -86_400 * 30, :second),
      created_by_display_name: @creator,
      cloned_from: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  defp rows(titles) when is_list(titles), do: Enum.map(titles, &row(title: &1))

  defp rows(n) when is_integer(n),
    do: Enum.map(1..n, fn i -> row(title: "Canvas #{String.pad_leading("#{i}", 3, "0")}") end)

  defp space_group(name, rows, overrides \\ []) do
    %{
      space_id: Ecto.UUID.generate(),
      space_name: name,
      total_count: length(rows),
      rows: rows
    }
    |> Map.merge(Map.new(overrides))
  end

  defp explorer(overrides) do
    render_component(
      &CanvasExplorer.canvas_explorer/1,
      Keyword.merge([id: "explorer"], overrides)
    )
  end

  # ── LazyHTML helpers ───────────────────────────────────────────────────

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> q(selector) |> Enum.count()

  # Whitespace-normalised so an assertion is about the words rendered, not
  # about how the HEEx formatter happened to indent them.
  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp texts(html, selector),
    do: html |> q(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))

  defp one_text(html, selector) do
    [text] = texts(html, selector)
    text
  end

  defp group_selector(key), do: ~s([data-group-key="#{key}"])

  defp space_key(group), do: "space:" <> group.space_id

  # Rows INSIDE a given group, by title. Scoped through the group's rows
  # container on purpose — "the row is somewhere in the document" is the
  # assertion this component's whole search behaviour has to be stronger
  # than.
  defp rows_in_group(html, key) do
    texts(
      html,
      ~s(#{group_selector(key)} [data-role="canvas-explorer-group-rows"] [data-role="canvas-explorer-row-title"])
    )
  end

  defp header_text(html, key),
    do: one_text(html, ~s(#{group_selector(key)} [data-role="canvas-explorer-group-header"]))

  # Scoped to ONE row's id, so a per-branch claim cannot be satisfied by
  # some other row's line.
  defp lineage_for(html, canvas_id),
    do:
      one_text(
        html,
        ~s([data-canvas-id="#{canvas_id}"] [data-role="canvas-explorer-row-lineage"])
      )

  defp aria_expanded(html, key) do
    html
    |> q(~s(#{group_selector(key)} [data-role="canvas-explorer-group-header"]))
    |> LazyHTML.attribute("aria-expanded")
  end

  # ── 1. Search opens the groups that hold matches ───────────────────────

  describe "search opens every group holding a match" do
    # NAMED MUTATION 1 for this test: make search mode consult
    # `expanded_keys` like browse mode does, i.e. change
    # `defp expanded?(group, true = _searching?, _expanded_keys), do:
    # group.rows != []` to `group.key in expanded_keys`. With
    # `expanded_keys: []` the matching group collapses and this test goes
    # red on the first assertion.
    #
    # Because collapse in this component is STRUCTURAL — a collapsed group
    # renders no rows at all rather than hidden ones — a weaker test that
    # only looked for the row somewhere in the document would also redden
    # here. The scoped assertion below is what keeps that true if someone
    # later re-implements collapse as a `hidden` class, which is the exact
    # defect this ticket names.
    test "a matching group is EXPANDED with its matching rows inside it, while a group with no match stays COLLAPSED and renders no rows" do
      hit =
        space_group("Alpha space", rows(["Approval flow — final", "Approval flow v2"]), %{
          total_count: 41
        })

      miss = space_group("Beta space", [], %{total_count: 12})

      html =
        explorer(
          query: "approval",
          space_groups: [hit, miss],
          expanded_keys: []
        )

      # The matching group: its rows are rendered INSIDE it.
      assert rows_in_group(html, space_key(hit)) == [
               "Approval flow — final",
               "Approval flow v2"
             ]

      assert aria_expanded(html, space_key(hit)) == ["true"]

      # The group with no match: still there, still collapsed, and it
      # contributes no rows and no rows container at all.
      assert count(html, group_selector(space_key(miss))) == 1

      assert count(
               html,
               ~s(#{group_selector(space_key(miss))} [data-role="canvas-explorer-group-rows"])
             ) == 0

      assert rows_in_group(html, space_key(miss)) == []
      assert aria_expanded(html, space_key(miss)) == ["false"]

      # And the whole document holds exactly the two matching rows: a
      # collapsed group has not smuggled its 12 canvases in behind a class.
      assert count(html, ~s([data-role="canvas-explorer-row"])) == 2
    end

    test "the header count in search mode reads matches against the group's true size" do
      hit =
        space_group("Alpha space", rows(["Approval flow — final", "Approval flow v2"]), %{
          total_count: 41
        })

      miss = space_group("Beta space", [], %{total_count: 12})

      html = explorer(query: "approval", space_groups: [hit, miss])

      assert header_text(html, space_key(hit)) == "Alpha space · 2 of 41"
      assert header_text(html, space_key(miss)) == "Beta space · 0 of 12"
    end

    test "in browse mode the user's own toggles decide, and an untoggled group renders no rows" do
      group = space_group("Alpha space", rows(["Atlas demo plan"]))

      collapsed = explorer(space_groups: [group], expanded_keys: [])
      opened = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      assert rows_in_group(collapsed, space_key(group)) == []
      assert rows_in_group(opened, space_key(group)) == ["Atlas demo plan"]
    end

    test "browse mode does NOT open a group just because it has rows" do
      # The inverse of the search rule, and worth its own test: if browse
      # mode ever fell through to `rows != []` the collapse control would
      # do nothing and every visit would render the whole archive.
      group = space_group("Alpha space", rows(30))

      html = explorer(space_groups: [group], expanded_keys: [])

      assert count(html, ~s([data-role="canvas-explorer-row"])) == 0
      assert header_text(html, space_key(group)) == "Alpha space · 30"
    end
  end

  # ── 2. Bounded pages ───────────────────────────────────────────────────

  describe "bounded pages" do
    # NAMED MUTATION 2 for this test: delete the `Enum.take(group.rows,
    # assigns.page_size)` in `explorer_group/1` and render `group.rows`
    # directly. This test goes red on the count.
    test "a group handed 40 rows renders at most page_size of them, and the header still reports the true total of 45" do
      group = space_group("Big space", rows(40), %{total_count: 45})

      html =
        explorer(
          space_groups: [group],
          expanded_keys: [space_key(group)],
          page_size: 20
        )

      rendered = rows_in_group(html, space_key(group))

      assert length(rendered) == 20,
             "expected the page to be bounded at 20, got #{length(rendered)} rows"

      assert length(rendered) <= 20

      # The rows rendered are the FIRST page, in the order handed over.
      assert List.first(rendered) == "Canvas 001"
      assert List.last(rendered) == "Canvas 020"

      # The header is not bounded. It reads the space's real size, which is
      # the whole reason stage 1 made `total_count` a COUNT rather than
      # `length(rows)`.
      assert header_text(html, space_key(group)) == "Big space · 45"

      # Nothing else on the page smuggled the other 20 in.
      assert count(html, ~s([data-role="canvas-explorer-row"])) == 20
    end

    test "search results are bounded by the same cap" do
      group = space_group("Big space", rows(40), %{total_count: 45, matched_count: 40})

      html = explorer(query: "canvas", space_groups: [group], page_size: 20)

      assert length(rows_in_group(html, space_key(group))) == 20
      assert header_text(html, space_key(group)) == "Big space · 40 of 45"
    end

    test "the pager offers the next page and says where in the group you are" do
      group = space_group("Big space", rows(20), %{total_count: 45})

      html =
        explorer(space_groups: [group], expanded_keys: [space_key(group)], page_size: 20)

      assert one_text(html, ~s([data-role="canvas-explorer-page-range"])) == "1–20 of 45"

      assert html
             |> q(~s([data-role="canvas-explorer-next-page"]))
             |> LazyHTML.attribute("phx-value-offset") == ["20"]

      # Page one has nowhere to go back to.
      assert count(html, ~s([data-role="canvas-explorer-prev-page"])) == 0
    end

    test "a later page offers both directions and its next page is the short remainder" do
      group = space_group("Big space", rows(20), %{total_count: 45, offset: 20})

      html =
        explorer(space_groups: [group], expanded_keys: [space_key(group)], page_size: 20)

      assert one_text(html, ~s([data-role="canvas-explorer-page-range"])) == "21–40 of 45"

      assert html
             |> q(~s([data-role="canvas-explorer-prev-page"]))
             |> LazyHTML.attribute("phx-value-offset") == ["0"]

      assert html
             |> q(~s([data-role="canvas-explorer-next-page"]))
             |> LazyHTML.attribute("phx-value-offset") == ["40"]

      assert one_text(html, ~s([data-role="canvas-explorer-next-page"])) == "Next 5"
    end

    test "a group that fits on one page gets no pager at all" do
      group = space_group("Small space", rows(3))

      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      assert rows_in_group(html, space_key(group)) |> length() == 3
      assert count(html, ~s([data-role="canvas-explorer-pager"])) == 0
    end

    test "search results get no pager, because a ranked list cannot be paged honestly" do
      group = space_group("Big space", rows(20), %{total_count: 45, matched_count: 40})

      html = explorer(query: "canvas", space_groups: [group], page_size: 20)

      assert count(html, ~s([data-role="canvas-explorer-pager"])) == 0
    end
  end

  # ── 3. The collapsed strip and its active-filter dot ───────────────────

  describe "the collapsed strip" do
    # NAMED MUTATION 3 for this test: delete the `:if={@searching?}` from
    # the dot span in `collapsed_strip/1`, or delete the span. The first
    # assertion goes red.
    #
    # The PAIR is what makes this test worth anything: without the
    # no-search half, a test asserting only "the dot is present" passes
    # against a component that renders the dot unconditionally — and an
    # always-on dot says nothing at all.
    test "the dot is on the search icon while a filter is set, and absent when the field is empty" do
      group = space_group("Alpha space", rows(["Approval flow"]), %{total_count: 41})

      filtered = explorer(collapsed: true, query: "approval", space_groups: [group])
      unfiltered = explorer(collapsed: true, query: "", space_groups: [group])

      assert count(filtered, ~s([data-role="canvas-explorer-filter-dot"])) == 1
      assert count(unfiltered, ~s([data-role="canvas-explorer-filter-dot"])) == 0

      # The dot is inside the SEARCH control, not floating on the strip:
      # a dot beside the folder icon would say a different thing.
      assert count(
               filtered,
               ~s([data-role="canvas-explorer-strip-search"] [data-role="canvas-explorer-filter-dot"])
             ) == 1

      # And it is spoken, not only drawn.
      assert filtered
             |> q(~s([data-role="canvas-explorer-strip-search"]))
             |> LazyHTML.attribute("aria-label") == [
               "Open the canvas list and search — a filter is still set"
             ]

      assert unfiltered
             |> q(~s([data-role="canvas-explorer-strip-search"]))
             |> LazyHTML.attribute("aria-label") == ["Open the canvas list and search"]
    end

    test "the strip carries the count, a folder control that opens the list and a search control that opens it focused" do
      groups = [
        space_group("Alpha space", rows(2), %{total_count: 41}),
        space_group("Beta space", rows(1), %{total_count: 3})
      ]

      html = explorer(collapsed: true, space_groups: groups)

      assert one_text(html, ~s([data-role="canvas-explorer-strip-count"])) == "44"

      assert html
             |> q(~s([data-role="canvas-explorer-strip-open"]))
             |> LazyHTML.attribute("phx-click") == ["canvas_explorer_expand"]

      # The search control asks the caller to focus its field — the field
      # belongs to the caller's shipped, debounced form, not to this
      # component.
      search = q(html, ~s([data-role="canvas-explorer-strip-search"]))
      assert LazyHTML.attribute(search, "phx-click") == ["canvas_explorer_expand"]
      assert LazyHTML.attribute(search, "phx-value-focus") == ["search"]
    end

    test "the strip count sums the space groups only, so a canvas pinned to this meeting is not counted twice" do
      space = space_group("Alpha space", rows(2), %{total_count: 41})

      pinned = %{
        key: "meeting",
        label: "In this meeting",
        rows: space.rows,
        total_count: 2
      }

      html = explorer(collapsed: true, space_groups: [space], pinned_groups: [pinned])

      assert one_text(html, ~s([data-role="canvas-explorer-strip-count"])) == "41"
    end

    test "collapsed renders the strip INSTEAD of the list, not beside it" do
      group = space_group("Alpha space", rows(3), %{total_count: 41})
      keys = [space_key(group)]

      collapsed = explorer(collapsed: true, space_groups: [group], expanded_keys: keys)
      open = explorer(collapsed: false, space_groups: [group], expanded_keys: keys)

      assert count(collapsed, ~s([data-role="canvas-explorer-strip"])) == 1
      assert count(collapsed, ~s([data-role="canvas-explorer-open"])) == 0
      assert count(collapsed, ~s([data-role="canvas-explorer-row"])) == 0

      assert count(open, ~s([data-role="canvas-explorer-strip"])) == 0
      assert count(open, ~s([data-role="canvas-explorer-open"])) == 1
      assert count(open, ~s([data-role="canvas-explorer-row"])) == 3
    end
  end

  # ── 4. Lineage: which parent, and the deleted branch ───────────────────

  describe "the lineage line" do
    # NAMED MUTATION 4 for this test: make the live-parent clause fall
    # through to the deleted copy, e.g. change
    # `{:ok, title} when is_binary(title) -> lineage_from_title(title)` to
    # `{:ok, title} when is_binary(title) -> "cloned from a deleted canvas"`.
    # The first assertion goes red and the second stays green — which is
    # the point of using two rows. Either assertion alone cannot tell the
    # two branches apart.
    test "a clone of a LIVE parent names that parent's title, and a clone of a soft-deleted parent reads 'cloned from a deleted canvas'" do
      live_parent = Ecto.UUID.generate()
      gone_parent = Ecto.UUID.generate()

      from_live = row(title: "Approval flow v3", cloned_from: live_parent)
      from_gone = row(title: "Approval flow (3)", cloned_from: gone_parent)

      group = space_group("Alpha space", [from_live, from_gone], %{total_count: 41})

      html =
        explorer(
          query: "approval",
          space_groups: [group],
          parent_titles: %{live_parent => "Approval flow v2", gone_parent => :deleted}
        )

      # Two rows, two assertions, each bound to its own row id rather than
      # to list order. Either one alone cannot tell the branches apart: a
      # component that always said "deleted" passes the second, and one
      # that never said it passes the first.
      assert lineage_for(html, from_live.id) == "cloned from Approval flow v2"
      assert lineage_for(html, from_gone.id) == "cloned from a deleted canvas"
    end

    test "a canvas that is not a clone gets no lineage line" do
      group = space_group("Alpha space", [row(title: "Approval flow", cloned_from: nil)])

      html = explorer(query: "approval", space_groups: [group])

      assert count(html, ~s([data-role="canvas-explorer-row-lineage"])) == 0
    end

    test "a parent the caller never resolved is not called deleted" do
      # `Map.fetch/2`, not `Map.get/2`: an id absent from the map means
      # nobody asked about it. Saying "deleted" there is a claim about a
      # canvas that may be perfectly alive.
      group =
        space_group("Alpha space", [
          row(title: "Approval flow v2", cloned_from: Ecto.UUID.generate())
        ])

      html = explorer(query: "approval", space_groups: [group], parent_titles: %{})

      assert one_text(html, ~s([data-role="canvas-explorer-row-lineage"])) ==
               "cloned from another canvas"
    end

    test "a live parent with no title reads as untitled rather than as an empty parent name" do
      parent = Ecto.UUID.generate()
      group = space_group("Alpha space", [row(title: "Approval flow v2", cloned_from: parent)])

      html = explorer(query: "a", space_groups: [group], parent_titles: %{parent => nil})

      assert one_text(html, ~s([data-role="canvas-explorer-row-lineage"])) ==
               "cloned from an untitled canvas"
    end
  end

  # ── 5. The second line: recency leads ──────────────────────────────────

  describe "the second line (the signature element)" do
    # NAMED MUTATION 5 for this test: swap the order in `meta_line/1`, i.e.
    # `[creator(row), recency(row)]`. Both assertions go red.
    #
    # The whole design call in section 1 of the design canvas is about
    # which token LEADS, so the ORDER is what has to be pinned — a test
    # that merely asserted both tokens appear would pass either way.
    test "the second line leads with recency and puts the creator AFTER it" do
      group =
        space_group("Alpha space", [
          row(
            title: "Approval flow — final",
            updated_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
          )
        ])

      html = explorer(query: "approval", space_groups: [group])

      line = one_text(html, ~s([data-role="canvas-explorer-row-meta"]))

      assert line == "Edited 2h ago · #{@creator}"

      # Stated as an ordering too, so the intent survives a wording change
      # to the recency phrase.
      recency_at = :binary.match(line, "Edited") |> elem(0)
      creator_at = :binary.match(line, @creator) |> elem(0)

      assert recency_at < creator_at,
             "recency must lead the second line; got #{inspect(line)}"
    end

    test "the five near-duplicate cluster is separable: one creator on all five rows, five distinct recency phrases" do
      now = DateTime.utc_now()

      offsets = [
        {"Approval flow — final", -2 * 3600},
        {"Approval flow (3)", -26 * 3600},
        {"Approval flow v3", -6 * 86_400},
        {"Approval flow v2", -20 * 86_400},
        {"Approval flow", -400 * 86_400}
      ]

      cluster =
        Enum.map(offsets, fn {title, offset} ->
          row(title: title, updated_at: DateTime.add(now, offset, :second))
        end)

      html =
        explorer(
          query: "approval",
          space_groups: [space_group("Alpha space", cluster, %{total_count: 41})]
        )

      lines = texts(html, ~s([data-role="canvas-explorer-row-meta"]))

      assert length(lines) == 5

      # The author separates none of them — that is the ticket's own worked
      # example, and it is why the author does not lead.
      assert Enum.all?(lines, &String.contains?(&1, @creator))

      # Recency does separate them. Five rows, five different second lines.
      assert lines |> Enum.uniq() |> length() == 5
    end

    test "a row with no creator name still leads with recency instead of rendering a stray separator" do
      group =
        space_group("Alpha space", [
          row(
            title: "Approval flow",
            created_by_display_name: nil,
            updated_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)
          )
        ])

      html = explorer(query: "approval", space_groups: [group])

      assert one_text(html, ~s([data-role="canvas-explorer-row-meta"])) == "Edited 5d ago"
    end

    test "browse rows are ONE line: the title, with no second line and no lineage line" do
      parent = Ecto.UUID.generate()

      group =
        space_group("Alpha space", [row(title: "Approval flow v2", cloned_from: parent)])

      html =
        explorer(
          space_groups: [group],
          expanded_keys: [space_key(group)],
          parent_titles: %{parent => "Approval flow"}
        )

      assert rows_in_group(html, space_key(group)) == ["Approval flow v2"]
      assert count(html, ~s([data-role="canvas-explorer-row-meta"])) == 0
      assert count(html, ~s([data-role="canvas-explorer-row-lineage"])) == 0
    end

    test "an untitled canvas is named rather than rendering an empty row" do
      group = space_group("Alpha space", [row(title: nil), row(title: "   ")])

      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      assert rows_in_group(html, space_key(group)) == ["Untitled canvas", "Untitled canvas"]
    end
  end

  # ── The match mark ─────────────────────────────────────────────────────

  describe "marking the match" do
    test "only the matched substring is marked, and the title still reads whole" do
      group = space_group("Alpha space", [row(title: "Approval flow v2")])

      html = explorer(query: "approval", space_groups: [group])

      assert one_text(html, ~s([data-role="canvas-explorer-title-match"])) == "Approval"
      assert one_text(html, ~s([data-role="canvas-explorer-row-title"])) == "Approval flow v2"
    end

    test "a match late in a long title is still marked, which is when the reader needs it most" do
      long = String.duplicate("Blaze-shaped onboarding ", 8) <> "approval addendum"
      group = space_group("Alpha space", [row(title: long)])

      html = explorer(query: "approval", space_groups: [group])

      assert one_text(html, ~s([data-role="canvas-explorer-title-match"])) == "approval"
    end

    test "a multi-word query marks each of its terms" do
      group = space_group("Alpha space", [row(title: "Approval flow — final")])

      html = explorer(query: "approval final", space_groups: [group])

      assert texts(html, ~s([data-role="canvas-explorer-title-match"])) == ["Approval", "final"]

      assert one_text(html, ~s([data-role="canvas-explorer-row-title"])) ==
               "Approval flow — final"
    end

    test "a body-only hit whose title does not contain the term renders the title unmarked and whole" do
      group = space_group("Alpha space", [row(title: "Atlas demo plan")])

      html = explorer(query: "approval", space_groups: [group])

      assert count(html, ~s([data-role="canvas-explorer-title-match"])) == 0
      assert one_text(html, ~s([data-role="canvas-explorer-row-title"])) == "Atlas demo plan"
    end

    test "browse mode marks nothing" do
      group = space_group("Approval space", [row(title: "Approval flow")])

      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      assert count(html, ~s([data-role="canvas-explorer-title-match"])) == 0
    end

    test "a title that looks like markup is escaped, not rendered" do
      group = space_group("Alpha space", [row(title: "<script>alert(1)</script> approval")])

      html = explorer(query: "approval", space_groups: [group])

      refute html =~ "<script>"
      assert one_text(html, ~s([data-role="canvas-explorer-row-title"])) =~ "alert(1)"
    end
  end

  # ── Pinned groups ──────────────────────────────────────────────────────

  describe "pinned groups" do
    test "pinned groups render first, in the caller's order, above the space groups" do
      meeting = %{
        key: "meeting",
        label: "In this meeting",
        rows: rows(["Atlas demo plan"]),
        total_count: 1
      }

      task = %{
        key: "task",
        label: "On this task",
        rows: rows(["Approval flow"]),
        total_count: 2
      }

      alpha = space_group("Alpha space", rows(1))

      html = explorer(pinned_groups: [meeting, task], space_groups: [alpha])

      assert html
             |> q(~s([data-role="canvas-explorer-group"]))
             |> LazyHTML.attribute("data-group-key") == [
               "meeting",
               "task",
               space_key(alpha)
             ]
    end

    test "a pinned group's label and count are the caller's, verbatim" do
      task = %{
        key: "task",
        label: "On this task",
        rows: rows(["Approval flow"]),
        total_count: 2
      }

      html = explorer(pinned_groups: [task], expanded_keys: ["task"])

      assert header_text(html, "task") == "On this task · 2"
      assert rows_in_group(html, "task") == ["Approval flow"]
    end

    test "a pinned group collapses and opens on the same rule as a space group" do
      task = %{key: "task", label: "On this task", rows: rows(["Approval flow"]), total_count: 1}

      assert rows_in_group(explorer(pinned_groups: [task], expanded_keys: []), "task") == []

      assert rows_in_group(explorer(pinned_groups: [task], expanded_keys: ["task"]), "task") ==
               ["Approval flow"]
    end
  end

  # ── Empty states ───────────────────────────────────────────────────────

  describe "empty states" do
    test "no groups at all says the archive is empty" do
      html = explorer([])

      assert count(html, ~s([data-role="canvas-explorer-empty"])) == 1
      assert count(html, ~s([data-role="canvas-explorer-no-matches"])) == 0
    end

    test "a search that matched nothing says so, and does NOT claim bodies are unindexed" do
      html =
        explorer(
          query: "approval",
          space_groups: [space_group("Alpha space", [], %{total_count: 41})]
        )

      line = one_text(html, ~s([data-role="canvas-explorer-no-matches"]))

      assert line == "Nothing matched “approval”."

      # The ticket's "bodies are not indexed" line would be false on
      # current main: `chat_canvas_search` carries a stored generated
      # `body_search_vector` and `search_canvases/3` searches both. The
      # true caveat — the partial-index one — is the caller's shipped
      # `canvas-search-indexing-state` line, and is not duplicated here.
      refute line =~ "index"

      # An empty archive and an empty filter are opposite facts.
      assert count(html, ~s([data-role="canvas-explorer-empty"])) == 0
    end

    test "an opened group with nothing in it says so rather than rendering a blank" do
      group = space_group("Alpha space", [], %{total_count: 0})

      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      assert count(html, ~s([data-role="canvas-explorer-group-empty"])) == 1
      assert header_text(html, space_key(group)) == "Alpha space · 0"
    end

    test "a space with no name still gets a header a reader can use" do
      group = space_group(nil, rows(1), %{total_count: 1})

      html = explorer(space_groups: [group])

      assert header_text(html, space_key(group)) == "Untitled space · 1"
    end
  end

  # ── Events ─────────────────────────────────────────────────────────────

  describe "the events it emits" do
    test "a row opens the canvas through the drawer's existing event and id" do
      canvas = row(title: "Approval flow")
      group = space_group("Alpha space", [canvas])

      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      button = q(html, ~s([data-role="canvas-explorer-row"]))

      assert LazyHTML.attribute(button, "phx-click") == ["canvas_open"]
      assert LazyHTML.attribute(button, "phx-value-canvas-id") == [canvas.id]
    end

    test "a group header toggles by key" do
      group = space_group("Alpha space", rows(1))

      html = explorer(space_groups: [group])

      header = q(html, ~s([data-role="canvas-explorer-group-header"]))

      assert LazyHTML.attribute(header, "phx-click") == ["canvas_explorer_toggle_group"]
      assert LazyHTML.attribute(header, "phx-value-key") == [space_key(group)]
    end

    test "every control carries the caller's phx-target when one is given" do
      group = space_group("Alpha space", rows(1), %{total_count: 40})

      html =
        explorer(
          space_groups: [group],
          expanded_keys: [space_key(group)],
          target: "#drawer"
        )

      for role <- [
            "canvas-explorer-group-header",
            "canvas-explorer-row",
            "canvas-explorer-next-page",
            "canvas-explorer-collapse"
          ] do
        assert html
               |> q(~s([data-role="#{role}"]))
               |> LazyHTML.attribute("phx-target") == ["#drawer"],
               "#{role} dropped phx-target"
      end
    end

    test "the selected canvas is marked as current" do
      selected = row(title: "Approval flow")
      other = row(title: "Atlas demo plan")
      group = space_group("Alpha space", [selected, other])

      html =
        explorer(
          space_groups: [group],
          expanded_keys: [space_key(group)],
          active_canvas_id: selected.id
        )

      assert html
             |> q(~s([data-role="canvas-explorer-row"][aria-current="true"]))
             |> LazyHTML.attribute("data-canvas-id") == [selected.id]
    end
  end

  # ── Token pins ─────────────────────────────────────────────────────────
  #
  # Class assertions, kept apart from every behaviour claim above on
  # purpose. These pin the DESIGN CONTRACT — which semantic slot each part
  # uses — and nothing here is offered as evidence that the component
  # behaves correctly.

  describe "palette and type slots" do
    test "the group header sits on base-200 with an --edge rule under it, never base-300" do
      group = space_group("Alpha space", rows(1))
      html = explorer(space_groups: [group])

      [class] =
        html |> q(~s([data-role="canvas-explorer-group-header"])) |> LazyHTML.attribute("class")

      assert class =~ "bg-base-200"
      assert class =~ "border-edge"
      refute class =~ "base-300"
    end

    test "the count carries no size or colour class of its own, so it cannot drift from the label" do
      group = space_group("Alpha space", rows(1))
      html = explorer(space_groups: [group])

      assert html
             |> q(~s([data-role="canvas-explorer-group-count"]))
             |> LazyHTML.attribute("class") == []
    end

    test "the match is marked by weight and a base-200 band, never by primary" do
      group = space_group("Alpha space", [row(title: "Approval flow")])
      html = explorer(query: "approval", space_groups: [group])

      [class] =
        html |> q(~s([data-role="canvas-explorer-title-match"])) |> LazyHTML.attribute("class")

      assert class =~ "font-semibold"
      assert class =~ "bg-base-200"
      refute class =~ "primary"
      refute class =~ "text-info"
    end

    test "the second line is 12.5px at base-content/60, not the /40 disabled treatment" do
      group = space_group("Alpha space", [row(title: "Approval flow")])
      html = explorer(query: "approval", space_groups: [group])

      [class] =
        html |> q(~s([data-role="canvas-explorer-row-meta"])) |> LazyHTML.attribute("class")

      assert class =~ "text-[12.5px]"
      assert class =~ "text-subtle"
      refute class =~ "text-base-content/40"
    end

    test "a row is not a card: no border box and no rounding on the row itself" do
      group = space_group("Alpha space", rows(1))
      html = explorer(space_groups: [group], expanded_keys: [space_key(group)])

      [class] = html |> q(~s([data-role="canvas-explorer-row"])) |> LazyHTML.attribute("class")

      refute class =~ "rounded"
      # `border-l-2 border-transparent` is the selection rail, invisible until
      # a row is current; what is refused here is a bare `border`, i.e. the
      # box that would make this a card.
      refute class =~ ~r/\bborder\b(?!-)/
    end

    test "the strip is 44px wide and its dot is the info slot" do
      group = space_group("Alpha space", rows(1), %{total_count: 41})
      html = explorer(collapsed: true, query: "approval", space_groups: [group])

      [strip_class] =
        html |> q(~s([data-role="canvas-explorer-strip"])) |> LazyHTML.attribute("class")

      # `w-11` is 2.75rem — 44px at the default root size.
      assert strip_class =~ "w-11"

      [dot_class] =
        html |> q(~s([data-role="canvas-explorer-filter-dot"])) |> LazyHTML.attribute("class")

      assert dot_class =~ "bg-info"
      refute dot_class =~ "primary"
    end
  end
end
