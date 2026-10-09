defmodule Platform.Federation.ToolSurfacePayloadAmendTest do
  @moduledoc """
  Task 01a0acb4 stage 2 — `validation_payload_amend`, the `plan`-bundle tool
  over `Tasks.amend_validation_payload/4`.

  Task 01a0e266 stage 1 adds: the task's execution-phase assignee is refused
  (`:amender_is_executor`, mutations M1 and M4), an agentless context is
  refused (`:agent_context_required`, M2), and the audit row's `actor_id` is
  the agent's UUID (M3).

  What this file pins, each against the tool boundary an agent touches:

    * the amender is the AUTHENTICATED caller: an `amended_by` key in the
      arguments is ignored (mutation M5 reads it first and turns this red);
    * a sibling-org agent is refused by `authorize_review_access/2` and the
      row is untouched (mutation M4 drops the call and turns this red);
    * every refusal names the path to take INSTEAD;
    * the serializers carry `payload_amendments` (plan_get, stage_list full)
      and omit it in stage_list's summary rows.

  POSITIVE CONTROL: plan_update still corrects a DRAFT in place and still
  refuses an approved plan. The new tool must be neither the only correction
  path nor a widening of plan_update.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Validation}
  alias Platform.Tenancy

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

  @reason "actions sent a header the pipeline refuses"

  # ── Fixtures ────────────────────────────────────────────────────────────

  setup do
    root = ensure_root_org()
    own = tenant_org("amend-own-#{u()}", root)
    sibling = tenant_org("amend-sibling-#{u()}", root)

    %{
      own_org: own,
      agent: create_agent("amend-planner", %{"org_id" => own.id}),
      sibling_agent: create_agent("amend-sibling", %{"org_id" => sibling.id})
    }
  end

  defp seed(org, opts \\ []) do
    plan_status = Keyword.get(opts, :plan_status, "approved")
    task_attrs = Keyword.get(opts, :task_attrs, %{})
    n = u()

    {:ok, project} = Tasks.create_project(%{name: "Amend Tool Project #{n}", org_id: org.id})

    {:ok, task} =
      Tasks.create_task(
        Map.merge(%{project_id: project.id, title: "Amend Tool Task #{n}"}, task_attrs)
      )

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

  defp ctx_for(%Agent{id: id}), do: %{agent_id: id}

  defp amend(id, context, overrides \\ %{}) do
    args =
      Map.merge(
        %{"validation_id" => id, "evaluation_payload" => @amended, "reason" => @reason},
        overrides
      )

    ToolSurface.execute("validation_payload_amend", args, context)
  end

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)

  defp set_status!(%Validation{} = v, status) do
    v |> Ecto.Changeset.change(%{status: status}) |> Repo.update!()
  end

  # Full column map, associations out — "unchanged" means every column,
  # updated_at included.
  defp columns(%Validation{} = v) do
    v
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reject(fn {_k, val} -> match?(%Ecto.Association.NotLoaded{}, val) end)
    |> Map.new()
  end

  defp assert_refused_unchanged(%Validation{} = v, context, overrides \\ %{}) do
    before = columns(reload(v))
    assert {:error, envelope} = amend(v.id, context, overrides)
    assert columns(reload(v)) == before
    envelope
  end

  # ── Happy path ──────────────────────────────────────────────────────────

  describe "amending through the tool" do
    test "the amender is the calling agent; a forged amended_by argument is ignored", ctx do
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
      s = seed(ctx.own_org)

      assert {:ok, result} =
               amend(s.a.id, ctx_for(ctx.agent), %{
                 "amended_by" => "forged",
                 "actor_type" => "user"
               })

      assert result.status_changed == false
      assert result.status == "pending"
      assert result.evaluation_payload == @amended
      assert [entry] = result.payload_amendments
      assert entry["amended_by"] == ctx.agent.slug
      assert entry["actor_type"] == "agent"
      assert entry["prior_payload"] == @payload
      assert entry["reason"] == @reason

      row = reload(s.a)
      assert row.status == "pending"
      assert [%{"amended_by" => slug}] = row.payload_amendments
      assert slug == ctx.agent.slug
      refute inspect(row.payload_amendments) =~ "forged"

      events = Platform.Audit.list(event_type: "platform.tasks.validation_payload_amended")

      assert Enum.any?(events, fn e ->
               e.resource_id == s.a.id and e.metadata["amended_by"] == ctx.agent.slug
             end)

      refute Enum.any?(events, fn e -> e.metadata["amended_by"] == "forged" end)
    end

    test "plan_get and stage_list (full) carry payload_amendments; summary rows omit it", ctx do
      s = seed(ctx.own_org)
      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.agent))

      assert {:ok, plan} = ToolSurface.execute("plan_get", %{"task_id" => s.task.id}, %{})

      validations = Enum.flat_map(plan.stages, & &1.validations)
      a = Enum.find(validations, &(&1.id == s.a.id))
      b = Enum.find(validations, &(&1.id == s.b.id))
      assert [%{"amended_by" => _}] = a.payload_amendments
      assert b.payload_amendments == []

      assert {:ok, %{stages: full}} =
               ToolSurface.execute(
                 "stage_list",
                 %{"plan_id" => s.plan.id, "detail" => "full"},
                 %{}
               )

      full_a = full |> Enum.flat_map(& &1.validations) |> Enum.find(&(&1.id == s.a.id))
      assert length(full_a.payload_amendments) == 1

      assert {:ok, %{stages: summary}} =
               ToolSurface.execute("stage_list", %{"plan_id" => s.plan.id}, %{})

      rows = Enum.flat_map(summary, & &1.validations)
      sum_a = Enum.find(rows, &(&1.id == s.a.id))
      sum_b = Enum.find(rows, &(&1.id == s.b.id))

      assert sum_a.payload_amendments == []
      assert sum_a.payload_amendments_omitted == true
      assert sum_a.payload_amendments_length > 0
      assert sum_b.payload_amendments == []
      assert sum_b.payload_amendments_omitted == false
    end
  end

  # ── Authorization ───────────────────────────────────────────────────────

  describe "authorization" do
    test "a sibling-org agent is refused and the row is unchanged", ctx do
      s = seed(ctx.own_org)

      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.sibling_agent))
      assert envelope.error =~ "unauthorized"
      refute envelope.recoverable
      assert reload(s.a).payload_amendments == []
    end

    test "the own-org agent on the same row is permitted (the denial is org-keyed)", ctx do
      s = seed(ctx.own_org)
      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.agent))
    end
  end

  # ── The executor under judgement (task 01a0e266 stage 1) ────────────────
  #
  # The refused identity is the task's EXECUTION-PHASE assignee. Every test
  # here seeds a planner P that differs from the executor E, and asserts BOTH
  # that E is refused and that P is permitted on the same row: a check keyed
  # on the planning assignee instead (mutation M4) inverts both outcomes, and
  # a blanket refusal fails the P half.

  defp phase(%Agent{id: id}), do: %{"assignee_id" => id, "assignee_type" => "agent"}

  defp amend_events(validation_id) do
    Platform.Audit.list(event_type: "platform.tasks.validation_payload_amended")
    |> Enum.filter(&(&1.resource_id == validation_id))
  end

  describe "the task's execution-phase assignee" do
    setup ctx do
      %{
        executor: create_agent("amend-executor", %{"org_id" => ctx.own_org.id}),
        planner: ctx.agent
      }
    end

    test "is refused before any state check and the full row is unchanged", ctx do
      s =
        seed(ctx.own_org,
          task_attrs: %{
            phase_assignees: %{
              "planning" => phase(ctx.planner),
              "execution" => phase(ctx.executor)
            }
          }
        )

      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.executor))
      assert envelope.code == :amender_is_executor
      refute envelope.recoverable
      assert envelope.error =~ "execution-phase assignee"
      assert envelope.suggestion =~ "execution space"
      assert envelope.suggestion =~ "planner"
      assert reload(s.a).payload_amendments == []

      # Refused before the status check: a passed row answers the same way,
      # so the executor learns nothing else about it.
      passed = set_status!(s.b, "passed")
      assert assert_refused_unchanged(passed, ctx_for(ctx.executor)).code == :amender_is_executor

      # POSITIVE CONTROL on the same row: the planner, a different same-org
      # agent, amends it. The refusal is identity-keyed, not blanket.
      assert {:ok, result} = amend(s.a.id, ctx_for(ctx.planner))
      assert [%{"amended_by" => slug}] = result.payload_amendments
      assert slug == ctx.planner.slug
    end

    test "falls back to the top-level assignee when phase_assignees has no execution slot",
         ctx do
      s =
        seed(ctx.own_org,
          task_attrs: %{phase_assignees: %{"planning" => phase(ctx.planner)}}
        )

      s.task
      |> Ecto.Changeset.change(%{assignee_id: ctx.executor.id, assignee_type: "agent"})
      |> Repo.update!()

      task = Tasks.get_task_record(s.task.id)
      refute Map.has_key?(task.phase_assignees, "execution")
      assert Tasks.assignee_for_phase(task, "execution") == {ctx.executor.id, "agent"}

      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.executor))
      assert envelope.code == :amender_is_executor

      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.planner))
    end

    test "an agent that plans, executes and reviews its own task is refused", ctx do
      x = ctx.executor

      s =
        seed(ctx.own_org,
          task_attrs: %{
            phase_assignees: %{
              "planning" => phase(x),
              "execution" => phase(x),
              "review" => phase(x)
            }
          }
        )

      envelope = assert_refused_unchanged(s.a, ctx_for(x))
      assert envelope.code == :amender_is_executor
    end

    test "a task with no assignee at all refuses nobody", ctx do
      s = seed(ctx.own_org)
      assert Tasks.assignee_for_phase(s.task, "execution") == {nil, nil}
      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.executor))
    end
  end

  describe "an agentless context" do
    test "%{}, agent_id nil and an unknown agent id are each refused; the row is unchanged",
         ctx do
      s = seed(ctx.own_org)

      for context <- [
            %{},
            %{agent_id: nil, runtime_id: "rig"},
            %{agent_id: Ecto.UUID.generate()}
          ] do
        envelope = assert_refused_unchanged(s.a, context)
        assert envelope.code == :agent_context_required, inspect(context)
        refute envelope.recoverable
        assert envelope.suggestion =~ "Platform.Tasks.amend_validation_payload/4"
      end

      assert reload(s.a).payload_amendments == []
      assert amend_events(s.a.id) == []
    end

    test "the operator path is the context function with an explicit system actor", ctx do
      s = seed(ctx.own_org)

      assert {:ok, updated} =
               Tasks.amend_validation_payload(
                 s.a.id,
                 @amended,
                 @reason,
                 {"operator:test", "system"}
               )

      assert [%{"amended_by" => "operator:test", "actor_type" => "system"}] =
               updated.payload_amendments
    end
  end

  describe "audit actor_id" do
    test "an agent amendment records the agent's UUID; an operator one records nil", ctx do
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
      s = seed(ctx.own_org)

      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.agent))

      assert {:ok, _} =
               Tasks.amend_validation_payload(
                 s.b.id,
                 @amended,
                 @reason,
                 {"operator:test", "system"}
               )

      assert [agent_row] = amend_events(s.a.id)
      assert agent_row.actor_id == ctx.agent.id
      assert agent_row.actor_type == "agent"
      assert agent_row.metadata["amended_by"] == ctx.agent.slug

      assert [operator_row] = amend_events(s.b.id)
      assert operator_row.actor_id == nil
      assert operator_row.actor_type == "system"
      assert operator_row.metadata["amended_by"] == "operator:test"
    end
  end

  describe "the shared review-access denial" do
    test "names no memory_search, for validation_payload_amend and for plan_get", ctx do
      s = seed(ctx.own_org)

      amend_envelope = assert_refused_unchanged(s.a, ctx_for(ctx.sibling_agent))

      assert {:error, plan_envelope} =
               ToolSurface.execute(
                 "plan_get",
                 %{"task_id" => s.task.id},
                 ctx_for(ctx.sibling_agent)
               )

      for envelope <- [amend_envelope, plan_envelope] do
        assert envelope.error == "unauthorized: review is in an org you are not a member of"
        refute envelope.suggestion =~ "memory_search"
        assert envelope.suggestion =~ "org you are not a member of"
      end
    end
  end

  # ── The execution-space notice (task 01a0e266 stage 2) ──────────────────
  #
  # M5 (delete the notice call) turns the +1 test red. M7 (post inside the
  # transaction, before the update) turns the refusal test red through the
  # PubSub half: a message inserted inside the amend transaction is rolled
  # back with it, so a row count alone cannot see M7, but the chat broadcast
  # fires when the INNER post transaction returns and is not rolled back.

  defp amendment_notices(space_id) do
    import Ecto.Query

    from(m in Platform.Chat.Message,
      where:
        m.space_id == ^space_id and
          fragment("?->>'reason' = ?", m.metadata, "validation_payload_amended")
    )
    |> Repo.all()
  end

  defp exec_space!(task) do
    {:ok, space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)
    space
  end

  describe "the execution-space notice" do
    test "a tool amendment posts exactly one log-only notice with the composed body", ctx do
      s = seed(ctx.own_org)
      space = exec_space!(s.task)
      before = length(amendment_notices(space.id))

      assert {:ok, result} = amend(s.a.id, ctx_for(ctx.agent))

      notices = amendment_notices(space.id)
      assert length(notices) == before + 1
      assert [notice] = notices
      assert notice.log_only == true
      assert notice.metadata["validation_id"] == s.a.id
      assert notice.metadata["amendment_number"] == 1

      [entry] = result.payload_amendments
      validation = reload(s.a)

      expected =
        "E2E case amended: #{s.a.id} (amendment 1, changed: actions). " <>
          "Amended by #{ctx.agent.name}. Reason: #{@reason}"

      assert Tasks.PayloadAmendmentNotice.compose_message(validation, entry, 1, ctx.agent.name) ==
               expected

      assert notice.content == expected
    end

    test "executor, :unchanged and changeset refusals post and broadcast nothing", ctx do
      executor = create_agent("amend-executor", %{"org_id" => ctx.own_org.id})

      s =
        seed(ctx.own_org,
          task_attrs: %{
            phase_assignees: %{
              "planning" => phase(ctx.agent),
              "execution" => phase(executor)
            }
          }
        )

      space = exec_space!(s.task)
      :ok = Platform.Chat.PubSub.subscribe(space.id)

      assert assert_refused_unchanged(s.a, ctx_for(executor)).code == :amender_is_executor

      assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{"evaluation_payload" => @payload})

      # A changeset refusal is raised by the UPDATE itself, so it is the one
      # refusal that gets past every earlier check: a notice posted anywhere
      # inside the transaction before the update is reached by it.
      assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{
        "evaluation_payload" => Map.delete(@amended, "expected")
      })

      assert amendment_notices(space.id) == []
      refute_receive {:new_message, _}, 100

      # POSITIVE CONTROL: the same subscription does see a committed notice,
      # so the refute above is a measurement.
      assert {:ok, _} = amend(s.a.id, ctx_for(ctx.agent))
      assert_receive {:new_message, %{metadata: %{"reason" => "validation_payload_amended"}}}, 500
      assert length(amendment_notices(space.id)) == 1
    end
  end

  # ── Refusals name the path to take instead ──────────────────────────────

  describe "refusals" do
    test "a passed case: the verdict is not re-opened", ctx do
      s = seed(ctx.own_org)
      passed = set_status!(s.a, "passed")
      envelope = assert_refused_unchanged(passed, ctx_for(ctx.agent))
      assert envelope.suggestion =~ "not re-opened"
    end

    test "a failed case: wait for remediation to re-pend it", ctx do
      s = seed(ctx.own_org)
      failed = set_status!(s.a, "failed")
      envelope = assert_refused_unchanged(failed, ctx_for(ctx.agent))
      assert envelope.suggestion =~ "remediation stage to re-pend"
    end

    test "a running case: an evaluation is in flight", ctx do
      s = seed(ctx.own_org)
      running = set_status!(s.a, "running")
      envelope = assert_refused_unchanged(running, ctx_for(ctx.agent))
      assert envelope.suggestion =~ "in flight"
    end

    test "a draft plan: use plan_update", ctx do
      s = seed(ctx.own_org, plan_status: "draft")
      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.agent))
      assert envelope.suggestion =~ "use plan_update"
    end

    test "a superseded plan: names the status", ctx do
      s = seed(ctx.own_org)

      # supersede_current_plan/3 only acts on an in-flight task.
      s.task |> Ecto.Changeset.change(%{status: "in_progress"}) |> Repo.update!()

      assert {:ok, _} = Tasks.supersede_current_plan(s.task.id, "re-plan", "planner-agent")
      assert Repo.get!(Plan, s.plan.id).status == "superseded"

      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.agent))
      assert envelope.error =~ "superseded"
      assert envelope.suggestion =~ "current plan"
    end

    test "test_pass: names the kind", ctx do
      s = seed(ctx.own_org)
      envelope = assert_refused_unchanged(s.test_pass, ctx_for(ctx.agent))
      assert envelope.error =~ "test_pass"
      assert envelope.error =~ "not e2e_behavior"
    end

    test "pr_merged: names the kind and the repo payload is untouched", ctx do
      s = seed(ctx.own_org)

      envelope =
        assert_refused_unchanged(s.pr_merged, ctx_for(ctx.agent), %{
          "evaluation_payload" => %{"repo" => "attacker/fork"}
        })

      assert envelope.error =~ "pr_merged"
      assert envelope.suggestion =~ "deploy gates"
      assert reload(s.pr_merged).evaluation_payload == %{"repo" => "Startup-Suite/core"}
    end

    test "a blank reason is a parameter error", ctx do
      s = seed(ctx.own_org)
      envelope = assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{"reason" => "   "})
      assert envelope.recoverable
      assert envelope.error =~ "`reason`"
    end

    test "an unchanged payload adds no empty history entry", ctx do
      s = seed(ctx.own_org)

      envelope =
        assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{"evaluation_payload" => @payload})

      assert envelope.suggestion =~ "Nothing was written"
    end

    test "a payload missing expected fails the e2e payload check", ctx do
      s = seed(ctx.own_org)

      envelope =
        assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{
          "evaluation_payload" => Map.delete(@amended, "expected")
        })

      assert envelope.error =~ "evaluation_payload"
      assert envelope.suggestion =~ "`expected`"
    end

    test "a non-object payload is a parameter error", ctx do
      s = seed(ctx.own_org)

      envelope =
        assert_refused_unchanged(s.a, ctx_for(ctx.agent), %{"evaluation_payload" => "text"})

      assert envelope.error =~ "must be an object"
    end

    test "a malformed validation id is not-found, without raising", ctx do
      assert {:error, envelope} = amend("not-a-uuid", ctx_for(ctx.agent))
      assert envelope.error =~ "not found"
      refute envelope.recoverable

      assert {:error, envelope} = amend(Ecto.UUID.generate(), ctx_for(ctx.agent))
      assert envelope.error =~ "not found"
    end
  end

  # ── Positive control: plan_update is neither replaced nor widened ───────

  describe "POSITIVE CONTROL: plan_update" do
    test "still corrects a DRAFT in place: tree replaced, plan id and version stable", ctx do
      s = seed(ctx.own_org, plan_status: "draft")
      changed_actions = "curl the endpoint via plan_update"

      stages = [
        %{
          "name" => "Land the change",
          "description" => "Implementation",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{
              "kind" => "e2e_behavior",
              "evaluation_payload" => Map.put(@payload, "actions", changed_actions)
            }
          ]
        }
      ]

      assert {:ok, updated} =
               ToolSurface.execute(
                 "plan_update",
                 %{"plan_id" => s.plan.id, "stages" => stages},
                 ctx_for(ctx.agent)
               )

      assert updated.id == s.plan.id
      assert updated.version == s.plan.version

      reloaded = Tasks.get_plan(s.plan.id) |> Repo.preload(stages: :validations)
      assert reloaded.status == "draft"
      assert reloaded.version == s.plan.version

      e2e =
        reloaded.stages
        |> Enum.flat_map(& &1.validations)
        |> Enum.filter(&(&1.kind == "e2e_behavior"))

      assert [%Validation{evaluation_payload: %{"actions" => ^changed_actions}}] = e2e
      # The old e2e rows were recreated, not mutated.
      refute Repo.get(Validation, s.a.id)
    end

    test "still refuses an APPROVED plan (the amend tool did not widen it)", ctx do
      s = seed(ctx.own_org)
      before = columns(reload(s.a))

      assert {:error, envelope} =
               ToolSurface.execute(
                 "plan_update",
                 %{
                   "plan_id" => s.plan.id,
                   "stages" => [
                     %{
                       "name" => "x",
                       "position" => 1,
                       "validations" => [%{"kind" => "test_pass"}]
                     }
                   ]
                 },
                 ctx_for(ctx.agent)
               )

      assert is_binary(envelope.error)
      assert Repo.get!(Plan, s.plan.id).status == "approved"
      assert columns(reload(s.a)) == before
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        Repo.insert!(
          Tenancy.Org.changeset(%Tenancy.Org{}, %{slug: "acme", name: "Acme", parent_org_id: nil})
        )

      org ->
        org
    end
  end

  defp tenant_org(slug, root) do
    Repo.insert!(
      Tenancy.Org.changeset(%Tenancy.Org{}, %{slug: slug, name: slug, parent_org_id: root.id})
    )
  end

  defp create_agent(slug_prefix, metadata) do
    Repo.insert!(
      Agent.changeset(%Agent{}, %{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
    )
  end
end
