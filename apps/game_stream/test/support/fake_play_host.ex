defmodule PlatformWeb.FakePlayHost do
  @moduledoc """
  Test support (task 01a1a34c stage 3): a stand-in for a play host that
  declares `game_stream_per_slot`, so every per-slot behaviour can be checked
  without a real host. It is a channel-joined process in the shape of the
  existing runtime-channel tests: the test process owns the joined socket,
  receives the host's `play_slots` pushes, and answers them with
  `play_peer_view` by the rule in `Platform.GameStream.Protocol`: a peer's
  video follows its LOWEST slot, a peer with no slot gets `shared`.

  It never calls git, never reads the network, and holds no runtime
  identifier: `ctx` carries the runtime and token the test registered.
  """

  import Phoenix.ChannelTest

  @endpoint PlatformWeb.Endpoint

  @default_features ["game_stream_host", "game_stream_multi", "game_stream_per_slot"]

  @doc "Joins `runtime:<id>` declaring `features`; returns the channel socket."
  def join(ctx, features \\ @default_features) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => ctx.runtime.runtime_id,
        "token" => ctx.token
      })

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
        "client_info" => %{"product" => "play_host", "features" => features}
      })

    socket
  end

  @doc "Pushes `play_session_status live` for the session."
  def drive(socket, session_id) do
    push(socket, "play_session_status", %{"session_id" => session_id, "state" => "live"})
  end

  @doc """
  Answers a `play_slots` payload (atom- or string-keyed): one `play_peer_view`
  per peer. Lowest slot -> `slot`, no slots -> `shared`.
  """
  def answer_slots(socket, payload) do
    session_id = fetch(payload, :session_id)

    for {peer_id, slots} <- fetch(payload, :peers) do
      report(socket, session_id, peer_id, slots)
    end

    :ok
  end

  @doc """
  Resumes the session on a (re)joined socket: pushes the `resume: true` status
  then re-reports every peer. `peers` is the `play_slots` `peers` map
  (`%{peer_id => %{src => slot}}`) or a plain list of peer ids (all reported
  as holding no slot).
  """
  def resume(socket, session_id, peers) do
    peers = if is_list(peers), do: Map.new(peers, &{&1, %{}}), else: peers

    push(socket, "play_session_status", %{
      "session_id" => session_id,
      "state" => "live",
      "detail" => "Resumed",
      "resume" => true,
      "peers" => Map.keys(peers)
    })

    for {peer_id, slots} <- peers, do: report(socket, session_id, peer_id, slots)
    :ok
  end

  @doc "Reports one peer's view by the lowest-slot rule."
  def report(socket, session_id, peer_id, slots) do
    frame =
      case slots |> Map.values() |> Enum.min(fn -> nil end) do
        nil -> %{"view" => "shared"}
        slot -> %{"view" => "slot", "slot" => slot}
      end

    push(
      socket,
      "play_peer_view",
      Map.merge(%{"session_id" => session_id, "peer_id" => peer_id}, frame)
    )
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.fetch!(map, Atom.to_string(key))
end
