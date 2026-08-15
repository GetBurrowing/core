defmodule Platform.Federation.PlanGetStatusToolTest do
  @moduledoc """
  Task 01a006c2 stage 3 — `plan_get` widened with an explicit,
  default-preserving `status` argument.

  ## The load-bearing test in this file is the boring one

  The interesting behaviour is `status: "rejected"` surfacing a
  `rejection_reason`. The DANGEROUS behaviour is the default path
  quietly starting to resolve the LATEST plan instead of the current
  approved one — because every existing caller omits `status`, and a
  default that drifts to "latest" would hand a caller a draft or a
  rejected plan while it believes it is holding the plan the task is
  executing. Nothing about the response shape would tell it otherwise.

  So the default is asserted on BOTH legs: the hit (an approved v1 is
  returned even though a newer rejected v2 exists) and the miss (the
  historical `"No approved plan for task"` envelope, verbatim, when only
  an unapproved plan exists). The miss leg is the one with teeth: a
  widened default would return the draft and never produce the string.

  Every assertion is against `ToolSurface.execute/3`, never the
  registration map — a registration can advertise a parameter the
  handler ignores, and that is exactly the failure mode being guarded.

  Not `async: true`: plan approval settles through `maybe_auto_approve/1`
  and broadcasts on `tasks:board`, matching the other plan tool tests.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "plan_get status #{u()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "plan_get status fixture #{u()}",
        status: "planning"
      })

    %{project: project, task: task}
  end

  # Inserted through `Repo.insert!` so a terminal status (rejected) can be
  # written directly — going through the engine would require walking a
  # transition chain that is not what this stage is testing.
  defp plan!(task, version, status, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Plan{
          task_id: task.id,
          version: version,
          status: status
        },
        attrs
      )
    )
  end

  describe "no `status` argument — today's behaviour, unchanged" do
    test "hit: returns the approved plan even when a newer plan exists", %{task: task} do
      approved = plan!(task, 1, "approved")
      _newer_rejected = plan!(task, 2, "rejected", %{rejection_reason: "scope too broad"})

      assert {:ok, result} = ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      # If the default had drifted to "latest", this would be v2.
      assert result.id == approved.id
      assert result.version == 1
      assert result.status == "approved"
      assert result.is_current == true
    end

    test "miss: the historical error envelope, verbatim", %{task: task} do
      # Positive control for the miss: a plan DOES exist for this task, it
      # is simply not approved. A widened default would return it and this
      # assertion would never see an error at all.
      draft = plan!(task, 1, "draft")

      assert {:error, err} = ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})
      assert err.error == "No approved plan for task"
      assert err.recoverable == false
      assert err.suggestion == "Create a plan with plan_create and approve it first"

      # Control: the draft is reachable, so the error above is about the
      # DEFAULT resolution and not about an empty task.
      assert {:ok, reachable} =
               ToolSurface.execute("plan_get", %{"task_id" => task.id, "status" => "latest"}, %{})

      assert reachable.id == draft.id
    end

    test "`status: \"approved\"` is the same path as omitting it", %{task: task} do
      approved = plan!(task, 1, "approved")
      _rejected = plan!(task, 2, "rejected")

      assert {:ok, explicit} =
               ToolSurface.execute(
                 "plan_get",
                 %{"task_id" => task.id, "status" => "approved"},
                 %{}
               )

      assert {:ok, implicit} = ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})
      assert explicit == implicit
      assert explicit.id == approved.id
    end
  end

  describe "reading a plan the default resolution hides" do
    test "`status: \"rejected\"` carries rejection_reason, architecture_verdict, is_current false",
         %{task: task} do
      _approved = plan!(task, 1, "approved")

      rejected =
        plan!(task, 2, "rejected", %{
          rejection_reason: "stage 2 has no rollback",
          architecture_verdict: %{"state" => "rejected", "source" => "mcp"}
        })

      assert {:ok, result} =
               ToolSurface.execute(
                 "plan_get",
                 %{"task_id" => task.id, "status" => "rejected"},
                 %{}
               )

      assert result.id == rejected.id
      assert result.status == "rejected"
      assert result.rejection_reason == "stage 2 has no rollback"
      assert result.architecture_verdict["state"] == "rejected"

      # The whole point: this must not be mistaken for the current plan,
      # which exists and is a DIFFERENT plan.
      assert result.is_current == false
    end

    test "`status: \"latest\"` surfaces a pending_review plan blocking plan_create", %{task: task} do
      _approved = plan!(task, 1, "approved")
      pending = plan!(task, 2, "pending_review")

      assert {:ok, result} =
               ToolSurface.execute("plan_get", %{"task_id" => task.id, "status" => "latest"}, %{})

      assert result.id == pending.id
      assert result.status == "pending_review"
      assert result.is_current == false

      # "any" is documented as an alias of "latest"; assert it, do not
      # assume the handler wired both.
      assert {:ok, ^result} =
               ToolSurface.execute("plan_get", %{"task_id" => task.id, "status" => "any"}, %{})
    end

    test "an explicit status picks the HIGHEST version with that status", %{task: task} do
      _old = plan!(task, 1, "rejected", %{rejection_reason: "first pass"})
      newer = plan!(task, 3, "rejected", %{rejection_reason: "second pass"})
      _draft = plan!(task, 4, "draft")

      assert {:ok, result} =
               ToolSurface.execute(
                 "plan_get",
                 %{"task_id" => task.id, "status" => "rejected"},
                 %{}
               )

      assert result.id == newer.id
      assert result.rejection_reason == "second pass"
    end
  end

  describe "refusals" do
    test "an unknown status is a non-recoverable error, never a fallback to approved", %{
      task: task
    } do
      # Positive control: an approved plan EXISTS. A silent fallback would
      # therefore succeed here, which is the failure this test exists for.
      approved = plan!(task, 1, "approved")

      assert {:error, err} =
               ToolSurface.execute(
                 "plan_get",
                 %{"task_id" => task.id, "status" => "aproved"},
                 %{}
               )

      assert err.recoverable == false
      assert err.error =~ "unknown `status`"

      # Scan the WHOLE envelope, not just `error`: the refusal must not
      # leak the plan it declined to resolve.
      refute inspect(err) =~ approved.id
    end

    test "a call naming no task is refused rather than answered", %{task: _task} do
      assert {:error, err} = ToolSurface.execute("plan_get", %{}, %{})
      assert err.error =~ "`task_id` is required"

      # Specifically NOT the plan-resolution error — that envelope would be
      # a confident answer about a task the caller never identified.
      refute err.error =~ "No approved plan"
    end

    test "the registered `id` alias still resolves", %{task: task} do
      approved = plan!(task, 1, "approved")
      assert {:ok, result} = ToolSurface.execute("plan_get", %{"id" => task.id}, %{})
      assert result.id == approved.id
    end
  end
end
