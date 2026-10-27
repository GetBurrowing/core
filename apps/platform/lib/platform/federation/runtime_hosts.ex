defmodule Platform.Federation.RuntimeHosts do
  @moduledoc """
  The burrow-cli hosts currently joined on `runtime_host:<runtime_id>`
  (`PlatformWeb.RuntimeHostChannel`), and the one way core asks them to do
  something.

  `request/4` pushes an allow-listed event to the newest joined host and waits
  for its reply by ref. No host, a dead host, or no answer in time is
  `{:error, :host_offline}`. Anything outside `ops/0` is
  `{:error, :event_not_allowed}` and never leaves core.
  """

  @registry Platform.Federation.RuntimeHostRegistry
  @ops ~w(file.list file.read file.write secret.set session.restart session.tools)
  @default_timeout 5_000

  @doc "Events core may send a host."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "True when `event` is one core may send."
  def op_allowed?(event), do: event in @ops

  @doc false
  def register(runtime_id, hello) when is_binary(runtime_id) and is_map(hello) do
    {:ok, _} =
      Registry.register(
        @registry,
        runtime_id,
        Map.put(hello, :joined_at, System.monotonic_time())
      )

    :ok
  end

  @doc """
  The newest joined host for `runtime_id`: `%{pid, hello}` or nil. `hello` is
  the sanitised hello payload (`harness`, `cli_version`, `capabilities`,
  `resumes`, `config_opt_in`).
  """
  @spec lookup(String.t()) :: %{pid: pid(), hello: map()} | nil
  def lookup(runtime_id) when is_binary(runtime_id) do
    @registry
    |> Registry.lookup(runtime_id)
    |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end)
    |> Enum.max_by(fn {_, hello} -> hello.joined_at end, fn -> nil end)
    |> case do
      nil -> nil
      {pid, hello} -> %{pid: pid, hello: Map.delete(hello, :joined_at)}
    end
  end

  def lookup(_), do: nil

  @doc "Ask the host for `event` and wait for the answer."
  @spec request(String.t(), String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, :host_offline | :event_not_allowed | {:host_error, String.t()}}
  def request(runtime_id, event, payload, timeout \\ @default_timeout) do
    with true <- op_allowed?(event) || {:error, :event_not_allowed},
         %{pid: pid} <- lookup(runtime_id) || {:error, :host_offline} do
      ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      mon = Process.monitor(pid)
      send(pid, {:host_request, self(), ref, event, payload})

      receive do
        {:host_reply, ^ref, result} ->
          Process.demonitor(mon, [:flush])
          result

        {:DOWN, ^mon, :process, ^pid, _} ->
          {:error, :host_offline}
      after
        timeout ->
          Process.demonitor(mon, [:flush])
          {:error, :host_offline}
      end
    else
      {:error, _} = error -> error
    end
  end
end
