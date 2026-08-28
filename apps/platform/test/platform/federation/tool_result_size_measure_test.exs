defmodule Platform.Federation.ToolResultSizeMeasureTest do
  @moduledoc """
  MEASUREMENT harness, not a guard. Excluded from the default run
  (`@moduletag :measure`); run it explicitly with

      mix test --only measure test/platform/federation/tool_result_size_measure_test.exs

  It seeds a worst-case-shaped corpus and PRINTS the serialized byte size of
  each list tool's result, so the same numbers can be taken before and after a
  change to `Platform.Federation.ToolSurface`. It asserts nothing about size on
  purpose — an assertion here would make the "before" run red and the number
  unobtainable.

  The one thing it does assert is that whatever comes back round-trips through
  `Jason`, which is true before and after and is the property a byte cap is
  most likely to break.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}

  @moduletag :measure
  # Seeding several hundred rows through the real changesets is not fast.
  @moduletag timeout: 600_000

  # Sizes are NOT invented. They are the distribution measured on 2026-08-28
  # against the live project named in task 01a049de
  # (019d1357-cb08-7023-b165-fd19e9462316), via the MCP `task_list` result that
  # Claude Code persisted to disk:
  #
  #   task_list  807 records, 3_366_819 bytes total
  #              description n=805 min=79 median=3_218 max=40_048 sum=2_799_877
  #   stage_list   4 stages,     47_048 bytes total
  #              description + validation evidence/evaluation_payload = 89.9%
  #
  # The ticket's "~8 KB" description was an understatement by 5x; the real
  # worst case is 40 KB. A fixture built to the ticket's figure would have
  # measured a 1.0 MB "before" and understated the defect by a third.
  @task_count 805
  @stage_count 40
  @review_item_count 258

  defp filler(n), do: String.duplicate("lorem ipsum dolor sit amet ", div(n, 27) + 1)

  # Reproduces the measured quartiles rather than a uniform size: a corpus
  # where every row is the maximum overstates the problem, and one where every
  # row is minimal understates it.
  defp description_for(i) do
    cond do
      rem(i, 200) == 0 -> filler(40_000)
      rem(i, 25) == 0 -> filler(12_000)
      rem(i, 2) == 0 -> filler(3_218)
      true -> filler(800)
    end
  end

  defp bytes(term), do: term |> Jason.encode!() |> byte_size()

  defp report(label, term) do
    size = bytes(term)

    # Round-trips before AND after. A cap that slices the encoded string
    # instead of dropping structure fails here.
    assert term |> Jason.encode!() |> Jason.decode!()

    IO.puts("\n[MEASURE] #{label}: #{size} bytes (#{Float.round(size / 1_048_576, 3)} MB)")
    size
  end

  describe "task_list" do
    test "serialized size for a project holding #{@task_count} tasks" do
      {:ok, project} = Tasks.create_project(%{name: "Measure Proj #{unique()}"})

      for i <- 1..@task_count do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Measured task #{i}",
            description: description_for(i)
          })
      end

      {:ok, result} = ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

      report("task_list project_id=<#{@task_count} tasks>", result)

      IO.puts(
        "[MEASURE]   records=#{length(result)} " <>
          "description_bytes=#{result |> Enum.map(&byte_size(&1.description || "")) |> Enum.sum()}"
      )
    end
  end

  describe "stage_list" do
    test "serialized size for a plan holding #{@stage_count} stages with validations" do
      {:ok, project} = Tasks.create_project(%{name: "Measure Stage Proj #{unique()}"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Staged"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      for i <- 1..@stage_count do
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: i,
            name: "Stage #{i}",
            description: filler(3_000)
          })

        {:ok, _} =
          Tasks.create_validation(%{
            stage_id: stage.id,
            kind: "test_pass",
            evidence: %{"log" => filler(4_000)}
          })
      end

      {:ok, result} = ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      report("stage_list plan_id=<#{@stage_count} stages>", result)
      IO.puts("[MEASURE]   records=#{length(result)}")
    end
  end

  describe "review_item_list" do
    test "serialized size for a task holding #{@review_item_count} review items" do
      {:ok, project} = Tasks.create_project(%{name: "Measure Review Proj #{unique()}"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Reviewed"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review Stage"})
      {:ok, _} = PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      for i <- 1..@review_item_count do
        {:ok, request} =
          ReviewRequests.create_review_request(%{
            validation_id: validation.id,
            task_id: task.id,
            submitted_by: "measure-agent",
            items: [
              %{
                label: "Item #{i}",
                canvas_id: "canvas-#{i}",
                content: filler(4_000)
              }
            ]
          })

        [item] = request.items
        {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", filler(1_500))
      end

      {:ok, result} = ToolSurface.execute("review_item_list", %{"task_id" => task.id}, %{})

      report("review_item_list task_id=<#{@review_item_count} items>", result)
      IO.puts("[MEASURE]   count=#{result.count} items=#{length(result.items)}")
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
