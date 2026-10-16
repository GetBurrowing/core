defmodule Platform.Federation.ToolCallTest do
  @moduledoc """
  Task 01a114a8 stage 1: `Platform.Federation.ToolCall.invoke/4` is the one
  path both federation transports use, and every call through it leaves one
  `dispatch_tool_calls` row: ok, error or denied.

  The transport tests go through the REAL transports (`POST /mcp` and a
  joined `RuntimeChannel`), not `invoke/4`, so routing a transport back to
  `ToolArguments.dispatch/3` directly turns them red: no row is written.
  """

  use PlatformWeb.ChannelCase, async: false

  import Platform.TenancyFixtures
  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Federation.ToolCall
  alias Platform.Federation.ToolCallLedger
  alias Platform.Federation.ToolCallRecord
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks

  @sentinel "sk-live-SENTINEL"

  defmodule RaisingWriter do
    @moduledoc false
    def insert(_entry), do: raise(RuntimeError, "boom sk-live-SENTINEL")
  end

  setup do
    agent = insert_agent()
    org_id = Platform.TenancyFixtures.acme_org_id()
    {:ok, project} = Tasks.create_project(%{name: "ToolCall #{u()}", org_id: org_id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "ToolCall task"})
    %{agent: agent, task: task, project: project}
  end

  # ── transports ────────────────────────────────────────────────────────

  describe "POST /mcp" do
    test "an ok call writes one ledger row through ToolCall", %{agent: agent, task: task} do
      {runtime, token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())

      body = mcp_call(token, "task_get", %{"task_id" => task.id})
      assert body["result"]["isError"] in [false, nil]

      assert [row] = rows_for(runtime)
      assert row.tool == "task_get"
      assert row.status == "ok"
      assert row.runtime_id == runtime.runtime_id
      assert row.agent_id == agent.id
      assert row.attribution == "explicit_arg"
      assert row.task_id == task.id
      assert row.stage_id == nil
      assert row.parent_run_id == nil
      assert is_integer(row.duration_ms) and row.duration_ms >= 0
      assert is_integer(row.result_bytes) and row.result_bytes > 0
    end

    test "a denied call is refused with -32001 and recorded as denied", %{agent: agent} do
      {runtime, token} = insert_runtime(agent, AgentRuntime.default_tool_profile())
      refute "plan" in runtime.allowed_bundles

      body = mcp_call(token, "plan_create", %{"task_id" => Ecto.UUID.generate()})
      assert body["error"]["code"] == -32001

      assert [row] = rows_for(runtime)
      assert row.tool == "plan_create"
      assert row.status == "denied"
      assert row.result_bytes == nil
    end

    test "a handler error is recorded as error", %{agent: agent} do
      {runtime, token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())

      body = mcp_call(token, "task_get", %{"task_id" => Ecto.UUID.generate()})
      assert body["result"]["isError"] == true

      assert [%ToolCallRecord{tool: "task_get", status: "error"}] = rows_for(runtime)
    end

    test "SENTINEL in args reaches no ledger row", %{agent: agent, task: task} do
      {runtime, token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())

      mcp_call(token, "task_get", %{"task_id" => task.id, "api_key" => @sentinel})

      assert [row] = rows_for(runtime)
      refute inspect(row) =~ "SENTINEL"

      refute Repo.query!("SELECT row_to_json(d)::text FROM dispatch_tool_calls d").rows
             |> inspect()
             |> String.contains?("SENTINEL")
    end
  end

  describe "RuntimeChannel tool_call" do
    test "an ok call writes one ledger row through ToolCall", %{agent: agent, task: task} do
      {runtime, raw_token} = channel_runtime(agent)
      socket = join!(runtime, raw_token)

      log =
        capture_log([level: :debug], fn ->
          push(socket, "tool_call", %{
            "call_id" => "call-ledger-1",
            "tool" => "task_get",
            "args" => %{"task_id" => task.id, "api_key" => @sentinel}
          })

          assert_push "tool_result", %{call_id: "call-ledger-1", status: "ok"}
        end)

      refute log =~ "SENTINEL"

      assert [row] = rows_for(runtime)
      assert row.tool == "task_get"
      assert row.status == "ok"
      assert row.attribution == "explicit_arg"
      assert row.task_id == task.id
      refute inspect(row) =~ "SENTINEL"
    end

    test "a denied call keeps the socket's refusal frame and is recorded", %{agent: agent} do
      {runtime, raw_token} = channel_runtime(agent)
      socket = join!(runtime, raw_token)

      push(socket, "tool_call", %{
        "call_id" => "call-ledger-2",
        "tool" => "plan_create",
        "args" => %{"task_id" => Ecto.UUID.generate()}
      })

      assert_push "tool_result", %{
        call_id: "call-ledger-2",
        status: "error",
        error: %{code: "forbidden"}
      }

      assert [%ToolCallRecord{tool: "plan_create", status: "denied"}] = rows_for(runtime)
    end
  end

  # ── invoke/4 ──────────────────────────────────────────────────────────

  describe "invoke/4" do
    test "a raising ledger writer changes neither the result nor raises", %{
      agent: agent,
      task: task
    } do
      {runtime, _token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())
      args = %{"task_id" => task.id, "api_key" => @sentinel}

      expected = ToolCall.invoke("task_get", args, runtime)
      assert {:ok, %{id: task_id}} = expected
      assert task_id == task.id

      previous = Application.get_env(:platform, :tool_call_ledger_writer)
      Application.put_env(:platform, :tool_call_ledger_writer, RaisingWriter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, :tool_call_ledger_writer, previous),
          else: Application.delete_env(:platform, :tool_call_ledger_writer)
      end)

      log =
        capture_log(fn ->
          assert ToolCall.invoke("task_get", args, runtime) == expected
        end)

      assert log =~ "[ToolCallLedger] dropped ledger row: tool=task_get"
      assert log =~ "reason=RuntimeError"
      refute log =~ "SENTINEL"
      # Only the first call's row exists.
      assert length(rows_for(runtime)) == 1
    end

    test "parent_run_id is recorded", %{agent: agent, task: task} do
      {runtime, _token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())
      run_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ToolCall.invoke("task_get", %{"task_id" => task.id}, runtime,
                 parent_run_id: run_id
               )

      assert [%ToolCallRecord{parent_run_id: ^run_id}] = rows_for(runtime)
    end
  end

  # ── error_kind (task 01a115b5 stage 1) ────────────────────────────────

  describe "classify/2" do
    test "a failed suite_run run is error with its enumerated kind" do
      assert ToolCall.classify(
               "suite_run",
               {:ok, %{ok: false, error: %{kind: "fuel", message: "m"}}}
             ) == {"error", "fuel"}
    end

    test "a suite_run kind outside the set is error with a nil kind, never free text" do
      assert ToolCall.classify("suite_run", {:ok, %{ok: false, error: %{kind: "oops"}}}) ==
               {"error", nil}
    end

    test "a successful suite_run run is ok with a nil kind" do
      assert ToolCall.classify("suite_run", {:ok, %{ok: true, result: 1}}) == {"ok", nil}
    end

    test "any other tool returning ok:false stays ok with a nil kind" do
      assert ToolCall.classify(
               "task_get",
               {:ok, %{ok: false, error: %{kind: "script_error", message: "m"}}}
             ) == {"ok", nil}

      assert ToolCall.classify("task_get", {:ok, %{ok: false}}) == {"ok", nil}
    end

    test "errors and denials keep their status and carry no kind" do
      assert ToolCall.classify("suite_run", {:error, %{code: "missing_script"}}) ==
               {"error", nil}

      assert ToolCall.classify("task_get", :denied) == {"denied", nil}
    end
  end

  describe "the error_kind column" do
    test "an error_kind outside the enumerated set is an invalid changeset" do
      base = %{runtime_id: "rt", tool: "suite_run", status: "error", attribution: "unattributed"}

      refute ToolCallRecord.changeset(Map.put(base, :error_kind, "oops")).valid?
      assert ToolCallRecord.changeset(Map.put(base, :error_kind, "timeout")).valid?
    end

    test "the ledger writes error_kind", %{agent: agent} do
      {runtime, _token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())

      ToolCallLedger.insert(%{
        tool: "suite_run",
        status: "error",
        error_kind: "memory",
        duration_ms: 1,
        runtime_id: runtime.runtime_id,
        agent_id: agent.id,
        hints: %{}
      })

      assert [%ToolCallRecord{status: "error", error_kind: "memory"}] = rows_for(runtime)
    end

    test "a non-suite_run row over /mcp carries a nil error_kind", %{agent: agent, task: task} do
      {runtime, token} = insert_runtime(agent, Platform.Access.RuntimeProfiles.valid_modules())

      mcp_call(token, "task_get", %{"task_id" => task.id})
      assert [%ToolCallRecord{status: "ok", error_kind: nil}] = rows_for(runtime)
    end
  end

  # ── attribution ladder ────────────────────────────────────────────────

  describe "attribute/3" do
    setup %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Build",
          status: "running",
          started_at: DateTime.utc_now()
        })

      %{plan: plan, stage: stage, runtime_id: "rt-ladder-#{u()}", now: DateTime.utc_now()}
    end

    test "rung 1: task_id in args", %{task: task, runtime_id: rt, now: now} do
      assert ToolCallLedger.attribute(%{"task_id" => task.id}, rt, now) == %{
               attribution: "explicit_arg",
               task_id: task.id,
               stage_id: nil,
               lease_id: nil
             }
    end

    test "rung 1: stage_id alone resolves its task", ctx do
      assert ToolCallLedger.attribute(%{"stage_id" => ctx.stage.id}, ctx.runtime_id, ctx.now) ==
               %{
                 attribution: "explicit_arg",
                 task_id: ctx.task.id,
                 stage_id: ctx.stage.id,
                 lease_id: nil
               }
    end

    test "rung 1: plan_id alone resolves its task", ctx do
      assert %{attribution: "explicit_arg", task_id: task_id, stage_id: nil} =
               ToolCallLedger.attribute(%{"plan_id" => ctx.plan.id}, ctx.runtime_id, ctx.now)

      assert task_id == ctx.task.id
    end

    test "rung 2: space_id of the task's execution space", ctx do
      {:ok, space} = ExecutionSpace.find_or_create(ctx.task.id)

      assert ToolCallLedger.attribute(%{"space_id" => space.id}, ctx.runtime_id, ctx.now) == %{
               attribution: "execution_space",
               task_id: ctx.task.id,
               stage_id: nil,
               lease_id: nil
             }
    end

    test "rung 3: exactly one acked stage still running", ctx do
      insert_ack!(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      assert ToolCallLedger.attribute(%{}, ctx.runtime_id, ctx.now) == %{
               attribution: "sole_acked_stage",
               task_id: ctx.task.id,
               stage_id: ctx.stage.id,
               lease_id: nil
             }
    end

    test "rung 3 does not fire for two running acked stages", ctx do
      {:ok, other} =
        Tasks.create_stage(%{
          plan_id: ctx.plan.id,
          position: 2,
          name: "Second",
          status: "running",
          started_at: DateTime.utc_now()
        })

      insert_ack!(ctx.task.id, ctx.stage.id, ctx.runtime_id)
      insert_ack!(ctx.task.id, other.id, ctx.runtime_id)

      assert %{attribution: "unattributed"} =
               ToolCallLedger.attribute(%{}, ctx.runtime_id, ctx.now)
    end

    test "rung 3 ignores an acked stage that is no longer running", ctx do
      Repo.update!(Platform.Tasks.Stage.changeset(ctx.stage, %{status: "passed"}))
      insert_ack!(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      assert %{attribution: "unattributed"} =
               ToolCallLedger.attribute(%{}, ctx.runtime_id, ctx.now)
    end

    test "rung 4: exactly one live lease", ctx do
      lease = insert_lease!(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      assert ToolCallLedger.attribute(%{}, ctx.runtime_id, ctx.now) == %{
               attribution: "sole_lease",
               task_id: ctx.task.id,
               stage_id: ctx.stage.id,
               lease_id: lease.id
             }
    end

    test "rung 1 fills lease_id from the runtime's one live lease on the task", ctx do
      lease = insert_lease!(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      assert %{attribution: "explicit_arg", lease_id: lease_id} =
               ToolCallLedger.attribute(%{"task_id" => ctx.task.id}, ctx.runtime_id, ctx.now)

      assert lease_id == lease.id
    end

    test "rung 5: nothing matches", ctx do
      assert ToolCallLedger.attribute(%{}, ctx.runtime_id, ctx.now) == %{
               attribution: "unattributed",
               task_id: nil,
               stage_id: nil,
               lease_id: nil
             }
    end

    test "attribution_hints keeps only UUID-valued id keys", ctx do
      assert ToolCallLedger.attribution_hints(%{
               "task_id" => ctx.task.id,
               "stage_id" => "not-a-uuid",
               "api_key" => @sentinel,
               "space_id" => 7
             }) == %{"task_id" => ctx.task.id}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp rows_for(runtime) do
    Repo.all(
      from(r in ToolCallRecord,
        where: r.runtime_id == ^runtime.runtime_id,
        order_by: [asc: r.inserted_at]
      )
    )
  end

  defp insert_agent do
    %Agent{}
    |> Agent.changeset(%{slug: "toolcall-agent-#{u()}", name: "ToolCall Agent", status: "active"})
    |> Repo.insert!()
  end

  defp insert_user, do: root_admin!()

  defp insert_runtime(agent, bundles) do
    raw_token = AgentRuntime.generate_token()

    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "toolcall-rt-#{u()}",
        owner_user_id: insert_user().id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        allowed_bundles: bundles
      })
      |> Repo.insert!()

    {runtime, raw_token}
  end

  defp channel_runtime(agent) do
    {:ok, runtime} =
      Federation.register_runtime(insert_user().id, %{runtime_id: "toolcall-ch-#{u()}"})

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {:ok, _} =
      Platform.Access.RuntimeProfiles.set_tool_profile(
        activated,
        AgentRuntime.default_tool_profile() ++ ["task"]
      )

    {Federation.get_runtime(activated.id), raw_token}
  end

  defp join!(runtime, raw_token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    socket
  end

  defp mcp_call(token, name, args) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
    |> json_response(200)
  end

  defp insert_ack!(task_id, stage_id, runtime_id) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task_id,
        phase: "execution",
        runtime_id: runtime_id,
        event_type: "execution.acked",
        occurred_at: DateTime.utc_now(),
        idempotency_key: "ack-#{u()}",
        payload: %{"stage_id" => stage_id, "subagent_id" => "sub-#{u()}"}
      })
    )
  end

  defp insert_lease!(task_id, stage_id, runtime_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      ExecutionLease.changeset(%ExecutionLease{}, %{
        task_id: task_id,
        stage_id: stage_id,
        phase: "execution",
        runtime_id: runtime_id,
        status: "active",
        started_at: now,
        expires_at: DateTime.add(now, 1800, :second)
      })
    )
  end
end
