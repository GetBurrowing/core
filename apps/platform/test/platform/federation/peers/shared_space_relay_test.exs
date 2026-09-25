defmodule Platform.Federation.Peers.SharedSpaceRelayTest.Inbox do
  @moduledoc """
  A real peer inbox on a loopback socket for the relay tests. It reports
  every envelope to the test with the status it answered, and answers as the
  test's mode Agent says: `:ok` (200 with a `data` id, as a real peer's
  inbox does) or `{:status, n}`. A loopback server needs no `Req.Test`
  ownership, so a RESTARTED connection (a new pid) reaches it too.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{test: test, state: state}) do
    {:ok, raw, conn} = read_body(conn)
    envelope = Jason.decode!(raw)
    %{mode: mode, share_space_id: share_space_id} = Agent.get(state, & &1)

    case mode do
      :ok ->
        data =
          case envelope["type"] do
            "space.share" -> %{"space_id" => share_space_id}
            _ -> %{"message_id" => Ecto.UUID.generate()}
          end

        send(test, {:inbox, envelope, 200})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{ok: true, result: "ok", data: data}))

      {:status, status} ->
        send(test, {:inbox, envelope, status})
        send_resp(conn, status, ~s({"error":"unavailable"}))

      # A 2xx whose body is not an inbox acknowledgement (a proxy's HTML
      # page). Reported as `{:raw, status}` so `collect_ok` does not count it.
      {:raw, status, body} ->
        send(test, {:inbox, envelope, {:raw, status}})
        send_resp(conn, status, body)
    end
  end
end

defmodule Platform.Federation.Peers.SharedSpaceRelayTest do
  @moduledoc """
  Task 01a0d90f stage 5 (ADR 0054 section 3): the shared-space relay in
  `Platform.Federation.Peers.PeerConnection`, against a real loopback inbox.

    * owner sends `message.replicate`, replica sends `message.submit`, each
      naming the receiver's space id and nothing about the author but a
      participant id and a display name;
    * the cursor advances only from a 2xx;
    * an ingested (`federation_inbound`) message is never sent back;
    * replay from the cursor on EVERY start (a killed connection loses its
      queue and does not set `resync_needed`) and after an overflow, each
      delivering the missed messages exactly once;
    * `Peers.share_space/3` end to end, and revoke stops the relay.
  """

  # async: false — flips global app env; connections run under the
  # application's peer supervisor (shared sandbox).
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.FederationPeerFixtures

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Boot
  alias Platform.Federation.Peers.Inbound
  alias Platform.Federation.Peers.Ingest
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.Relay
  alias Platform.Federation.Peers.SharedSpace
  alias Platform.Federation.Peers.SharedSpaces
  alias Platform.Federation.Peers.Supervisor, as: PeerSupervisor

  @quiet_ms 300

  setup do
    enable_federation!(allow_http: true)
    # No Req.Test plug: requests go through the real adapter to the loopback
    # inbox below.
    put_env_restored(:peer_federation_req_options, [])
    InstallIdentity.ensure!()

    state =
      start_supervised!(
        {Agent, fn -> %{mode: :ok, share_space_id: Ecto.UUID.generate()} end},
        id: :inbox_state
      )

    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {__MODULE__.Inbox, %{test: self(), state: state}},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    peer = peer_for!(remote_install(%{base_url: "http://127.0.0.1:#{port}"}))
    %{peer: peer, state: state}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mode!(state, mode), do: Agent.update(state, &%{&1 | mode: mode})

  defp local_space!(kind \\ "channel") do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Relay #{n}", slug: "fed-relay-#{n}", kind: kind})

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Local Pat",
        joined_at: DateTime.utc_now()
      })

    {space, author}
  end

  defp shared!(peer, space, role, cursor \\ nil) do
    %SharedSpace{}
    |> SharedSpace.create_changeset(%{
      peer_id: peer.id,
      local_space_id: space.id,
      remote_space_id: Ecto.UUID.generate(),
      role: role,
      outbound_cursor_message_id: cursor
    })
    |> Repo.insert!()
  end

  defp post!(space, author, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp start_conn!(peer, opts \\ [base_backoff_ms: 10, max_backoff_ms: 40]) do
    {:ok, _wrapper} = PeerSupervisor.start_peer(peer, opts)
    on_exit(fn -> PeerSupervisor.stop_peer(peer.id) end)
    pid = PeerConnection.whereis(peer.id)
    assert is_pid(pid)
    # A call is answered after `handle_continue`, so the subscriptions and
    # the start-up replay have happened once this returns.
    status!(peer)
    pid
  end

  defp status!(peer) do
    {:ok, status} = PeerConnection.status(peer.id)
    status
  end

  defp cursor(shared_id), do: Repo.get!(SharedSpace, shared_id).outbound_cursor_message_id

  # Collects successful (200) relay deliveries until `count` have arrived,
  # then waits `@quiet_ms` more to catch any extra one.
  defp collect_ok(count, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    ids = collect_ok(count, deadline, [])
    ids ++ drain_ok()
  end

  defp collect_ok(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect_ok(count, deadline, acc) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:inbox, %{"type" => "message." <> _, "payload" => p}, 200} ->
        collect_ok(count - 1, deadline, [p["message_id"] | acc])

      {:inbox, _env, _status} ->
        collect_ok(count, deadline, acc)
    after
      wait -> flunk("only #{length(acc)} of #{length(acc) + count} deliveries arrived")
    end
  end

  defp drain_ok do
    receive do
      {:inbox, %{"type" => "message." <> _, "payload" => p}, 200} ->
        [p["message_id"] | drain_ok()]

      {:inbox, _env, _status} ->
        drain_ok()
    after
      @quiet_ms -> []
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # ── direction and payload ────────────────────────────────────────────────

  describe "what crosses" do
    test "owner: a local message goes as message.replicate; the cursor advances on the 2xx",
         %{peer: peer} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      start_conn!(peer)

      msg = post!(space, author, "ping-01a0d90f-a")

      assert_receive {:inbox, %{"type" => "message.replicate", "payload" => p}, 200}, 2_000
      assert p["space_id"] == shared.remote_space_id
      assert p["message_id"] == msg.id
      assert p["content"] == "ping-01a0d90f-a"
      assert p["author"] == %{"id" => author.id, "name" => "Local Pat"}
      assert Enum.sort(Map.keys(p)) == ~w(author content message_id sent_at space_id)

      assert assert_eventually(fn -> cursor(shared.id) end) == msg.id

      assert [%{direction: "outbound", local_message_id: local_id}] =
               SharedSpaces.list_links(peer.id)

      assert local_id == msg.id
    end

    test "replica: a local message goes as message.submit", %{peer: peer} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "replica")
      start_conn!(peer)

      msg = post!(space, author, "pong-01a0d90f-b")

      assert_receive {:inbox, %{"type" => "message.submit", "payload" => p}, 200}, 2_000
      assert p["space_id"] == shared.remote_space_id
      assert p["message_id"] == msg.id
    end

    test "the cursor does not move on a failure, only on the later 2xx", %{
      peer: peer,
      state: state
    } do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      mode!(state, {:status, 503})
      start_conn!(peer, base_backoff_ms: 200, max_backoff_ms: 200)

      msg = post!(space, author, "retry-01a0d90f")
      assert_receive {:inbox, %{"payload" => %{"message_id" => id}}, 503}, 2_000
      assert id == msg.id
      assert assert_eventually(fn -> status!(peer).failed >= 1 end)
      assert cursor(shared.id) == nil

      mode!(state, :ok)
      assert [msg.id] == collect_ok(1)
      assert cursor(shared.id) == msg.id
    end

    test "an ingested message is never sent back; the next local one is", %{peer: peer} do
      {space, author} = local_space!()
      _shared = shared!(peer, space, "owner")
      start_conn!(peer)

      # The peer submits a message (we are the owner): it is posted here as
      # federation_inbound and broadcast like any other.
      {:ok, :message_ingested, %{"message_id" => ingested_id}} =
        Ingest.ingest(peer, "message.submit", %{
          "space_id" => space.id,
          "message_id" => Platform.Types.UUIDv7.generate(),
          "author" => %{"id" => "r1", "name" => "Remote Sam"},
          "content" => "from the replica"
        })

      # POSITIVE CONTROL, posted after it: the connection is live and in
      # order, so had the ingested one been queued it would arrive first.
      local = post!(space, author, "local-after-01a0d90f")

      assert collect_ok(1) == [local.id]
      refute ingested_id == local.id
    end

    test "thread replies, deleted and non-text messages are not relayed" do
      base = %Message{
        thread_id: nil,
        deleted_at: nil,
        content_type: "text",
        content: "x",
        metadata: %{}
      }

      assert Relay.relayable?(base)
      refute Relay.relayable?(%{base | thread_id: Ecto.UUID.generate()})
      refute Relay.relayable?(%{base | deleted_at: DateTime.utc_now()})
      refute Relay.relayable?(%{base | content_type: "canvas"})
      refute Relay.relayable?(%{base | content: ""})
      refute Relay.relayable?(%{base | metadata: %{"source" => "federation_inbound"}})
      assert Relay.relayable?(%{base | metadata: %{"source" => "email_inbound"}})
    end
  end

  # ── replay ───────────────────────────────────────────────────────────────

  describe "replay from the cursor" do
    test "a killed connection loses its queue; the restart replays it exactly once",
         %{peer: peer, state: state} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      mode!(state, {:status, 503})
      old = start_conn!(peer, base_backoff_ms: 60_000, max_backoff_ms: 60_000)

      m1 = post!(space, author, "k1")
      assert_receive {:inbox, _, 503}, 2_000
      m2 = post!(space, author, "k2")
      m3 = post!(space, author, "k3")

      assert %{queue_len: 3, in_flight: false, resync_needed: false} =
               assert_eventually(fn ->
                 s = status!(peer)
                 s.queue_len == 3 and not s.in_flight and s
               end)

      mode!(state, :ok)
      Process.exit(old, :kill)

      new = assert_eventually(fn -> (pid = PeerConnection.whereis(peer.id)) != old and pid end)
      assert is_pid(new)

      assert collect_ok(3) == [m1.id, m2.id, m3.id]
      assert cursor(shared.id) == m3.id
      # The restarted process never saw an overflow: the replay ran because
      # it started, not because a flag told it to.
      refute status!(peer).resync_needed
    end

    test "after an overflow the missed messages arrive exactly once, in order",
         %{peer: peer, state: state} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      mode!(state, {:status, 503})
      start_conn!(peer, queue_cap: 2, base_backoff_ms: 1_000, max_backoff_ms: 1_000)

      m1 = post!(space, author, "o1")
      assert_receive {:inbox, _, 503}, 2_000
      rest = for n <- 2..5, do: post!(space, author, "o#{n}")

      # m1 was requeued and then dropped by the overflow.
      assert %{resync_needed: true, queue_len: 2} = status!(peer)

      mode!(state, :ok)
      ids = [m1 | rest] |> Enum.map(& &1.id)

      assert collect_ok(5) == ids
      assert cursor(shared.id) == List.last(ids)
      assert %{resync_needed: false, queue_len: 0} = status!(peer)
    end

    test "a start replays only what is after the cursor", %{peer: peer} do
      {space, author} = local_space!()
      acked = post!(space, author, "already there")
      missed = post!(space, author, "missed while down")
      _shared = shared!(peer, space, "owner", acked.id)

      start_conn!(peer)
      assert collect_ok(1) == [missed.id]
    end
  end

  # ── the replica side of a share ──────────────────────────────────────────

  describe "space.share on the replica" do
    # ORDER IS THE POINT. On a real install the replica's connection starts
    # when the relationship is accepted, BEFORE any share arrives. The stage 5
    # tests inserted the replica row and then started the connection, so the
    # start-up read found it and a missing refresh could not show (reviewer
    # finding V1, task 01a0d90f stage 6).
    test "a share delivered to a RUNNING connection relays replica posts as message.submit",
         %{peer: peer} do
      start_conn!(peer)
      assert status!(peer).shared_spaces == 0

      owner_space_id = Ecto.UUID.generate()

      assert {:ok, :space_shared, %{"space_id" => local_id}} =
               Inbound.handle(%{
                 envelope: %{
                   "type" => "space.share",
                   "payload" => %{"space_id" => owner_space_id, "name" => "Plans"}
                 },
                 peer: peer
               })

      # The handler's refresh is a cast from this process, so it is handled
      # before this call.
      assert status!(peer).shared_spaces == 1

      {:ok, author} =
        Chat.add_participant(local_id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Replica Pat",
          joined_at: DateTime.utc_now()
        })

      msg = post!(%{id: local_id}, author, "pong-01a0d90f-s6")

      assert_receive {:inbox, %{"type" => "message.submit", "payload" => p}, 200}, 2_000
      assert p["space_id"] == owner_space_id
      assert p["message_id"] == msg.id
    end
  end

  describe "Boot re-scan safety net" do
    test "a re-scan refreshes a running connection that was never told of a row",
         %{peer: peer} do
      start_conn!(peer)
      {space, author} = local_space!()
      # Written with no refresh, as a future writer that forgot would.
      shared = shared!(peer, space, "replica")
      # POSITIVE CONTROL: nothing has told the connection yet.
      assert status!(peer).shared_spaces == 0

      start_supervised!({Boot, interval: 3_600_000})
      :ok = Boot.rescan()
      assert assert_eventually(fn -> status!(peer).shared_spaces == 1 end)

      msg = post!(space, author, "rescan-01a0d90f-s6")
      assert_receive {:inbox, %{"type" => "message.submit", "payload" => p}, 200}, 2_000
      assert p["space_id"] == shared.remote_space_id
      assert p["message_id"] == msg.id
    end
  end

  # ── share_space and revoke ───────────────────────────────────────────────

  describe "Peers.share_space/3" do
    test "records the owner row from the peer's answer and relays what follows",
         %{peer: peer, state: state} do
      {space, author} = local_space!()
      start_conn!(peer)
      before = post!(space, author, "history before the share")

      assert {:ok, %SharedSpace{role: "owner"} = shared} = Peers.share_space(peer, space.id)
      # The connection was running before the row existed: share_space's
      # refresh (a cast from this process, so ordered before this call) is
      # what made it subscribe.
      assert status!(peer).shared_spaces == 1

      assert_receive {:inbox, %{"type" => "space.share", "payload" => share}, 200}, 2_000
      assert share == %{"space_id" => space.id, "name" => space.name}
      %{share_space_id: replica_id} = Agent.get(state, & &1)
      assert shared.remote_space_id == replica_id
      assert shared.outbound_cursor_message_id == before.id

      after_msg = post!(space, author, "after the share")
      assert collect_ok(1) == [after_msg.id]
    end

    test "a 2xx with a non-JSON body is not an acknowledgement: the cursor stays",
         %{peer: peer, state: state} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      mode!(state, {:raw, 200, "<html>accepted</html>"})
      start_conn!(peer, base_backoff_ms: 200, max_backoff_ms: 200)

      msg = post!(space, author, "garbage-2xx-01a0d90f")
      assert_receive {:inbox, %{"payload" => %{"message_id" => id}}, {:raw, 200}}, 2_000
      assert id == msg.id

      status = assert_eventually(fn -> (s = status!(peer)) && s.failed >= 1 && s end)
      assert status.last_error == :invalid_answer
      assert status.sent == 0
      assert cursor(shared.id) == nil

      # POSITIVE CONTROL: the same message is retried and lands once the
      # peer acknowledges properly, so it was held, not lost.
      mode!(state, :ok)
      assert collect_ok(1) == [msg.id]
      assert cursor(shared.id) == msg.id
    end

    test "refuses a DM, an already-shared space and a non-active peer", %{peer: peer} do
      {dm, _} = local_space!("dm")
      assert Peers.share_space(peer, dm.id) == {:error, :space_not_shareable}

      {space, _} = local_space!()
      _ = shared!(peer, space, "owner")
      assert Peers.share_space(peer, space.id) == {:error, :already_shared}

      pending = peer_for!(remote_install(), "pending_outbound")
      {other, _} = local_space!()

      assert Peers.share_space(pending, other.id) ==
               {:error, {:peer_not_active, "pending_outbound"}}

      assert Peers.share_space(peer, Ecto.UUID.generate()) == {:error, :space_not_found}
    end

    test "revoke marks the shared spaces revoked and nothing more crosses", %{peer: peer} do
      {space, author} = local_space!()
      shared = shared!(peer, space, "owner")
      start_conn!(peer)

      # POSITIVE CONTROL: the relay is live before the revoke.
      live = post!(space, author, "before revoke")
      assert collect_ok(1) == [live.id]

      {:ok, _} = Peers.revoke(peer, notify: false)
      assert Repo.get!(SharedSpace, shared.id).status == "revoked"
      assert PeerConnection.whereis(peer.id) == nil

      _ = post!(space, author, "after revoke")
      assert drain_ok() == []

      assert from(s in SharedSpace, where: s.peer_id == ^peer.id and s.status == "active")
             |> Repo.aggregate(:count) == 0
    end
  end
end
