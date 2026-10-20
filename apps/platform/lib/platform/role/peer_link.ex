defmodule Platform.Role.PeerLink do
  @moduledoc """
  Joins a web node to its full peer over distributed Erlang (task 01a155a6
  stage 3). WEB only: `Platform.Application.children/2` adds it under `:web`,
  directly after `Phoenix.PubSub`, so it is absent from the full list by
  construction.

  The peer is `config :platform, :cluster_peer`, which `config/runtime.exs`
  reads from `PLATFORM_CLUSTER_PEER` (a node name such as
  `platform@core-platform`). Unset gives `:ignore`: the web node serves, alone.

  `DNSCluster` stays background. Joining a cluster is this module's explicit
  job, never a side effect of `DNS_CLUSTER_QUERY` being set.

  ## Behaviour

    * `Node.connect/1` at start, then every `:interval_ms` (5s) until it
      succeeds;
    * `:net_kernel.monitor_nodes/1`, so a `:nodedown` for the peer starts the
      retry loop again;
    * every state change (connected, disconnected, a failed attempt after a
      success) is logged once, not once per attempt;
    * `connected?/0` answers from the process, and is `false` when the link is
      not running.

  While disconnected the web node keeps serving, but nothing it relays reaches
  the full node: see the limitation in `Platform.Role.Relay`.

  ## Trust

  The peer shares this node's cookie. Anyone who can run code on a web node
  can run code on its full peer. See `Platform.Role`.

  ## Injection

  `:peer`, `:connect` (`Node.connect/1`'s shape), `:monitor`
  (`:net_kernel.monitor_nodes/1`'s shape), `:interval_ms` and `:name`, so the
  reconnect loop is testable on a node that is not distributed.
  """

  use GenServer

  require Logger

  @interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "True when the link is running and its peer is connected."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__) do
    GenServer.call(server, :connected?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    case Keyword.get_lazy(opts, :peer, fn -> Application.get_env(:platform, :cluster_peer) end) do
      nil ->
        :ignore

      peer when is_atom(peer) ->
        monitor = Keyword.get(opts, :monitor, &:net_kernel.monitor_nodes/1)

        monitor_result =
          try do
            monitor.(true)
          catch
            kind, reason -> {kind, reason}
          end

        if monitor_result != :ok do
          Logger.warning(
            "[Role.PeerLink] node monitoring unavailable (#{inspect(monitor_result)}); " <>
              "a nodedown for #{peer} will not be seen"
          )
        end

        state = %{
          peer: peer,
          connect: Keyword.get(opts, :connect, &Node.connect/1),
          interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
          connected?: false,
          logged: nil
        }

        send(self(), :connect)
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected?, state}

  @impl true
  def handle_info(:connect, %{connected?: true} = state), do: {:noreply, state}

  def handle_info(:connect, state) do
    case state.connect.(state.peer) do
      true ->
        {:noreply, state |> log(:connected) |> Map.put(:connected?, true)}

      other ->
        Process.send_after(self(), :connect, state.interval_ms)
        {:noreply, log(state, {:failed, other})}
    end
  end

  def handle_info({:nodedown, peer}, %{peer: peer} = state) do
    send(self(), :connect)
    {:noreply, state |> log(:nodedown) |> Map.put(:connected?, false)}
  end

  def handle_info({:nodeup, peer}, %{peer: peer} = state) do
    {:noreply, state |> log(:connected) |> Map.put(:connected?, true)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One line per change of state, so a peer that is down for an hour logs
  # once rather than 720 times.
  defp log(%{logged: same} = state, same), do: state

  defp log(state, :connected) do
    Logger.info("[Role.PeerLink] connected to #{state.peer}")
    %{state | logged: :connected}
  end

  defp log(state, :nodedown) do
    Logger.warning(
      "[Role.PeerLink] #{state.peer} is down; retrying every #{state.interval_ms}ms. " <>
        "Messages posted here are not routed to agents until it is back."
    )

    %{state | logged: :nodedown}
  end

  defp log(%{logged: {:failed, _}} = state, {:failed, _}), do: state

  defp log(state, {:failed, result} = failed) do
    Logger.warning(
      "[Role.PeerLink] cannot connect to #{state.peer} (#{inspect(result)}); " <>
        "retrying every #{state.interval_ms}ms"
    )

    %{state | logged: failed}
  end
end
