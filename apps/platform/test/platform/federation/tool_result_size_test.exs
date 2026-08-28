defmodule Platform.Federation.ToolResultSizeTest do
  @moduledoc """
  The three list tools named in task 01a049de must return a payload an agent
  can afford to read: `task_list`, `stage_list`, `review_item_list`.

  ## Measured baseline (this is what these numbers are defending)

  Live, against project 019d1357 on 2026-08-28, before the change:

      task_list  {project_id: 019d1357}      3_366_819 bytes, 807 records
                                             description = 83.2% of the payload
      stage_list {task_id: 01a01ce0}            47_048 bytes, 4 stages
                                             description + evidence = 89.9%
      review_item_list                           6_855 bytes, 7 items (largest
                                             instance findable; the ticket's
                                             1.76 MB gate no longer exists)

  ## Anti-vacuity notes

  Each fixture is sized to the WRONG answer: the record counts and field sizes
  here produce a payload well over the bound on the pre-change code, so a test
  that goes green proves the bound fired rather than proving the fixture was
  small. The fixtures were run against the unbounded code and observed failing.

  The load-bearing assertions are STRUCTURE and SIZE. `payload =~ "something"`
  is true of the broken payload too, so content-presence is never the check.
  Size is asserted against `Jason.encode!/1` — the same serialization
  `PlatformWeb.MCPController` performs — not against the Elixir term.

  Every describe block carries a POSITIVE CONTROL: a small, normal call whose
  fields must survive intact. Without them, a change that emptied every
  response would satisfy every size assertion in this file.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}

  @moduletag timeout: 300_000

  # RESTATED literals, deliberately NOT `ResultBound.default_limit()` and
  # friends. Reading them back made `length(rows) == default_limit` true by
  # construction, and a mutation dropping the default from 50 to 1 survived the
  # entire suite. `ResultBoundTest` pins these same four against the module in
  # one assertion, so a deliberate change still fails loudly — once.
  @max_result_bytes 100_000
  @snippet_chars 500
  @default_limit 50

  defp filler(n), do: String.duplicate("lorem ipsum dolor sit amet ", div(n, 27) + 1)
  defp bytes(term), do: term |> Jason.encode!() |> byte_size()
  defp u, do: System.unique_integer([:positive])

  defp project, do: elem(Tasks.create_project(%{name: "Bound Proj #{u()}"}), 1)

  # ── task_list ───────────────────────────────────────────────────────────

  describe "task_list" do
    setup do
      p = project()

      # 300 tasks x ~4 KB of description unbounded-serializes to >1 MB. The
      # bound must bring it under 100 KB.
      for i <- 1..300 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: p.id,
            title: "Bounded task #{i}",
            description: filler(4_000)
          })
      end

      %{project: p}
    end

    test "the default call is bounded, parses, and keeps identity fields", %{project: p} do
      {:ok, rows} = ToolSurface.execute("task_list", %{"project_id" => p.id}, %{})

      assert bytes(rows) <= @max_result_bytes
      assert rows |> Jason.encode!() |> Jason.decode!() |> length() == length(rows)

      # Bounded by `limit`, not by emptiness.
      assert length(rows) == @default_limit

      # Identity survives. This is what makes the result useful at all, and it
      # is what a "just return []" implementation would fail.
      for row <- rows do
        assert is_binary(row.id)
        assert is_binary(row.title)
        assert is_binary(row.status)
        assert row.project_id == p.id
      end
    end

    test "description is PREVIEWED, never silently dropped", %{project: p} do
      {:ok, [row | _]} = ToolSurface.execute("task_list", %{"project_id" => p.id}, %{})

      # The ticket is explicit that an existing caller reading a field must not
      # get nothing. It gets a shorter string plus the means to know that.
      assert is_binary(row.description)
      assert String.length(row.description) == @snippet_chars
      assert row.description_truncated == true
      assert row.description_length > @snippet_chars
    end

    test "limit and offset page through the corpus without overlap", %{project: p} do
      {:ok, first} =
        ToolSurface.execute("task_list", %{"project_id" => p.id, "limit" => 10}, %{})

      {:ok, second} =
        ToolSurface.execute(
          "task_list",
          %{"project_id" => p.id, "limit" => 10, "offset" => 10},
          %{}
        )

      assert length(first) == 10
      assert length(second) == 10
      assert MapSet.disjoint?(MapSet.new(first, & &1.id), MapSet.new(second, & &1.id))
    end

    test "detail=full restores whole descriptions for a caller that asks", %{project: p} do
      {:ok, [row | _]} =
        ToolSurface.execute(
          "task_list",
          %{"project_id" => p.id, "limit" => 2, "detail" => "full"},
          %{}
        )

      assert String.length(row.description) > @snippet_chars
      refute Map.has_key?(row, :description_truncated)
    end

    test "POSITIVE CONTROL: a small project is not truncated and carries full descriptions" do
      small = project()
      {:ok, _} = Tasks.create_task(%{project_id: small.id, title: "Only", description: "tiny"})

      {:ok, rows} = ToolSurface.execute("task_list", %{"project_id" => small.id}, %{})

      assert length(rows) == 1
      row = hd(rows)
      assert row.title == "Only"
      # Untouched value, and explicitly flagged as complete.
      assert row.description == "tiny"
      assert row.description_truncated == false
      assert row.description_length == 4
    end
  end

  # ── stage_list ──────────────────────────────────────────────────────────

  describe "stage_list" do
    setup do
      p = project()
      {:ok, task} = Tasks.create_task(%{project_id: p.id, title: "Staged"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      for i <- 1..30 do
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

      %{plan: plan}
    end

    test "bounded, parses, and keeps stage identity and validation status", %{plan: plan} do
      {:ok, stages} = ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      assert bytes(stages) <= @max_result_bytes
      assert stages |> Jason.encode!() |> Jason.decode!() |> length() == length(stages)

      for stage <- stages do
        assert is_binary(stage.id)
        assert is_binary(stage.name)
        assert stage.plan_id == plan.id
        # Gate STATE must survive summarization — it is the reason to call this
        # tool. Only the bulky evidence blob goes.
        assert Enum.all?(stage.validations, &is_binary(&1.status))
        assert Enum.all?(stage.validations, &is_binary(&1.kind))
      end
    end

    test "evidence is emptied with a marker, not half-serialized", %{plan: plan} do
      {:ok, stages} = ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})
      validation = stages |> hd() |> Map.fetch!(:validations) |> hd()

      # An empty map, NOT a partial one — a caller must not be able to read a
      # surviving key out of a map that lost its siblings.
      assert validation.evidence == %{}
      assert validation.evidence_omitted == true
      assert validation.evidence_length > 0
    end

    test "detail=full returns evidence whole", %{plan: plan} do
      {:ok, stages} =
        ToolSurface.execute("stage_list", %{"plan_id" => plan.id, "detail" => "full"}, %{})

      validation = stages |> hd() |> Map.fetch!(:validations) |> hd()
      assert Map.has_key?(validation.evidence, "log")
      refute Map.has_key?(validation, :evidence_omitted)
    end

    test "POSITIVE CONTROL: a small plan keeps its description and its evidence flagged intact" do
      p = project()
      {:ok, task} = Tasks.create_task(%{project_id: p.id, title: "Small"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "One", description: "short"})

      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, [row]} = ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      assert row.name == "One"
      assert row.description == "short"
      assert row.description_truncated == false
      assert length(row.validations) == 1
      # No evidence to omit, and it says so rather than lying about a blob.
      assert hd(row.validations).evidence_omitted == false
    end
  end

  # ── review_item_list ────────────────────────────────────────────────────

  describe "review_item_list" do
    setup do
      p = project()
      {:ok, task} = Tasks.create_task(%{project_id: p.id, title: "Reviewed"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review Stage"})
      {:ok, _} = PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      # 120 stacked requests reproduces the shape of the incident in the
      # ticket (258 superseded requests on one pending gate) at a size that
      # still blows the bound on the pre-change code.
      for i <- 1..120 do
        {:ok, request} =
          ReviewRequests.create_review_request(%{
            validation_id: validation.id,
            task_id: task.id,
            submitted_by: "bound-agent",
            items: [%{label: "Item #{i}", canvas_id: "c-#{i}", content: filler(4_000)}]
          })

        [item] = request.items
        {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", filler(1_500))
      end

      %{task: task}
    end

    test "bounded, parses, and reports the true total separately from the page", %{task: task} do
      {:ok, result} = ToolSurface.execute("review_item_list", %{"task_id" => task.id}, %{})

      assert bytes(result) <= @max_result_bytes
      assert result |> Jason.encode!() |> Jason.decode!() |> Map.has_key?("items")

      # `count` is the pre-existing key and it still means the TOTAL. Callers
      # branch on it; redefining it would be a silent breaking change.
      assert result.count == 120
      assert result.returned_count == @default_limit
      assert length(result.items) == @default_limit
      assert result.offset == 0
      assert result.next_offset == @default_limit
    end

    test "rulings survive summarization — only the bulky prose is previewed", %{task: task} do
      {:ok, result} = ToolSurface.execute("review_item_list", %{"task_id" => task.id}, %{})
      item = hd(result.items)

      # The tool exists to report what a human decided. Status, label and the
      # request linkage must be whole regardless of the size bound.
      assert item.status == "needs_revision"
      assert is_binary(item.label)
      assert is_binary(item.review_request_id)
      assert is_binary(item.request_status)

      assert String.length(item.content) == @snippet_chars
      assert item.content_truncated == true
      assert item.feedback_truncated == true
    end

    test "next_offset is nil on the last page", %{task: task} do
      {:ok, result} =
        ToolSurface.execute(
          "review_item_list",
          %{"task_id" => task.id, "limit" => 50, "offset" => 100},
          %{}
        )

      assert result.returned_count == 20
      assert result.next_offset == nil
    end

    test "POSITIVE CONTROL: a task with one short ruling returns it verbatim" do
      p = project()
      {:ok, task} = Tasks.create_task(%{project_id: p.id, title: "One ruling"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S"})
      {:ok, _} = PlanEngine.start_stage(stage.id)
      {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: v.id,
          task_id: task.id,
          submitted_by: "agent",
          items: [%{label: "Mobile nav", canvas_id: "c1", content: "Mobile screenshot"}]
        })

      [item] = request.items
      {:ok, _} = ReviewRequests.reject_item(item.id, "rowan", "FAB overlaps the bottom nav")

      {:ok, result} = ToolSurface.execute("review_item_list", %{"task_id" => task.id}, %{})

      assert result.count == 1
      assert result.returned_count == 1
      assert result.next_offset == nil

      row = hd(result.items)
      # Exact values, untouched. The whole point of the control.
      assert row.label == "Mobile nav"
      assert row.content == "Mobile screenshot"
      assert row.content_truncated == false
      assert row.feedback == "FAB overlaps the bottom nav"
      assert row.feedback_truncated == false
    end
  end
end
