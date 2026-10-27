defmodule Platform.CodeMode.Runtime do
  @moduledoc """
  Runs one script in a fresh QuickJS-ng wasm instance (task 01a114a8 stage 2).

  The artifact is `priv/code_mode/quickjs_cm.wasm`, built from
  `native/code_mode/cm.c` by `scripts/build-code-mode-wasm.sh`. It is
  compiled once per node (cached in `:persistent_term`) and its sha256 is
  checked against `wasm_sha256/0` before it is compiled, so a priv file that
  is not the reviewed artifact is refused rather than run.

  ## What the instance can reach

  One wasmtime Store per run, created with:

    * WASI preview 1 with NO preopened directories, no args, no env and no
      stdio pipes. wasmtime's default stdin is empty and its default
      stdout/stderr discard, so nothing the guest writes reaches the BEAM's
      stdio and nothing accumulates host-side (Wasmex pipes are unbounded,
      which is why none are attached). The module imports only the five
      wasi functions wasi-libc needs (`expected_imports/0`).
    * `burrow.host_call`, serviced by the `:host` function in THIS process.
      It is the only path from a script to anything in core, and the
      callers of this module route it through
      `Platform.Federation.ToolCall.invoke/4` (`Platform.CodeMode.Bindings`).
    * `Wasmex.StoreLimits{memory_size}` and fuel (`Platform.CodeMode.Limits`).

  ## Time

  `cm_run` is called with a native timeout: at the deadline Wasmex sets the
  Store's interrupt flag and wasmtime's epoch check (a 10 ms ticker) traps
  the guest at its next check, then sends NO reply. So a timed-out run is
  detected here by the reply not arriving, after a short grace. The wasm
  call itself has then been interrupted, or is about to be once a host call
  in flight returns; it is not left spinning. `Platform.CodeMode.Slots`
  still waits for the Store to go idle before freeing the run's slot.

  That interrupt depends on the epoch ticker getting a tokio worker, so
  every run's native work (Store, instance, setup and `cm_run`) holds one of
  the node's `Platform.CodeMode.Permits`: at most one fewer guest than
  wasmex has tokio workers runs at once, node-wide, whichever pool started
  it, and no one `:permit_key` holds all of them. The wall deadline is
  taken when `run/3` is called and the wait for a
  permit is charged to it: `cm_run` gets `wall_ms` minus that wait, and a
  run still waiting at its deadline returns `timeout` without running.
  Setup calls keep their own 5 s bound and are not charged. The permit is
  returned once the Store is idle.

  Host callbacks arrive as `{:invoke_callback, ...}` messages to the process
  that instantiated the module, which is the process calling `run/3`. This
  module services them itself (as `Wasmex`'s own GenServer does), so tool
  calls run in the caller's process.
  """

  require Logger

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Permits
  alias Wasmex.Wasi.WasiOptions

  @wasm_sha256 "0aafebd10bd889e34afd544595d041d6998af9f5a2c2277e80e16c33cb510792"

  @expected_imports %{
    "burrow" => ["host_call"],
    "wasi_snapshot_preview1" => [
      "clock_time_get",
      "fd_close",
      "fd_fdstat_get",
      "fd_seek",
      "fd_write"
    ]
  }

  # Setup calls (_initialize, cm_alloc) never call the host.
  @setup_timeout_ms 5_000
  @setup_fuel 50_000_000
  # How long past the native deadline to wait for a reply that is not coming.
  @timeout_grace_ms 500
  @max_name_bytes 256
  @max_args_bytes 1_048_576

  @type outcome ::
          {:ok, %{result: term(), logs: [String.t()], logs_truncated: boolean()}}
          | {:error, String.t(), String.t()}

  @doc "The pinned sha256 of `priv/code_mode/quickjs_cm.wasm`."
  def wasm_sha256, do: @wasm_sha256

  @doc "Every import the module may declare, by namespace."
  def expected_imports, do: @expected_imports

  @doc "Path of the vendored artifact."
  def wasm_path, do: Application.app_dir(:platform, "priv/code_mode/quickjs_cm.wasm")

  @doc """
  Run `script` with `inputs` (any JSON value).

  Options:

    * `:host` — `fn name, args_json -> response_json end`, called in this
      process for every `burrow.host_call`. Defaults to refusing everything.
    * `:tools` — tool names to bind on `burrow` (also reachable as `suite`,
      the same object) (default none).
    * `:limits` — `Platform.CodeMode.Limits.get/0` by default.
    * `:wall_ms` — the wall budget, default `limits.wall_ms`.
    * `:on_store` — called with the Store before it runs anything, so a
      caller can track it (`Platform.CodeMode.Slots`).
    * `:permit_key` — the key the run's native permit is capped under
      (`Platform.CodeMode.Permits`): one key may hold at most one fewer
      permit than the node has. Default nil, no per-key cap.

  Returns `{:ok, %{result, logs, logs_truncated}}` or
  `{:error, kind, message}` with kind one of `timeout`, `memory`, `fuel`,
  `output_limit`, `script_error`, `forbidden`, `call_limit`.
  """
  @spec run(String.t(), term(), keyword()) :: outcome()
  def run(script, inputs, opts \\ []) when is_binary(script) do
    limits = Keyword.get_lazy(opts, :limits, &Limits.get/0)
    wall_ms = Keyword.get(opts, :wall_ms, Limits.wall_ms(limits, nil))
    host = Keyword.get(opts, :host, &refuse_all/2)
    on_store = Keyword.get(opts, :on_store, fn _store -> :ok end)

    config =
      Jason.encode!(%{tools: Keyword.get(opts, :tools, []), log_cap: limits.log_bytes})

    started_at = System.monotonic_time(:millisecond)

    with {:ok, inputs_json} <- encode_inputs(inputs),
         {:ok, {engine, module}} <- compiled() do
      execute(script, inputs_json, config, %{
        engine: engine,
        module: module,
        limits: limits,
        wall_ms: wall_ms,
        started_at: started_at,
        deadline: started_at + wall_ms,
        host: host,
        on_store: on_store,
        permit_key: Keyword.get(opts, :permit_key)
      })
    end
  end

  defp encode_inputs(inputs) do
    case Jason.encode(inputs) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, "script_error", "inputs must be JSON-encodable"}
    end
  end

  # Every native step of a run (Store, instance, setup calls, cm_run) holds
  # a node-wide permit (`Platform.CodeMode.Permits`). The wait for one is
  # charged to the run's wall budget; a run that cannot get one before its
  # deadline times out like any other.
  defp execute(script, inputs_json, config, ctx) do
    case Permits.acquire(ctx.permit_key, ctx.deadline) do
      {:ok, permit} ->
        waited = max(System.monotonic_time(:millisecond) - ctx.started_at, 0)
        execute_with_permit(script, inputs_json, config, ctx, permit, ctx.wall_ms - waited)

      {:error, :timeout} ->
        timeout(ctx.wall_ms)
    end
  end

  defp execute_with_permit(_script, _inputs_json, _config, ctx, permit, run_ms)
       when run_ms <= 0 do
    Permits.release(permit)
    timeout(ctx.wall_ms)
  end

  defp execute_with_permit(script, inputs_json, config, ctx, permit, run_ms) do
    on_store = fn store ->
      Permits.attach_store(permit, store)
      ctx.on_store.(store)
    end

    outcome =
      try do
        execute_native(script, inputs_json, config, %{ctx | on_store: on_store}, run_ms)
      catch
        kind, reason ->
          Permits.release_when_idle(permit)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case outcome do
      {:error, "timeout", _} -> Permits.release_when_idle(permit)
      _ -> Permits.release(permit)
    end

    outcome
  end

  defp execute_native(script, inputs_json, config, ctx, run_ms) do
    {:ok, store} =
      Wasmex.Store.new_wasi(
        %WasiOptions{args: [], env: %{}, preopen: []},
        %Wasmex.StoreLimits{memory_size: ctx.limits.memory_bytes},
        ctx.engine
      )

    ctx.on_store.(store)
    :ok = Wasmex.StoreOrCaller.set_fuel(store, @setup_fuel)

    imports = %{"burrow" => %{"host_call" => host_import(ctx.host, ctx.limits)}}
    {:ok, instance} = Wasmex.Instance.new(store, ctx.module, imports, [])
    {:ok, memory} = Wasmex.Instance.memory(store, instance)

    with {:ok, _} <- call(store, instance, imports, "_initialize", [], @setup_timeout_ms),
         {:ok, script_ptr} <- put(store, instance, imports, memory, script),
         {:ok, inputs_ptr} <- put(store, instance, imports, memory, inputs_json),
         {:ok, config_ptr} <- put(store, instance, imports, memory, config),
         :ok <- Wasmex.StoreOrCaller.set_fuel(store, Limits.fuel(ctx.limits, run_ms)) do
      params = [
        script_ptr,
        byte_size(script),
        inputs_ptr,
        byte_size(inputs_json),
        config_ptr,
        byte_size(config)
      ]

      case call(store, instance, imports, "cm_run", params, run_ms) do
        {:ok, [result_ptr]} -> read_result(store, memory, result_ptr, ctx.limits)
        {:error, :timeout} -> timeout(ctx.wall_ms)
        {:error, reason} -> trapped(store, memory, reason, ctx.limits)
      end
    else
      {:error, :timeout} -> timeout(ctx.wall_ms)
      {:error, reason} -> trapped(store, memory, reason, ctx.limits)
    end
  end

  # Allocate len+1 bytes in the guest and write `bytes` NUL-terminated
  # (QuickJS's parser and JSON reader require it).
  defp put(store, instance, imports, memory, bytes) do
    with {:ok, [ptr]} when ptr > 0 <-
           call(store, instance, imports, "cm_alloc", [byte_size(bytes) + 1], @setup_timeout_ms),
         :ok <- Wasmex.Memory.write_binary(store, memory, ptr, bytes <> <<0>>) do
      {:ok, ptr}
    else
      {:ok, [_null]} -> {:error, "(MemoryOutOfBounds) cm_alloc returned NULL"}
      other -> other
    end
  end

  defp call(store, instance, imports, name, params, timeout_ms) do
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout_ms + @timeout_grace_ms

    :ok =
      Wasmex.Instance.call_exported_function(
        store,
        instance,
        name,
        params,
        {self(), ref},
        timeout_ms
      )

    await(ref, deadline, imports)
  end

  defp await(ref, deadline, imports) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, result} ->
        result

      {:invoke_callback, namespace, name, context, params, token} ->
        invoke_callback(imports, namespace, name, context, params, token)
        await(ref, deadline, imports)
    after
      remaining -> {:error, :timeout}
    end
  end

  # Mirrors `Wasmex.handle_info({:invoke_callback, ...})` (wasmex 0.15.1).
  defp invoke_callback(imports, namespace, name, context, params, token) do
    context = %{
      memory: Wasmex.Memory.__wrap_resource__(Map.get(context, :memory)),
      caller: Wasmex.StoreOrCaller.__wrap_resource__(Map.get(context, :caller))
    }

    {success, results} =
      try do
        {:fn, _params, [_result], callback} = imports |> Map.fetch!(namespace) |> Map.fetch!(name)
        {true, [apply(callback, [context | params])]}
      rescue
        error ->
          Logger.warning("[CodeMode] host callback raised #{inspect(error.__struct__)}")
          {false, []}
      catch
        kind, _reason ->
          Logger.warning("[CodeMode] host callback exited (#{kind})")
          {false, []}
      end

    :ok = Wasmex.Native.instance_receive_callback_result(token, success, results)
  end

  defp host_import(host, limits) do
    {:fn, [:i32, :i32, :i32, :i32, :i32, :i32], [:i32],
     fn %{memory: memory, caller: caller}, name_ptr, name_len, args_ptr, args_len, out, cap ->
       response =
         if name_len > @max_name_bytes or args_len > @max_args_bytes do
           host_error("invalid_args", "the call's name or arguments are too large")
         else
           name = Wasmex.Memory.read_binary(caller, memory, name_ptr, name_len)
           args = Wasmex.Memory.read_binary(caller, memory, args_ptr, args_len)

           if is_binary(name) and is_binary(args),
             do: host.(name, args),
             else: host_error("invalid_args", "the call's name or arguments are unreadable")
         end

       response =
         if byte_size(response) > min(cap, limits.inner_result_bytes + 65_536) do
           host_error("result_too_large", "the call's result exceeds the sandbox buffer")
         else
           response
         end

       :ok = Wasmex.Memory.write_binary(caller, memory, out, response)
       byte_size(response)
     end}
  end

  @doc """
  Send `message` to `pid` once `store` is idle: a Store runs one operation
  at a time, so a `get_fuel` probe completes only after any native call in
  flight on it has returned. The one idle probe `Platform.CodeMode.Slots`
  and `Platform.CodeMode.Permits` both drain with.
  """
  @spec notify_when_idle(Wasmex.StoreOrCaller.t(), pid(), term()) :: :ok
  def notify_when_idle(store, pid, message) do
    {:ok, _} =
      Task.start(fn ->
        _ = Wasmex.StoreOrCaller.get_fuel(store)
        send(pid, message)
      end)

    :ok
  end

  @doc false
  def host_error(kind, message), do: Jason.encode!(%{ok: false, kind: kind, message: message})

  defp refuse_all(_name, _args),
    do: host_error("forbidden", "no tools are bound in this sandbox")

  defp read_result(store, memory, ptr, limits) do
    cap = limits.max_result_bytes + limits.log_bytes * 2 + 4_096

    with true <- ptr > 0,
         <<len::little-unsigned-32>> <- Wasmex.Memory.read_binary(store, memory, ptr, 4) do
      if len > cap do
        {:error, "output_limit", output_limit_message(limits)}
      else
        store |> Wasmex.Memory.read_binary(memory, ptr + 4, len) |> decode_result(limits)
      end
    else
      _ -> {:error, "memory", "the sandbox ran out of memory"}
    end
  end

  defp decode_result(json, limits) do
    case Jason.decode(json) do
      {:ok, %{"ok" => true, "result" => result} = body} ->
        if byte_size(Jason.encode!(result)) > limits.max_result_bytes do
          {:error, "output_limit", output_limit_message(limits)}
        else
          {:ok,
           %{
             result: result,
             logs: Map.get(body, "logs", []),
             logs_truncated: Map.get(body, "logs_truncated", false)
           }}
        end

      {:ok, %{"ok" => false, "error" => %{"kind" => kind, "message" => message}}} ->
        {:error, kind, message}

      _ ->
        {:error, "script_error", "the sandbox returned a malformed result"}
    end
  end

  defp output_limit_message(limits),
    do: "the script's result exceeds #{limits.max_result_bytes} bytes of JSON"

  defp timeout(wall_ms),
    do: {:error, "timeout", "the script exceeded its #{wall_ms} ms wall limit"}

  # A trap, in wasmtime 47's wording ("wasm trap: all fuel consumed by
  # WebAssembly", "wasm trap: interrupt", "wasm trap: call stack
  # exhausted"; the adversarial tests pin each). Anything else
  # (unreachable, stack exhaustion, a failed allocation that aborted) is a
  # memory error when linear memory is at its cap, else a script error.
  defp trapped(store, memory, reason, limits) do
    reason = if is_binary(reason), do: reason, else: inspect(reason)

    cond do
      String.contains?(reason, "all fuel consumed") ->
        {:error, "fuel", "the script exhausted its CPU budget (fuel)"}

      String.contains?(reason, "wasm trap: interrupt") ->
        {:error, "timeout", "the script was interrupted at its wall limit"}

      String.contains?(reason, "call stack exhausted") ->
        {:error, "script_error",
         "the script exhausted the sandbox call stack (recursion too deep)"}

      at_memory_cap?(store, memory, limits) ->
        {:error, "memory", "the script exceeded its #{limits.memory_bytes} byte memory limit"}

      true ->
        {:error, "script_error", "the sandbox trapped: " <> String.slice(reason, 0, 300)}
    end
  end

  defp at_memory_cap?(store, memory, limits) do
    Wasmex.Memory.size(store, memory) > limits.memory_bytes - 2 * 65_536
  rescue
    _ -> false
  end

  @doc false
  # {engine, module}, compiled once per node. Public for the tests.
  def compiled do
    case :persistent_term.get({__MODULE__, :compiled}, nil) do
      nil -> compile()
      compiled -> {:ok, compiled}
    end
  end

  defp compile do
    bytes = File.read!(wasm_path())
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if sha != @wasm_sha256 do
      raise "code_mode: #{wasm_path()} has sha256 #{sha}, expected #{@wasm_sha256}"
    end

    config =
      %Wasmex.EngineConfig{}
      |> Wasmex.EngineConfig.consume_fuel(true)
      |> Wasmex.EngineConfig.cranelift_opt_level(:speed)

    {:ok, engine} = Wasmex.Engine.new(config)
    {:ok, store} = Wasmex.Store.new(nil, engine)
    {:ok, module} = Wasmex.Module.compile(store, bytes)
    :persistent_term.put({__MODULE__, :compiled}, {engine, module})
    {:ok, {engine, module}}
  end
end
