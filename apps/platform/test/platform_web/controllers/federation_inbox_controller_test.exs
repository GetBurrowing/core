defmodule PlatformWeb.FederationInboxControllerTest do
  @moduledoc """
  Task 01a0d90f stage 3 (ADR 0054 section 2): `POST /federation/v1/inbox`
  through the real endpoint and router.

    * The inbox never echoes the request: every refusal, and the success
      path, answers without any request bytes, marker included.
    * The 256 KB cap holds WHILE reading: an oversized body is refused with
      most of it still unread in the adapter, measured on the adapter state.
    * Flag off answers 404; flag on handles a real envelope (positive
      control), with HTTP stubbed by `Req.Test`.
  """

  # async: false — flips global app env and uses the named NonceCache table.
  use PlatformWeb.ConnCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache
  alias PlatformWeb.Plugs.VerifyPeerEnvelope

  @path "/federation/v1/inbox"
  @public {93, 184, 216, 34}

  setup do
    enable_federation!()
    NonceCache.reset()
    on_exit(&NonceCache.reset/0)
    InstallIdentity.ensure!()
    :ok
  end

  defp post_raw(conn, raw, headers) do
    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> put_req_header("content-type", "application/json")
    |> post(@path, raw)
  end

  describe "positive control" do
    test "a valid accept from a pending_outbound peer is handled", %{conn: conn} do
      remote = remote_install()
      peer = peer_for!(remote, "pending_outbound")
      {raw, headers} = envelope(remote, "relationship.accept")

      conn = post_raw(conn, raw, headers)

      assert json_response(conn, 200) == %{"ok" => true, "result" => "accepted"}
      assert Peers.get_peer(peer.id).status == "active"
    end

    test "a propose from an unknown install is recorded end to end", %{conn: conn} do
      remote = remote_install()
      resolve!(%{URI.parse(remote.base_url).host => [@public]})
      Req.Test.stub(Client, &Req.Test.json(&1, descriptor(remote)))

      {raw, headers} = envelope(remote, "relationship.propose", propose_payload(remote))
      conn = post_raw(conn, raw, headers)

      assert json_response(conn, 200) == %{"ok" => true, "result" => "proposal_recorded"}
      assert Peers.get_peer_by_install_id(remote.install_id).status == "pending_inbound"
    end
  end

  describe "the inbox never echoes the request" do
    setup do
      remote = remote_install()
      peer_for!(remote)
      marker = "echo-marker-01a0d90f-" <> Base.encode16(:crypto.strong_rand_bytes(6))
      %{remote: remote, marker: marker}
    end

    defp assert_no_echo(conn, status, reason, marker, sig) do
      body = conn.resp_body
      assert conn.status == status
      assert Jason.decode!(body) == %{"error" => reason}
      refute body =~ marker
      if sig, do: refute(body =~ sig)
    end

    test "on every refusal", %{remote: remote, marker: marker} do
      payload = %{"note" => marker}
      {_pub, other_priv} = Platform.Federation.Ed25519.generate()

      cases = [
        {"bad_signature", 401,
         envelope(remote, "test.ping", payload, signer: {remote.kid, other_priv})},
        {"wrong_recipient", 421,
         envelope(remote, "test.ping", payload, to: Platform.Types.UUIDv7.generate())},
        {"unknown_kid", 401,
         envelope(remote, "test.ping", payload, signer: {marker, remote.private_key})},
        {"unknown_peer", 403, envelope(remote_install(), "test.ping", payload)},
        {"stale_timestamp", 401,
         envelope(remote, "test.ping", payload, ts: System.system_time(:millisecond) - 600_000)},
        {"invalid_json", 400, {"{not json " <> marker, []}},
        {"too_large", 413,
         {String.duplicate(marker, div(Envelope.max_bytes(), byte_size(marker)) + 2), []}}
      ]

      for {reason, status, {raw, headers}} <- cases do
        sig =
          Enum.find_value(headers, fn {k, v} -> if k == Envelope.signature_header(), do: v end)

        conn = post_raw(build_conn(), raw, headers)
        assert_no_echo(conn, status, reason, marker, sig)
      end
    end

    test "on a replay and on success", %{remote: remote, marker: marker} do
      {raw, headers} = envelope(remote, "test.ping", %{"note" => marker})

      first = post_raw(build_conn(), raw, headers)
      # verified, then refused by the handler: still no echo
      assert Jason.decode!(first.resp_body) == %{"error" => "unsupported_type"}
      refute first.resp_body =~ marker

      replay = post_raw(build_conn(), raw, headers)
      assert_no_echo(replay, 409, "replayed_nonce", marker, nil)
    end
  end

  describe "body cap holds while reading" do
    test "an oversized body is refused with the rest left unread" do
      total = 10 * 1024 * 1024
      conn = Plug.Test.conn(:post, @path, :binary.copy("a", total))

      conn = VerifyPeerEnvelope.call(conn, [])

      assert conn.halted
      assert conn.status == 413
      {Plug.Adapters.Test.Conn, %{req_body: unread}} = conn.adapter
      assert byte_size(unread) == total - (Envelope.max_bytes() + 1)
    end

    test "a declared content-length over the cap is refused before any byte is read" do
      total = Envelope.max_bytes() + 10

      conn =
        :post
        |> Plug.Test.conn(@path, :binary.copy("a", total))
        |> put_req_header("content-length", Integer.to_string(total))
        |> VerifyPeerEnvelope.call([])

      assert conn.status == 413
      {Plug.Adapters.Test.Conn, %{req_body: unread}} = conn.adapter
      assert byte_size(unread) == total
    end

    test "control: a body at the cap is read in full and reaches verification" do
      body = :binary.copy("a", Envelope.max_bytes())
      conn = :post |> Plug.Test.conn(@path, body) |> VerifyPeerEnvelope.call([])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_json"}
      {Plug.Adapters.Test.Conn, %{req_body: unread}} = conn.adapter
      assert unread == ""
    end
  end

  test "flag off: 404 and nothing is read", %{conn: conn} do
    put_env_restored(:peer_federation_enabled, false)
    remote = remote_install()
    peer_for!(remote, "pending_outbound")
    {raw, headers} = envelope(remote, "relationship.accept")

    conn = post_raw(conn, raw, headers)

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    assert Peers.get_peer_by_install_id(remote.install_id).status == "pending_outbound"
  end

  test "host-agnostic: answers on a chat-prefixed host", %{conn: conn} do
    remote = remote_install()
    peer_for!(remote, "pending_outbound")
    {raw, headers} = envelope(remote, "relationship.accept")

    conn = post_raw(%{conn | host: "chat.example.test"}, raw, headers)
    assert json_response(conn, 200)["result"] == "accepted"
  end
end
