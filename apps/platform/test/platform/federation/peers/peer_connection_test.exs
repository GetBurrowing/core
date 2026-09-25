defmodule Platform.Federation.Peers.PeerConnectionTest.PeerPlug do
  @moduledoc """
  A real inbox for the slow-peer test. `mode: :slow` holds every request
  past the client's receive deadline; `mode: :fast` answers at once and tells
  the test when each request arrived. A `Req.Test` stub runs in the calling
  process and never reaches the adapter, so it cannot exercise the client's
  receive deadline; this endpoint is reached over a loopback socket.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{mode: :slow, sleep_ms: sleep_ms}) do
    Process.sleep(sleep_ms)
    send_resp(conn, 200, ~s({"ok":true}))
  end

  def call(conn, %{mode: :fast, test: test}) do
    send(test, {:fast_inbox, System.monotonic_time(:millisecond)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
  end
end

defmodule Platform.Federation.Peers.PeerConnectionTest do
  @moduledoc """
  Task 01a0d90f stage 4 (ADR 0054 section 4): one peer's outbound
  connection — queue, backoff, breaker, and the promise that peer
  misbehaviour is a value and never a crash.
  """

  # async: false — flips global app env, and the connections run under the
  # application's peer supervisor (shared sandbox).
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.Supervisor, as: PeerSupervisor
  alias Platform.Vault

  @fast [base_backoff_ms: 10, max_backoff_ms: 40]

  setup do
    enable_federation!(allow_http: true)
    me = InstallIdentity.ensure!()
    %{me: me}
  end

  defp start_conn!(peer, opts \\ @fast) do
    {:ok, _wrapper} = PeerSupervisor.start_peer(peer, opts)
    on_exit(fn -> PeerSupervisor.stop_peer(peer.id) end)
    pid = PeerConnection.whereis(peer.id)
    assert is_pid(pid)
    pid
  end

  # Req.Test resolves a stub through `$callers`; each send runs in a sender
  # whose callers begin with the connection, so allowing the connection
  # covers every send it makes.
  defp stub!(fun, pid) do
    Req.Test.stub(Client, fun)
    Req.Test.allow(Client, self(), pid)
  end

  defp forward_and_answer(status, body) do
    test_pid = self()

    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:inbox, raw})
      Plug.Conn.send_resp(conn, status, body)
    end
  end

  defp status!(peer) do
    {:ok, status} = PeerConnection.status(peer.id)
    status
  end

  defp attach_telemetry! do
    test_pid = self()
    id = "peer-connection-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:platform, :federation, :peer, :send], [:platform, :federation, :peer, :breaker]],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "delivery" do
    test "a queued item is signed, sent once through the client, and counted" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)
      stub!(forward_and_answer(200, ~s({"ok":true})), pid)

      assert :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"n" => 1}})

      assert_receive {:inbox, raw}, 2_000
      assert %{"type" => "test.ping", "payload" => %{"n" => 1}} = Jason.decode!(raw)

      status = assert_eventually(fn -> match?(%{sent: 1}, status!(peer)) && status!(peer) end)
      assert status.breaker == :closed
      assert status.queue_len == 0
      assert status.last_error == nil
    end

    test "enqueue returns immediately, even while a send is outstanding" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)

      stub!(
        fn conn ->
          Process.sleep(500)
          Plug.Conn.send_resp(conn, 200, ~s({"ok":true}))
        end,
        pid
      )

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})
      assert_eventually(fn -> status!(peer).in_flight end)

      {micros, :ok} = :timer.tc(fn -> PeerConnection.enqueue(peer.id, {"test.ping", %{}}) end)

      {status_micros, {:ok, %{in_flight: true}}} =
        :timer.tc(fn -> PeerConnection.status(peer.id) end)

      assert micros < 50_000
      assert status_micros < 50_000
    end

    test "a retried item keeps its envelope id and gets a fresh nonce" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)
      test_pid = self()
      counter = :counters.new(1, [])

      stub!(
        fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:inbox, raw})
          :counters.add(counter, 1, 1)
          status = if :counters.get(counter, 1) == 1, do: 503, else: 200
          Plug.Conn.send_resp(conn, status, ~s({"ok":true}))
        end,
        pid
      )

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      assert_receive {:inbox, first}, 2_000
      assert_receive {:inbox, second}, 2_000

      first = Jason.decode!(first)
      second = Jason.decode!(second)
      assert first["id"] == second["id"]
      refute first["nonce"] == second["nonce"]

      assert_eventually(fn -> status!(peer).sent == 1 end)
    end
  end

  describe "peer misbehaviour is a value" do
    test "a 500 with a non-JSON body is a failure and the process survives" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)
      stub!(forward_and_answer(500, "<html>\x00\xff not json"), pid)

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      status = assert_eventually(fn -> (s = status!(peer)) && s.failed >= 1 && s end)
      assert status.last_error == {:http_status, 500}
      assert status.queue_len + if(status.in_flight, do: 1, else: 0) == 1
      assert PeerConnection.whereis(peer.id) == pid
      assert Process.alive?(pid)
    end

    test "a 2xx that is not an inbox acknowledgement is a failure the breaker counts" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)
      stub!(forward_and_answer(200, "<html>\x00\xff not json"), pid)

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      status = assert_eventually(fn -> (s = status!(peer)) && s.failed >= 1 && s end)
      assert status.last_error == :invalid_answer
      assert status.consecutive_failures >= 1
      assert status.sent == 0
      assert Process.alive?(pid)

      # A parseable body that is not the inbox's `{"ok": true}` is no better.
      stub!(forward_and_answer(200, ~s([1,2])), pid)

      assert_eventually(fn -> status!(peer).failed >= 2 end)
      assert status!(peer).sent == 0

      # POSITIVE CONTROL: the real acknowledgement is counted as sent.
      stub!(forward_and_answer(200, ~s({"ok":true})), pid)
      assert assert_eventually(fn -> status!(peer).sent == 1 end)
    end

    test "a transport error and a raising stub are failures, never crashes" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer)

      stub!(&Req.Test.transport_error(&1, :econnrefused), pid)
      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      assert_eventually(fn ->
        status!(peer).last_error == {:transport, :econnrefused}
      end)

      stub!(fn _conn -> raise "peer stub exploded" end, pid)

      capture_log(fn ->
        assert_eventually(fn -> status!(peer).last_error != {:transport, :econnrefused} end)
      end)

      assert PeerConnection.whereis(peer.id) == pid
      assert Process.alive?(pid)
    end
  end

  describe "circuit breaker" do
    test "opens after 5 consecutive failures, probes half-open, closes on success" do
      attach_telemetry!()
      peer = peer_for!(remote_install())
      pid = start_conn!(peer, base_backoff_ms: 50, max_backoff_ms: 50)
      healthy = :atomics.new(1, [])

      stub!(
        fn conn ->
          if :atomics.get(healthy, 1) == 1,
            do: Plug.Conn.send_resp(conn, 200, ~s({"ok":true})),
            else: Plug.Conn.send_resp(conn, 502, "{}")
        end,
        pid
      )

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      # Collect this peer's events IN ORDER until the half-open probe has
      # failed once, then let the peer recover.
      first = collect_events(peer.id, &(&1 == {:breaker, :open}), 2)

      assert first == [
               {:send, :error},
               {:send, :error},
               {:send, :error},
               {:send, :error},
               {:send, :error},
               {:breaker, :open},
               {:breaker, :half_open},
               {:send, :error},
               {:breaker, :open}
             ]

      :atomics.put(healthy, 1, 1)

      # One more failed probe may land before the flip; the recovery itself
      # is always half_open -> ok -> closed.
      recovery = collect_events(peer.id, &(&1 == {:breaker, :closed}), 1)

      assert Enum.take(recovery, -3) == [
               {:breaker, :half_open},
               {:send, :ok},
               {:breaker, :closed}
             ]

      status = status!(peer)
      assert status.breaker == :closed
      assert status.consecutive_failures == 0
      assert status.sent == 1
    end

    test "backoff grows between attempts and is capped" do
      peer = peer_for!(remote_install())
      pid = start_conn!(peer, base_backoff_ms: 10, max_backoff_ms: 80)
      stub!(forward_and_answer(503, "{}"), pid)

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{}})

      backoffs =
        for _ <- 1..6 do
          assert_receive {:inbox, _}, 2_000
          status!(peer).backoff_ms
        end

      assert List.last(backoffs) == 80
      assert Enum.max(backoffs) == 80
      assert hd(backoffs) < 80
    end
  end

  describe "queue bound" do
    test "overflow drops the oldest and sets resync_needed" do
      peer = peer_for!(remote_install())
      # every send fails and the next attempt is a minute away, so enqueued
      # items stay queued
      pid = start_conn!(peer, queue_cap: 3, base_backoff_ms: 60_000, max_backoff_ms: 60_000)
      stub!(forward_and_answer(503, "{}"), pid)

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"n" => 0}})
      assert_receive {:inbox, _}, 2_000
      assert_eventually(fn -> status!(peer).failed == 1 end)

      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"n" => 1}})
      :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"n" => 2}})

      # control: exactly at the cap, nothing dropped yet
      assert %{queue_len: 3, resync_needed: false} = status!(peer)

      log =
        capture_log(fn ->
          :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"n" => 3}})
          assert %{queue_len: 3, resync_needed: true} = status!(peer)
        end)

      assert log =~ "peer queue overflow peer_id=#{peer.id}"
    end
  end

  describe "the slow-peer isolation" do
    setup do
      # No Req.Test plug: these requests go through the real adapter, so the
      # receive deadline that times X out is the client's own.
      put_env_restored(:peer_federation_req_options, [])
      put_env_restored(:peer_federation_timeouts, receive: 200)

      slow_port = free_port()
      fast_port = free_port()

      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__.PeerPlug, %{mode: :slow, sleep_ms: 1_000}},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: slow_port,
           startup_log: false},
          id: :slow_peer
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__.PeerPlug, %{mode: :fast, test: self()}},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: fast_port,
           startup_log: false},
          id: :fast_peer
        )
      )

      x = peer_for!(remote_install(%{base_url: "http://127.0.0.1:#{slow_port}"}))
      y = peer_for!(remote_install(%{base_url: "http://127.0.0.1:#{fast_port}"}))
      %{x: x, y: y}
    end

    test "a slow peer opens its own breaker while the other peer's sends complete in time",
         %{x: x, y: y} do
      x_pid = start_conn!(x)
      y_pid = start_conn!(y)

      :ok = PeerConnection.enqueue(x.id, {"test.ping", %{}})
      assert_eventually(fn -> status!(x).in_flight end)

      # Y's latency, measured while X is held by the slow peer
      latencies =
        for n <- 1..3 do
          assert %{in_flight: true} = status!(x)
          started = System.monotonic_time(:millisecond)
          :ok = PeerConnection.enqueue(y.id, {"test.ping", %{"n" => n}})
          assert_receive {:fast_inbox, arrived}, 1_000
          arrived - started
        end

      assert Enum.all?(latencies, &(&1 < Client.receive_timeout())),
             "Y latencies #{inspect(latencies)} ms vs receive_timeout #{Client.receive_timeout()} ms"

      # X is timed out by the adapter deadline (a transport timeout) and,
      # after 5 of them, its breaker opens.
      status = assert_eventually(fn -> (s = status!(x)) && s.breaker == :open && s end, 5_000)
      assert status.last_error == {:transport, :timeout}

      assert status!(y).breaker == :closed
      assert status!(y).sent == 3
      assert PeerConnection.whereis(x.id) == x_pid
      assert PeerConnection.whereis(y.id) == y_pid

      IO.puts(
        "[measure] Y send latency while X in flight: #{inspect(latencies)} ms " <>
          "(receive_timeout #{Client.receive_timeout()} ms); X last_error=#{inspect(status.last_error)}"
      )
    end
  end

  describe "no payloads or key material leave the process" do
    test "status, telemetry, sys status and logs carry neither", %{me: me} do
      attach_telemetry!()
      peer = peer_for!(remote_install())
      pid = start_conn!(peer, base_backoff_ms: 60_000, max_backoff_ms: 60_000)
      stub!(forward_and_answer(500, ~s({"error":"nope"})), pid)

      sentinel = "payload-sentinel-" <> Base.encode16(:crypto.strong_rand_bytes(8))

      log =
        capture_log(fn ->
          :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"body" => sentinel}})
          :ok = PeerConnection.enqueue(peer.id, {"test.ping", %{"body" => sentinel}})
          assert_receive {:inbox, raw}, 2_000
          # POSITIVE CONTROL: the sentinel is in what was sent, so its absence
          # below is not an artifact of it never having been queued
          assert raw =~ sentinel
          assert_eventually(fn -> status!(peer).failed == 1 end)
          assert {:error, :unknown_call} = GenServer.call(pid, :not_a_real_call)
        end)

      {:ok, priv} = Vault.get(InstallIdentity.vault_slug(me.kid), accessor: {:system, nil})
      assert byte_size(priv) == 32

      status = status!(peer)
      assert status.queue_len == 2

      sys = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      assert sys =~ "queue_len"

      telemetry =
        for {:telemetry, _event, _m, metadata} <- drain_messages() do
          assert metadata |> Map.keys() |> Enum.sort() == [:outcome, :peer_id]
          inspect(metadata)
        end

      assert telemetry != []

      for haystack <- [inspect(status), sys, log | telemetry] do
        refute haystack =~ sentinel
        refute_key(haystack, priv)
      end
    end
  end

  # Receives this peer's telemetry events, in order, until `stop?` has
  # matched `times` of them. Returns `[{:send | :breaker, outcome}]`.
  defp collect_events(peer_id, stop?, times, acc \\ []) do
    receive do
      {:telemetry, [:platform, :federation, :peer, kind], _m, %{peer_id: ^peer_id} = meta} ->
        event = {kind, meta.outcome}
        acc = [event | acc]
        times = if stop?.(event), do: times - 1, else: times
        if times == 0, do: Enum.reverse(acc), else: collect_events(peer_id, stop?, times, acc)
    after
      3_000 -> flunk("telemetry stalled; so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  defp drain_messages(acc \\ []) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp refute_key(haystack, priv) do
    for form <- [
          priv,
          Base.encode64(priv),
          Base.encode64(priv, padding: false),
          Base.url_encode64(priv),
          Base.url_encode64(priv, padding: false),
          Base.encode16(priv, case: :lower),
          Base.encode16(priv, case: :upper),
          inspect(priv)
        ] do
      refute String.contains?(haystack, form), "private-key encoding found"
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
