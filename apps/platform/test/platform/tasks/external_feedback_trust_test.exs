defmodule Platform.Tasks.ExternalFeedbackTrustTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Task}

  setup do
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)

    {:ok, project} =
      Tasks.create_project(%{name: "External trust #{System.unique_integer([:positive])}"})

    %{project: project}
  end

  test "origin, trust, and external identity are independent persisted dimensions", %{
    project: project
  } do
    assert {:ok, internal} = Tasks.create_task(%{project_id: project.id, title: "Internal"})
    assert {internal.origin, internal.trust} == {"internal", "trusted"}
    assert is_nil(internal.external_repository_identity)
    assert is_nil(internal.external_issue_number)

    assert {:ok, external} = external_task(project, 41)
    assert external.kind == "bug"
    assert external.origin == "external_feedback"
    assert external.trust == "quarantined"
    assert external.external_repository_identity == "Startup-Suite/feedback"
    assert external.external_issue_number == 41

    refute Task.changeset(%Task{}, %{
             project_id: project.id,
             title: "Missing issue",
             origin: "external_feedback"
           }).valid?

    refute Task.changeset(%Task{}, %{
             project_id: project.id,
             title: "Internal contradiction",
             external_repository_identity: "x/y",
             external_issue_number: 1
           }).valid?

    constraints =
      Repo.query!("""
      SELECT conname FROM pg_constraint
      WHERE conname IN ('tasks_origin_valid', 'tasks_trust_valid', 'tasks_external_feedback_provenance_complete')
      ORDER BY conname
      """).rows
      |> List.flatten()

    assert constraints == [
             "tasks_external_feedback_provenance_complete",
             "tasks_origin_valid",
             "tasks_trust_valid"
           ]
  end

  test "repository and issue identity are unique for external feedback", %{project: project} do
    assert {:ok, _} = external_task(project, 42)
    assert {:error, changeset} = external_task(project, 42)
    assert "has already been taken" in errors_on(changeset).external_repository_identity
  end

  test "ordinary updates cannot forge trust or rewrite provenance", %{project: project} do
    assert {:ok, task} = external_task(project, 43)

    for attrs <- [
          %{trust: "trusted"},
          %{origin: "internal"},
          %{external_repository_identity: "other/repo"},
          %{external_issue_number: 999}
        ] do
      assert {:error, %Ecto.Changeset{} = changeset} = Tasks.update_task(task, attrs)
      refute changeset.valid?
    end

    persisted = Tasks.get_task_record(task.id)
    assert persisted.trust == "quarantined"
    assert persisted.origin == "external_feedback"
    assert persisted.external_repository_identity == "Startup-Suite/feedback"
    assert persisted.external_issue_number == 43
  end

  test "promotion requires actor and via, is audited, and retains provenance", %{project: project} do
    assert {:ok, task} = external_task(project, 44)

    assert {:error, :promotion_actor_required} =
             Tasks.promote_from_quarantine(task, :unattributed)

    assert {:error, :promotion_via_required} =
             Tasks.promote_from_quarantine(task, :system, via: "  ")

    actor_id = Ecto.UUID.generate()

    assert {:ok, promoted} =
             Tasks.promote_from_quarantine(task, {:user, actor_id},
               via: "external_feedback_review"
             )

    assert promoted.trust == "trusted"
    assert promoted.origin == "external_feedback"
    assert promoted.external_repository_identity == task.external_repository_identity
    assert promoted.external_issue_number == task.external_issue_number

    assert %Event{} =
             event =
             Repo.get_by(Event,
               event_type: "platform.tasks.external_feedback_promoted",
               resource_id: task.id
             )

    assert event.actor_type == "user"
    assert event.actor_id == actor_id
    assert event.action == "external_feedback_promoted"
    assert event.metadata["via"] == "external_feedback_review"
    assert event.metadata["origin"] == "external_feedback"
    assert event.metadata["external_issue_number"] == 44
  end

  test "all domain planning, transition, approval, and stage-start seams refuse quarantine", %{
    project: project
  } do
    assert {:ok, task} = external_task(project, 45)

    assert {:error, :quarantined, %{task_id: id}} = Tasks.create_plan(%{task_id: task.id})
    assert id == task.id

    for status <- ~w(planning stack_pending in_progress in_review deploying) do
      assert {:error, :quarantined, %{task_id: id}} = Tasks.transition_task_status(task, status)
      assert id == task.id
    end

    assert {:error, :quarantined, _} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Cannot arrive active",
               status: "planning",
               origin: "external_feedback",
               trust: "quarantined",
               external_repository_identity: "Startup-Suite/feedback",
               external_issue_number: 46
             })

    assert {:ok, trusted} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Seed guarded plan",
               origin: "external_feedback",
               trust: "trusted",
               external_repository_identity: "Startup-Suite/feedback",
               external_issue_number: 47
             })

    assert {:ok, plan} = Tasks.create_plan(%{task_id: trusted.id})
    assert {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

    Repo.update_all(from(t in Task, where: t.id == ^trusted.id), set: [trust: "quarantined"])

    assert {:error, :quarantined, _} = Tasks.submit_plan_for_review(plan)
    assert {:error, :quarantined, _} = PlanEngine.start_stage(stage.id)

    Repo.update_all(from(p in Plan, where: p.id == ^plan.id), set: [status: "pending_review"])
    pending = Repo.get!(Plan, plan.id)
    assert {:error, :quarantined, _} = Tasks.approve_plan(pending, "system")
  end

  test "trusted internal chore eligibility excludes external, quarantined, and non-backlog rows",
       %{project: project} do
    assert {:ok, eligible} =
             Tasks.create_task(%{project_id: project.id, title: "Eligible", kind: "chore"})

    assert {:ok, _external} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "External trusted chore",
               kind: "chore",
               origin: "external_feedback",
               trust: "trusted",
               external_repository_identity: "Startup-Suite/feedback",
               external_issue_number: 48
             })

    assert {:ok, _quarantined} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Internal quarantined chore",
               kind: "chore",
               trust: "quarantined"
             })

    assert {:ok, _done} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Done chore",
               kind: "chore",
               status: "done"
             })

    assert [row] = Repo.all(Tasks.trusted_internal_chore_query())
    assert row.id == eligible.id
  end

  # ── Added by Dalton on top of Geordi's stage-1 commit (2e607e870) ────
  #
  # Each test names, in a comment, whether it fails against 2e607e870 (the
  # previous tip of this branch) or only against the unfixed rollup base
  # 365b342a2 (where none of these fields exist and every test here fails).

  # Fails against 2e607e870: the schema default `trusted` applied to an
  # external row that did not state its trust.
  test "a new external-feedback row that omits trust is quarantined, not trusted", %{
    project: project
  } do
    assert {:ok, task} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "No trust stated",
               kind: "bug",
               origin: "external_feedback",
               external_repository_identity: "Startup-Suite/feedback",
               external_issue_number: 60
             })

    assert task.trust == "quarantined"
    assert Tasks.get_task_record(task.id).trust == "quarantined"

    # An internal row that omits trust keeps the trusted default.
    assert {:ok, internal} = Tasks.create_task(%{project_id: project.id, title: "Internal"})
    assert internal.trust == "trusted"
  end

  # Fails against 2e607e870: the index was case-sensitive, so one GitHub
  # issue spelled two ways produced two tasks.
  test "repository identity deduplicates case-insensitively", %{project: project} do
    assert {:ok, first} = external_task(project, 61)
    assert first.external_repository_identity == "Startup-Suite/feedback"

    assert {:error, changeset} =
             Tasks.create_task(%{
               project_id: project.id,
               title: "Same issue, other casing",
               origin: "external_feedback",
               trust: "quarantined",
               external_repository_identity: "startup-suite/FEEDBACK",
               external_issue_number: 61
             })

    assert "has already been taken" in errors_on(changeset).external_repository_identity

    # Same repository, different issue: a distinct identity.
    assert {:ok, _} = external_task(project, 62)
  end

  # Fails against 2e607e870: any non-empty string was accepted.
  test "repository identity must be owner/repository", %{project: project} do
    for bad <- ["feedback", "a/b/c", "/repo", "owner/", "owner/re po", "https://github.com/a/b"] do
      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          title: "Bad identity",
          origin: "external_feedback",
          trust: "quarantined",
          external_repository_identity: bad,
          external_issue_number: 1
        })

      refute changeset.valid?, "accepted #{inspect(bad)}"
      assert errors_on(changeset)[:external_repository_identity]
    end
  end

  # Fails against 2e607e870: its changeset guard only ran on :update, so a
  # writer inserting through Task.changeset/2 without Tasks.create_task/2
  # could persist a quarantined row already in `planning`.
  test "the changeset refuses a quarantined row born into planning or execution", %{
    project: project
  } do
    for status <- ~w(planning stack_pending in_progress in_review deploying) do
      result =
        %Task{}
        |> Task.changeset(%{
          project_id: project.id,
          title: "Born active",
          status: status,
          origin: "external_feedback",
          trust: "quarantined",
          external_repository_identity: "Startup-Suite/feedback",
          external_issue_number: 70 + String.length(status)
        })
        |> Repo.insert()

      assert {:error, changeset} = result, "inserted quarantined row at #{status}"
      assert errors_on(changeset)[:status]
    end

    assert Repo.aggregate(from(t in Task, where: t.title == "Born active"), :count) == 0
  end

  # Coverage of the remaining domain status writers (passes against
  # 2e607e870; fails against the base, which has no trust column).
  test "update_task/2 and transition_task/3 refuse every dispatch-bearing status", %{
    project: project
  } do
    assert {:ok, task} = external_task(project, 80)

    id = task.id

    # update_task/2 has no transition precheck; the Task.changeset/2 guard
    # is its only line, so it answers a changeset carrying the status error.
    for status <- ~w(planning stack_pending in_progress in_review deploying) do
      assert {:error, %Ecto.Changeset{} = changeset} = Tasks.update_task(task, %{status: status})

      assert errors_on(changeset).status == [
               "cannot enter planning or execution while task trust is quarantined"
             ]

      assert {:error, :quarantined, %{task_id: ^id}} =
               Tasks.transition_task(task, status, {:user, Ecto.UUID.generate()})
    end

    assert Tasks.get_task_record(task.id).status == "backlog"

    # Parking and retiring stay allowed: quarantine refuses work, not triage.
    assert {:ok, blocked} = Tasks.update_task(task, %{status: "blocked"})
    assert blocked.status == "blocked"
  end

  # Fails against 2e607e870 on both halves: a struct reading `trusted`
  # short-circuited without promoting the quarantined row, and a second
  # promoter holding a stale quarantined struct emitted a second audit row.
  test "promotion decides on the persisted row, not the caller's struct", %{project: project} do
    assert {:ok, task} = external_task(project, 81)
    actor = {:user, Ecto.UUID.generate()}

    stale_trusted = %{task | trust: "trusted"}
    assert {:ok, promoted} = Tasks.promote_from_quarantine(stale_trusted, actor, via: "review")
    assert promoted.trust == "trusted"
    assert Tasks.get_task_record(task.id).trust == "trusted"

    # `task` still says quarantined; the row does not.
    assert {:ok, again} = Tasks.promote_from_quarantine(task, actor, via: "review")
    assert again.trust == "trusted"

    assert Repo.aggregate(
             from(e in Event,
               where:
                 e.event_type == "platform.tasks.external_feedback_promoted" and
                   e.resource_id == ^task.id
             ),
             :count
           ) == 1
  end

  # Coverage: after an attributed promotion the ordinary lifecycle works
  # (passes against 2e607e870; fails against the base).
  test "after promotion the ordinary plan and execution path is open", %{project: project} do
    assert {:ok, task} = external_task(project, 82)
    assert {:error, :quarantined, _} = Tasks.create_plan(%{task_id: task.id})

    assert {:ok, promoted} =
             Tasks.promote_from_quarantine(task, {:user, Ecto.UUID.generate()},
               via: "external_feedback_review"
             )

    assert {:ok, planning} = Tasks.transition_task_status(promoted, "planning")
    assert planning.status == "planning"

    assert {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    assert {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    assert {:ok, submitted} = Tasks.submit_plan_for_review(plan)
    assert submitted.status == "pending_review"
    assert {:ok, approved} = Tasks.approve_plan(submitted, "system")
    assert approved.status == "approved"
    assert {:ok, _} = PlanEngine.start_stage(stage.id)

    persisted = Tasks.get_task_record(task.id)
    assert persisted.origin == "external_feedback"
    assert persisted.external_repository_identity == "Startup-Suite/feedback"
    assert persisted.external_issue_number == 82
  end

  defp external_task(project, issue_number) do
    Tasks.create_task(%{
      project_id: project.id,
      title: "External issue #{issue_number}",
      kind: "bug",
      origin: "external_feedback",
      trust: "quarantined",
      external_repository_identity: "Startup-Suite/feedback",
      external_issue_number: issue_number
    })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
