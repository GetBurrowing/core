defmodule Platform.Federation.Peers.HandshakeTest do
  @moduledoc """
  Task 01a0d90f stage 3 (ADR 0054 section 1): the sending side of the
  handshake, `Peers.propose/2`, `accept/2`, `revoke/2` and `rotate_key/0`.
  The remote install is a `Req.Test` stub that records what it receives, and
  each sent envelope is checked against THIS install's public key the way the
  remote would check it.
  """

  # async: false — flips global app env.
  use Platform.DataCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.InstallIdentity

  @public {93, 184, 216, 34}

  setup do
    enable_federation!()
    me = InstallIdentity.ensure!()
    remote = remote_install()
    resolve!(%{URI.parse(remote.base_url).host => [@public]})
    %{me: me, remote: remote}
  end

  # The remote: serves its descriptor on GET, answers inbox POSTs with
  # `inbox_status`, and forwards every POST (plus whatever `on_post` returns)
  # to the test.
  defp stub_remote(remote, inbox_status \\ 200, on_post \\ fn -> nil end) do
    test_pid = self()

    Req.Test.stub(Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, descriptor(remote))

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          [sig] = Plug.Conn.get_req_header(conn, Envelope.signature_header())
          send(test_pid, {:inbox, conn.request_path, raw, sig, on_post.()})

          conn
          |> Plug.Conn.put_status(inbox_status)
          |> Req.Test.json(if inbox_status == 200, do: %{ok: true}, else: %{error: "nope"})
      end
    end)
  end

  defp signed_by?(raw, sig, public_key) do
    Ed25519.verify(
      Envelope.signing_prefix() <> raw,
      Base.url_decode64!(sig, padding: false),
      public_key
    )
  end

  test "propose records pending_outbound and sends a propose signed by this install", %{
    me: me,
    remote: remote
  } do
    stub_remote(remote)

    assert {:ok, peer} = Peers.propose(remote.base_url <> "/")
    assert peer.status == "pending_outbound"
    assert peer.peer_install_id == remote.install_id
    assert [%{kid: kid}] = peer.public_keys
    assert kid == remote.kid

    assert_received {:inbox, "/federation/v1/inbox", raw, sig, _}
    assert signed_by?(raw, sig, me.public_key)

    body = Jason.decode!(raw)
    assert body["type"] == "relationship.propose"
    assert body["to"] == remote.install_id
    assert body["from"] == me.install_id
    assert body["payload"]["install_id"] == me.install_id
    assert body["payload"]["kid"] == me.kid
    assert Base.url_decode64!(body["payload"]["public_key"], padding: false) == me.public_key
    assert body["payload"]["base_url"] == "https://local.example.test"
  end

  test "a propose the remote refuses leaves no row behind", %{remote: remote} do
    stub_remote(remote, 403)

    assert {:error, {:http_status, 403, "nope"}} = Peers.propose(remote.base_url)
    assert Peers.list_peers() == []
  end

  test "propose is refused while federation is off", %{remote: remote} do
    put_env_restored(:peer_federation_enabled, false)
    stub_remote(remote)

    assert Peers.propose(remote.base_url) == {:error, :federation_disabled}
    refute_received {:inbox, _, _, _, _}
  end

  test "accept sends relationship.accept, then activates", %{me: me, remote: remote} do
    peer = peer_for!(remote, "pending_inbound")
    stub_remote(remote)
    n = System.unique_integer([:positive])

    %{id: user_id} =
      Repo.insert!(%Platform.Accounts.User{
        name: "Peer Admin #{n}",
        email: "peer-admin-01a0d90f-#{n}@example.com",
        oidc_sub: "peer-admin-01a0d90f-#{n}"
      })

    assert {:ok, active} = Peers.accept(peer, user_id)
    assert {active.status, active.accepted_by_user_id} == {"active", user_id}

    assert_received {:inbox, _, raw, sig, _}
    assert signed_by?(raw, sig, me.public_key)
    assert Jason.decode!(raw)["type"] == "relationship.accept"
  end

  test "an undelivered accept leaves the row pending for a retry", %{remote: remote} do
    peer = peer_for!(remote, "pending_inbound")
    stub_remote(remote, 500)

    assert {:error, {:http_status, 500, _}} = Peers.accept(peer, nil)
    assert Peers.get_peer(peer.id).status == "pending_inbound"
  end

  test "revoke persists revoked BEFORE the notice goes out", %{remote: remote} do
    peer = peer_for!(remote)
    stub_remote(remote, 200, fn -> Peers.get_peer(peer.id).status end)

    assert {:ok, revoked} = Peers.revoke(peer)
    assert {revoked.status, revoked.revoked_by} == {"revoked", "local"}

    assert_received {:inbox, _, raw, _sig, "revoked"}
    assert Jason.decode!(raw)["type"] == "relationship.revoke"
  end

  test "revoke holds when the notice fails", %{remote: remote} do
    peer = peer_for!(remote)
    Req.Test.stub(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:ok, %{status: "revoked"}} = Peers.revoke(peer)
    assert Peers.get_peer(peer.id).status == "revoked"
  end

  test "rotate_key announces the new kid to active peers, signed by the OLD key", %{
    me: old,
    remote: remote
  } do
    peer = peer_for!(remote)
    _pending = peer_for!(remote_install(), "pending_outbound")
    stub_remote(remote)

    assert {:ok, new, [{peer_id, :ok}]} = Peers.rotate_key()
    assert peer_id == peer.id
    refute new.kid == old.kid

    assert_received {:inbox, _, raw, sig, _}
    refute_received {:inbox, _, _, _, _}

    body = Jason.decode!(raw)
    assert body["type"] == "key.rotate"
    assert body["kid"] == old.kid
    assert signed_by?(raw, sig, old.public_key)
    refute signed_by?(raw, sig, new.public_key)
    assert body["payload"]["kid"] == new.kid
    assert Base.url_decode64!(body["payload"]["public_key"], padding: false) == new.public_key
  end

  describe "protocol versions (task 01a14ba9 stage 2)" do
    @dual ["suite-federation/1", "burrow-federation/2"]

    # The remote serving `desc`; every POST is forwarded with BOTH signature
    # header lists, so a test sees exactly which header(s) were sent.
    defp stub_remote_desc(desc) do
      test_pid = self()

      Req.Test.stub(Client, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, desc)

          "POST" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)

            v1 = Plug.Conn.get_req_header(conn, Envelope.signature_header(:v1))
            v2 = Plug.Conn.get_req_header(conn, Envelope.signature_header(:v2))
            send(test_pid, {:inbox_headers, raw, v1, v2})

            Req.Test.json(conn, %{ok: true})
        end
      end)
    end

    test "propose stores the descriptor's protocols on the pending_outbound row", %{
      remote: remote
    } do
      stub_remote_desc(descriptor(remote, %{"protocols" => @dual}))

      assert {:ok, peer} = Peers.propose(remote.base_url)
      assert peer.metadata["protocols"] == @dual
      assert Peers.get_peer(peer.id).metadata["protocols"] == @dual
    end

    test "propose to a peer with no protocols list stores it as v1-only", %{remote: remote} do
      stub_remote_desc(descriptor(remote))

      assert {:ok, peer} = Peers.propose(remote.base_url)
      assert Peers.get_peer(peer.id).metadata["protocols"] == ["suite-federation/1"]
    end

    test "with the flag off, propose to a v2 peer signs v1 only", %{me: me, remote: remote} do
      stub_remote_desc(descriptor(remote, %{"protocols" => @dual}))

      assert {:ok, _peer} = Peers.propose(remote.base_url)
      assert_received {:inbox_headers, raw, [v1], []}
      assert signed_by?(raw, v1, me.public_key)
    end

    test "with the flag on, propose to a peer whose descriptor advertises v2 signs v2 only", %{
      me: me,
      remote: remote
    } do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")
      stub_remote_desc(descriptor(remote, %{"protocols" => @dual}))

      assert {:ok, _peer} = Peers.propose(remote.base_url)
      assert_received {:inbox_headers, raw, [], [v2]}

      assert Ed25519.verify(
               Envelope.signing_prefix(:v2) <> raw,
               Base.url_decode64!(v2, padding: false),
               me.public_key
             )
    end

    test "with the flag on, propose to a v1-only peer signs v1 only", %{me: me, remote: remote} do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")
      stub_remote_desc(descriptor(remote))

      assert {:ok, _peer} = Peers.propose(remote.base_url)
      assert_received {:inbox_headers, raw, [v1], []}
      assert signed_by?(raw, v1, me.public_key)
    end
  end
end
