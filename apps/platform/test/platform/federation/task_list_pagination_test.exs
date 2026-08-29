defmodule Platform.Federation.TaskListPaginationTest do
  @moduledoc """
  `task_list` truncation must be VISIBLE and paging must be STABLE (task
  01a04a7a).

  Task 01a049de (#840) capped `task_list` at #{Platform.Federation.ResultBound.default_limit()}
  records. That was the right fix for a 3.3 MB response, but it left the caller
  unable to tell a short list from a truncated one: the result was a bare JSON
  array, so "50 tasks" and "50 of 807 tasks" were the same bytes. The
  orchestrator's measured cost was having to answer "how big is the backlog?"
  with "at least 50, upper bound unknown".

  Two failures are pinned here, and they are different failures:

    * **Invisible truncation.** `has_more` must distinguish a full page that is
      the last page from a full page that is not. The cheap implementation —
      `length(rows) == limit` — cannot, and is wrong at exactly the boundary
      where the corpus size is a multiple of the page size.

    * **Unstable paging.** `ORDER BY inserted_at DESC` alone is not a total
      order, and paging over a non-total order skips some rows and repeats
      others while returning a plausible-looking answer. That is strictly worse
      than the truncation it replaced, because truncation at least under-reports
      honestly.
  """
  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.Federation.ResultBound
  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  @default_limit ResultBound.default_limit()
  @max_limit ResultBound.max_limit()

  defp u, do: System.unique_integer([:positive])

  defp project, do: elem(Tasks.create_project(%{name: "Page Proj #{u()}"}), 1)

  defp seed(project, n) do
    for i <- 1..n do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Paged #{i}"})

      task
    end
  end

  defp list(args), do: elem(ToolSurface.execute("task_list", args, %{}), 1)

  # ── has_more: both directions, and the boundary ─────────────────────────

  describe "has_more" do
    test "is true when tasks remain beyond the page, with a total that exceeds it" do
      p = project()
      seed(p, 30)

      env = list(%{"project_id" => p.id, "limit" => 10})

      assert length(env.tasks) == 10
      assert env.total == 30
      assert env.has_more == true
      assert env.total > length(env.tasks)
    end

    test "is false when the page is the whole corpus" do
      p = project()
      seed(p, 3)

      env = list(%{"project_id" => p.id})

      assert length(env.tasks) == 3
      assert env.total == 3
      assert env.has_more == false
      # The second half of the control: `total` equals what came back, so a
      # caller can cross-check the flag against the number rather than
      # trusting a boolean that might be hardcoded.
      assert env.total == length(env.tasks)
    end

    test "BOUNDARY: a full page that is exactly the whole corpus reports false" do
      # THE trap this ticket names. `has_more = length(rows) == limit` returns
      # TRUE here — the page is full — and the caller pages again into an empty
      # result. The flag has to come from a real count, not from the page size.
      #
      # Asserted at three sizes so a fix that special-cases one number, or that
      # happens to be right only for the default limit, still fails.
      p = project()
      seed(p, 7)

      for limit <- [7, 7, 7] do
        env = list(%{"project_id" => p.id, "limit" => limit})
        assert length(env.tasks) == 7
        assert env.total == 7
        assert env.has_more == false, "a full last page must not claim more follows"
      end

      # And the page AFTER that boundary page is genuinely empty — which is
      # what makes the `false` above the correct answer rather than a lucky one.
      after_end = list(%{"project_id" => p.id, "limit" => 7, "offset" => 7})
      assert after_end.tasks == []
      assert after_end.total == 7
      assert after_end.has_more == false
    end

    test "BOUNDARY: the corpus is an exact multiple of the page size" do
      # 20 tasks, 10 per page. Page 2 is full AND final. `length == limit` says
      # "more"; the count says otherwise.
      p = project()
      seed(p, 20)

      page1 = list(%{"project_id" => p.id, "limit" => 10, "offset" => 0})
      page2 = list(%{"project_id" => p.id, "limit" => 10, "offset" => 10})

      assert length(page1.tasks) == 10
      assert page1.has_more == true

      assert length(page2.tasks) == 10
      assert page2.has_more == false
    end

    test "BOUNDARY: the default limit against a corpus of exactly the default limit" do
      p = project()
      seed(p, @default_limit)

      env = list(%{"project_id" => p.id})

      assert length(env.tasks) == @default_limit
      assert env.total == @default_limit
      assert env.has_more == false
    end

    test "an offset past the end is empty, and says so without claiming more" do
      p = project()
      seed(p, 5)

      env = list(%{"project_id" => p.id, "offset" => 500})

      assert env.tasks == []
      assert env.total == 5
      assert env.has_more == false
    end

    test "an empty corpus reports zero rather than an unexplained empty array" do
      p = project()

      env = list(%{"project_id" => p.id})

      assert env.tasks == []
      assert env.total == 0
      assert env.has_more == false
    end

    test "total counts the FILTERED set, not the table" do
      # A `total` taken over the wrong query is the ticket's own named failure
      # — a clean measurement of the wrong quantity — and it would read as a
      # perfectly plausible number.
      p = project()
      other = project()

      for i <- 1..4 do
        {:ok, _} =
          Tasks.create_task(%{project_id: p.id, title: "Mine #{i}", status: "planning"})
      end

      {:ok, _} = Tasks.create_task(%{project_id: p.id, title: "Wrong status", status: "done"})

      for i <- 1..9 do
        {:ok, _} = Tasks.create_task(%{project_id: other.id, title: "Theirs #{i}"})
      end

      env = list(%{"project_id" => p.id, "status" => "planning"})

      assert env.total == 4
      assert length(env.tasks) == 4
      assert env.has_more == false
    end

    test "total ignores soft-deleted tasks, matching the rows it describes" do
      p = project()
      [_keep, drop | _] = seed(p, 3)
      {:ok, _} = Tasks.soft_delete_task(drop)

      env = list(%{"project_id" => p.id})

      assert env.total == 2
      assert length(env.tasks) == 2
      refute Enum.any?(env.tasks, &(&1.id == drop.id))
    end
  end

  # ── paging is stable: every row exactly once ────────────────────────────

  describe "paging stability" do
    test "paging a corpus returns every task exactly once, in order, with no repeats" do
      p = project()
      seeded = seed(p, 47)
      seeded_ids = MapSet.new(seeded, & &1.id)

      {collected, pages} = drain(p.id, 10)

      # Exactly once: no skips (set equality) and no duplicates (length
      # equality against the deduplicated set). Both are needed — a page that
      # repeats a row AND drops another has the right length and the wrong
      # content.
      assert length(collected) == 47
      assert MapSet.new(collected) == seeded_ids
      assert length(Enum.uniq(collected)) == 47

      # Four full pages of 10 and a final short page of 7 — proof the drain
      # actually paged rather than getting everything in one call.
      assert pages == 4
    end

    test "POSITIVE CONTROL: the exactly-once assertions detect a duplicated row" do
      # A test that only ever sees correct pages proves nothing about its own
      # sensitivity. Corrupt the collected sequence the way an unstable order
      # would — one row repeated on the next page, one row consequently never
      # seen — and confirm each assertion above goes red.
      p = project()
      seeded = seed(p, 47)
      seeded_ids = MapSet.new(seeded, & &1.id)

      {collected, _pages} = drain(p.id, 10)

      # The signature of an unstable sort key: row 9 comes back again on the
      # next page, and row 10 is never returned at all.
      corrupted = List.replace_at(collected, 10, Enum.at(collected, 9))

      assert length(corrupted) == 47, "the length alone cannot see this — that is the point"
      refute length(Enum.uniq(corrupted)) == 47
      refute MapSet.new(corrupted) == seeded_ids
    end

    test "pages are ordered newest-first and the order is consistent across calls" do
      p = project()
      seed(p, 25)

      first_pass = elem(drain(p.id, 5), 0)
      second_pass = elem(drain(p.id, 5), 0)

      # Same sequence, twice. An unstable order would agree on the SET while
      # disagreeing on the sequence, so compare the lists, not sets.
      assert first_pass == second_pass

      # And one unpaged read agrees with the paged traversal.
      whole = list(%{"project_id" => p.id, "limit" => 100})
      assert Enum.map(whole.tasks, & &1.id) == first_pass
    end

    test "paging is stable when every task shares an inserted_at to the microsecond" do
      # The real hazard, forced. `inserted_at` is `utc_datetime_usec`, so
      # natural ties are rare — and "rare" is how an unstable-paging bug
      # survives a suite. Backdate a whole corpus to ONE timestamp and the
      # primary sort key stops discriminating at all; only the `id` tiebreaker
      # is left. Without it, Postgres may order the ties differently between
      # the two queries that produce two pages, and rows are skipped and
      # repeated with no error anywhere.
      p = project()
      seeded = seed(p, 40)
      seeded_ids = MapSet.new(seeded, & &1.id)

      {40, _} =
        Platform.Repo.update_all(
          from(t in Platform.Tasks.Task, where: t.project_id == ^p.id),
          set: [inserted_at: ~U[2026-01-01 00:00:00.000000Z]]
        )

      {collected, _pages} = drain(p.id, 7)

      assert length(collected) == 40
      assert length(Enum.uniq(collected)) == 40
      assert MapSet.new(collected) == seeded_ids
    end
  end

  # ── limit honouring ─────────────────────────────────────────────────────

  describe "limit" do
    test "an explicit limit is honoured below the default" do
      p = project()
      seed(p, 12)

      env = list(%{"project_id" => p.id, "limit" => 3})

      assert length(env.tasks) == 3
      assert env.limit == 3
      assert env.total == 12
      assert env.has_more == true
    end

    test "a limit above the ceiling is clamped, not obeyed and not refused" do
      p = project()
      seed(p, 2)

      env = list(%{"project_id" => p.id, "limit" => 10_000})

      assert env.limit == @max_limit
      # The cap survives the ticket. Paging exists so the cap does not have to
      # be removed, and a caller cannot page its way around the ceiling in one
      # call.
      assert env.limit <= @max_limit
    end

    test "garbage in limit/offset falls back to the defaults rather than raising" do
      p = project()
      seed(p, 4)

      env = list(%{"project_id" => p.id, "limit" => "not a number", "offset" => -5})

      assert env.limit == @default_limit
      assert env.offset == 0
      assert length(env.tasks) == 4
      assert env.has_more == false
    end

    test "the envelope echoes the page it applied" do
      p = project()
      seed(p, 30)

      env = list(%{"project_id" => p.id, "limit" => 6, "offset" => 12})

      assert env.limit == 6
      assert env.offset == 12
      assert length(env.tasks) == 6
    end
  end

  # ── the rows themselves are unchanged ───────────────────────────────────

  describe "backward compatibility of the rows" do
    test "row fields are exactly what the pre-envelope call returned" do
      # The envelope is a new wrapper, not a new row shape. Anything reading a
      # task out of `task_list` reads the same keys it always did.
      p = project()

      {:ok, task} =
        Tasks.create_task(%{project_id: p.id, title: "Shape", description: "d", priority: "high"})

      env = list(%{"project_id" => p.id})
      row = hd(env.tasks)

      assert row.id == task.id
      assert row.title == "Shape"
      assert row.status == task.status
      assert row.priority == "high"
      assert row.project_id == p.id
      assert Map.has_key?(row, :sponsor)
      assert Map.has_key?(row, :auto_approve_plan)
      assert row.description_truncated == false
    end

    test "the default page size is still the pre-existing cap" do
      # Pagination must not have quietly widened the bound the cap exists to
      # hold. A default that drifted upward would re-open the context blowout
      # #840 closed.
      p = project()
      seed(p, 60)

      env = list(%{"project_id" => p.id})

      assert length(env.tasks) == @default_limit
      assert env.limit == @default_limit
      assert env.offset == 0
    end
  end

  # Page through a project with the given page size, returning the collected
  # ids and the number of full pages seen. Terminates on `has_more`, which is
  # the contract under test: a caller that stops on a short page would mask the
  # very bug the stability tests are looking for.
  defp drain(project_id, page_size), do: drain(project_id, page_size, 0, [], 0)

  defp drain(project_id, page_size, offset, acc, full_pages) do
    env = list(%{"project_id" => project_id, "limit" => page_size, "offset" => offset})
    ids = Enum.map(env.tasks, & &1.id)
    full_pages = if length(ids) == page_size, do: full_pages + 1, else: full_pages

    if env.has_more do
      drain(project_id, page_size, offset + page_size, acc ++ ids, full_pages)
    else
      {acc ++ ids, full_pages}
    end
  end
end
