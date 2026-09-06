defmodule Platform.Chat.CanvasSearchBackfillTest do
  @moduledoc """
  Task `01a07402` stage 3: canvases saved before stage 2's write path existed
  get `chat_canvas_search` rows.

  ## Why every canvas here is inserted with `Repo.insert_all/2`

  This is the whole point of the file, so it is worth being blunt about.
  Creating a canvas through `Platform.Chat` runs stage 2's wiring, which
  writes an index row in the same transaction. A test built on
  `Chat.create_canvas/1` would find an index row present after calling the
  backfill **whether or not the backfill exists** — it would be asserting
  that stage 2 works, in a file named for stage 3, and it would stay green
  while all 409 historical canvases remained unfindable. CI cannot see that
  difference; only the choice of fixture can.

  So `raw_canvas/2` writes straight to the `"chat_canvases"` table, bypassing
  `Platform.Chat` entirely, and every test asserts the index row is absent
  first. `unindexed guard` below fails if that bypass ever stops bypassing.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasSearchBackfill
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Repo

  setup do
    {:ok, space} =
      Chat.create_space(%{
        name: "CSB #{System.unique_integer([:positive])}",
        slug: "csb-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Backfill Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp markdown_doc(text) do
    %{"root" => %{"type" => "markdown", "props" => %{"content" => text}}}
  end

  # The canonical shape `Canvas.changeset/2` accepts, for the handful of
  # canvases that deliberately go through `Platform.Chat` as a control.
  # `markdown_doc/1` above is looser on purpose: `Repo.insert_all/2` runs no
  # changeset, which is exactly how the historical rows this stage indexes
  # got there.
  defp canonical_doc(phrase) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{"id" => "t1", "type" => "text", "props" => %{"value" => phrase}, "children" => []}
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  # Straight into the table. No changeset, no context function, no index row.
  # This is what a canvas written before stage 2 shipped looks like.
  defp raw_canvas(space, opts) do
    id = Keyword.get_lazy(opts, :id, &Platform.Types.UUIDv7.generate/0)

    now =
      DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_naive()

    row = %{
      id: Ecto.UUID.dump!(id),
      space_id: Ecto.UUID.dump!(space.id),
      title: Keyword.get(opts, :title, "legacy canvas"),
      document: Keyword.get(opts, :document, markdown_doc("legacy body")),
      metadata: %{},
      inserted_at: now,
      updated_at: now,
      deleted_at: opts |> Keyword.get(:deleted_at) |> naive_or_nil()
    }

    {1, _} = Repo.insert_all("chat_canvases", [row])

    Repo.get!(Canvas, id)
  end

  defp naive_or_nil(nil), do: nil

  defp naive_or_nil(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:microsecond) |> DateTime.to_naive()

  defp index_row(canvas_id), do: Repo.get(CanvasSearchIndex, canvas_id)

  defp index_row_count(canvas_id) do
    Repo.aggregate(
      from(r in CanvasSearchIndex, where: r.canvas_id == ^canvas_id),
      :count,
      :canvas_id
    )
  end

  # A body Postgres will refuse: `body_search_vector` is a STORED GENERATED
  # `to_tsvector(...)` and a tsvector caps at 1,048,575 bytes. Distinct tokens
  # are required — repeating one word produces a tiny vector no matter how
  # long the text is. This is a real hazard for a corpus of historical
  # canvases, not a synthetic one: it is just a big canvas.
  defp oversized_body do
    Enum.map_join(1..130_000, " ", fn i -> "w#{i}" end)
  end

  # ── the test this stage exists for ───────────────────────────────────────

  describe "a canvas that predates the write path" do
    test "has no index row until the backfill runs, and then has one carrying its body",
         %{space: space} do
      canvas = raw_canvas(space, document: markdown_doc("mnemonic parsnip protocol"))

      # Before: provably unindexed. If this ever passes trivially it means
      # `raw_canvas/2` stopped bypassing `Platform.Chat` and the test below
      # would be asserting stage 2, not stage 3.
      assert index_row_count(canvas.id) == 0

      assert {:ok, report} = CanvasSearchBackfill.run([])

      assert index_row_count(canvas.id) == 1
      assert index_row(canvas.id).body_text =~ "mnemonic parsnip protocol"
      assert report.processed >= 1
      assert report.failed == 0
      assert report.remaining == 0
    end

    test "unindexed guard: raw_canvas/2 really does bypass the stage 2 write path",
         %{space: space, participant: participant} do
      # The negative control for the fixture itself. A canvas made through
      # `Platform.Chat` is indexed on save; one made by `raw_canvas/2` is not.
      # If these two ever agree, every assertion in this file is vacuous.
      raw = raw_canvas(space, document: markdown_doc("raw body"))

      {:ok, via_context} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "context canvas",
          "document" => canonical_doc("context body")
        })

      assert index_row_count(raw.id) == 0
      assert index_row_count(via_context.id) == 1
    end

    test "the backfill leaves the already-indexed canvas alone", %{
      space: space,
      participant: participant
    } do
      {:ok, via_context} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "context canvas",
          "document" => canonical_doc("context body")
        })

      before_row = index_row(via_context.id)

      assert {:ok, _} = CanvasSearchBackfill.run([])

      after_row = index_row(via_context.id)
      assert after_row.indexed_at == before_row.indexed_at
      assert after_row.body_text == before_row.body_text
    end
  end

  # ── idempotence ──────────────────────────────────────────────────────────

  describe "idempotence" do
    test "a second full run changes nothing", %{space: space} do
      canvas = raw_canvas(space, document: markdown_doc("stable body text"))

      assert {:ok, first} = CanvasSearchBackfill.run([])
      assert first.processed >= 1

      row_after_first = index_row(canvas.id)
      total_after_first = Repo.aggregate(CanvasSearchIndex, :count, :canvas_id)

      assert {:ok, second} = CanvasSearchBackfill.run([])

      assert second.processed == 0
      assert second.failed == 0
      assert second.remaining == 0

      row_after_second = index_row(canvas.id)

      assert row_after_second.body_text == row_after_first.body_text
      assert row_after_second.indexed_at == row_after_first.indexed_at
      assert Repo.aggregate(CanvasSearchIndex, :count, :canvas_id) == total_after_first
    end
  end

  # ── batching and termination ─────────────────────────────────────────────

  describe "batching" do
    # NOTE ON THE SPEC: the stage description asks for `run(batch: n)` on
    # `batch + 1` rows to report `remaining > 0`. It cannot: `run/1` loops to
    # completion (the boot-time one-shot has to converge on its own), so a
    # second batch picks up the spare row and `remaining` lands on 0. `:limit`
    # is the option that stops a run short, so that is what is driven here.
    test "a run stopped short reports the rows it did not reach", %{space: space} do
      batch = 3
      for i <- 1..(batch + 1), do: raw_canvas(space, document: markdown_doc("row #{i}"))

      assert {:ok, report} = CanvasSearchBackfill.run(batch: batch, limit: batch)

      assert report.processed == batch
      assert report.remaining > 0
      assert report.remaining == 1

      # And the honest number is measured, not assumed: finishing the job
      # takes it to zero.
      assert {:ok, finished} = CanvasSearchBackfill.run(batch: batch)
      assert finished.processed == 1
      assert finished.remaining == 0
    end

    test "a batch smaller than the corpus still indexes every row", %{space: space} do
      canvases = for i <- 1..7, do: raw_canvas(space, document: markdown_doc("body #{i}"))

      assert {:ok, report} = CanvasSearchBackfill.run(batch: 2)

      assert report.processed == 7
      assert report.batches == 4
      assert report.remaining == 0

      for c <- canvases, do: assert(index_row_count(c.id) == 1)
    end

    test "a batch of zero is refused rather than reporting a sweep it never made" do
      assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
        CanvasSearchBackfill.run(batch: 0)
      end
    end
  end

  describe "termination" do
    # Failure mode 2. The cursor is driven by the ids seen, not by the index
    # rows written, so a batch in which EVERY row fails must still advance
    # past those rows. If it did not, `run/1` would re-fetch the same failing
    # batch forever and the boot-time Task would hang the supervision tree.
    #
    # A spin shows up here as an ExUnit timeout rather than a hang, and the
    # assertion on `failed` is the positive form: it can only reach 3 if the
    # loop crossed three single-row batches that each produced nothing.
    @tag timeout: 120_000
    test "the cursor advances across batches that write no index rows", %{space: space} do
      poison = oversized_body()
      for _ <- 1..3, do: raw_canvas(space, document: markdown_doc(poison))

      log =
        capture_log(fn ->
          assert {:ok, report} = CanvasSearchBackfill.run(batch: 1)

          assert report.processed == 0
          assert report.failed == 3
          assert report.batches == 3
          assert report.remaining == 3
        end)

      assert log =~ "left unindexed"
    end
  end

  # ── a row whose write fails ──────────────────────────────────────────────

  describe "a row Postgres refuses" do
    # Failure mode 1, and the choice made: SKIP the row, log it, and leave it
    # counted in `remaining` — never crash the run, and never report a clean
    # sweep over it.
    test "is skipped without stopping the run, and stays visible in the report",
         %{space: space} do
      good_before = raw_canvas(space, document: markdown_doc("readable alpha"))
      poison = raw_canvas(space, document: markdown_doc(oversized_body()))
      good_after = raw_canvas(space, document: markdown_doc("readable omega"))

      log =
        capture_log(fn ->
          assert {:ok, report} = CanvasSearchBackfill.run([])

          # The two healthy rows are indexed. One bad canvas does not cost
          # its neighbours their index.
          assert report.processed == 2
          assert report.failed == 1
          assert report.failed_ids == [poison.id]

          # And the run does NOT report a clean sweep. `remaining` is counted
          # from the database after the loop, so the skipped row is still
          # there in the number — this is what stops "skip and advance the
          # cursor" from becoming "silently unindexed forever".
          assert report.remaining == 1
        end)

      assert log =~ poison.id
      assert log =~ "left unindexed"

      assert index_row_count(good_before.id) == 1
      assert index_row_count(good_after.id) == 1
      assert index_row_count(poison.id) == 0
    end

    test "comes back round on the next run rather than being marked done",
         %{space: space} do
      poison = raw_canvas(space, document: markdown_doc(oversized_body()))

      capture_log(fn ->
        assert {:ok, _} = CanvasSearchBackfill.run([])
        assert {:ok, second} = CanvasSearchBackfill.run([])

        # Still a candidate — re-running is the retry, there is no queue.
        assert second.failed == 1
        assert second.failed_ids == [poison.id]
        assert second.remaining == 1
      end)
    end

    test "index_one/1 returns an error tuple instead of raising", %{space: space} do
      canvas = raw_canvas(space, document: markdown_doc("about to vanish"))

      # A canvas hard-deleted between the batch query and the write — the FK
      # on `chat_canvas_search.canvas_id` refuses the row. The point is the
      # return type: the decision to skip is one testable function.
      Repo.delete_all(from(c in Canvas, where: c.id == ^canvas.id))

      assert {:error, %Postgrex.Error{}} = CanvasSearchBackfill.index_one(canvas)
    end

    test "index_one/1 indexes one row without the loop", %{space: space} do
      canvas = raw_canvas(space, document: markdown_doc("driven directly"))

      assert index_row_count(canvas.id) == 0
      assert :ok = CanvasSearchBackfill.index_one(canvas)
      assert index_row(canvas.id).body_text =~ "driven directly"
    end
  end

  describe "a structurally invalid document" do
    # The stage description expected this to raise. It does not:
    # `Canvas.SearchText.extract/1` is total by construction — it delegates to
    # `MarkdownExporter.export_markdown/1`, whose fallthrough clause returns
    # `{:error, :invalid_document}`, which `extract/1` maps to `""`. So the
    # row is indexed with an empty body rather than skipped, and the
    # "unindexed forever" hazard never arises for it. Pinned here so a future
    # extractor that starts raising on garbage is a red test, not a silent
    # switch to the skip path.
    test "is indexed as empty text rather than raising or being skipped", %{space: space} do
      canvas = raw_canvas(space, document: %{"nodes" => "not-a-list"})

      assert {:ok, report} = CanvasSearchBackfill.run([])

      assert report.failed == 0
      assert report.processed >= 1
      assert index_row_count(canvas.id) == 1
      assert index_row(canvas.id).body_text == ""
    end
  end

  # ── soft deletes ─────────────────────────────────────────────────────────

  describe "soft-deleted canvases" do
    test "are indexed too, so a restore does not have to re-index", %{space: space} do
      deleted =
        raw_canvas(space,
          document: markdown_doc("deleted but searchable later"),
          deleted_at: DateTime.utc_now()
        )

      assert index_row_count(deleted.id) == 0

      assert {:ok, report} = CanvasSearchBackfill.run([])

      assert report.remaining == 0
      assert index_row_count(deleted.id) == 1
      assert index_row(deleted.id).body_text =~ "deleted but searchable later"
    end
  end

  # ── unindexed_count/1 ────────────────────────────────────────────────────

  describe "CanvasSearchIndex.unindexed_count/1" do
    test "counts unindexed canvases in the given spaces", %{space: space} do
      raw_canvas(space, document: markdown_doc("one"))
      raw_canvas(space, document: markdown_doc("two"))

      assert CanvasSearchIndex.unindexed_count([space.id]) == 2

      assert {:ok, _} = CanvasSearchBackfill.run([])

      assert CanvasSearchIndex.unindexed_count([space.id]) == 0
    end

    test "excludes soft-deleted canvases", %{space: space} do
      raw_canvas(space, document: markdown_doc("live"))

      raw_canvas(space,
        document: markdown_doc("gone"),
        deleted_at: DateTime.utc_now()
      )

      # Two unindexed canvases exist; only the live one counts. Counting the
      # deleted one would keep stage 5's partial-index line lit forever in
      # any space that has ever had a canvas deleted.
      assert CanvasSearchIndex.unindexed_count([space.id]) == 1
    end

    test "a space whose only unindexed canvas is deleted reads as fully indexed",
         %{space: space} do
      raw_canvas(space, document: markdown_doc("gone"), deleted_at: DateTime.utc_now())

      # The sharper form of the test above: this is 0 versus 1, so a query
      # that drops the `deleted_at` filter cannot pass it by coincidence.
      assert CanvasSearchIndex.unindexed_count([space.id]) == 0
    end

    test "is scoped to the spaces it is given", %{space: space} do
      {:ok, other_space} =
        Chat.create_space(%{
          name: "CSB other #{System.unique_integer([:positive])}",
          slug: "csb-other-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      raw_canvas(space, document: markdown_doc("here"))
      raw_canvas(other_space, document: markdown_doc("there"))

      assert CanvasSearchIndex.unindexed_count([space.id]) == 1
      assert CanvasSearchIndex.unindexed_count([other_space.id]) == 1
      assert CanvasSearchIndex.unindexed_count([space.id, other_space.id]) == 2
    end

    test "returns 0 for no spaces" do
      assert CanvasSearchIndex.unindexed_count([]) == 0
    end

    test "drops malformed ids instead of raising Ecto.Query.CastError", %{space: space} do
      # `where: c.space_id in ^ids` raises the same CastError as `Repo.get/2`
      # on a non-UUID, and stage 5 renders this from whatever spaces the
      # current view holds. A bad id must degrade, not take the render down.
      raw_canvas(space, document: markdown_doc("here"))

      assert CanvasSearchIndex.unindexed_count(["not-a-uuid"]) == 0
      assert CanvasSearchIndex.unindexed_count([nil]) == 0
      assert CanvasSearchIndex.unindexed_count(["not-a-uuid", space.id]) == 1
    end
  end

  # ── the boot-time one-shot ───────────────────────────────────────────────

  describe "run_at_boot/0" do
    # Failure mode 3. The supervised child is `restart: :transient`, which
    # restarts on abnormal exit — so a raise here would be retried, raise
    # again, and trip the supervisor's max-restart intensity, taking the
    # whole application down over an unindexed canvas.
    test "returns :ok and does the work", %{space: space} do
      canvas = raw_canvas(space, document: markdown_doc("booted body"))

      assert :ok = CanvasSearchBackfill.run_at_boot()
      assert index_row(canvas.id).body_text =~ "booted body"
    end

    test "returns :ok when rows fail, so the transient child exits normally",
         %{space: space} do
      raw_canvas(space, document: markdown_doc(oversized_body()))

      log = capture_log(fn -> assert :ok = CanvasSearchBackfill.run_at_boot() end)

      assert log =~ "left 1 canvas(es) unindexed"
    end

    # The next three drive the real rescue/catch clauses, through the
    # `run_fun` argument, with the three ways `run/1` can fail wholesale.
    # Each one is a raise that would otherwise reach the supervisor.
    test "returns :ok when the run raises" do
      log =
        capture_log(fn ->
          assert :ok = CanvasSearchBackfill.run_at_boot(fn -> raise "repo is down" end)
        end)

      assert log =~ "crash-looping"
      assert log =~ "repo is down"
    end

    test "returns :ok when the run exits" do
      log =
        capture_log(fn ->
          assert :ok = CanvasSearchBackfill.run_at_boot(fn -> exit(:boom) end)
        end)

      assert log =~ "crash-looping"
    end

    test "returns :ok when the run throws" do
      log =
        capture_log(fn ->
          assert :ok = CanvasSearchBackfill.run_at_boot(fn -> throw(:nope) end)
        end)

      assert log =~ "crash-looping"
    end

    test "a raising run makes the supervised child exit :normal, so :transient never restarts it" do
      # The end-to-end form of failure mode 3, built the way the application
      # builds it: the same child spec, with a run that raises. `:transient`
      # restarts on ABNORMAL exit, so the reason has to be `:normal` — if
      # `run_at_boot/0` ever stops swallowing, this becomes an abnormal exit
      # and, in production, a restart loop that trips max-restart intensity
      # and takes the whole application down.
      parent = self()

      body = fn ->
        send(parent, {:running, self()})
        receive do: (:go -> :ok)
        CanvasSearchBackfill.run_at_boot(fn -> raise "repo is down" end)
      end

      spec =
        Supervisor.child_spec({Task, body},
          id: :canvas_search_backfill,
          restart: :transient
        )

      assert %{restart: :transient} = spec

      capture_log(fn ->
        {:ok, pid} = start_supervised(spec)

        # Handshake before monitoring, so a fast exit cannot race the monitor
        # into reporting `:noproc` and passing for the wrong reason.
        assert_receive {:running, ^pid}, 5_000
        ref = Process.monitor(pid)
        send(pid, :go)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)
    end
  end

  # ── boot wiring ──────────────────────────────────────────────────────────

  describe "boot wiring" do
    test "the supervised child is transient and calls run_at_boot/0, not run/1" do
      # Reading the source rather than booting a second supervision tree. The
      # two facts that matter are both textual: which entry point the child
      # calls (`run/1` would crash-loop the app on a raise) and that it is
      # `:transient` (`:permanent` would restart it after a clean finish).
      source = File.read!("lib/platform/application.ex")

      assert source =~ "maybe_add_canvas_search_backfill"
      assert source =~ "Platform.Chat.CanvasSearchBackfill.run_at_boot()"
      refute source =~ "Platform.Chat.CanvasSearchBackfill.run(["
      assert source =~ "id: :canvas_search_backfill"
    end

    test "it is disabled in the test environment" do
      # If this ever flips, the backfill runs at suite boot against the real
      # test database from outside every sandbox.
      assert Application.get_env(:platform, :start_canvas_search_backfill) == false
    end
  end
end
