defmodule Platform.Federation.Peers.Boot do
  @moduledoc """
  Starts a `Platform.Federation.Peers.PeerConnection` for every active peer
  (task 01a0d90f stage 4, ADR 0054 section 4): at boot, whenever a peer is
  activated (`peer_activated/1`, called by `Peers.activate/2`), and on a
  re-scan every 60 s (`:interval`).

  A re-scan also calls `PeerConnection.refresh/1` on every connection that
  is already running, so it re-reads its shared spaces. That is a safety
  net only: every path that creates a shared-space row refreshes the
  connection itself, at once (task 01a0d90f stage 6).

  The re-scan is what brings back a peer whose wrapper gave up after
  crash-looping (see `Platform.Federation.Peers.Supervisor`). Boot monitors
  every wrapper it starts and logs, by peer_id, when one goes down and when
  a re-scan restarts it.

  ## Flag off: nothing starts

  When `Platform.Federation.Peers.Config.enabled?/0` is false at start,
  `start_link/1` returns `:ignore`: there is no Boot process, no scan, and
  `peer_activated/1` is a no-op, so no connection is ever started. Turning
  federation on is a restart, as for every other env-read flag.
  """

  use GenServer

  require Logger

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.Supervisor, as: PeerSupervisor

  @interval_ms 60_000

  @doc """
  Options: `:name` (default this module), `:interval` (ms between
  re-scans), `:connection_opts` (passed to every started peer).
  """
  def start_link(opts \\ []) do
    if Config.enabled?() do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "Starts `peer`'s connection now, if Boot is running. Always `:ok`."
  @spec peer_activated(Peer.t(), GenServer.server()) :: :ok
  def peer_activated(%Peer{status: "active"} = peer, server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:start, peer})
    :ok
  end

  @doc "Runs a scan now and returns once it has finished (tests)."
  @spec rescan(GenServer.server()) :: :ok
  def rescan(server \\ __MODULE__), do: GenServer.call(server, :scan)

  @impl true
  def init(opts) do
    send(self(), :scan)

    {:ok,
     %{
       interval: Keyword.get(opts, :interval, @interval_ms),
       connection_opts: Keyword.get(opts, :connection_opts, []),
       monitors: %{},
       offline: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:scan, state) do
    state = scan(state)
    Process.send_after(self(), :scan, state.interval)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {peer_id, monitors} ->
        Logger.warning(
          "[federation] peer connection offline peer_id=#{peer_id} " <>
            "reason=#{inspect(reason)}; restarted by the next re-scan if still active"
        )

        {:noreply, %{state | monitors: monitors, offline: MapSet.put(state.offline, peer_id)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:start, peer}, state), do: {:noreply, start(peer, state)}

  @impl true
  def handle_call(:scan, _from, state), do: {:reply, :ok, scan(state)}

  defp scan(state) do
    peers =
      try do
        Peers.list_peers(status: "active")
      rescue
        error ->
          Logger.warning("[federation] peer boot scan failed: #{Exception.message(error)}")
          []
      end

    Enum.reduce(peers, state, &start/2)
  end

  defp start(%Peer{} = peer, state) do
    if PeerSupervisor.wrapper_pid(peer.id) do
      # Safety net (task 01a0d90f stage 6): a running connection re-reads
      # its shared spaces, so a row whose writer did not call
      # `PeerConnection.refresh/1` is picked up within one interval.
      PeerConnection.refresh(peer.id)
      state
    else
      if MapSet.member?(state.offline, peer.id) do
        Logger.warning("[federation] restarting offline peer connection peer_id=#{peer.id}")
      end

      case PeerSupervisor.start_peer(peer, state.connection_opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          %{
            state
            | monitors: Map.put(state.monitors, ref, peer.id),
              offline: MapSet.delete(state.offline, peer.id)
          }

        {:error, reason} ->
          Logger.warning(
            "[federation] peer connection did not start peer_id=#{peer.id} " <>
              "reason=#{inspect(reason)}"
          )

          state
      end
    end
  end
end
