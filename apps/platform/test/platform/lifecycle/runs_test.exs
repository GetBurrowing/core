defmodule Platform.Lifecycle.RunsTest do
  use Platform.DataCase, async: true

  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRun
  alias Platform.Tasks

  @edge "in_progress->deploying"

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Lifecycle Runs Project",
        repo_url: "https://github.com/test/lifecycle-runs",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"}
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Lifecycle Runs Task"
      })

    %{task: task}
  end

  # `Platform.DataCase` does not define `errors_on/1`; every module in this
  # suite carries its own copy (`architecture_gate_test.exs:78`,
  # `project_test.exs:138`, ~20 others). Following the local convention
  # rather than hoisting it, which this stage has no mandate for.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp attrs(task, overrides) do
    Map.merge(
      %{
        task_id: task.id,
        edge: @edge,
        run_seq: 1,
        step_name: "notify",
        position: 0,
        awaited: false,
        can_divert: false,
        status: "completed"
      },
      Map.new(overrides)
    )
  end

  describe "record/1" do
    test "persists a run with its declared await/divert authority", %{task: task} do
      assert {:ok, run} =
               Runs.record(
                 attrs(task,
                   step_name: "architecture_review",
                   position: 2,
                   awaited: true,
                   can_divert: true,
                   status: "diverted",
                   reason: "plan contradicts ADR 0046"
                 )
               )

      reloaded = Repo.get!(StepRun, run.id)
      assert reloaded.task_id == task.id
      assert reloaded.edge == @edge
      assert reloaded.step_name == "architecture_review"
      assert reloaded.position == 2
      assert reloaded.awaited == true
      assert reloaded.can_divert == true
      assert reloaded.status == "diverted"
      assert reloaded.reason == "plan contradicts ADR 0046"
    end

    test "accepts a suppressed run that named no step", %{task: task} do
      assert {:ok, run} =
               Runs.record(
                 attrs(task,
                   step_name: nil,
                   position: nil,
                   status: "suppressed",
                   reason: "re-entry bound reached"
                 )
               )

      assert run.step_name == nil
      assert run.position == nil
      assert run.status == "suppressed"
    end

    test "rejects a status outside the vocabulary", %{task: task} do
      assert {:error, changeset} = Runs.record(attrs(task, status: "errored"))
      assert "is invalid" in errors_on(changeset).status
    end

    test "the vocabulary keeps budget-kill, step-error and never-ran distinct" do
      # A collapse of any two of these is the exact defect ADR 0046 exists to
      # prevent, and it would show up here first: as a shrunk list.
      assert StepRun.statuses() == ~w(started completed diverted failed timed_out suppressed)
    end
  end

  describe "next_run_seq/2" do
    test "is 1 for an edge that has never fired", %{task: task} do
      assert Runs.next_run_seq(task.id, @edge) == 1
    end

    test "increments once per firing, not once per row", %{task: task} do
      for position <- 0..2 do
        {:ok, _} = Runs.record(attrs(task, run_seq: 1, position: position))
      end

      assert Runs.next_run_seq(task.id, @edge) == 2

      {:ok, _} = Runs.record(attrs(task, run_seq: 2, position: 0))
      assert Runs.next_run_seq(task.id, @edge) == 3
    end

    test "is scoped to the edge", %{task: task} do
      {:ok, _} = Runs.record(attrs(task, run_seq: 1))
      assert Runs.next_run_seq(task.id, "planning->in_progress") == 1
    end
  end

  describe "run_count/2" do
    test "counts DISTINCT run_seq — a three-step single firing is one run", %{task: task} do
      # THREE rows, ONE run_seq. Two rows could not distinguish a distinct
      # count from a row count (2 vs 1 is a difference either way only by
      # luck); three makes a row count read 3 against the expected 1.
      for {step, position} <- [{"design", 0}, {"notify", 1}, {"webhook", 2}] do
        {:ok, _} = Runs.record(attrs(task, run_seq: 1, step_name: step, position: position))
      end

      assert Runs.run_count(task.id, @edge) == 1
    end

    test "is 0 for an edge that has never fired", %{task: task} do
      assert Runs.run_count(task.id, @edge) == 0
    end

    test "counts a second firing separately", %{task: task} do
      {:ok, _} = Runs.record(attrs(task, run_seq: 1, position: 0))
      {:ok, _} = Runs.record(attrs(task, run_seq: 1, position: 1))
      {:ok, _} = Runs.record(attrs(task, run_seq: 2, position: 0))

      assert Runs.run_count(task.id, @edge) == 2
    end
  end

  describe "for_edge/2" do
    test "orders by run_seq then position, as an explicit list", %{task: task} do
      inserted = [
        {2, 1, "second-firing-notify"},
        {1, 2, "first-firing-webhook"},
        {2, 0, "second-firing-design"},
        {1, 0, "first-firing-design"},
        {1, 1, "first-firing-notify"}
      ]

      for {run_seq, position, step} <- inserted do
        {:ok, _} = Runs.record(attrs(task, run_seq: run_seq, position: position, step_name: step))
      end

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.run_seq, &1.position, &1.step_name}) ==
               [
                 {1, 0, "first-firing-design"},
                 {1, 1, "first-firing-notify"},
                 {1, 2, "first-firing-webhook"},
                 {2, 0, "second-firing-design"},
                 {2, 1, "second-firing-notify"}
               ]
    end

    test "returns only rows for the asked-for edge", %{task: task} do
      {:ok, _} = Runs.record(attrs(task, step_name: "on-edge"))
      {:ok, _} = Runs.record(attrs(task, edge: "planning->in_progress", step_name: "other-edge"))

      assert Enum.map(Runs.for_edge(task.id, @edge), & &1.step_name) == ["on-edge"]
    end
  end
end
