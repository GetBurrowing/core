defmodule Platform.Federation.Peers.Supervisor do
  @moduledoc """
  Supervises one `Platform.Federation.Peers.PeerConnection` per active peer
  (task 01a0d90f stage 4, ADR 0054 section 4). The DynamicSupervisor +
  Registry shape of `Platform.Agents.RuntimeSupervisor`, with one extra
  level, and the extra level is the point of the module.

  ## Why each peer has its own wrapper

  A supervisor's restart intensity (the DynamicSupervisor default is 3
  restarts in 5 s) is counted across ALL of its children. If connections sat
  directly under this DynamicSupervisor, one peer that crash-looped would
  exhaust the budget, the DynamicSupervisor would exit, and every sibling
  connection would die with it.

  So each peer runs under its own small `Supervisor`
  (`Platform.Federation.Peers.Supervisor.PeerWrapper`) with its own
  intensity (default 5 restarts in 10 s, `:max_restarts` / `:max_seconds`),
  and that wrapper is started `restart: :temporary` here. A temporary child
  is never restarted, so a wrapper that gives up adds nothing to this
  supervisor's count. The failure stays inside one peer.

  A peer whose wrapper gave up stays offline until `Platform.Federation.Peers.Boot`
  re-scans (every 60 s) and starts it again; Boot logs both events with the
  peer_id.

  The wrapper is registered under `{:peer_sup, peer_id}` and the connection
  under `{:peer, peer_id}`, both in `Platform.Federation.Peers.Registry`.
  """

  use DynamicSupervisor

  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerConnection

  @registry Platform.Federation.Peers.Registry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts the connection for `peer` under its own wrapper. Idempotent: an
  already-running peer returns the existing wrapper. `opts` pass to the
  wrapper (`:max_restarts`, `:max_seconds`) and to the connection.
  """
  @spec start_peer(Peer.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_peer(%Peer{} = peer, opts \\ []) do
    spec = %{
      id: {__MODULE__.PeerWrapper, peer.id},
      start: {__MODULE__.PeerWrapper, :start_link, [{peer, opts}]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a peer's wrapper and connection. The queue goes with the process.
  Returns `:ok` whether or not it was running.
  """
  @spec stop_peer(String.t()) :: :ok
  def stop_peer(peer_id) do
    with pid when is_pid(pid) <- wrapper_pid(peer_id),
         sup when is_pid(sup) <- Process.whereis(__MODULE__) do
      _ = DynamicSupervisor.terminate_child(sup, pid)
    end

    :ok
  end

  @doc "The pid of a peer's live wrapper supervisor, or nil (see `PeerConnection.whereis/1`)."
  @spec wrapper_pid(String.t()) :: pid() | nil
  def wrapper_pid(peer_id) do
    case Registry.lookup(@registry, {:peer_sup, peer_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "The pid of a peer's connection, or nil."
  @spec connection_pid(String.t()) :: pid() | nil
  defdelegate connection_pid(peer_id), to: PeerConnection, as: :whereis

  defmodule PeerWrapper do
    @moduledoc """
    One peer's own supervisor, so its restart intensity is counted for that
    peer alone. See `Platform.Federation.Peers.Supervisor`.
    """

    use Supervisor

    alias Platform.Federation.Peers.PeerConnection

    @max_restarts 5
    @max_seconds 10

    def start_link({%Peer{} = peer, opts}) do
      Supervisor.start_link(__MODULE__, {peer, opts},
        name: {:via, Registry, {Platform.Federation.Peers.Registry, {:peer_sup, peer.id}}}
      )
    end

    @impl true
    def init({peer, opts}) do
      {sup_opts, conn_opts} = Keyword.split(opts, [:max_restarts, :max_seconds])

      Supervisor.init([{PeerConnection, {peer, conn_opts}}],
        strategy: :one_for_one,
        max_restarts: Keyword.get(sup_opts, :max_restarts, @max_restarts),
        max_seconds: Keyword.get(sup_opts, :max_seconds, @max_seconds)
      )
    end
  end
end
