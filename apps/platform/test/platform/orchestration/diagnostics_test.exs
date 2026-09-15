defmodule Platform.Orchestration.DiagnosticsTest do
  @moduledoc """
  Unit-level tests for `Diagnostics.list_execution_leases/2`'s `:limit`.

  Chosen as the home (rather than the tool-surface test file) because the bound
  lives in the query, not in the MCP serializer: a test that only went through
  `ToolSurface.execute/3` could pass on a limit applied in either place and so
  would not say which one was bounded.

  ANTI-VACUITY: asserting merely that `:limit` is ACCEPTED proves nothing — an
  option the query drops on the floor passes that test unchanged. Every case
  below seeds MORE rows than the bound it is testing and asserts the returned
  length EXACTLY equals the bound, and that the rows kept are the NEWEST ones
  rather than an arbitrary slice.

  Every cap figure is read from `Diagnostics.max_limit/0` /
  `Diagnostics.default_limit/0`. A hardcoded 200 here would keep passing after
  someone changed the module attribute, which is the failure mode this comment
  exists to prevent.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.{Diagnostics, ExecutionLease}
  alias Platform.Repo
  alias Platform.Tasks

  @max Diagnostics.max_limit()
  @default Diagnostics.default_limit()

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Diag Limit #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lease-heavy task"})

    # One more than the cap, so the cap is a real truncation and not the whole set.
    seed_leases(task, @max + 10)

    %{task: task}
  end

  describe "list_execution_leases/2 :limit" do
    test "an over-cap ask is clamped to @max_limit rather than refused", %{task: task} do
      assert {:ok, leases} = Diagnostics.list_execution_leases(task.id, limit: @max + 10)
      assert length(leases) == @max
    end

    test "no :limit returns exactly the default, not the whole set", %{task: task} do
      assert {:ok, leases} = Diagnostics.list_execution_leases(task.id)
      assert length(leases) == @default
      assert @default < @max + 10
    end

    test "a small explicit limit is honoured exactly", %{task: task} do
      assert {:ok, leases} = Diagnostics.list_execution_leases(task.id, limit: 5)
      assert length(leases) == 5
    end

    # The limit must be applied AFTER the ordering. A limit applied before it
    # returns the right COUNT of the wrong rows, which is the bug that reads as
    # "the diagnostic is lying about what happened most recently".
    test "the rows kept are the NEWEST, and newest-first ordering survives", %{task: task} do
      {:ok, all} = Diagnostics.list_execution_leases(task.id, limit: @max)
      {:ok, few} = Diagnostics.list_execution_leases(task.id, limit: 5)

      assert Enum.map(few, & &1.id) == all |> Enum.take(5) |> Enum.map(& &1.id)

      starts = Enum.map(few, & &1.started_at)
      assert starts == Enum.sort(starts, {:desc, DateTime})

      newest =
        Repo.one(
          from(l in ExecutionLease,
            where: l.task_id == ^task.id,
            order_by: [desc: l.started_at],
            limit: 1,
            select: l.id
          )
        )

      assert hd(few).id == newest
    end

    test "a garbage or zero limit falls back to a usable bound, never unbounded", %{task: task} do
      for bad <- [nil, 0, -7, "banana", :nope] do
        assert {:ok, leases} = Diagnostics.list_execution_leases(task.id, limit: bad)
        assert length(leases) >= 1
        assert length(leases) <= @max
      end
    end

    test "a string limit is parsed and applied", %{task: task} do
      assert {:ok, leases} = Diagnostics.list_execution_leases(task.id, limit: "7")
      assert length(leases) == 7
    end

    # The :status filter bounds by semantic property, not by count. It must keep
    # working alongside :limit, and the invalid-status refusal must still fire
    # when a limit is present.
    test ":limit composes with :status; neither is dropped", %{task: task} do
      assert {:ok, blocked} =
               Diagnostics.list_execution_leases(task.id, status: "blocked", limit: 3)

      assert length(blocked) == 3
      assert Enum.all?(blocked, &(&1.status == "blocked"))

      assert {:error, :invalid_status} =
               Diagnostics.list_execution_leases(task.id, status: "bogus", limit: 3)
    end
  end

  defp seed_leases(task, count) do
    now = DateTime.utc_now()

    rows =
      for i <- 0..(count - 1) do
        # Distinct started_at per row — a shared timestamp would let term order
        # masquerade as chronological order and the ordering assertion above
        # would pass without the sorter doing anything.
        started = DateTime.add(now, -i * 3, :second)

        %{
          id: Platform.Types.UUIDv7.autogenerate(),
          task_id: task.id,
          stage_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime-#{i}",
          status: if(rem(i, 2) == 0, do: "blocked", else: "active"),
          started_at: started,
          last_heartbeat_at: started,
          last_progress_at: started,
          expires_at: DateTime.add(started, 1800, :second),
          metadata: %{},
          owner_attribution_status: "legacy_pre_migration",
          inserted_at: started,
          updated_at: started
        }
      end

    {^count, _} = Repo.insert_all(ExecutionLease, rows)
    :ok
  end
end
