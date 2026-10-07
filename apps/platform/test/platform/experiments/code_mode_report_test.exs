defmodule Platform.Experiments.CodeModeReportTest do
  @moduledoc """
  Task 01a114a8 stage 4: the `dispatch_usage` metric kind,
  `Results.by_agent/2` and the `code_mode_report` tool.

  Every expected value is a LITERAL read off the fixture, never recomputed
  from the code under test.

  The fixture is a running `dispatch.code_mode` experiment enrolling three
  agents:

    * A acks its stages (a Claude Code runtime with `task_ack`).
    * M never acks (the Moore case: a runtime whose MCP cache may lack
      `task_ack`), so its dispatches are `stage_row` units.
    * C is enrolled and never dispatched.

  | task | arm       | agent | stage  | unit      | calls (model-issued)          |
  |------|-----------|-------|--------|-----------|-------------------------------|
  | T1   | treatment | A     | passed | ack       | suite_run + task_get, 2 inner |
  | T2   | control   | A     | failed | ack       | 3 task_get + suite_run        |
  | T3   | treatment | M     | passed | stage_row | 2 task_get                    |
  | T4   | treatment | A     | passed | ack       | EXCLUDED subject              |

  plus one unattributed M call. A's T1 dispatch has a usage report (5 turns,
  1000 tokens in, 200 out).
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Analytics
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.MetricKinds.DispatchUsage
  alias Platform.Experiments.Results
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolCallRecord
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Tasks
  alias Platform.Tasks.Validation

  @base ~U[2026-10-01 10:00:00.000000Z]
  @now ~U[2026-10-02 10:00:00.000000Z]

  defp u, do: System.unique_integer([:positive])
  defp at(min, sec \\ 0), do: DateTime.add(@base, min * 60 + sec, :second)

  # ── pure aggregation ────────────────────────────────────────────────────

  describe "DispatchUsage.aggregate/3 (pure)" do
    @rows [
      %{
        suite_tool_calls: 4,
        client_turns: nil,
        wall_ms: 1000,
        stage_status: "passed",
        validations: %{"passed" => 2},
        re_dispatch_count: 0
      },
      %{
        suite_tool_calls: 1,
        client_turns: 6,
        wall_ms: nil,
        stage_status: "failed",
        validations: %{},
        re_dispatch_count: 0
      },
      %{
        suite_tool_calls: 7,
        client_turns: 2,
        wall_ms: 4000,
        stage_status: "running",
        validations: %{},
        re_dispatch_count: nil
      },
      %{
        suite_tool_calls: 0,
        client_turns: nil,
        wall_ms: 3000,
        stage_status: "passed",
        validations: %{"failed" => 1},
        re_dispatch_count: 0
      }
    ]

    test "mean and median over every row; a measured 0 counts" do
      assert DispatchUsage.aggregate(@rows, "suite_tool_calls", "mean") ==
               {:ok, %Result{value: 3.0, n: 4, unit: :count}}

      assert DispatchUsage.aggregate(@rows, "suite_tool_calls", "median") ==
               {:ok, %Result{value: 2.5, n: 4, unit: :count}}
    end

    test "nil is left out of value AND n, never read as 0" do
      assert DispatchUsage.aggregate(@rows, "client_turns", "mean") ==
               {:ok, %Result{value: 4.0, n: 2, unit: :count}}

      assert DispatchUsage.aggregate(@rows, "wall_ms", "median") ==
               {:ok, %Result{value: 3000.0, n: 3, unit: :milliseconds}}
    end

    test "outcome_first_pass: passed with no failed validation; running is unmeasured" do
      assert DispatchUsage.aggregate(@rows, "outcome_first_pass", "mean") ==
               {:ok, %Result{value: 1 / 3, n: 3, unit: :ratio}}
    end

    test "a re-dispatched passed stage is not a first pass" do
      rows = [%{stage_status: "passed", validations: %{}, re_dispatch_count: 1}]

      assert DispatchUsage.aggregate(rows, "outcome_first_pass", "mean") ==
               {:ok, %Result{value: 0.0, n: 1, unit: :ratio}}
    end

    test "an empty set, or one where no row carries the field, is :insufficient_data" do
      for field <- DispatchUsage.fields() do
        assert DispatchUsage.aggregate([], field, "mean") == :insufficient_data
      end

      rows = [%{client_tokens_in: nil}, %{client_tokens_in: nil}]
      assert DispatchUsage.aggregate(rows, "client_tokens_in", "median") == :insufficient_data
    end

    test "the spec validates when written" do
      assert {:ok, DispatchUsage, %{"field" => "wall_ms", "agg" => "mean"}} =
               MetricKind.parse(%{"kind" => "dispatch_usage", "field" => "wall_ms"})

      assert {:error, ["dispatch_usage field must be one of: " <> _]} =
               MetricKind.parse(%{"kind" => "dispatch_usage", "field" => "tokens"})

      assert {:error, ["dispatch_usage agg must be one of: mean, median"]} =
               MetricKind.parse(%{
                 "kind" => "dispatch_usage",
                 "field" => "wall_ms",
                 "agg" => "p99"
               })

      assert {:error, ["unknown dispatch_usage parameters: x"]} =
               MetricKind.parse(%{"kind" => "dispatch_usage", "field" => "wall_ms", "x" => 1})
    end

    test "the fields, literally" do
      assert DispatchUsage.fields() == [
               "suite_tool_calls",
               "client_turns",
               "client_tokens_in",
               "client_tokens_out",
               "wall_ms",
               "outcome_first_pass",
               "tool_calls_error"
             ]
    end

    test "tool_calls_error: a mean over dispatches; a measured 0 counts (task 01a115b5)" do
      assert DispatchUsage.aggregate(
               [%{tool_calls_error: 1}, %{tool_calls_error: 0}],
               "tool_calls_error",
               "mean"
             ) == {:ok, %Result{value: 0.5, n: 2, unit: :count}}

      assert {:ok, DispatchUsage, %{"field" => "tool_calls_error", "agg" => "mean"}} =
               MetricKind.parse(%{"kind" => "dispatch_usage", "field" => "tool_calls_error"})
    end
  end

  # ── the fixture ─────────────────────────────────────────────────────────

  defp fixture(opts \\ []) do
    a = insert_agent("a")
    m = insert_agent("m")
    c = insert_agent("c")
    rt_a = insert_runtime(a)
    rt_m = insert_runtime(m)

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "cm-report-#{u()}",
        name: "Code mode report",
        surface_key: "dispatch.code_mode",
        surface_target: "dispatch.prompt_directive",
        assignment_policy: %{
          "type" => "task_cohort",
          "cohort" => %{"agent_id" => [a.id, m.id, c.id]}
        },
        stop_rule: Keyword.get(opts, :stop_rule, %{"min_subjects" => 1}),
        metric_spec: Keyword.get(opts, :metric_spec, %{})
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: %{"suite_run" => true},
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = experiment} =
      Experiments.start(experiment, %User{id: Ecto.UUID.generate()})

    {:ok, project} = Tasks.create_project(%{name: "CM report #{u()}"})

    t1 = task!(project, a)
    t2 = task!(project, a)
    t3 = task!(project, m)
    t4 = task!(project, a)

    assign!(experiment, t1, "treatment", nil)
    assign!(experiment, t2, "control", nil)
    assign!(experiment, t3, "treatment", nil)
    assign!(experiment, t4, "treatment", "contaminated by a manual rerun")

    s1 = stage!(t1, "passed", at(1), at(11))
    validation!(s1, "passed")
    ack!(t1, s1, rt_a, at(2))
    call!(rt_a, a, t1, at(3), nil, "suite_run")
    call!(rt_a, a, t1, at(3, 5), Ecto.UUID.generate(), "task_get")
    call!(rt_a, a, t1, at(3, 6), Ecto.UUID.generate(), "stage_list")
    call!(rt_a, a, t1, at(4), nil, "task_get")
    usage!(a, t1, s1, 5, 1000, 200)

    s2 = stage!(t2, "failed", at(20), at(40))
    validation!(s2, "failed")
    ack!(t2, s2, rt_a, at(21))
    for sec <- 1..3, do: call!(rt_a, a, t2, at(22, sec), nil, "task_get")
    call!(rt_a, a, t2, at(23), nil, "suite_run")

    s3 = stage!(t3, "passed", at(50), at(55))
    validation!(s3, "passed")
    call!(rt_m, m, t3, at(51), nil, "task_get")
    call!(rt_m, m, t3, at(52), nil, "task_get")
    unattributed_call!(rt_m, m, at(53))

    s4 = stage!(t4, "passed", at(60), at(61))
    ack!(t4, s4, rt_a, at(60, 30))
    call!(rt_a, a, t4, at(60, 40), nil, "suite_run")

    %{experiment: experiment, a: a, m: m, c: c, t1: t1, t2: t2, t3: t3, t4: t4}
  end

  defp rows_by_cell(rows), do: Map.new(rows, &{{&1.agent_id, &1.variant_slug}, &1})

  describe "Results.by_agent/2" do
    test "splits the literal fixture per agent x arm" do
      f = fixture()
      cells = f.experiment |> Results.by_agent(now: @now) |> rows_by_cell()

      assert cells |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 {f.a.id, "control"},
                 {f.a.id, "treatment"},
                 {f.m.id, "control"},
                 {f.m.id, "treatment"},
                 {f.c.id, "control"},
                 {f.c.id, "treatment"}
               ])

      a_t = cells[{f.a.id, "treatment"}]
      assert {a_t.n, a_t.tasks, a_t.suite_run_arm} == {1, 1, true}

      assert a_t.metrics["suite_tool_calls_mean"] == %{value: 2.0, n: 1, reason: :measured}
      assert a_t.metrics["client_turns_mean"] == %{value: 5.0, n: 1, reason: :measured}
      assert a_t.metrics["client_tokens_in_mean"] == %{value: 1000.0, n: 1, reason: :measured}
      assert a_t.metrics["client_tokens_out_mean"] == %{value: 200.0, n: 1, reason: :measured}
      # ack at minute 2 -> stage completed at minute 11
      assert a_t.metrics["wall_ms_mean"] == %{value: 540_000.0, n: 1, reason: :measured}
      assert a_t.metrics["outcome_first_pass_mean"] == %{value: 1.0, n: 1, reason: :measured}
      # Every fixture call is ledgered ok: a measured 0, not insufficient data.
      assert a_t.metrics["tool_calls_error_mean"] == %{value: 0.0, n: 1, reason: :measured}
      assert {a_t.suite_run_dispatches, a_t.suite_run_adoption_rate} == {1, 1.0}
      assert a_t.control_suite_run_violations == nil

      a_c = cells[{f.a.id, "control"}]
      assert {a_c.n, a_c.suite_run_arm} == {1, false}
      assert a_c.metrics["suite_tool_calls_mean"] == %{value: 4.0, n: 1, reason: :measured}
      assert a_c.metrics["client_turns_mean"] == %{value: nil, n: 0, reason: :insufficient_data}
      assert a_c.metrics["outcome_first_pass_mean"] == %{value: 0.0, n: 1, reason: :measured}
      assert a_c.control_suite_run_violations == 1
      assert a_c.suite_run_adoption_rate == nil

      m_t = cells[{f.m.id, "treatment"}]
      assert m_t.n == 1
      assert m_t.metrics["suite_tool_calls_mean"] == %{value: 2.0, n: 1, reason: :measured}

      assert m_t.metrics["client_tokens_in_mean"] == %{
               value: nil,
               n: 0,
               reason: :insufficient_data
             }

      assert m_t.metrics["wall_ms_mean"] == %{value: 300_000.0, n: 1, reason: :measured}
      assert {m_t.suite_run_dispatches, m_t.suite_run_adoption_rate} == {0, 0.0}

      for slug <- ["control", "treatment"], agent <- [f.c.id] do
        empty = cells[{agent, slug}]
        assert {empty.n, empty.tasks, empty.suite_run_dispatches} == {0, 0, 0}

        assert empty.metrics["suite_tool_calls_mean"] == %{
                 value: nil,
                 n: 0,
                 reason: :insufficient_data
               }

        assert empty.coverage.ack_pct == nil
      end

      assert cells[{f.m.id, "control"}].n == 0
    end

    test "coverage shows the agent that never acks, per agent, not hidden" do
      f = fixture()
      cells = f.experiment |> Results.by_agent(now: @now) |> rows_by_cell()

      assert cells[{f.a.id, "treatment"}].coverage == %{
               unit_source: %{"ack" => 1, "stage_row" => 0, "lease" => 0},
               ack_pct: 100.0,
               client_report_pct: 100.0,
               # T1 2 + T2 4 + T4 1 model-issued calls, all explicit_arg
               attribution_tool_calls: 7,
               attribution_pct: 100.0,
               attribution_by_rung: %{"explicit_arg" => 7}
             }

      assert cells[{f.m.id, "treatment"}].coverage == %{
               unit_source: %{"ack" => 0, "stage_row" => 1, "lease" => 0},
               ack_pct: 0.0,
               client_report_pct: 0.0,
               attribution_tool_calls: 3,
               attribution_pct: 66.7,
               attribution_by_rung: %{"explicit_arg" => 2, "unattributed" => 1}
             }

      assert cells[{f.c.id, "treatment"}].coverage.attribution_tool_calls == nil
    end

    test "an excluded subject's dispatches are in no row" do
      f = fixture()
      rows = Results.by_agent(f.experiment, now: @now)

      # T4's suite_run is A's only other one; with it A/treatment would be 2.
      assert Enum.sum(Enum.map(rows, & &1.n)) == 3
      assert rows |> rows_by_cell() |> Map.fetch!({f.a.id, "treatment"}) |> Map.get(:n) == 1
    end

    test "without a stop rule every figure is withheld and n still travels" do
      f = fixture(stop_rule: %{})
      cells = f.experiment |> Results.by_agent(now: @now) |> rows_by_cell()

      assert cells[{f.a.id, "treatment"}].metrics["suite_tool_calls_mean"] ==
               %{value: nil, n: 1, reason: :no_stop_rule}

      assert cells[{f.a.id, "control"}].metrics["outcome_first_pass_mean"] ==
               %{value: nil, n: 1, reason: :no_stop_rule}
    end
  end

  describe "the dispatch_usage kind on an experiment" do
    test "computes per arm from the assigned, non-excluded tasks" do
      f =
        fixture(
          metric_spec: %{
            "kind" => "dispatch_usage",
            "field" => "suite_tool_calls",
            "agg" => "mean"
          }
        )

      # treatment: T1 (A, 2 calls) and T3 (M, 2 calls); T4 is excluded
      assert Platform.Experiments.Metrics.compute_spec(f.experiment, "treatment") ==
               {:ok, %Result{value: 2.0, n: 2, unit: :count}}

      assert Platform.Experiments.Metrics.compute_spec(f.experiment, "control") ==
               {:ok, %Result{value: 4.0, n: 1, unit: :count}}
    end

    test "an arm whose dispatches carry no client report is :insufficient_data, not 0.0" do
      f =
        fixture(
          metric_spec: %{
            "kind" => "dispatch_usage",
            "field" => "client_tokens_in",
            "agg" => "mean"
          }
        )

      assert Platform.Experiments.Metrics.compute_spec(f.experiment, "control") ==
               :insufficient_data

      [row] = f.experiment |> Results.rows() |> Enum.filter(&(&1.variant_slug == "control"))
      assert {row.reason, row.value, row.n} == {:insufficient_data, nil, 0}
    end

    test "an arm with no assigned subject is :insufficient_data" do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "cm-empty-#{u()}",
          name: "Empty",
          surface_key: "dispatch.code_mode",
          surface_target: "dispatch.prompt_directive",
          metric_spec: %{"kind" => "dispatch_usage", "field" => "wall_ms"}
        })

      assert Platform.Experiments.Metrics.compute_spec(experiment, "control") ==
               :insufficient_data

      assert Results.by_agent(experiment, now: @now) == []
    end
  end

  describe "code_mode_report" do
    test "returns the rows whole, in the list envelope, with reasons as strings" do
      f = fixture()

      assert {:ok, env} =
               ToolArguments.dispatch(
                 "code_mode_report",
                 %{"experiment_id" => f.experiment.id},
                 %{}
               )

      assert env.experiment_id == f.experiment.id
      assert env.surface_key == "dispatch.code_mode"
      assert env.min_subjects == 1
      assert {env.total, env.has_more, length(env.rows)} == {6, false, 6}

      row = Enum.find(env.rows, &(&1.agent_id == f.a.id and &1.variant_slug == "control"))
      assert row.metrics["client_turns_mean"] == %{value: nil, n: 0, reason: "insufficient_data"}
      assert {:ok, _json} = Jason.encode(env)
    end

    test "refuses an experiment on another surface" do
      {:ok, other} =
        Experiments.create_experiment(%{
          slug: "cm-other-#{u()}",
          name: "Other",
          surface_key: "planner.stage_budget",
          surface_target: "dispatch.planning"
        })

      assert {:error, %{code: :wrong_surface, recoverable: true}} =
               ToolArguments.dispatch("code_mode_report", %{"experiment_id" => other.id}, %{})
    end

    test "is in the experiments bundle" do
      assert %{bundle: "experiments"} =
               Enum.find(
                 Platform.Federation.ToolSurface.tool_definitions(),
                 &(&1.name == "code_mode_report")
               )
    end
  end

  # ── fixture helpers ─────────────────────────────────────────────────────

  defp insert_agent(tag) do
    %Agent{}
    |> Agent.changeset(%{slug: "cm-#{tag}-#{u()}", name: "CM #{tag}", status: "active"})
    |> Repo.insert!()
  end

  defp insert_runtime(agent) do
    user =
      Repo.insert!(%User{
        email: "cm_#{u()}@example.com",
        name: "CM User",
        oidc_sub: "oidc-cm-#{u()}"
      })

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "cm-rt-#{u()}",
      owner_user_id: user.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active"
    })
    |> Repo.insert!()
  end

  defp task!(project, agent) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "CM task #{u()}",
        phase_assignees: %{
          "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
        }
      })

    task
  end

  defp assign!(experiment, task, slug, excluded_reason) do
    Repo.insert!(
      Assignment.changeset(%Assignment{}, %{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: task.id,
        variant_slug: slug,
        assigned_at: @base,
        excluded_reason: excluded_reason
      })
    )
  end

  defp stage!(task, status, started_at, completed_at) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Stage",
        status: status,
        started_at: started_at,
        completed_at: completed_at
      })

    stage
  end

  defp validation!(stage, status) do
    Repo.insert!(
      Validation.changeset(%Validation{}, %{stage_id: stage.id, kind: "test_pass", status: status})
    )
  end

  defp ack!(task, stage, runtime, occurred_at) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task.id,
        phase: "execution",
        runtime_id: runtime.runtime_id,
        event_type: "execution.acked",
        occurred_at: occurred_at,
        idempotency_key: "cm-ack-#{u()}",
        payload: %{"stage_id" => stage.id, "subagent_id" => "sub-1"}
      })
    )
  end

  defp call!(runtime, agent, task, inserted_at, parent_run_id, tool) do
    Repo.insert!(%ToolCallRecord{
      runtime_id: runtime.runtime_id,
      agent_id: agent.id,
      tool: tool,
      status: "ok",
      duration_ms: 3,
      task_id: task.id,
      stage_id: nil,
      attribution: "explicit_arg",
      parent_run_id: parent_run_id,
      inserted_at: inserted_at
    })
  end

  defp unattributed_call!(runtime, agent, inserted_at) do
    Repo.insert!(%ToolCallRecord{
      runtime_id: runtime.runtime_id,
      agent_id: agent.id,
      tool: "space_get_messages",
      status: "ok",
      duration_ms: 3,
      attribution: "unattributed",
      inserted_at: inserted_at
    })
  end

  defp usage!(agent, task, stage, turns, tokens_in, tokens_out) do
    {:ok, _} =
      Analytics.record_usage_event(%{
        "model" => "claude-opus-5-5",
        "provider" => "anthropic",
        "session_key" => "s-#{u()}",
        "agent_id" => agent.id,
        "task_id" => task.id,
        "input_tokens" => tokens_in,
        "output_tokens" => tokens_out,
        "metadata" => %{"stage_id" => stage.id, "turns" => turns, "harness" => "claude-code"}
      })
  end
end
