defmodule Platform.Federation.ToolSurfaceExternalFeedbackTrustTest do
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Task}

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Transport quarantine #{System.unique_integer([:positive])}"})

    %{project: project}
  end

  test "create, update, read, and list envelopes carry provenance without update promotion", %{
    project: project
  } do
    args = %{
      "project_id" => project.id,
      "title" => "External report",
      "kind" => "bug",
      "origin" => "external_feedback",
      "trust" => "quarantined",
      "external_repository_identity" => "Startup-Suite/feedback",
      "external_issue_number" => 91
    }

    assert {:ok, created} = ToolSurface.execute("task_create", args, %{})
    assert created.kind == "bug"
    assert created.origin == "external_feedback"
    assert created.trust == "quarantined"
    assert created.external_repository_identity == "Startup-Suite/feedback"
    assert created.external_issue_number == 91

    assert {:ok, fetched} =
             ToolSurface.execute("task_get", %{"task_id" => created.id}, %{})

    assert Map.take(fetched, [
             :origin,
             :trust,
             :external_repository_identity,
             :external_issue_number
           ]) ==
             Map.take(created, [
               :origin,
               :trust,
               :external_repository_identity,
               :external_issue_number
             ])

    assert {:ok, listed} =
             ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

    listed_task = Enum.find(listed.tasks, &(&1.id == created.id))
    assert listed_task.origin == "external_feedback"
    assert listed_task.trust == "quarantined"
    assert listed_task.external_issue_number == 91

    assert {:error, update_error} =
             ToolSurface.execute(
               "task_update",
               %{"task_id" => created.id, "trust" => "trusted"},
               %{}
             )

    assert inspect(update_error) =~ "trust"
    assert Tasks.get_task_record(created.id).trust == "quarantined"
  end

  test "all federation planning and execution handlers return quarantine envelopes", %{
    project: project
  } do
    assert {:ok, trusted} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Transport guarded",
               origin: "external_feedback",
               trust: "trusted",
               external_repository_identity: "Startup-Suite/feedback",
               external_issue_number: 92
             })

    assert {:ok, plan} = Tasks.create_plan(%{task_id: trusted.id})
    assert {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

    Repo.update_all(from(t in Task, where: t.id == ^trusted.id), set: [trust: "quarantined"])

    for {tool, args} <- [
          {"task_start", %{"task_id" => trusted.id}},
          {"plan_create", %{"task_id" => trusted.id, "stages" => []}},
          {"plan_submit", %{"plan_id" => plan.id}},
          {"stage_start", %{"stage_id" => stage.id}}
        ] do
      assert {:error, envelope} = ToolSurface.execute(tool, args, %{})
      assert envelope.recoverable == false
      assert envelope.quarantine.task_id == trusted.id
      assert envelope.quarantine.trust == "quarantined"
    end

    Repo.update_all(from(p in Plan, where: p.id == ^plan.id), set: [status: "pending_review"])

    assert {:error, envelope} =
             ToolSurface.execute("plan_approve", %{"plan_id" => plan.id}, %{})

    assert envelope.quarantine.task_id == trusted.id
    assert envelope.recoverable == false
  end

  # Fails against 2e607e870: task_update's `with` had no arm for the
  # 3-tuple quarantine refusal, so this raised WithClauseError (a 500 on
  # the wire) instead of answering.
  test "task_update into planning answers a quarantine envelope instead of raising", %{
    project: project
  } do
    {:ok, created} =
      ToolSurface.execute(
        "task_create",
        %{
          "project_id" => project.id,
          "title" => "External via update",
          "origin" => "external_feedback",
          "trust" => "quarantined",
          "external_repository_identity" => "Startup-Suite/feedback",
          "external_issue_number" => 93
        },
        %{}
      )

    assert created.trust == "quarantined"

    assert {:error, envelope} =
             ToolSurface.execute(
               "task_update",
               %{"task_id" => created.id, "status" => "planning"},
               %{}
             )

    assert envelope.recoverable == false
    assert envelope.quarantine.task_id == created.id
    assert Tasks.get_task_record(created.id).status == "backlog"
  end

  # Fails against 2e607e870: an MCP caller could mint a TRUSTED external
  # row, pre-claiming that repository+issue identity for a later intake.
  test "task_create cannot mint trusted external feedback", %{project: project} do
    base = %{
      "project_id" => project.id,
      "title" => "Minted",
      "origin" => "external_feedback",
      "external_repository_identity" => "Startup-Suite/feedback",
      "external_issue_number" => 94
    }

    assert {:error, envelope} =
             ToolSurface.execute("task_create", Map.put(base, "trust", "trusted"), %{})

    assert envelope.error =~ "quarantined"
    assert envelope.recoverable == true

    assert Repo.aggregate(
             from(t in Task,
               where:
                 t.external_repository_identity == "Startup-Suite/feedback" and
                   t.external_issue_number == 94
             ),
             :count
           ) == 0

    # An internal task may still say trusted explicitly (the default).
    assert {:ok, internal} =
             ToolSurface.execute(
               "task_create",
               %{"project_id" => project.id, "title" => "Internal", "trust" => "trusted"},
               %{}
             )

    assert internal.trust == "trusted"
  end

  # Fails against 2e607e870: Tasks.create_task/2 refused with a 3-tuple
  # that task_create's `with` had no arm for, so this raised
  # WithClauseError (a 500 on the wire).
  test "task_create of quarantined feedback straight into planning answers an envelope", %{
    project: project
  } do
    args = %{
      "project_id" => project.id,
      "title" => "Born planning",
      "status" => "planning",
      "origin" => "external_feedback",
      "trust" => "quarantined",
      "external_repository_identity" => "Startup-Suite/feedback",
      "external_issue_number" => 95
    }

    assert {:error, envelope} = ToolSurface.execute("task_create", args, %{})
    assert envelope.recoverable == false
    assert envelope.quarantine.trust == "quarantined"

    assert Repo.aggregate(from(t in Task, where: t.title == "Born planning"), :count) == 0
  end

  test "tool definitions document independent create and immutable update provenance" do
    tools = ToolSurface.tool_definitions()
    create = Enum.find(tools, &(&1.name == "task_create"))
    update = Enum.find(tools, &(&1.name == "task_update"))

    for tool <- [create, update],
        field <- [:origin, :trust, :external_repository_identity, :external_issue_number] do
      assert Map.has_key?(tool.parameters, field)
      assert tool.parameters[field].required == false
    end

    assert create.parameters.external_issue_number.type == "integer"
    assert update.parameters.trust.description =~ "cannot promote"
  end
end
