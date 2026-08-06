defmodule Platform.Tasks.PlanningStepTest do
  # NOT `async: true`, deliberately. `record_planning_step/3` and
  # `set_planning_step/2` both broadcast `{:task_updated, task}` on
  # `tasks:board`, which the singleton `TaskRouterWatcher` consumes and
  # evaluates from a process that does not own an async test's sandbox
  # connection — the race the watcher documents at
  # `task_router_watcher.ex:509`, and the one stage 1 of this task measured
  # into the TaskRouter family (8/2/5/3 failures across four full runs).
  # A sync module puts the sandbox in shared mode, so the watcher can use
  # the connection legally. The broadcast is the subject here (member 8
  # depends on it), so it cannot be avoided the way stage 1 avoided it.
  #
  # BOARD-SCOPE-EXEMPT: the `Tasks.subscribe_board()` call below stays on the
  # global topic deliberately. `use Platform.DataCase` with no `async:` option
  # is sync (see `data_case.ex` — `shared: not tags[:async]`), so no concurrent
  # module can race it. The global topic is also the subject: this test proves
  # the board broadcast fires at all, which is what member 8's card consumes.
  use Platform.DataCase

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Planning Step Project"})
    %{project: project}
  end

  defp insert_task(project, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Task{project_id: project.id, title: "Planning step subject", status: "planning"},
        attrs
      )
    )
  end

  defp stored_outcomes(task) do
    Repo.get(Task, task.id).planning_step_outcomes
  end

  # `Platform.DataCase` does NOT define `errors_on/1` — every test module in
  # this suite carries its own copy (see `project_test.exs:138`,
  # `task_test.exs`, ~20 others). Following the local convention rather than
  # hoisting it into DataCase, which would be a suite-wide change this stage
  # has no mandate for.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "record_planning_step/3 — the ADR-0046 outcome table" do
    # GUARD. The three-value table from
    # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`, exercised end to
    # end through the JSONB column rather than against the mapping
    # function in isolation: a writer that dropped the value on the floor
    # between `outcome/1` and the changeset would still satisfy a unit
    # test of `outcome/1`.
    test "{:ok, :dispatched} records \"complete\"", %{project: project} do
      task = insert_task(project)

      assert {:ok, updated} = Tasks.record_planning_step(task, :architecture, {:ok, :dispatched})

      assert %{"architecture" => %{"outcome" => "complete", "detail" => nil} = entry} =
               updated.planning_step_outcomes

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(entry["recorded_at"])
      assert stored_outcomes(task) == updated.planning_step_outcomes
    end

    test "{:ok, :unfilled} records \"not_applicable\"", %{project: project} do
      task = insert_task(project)

      assert {:ok, updated} = Tasks.record_planning_step(task, :architecture, {:ok, :unfilled})

      assert %{"architecture" => %{"outcome" => "not_applicable"}} =
               updated.planning_step_outcomes
    end

    test "{:ok, :unknown_responsibility} records \"not_applicable\"", %{project: project} do
      task = insert_task(project)

      assert {:ok, updated} =
               Tasks.record_planning_step(task, :architecture, {:ok, :unknown_responsibility})

      assert %{"architecture" => %{"outcome" => "not_applicable"}} =
               updated.planning_step_outcomes
    end

    test "{:error, reason} records \"failed\" with the reason in detail", %{project: project} do
      task = insert_task(project)

      assert {:ok, updated} = Tasks.record_planning_step(task, :architecture, {:error, :timeout})

      assert %{"architecture" => %{"outcome" => "failed", "detail" => detail}} =
               updated.planning_step_outcomes

      assert detail == ":timeout"
    end

    test "an oversized failure reason is truncated to 500 chars", %{project: project} do
      task = insert_task(project)
      reason = String.duplicate("x", 2_000)

      assert {:ok, updated} = Tasks.record_planning_step(task, :design, {:error, reason})

      detail = updated.planning_step_outcomes["design"]["detail"]
      assert String.length(detail) == 500
    end

    # GUARD (conflation) — written as a DIRECT INEQUALITY, not as two
    # separate equality assertions. The rule in
    # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome` is precisely that
    # `not_applicable` (nobody holds the responsibility) and `failed` (the
    # dispatch broke) must never collapse into one value. A future
    # refactor that collapses them fails THIS named test, instead of
    # failing two tests that read like unrelated table entries.
    test "\"not applicable\" and \"failed\" are never the same stored value", %{project: project} do
      unfilled_task = insert_task(project)
      failed_task = insert_task(project)

      assert {:ok, unfilled} =
               Tasks.record_planning_step(unfilled_task, :architecture, {:ok, :unfilled})

      assert {:ok, failed} =
               Tasks.record_planning_step(failed_task, :architecture, {:error, :boom})

      refute unfilled.planning_step_outcomes["architecture"]["outcome"] ==
               failed.planning_step_outcomes["architecture"]["outcome"]
    end

    # GUARD (contract binding). The mapping deliberately lives in ONE
    # place. If member 1's function is renamed or deleted, this fails
    # loudly at the seam rather than letting `tasks.ex` quietly grow a
    # local copy of the table.
    test "the outcome mapping is Responsibilities.outcome/1, not a local copy" do
      assert Code.ensure_loaded?(Platform.Responsibilities)
      assert function_exported?(Platform.Responsibilities, :outcome, 1)

      source = File.read!("lib/platform/tasks.ex")

      # Positive half: the seam is actually used here.
      assert source =~ "Platform.Responsibilities.outcome("
      # Negative half: no second definition of the table in this module.
      refute source =~ ~r/defp?\s+outcome\(/

      # NOTE, deliberately not asserted: `tasks.ex` DOES still pattern-match
      # fire-result shapes once, in `fire_architecture_review_plan/1`, to
      # pick a log level (`:unfilled` is info, `{:error, _}` is warning).
      # That predates this stage (019f9b27) and derives no outcome, so it is
      # not the duplication this guard exists to catch. A blanket
      # `refute source =~ "{:ok, :dispatched}"` would fail on a comment.
    end

    # GUARD — merge, not replace. Member 7 records `:design` and stage 3
    # records `:architecture` through the same column; whichever runs
    # second must not erase the first.
    test "recording a second step merges rather than replaces", %{project: project} do
      task = insert_task(project)

      assert {:ok, _} = Tasks.record_planning_step(task, :design, {:ok, :unfilled})
      assert {:ok, both} = Tasks.record_planning_step(task, :architecture, {:error, :nope})

      assert %{
               "design" => %{"outcome" => "not_applicable"},
               "architecture" => %{"outcome" => "failed"}
             } = both.planning_step_outcomes

      assert Enum.sort(Map.keys(stored_outcomes(task))) == ["architecture", "design"]
    end

    # The second recording above passed a STALE `%Task{}` (captured before
    # the first write). Re-reading the row inside the writer is what makes
    # the merge correct; passing the struct straight through to the
    # changeset would silently drop the `design` entry.
    test "a stale struct does not clobber a step recorded in between", %{project: project} do
      stale = insert_task(project)

      assert {:ok, _} = Tasks.record_planning_step(stale.id, :design, {:ok, :dispatched})
      assert stale.planning_step_outcomes == %{}

      assert {:ok, merged} = Tasks.record_planning_step(stale, :architecture, {:ok, :dispatched})
      assert Map.has_key?(merged.planning_step_outcomes, "design")
    end

    test "an unknown task id returns {:error, :task_not_found}" do
      assert {:error, :task_not_found} =
               Tasks.record_planning_step(Ecto.UUID.generate(), :architecture, {:ok, :dispatched})
    end

    test "the board broadcast fires so member 8's card refreshes", %{project: project} do
      task = insert_task(project)
      Tasks.subscribe_board()

      assert {:ok, _} = Tasks.record_planning_step(task, :architecture, {:ok, :dispatched})

      assert_receive {:task_updated, %Task{id: id, planning_step_outcomes: outcomes}}, 1_000
      assert id == task.id
      assert %{"architecture" => %{"outcome" => "complete"}} = outcomes
    end

    # GUARD (transaction semantics). The @doc claims the write
    # participates in any ambient transaction; prove it rather than
    # asserting it in prose. The second half is the positive control —
    # without it, an implementation that never wrote anything at all would
    # pass the first half.
    test "the write participates in an ambient transaction", %{project: project} do
      task = insert_task(project)

      assert {:error, :nope} =
               Repo.transaction(fn ->
                 assert {:ok, _} =
                          Tasks.record_planning_step(task, :architecture, {:ok, :dispatched})

                 Repo.rollback(:nope)
               end)

      assert stored_outcomes(task) == %{}

      # Positive control: the IDENTICAL call outside a transaction persists.
      assert {:ok, _} = Tasks.record_planning_step(task, :architecture, {:ok, :dispatched})
      assert %{"architecture" => %{"outcome" => "complete"}} = stored_outcomes(task)
    end
  end

  describe "set_planning_step/2" do
    # GUARD — re-asserted at the CONTEXT level, not just at the changeset
    # level: `set_planning_step/2` could have been implemented over
    # `update_task/3` (which casts `:status`), and then a status already
    # in flight elsewhere could ride along on a cursor move.
    test "moves the cursor and cannot change status", %{project: project} do
      task = insert_task(project, %{status: "planning"})

      assert {:ok, updated} = Tasks.set_planning_step(task, :architecting)
      assert updated.planning_step == "architecting"
      assert updated.status == "planning"
      assert Repo.get(Task, task.id).status == "planning"

      assert {:ok, back} = Tasks.set_planning_step(updated, :planning)
      assert back.planning_step == "planning"
      assert back.status == "planning"
    end

    test "rejects a cursor value outside the domain", %{project: project} do
      task = insert_task(project)

      assert {:error, %Ecto.Changeset{} = changeset} = Tasks.set_planning_step(task, :done)
      assert %{planning_step: ["is invalid"]} = errors_on(changeset)
      assert Repo.get(Task, task.id).planning_step == "planning"

      # Not a raise, even for a term with no String.Chars implementation:
      # these writers must return errors so an ambient transaction they did
      # not open cannot be aborted by a bad argument.
      assert {:error, %Ecto.Changeset{}} = Tasks.set_planning_step(task, %{bogus: true})
    end

    test "leaves recorded outcomes alone", %{project: project} do
      task = insert_task(project)
      assert {:ok, _} = Tasks.record_planning_step(task, :architecture, {:error, :boom})

      assert {:ok, moved} = Tasks.set_planning_step(task, :architecting)
      assert %{"architecture" => %{"outcome" => "failed"}} = moved.planning_step_outcomes
    end

    test "an unknown task id returns {:error, :task_not_found}" do
      assert {:error, :task_not_found} =
               Tasks.set_planning_step(Ecto.UUID.generate(), :architecting)
    end
  end

  describe "failed_planning_steps/1 and planning_gate_failed?/1" do
    test "report only the failed steps, in planning_step_keys/0 order", %{project: project} do
      task = insert_task(project)

      assert {:ok, _} = Tasks.record_planning_step(task, :architecture, {:error, :econnrefused})
      assert {:ok, reloaded} = Tasks.record_planning_step(task, :design, {:error, :timeout})

      assert [
               %{step: "design", detail: ":timeout"},
               %{step: "architecture", detail: ":econnrefused"}
             ] = Tasks.failed_planning_steps(reloaded)

      assert Tasks.planning_gate_failed?(reloaded)
    end

    test "carry the recorded_at stamp", %{project: project} do
      task = insert_task(project)
      assert {:ok, reloaded} = Tasks.record_planning_step(task, :architecture, {:error, :boom})

      assert [%{recorded_at: stamp}] = Tasks.failed_planning_steps(reloaded)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(stamp)
    end

    # The conflation guard at the READ layer. `not_applicable` is the
    # progressive-enhancement path — no architect is assigned — and must
    # never be reported as a gate that failed.
    test "\"not_applicable\" and \"complete\" are not failures", %{project: project} do
      task = insert_task(project)

      assert {:ok, _} = Tasks.record_planning_step(task, :architecture, {:ok, :unfilled})
      assert {:ok, reloaded} = Tasks.record_planning_step(task, :design, {:ok, :dispatched})

      assert Tasks.failed_planning_steps(reloaded) == []
      refute Tasks.planning_gate_failed?(reloaded)
    end

    test "a task with nothing recorded has no failed steps", %{project: project} do
      task = insert_task(project)

      assert Tasks.failed_planning_steps(task) == []
      refute Tasks.planning_gate_failed?(task)
    end
  end
end
