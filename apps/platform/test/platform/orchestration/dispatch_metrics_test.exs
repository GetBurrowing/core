defmodule Platform.Orchestration.DispatchMetricsTest do
  @moduledoc """
  Task 01a114a8 stage 1. Every expected value below is a literal read off
  the fixture, never recomputed from the code under test.

  The fixtures write NO execution_lease rows unless a test is about leases:
  Claude Code runtimes never write them (runtime_supervision.ex:40), so a
  DispatchMetrics that needs them would report nothing for most agents.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Analytics
  alias Platform.Federation.ToolCallRecord
  alias Platform.Orchestration.DispatchMetrics
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @base ~U[2026-10-01 10:00:00.000000Z]
  @now ~U[2026-10-02 10:00:00.000000Z]

  setup do
    agent = insert_agent()
    runtime = insert_runtime(agent)
    org_id = Platform.TenancyFixtures.acme_org_id()
    {:ok, project} = Tasks.create_project(%{name: "Metrics #{u()}", org_id: org_id})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Metrics task",
        phase_assignees: %{
          "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    %{agent: agent, runtime: runtime, task: task, plan: plan}
  end

  describe "ack units" do
    setup ctx do
      stage = insert_stage!(ctx.plan, 1, "passed", @base, at(30))
      insert_ack!(ctx.task.id, stage.id, ctx.runtime.runtime_id, "sub-1", at(1))
      %{stage: stage}
    end

    test "an ack with ZERO lease rows still yields a dispatch with tool-call counts", ctx do
      call!(ctx, at(0, 30), nil, "task_get")
      call!(ctx, at(2), nil, "task_get")
      call!(ctx, at(3), Ecto.UUID.generate(), "task_get")
      call!(ctx, at(4), nil, "suite_run")
      call!(ctx, at(40), nil, "task_get")
      call!(%{ctx | runtime: %{runtime_id: "someone-else"}}, at(5), nil, "task_get")

      assert Repo.aggregate(ExecutionLease, :count) == 0

      assert %{dispatches: [row], total: 1} = metrics(ctx)
      assert row.unit_source == "ack"
      assert row.runtime_id == ctx.runtime.runtime_id
      assert row.agent_id == ctx.agent.id
      assert row.subagent_id == "sub-1"
      assert row.started_at == at(1)
      assert row.ended_at == at(30)
      assert row.wall_ms == 1_740_000
      assert row.suite_tool_calls == 2
      assert row.inner_tool_calls == 1
      assert row.suite_run_calls == 1
      assert row.re_dispatch_count == 0
      assert row.stage_status == "passed"
      assert row.lease_ids == []
    end

    test "a failed suite_run run, ledgered by the real path, is a tool_calls_error",
         ctx do
      # Task 01a115b5 stage 1. The row is written by ToolCall.invoke/4, not
      # inserted here, so the count reads the ledger's classification.
      {:ok, _profile} =
        Platform.Access.RuntimeProfiles.set_tool_profile(
          ctx.runtime,
          AgentRuntime.default_tool_profile() ++ ["code_mode"]
        )

      assert {:ok, %{ok: false, error: %{kind: "script_error"}, run_id: run_id}} =
               Platform.Federation.ToolCall.invoke(
                 "suite_run",
                 %{"script" => "nope()", "inputs" => %{"task_id" => ctx.task.id}},
                 ctx.runtime
               )

      {1, _} =
        Repo.update_all(
          from(c in ToolCallRecord, where: c.id == ^run_id),
          set: [inserted_at: at(4)]
        )

      assert %{dispatches: [row], total: 1} = metrics(ctx)
      assert row.suite_run_calls == 1
      assert row.tool_calls_error == 1
      assert row.tool_calls_denied == 0
    end

    test "an acked stage produces no duplicate stage_row", ctx do
      rows = metrics(ctx).dispatches
      assert Enum.map(rows, &{&1.stage_id, &1.unit_source}) == [{ctx.stage.id, "ack"}]
    end

    test "a re-dispatch by a different subagent splits the window", ctx do
      insert_ack!(ctx.task.id, ctx.stage.id, ctx.runtime.runtime_id, "sub-1", at(2))
      insert_ack!(ctx.task.id, ctx.stage.id, ctx.runtime.runtime_id, "sub-2", at(10))

      [second, first] = metrics(ctx).dispatches

      assert {first.subagent_id, first.started_at, first.ended_at, first.wall_ms} ==
               {"sub-1", at(1), at(10), 540_000}

      assert {second.subagent_id, second.started_at, second.ended_at, second.wall_ms} ==
               {"sub-2", at(10), at(30), 1_200_000}

      assert first.re_dispatch_count == 1
      assert second.re_dispatch_count == 1
    end

    test "client numbers are nil, not 0, when no usage event exists", ctx do
      [row] = metrics(ctx).dispatches
      assert row.client_reports == 0
      assert row.client_turns == nil
      assert row.client_tokens_in == nil
      assert row.client_tokens_out == nil
      assert row.client_tool_calls == nil
      assert row.client_wall_ms == nil
    end

    test "a matching usage event is counted; another agent's is not", ctx do
      usage!(ctx.agent.id, ctx.task.id, ctx.stage.id, 7, 1200, 340, 19)
      usage!(insert_agent().id, ctx.task.id, ctx.stage.id, 99, 99_999, 99_999, 99)

      [row] = metrics(ctx).dispatches
      assert row.client_reports == 1
      assert row.client_turns == 7
      assert row.client_tokens_in == 1200
      assert row.client_tokens_out == 340
      assert row.client_tool_calls == 19
      assert row.client_harness == "claude-code"
    end

    test "validation counts and coverage", ctx do
      insert_validation!(ctx.stage, "passed")
      insert_validation!(ctx.stage, "failed")

      result = metrics(ctx)
      [row] = result.dispatches
      assert row.validations == %{"passed" => 1, "failed" => 1}

      assert result.coverage == [
               %{
                 agent_id: ctx.agent.id,
                 dispatches: 1,
                 by_unit_source: %{
                   "ack" => %{count: 1, pct: 100.0},
                   "stage_row" => %{count: 0, pct: 0.0},
                   "lease" => %{count: 0, pct: 0.0}
                 }
               }
             ]
    end
  end

  describe "stage_row units" do
    test "a started stage with no ack and no lease is still a dispatch", ctx do
      stage = insert_stage!(ctx.plan, 1, "passed", @base, at(45))
      call!(ctx, at(5), nil, "task_get")

      assert Repo.aggregate(RuntimeEvent, :count) == 0
      assert Repo.aggregate(ExecutionLease, :count) == 0

      assert %{dispatches: [row], total: 1} = metrics(ctx)
      assert row.unit_source == "stage_row"
      assert row.dispatch_id == "stage:" <> stage.id
      assert row.agent_id == ctx.agent.id
      assert row.runtime_id == ctx.runtime.runtime_id
      assert row.started_at == @base
      assert row.wall_ms == 2_700_000
      assert row.suite_tool_calls == 1
      assert row.re_dispatch_count == nil
    end

    test "a running stage has no end and no wall time yet", ctx do
      insert_stage!(ctx.plan, 1, "running", @base, nil)
      [row] = metrics(ctx).dispatches
      assert row.ended_at == nil
      assert row.wall_ms == nil
    end

    test "a pending stage is not a dispatch", ctx do
      insert_stage!(ctx.plan, 1, "pending", nil, nil)
      assert metrics(ctx).total == 0
    end

    test "a lease adds detail and names the runtime that held the stage", ctx do
      stage = insert_stage!(ctx.plan, 1, "passed", @base, at(45))
      other_agent = insert_agent()
      openclaw = insert_runtime(other_agent)
      lease = insert_lease!(ctx.task.id, stage.id, openclaw.runtime_id, at(2))

      [row] = metrics(ctx).dispatches
      assert row.unit_source == "stage_row"
      assert row.lease_ids == [lease.id]
      assert row.lease_started_at == at(2)
      assert row.runtime_id == openclaw.runtime_id
      assert row.agent_id == other_agent.id
    end
  end

  describe "run_tool/2" do
    test "returns the list envelope", ctx do
      insert_stage!(ctx.plan, 1, "passed", @base, at(45))
      insert_stage!(ctx.plan, 2, "passed", at(50), at(60))

      assert {:ok, env} =
               DispatchMetrics.run_tool(%{"task_id" => ctx.task.id, "limit" => 1}, %{})

      assert env.total == 2
      assert env.count == 1
      assert env.has_more == true
      assert [%{unit_source: "stage_row"}] = env.dispatches
    end

    test "refuses a malformed filter" do
      assert {:error, %{code: :invalid_agent_id}} =
               DispatchMetrics.run_tool(%{"agent_id" => "dalton"}, %{})

      assert {:error, %{code: :invalid_from}} =
               DispatchMetrics.run_tool(%{"from" => "yesterday"}, %{})
    end
  end

  describe "usage event metadata" do
    test "well-formed dispatch keys are kept, malformed ones dropped", ctx do
      {:ok, event} =
        Analytics.record_usage_event(%{
          "model" => "m",
          "provider" => "p",
          "session_key" => "s",
          "metadata" => %{
            "stage_id" => "not-a-uuid",
            "turns" => -1,
            "wall_ms" => 5000,
            "client_tool_calls" => "12",
            "harness" => "claude-code",
            "other" => "kept"
          }
        })

      assert event.metadata == %{"wall_ms" => 5000, "harness" => "claude-code", "other" => "kept"}

      {:ok, event} =
        Analytics.record_usage_event(%{
          "model" => "m",
          "provider" => "p",
          "session_key" => "s",
          "metadata" => %{"stage_id" => ctx.plan.id, "turns" => 3}
        })

      assert event.metadata == %{"stage_id" => ctx.plan.id, "turns" => 3}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])
  defp at(minutes, seconds \\ 0), do: DateTime.add(@base, minutes * 60 + seconds, :second)

  defp metrics(ctx), do: DispatchMetrics.list(%{task_id: ctx.task.id, now: @now})

  defp insert_agent do
    %Agent{}
    |> Agent.changeset(%{slug: "metrics-agent-#{u()}", name: "Metrics Agent", status: "active"})
    |> Repo.insert!()
  end

  defp insert_runtime(agent) do
    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "metrics_#{u()}@example.com",
        name: "Metrics User",
        oidc_sub: "oidc-metrics-#{u()}"
      })

    Platform.ExternalUserFixtures.plain_member!(
      user,
      Platform.Tenancy.get_org!(Platform.TenancyFixtures.acme_org_id()),
      "admin"
    )

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "metrics-rt-#{u()}",
      owner_user_id: user.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active"
    })
    |> Repo.insert!()
  end

  defp insert_stage!(plan, position, status, started_at, completed_at) do
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: position,
        name: "Stage #{position}",
        status: status,
        started_at: started_at,
        completed_at: completed_at
      })

    stage
  end

  defp insert_ack!(task_id, stage_id, runtime_id, subagent_id, occurred_at) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task_id,
        phase: "execution",
        runtime_id: runtime_id,
        event_type: "execution.acked",
        occurred_at: occurred_at,
        idempotency_key: "ack-#{u()}",
        payload: %{"stage_id" => stage_id, "subagent_id" => subagent_id}
      })
    )
  end

  defp insert_lease!(task_id, stage_id, runtime_id, started_at) do
    Repo.insert!(
      ExecutionLease.changeset(%ExecutionLease{}, %{
        task_id: task_id,
        stage_id: stage_id,
        phase: "execution",
        runtime_id: runtime_id,
        status: "finished",
        started_at: started_at,
        expires_at: DateTime.add(started_at, 1800, :second)
      })
    )
  end

  defp insert_validation!(%Stage{} = stage, status) do
    Repo.insert!(
      Validation.changeset(%Validation{}, %{stage_id: stage.id, kind: "test_pass", status: status})
    )
  end

  defp call!(ctx, inserted_at, parent_run_id, tool) do
    Repo.insert!(%ToolCallRecord{
      runtime_id: ctx.runtime.runtime_id,
      agent_id: Map.get(ctx.agent, :id),
      tool: tool,
      status: "ok",
      duration_ms: 3,
      task_id: ctx.task.id,
      stage_id: nil,
      attribution: "explicit_arg",
      parent_run_id: parent_run_id,
      inserted_at: inserted_at
    })
  end

  defp usage!(agent_id, task_id, stage_id, turns, tokens_in, tokens_out, client_tool_calls) do
    {:ok, _} =
      Analytics.record_usage_event(%{
        "model" => "claude-opus-5-5",
        "provider" => "anthropic",
        "session_key" => "s-#{u()}",
        "agent_id" => agent_id,
        "task_id" => task_id,
        "input_tokens" => tokens_in,
        "output_tokens" => tokens_out,
        "metadata" => %{
          "stage_id" => stage_id,
          "turns" => turns,
          "client_tool_calls" => client_tool_calls,
          "harness" => "claude-code"
        }
      })
  end
end
