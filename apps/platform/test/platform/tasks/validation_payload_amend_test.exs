defmodule Platform.Tasks.ValidationPayloadAmendTest do
  @moduledoc """
  Task 01a0acb4 stage 1 — `Tasks.amend_validation_payload/4`, the in-place
  correction of ONE `e2e_behavior` case on an approved/executing plan.

  Three properties carry the design and each has a test that a named
  mutation turns red:

    * the history is APPEND-only (`existing ++ [entry]`), so a second
      amendment cannot erase the first;
    * only a `pending` row is amended, so a verdict is never detached from
      the text it measured;
    * the write touches ONLY the target row. That one is checked by a full
      before/after snapshot of every validation, stage, plan and task row of
      this task AND an unrelated one — and the comparator is shown to fire in
      the same test, because a diff that has never reported anything is not
      evidence that nothing changed.

  Every refusal re-reads the target row and asserts it is unchanged.
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Stage, Task, Validation}

  @payload %{
    "setup" => "A task with a merged PR",
    "actions" => "curl the endpoint with X-Forwarded-Host set",
    "expected" => "The endpoint answers 200"
  }

  @amended %{
    "setup" => "A task with a merged PR",
    "actions" => "curl the endpoint without X-Forwarded-Host",
    "expected" => "The endpoint answers 200"
  }

  @actor {"planner-agent", "agent"}

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp seed(opts \\ []) do
    plan_status = Keyword.get(opts, :plan_status, "approved")
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Amend Project #{n}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Amend Task #{n}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, impl} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Land the change"})
    {:ok, gate} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Task-level review"})

    {:ok, test_pass} = Tasks.create_validation(%{stage_id: impl.id, kind: "test_pass"})

    {:ok, a} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "e2e_behavior",
        evaluation_payload: @payload
      })

    {:ok, b} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "e2e_behavior",
        evaluation_payload: Map.put(@payload, "expected", "Sibling case B")
      })

    {:ok, pr_merged} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "pr_merged",
        evaluation_payload: %{"repo" => "Startup-Suite/core"}
      })

    plan =
      if plan_status == "draft",
        do: plan,
        else: plan |> Plan.changeset(%{status: plan_status}) |> Repo.update!()

    %{
      project: project,
      task: task,
      plan: plan,
      impl: impl,
      gate: gate,
      a: a,
      b: b,
      test_pass: test_pass,
      pr_merged: pr_merged
    }
  end

  defp amend(validation_or_id, payload, reason \\ "actions sent a header the pipeline refuses")

  defp amend(%Validation{id: id}, payload, reason), do: amend(id, payload, reason)

  defp amend(id, payload, reason), do: Tasks.amend_validation_payload(id, payload, reason, @actor)

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)

  defp set_status!(%Validation{} = v, status) do
    v |> Ecto.Changeset.change(%{status: status}) |> Repo.update!()
  end

  # Every row of the four tables that belongs to the given tasks, keyed by
  # {schema, id}, as full column maps (incl. updated_at), associations out.
  defp snapshot(task_ids) do
    plans = Repo.all(from(p in Plan, where: p.task_id in ^task_ids))
    plan_ids = Enum.map(plans, & &1.id)
    stages = Repo.all(from(s in Stage, where: s.plan_id in ^plan_ids))
    stage_ids = Enum.map(stages, & &1.id)
    validations = Repo.all(from(v in Validation, where: v.stage_id in ^stage_ids))
    tasks = Repo.all(from(t in Task, where: t.id in ^task_ids))

    for row <- plans ++ stages ++ validations ++ tasks, into: %{} do
      {{row.__struct__, row.id}, columns(row)}
    end
  end

  defp columns(row) do
    row
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Map.new()
  end

  # The keys whose rows differ, appeared or vanished between two snapshots.
  defp changed_keys(before, after_) do
    (Map.keys(before) ++ Map.keys(after_))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(after_, &1)))
    |> Enum.sort()
  end

  defp assert_refused(%Validation{} = target, expected, payload \\ @amended, reason \\ nil) do
    before = columns(reload(target))

    result =
      if reason,
        do: amend(target, payload, reason),
        else: amend(target, payload)

    assert result == {:error, expected}
    assert columns(reload(target)) == before
    result
  end

  @forged [%{"prior_payload" => %{"setup" => "forged"}, "amended_by" => "nobody"}]

  defp forged_stages do
    [
      %{
        "name" => "Land the change",
        "description" => "Do it",
        "position" => 1,
        "validations" => [
          %{"kind" => "test_pass", "payload_amendments" => @forged},
          %{
            "kind" => "e2e_behavior",
            "evaluation_payload" => @payload,
            "payload_amendments" => @forged
          }
        ]
      }
    ]
  end

  defp all_validations(plan_id) do
    Repo.all(
      from(v in Validation,
        join: s in Stage,
        on: s.id == v.stage_id,
        where: s.plan_id == ^plan_id
      )
    )
  end

  # ── Happy path ──────────────────────────────────────────────────────────

  describe "amending a pending e2e case" do
    test "replaces the payload, records one history entry, and leaves status pending" do
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
      ctx = seed()

      assert {:ok, updated} = amend(ctx.a, @amended)

      row = reload(ctx.a)
      assert row.evaluation_payload == @amended
      assert row.status == "pending"
      assert updated.status == "pending"

      assert [entry] = row.payload_amendments
      assert entry["prior_payload"] == @payload
      assert entry["amended_by"] == "planner-agent"
      assert entry["actor_type"] == "agent"
      assert entry["reason"] == "actions sent a header the pipeline refuses"
      assert entry["last_ruling"] == nil
      assert {:ok, _, _} = DateTime.from_iso8601(entry["amended_at"])

      events = Platform.Audit.list(event_type: "platform.tasks.validation_payload_amended")

      assert Enum.any?(events, fn e ->
               e.resource_type == "validation" and e.resource_id == ctx.a.id and
                 e.action == "validation_payload_amended" and e.actor_type == "agent" and
                 e.metadata["amended_by"] == "planner-agent" and
                 e.metadata["plan_id"] == ctx.plan.id and
                 e.metadata["task_id"] == ctx.task.id and
                 e.metadata["stage_id"] == ctx.gate.id and
                 e.metadata["prior_payload"] == @payload and
                 e.metadata["reason"] == "actions sent a header the pipeline refuses"
             end)
    end

    test "an executing plan is amendable too" do
      ctx = seed(plan_status: "executing")
      assert {:ok, _} = amend(ctx.a, @amended)
      assert reload(ctx.a).evaluation_payload == @amended
    end

    test "broadcasts {:plan_updated, plan} on the task's board topic" do
      ctx = seed()
      :ok = Tasks.subscribe_board([{:task, ctx.task.id}])

      assert {:ok, _} = amend(ctx.a, @amended)

      plan_id = ctx.plan.id
      assert_receive {:plan_updated, %Plan{id: ^plan_id}}
    end

    test "a second amendment appends and leaves the first entry unchanged" do
      ctx = seed()
      second = Map.put(@amended, "expected", "The endpoint answers 204")

      assert {:ok, _} = amend(ctx.a, @amended, "first correction")
      [first_entry] = reload(ctx.a).payload_amendments

      assert {:ok, _} = amend(ctx.a, second, "second correction")
      row = reload(ctx.a)

      assert row.evaluation_payload == second
      assert [entry1, entry2] = row.payload_amendments
      assert entry1 == first_entry
      assert entry1["prior_payload"] == @payload
      assert entry2["prior_payload"] == @amended
      assert entry2["reason"] == "second correction"
    end

    test "an atom-keyed payload is stored string-keyed" do
      ctx = seed()

      assert {:ok, _} =
               amend(ctx.a, %{setup: "s2", actions: "a2", expected: "e2"})

      assert reload(ctx.a).evaluation_payload == %{
               "setup" => "s2",
               "actions" => "a2",
               "expected" => "e2"
             }
    end

    test "last_ruling captures the ruling archived by a real remediation re-pend" do
      ctx = seed()

      # Drive the gate the way the engine does: a running stage, a real failed
      # verdict through the lifecycle writer, then the remediation re-pend
      # that archives the ruling into prior_rulings.
      ctx.gate |> Stage.changeset(%{status: "running"}) |> Repo.update!()

      {:ok, _} =
        PlanEngine.evaluate_validation(ctx.a.id, %{
          status: "failed",
          evidence: %{"observed" => "the pipeline refused X-Forwarded-Host with 400"},
          evaluated_by: "review-agent"
        })

      assert reload(ctx.a).status == "failed"
      assert {:ok, _stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

      repended = reload(ctx.a)
      assert repended.status == "pending"
      assert [ruling] = repended.evidence["prior_rulings"]

      assert {:ok, _} = amend(ctx.a, @amended)

      assert [entry] = reload(ctx.a).payload_amendments
      assert entry["last_ruling"] == ruling
      assert entry["last_ruling"]["status"] == "failed"

      assert entry["last_ruling"]["evidence"]["observed"] ==
               "the pipeline refused X-Forwarded-Host with 400"
    end
  end

  # ── Blast radius ────────────────────────────────────────────────────────

  describe "other rows" do
    test "only the target validation changes; the comparator is shown to fire" do
      ctx = seed()
      other = seed()
      task_ids = [ctx.task.id, other.task.id]

      before = snapshot(task_ids)
      # The snapshot covers what it claims to: both tasks, both plans, all
      # four stages, all eight validations.
      assert map_size(before) == 2 + 2 + 4 + 8

      assert {:ok, _} = amend(ctx.a, @amended)

      after_ = snapshot(task_ids)
      assert changed_keys(before, after_) == [{Validation, ctx.a.id}]

      # POSITIVE CONTROL: the same comparator reports a sibling written
      # through Repo.update. Without this, an empty diff would be
      # indistinguishable from a comparator that cannot see changes.
      ctx.b
      |> Ecto.Changeset.change(%{evaluation_payload: Map.put(@payload, "expected", "touched")})
      |> Repo.update!()

      assert changed_keys(after_, snapshot(task_ids)) == [{Validation, ctx.b.id}]
    end
  end

  # ── Refusals ────────────────────────────────────────────────────────────

  describe "refusals leave the target row unchanged" do
    test "test_pass is not e2e_behavior" do
      ctx = seed()
      assert_refused(ctx.test_pass, :not_e2e_behavior)
    end

    test "pr_merged (a deploy gate carrying repo) is not e2e_behavior" do
      ctx = seed()
      assert_refused(ctx.pr_merged, :not_e2e_behavior, %{"repo" => "attacker/fork"})
      assert reload(ctx.pr_merged).evaluation_payload == %{"repo" => "Startup-Suite/core"}
    end

    test "a draft plan is plan_update's job" do
      ctx = seed(plan_status: "draft")
      assert_refused(ctx.a, :plan_not_amendable)
    end

    test "a completed plan is history" do
      ctx = seed(plan_status: "completed")
      assert_refused(ctx.a, :plan_not_amendable)
    end

    test "a superseded plan is history" do
      ctx = seed()

      from(t in Task, where: t.id == ^ctx.task.id)
      |> Repo.update_all(set: [status: "in_progress"])

      assert {:ok, _} = Tasks.supersede_current_plan(ctx.task.id, "re-plan", "planner-agent")
      assert Repo.get!(Plan, ctx.plan.id).status == "superseded"

      assert_refused(ctx.a, :plan_not_amendable)
    end

    test "a passed case is not re-opened" do
      ctx = seed()
      a = set_status!(ctx.a, "passed")
      assert_refused(a, {:validation_not_pending, "passed"})
    end

    test "a failed case waits for the remediation re-pend" do
      ctx = seed()
      a = set_status!(ctx.a, "failed")
      assert_refused(a, {:validation_not_pending, "failed"})
    end

    test "a running case is under evaluation" do
      ctx = seed()
      a = set_status!(ctx.a, "running")
      assert_refused(a, {:validation_not_pending, "running"})
    end

    test "a skipped case is not re-opened" do
      ctx = seed()
      a = set_status!(ctx.a, "skipped")
      assert_refused(a, {:validation_not_pending, "skipped"})
    end

    test "a blank reason is refused" do
      ctx = seed()
      assert_refused(ctx.a, :reason_required, @amended, "   \n ")

      assert {:error, :reason_required} =
               Tasks.amend_validation_payload(ctx.a.id, @amended, nil, @actor)
    end

    test "an unchanged payload is refused (no empty history entries)" do
      ctx = seed()
      assert_refused(ctx.a, :unchanged, @payload)

      atom_keyed = Map.new(@payload, fn {k, v} -> {String.to_atom(k), v} end)
      assert_refused(ctx.a, :unchanged, atom_keyed)
    end

    test "a payload missing expected fails the e2e payload check" do
      ctx = seed()
      before = columns(reload(ctx.a))

      assert {:error, %Ecto.Changeset{} = cs} = amend(ctx.a, Map.delete(@amended, "expected"))
      assert {"missing required keys: expected", _} = cs.errors[:evaluation_payload]
      assert columns(reload(ctx.a)) == before
    end

    test "a non-map payload is refused" do
      ctx = seed()
      assert_refused(ctx.a, :invalid_payload, "not a map")
    end

    test "a malformed validation id is :not_found and nothing is written" do
      ctx = seed()
      before = snapshot([ctx.task.id])

      assert {:error, :not_found} = amend("higginshigginsxx", @amended)
      assert {:error, :not_found} = amend("not-a-uuid", @amended)
      assert {:error, :not_found} = amend(nil, @amended)
      assert {:error, :not_found} = amend(Ecto.UUID.generate(), @amended)

      assert snapshot([ctx.task.id]) == before
    end
  end

  # ── The other writers cannot touch the column ──────────────────────────

  describe "payload_amendments is not writable through the ordinary writers" do
    test "Validation.changeset/2 does not cast it" do
      ctx = seed()

      {:ok, v} =
        Tasks.create_validation(%{
          stage_id: ctx.impl.id,
          kind: "lint_pass",
          payload_amendments: @forged
        })

      assert reload(v).payload_amendments == []
    end

    test "plan_create and plan_update drop it" do
      {:ok, project} =
        Tasks.create_project(%{name: "Forge #{System.unique_integer([:positive])}"})

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Forge task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => task.id, "stages" => forged_stages()},
          %{}
        )

      created = all_validations(plan.id)
      assert Enum.any?(created, &(&1.kind == "e2e_behavior"))
      assert Enum.all?(created, &(&1.payload_amendments == []))

      {:ok, _} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => forged_stages()},
          %{}
        )

      updated = all_validations(plan.id)
      assert Enum.any?(updated, &(&1.kind == "e2e_behavior"))
      assert Enum.all?(updated, &(&1.payload_amendments == []))
    end

    test "validation_evaluate drops it" do
      ctx = seed()

      {:ok, _} =
        ToolSurface.execute(
          "validation_evaluate",
          %{
            "validation_id" => ctx.test_pass.id,
            "status" => "passed",
            "evidence" => %{"payload_amendments" => @forged},
            "payload_amendments" => @forged
          },
          %{}
        )

      row = reload(ctx.test_pass)
      assert row.status == "passed"
      assert row.payload_amendments == []
    end
  end
end
