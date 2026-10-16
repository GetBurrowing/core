defmodule Platform.CodeMode.SuiteRunTest do
  @moduledoc """
  Task 01a114a8 stage 2: `suite_run` over the real `/mcp` transport. The
  outer call is authorized by `ToolCall.invoke/4` like any tool, the bundle
  is off by default, and the ledger holds the run's fingerprint (never its
  script, inputs or result) plus one row per inner call.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.CodeModeFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.CodeMode.Bindings
  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Run
  alias Platform.CodeMode.Slots
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolCallRecord
  alias Platform.Repo

  @sentinel "sk-live-SENTINEL"

  setup do
    %{agent: insert_agent!()}
  end

  describe "the bundle" do
    test "code_mode is grantable and not a default" do
      assert "code_mode" in Platform.Access.RuntimeProfiles.valid_modules()
      refute "code_mode" in AgentRuntime.default_tool_profile()
    end

    test "a default runtime does not see suite_run and is refused -32001", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, AgentRuntime.default_tool_profile())

      tools = mcp(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      refute "suite_run" in tools

      body = mcp_call(token, "suite_run", %{"script" => "1"})
      assert body["error"]["code"] == -32001
    end

    test "a runtime granted code_mode sees suite_run", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      tools = mcp(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      assert "suite_run" in tools
    end

    test "bindings are the runtime's effective tools minus suite_run", %{agent: agent} do
      {runtime, _token} = insert_runtime!(agent, bundles(["code_mode", "canvas"]))

      expected = ToolAuthorization.tool_names(runtime) -- ["suite_run"]
      assert Bindings.tool_names(runtime) == expected
      assert "canvas.create" in expected

      {:ok, body} = Run.execute(runtime, "[typeof suite.canvas.create, typeof suite.suite_run]")
      # suite_run is not BOUND; an unbound name still resolves to a caller
      # that the host refuses, so typeof is "function" for both.
      assert body.result == ["function", "function"]

      {:ok, body} = Run.execute(runtime, "Object.keys(suite).includes('suite_run')")
      assert body.result == false
    end
  end

  describe "attribution by inputs (task 01a114a8 stage 4)" do
    test "the run and an id-less inner call take the task from inputs; an inner call naming its own task keeps it",
         %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))
      task_id = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      script = """
      suite.federation_status({});
      try { suite.task_get({task_id: inputs.other}); } catch (e) {}
      1
      """

      body =
        mcp_call(token, "suite_run", %{
          "script" => script,
          "inputs" => %{"task_id" => task_id, "other" => other}
        })

      assert %{"ok" => true, "run_id" => run_id} = result_json(body)

      outer = Repo.get!(ToolCallRecord, run_id)
      assert {outer.task_id, outer.attribution} == {task_id, "explicit_arg"}

      assert [status, get] = inner_rows(run_id)

      assert {status.tool, status.task_id, status.attribution} ==
               {"federation_status", task_id, "explicit_arg"}

      assert {get.tool, get.task_id, get.attribution} == {"task_get", other, "explicit_arg"}
    end

    test "a run with no ids in inputs attributes nothing from them", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      body =
        mcp_call(token, "suite_run", %{
          "script" => "suite.federation_status({}); 1",
          "inputs" => %{"task_id" => "not-a-uuid"}
        })

      assert %{"ok" => true, "run_id" => run_id} = result_json(body)
      assert Repo.get!(ToolCallRecord, run_id).attribution == "unattributed"
      assert [%{attribution: "unattributed", task_id: nil}] = inner_rows(run_id)
    end
  end

  describe "POST /mcp tools/call suite_run" do
    test "runs, returns the result, and ledgers the run and its inner calls", %{agent: agent} do
      {runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      script = """
      const a = suite.federation_status({});
      const b = suite.call('federation_status', {});
      console.log('two calls');
      ({n: inputs.n + 1, same: a.length === b.length})
      """

      # The run's one log line is :info; test.exs keeps the primary level
      # higher, so raise this module's level for the capture.
      Logger.put_module_level(Platform.CodeMode.Run, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.CodeMode.Run) end)

      log =
        capture_log([level: :debug], fn ->
          body = mcp_call(token, "suite_run", %{"script" => script, "inputs" => %{"n" => 41}})
          send(self(), {:body, body})
        end)

      assert_received {:body, body}
      result = result_json(body)

      assert %{
               "ok" => true,
               "result" => %{"n" => 42, "same" => true},
               "logs" => ["two calls"],
               "calls" => 2,
               "run_id" => run_id
             } = result

      assert is_integer(result["elapsed_ms"])

      outer = Repo.get!(ToolCallRecord, run_id)
      assert outer.tool == "suite_run"
      assert outer.status == "ok"
      assert outer.error_kind == nil
      assert outer.parent_run_id == nil
      assert outer.runtime_id == runtime.runtime_id
      assert outer.script_bytes == byte_size(script)

      assert outer.script_sha256 ==
               :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)

      assert [%{tool: "federation_status"}, %{tool: "federation_status"}] = inner_rows(run_id)

      assert log =~ "[CodeMode] suite_run run=#{run_id}"
      refute log =~ "two calls"
      refute log =~ "federation_status({})"
    end

    test "SENTINEL in the script and inputs reaches no row and no log", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      script = "const k = '#{@sentinel}'; console.log(k); [k, inputs.key]"

      log =
        capture_log([level: :debug], fn ->
          body =
            mcp_call(token, "suite_run", %{"script" => script, "inputs" => %{"key" => @sentinel}})

          assert %{"ok" => true} = result_json(body)
        end)

      refute log =~ "SENTINEL"

      refute Repo.query!("SELECT row_to_json(d)::text FROM dispatch_tool_calls d").rows
             |> inspect()
             |> String.contains?("SENTINEL")
    end

    test "a missing script is a recoverable tool error", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      body = mcp_call(token, "suite_run", %{"inputs" => %{}})
      assert body["result"]["isError"] == true
      assert %{"code" => "missing_script"} = result_json(body)
    end

    test "a script error is a successful call with ok:false", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      body = mcp_call(token, "suite_run", %{"script" => "nope()"})
      assert body["result"]["isError"] == false
      assert %{"ok" => false, "error" => %{"kind" => "script_error"}} = result_json(body)
    end
  end

  describe "a failed run in the ledger (task 01a115b5 stage 1)" do
    test "a script error keeps its wire shape and is ledgered as error with its kind", %{
      agent: agent
    } do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      body = mcp_call(token, "suite_run", %{"script" => "nope()"})
      assert body["result"]["isError"] == false

      assert %{"ok" => false, "error" => %{"kind" => "script_error"}, "run_id" => run_id} =
               result_json(body)

      row = Repo.get!(ToolCallRecord, run_id)
      assert row.tool == "suite_run"
      assert row.status == "error"
      assert row.error_kind == "script_error"
      assert row.script_bytes == 6
    end

    test "a run stopped at the call limit is ledgered as call_limit", %{agent: agent} do
      previous = Application.get_env(:platform, Platform.CodeMode)
      Application.put_env(:platform, Platform.CodeMode, max_calls: 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, Platform.CodeMode, previous),
          else: Application.delete_env(:platform, Platform.CodeMode)
      end)

      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      script = "for (let i = 0; i < 3; i++) suite.federation_status({})"
      body = mcp_call(token, "suite_run", %{"script" => script})
      assert body["result"]["isError"] == false

      assert %{"ok" => false, "error" => %{"kind" => "call_limit"}, "calls" => 2} =
               result = result_json(body)

      row = Repo.get!(ToolCallRecord, result["run_id"])
      assert row.status == "error"
      assert row.error_kind == "call_limit"
      # The inner calls that ran are still ledgered as ok.
      assert [%{status: "ok"}, %{status: "ok"}] = inner_rows(result["run_id"])
    end

    test "SENTINEL in a thrown error's message reaches no row and no log", %{agent: agent} do
      {_runtime, token} = insert_runtime!(agent, bundles(["code_mode"]))

      Logger.put_module_level(Platform.CodeMode.Run, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.CodeMode.Run) end)

      log =
        capture_log([level: :debug], fn ->
          body =
            mcp_call(token, "suite_run", %{"script" => "throw new Error('#{@sentinel}')"})

          send(self(), {:body, body})
        end)

      assert_received {:body, body}

      assert %{"ok" => false, "error" => %{"kind" => "script_error"}, "run_id" => run_id} =
               result_json(body)

      assert Repo.get!(ToolCallRecord, run_id).status == "error"
      refute log =~ "SENTINEL"

      refute Repo.query!("SELECT row_to_json(d)::text FROM dispatch_tool_calls d").rows
             |> inspect()
             |> String.contains?("SENTINEL")
    end
  end

  describe "the runtime is reloaded per inner call" do
    test "a grant revoked between two calls refuses the second", %{agent: agent} do
      {runtime, _token} = insert_runtime!(agent, bundles(["code_mode"]))
      run_id = Platform.Types.UUIDv7.generate()

      host =
        Bindings.host(%{
          runtime_pk: runtime.id,
          runtime_id: runtime.runtime_id,
          agent_id: agent.id,
          run_id: run_id,
          store_scope: "runtime:" <> runtime.runtime_id,
          limits: Limits.get(),
          counter: Bindings.new_counter()
        })

      assert %{"ok" => true} = Jason.decode!(host.("federation_status", "{}"))

      {:ok, _} = Platform.Access.RuntimeProfiles.set_tool_profile(runtime, ["code_mode", "space"])

      assert %{"ok" => false, "kind" => "forbidden"} =
               Jason.decode!(host.("federation_status", "{}"))

      assert [%{status: "ok"}, %{status: "denied"}] = inner_rows(run_id)
    end
  end

  describe "concurrency" do
    test "a third concurrent run for one runtime is refused, not queued", %{agent: agent} do
      {runtime, _token} = insert_runtime!(agent, bundles(["code_mode"]))
      holders = for _ <- 1..2, do: hold_slot(runtime.runtime_id)

      assert {:error, %{code: "concurrency_limit", recoverable: true}} =
               Run.execute(runtime, "1")

      Enum.each(holders, &release_holder/1)
      assert {:ok, %{ok: true, result: 1}} = Run.execute(runtime, "1")
    end

    test "the node cap refuses a run from another runtime", %{agent: agent} do
      {runtime, _token} = insert_runtime!(agent, bundles(["code_mode"]))
      holder = hold_slot("some-other-runtime-#{u()}")
      limits = %{Limits.get() | global_concurrency: 1}

      assert {:error, %{code: "concurrency_limit", error: message}} =
               Run.execute(runtime, "1", limits: limits)

      assert message =~ "the node already has 1"
      release_holder(holder)
    end
  end

  describe "store" do
    test "a value set in one run is read in the next, then expires", %{agent: agent} do
      {runtime, _token} = insert_runtime!(agent, bundles(["code_mode"]))

      assert {:ok, %{ok: true, result: true}} =
               Run.execute(runtime, "store.set('k', {v: 1}, {ttl: 60})")

      assert {:ok, %{ok: true, result: %{"v" => 1}}} = Run.execute(runtime, "store.get('k')")

      # Another session does not see it.
      assert {:ok, %{ok: true, result: nil}} =
               Run.execute(runtime, "store.get('k')", session: "elsewhere")

      Platform.CodeMode.Store.sweep(System.system_time(:millisecond) + 61_000)
      assert {:ok, %{ok: true, result: nil}} = Run.execute(runtime, "store.get('k')")
    end
  end

  defp hold_slot(runtime_id) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, slot} = Slots.acquire(runtime_id)
        send(test, {:held, self()})

        receive do
          :release -> Slots.release(slot)
        end

        send(test, {:released, self()})
      end)

    assert_receive {:held, ^pid}
    pid
  end

  defp release_holder(pid) do
    send(pid, :release)
    assert_receive {:released, ^pid}
    # The cast is processed before this call returns.
    _ = Slots.held()
  end
end
