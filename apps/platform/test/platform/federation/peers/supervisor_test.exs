defmodule Platform.Federation.Peers.SupervisorTest do
  @moduledoc """
  Task 01a0d90f stage 4 (ADR 0054 section 4): per-peer supervision.

  The isolation claim is that one peer's crashes, however many, cannot take
  down another peer's connection or the shared DynamicSupervisor. It is
  bounded by the crash-loop test below: more than 10 crashes of X inside
  1 s, with Y's pid and the DynamicSupervisor's pid read before and after.
  """

  # async: false — the connections run under the application's peer
  # supervisor and registry, and the tests flip the federation flag.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Boot
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.Supervisor, as: PeerSupervisor

  defp start_conn!(peer, opts \\ []) do
    {:ok, wrapper} = PeerSupervisor.start_peer(peer, opts)
    cleanup!(peer)
    {wrapper, PeerConnection.whereis(peer.id)}
  end

  defp cleanup!(peer), do: on_exit(fn -> PeerSupervisor.stop_peer(peer.id) end)

  defp dynamic_sup, do: Process.whereis(PeerSupervisor)

  defp active_children, do: DynamicSupervisor.count_children(PeerSupervisor).active

  # The connection's pid once it is alive and not `old`, or :gone when no
  # new connection has appeared within `grace_ms` and no wrapper is alive.
  # The grace matters: between a kill and the restart there is a moment with
  # no registered connection, and "gone" must not be read off that moment,
  # or a regression that restarts X somewhere else would pass as a give-up.
  defp next_pid(peer_id, old, grace_ms \\ 300) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_next_pid(peer_id, old, deadline)
  end

  defp do_next_pid(peer_id, old, deadline) do
    pid = PeerConnection.whereis(peer_id)

    cond do
      is_pid(pid) and pid != old ->
        pid

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(1)
        do_next_pid(peer_id, old, deadline)

      PeerSupervisor.wrapper_pid(peer_id) == nil ->
        :gone

      true ->
        flunk("peer #{peer_id}: wrapper alive but no restarted connection")
    end
  end

  # Kills the peer's connection until it stays gone. Returns the number of
  # kills and the ms from the first kill to the last.
  defp crash_until_gone(peer_id, pid) do
    started = System.monotonic_time(:millisecond)
    crash_until_gone(peer_id, pid, 0, started)
  end

  defp crash_until_gone(peer_id, pid, kills, started) do
    Process.exit(pid, :kill)
    killed_at = System.monotonic_time(:millisecond) - started

    case next_pid(peer_id, pid) do
      :gone -> {kills + 1, killed_at}
      next -> crash_until_gone(peer_id, next, kills + 1, started)
    end
  end

  describe "restart isolation" do
    test "killing X's pid restarts X; Y's pid is unchanged" do
      x = peer_for!(remote_install())
      y = peer_for!(remote_install())
      {x_wrapper, x_pid} = start_conn!(x)
      {y_wrapper, y_pid} = start_conn!(y)
      sup = dynamic_sup()

      Process.exit(x_pid, :kill)
      x_new = next_pid(x.id, x_pid)

      assert is_pid(x_new)
      refute x_new == x_pid
      assert PeerConnection.whereis(y.id) == y_pid
      assert PeerSupervisor.wrapper_pid(x.id) == x_wrapper
      assert PeerSupervisor.wrapper_pid(y.id) == y_wrapper
      assert dynamic_sup() == sup

      IO.puts(
        "[measure] kill-one: X #{inspect(x_pid)} -> #{inspect(x_new)}; " <>
          "Y #{inspect(y_pid)} -> #{inspect(PeerConnection.whereis(y.id))}"
      )
    end

    test "X crashing more than 10 times in 1 s: X's wrapper gives up, Y and the DynamicSupervisor stand" do
      x = peer_for!(remote_install())
      y = peer_for!(remote_install())
      # X's own budget is 10 restarts; the 11th crash exhausts it. The
      # DynamicSupervisor's budget is the default 3 in 5 s, so if X's
      # restarts were counted there it would have died at the 4th.
      {_x_wrapper, x_pid} = start_conn!(x, max_restarts: 10, max_seconds: 5)
      {y_wrapper, y_pid} = start_conn!(y)
      sup = dynamic_sup()

      {kills, elapsed} = crash_until_gone(x.id, x_pid)

      # the isolation claim first, so a regression names it
      assert dynamic_sup() == sup, "the DynamicSupervisor was restarted by X's crashes"
      assert Process.alive?(sup)
      assert PeerConnection.whereis(y.id) == y_pid, "Y's connection was restarted by X's crashes"
      assert Process.alive?(y_pid)
      assert PeerSupervisor.wrapper_pid(y.id) == y_wrapper

      assert kills == 11
      assert elapsed < 1_000, "11 crashes spanned #{elapsed} ms, not inside 1 s"

      assert PeerSupervisor.wrapper_pid(x.id) == nil
      assert PeerConnection.enqueue(x.id, {"test.ping", %{}}) == {:error, :not_running}

      IO.puts(
        "[measure] crash-loop: #{kills} kills of X, first to last #{elapsed} ms; " <>
          "DynamicSupervisor #{inspect(sup)} -> #{inspect(dynamic_sup())}; " <>
          "Y #{inspect(y_pid)} -> #{inspect(PeerConnection.whereis(y.id))}"
      )
    end
  end

  describe "Boot" do
    test "flag off: Boot starts nothing; POSITIVE CONTROL: flag on, it starts the active peer" do
      peer = peer_for!(remote_install())
      cleanup!(peer)
      before = active_children()

      refute Platform.Federation.Peers.Config.enabled?()
      assert Boot.start_link(interval: 3_600_000) == :ignore
      assert Process.whereis(Boot) == nil

      # activation is a no-op too while Boot is not running
      other = peer_for!(remote_install())
      cleanup!(other)

      assert active_children() == before
      assert PeerConnection.whereis(peer.id) == nil
      assert PeerConnection.whereis(other.id) == nil

      enable_federation!()
      start_supervised!({Boot, interval: 3_600_000})
      :ok = Boot.rescan()

      assert is_pid(PeerConnection.whereis(peer.id))
      assert is_pid(PeerConnection.whereis(other.id))
      assert active_children() == before + 2
    end

    test "with Boot running, activating a peer starts its connection" do
      enable_federation!()
      start_supervised!({Boot, interval: 3_600_000})

      remote = remote_install()

      {:ok, pending} =
        Peers.create_peer(%{
          peer_install_id: remote.install_id,
          base_url: remote.base_url,
          status: "pending_outbound",
          public_keys: [%{kid: remote.kid, public_key: remote.b64}]
        })

      cleanup!(pending)
      :ok = Boot.rescan()
      assert PeerConnection.whereis(pending.id) == nil

      {:ok, _active} = Peers.activate(pending)
      assert assert_eventually(fn -> PeerConnection.whereis(pending.id) end)
    end

    test "a wrapper that gives up is logged by peer_id and restarted by the next re-scan" do
      enable_federation!()
      start_supervised!({Boot, interval: 3_600_000, connection_opts: [max_restarts: 1]})

      x = peer_for!(remote_install())
      y = peer_for!(remote_install())
      cleanup!(x)
      cleanup!(y)
      :ok = Boot.rescan()

      x_pid = assert_eventually(fn -> PeerConnection.whereis(x.id) end)
      y_pid = assert_eventually(fn -> PeerConnection.whereis(y.id) end)

      log =
        capture_log(fn ->
          assert {2, _ms} = crash_until_gone(x.id, x_pid)
          # wait until Boot has processed the wrapper's DOWN
          assert_eventually(fn -> MapSet.member?(:sys.get_state(Boot).offline, x.id) end)
          :ok = Boot.rescan()
        end)

      assert log =~ "peer connection offline peer_id=#{x.id}"
      assert log =~ "restarting offline peer connection peer_id=#{x.id}"
      refute log =~ "peer_id=#{y.id}"

      assert is_pid(PeerConnection.whereis(x.id))
      refute PeerConnection.whereis(x.id) == x_pid
      assert PeerConnection.whereis(y.id) == y_pid
    end
  end

  describe "revoke" do
    test "revoking X terminates only X's process and drops its queue" do
      x = peer_for!(remote_install())
      y = peer_for!(remote_install())
      {x_wrapper, x_pid} = start_conn!(x)
      {y_wrapper, y_pid} = start_conn!(y)
      x_ref = Process.monitor(x_pid)

      # control: X is reachable immediately before the revoke
      assert {:ok, %{breaker: :closed}} = PeerConnection.status(x.id)

      {:ok, revoked} = Peers.revoke(x, notify: false)
      assert revoked.status == "revoked"

      assert_receive {:DOWN, ^x_ref, :process, ^x_pid, _}, 1_000
      refute Process.alive?(x_wrapper)
      assert PeerSupervisor.wrapper_pid(x.id) == nil
      assert PeerConnection.enqueue(x.id, {"test.ping", %{}}) == {:error, :not_running}

      assert PeerConnection.whereis(y.id) == y_pid
      assert PeerSupervisor.wrapper_pid(y.id) == y_wrapper
    end

    test "a revoke by the peer stops that peer's connection too" do
      x = peer_for!(remote_install())
      y = peer_for!(remote_install())
      {_x_wrapper, x_pid} = start_conn!(x)
      {_y_wrapper, y_pid} = start_conn!(y)
      x_ref = Process.monitor(x_pid)

      {:ok, _} = Peers.mark_revoked(x, :peer)

      assert_receive {:DOWN, ^x_ref, :process, ^x_pid, _}, 1_000
      assert PeerConnection.whereis(y.id) == y_pid
    end
  end
end
