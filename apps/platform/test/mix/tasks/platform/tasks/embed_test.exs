defmodule Mix.Tasks.Platform.Tasks.EmbedTest do
  @moduledoc """
  Tests for `Mix.Tasks.Platform.Tasks.Embed` — the one-shot backfill for
  task embeddings + `task_references`.

  `async: false` because we override the app-env memory-service provider
  to capture ingest calls.
  """

  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.Tasks.Embed
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.TaskReference

  # Stub provider — captures every `ingest/2` call by sending to the
  # owner pid stashed in config. Same pattern as the wiki indexer test.
  defmodule StubProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, config) do
      target = Keyword.fetch!(config, :test_pid)
      send(target, {:ingest, entries})
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _config), do: {:ok, length(ids)}

    @impl true
    def health(_c), do: :ok
  end

  setup do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: StubProvider,
      test_pid: self()
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    {:ok, project} = Tasks.create_project(%{name: "Embed Backfill Project"})

    %{project: project}
  end

  describe "process_all/1" do
    test "runs References + Memory.ingest for every task in the project",
         %{project: project} do
      # Two targets that stand alone, plus a source whose description
      # references both. `create_task` already ran the hooks — the
      # backfill must be a stable no-op on top.
      {:ok, target_a} =
        Tasks.create_task(%{project_id: project.id, title: "target A"})

      {:ok, target_b} =
        Tasks.create_task(%{project_id: project.id, title: "target B"})

      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "cites #{target_a.id} and #{target_b.id}"
        })

      # Drain the ingest messages from create_task/1's hook so the
      # backfill assertions below aren't confused with the write path.
      drain_ingest_messages()

      config = %{
        batch: 2,
        project_id: project.id,
        dry_run?: false,
        skip_refs?: false,
        skip_embed?: false
      }

      %{processed: 3, errors: 0} = Embed.process_all(config)

      # References already exist and are idempotent.
      assert Enum.sort(list_outgoing_refs(source.id)) ==
               Enum.sort([target_a.id, target_b.id])

      # Each of the 3 tasks was re-ingested by the backfill.
      assert_receive {:ingest, [entry_1]}
      assert_receive {:ingest, [entry_2]}
      assert_receive {:ingest, [entry_3]}

      seen_ids = MapSet.new([entry_1.id, entry_2.id, entry_3.id])

      assert MapSet.equal?(
               seen_ids,
               MapSet.new([target_a.id, target_b.id, source.id])
             )

      # Every entry carries the "task" corpus tag.
      for entry <- [entry_1, entry_2, entry_3] do
        assert entry.memory_type == "task"
      end
    end

    test "dry_run skips both refs upsert and memory ingest", %{project: project} do
      # Two tasks whose description will produce reference candidates.
      {:ok, target} =
        Tasks.create_task(%{project_id: project.id, title: "target"})

      # Create source with references, then wipe task_references so we
      # can prove the dry-run pass leaves it empty.
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "cites #{target.id}"
        })

      Repo.delete_all(TaskReference)
      drain_ingest_messages()

      %{processed: 2, errors: 0} =
        Embed.process_all(%{
          batch: 50,
          project_id: project.id,
          dry_run?: true,
          skip_refs?: false,
          skip_embed?: false
        })

      # No refs re-inserted (dry-run skipped them).
      assert list_outgoing_refs(source.id) == []

      # No ingest calls happened either.
      refute_received {:ingest, _}
    end

    test "skip_refs runs only the embed path", %{project: project} do
      {:ok, target} =
        Tasks.create_task(%{project_id: project.id, title: "target"})

      {:ok, _source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "cites #{target.id}"
        })

      Repo.delete_all(TaskReference)
      drain_ingest_messages()

      %{processed: 2, errors: 0} =
        Embed.process_all(%{
          batch: 50,
          project_id: project.id,
          dry_run?: false,
          skip_refs?: true,
          skip_embed?: false
        })

      # Refs skipped → still empty.
      assert Repo.aggregate(TaskReference, :count, :source_task_id) == 0

      # Ingest still happened.
      assert_receive {:ingest, _}
      assert_receive {:ingest, _}
    end

    test "skip_embed runs only the references path", %{project: project} do
      {:ok, target} =
        Tasks.create_task(%{project_id: project.id, title: "target"})

      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "cites #{target.id}"
        })

      Repo.delete_all(TaskReference)
      drain_ingest_messages()

      %{processed: 2, errors: 0} =
        Embed.process_all(%{
          batch: 50,
          project_id: project.id,
          dry_run?: false,
          skip_refs?: false,
          skip_embed?: true
        })

      # Refs recomputed.
      assert list_outgoing_refs(source.id) == [target.id]

      # No ingest calls.
      refute_received {:ingest, _}
    end
  end

  describe "process_one/2" do
    test "returns :ok on success", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "solo"})
      drain_ingest_messages()

      assert Embed.process_one(task, %{
               batch: 50,
               project_id: project.id,
               dry_run?: false,
               skip_refs?: false,
               skip_embed?: false
             }) == :ok

      assert_receive {:ingest, _}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp list_outgoing_refs(source_id) do
    import Ecto.Query

    TaskReference
    |> where([r], r.source_task_id == ^source_id)
    |> select([r], r.target_task_id)
    |> Repo.all()
  end

  # `create_task/1` and `update_task/2` fire ingest_async under
  # `Platform.TaskSupervisor` — which uses the same StubProvider, so
  # the test mailbox accumulates `{:ingest, _}` before we're ready to
  # observe backfill-only ingests. Wait a beat for async fan-out to
  # settle, then flush.
  defp drain_ingest_messages do
    Process.sleep(50)
    do_drain()
  end

  defp do_drain do
    receive do
      {:ingest, _} -> do_drain()
    after
      0 -> :ok
    end
  end
end
