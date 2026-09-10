defmodule Platform.Tasks.PlanAutoApprovePolicyTest do
  # task 01a08c1e stage 2: the project-level `config["plan_auto_approve"]`
  # policy arms `maybe_auto_approve/1` (via `:project_policy`) for a
  # submitted plan that fits it. Every case here runs the real
  # `Tasks.submit_plan_for_review/1` tail; no architect is assigned, so
  # the ADR-0046 gate never opens and the tail settles synchronously.
  use Platform.DataCase, async: false

  import Platform.SubmittablePlanFixtures

  alias Platform.Tasks

  @exec_id "00000000-0000-0000-0000-00000000aa01"
  @review_id "00000000-0000-0000-0000-00000000aa02"

  defp create_project(policy) do
    config = if policy, do: %{"plan_auto_approve" => policy}, else: %{}

    {:ok, project} =
      Tasks.create_project(%{name: "Policy #{System.unique_integer()}", config: config})

    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Policy task",
            status: "planning",
            auto_approve_plan: false,
            phase_assignees: %{
              "execution" => %{"assignee_id" => @exec_id, "assignee_type" => "agent"},
              "review" => %{"assignee_id" => @review_id, "assignee_type" => "agent"}
            }
          },
          attrs
        )
      )

    task
  end

  # A draft with `count` planner-authored stages; `manual_approval_on`
  # names the position (if any) that carries a manual_approval gate.
  defp create_plan(task, count, opts \\ []) do
    {:ok, plan} = create_submittable_plan(%{task_id: task.id}, %{position: 1, name: "S1"})

    for position <- 2..count//1 do
      {:ok, _} = create_authored_stage(plan, %{position: position, name: "S#{position}"})
    end

    if gated = Keyword.get(opts, :manual_approval_on) do
      stage = Tasks.list_stages(plan.id) |> Enum.find(&(&1.position == gated))

      {:ok, _} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "manual_approval",
          evaluation_payload: %{"ui_surface" => "the thing"}
        })
    end

    plan
  end

  describe "project plan_auto_approve policy" do
    test "a fitting plan lands approved via system:project_policy" do
      project = create_project(%{"enabled" => true, "max_stages" => 5})
      task = create_task(project)
      plan = create_plan(task, 3)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "approved"
      assert submitted.approved_by == "system:project_policy"
      refute is_nil(submitted.auto_approved_at)
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "a plan with more implementation stages than max_stages stays pending_review" do
      project = create_project(%{"enabled" => true, "max_stages" => 5})
      task = create_task(project)
      plan = create_plan(task, 6)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "pending_review"
      assert is_nil(submitted.approved_by)
    end

    test "a plan at exactly max_stages fits" do
      project = create_project(%{"enabled" => true, "max_stages" => 3})
      task = create_task(project)
      plan = create_plan(task, 3)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "approved"
      assert submitted.approved_by == "system:project_policy"
    end

    test "a deploy: stage does not count against max_stages" do
      project = create_project(%{"enabled" => true, "max_stages" => 3})
      task = create_task(project)
      plan = create_plan(task, 3)
      {:ok, _} = create_authored_stage(plan, %{position: 4, name: "deploy: production"})

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "approved"
    end

    test "a manual_approval gate keeps the plan pending_review by default" do
      project = create_project(%{"enabled" => true, "max_stages" => 5})
      task = create_task(project)
      plan = create_plan(task, 3, manual_approval_on: 2)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "pending_review"
    end

    test "allow_manual_approval: true lets a manual_approval-gated plan through" do
      project =
        create_project(%{"enabled" => true, "max_stages" => 5, "allow_manual_approval" => true})

      task = create_task(project)
      plan = create_plan(task, 3, manual_approval_on: 2)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "approved"
      assert submitted.approved_by == "system:project_policy"
    end

    test "a disabled policy leaves the plan pending_review" do
      project = create_project(%{"enabled" => false, "max_stages" => 5})
      task = create_task(project)
      plan = create_plan(task, 3)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "pending_review"
    end

    test "no policy leaves the plan pending_review" do
      project = create_project(nil)
      task = create_task(project)
      plan = create_plan(task, 1)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "pending_review"
    end

    test "regression: auto_approve_plan on the task still approves via :task in a policy-less project" do
      project = create_project(nil)
      task = create_task(project, %{auto_approve_plan: true})
      plan = create_plan(task, 3)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "approved"
      assert submitted.approved_by == "system:auto"
    end

    test "the policy only arms: a missing review assignee still skips" do
      project = create_project(%{"enabled" => true, "max_stages" => 5})

      task =
        create_task(project, %{
          phase_assignees: %{
            "execution" => %{"assignee_id" => @exec_id, "assignee_type" => "agent"}
          }
        })

      plan = create_plan(task, 2)

      {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert submitted.status == "pending_review"
    end
  end
end
