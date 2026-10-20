defmodule Platform.Role.Peer do
  @moduledoc """
  Reads and calls that a web node sends to its full peer (task 01a155a6
  stage 4).

  Some state a web node's request path reads lives in a process only the
  full node runs, or in a web-classified process whose writers are on the
  full node (runtimes connect to prod, so `RuntimePresence` there is the one
  that knows who is online). On a web node those reads would answer from an
  empty local copy, or exit `:noproc`.

  A web node is "remote" when its role is `:web` AND a cluster peer is
  configured (`PLATFORM_CLUSTER_PEER`, see `Platform.Role.PeerLink`). Then:

    * `server/1` gives `{name, peer}`, so a `GenServer.call/3` goes to the
      peer's process;
    * `read/5` runs `apply(module, fun, args)` on the peer through `:erpc`
      with a short timeout (`@timeout_ms`, 2s) and answers `default` if the
      peer is unreachable, slow or raises. A web node keeps serving while
      its peer is down; it shows the default (nobody online, no active agent)
      rather than crashing the LiveView.

  On a full node, or a web node with no peer, `remote?/0` is false: `server/1`
  is the local name, and `read/5` answers `default` without calling anything,
  so callers decide what the local answer is.

  `Platform.Role` lists every call site that goes through here.

  ## Injection

  `config :platform, :role_peer_rpc` replaces `:erpc.call/5` (same arity), so
  a test can observe what would be sent to the peer without a second node.
  """

  require Logger

  @timeout_ms 2_000

  @doc "The configured peer node when this is a web node with a peer, else nil."
  @spec peer() :: node() | nil
  def peer do
    case {Platform.Role.role(), Application.get_env(:platform, :cluster_peer)} do
      {:web, peer} when is_atom(peer) and not is_nil(peer) -> peer
      _ -> nil
    end
  end

  @doc "True when reads and calls for full-node state go to the peer."
  @spec remote?() :: boolean()
  def remote?, do: not is_nil(peer())

  @doc "`{name, peer}` on a remote web node, else `name`."
  @spec server(atom()) :: GenServer.server()
  def server(name) when is_atom(name) do
    case peer() do
      nil -> name
      peer -> {name, peer}
    end
  end

  @doc """
  Run `apply(module, fun, args)` on the peer when `remote?/0`, answering
  `default` when there is no peer to ask or the call fails within
  `timeout_ms`. Never raises or exits.
  """
  @spec read(module(), atom(), list(), term(), timeout()) :: term()
  def read(module, fun, args, default, timeout_ms \\ @timeout_ms) do
    case peer() do
      nil ->
        default

      peer ->
        try do
          rpc().(peer, module, fun, args, timeout_ms)
        catch
          kind, reason ->
            Logger.warning(
              "[Role.Peer] #{inspect(module)}.#{fun}/#{length(args)} on #{peer} " <>
                "failed (#{kind}: #{inspect(reason, limit: 5)}); answering the default"
            )

            default
        end
    end
  end

  defp rpc, do: Application.get_env(:platform, :role_peer_rpc, &:erpc.call/5)
end
