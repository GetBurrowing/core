defmodule Platform.Chat.CanvasExplorerListingTest do
  @moduledoc """
  `Chat.list_canvas_groups/2` and `Chat.canvas_parent_titles/1` — the bounded
  multi-space read behind the canvas explorer (task 01a0740d, stage 1).

  The fixture is built so that each assertion can only pass for the right
  reason:

    * the paging space holds 45 canvases inserted in REVERSE title order, so
      an implementation that returns rows in insertion order (or in no order)
      fails the sequence assertion rather than passing on fixture luck;
    * `total_count` is pinned by its own named test on the SAME space whose
      rows are capped, so removing the cap and deriving the count from
      `length(rows)` cannot both stay green;
    * the no-`:document` assertion is on key ABSENCE, because a `%Canvas{}`
      struct carries `document` even when the caller never reads it, and
      `row.document == nil` would pass against a struct.

  Mutations run while writing this file, each confirmed RED and reverted —
  see the stage report for verbatim output:

    1. delete the `where: r.rank > ^offset and r.rank <= ^(offset + limit)`
       bound in `canvas_group_rows/3` (the per-space `:limit`) — reddens
       "caps rows at :limit …".
    2. make `canvas_parent_titles/1` default to `nil` instead of `:deleted` —
       reddens "a soft-deleted parent resolves to the :deleted marker …".
    3. add `document: c.document` back into both selects in
       `canvas_group_rows/3` — reddens "rows carry no :document key …".
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Canvas

  # 45 > any plausible default page, and > 40 as the stage requires, so the
  # group header and the row count are forced to disagree.
  @paging_space_size 45

  setup do
    # Names chosen so BYTE order and CASE-INSENSITIVE order differ: byte order
    # files "Bravo"/"Zulu" before lowercase "apple". A missing `lower()` on the
    # space-name sort therefore fails rather than passing by luck.
    paging = space!("Bravo paging space")
    tiny = space!("apple tiny space")
    lineage = space!("Zulu lineage space")
    empty = space!("Delta empty space")

    paging_author = participant!(paging.id, "Paging Author")
    tiny_author = participant!(tiny.id, "Tiny Author")
    lineage_author = participant!(lineage.id, "Lineage Author")

    # Inserted 45..01, i.e. DESCENDING by title. Ascending title order is
    # therefore the exact reverse of insertion order.
    paging_canvases =
      @paging_space_size..1//-1
      |> Enum.map(fn n ->
        canvas!(paging.id, "Doc #{String.pad_leading(to_string(n), 2, "0")}", paging_author.id)
      end)

    # Byte order: "Middle", "Zebra", "apple". Case-insensitive: apple, Middle,
    # Zebra. Plus a title TIE inserted at two distinct times, for the
    # `inserted_at` tiebreaker.
    _ = canvas!(tiny.id, "Zebra", tiny_author.id)
    _ = canvas!(tiny.id, "apple", tiny_author.id)
    _ = canvas!(tiny.id, "Middle", tiny_author.id)
    tie_first = canvas!(tiny.id, "Same title", tiny_author.id, sleep: 5)
    tie_second = canvas!(tiny.id, "Same title", tiny_author.id, sleep: 5)
    gone = canvas!(tiny.id, "Soft deleted", tiny_author.id)
    soft_delete!(gone)

    live_parent = canvas!(lineage.id, "Live parent", lineage_author.id)
    doomed_parent = canvas!(lineage.id, "Doomed parent", lineage_author.id)

    child_of_live =
      canvas!(lineage.id, "Child of live", lineage_author.id, cloned_from: live_parent.id)

    child_of_deleted =
      canvas!(lineage.id, "Child of deleted", lineage_author.id, cloned_from: doomed_parent.id)

    soft_delete!(doomed_parent)

    %{
      paging: paging,
      tiny: tiny,
      lineage: lineage,
      empty: empty,
      paging_canvases: paging_canvases,
      tie_first: tie_first,
      tie_second: tie_second,
      gone: gone,
      live_parent: live_parent,
      doomed_parent: doomed_parent,
      child_of_live: child_of_live,
      child_of_deleted: child_of_deleted
    }
  end

  # ── fixture helpers ───────────────────────────────────────────────────────

  defp space!(name) do
    suffix = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        "name" => "#{name} #{suffix}",
        "slug" => "canvas-explorer-#{suffix}",
        "kind" => "channel"
      })

    space
  end

  defp participant!(space_id, display_name) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp canvas!(space_id, title, created_by, opts \\ []) do
    attrs = %{
      "space_id" => space_id,
      "title" => title,
      "created_by" => created_by,
      "created_by_display_name" => "Author of #{title}"
    }

    attrs =
      case Keyword.get(opts, :cloned_from) do
        nil -> attrs
        parent_id -> Map.put(attrs, "cloned_from", parent_id)
      end

    {:ok, canvas} = Chat.create_canvas(attrs)

    # Only where a test depends on distinct `inserted_at` values. Without it two
    # canvases sharing a title could share a timestamp and the tiebreaker
    # assertion would pass on ordering luck.
    case Keyword.get(opts, :sleep) do
      nil -> :ok
      ms -> Process.sleep(ms)
    end

    canvas
  end

  defp soft_delete!(canvas) do
    {:ok, deleted} =
      canvas
      |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    deleted
  end

  defp group_for(groups, space_id), do: Enum.find(groups, &(&1.space_id == space_id))

  defp titles(rows), do: Enum.map(rows, & &1.title)

  # ── the cap ───────────────────────────────────────────────────────────────

  describe "list_canvas_groups/2 bounding" do
    test "caps rows at :limit for a space holding 45 canvases (pins length(rows))", %{
      paging: paging
    } do
      limit = 20

      [group] = Chat.list_canvas_groups([paging.id], limit: limit)

      assert length(group.rows) <= limit,
             "expected at most #{limit} rows, got #{length(group.rows)} — the per-space cap is gone"

      assert length(group.rows) == limit
    end

    test "total_count reports all 45 live canvases while rows are capped at 20 (pins total_count)",
         %{paging: paging} do
      [group] = Chat.list_canvas_groups([paging.id], limit: 20)

      # The whole point of the pair: the header number and the row number must
      # be allowed to disagree. A `total_count` derived from `length(rows)`
      # reads 20 here.
      assert group.total_count == @paging_space_size
      assert length(group.rows) == 20
      refute group.total_count == length(group.rows)
    end

    test "a smaller :limit shrinks rows but never total_count", %{paging: paging} do
      [three] = Chat.list_canvas_groups([paging.id], limit: 3)
      [ten] = Chat.list_canvas_groups([paging.id], limit: 10)

      assert length(three.rows) == 3
      assert length(ten.rows) == 10
      assert three.total_count == @paging_space_size
      assert ten.total_count == @paging_space_size
    end

    test "defaults to a limit of 20 when none is given", %{paging: paging} do
      [group] = Chat.list_canvas_groups([paging.id])

      assert length(group.rows) == 20
      assert group.total_count == @paging_space_size
    end

    test ":offset pages through the space without overlap and without gaps", %{paging: paging} do
      [first] = Chat.list_canvas_groups([paging.id], limit: 20, offset: 0)
      [second] = Chat.list_canvas_groups([paging.id], limit: 20, offset: 20)
      [third] = Chat.list_canvas_groups([paging.id], limit: 20, offset: 40)

      assert length(first.rows) == 20
      assert length(second.rows) == 20
      # 45 canvases: the last page is a partial one.
      assert length(third.rows) == 5

      ids = Enum.flat_map([first, second, third], fn g -> Enum.map(g.rows, & &1.id) end)

      assert length(Enum.uniq(ids)) == @paging_space_size
      assert MapSet.new(ids) == MapSet.new(Enum.map(paging_ids(paging.id), & &1))
    end

    test "an offset past the end yields no rows but still reports total_count", %{paging: paging} do
      [group] = Chat.list_canvas_groups([paging.id], limit: 20, offset: 500)

      assert group.rows == []
      assert group.total_count == @paging_space_size
    end

    test "the cap is applied PER SPACE, not across the whole result set", %{
      paging: paging,
      tiny: tiny
    } do
      groups = Chat.list_canvas_groups([paging.id, tiny.id], limit: 20)

      paging_group = group_for(groups, paging.id)
      tiny_group = group_for(groups, tiny.id)

      # A single global `limit: 20` would hand all 20 rows to whichever space
      # sorted first and leave the other empty.
      assert length(paging_group.rows) == 20
      assert length(tiny_group.rows) == 5
    end
  end

  # ── shape of a row ────────────────────────────────────────────────────────

  describe "list_canvas_groups/2 row shape" do
    test "rows carry no :document key at all", %{paging: paging} do
      [group] = Chat.list_canvas_groups([paging.id], limit: 5)

      assert length(group.rows) == 5

      for row <- group.rows do
        # Key ABSENCE, not `row.document == nil`: a `%Canvas{}` struct — or a
        # select that added the column back — carries the key, and a nil check
        # would pass against a struct whose document happened to be empty.
        refute Map.has_key?(row, :document),
               "explorer row selected :document — #{inspect(Map.keys(row))}"

        refute match?(%Canvas{}, row),
               "explorer row is a %Canvas{} struct, which always carries :document"
      end
    end

    test "rows carry exactly the seven documented keys", %{paging: paging} do
      [group] = Chat.list_canvas_groups([paging.id], limit: 1)
      [row] = group.rows

      assert Enum.sort(Map.keys(row)) ==
               Enum.sort([
                 :id,
                 :title,
                 :space_id,
                 :updated_at,
                 :inserted_at,
                 :created_by_display_name,
                 :cloned_from
               ])
    end

    test "the selected columns carry their real values", %{
      lineage: lineage,
      child_of_live: child,
      live_parent: parent
    } do
      [group] = Chat.list_canvas_groups([lineage.id], limit: 20)
      row = Enum.find(group.rows, &(&1.id == child.id))

      assert row.title == "Child of live"
      assert row.space_id == lineage.id
      assert row.cloned_from == parent.id
      assert row.created_by_display_name == "Author of Child of live"
      assert %DateTime{} = row.inserted_at
      assert %DateTime{} = row.updated_at
    end
  end

  # ── ordering ──────────────────────────────────────────────────────────────

  describe "list_canvas_groups/2 ordering" do
    test "rows are ordered by lower(title), so the first page is the alphabetical head", %{
      paging: paging
    } do
      [group] = Chat.list_canvas_groups([paging.id], limit: 20)

      # Fixture inserted Doc 45 .. Doc 01. Insertion order would start "Doc 45".
      assert titles(group.rows) ==
               Enum.map(1..20, &"Doc #{String.pad_leading(to_string(&1), 2, "0")}")
    end

    test "title ordering is case-insensitive", %{tiny: tiny} do
      [group] = Chat.list_canvas_groups([tiny.id], limit: 20)

      # Postgres's default collation on a bare `asc: title` files uppercase
      # first: ["Middle", "Same title", "Same title", "Zebra", "apple"].
      assert titles(group.rows) == ["apple", "Middle", "Same title", "Same title", "Zebra"]
    end

    test "canvases sharing a title break the tie on inserted_at, oldest first", %{
      tiny: tiny,
      tie_first: tie_first,
      tie_second: tie_second
    } do
      [group] = Chat.list_canvas_groups([tiny.id], limit: 20)

      tied = Enum.filter(group.rows, &(&1.title == "Same title"))

      assert Enum.map(tied, & &1.id) == [tie_first.id, tie_second.id]
      assert DateTime.compare(tie_first.inserted_at, tie_second.inserted_at) == :lt
    end

    test "the same page is returned on every visit", %{paging: paging} do
      pages =
        for _ <- 1..4 do
          [group] = Chat.list_canvas_groups([paging.id], limit: 7, offset: 14)
          Enum.map(group.rows, & &1.id)
        end

      assert length(Enum.uniq(pages)) == 1
    end

    test "groups are ordered alphabetically by space name, case-insensitively", %{
      paging: paging,
      tiny: tiny,
      lineage: lineage,
      empty: empty
    } do
      # Requested in a scrambled order so the result cannot be echoing the
      # input sequence.
      groups = Chat.list_canvas_groups([lineage.id, paging.id, empty.id, tiny.id], limit: 5)

      assert Enum.map(groups, & &1.space_id) == [tiny.id, paging.id, empty.id, lineage.id]

      names = Enum.map(groups, & &1.space_name)
      assert names == Enum.sort_by(names, &String.downcase/1)
    end

    # ── the `:order` option (task 01a0740d stage 3) ───────────────────────
    #
    # WHY IT EXISTS. The canvases drawer keeps a sort `<select>` offering four
    # orderings. The explorer holds ONE bounded page of each group, so sorting
    # in the caller would order 20 rows out of 45 and present the answer as the
    # group's order — a different and wrong answer, not a slower one. Left
    # unwired, the control would have been live and moved nothing.
    #
    # ANTI-VACUITY. Each of these asserts the sequence is DIFFERENT from the
    # default's, not merely that some rows came back. An `:order` that were
    # silently ignored returns the alphabetical page every time, and a test
    # that only checked "20 rows" would pass against exactly that.
    test "an unrecognised :order falls back to the alphabetical default rather than raising", %{
      paging: paging
    } do
      [default] = Chat.list_canvas_groups([paging.id], limit: 5)
      [nonsense] = Chat.list_canvas_groups([paging.id], limit: 5, order: :not_a_sort)

      assert titles(nonsense.rows) == titles(default.rows)
      assert titles(default.rows) == ["Doc 01", "Doc 02", "Doc 03", "Doc 04", "Doc 05"]
    end

    test "order: :inserted_desc pages the NEWEST rows, which the default page does not", %{
      paging: paging
    } do
      [default] = Chat.list_canvas_groups([paging.id], limit: 5)
      [newest] = Chat.list_canvas_groups([paging.id], limit: 5, order: :inserted_desc)

      # The fixture inserted Doc 45 first, descending to Doc 01 last, so
      # newest-first is the alphabetical HEAD reversed... which is exactly why
      # the assertion names the titles rather than trusting the direction.
      assert titles(newest.rows) == ["Doc 01", "Doc 02", "Doc 03", "Doc 04", "Doc 05"]

      # ...and that coincidence is the trap. `:inserted_asc` is the sequence
      # that cannot be confused with the default, so it carries the real proof.
      [oldest] = Chat.list_canvas_groups([paging.id], limit: 5, order: :inserted_asc)

      assert titles(oldest.rows) == ["Doc 45", "Doc 44", "Doc 43", "Doc 42", "Doc 41"]

      refute titles(oldest.rows) == titles(default.rows),
             ":order was ignored — the page is the alphabetical default"
    end

    test "order: :updated_desc leads with the most recently edited row", %{tiny: tiny} do
      # Touch ONE canvas so its `updated_at` is unambiguously the newest, then
      # ask for recency order. The default (alphabetical) puts "apple" first.
      [default] = Chat.list_canvas_groups([tiny.id], limit: 20)
      assert List.first(titles(default.rows)) == "apple"

      zebra = Enum.find(default.rows, &(&1.title == "Zebra"))

      {1, _} =
        Repo.update_all(
          from(c in Canvas, where: c.id == ^zebra.id),
          set: [updated_at: DateTime.add(DateTime.utc_now(), 3600, :second)]
        )

      [recent] = Chat.list_canvas_groups([tiny.id], limit: 20, order: :updated_desc)

      assert List.first(titles(recent.rows)) == "Zebra"

      refute titles(recent.rows) == titles(default.rows),
             ":order was ignored — recency order matched the alphabetical page"
    end

    test "every ordering still pages deterministically across repeated reads", %{paging: paging} do
      for order <- [:title_asc, :updated_desc, :inserted_desc, :inserted_asc] do
        pages =
          for _ <- 1..4 do
            [group] = Chat.list_canvas_groups([paging.id], limit: 7, offset: 14, order: order)
            Enum.map(group.rows, & &1.id)
          end

        assert length(Enum.uniq(pages)) == 1,
               "order #{inspect(order)} returned a different page across reads — " <>
                 "the tiebreaker is missing"
      end
    end
  end

  # ── membership ────────────────────────────────────────────────────────────

  describe "list_canvas_groups/2 membership" do
    test "soft-deleted canvases are absent from rows and uncounted", %{tiny: tiny, gone: gone} do
      [group] = Chat.list_canvas_groups([tiny.id], limit: 20)

      refute gone.id in Enum.map(group.rows, & &1.id)
      # 6 canvases created in this space, 1 soft-deleted.
      assert group.total_count == 5
      assert length(group.rows) == 5
    end

    test "a space with no live canvases is kept, as an empty group", %{empty: empty} do
      [group] = Chat.list_canvas_groups([empty.id])

      assert group.space_id == empty.id
      assert group.total_count == 0
      assert group.rows == []
    end

    test "each row belongs to its own group's space", %{
      paging: paging,
      tiny: tiny,
      lineage: lineage
    } do
      groups = Chat.list_canvas_groups([paging.id, tiny.id, lineage.id], limit: 50)

      for group <- groups, row <- group.rows do
        assert row.space_id == group.space_id
      end
    end

    test "an unknown space id is dropped rather than returned as an empty group", %{tiny: tiny} do
      groups = Chat.list_canvas_groups([tiny.id, Ecto.UUID.generate()])

      assert Enum.map(groups, & &1.space_id) == [tiny.id]
    end

    test "an empty space_ids list short-circuits" do
      assert Chat.list_canvas_groups([]) == []
      assert Chat.list_canvas_groups([], limit: 5) == []
    end
  end

  # ── clone lineage ─────────────────────────────────────────────────────────

  describe "canvas_parent_titles/1" do
    test "a live parent resolves to its title", %{live_parent: parent} do
      assert Chat.canvas_parent_titles([parent.id]) == %{parent.id => "Live parent"}
    end

    test "a soft-deleted parent resolves to the :deleted marker, not nil", %{
      doomed_parent: doomed
    } do
      resolved = Chat.canvas_parent_titles([doomed.id])

      # `:deleted` SPECIFICALLY. `assert Map.has_key?(resolved, doomed.id)`
      # would pass against a nil, and the UI would then be unable to tell
      # "cloned from a deleted canvas" from "not a clone" — which is the whole
      # reason the marker exists.
      assert resolved[doomed.id] == :deleted
      refute resolved[doomed.id] == nil
      refute resolved[doomed.id] == "Doomed parent"
    end

    test "a parent id naming no row at all resolves to :deleted" do
      orphan = Ecto.UUID.generate()

      assert Chat.canvas_parent_titles([orphan]) == %{orphan => :deleted}
    end

    test "a malformed parent id resolves to :deleted rather than raising" do
      assert Chat.canvas_parent_titles(["not-a-uuid"]) == %{"not-a-uuid" => :deleted}

      # Mixed batch: the malformed id must not take the valid one down with it.
      resolved = Chat.canvas_parent_titles(["not-a-uuid", Ecto.UUID.generate()])
      assert map_size(resolved) == 2
      assert Enum.all?(Map.values(resolved), &(&1 == :deleted))
    end

    test "nil entries are absent from the map, which is how 'not a clone' reads", %{
      live_parent: parent
    } do
      resolved = Chat.canvas_parent_titles([nil, parent.id, nil])

      assert Map.keys(resolved) == [parent.id]
      refute Map.has_key?(resolved, nil)
    end

    test "an empty batch is an empty map" do
      assert Chat.canvas_parent_titles([]) == %{}
      assert Chat.canvas_parent_titles([nil, nil]) == %{}
    end

    test "live and deleted parents are distinguishable in one batch", %{
      live_parent: live,
      doomed_parent: doomed
    } do
      resolved = Chat.canvas_parent_titles([live.id, doomed.id])

      assert resolved[live.id] == "Live parent"
      assert resolved[doomed.id] == :deleted
    end

    test "the whole batch is resolved in ONE query, not one per id", %{
      live_parent: live,
      doomed_parent: doomed
    } do
      ids = [live.id, doomed.id, Ecto.UUID.generate(), Ecto.UUID.generate()]

      queries = capture_canvas_queries(ids, fn -> Chat.canvas_parent_titles(ids) end)

      assert length(queries) == 1,
             "expected 1 chat_canvases query for a 4-id batch, got #{length(queries)}:\n" <>
               Enum.join(queries, "\n")
    end

    test "the query telemetry event is the one Repo actually emits" do
      # Keeps the N+1 guard above from going vacuous if the prefix drifts: a
      # handler on a dead event name captures zero queries, and `length == 1`
      # would then fail loudly rather than silently — but a future rewrite to
      # `>= 1` would pass on nothing. Pinned here explicitly.
      assert Repo.config()[:telemetry_prefix] ++ [:query] == [:platform, :repo, :query]
    end
  end

  # `[:platform, :repo, :query]` handlers are GLOBAL — sibling `async: true`
  # files emit into them too. So the filter is doubly narrow: the statement has
  # to touch `chat_canvases`, and its params have to include one of the ids
  # this test is asking about.
  defp capture_canvas_queries(ids, fun) do
    test_pid = self()
    handler_id = "canvas-explorer-queries-#{System.unique_integer([:positive])}"
    wanted = MapSet.new(Enum.map(ids, &normalize_uuid/1))

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          sql = Map.get(meta, :query) || ""
          params = Map.get(meta, :params) || []

          if String.contains?(sql, "chat_canvases") and
               Enum.any?(params, &param_in?(&1, wanted)) do
            send(test_pid, {:canvas_query, handler_id, sql})
          end
        end,
        nil
      )

    try do
      fun.()
      drain_queries(handler_id, [])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp param_in?(param, wanted) when is_list(param),
    do: Enum.any?(param, &param_in?(&1, wanted))

  defp param_in?(param, wanted) do
    case normalize_uuid(param) do
      nil -> false
      uuid -> MapSet.member?(wanted, uuid)
    end
  end

  defp normalize_uuid(<<_::binary-size(16)>> = raw) do
    case Ecto.UUID.load(raw) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp normalize_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp normalize_uuid(_), do: nil

  defp drain_queries(handler_id, acc) do
    receive do
      {:canvas_query, ^handler_id, sql} -> drain_queries(handler_id, [sql | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp paging_ids(space_id) do
    Repo.all(
      from(c in Canvas, where: c.space_id == ^space_id and is_nil(c.deleted_at), select: c.id)
    )
  end
end
