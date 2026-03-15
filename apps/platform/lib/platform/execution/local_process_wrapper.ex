defmodule Platform.Execution.LocalProcessWrapper do
  @moduledoc false

  use GenServer

  @type provider_ref :: %{
          provider: :local,
          run_id: String.t(),
          workspace_root: String.t(),
          workspace_path: String.t(),
          wrapper_pid: pid(),
          os_pid: pos_integer() | nil
        }

  defstruct run_id: nil,
            run_server: nil,
            workspace_root: nil,
            workspace_path: nil,
            port: nil,
            os_pid: nil,
            command: nil,
            args: [],
            env: [],
            status: :running,
            stop_mode: nil,
            exit_status: nil

  @type state :: %__MODULE__{
          run_id: String.t(),
          run_server: pid(),
          workspace_root: String.t(),
          workspace_path: String.t(),
          port: port() | nil,
          os_pid: pos_integer() | nil,
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          status: :running | :exited,
          stop_mode: :graceful | :force | nil,
          exit_status: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec provider_ref(pid()) :: provider_ref()
  def provider_ref(server), do: GenServer.call(server, :provider_ref)

  @spec describe(pid()) :: {:ok, map()} | {:error, term()}
  def describe(server), do: GenServer.call(server, :describe)

  @spec request_stop(pid()) :: :ok | {:error, term()}
  def request_stop(server), do: GenServer.call(server, :request_stop)

  @spec force_stop(pid()) :: :ok | {:error, term()}
  def force_stop(server), do: GenServer.call(server, :force_stop)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    run_id = Keyword.fetch!(opts, :run_id)
    run_server = Keyword.fetch!(opts, :run_server)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    command = Keyword.fetch!(opts, :command)
    args = Enum.map(Keyword.get(opts, :args, []), &to_string/1)
    env = Keyword.get(opts, :env, [])

    port_opts = [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      {:args, args},
      {:cd, workspace_path}
    ]

    port_opts =
      if env != [] do
        port_opts ++ [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
      else
        port_opts
      end

    port = Port.open({:spawn_executable, command}, port_opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, child_pid} when is_integer(child_pid) and child_pid > 0 -> child_pid
        _ -> nil
      end

    {:ok,
     %__MODULE__{
       run_id: run_id,
       run_server: run_server,
       workspace_root: workspace_root,
       workspace_path: workspace_path,
       port: port,
       os_pid: os_pid,
       command: command,
       args: args,
       env: env
     }}
  end

  @impl true
  def handle_call(:provider_ref, _from, state) do
    {:reply, provider_ref_from_state(state), state}
  end

  def handle_call(:describe, _from, state) do
    {:reply, {:ok, describe_state(state)}, state}
  end

  def handle_call(:request_stop, _from, state) do
    state = %{state | stop_mode: state.stop_mode || :graceful}
    {:reply, maybe_signal(state, "-TERM"), state}
  end

  def handle_call(:force_stop, _from, state) do
    state = %{state | stop_mode: :force}
    {:reply, maybe_signal(state, "-KILL"), state}
  end

  @impl true
  def handle_info({port, {:data, _output}}, %__MODULE__{port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, exit_status}}, %__MODULE__{port: port} = state) do
    state = %{state | port: nil, status: :exited, exit_status: exit_status}

    # Notify the run server about the exit. The run server may or may not
    # have a `runner_exited/2` callback depending on the current version;
    # we send an async message so the wrapper never blocks on notification.
    if is_pid(state.run_server) and Process.alive?(state.run_server) do
      send(
        state.run_server,
        {:runner_exited, state.run_id,
         %{
           exit_code: exit_status,
           exit_state: classify_exit_state(state, exit_status)
         }}
      )
    end

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = maybe_signal(state, "-KILL")
    :ok
  end

  defp provider_ref_from_state(state) do
    %{
      provider: :local,
      run_id: state.run_id,
      workspace_root: state.workspace_root,
      workspace_path: state.workspace_path,
      wrapper_pid: self(),
      os_pid: state.os_pid
    }
  end

  defp describe_state(state) do
    provider_ref_from_state(state)
    |> Map.merge(%{
      status: state.status,
      stop_mode: state.stop_mode,
      command: state.command,
      args: state.args,
      exit_status: state.exit_status
    })
  end

  defp maybe_signal(%__MODULE__{status: :exited}, _signal), do: :ok
  defp maybe_signal(%__MODULE__{os_pid: nil}, _signal), do: :ok

  defp maybe_signal(%__MODULE__{os_pid: os_pid}, signal) do
    case System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:kill_failed, code, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp classify_exit_state(%__MODULE__{stop_mode: :force}, _exit_status), do: :killed
  defp classify_exit_state(%__MODULE__{stop_mode: :graceful}, _exit_status), do: :cancelled
  defp classify_exit_state(_state, exit_status) when exit_status == 0, do: :completed
  defp classify_exit_state(_state, _exit_status), do: :failed
end
