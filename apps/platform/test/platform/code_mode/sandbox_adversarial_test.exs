defmodule Platform.CodeMode.SandboxAdversarialTest do
  @moduledoc """
  Task 01a114a8 stage 2: what an adversarial `suite_run` script can and
  cannot do. Scripts run through `Platform.CodeMode.Run.execute/3`, the
  path `suite_run` takes after `ToolCall.invoke/4` has authorized the outer
  call, so every inner call goes through `ToolCall.invoke/4` for real.

  Mutation targets (each must turn a test here red; see the stage report):

    1. remove the `ToolAuthorization.authorize` hop from `ToolCall.invoke/4`
       -> "a tool outside the runtime's bundles is refused as forbidden";
    2. drop `StoreLimits` in `Runtime` -> "a finite 96 MB allocation is
       stopped at the 64 MB memory limit";
    3. disable fuel in `Runtime` -> "a finite CPU loop of a few seconds is
       stopped by fuel". That loop is FINITE (1.5e8 iterations, about 3.5 s
       on moon with fuel off), so the mutated run completes and fails
       instead of spinning.
  """

  use Platform.DataCase, async: false

  import Platform.CodeModeFixtures

  alias Platform.CodeMode.Bindings
  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Run
  alias Platform.CodeMode.Runtime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolCallRecord
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  setup do
    agent = insert_agent!()
    {runtime, _token} = insert_runtime!(agent, bundles(["code_mode"]))
    %{agent: agent, runtime: runtime}
  end

  defp run(runtime, script, opts \\ []) do
    {:ok, body} = Run.execute(runtime, script, opts)
    body
  end

  describe "no network, modules, files or host process" do
    for {label, script} <- [
          {"fetch", "fetch('http://x')"},
          {"require", "require('fs')"},
          {"import()", "await import('os')"},
          {"std.loadFile", "std.loadFile('/etc/passwd')"},
          {"os.open", "os.open('/etc/passwd', 0)"},
          {"setTimeout", "setTimeout(() => 1, 0)"},
          {"process", "process.exit(1)"}
        ] do
      test "#{label} is a script_error ReferenceError with no side effect", %{runtime: runtime} do
        body = run(runtime, unquote(script))

        assert %{ok: false, error: %{kind: "script_error", message: message}} = body
        assert message =~ "ReferenceError"
        assert body.calls == 0
        assert inner_rows(body.run_id) == []
      end
    end
  end

  describe "authorization" do
    test "a tool outside the runtime's bundles is refused as forbidden", %{runtime: runtime} do
      refute "plan" in runtime.allowed_bundles
      refute "task" in runtime.allowed_bundles

      body = run(runtime, "suite.plan_create({task_id: '#{Ecto.UUID.generate()}'})")

      assert %{ok: false, error: %{kind: "forbidden", message: message}} = body
      assert message =~ "tool 'plan_create' not in allowed bundles"
      assert body.calls == 1

      assert [%ToolCallRecord{tool: "plan_create", status: "denied", parent_run_id: parent}] =
               inner_rows(body.run_id)

      assert parent == body.run_id
    end

    test "suite.call to an ungranted tool is refused as forbidden", %{runtime: runtime} do
      body = run(runtime, "suite.call('task_update', {task_id: '#{Ecto.UUID.generate()}'})")

      assert %{ok: false, error: %{kind: "forbidden"}} = body
      assert [%ToolCallRecord{tool: "task_update", status: "denied"}] = inner_rows(body.run_id)
    end

    test "a nested suite_run is refused and ledgered as denied", %{runtime: runtime} do
      body = run(runtime, "suite.suite_run({script: '1'})")

      assert %{ok: false, error: %{kind: "forbidden", message: message}} = body
      assert message =~ "suite_run cannot be called from inside suite_run"
      assert [%ToolCallRecord{tool: "suite_run", status: "denied"}] = inner_rows(body.run_id)
    end

    test "a granted tool runs, and its row carries the run id", %{runtime: runtime} do
      body =
        run(runtime, "const s = suite.federation_status({}); typeof s === 'object' && s !== null")

      assert %{ok: true, result: true, calls: 1} = body
      assert [%ToolCallRecord{tool: "federation_status", status: "ok"}] = inner_rows(body.run_id)
    end

    test "an external-principal runtime reaches only chat tools" do
      org = Tenancy.get_org_by_slug!("sxi")
      external = World.create_user!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: org.id})

      {runtime, _token} =
        insert_runtime!(
          insert_agent!(),
          ~w(messaging space context_read task canvas code_mode),
          external.id
        )

      assert Enum.sort(Bindings.tool_names(runtime)) == Enum.sort(@chat_names)

      body = run(runtime, "Object.keys(suite).sort()")
      assert body.result == Enum.sort(["call" | @chat_names])

      body = run(runtime, "suite.task_get({task_id: '#{Ecto.UUID.generate()}'})")
      assert %{ok: false, error: %{kind: "forbidden"}} = body
      assert [%ToolCallRecord{tool: "task_get", status: "denied"}] = inner_rows(body.run_id)
    end
  end

  describe "CPU" do
    test "while(true){} is killed with kind fuel or timeout", %{runtime: runtime} do
      started = System.monotonic_time(:millisecond)
      body = run(runtime, "while(true){}", timeout_ms: 2_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert %{ok: false, error: %{kind: kind}} = body
      assert kind in ["fuel", "timeout"]
      assert elapsed < 2_000 + 2_000
    end

    # Mutation target 3. Fuel is set so this loop CANNOT finish inside it:
    # about 510 fuel per iteration x 1.5e8 iterations is about 7.6e10 fuel,
    # against 1e6 x 30_000 = 3e10 granted. The wall budget (30 s) is far
    # beyond the loop's real duration, so only fuel can stop it.
    test "a finite CPU loop of a few seconds is stopped by fuel", %{runtime: runtime} do
      limits = %{Limits.get() | fuel_per_ms: 1_000_000}

      body =
        run(runtime, "let i = 0; for (; i < 150000000; i++) {} i",
          limits: limits,
          timeout_ms: 30_000
        )

      assert %{ok: false, error: %{kind: "fuel"}} = body
    end
  end

  describe "memory" do
    test "let a=[];for(;;)a.push(new Array(1e6)) is killed with kind memory", %{runtime: runtime} do
      body = run(runtime, "let a=[];for(;;)a.push(new Array(1e6))")
      assert %{ok: false, error: %{kind: "memory"}} = body
    end

    # Mutation target 2: without StoreLimits, 96 MB fits and the script
    # returns 12.
    test "a finite 96 MB allocation is stopped at the 64 MB memory limit", %{runtime: runtime} do
      body =
        run(
          runtime,
          "let a=[]; for (let i = 0; i < 12; i++) a.push(new Float64Array(1e6)); a.length"
        )

      assert %{ok: false, error: %{kind: "memory"}} = body
    end
  end

  describe "call limit" do
    test "51 calls are stopped with call_limit at 50", %{runtime: runtime} do
      body = run(runtime, "for (let i = 0; i < 51; i++) suite.federation_status({})")

      assert %{ok: false, error: %{kind: "call_limit"}, calls: 50} = body
      assert length(inner_rows(body.run_id)) == 50
    end

    test "catching the call_limit error does not rescue the run", %{runtime: runtime} do
      script = """
      let n = 0;
      try { for (;;) { suite.federation_status({}); n++; } } catch (e) { }
      n
      """

      assert %{ok: false, error: %{kind: "call_limit"}, calls: 50} = run(runtime, script)
    end
  end

  describe "the module" do
    test "imports EXACTLY suite.host_call and five wasi functions" do
      {:ok, {_engine, module}} = Runtime.compiled()

      assert Wasmex.Module.imports(module) == %{
               "suite" => %{
                 "host_call" => {:fn, [:i32, :i32, :i32, :i32, :i32, :i32], [:i32]}
               },
               "wasi_snapshot_preview1" => %{
                 "clock_time_get" => {:fn, [:i32, :i64, :i32], [:i32]},
                 "fd_close" => {:fn, [:i32], [:i32]},
                 "fd_fdstat_get" => {:fn, [:i32, :i32], [:i32]},
                 "fd_seek" => {:fn, [:i32, :i64, :i32, :i32], [:i32]},
                 "fd_write" => {:fn, [:i32, :i32, :i32, :i32], [:i32]}
               }
             }

      names =
        Map.new(Wasmex.Module.imports(module), fn {namespace, fns} ->
          {namespace, fns |> Map.keys() |> Enum.sort()}
        end)

      assert names == Runtime.expected_imports()
    end

    test "the vendored artifact is the pinned build" do
      bytes = File.read!(Runtime.wasm_path())

      assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
               "97b3e1f68dd8d51e2cfdb36adb77574647339fdb0ab77727caf60af7caf9303a"

      assert Runtime.wasm_sha256() ==
               "97b3e1f68dd8d51e2cfdb36adb77574647339fdb0ab77727caf60af7caf9303a"
    end
  end

  test "a runtime whose row is gone mid-run is refused", %{runtime: runtime} do
    Repo.delete!(runtime)

    assert %{ok: false, error: %{kind: "forbidden", message: message}} =
             run(runtime, "suite.federation_status({})")

    assert message =~ "no longer active"
  end

  test "an inner tool error is catchable and carries the tool's code", %{agent: agent} do
    {runtime, _} = insert_runtime!(agent, bundles(["code_mode", "task"]))
    org_id = Platform.TenancyFixtures.fabrikam_org_id()
    {:ok, _project} = Tasks.create_project(%{name: "CM #{u()}", org_id: org_id})

    script = """
    try { suite.task_get({task_id: '#{Ecto.UUID.generate()}'}); 'no error' }
    catch (e) { [e.name, e.kind] }
    """

    assert %{ok: true, result: ["SuiteError", "tool_error"]} = run(runtime, script)
  end
end
