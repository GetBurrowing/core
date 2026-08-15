defmodule Platform.Tasks.PlanSubmitInboxTest do
  @moduledoc """
  M3 (task 019f904c) — producer tests for the sponsor plan-review inbox row.

  `Platform.Tasks.submit_plan_for_review/1` emits exactly ONE
  `task_plan_review` inbox row to the task SPONSOR when a plan lands in
  `pending_review` for human review. The emit is a side effect only — the
  return value (`{:ok, %Plan{status: "pending_review"}}`) is invariant.

  Gating (all must hold to emit): the settled plan is `pending_review` (an
  auto-approved plan has no human gate), the task is not `auto_approve_plan`,
  a sponsor exists, the task is not terminal, and the sponsor did not author
  the plan themselves (self-notify guard). No dedup — a v2 plan superseding a
  rejected v1 emits another row.

  Not `async: true`: subscribes to the sponsor inbox PubSub topic and asserts
  broadcasts.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  # ── fixtures ───────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp sponsor_fixture do
    n = unique()

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "sponsor-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  defp agent_fixture(name \\ "Fixture Planner") do
    n = unique()

    Repo.insert!(%Agent{
      slug: "planner-#{n}",
      name: name,
      status: "active",
      kind: "native"
    })
  end

  defp project_fixture do
    {:ok, project} = Tasks.create_project(%{name: "Inbox Producer Project #{unique()}"})
    project
  end

  # Build a plan with `stage_count` stages and `validation_count` total
  # validations (spread across the stages) so the body string counts are
  # non-trivial and assertable.
  defp plan_with_stages(task, stage_count, validation_count) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    stages =
      for pos <- 1..stage_count do
        {:ok, stage} =
          Tasks.create_stage(%{plan_id: plan.id, position: pos, name: "Stage #{pos}"})

        stage
      end

    for i <- 1..validation_count do
      stage = Enum.at(stages, rem(i - 1, stage_count))
      {:ok, _v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
    end

    plan
  end

  defp submit(plan) do
    {result, _log} = with_log(fn -> Tasks.submit_plan_for_review(plan) end)
    result
  end

  # ── tests ──────────────────────────────────────────────────────────────

  describe "sponsored, non-auto-approve plan submit" do
    test "emits exactly one task_plan_review row to the sponsor and broadcasts it" do
      project = project_fixture()
      sponsor = sponsor_fixture()
      agent = agent_fixture("Ada Planner")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ship the widget",
          status: "planning",
          sponsor_user_id: sponsor.id,
          auto_approve_plan: false,
          phase_assignees: %{
            "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })

      plan = plan_with_stages(task, 2, 3)

      Inbox.subscribe(sponsor.id)

      assert {:ok, %Plan{status: "pending_review"}} = submit(plan)

      # Scope to the plan-review kind: creating a sponsored task now also
      # emits a `task_sponsor_assigned` row (M4, task 019f9251), so the
      # unfiltered inbox holds two rows.
      assert [item] = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")
      assert item.kind == "task_plan_review"
      assert item.source_type == "task"
      assert item.source_id == task.id
      assert item.title == "Plan ready for review: Ship the widget"
      assert item.url == "/tasks/#{task.id}"
      assert item.body == "Planner: Ada Planner · Stages: 2 · Validations: 3"

      assert_receive {:inbox_item_added, %Inbox.Item{id: added_id}}
      assert added_id == item.id
    end
  end

  describe "auto_approve_plan: true" do
    test "no inbox row — the auto-approve path has no human gate" do
      project = project_fixture()
      sponsor = sponsor_fixture()
      planner = agent_fixture()
      executor = agent_fixture("Exec")
      reviewer = agent_fixture("Reviewer")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto approved",
          status: "planning",
          sponsor_user_id: sponsor.id,
          auto_approve_plan: true,
          phase_assignees: %{
            "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
          }
        })

      plan = plan_with_stages(task, 1, 1)

      Inbox.subscribe(sponsor.id)

      # Precondition met (stage + exec/review assignees) → plan auto-approves.
      assert {:ok, %Plan{status: "approved"}} = submit(plan)

      # No plan-review row (auto-approve has no human gate). The sponsored
      # create still emits a `task_sponsor_assigned` row (M4, 019f9251), so
      # scope to the plan-review kind here.
      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == []
      refute_receive {:inbox_item_added, _}, 50
    end
  end

  describe "unsponsored task" do
    test "no inbox row — no recipient, but plan still reaches pending_review" do
      project = project_fixture()
      agent = agent_fixture()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Unsponsored",
          status: "planning",
          sponsor_user_id: nil,
          auto_approve_plan: false,
          phase_assignees: %{
            "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })

      plan = plan_with_stages(task, 1, 1)

      assert {:ok, %Plan{status: "pending_review"}} = submit(plan)
    end
  end

  describe "sponsor is the plan author (self-notify guard)" do
    test "no inbox row when the planning assignee is the sponsor user" do
      project = project_fixture()
      sponsor = sponsor_fixture()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Self planned",
          status: "planning",
          sponsor_user_id: sponsor.id,
          auto_approve_plan: false,
          phase_assignees: %{
            "planning" => %{"assignee_id" => sponsor.id, "assignee_type" => "user"}
          }
        })

      plan = plan_with_stages(task, 1, 1)

      Inbox.subscribe(sponsor.id)

      assert {:ok, %Plan{status: "pending_review"}} = submit(plan)

      # Self-notify guard suppresses the plan-review row. The task's create
      # emitted a `task_sponsor_assigned` row (M4, 019f9251) — and note that
      # here the sponsor IS the planning assignee, NOT the create actor
      # (no actor threaded), so the sponsor-assigned emit is not self-skipped.
      # Scope to the plan-review kind to assert the guard.
      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == []
      refute_receive {:inbox_item_added, _}, 50
    end
  end

  describe "v2 supersession" do
    test "a second submit emits a SECOND, distinct row" do
      project = project_fixture()
      sponsor = sponsor_fixture()
      agent = agent_fixture()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Two rounds",
          status: "planning",
          sponsor_user_id: sponsor.id,
          auto_approve_plan: false,
          phase_assignees: %{
            "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })

      plan_v1 = plan_with_stages(task, 1, 1)

      Inbox.subscribe(sponsor.id)

      assert {:ok, %Plan{status: "pending_review"} = submitted_v1} = submit(plan_v1)
      # Scope to plan-review rows — the sponsored create also emitted one
      # `task_sponsor_assigned` row (M4, 019f9251).
      assert [v1_row] = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")
      assert_receive {:inbox_item_added, %Inbox.Item{id: v1_id}}
      assert v1_id == v1_row.id

      # Reject v1 so a fresh draft can be created for v2.
      #
      # Task 01a00066 stage 5 CHANGED what this leaves behind: the rejection
      # now eagerly clears v1's row, because a rejected plan is a settled
      # one and the sponsor has nothing left to review. This test used to
      # assert the row was "left intact" — that surviving row was precisely
      # the stale-inbox defect the eager clear (and the reconciler behind
      # it) exists to remove. What the test is really about, and what still
      # holds, is that a second submit emits a SECOND row rather than
      # silently deduping against the first.
      {:ok, _rejected} = Tasks.reject_plan(submitted_v1, "reviewer")

      assert Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review") == []

      plan_v2 = plan_with_stages(task, 2, 2)

      assert {:ok, %Plan{status: "pending_review"}} = submit(plan_v2)

      assert [v2_row] = Inbox.list_unread_for_user(sponsor.id, kind: "task_plan_review")
      assert v2_row.id != v1_row.id

      assert_receive {:inbox_item_added, %Inbox.Item{id: v2_id}}
      assert v2_id == v2_row.id
      assert v2_id != v1_id
    end
  end
end
