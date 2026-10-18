defmodule Platform.Federation.Peers.EnvelopeTest do
  @moduledoc """
  Task 01a0d90f stage 3 (ADR 0054 section 2): every verify check refuses
  with its own reason, measured against a POSITIVE CONTROL built by the same
  builder, so no refusal here is an artefact of a broken builder.

  Mutation map (each check was removed once and the named test went red;
  see the stage 3 report): signature -> "forged signature" and "tampered
  body"; ts window -> "stale" and "future"; nonce -> "replayed nonce";
  `to` -> "wrong recipient"; kid -> "unknown kid", "retired kid",
  "a previous kid past its overlap"; active-peer -> "revoked peer" and "pending peer".
  """

  # async: false — flips global app env and uses the named NonceCache table.
  use Platform.DataCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.Inbound
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache

  setup do
    enable_federation!()
    NonceCache.reset()
    on_exit(&NonceCache.reset/0)
    InstallIdentity.ensure!()
    remote = remote_install()
    peer = peer_for!(remote)
    now = System.system_time(:millisecond)
    %{remote: remote, peer: peer, now: now}
  end

  defp verify({raw, headers}, now), do: Envelope.verify(raw, headers, now)

  # Replace one byte inside the body without changing its length or shape.
  defp flip_one_byte(raw, marker) do
    [before, rest] = String.split(raw, marker, parts: 2)
    <<first, tail::binary>> = marker
    before <> <<first + 1>> <> tail <> rest
  end

  describe "positive control" do
    test "an envelope from the same builder is accepted", %{
      remote: remote,
      peer: peer,
      now: now
    } do
      env = envelope(remote, "test.ping", %{"note" => "aaaa"}, ts: now)

      assert {:ok, %{envelope: body, peer: verified_peer, key_status: "current"}} =
               verify(env, now)

      assert verified_peer.id == peer.id
      assert body["type"] == "test.ping"
      assert body["payload"] == %{"note" => "aaaa"}
    end

    test "the timestamp window is inclusive at exactly 300 s either side", %{
      remote: remote,
      now: now
    } do
      assert {:ok, _} = verify(envelope(remote, "test.ping", %{}, ts: now), now + 300_000)
      assert {:ok, _} = verify(envelope(remote, "test.ping", %{}, ts: now), now - 300_000)
    end
  end

  describe "each check refuses with its own reason" do
    test "forged signature (a different key under the peer's kid)", %{remote: remote, now: now} do
      {_pub, other_priv} = Ed25519.generate()
      env = envelope(remote, "test.ping", %{}, ts: now, signer: {remote.kid, other_priv})

      assert verify(env, now) == {:error, :bad_signature}
    end

    test "a body tampered by one byte after signing", %{remote: remote, now: now} do
      {raw, headers} = envelope(remote, "test.ping", %{"note" => "aaaa"}, ts: now)
      tampered = flip_one_byte(raw, "aaaa")

      assert byte_size(tampered) == byte_size(raw)
      assert tampered != raw
      assert Envelope.verify(tampered, headers, now) == {:error, :bad_signature}
      # control: the untampered original still verifies
      assert {:ok, _} = Envelope.verify(raw, headers, now)
    end

    test "a missing or undecodable signature header", %{remote: remote, now: now} do
      {raw, headers} = envelope(remote, "test.ping", %{}, ts: now)
      without = List.keydelete(headers, Envelope.signature_header(), 0)

      assert Envelope.verify(raw, without, now) == {:error, :missing_signature}
      assert Envelope.verify(raw, with_signature(headers, "!!!"), now) == {:error, :bad_signature}
    end

    test "wrong recipient", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now, to: Platform.Types.UUIDv7.generate())
      assert verify(env, now) == {:error, :wrong_recipient}
    end

    test "unknown kid", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now, signer: {"nope", remote.private_key})
      assert verify(env, now) == {:error, :unknown_kid}
    end

    test "retired kid", %{remote: remote, peer: peer, now: now} do
      {:ok, _} = Peers.retire_peer_key(peer, remote.kid)
      assert verify(envelope(remote, "test.ping", %{}, ts: now), now) == {:error, :retired_kid}
    end

    test "a previous kid verifies inside its overlap", %{remote: remote, peer: peer, now: now} do
      {:ok, _} = Peers.add_peer_key(peer, "rotated", remote_install().b64, 60)

      assert {:ok, %{key_status: "previous"}} =
               verify(envelope(remote, "test.ping", %{}, ts: now), now)
    end

    test "a previous kid past its overlap is refused", %{remote: remote, peer: peer, now: now} do
      # overlap 0: valid_until is the moment of rotation
      {:ok, _} = Peers.add_peer_key(peer, "rotated", remote_install().b64, 0)
      later = now + 5_000

      assert verify(envelope(remote, "test.ping", %{}, ts: later), later) ==
               {:error, :expired_kid}
    end

    test "timestamp outside the window in the past", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now)
      assert verify(env, now + 300_001) == {:error, :stale_timestamp}
    end

    test "timestamp outside the window in the future", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now)
      assert verify(env, now - 300_001) == {:error, :future_timestamp}
    end

    test "replayed nonce", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now)
      assert {:ok, _} = verify(env, now)
      assert verify(env, now + 10) == {:error, :replayed_nonce}
    end

    test "a refused envelope does not burn its nonce", %{remote: remote, now: now} do
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {_pub, other_priv} = Ed25519.generate()

      forged =
        envelope(remote, "test.ping", %{},
          ts: now,
          nonce: nonce,
          signer: {remote.kid, other_priv}
        )

      assert verify(forged, now) == {:error, :bad_signature}
      assert {:ok, _} = verify(envelope(remote, "test.ping", %{}, ts: now, nonce: nonce), now)
    end

    test "oversize body, checked before decoding", %{remote: remote, now: now} do
      big = envelope(remote, "test.ping", %{"pad" => String.duplicate("x", 256 * 1024)}, ts: now)
      assert verify(big, now) == {:error, :too_large}

      not_json = String.duplicate("z", Envelope.max_bytes() + 1)
      assert Envelope.verify(not_json, [], now) == {:error, :too_large}

      # control: exactly at the cap is not refused for size
      at_cap = String.duplicate("z", Envelope.max_bytes())
      assert Envelope.verify(at_cap, [], now) == {:error, :invalid_json}
    end

    test "non-JSON and non-object bodies", %{now: now} do
      assert Envelope.verify("not json", [], now) == {:error, :invalid_json}
      assert Envelope.verify("[1,2]", [], now) == {:error, :invalid_json}
    end

    test "unsupported version and malformed fields", %{remote: remote, now: now} do
      {raw, headers} = envelope(remote, "test.ping", %{}, ts: now)
      body = Jason.decode!(raw)

      assert Envelope.verify(Jason.encode!(%{body | "v" => 2}), headers, now) ==
               {:error, :unsupported_version}

      assert Envelope.verify(Jason.encode!(Map.delete(body, "nonce")), headers, now) ==
               {:error, :malformed_envelope}

      assert Envelope.verify(Jason.encode!(%{body | "from" => "not-a-uuid"}), headers, now) ==
               {:error, :malformed_envelope}
    end

    test "unknown sender for any type except relationship.propose", %{now: now} do
      stranger = remote_install()
      env = envelope(stranger, "test.ping", %{}, ts: now)
      assert verify(env, now) == {:error, :unknown_peer}
    end
  end

  describe "peer status" do
    test "a revoked peer is refused; the same peer was accepted immediately before", %{
      remote: remote,
      peer: peer,
      now: now
    } do
      assert {:ok, _} = verify(envelope(remote, "test.ping", %{}, ts: now), now)

      {:ok, _} = Peers.revoke(peer, notify: false)

      assert verify(envelope(remote, "test.ping", %{}, ts: now), now) == {:error, :peer_revoked}

      assert verify(envelope(remote, "relationship.accept", %{}, ts: now), now) ==
               {:error, :peer_revoked}
    end

    test "a pending peer may send handshake types only", %{now: now} do
      remote = remote_install()
      _pending = peer_for!(remote, "pending_outbound")

      assert verify(envelope(remote, "test.ping", %{}, ts: now), now) ==
               {:error, :peer_not_active}

      assert {:ok, _} = verify(envelope(remote, "relationship.accept", %{}, ts: now), now)
    end

    test "an unknown proposer verifies against its payload key, which must name it", %{
      now: now
    } do
      stranger = remote_install()

      assert {:ok, %{peer: nil, key_status: :payload}} =
               verify(
                 envelope(stranger, "relationship.propose", propose_payload(stranger), ts: now),
                 now
               )

      other = remote_install()

      # the payload key is someone else's: the envelope signature is not by it
      mismatched = propose_payload(stranger, %{"public_key" => other.b64})

      assert verify(envelope(stranger, "relationship.propose", mismatched, ts: now), now) ==
               {:error, :bad_signature}

      # the payload names a different install than `from`
      wrong_id = propose_payload(stranger, %{"install_id" => other.install_id})

      assert verify(envelope(stranger, "relationship.propose", wrong_id, ts: now), now) ==
               {:error, :malformed_key}
    end
  end

  describe "replay after a NonceCache wipe (a restart)" do
    test "outside the window it is refused by the timestamp check", %{remote: remote, now: now} do
      env = envelope(remote, "test.ping", %{}, ts: now)
      assert {:ok, _} = verify(env, now)

      NonceCache.reset()

      assert verify(env, now + 300_001) == {:error, :stale_timestamp}
    end

    test "inside the window it passes verify and is ONLY an idempotent no-op", %{now: now} do
      # This test proves the weaker of the two properties: with the cache
      # wiped, an in-window replay is NOT refused by verify/3. What holds is
      # that handling it again changes nothing.
      remote = remote_install()
      peer = peer_for!(remote, "pending_outbound")
      env = envelope(remote, "relationship.accept", %{}, ts: now)

      assert {:ok, verified} = verify(env, now)
      assert Inbound.handle(verified) == {:ok, :accepted}
      active = Peers.get_peer(peer.id)
      assert active.status == "active"

      NonceCache.reset()

      assert {:ok, replayed} = verify(env, now + 1_000)
      assert Inbound.handle(replayed) == {:ok, :already_applied}

      after_replay = Peers.get_peer(peer.id)
      assert after_replay.status == "active"
      assert after_replay.accepted_by_user_id == active.accepted_by_user_id
      assert length(Peers.list_peers()) == 2
    end
  end

  describe "protocol ids: suite-federation/1 and burrow-federation/2 (task 01a14ba9 stage 1)" do
    test "a v1-signed envelope verifies as suite-federation/1 (unchanged behaviour)", %{
      remote: remote,
      now: now
    } do
      {raw, headers} = envelope(remote, "test.ping", %{"note" => "v1"}, ts: now)

      assert List.keymember?(headers, "suite-federation-signature", 0)
      refute List.keymember?(headers, "burrow-federation-signature", 0)

      assert {:ok, %{protocol: "suite-federation/1", envelope: %{"v" => 1}}} =
               Envelope.verify(raw, headers, now)
    end

    test "a v2-signed envelope verifies as burrow-federation/2", %{remote: remote, now: now} do
      {raw, headers} = envelope_v2(remote, "test.ping", %{"note" => "v2"}, ts: now)

      assert List.keymember?(headers, "burrow-federation-signature", 0)
      refute List.keymember?(headers, "suite-federation-signature", 0)

      assert {:ok, %{protocol: "burrow-federation/2", envelope: body}} =
               Envelope.verify(raw, headers, now)

      # the body schema is unchanged: the protocol id names the signature domain only
      assert body["v"] == 1
      assert body["payload"] == %{"note" => "v2"}
    end

    test "the builder this install sends with still signs v1 only", %{remote: remote, now: now} do
      {_raw, headers} = envelope(remote, "test.ping", %{}, ts: now)

      assert Envelope.signature_header() == "suite-federation-signature"
      assert Envelope.signing_prefix() == "suite-federation/1\n"
      assert Envelope.signature_header(:v2) == "burrow-federation-signature"
      assert Envelope.signing_prefix(:v2) == "burrow-federation/2\n"
      assert [{"content-type", _}, {"suite-federation-signature", _}] = headers
    end

    test "a v1 signature in the v2 header is refused, and a v2 signature in the v1 header", %{
      remote: remote,
      now: now
    } do
      {raw, v1_headers} = envelope(remote, "test.ping", %{}, ts: now)
      v1_sig = signature(v1_headers, :v1)
      v2_sig = [] |> sign_headers(raw, remote.private_key, :v2) |> signature(:v2)

      # positive controls: each signature verifies under its own header
      assert {:ok, %{protocol: "suite-federation/1"}} =
               Envelope.verify(raw, [{"suite-federation-signature", v1_sig}], now)

      NonceCache.reset()

      assert {:ok, %{protocol: "burrow-federation/2"}} =
               Envelope.verify(raw, [{"burrow-federation-signature", v2_sig}], now)

      NonceCache.reset()

      # domain separation: swapped headers do not verify
      assert Envelope.verify(raw, [{"burrow-federation-signature", v1_sig}], now) ==
               {:error, :bad_signature}

      assert Envelope.verify(raw, [{"suite-federation-signature", v2_sig}], now) ==
               {:error, :bad_signature}
    end

    test "a bad v2 header beside a good v1 header is refused: no fallback to v1", %{
      remote: remote,
      now: now
    } do
      {raw, v1_headers} = envelope(remote, "test.ping", %{}, ts: now)
      {_pub, other_priv} = Ed25519.generate()
      bad_v2 = [] |> sign_headers(raw, other_priv, :v2) |> signature(:v2)

      both = with_signature(v1_headers, bad_v2, :v2)

      assert signature(both, :v1) == signature(v1_headers, :v1)
      assert Envelope.verify(raw, both, now) == {:error, :bad_signature}

      # control: the same request without the bad v2 header verifies on v1
      assert {:ok, %{protocol: "suite-federation/1"}} = Envelope.verify(raw, v1_headers, now)
    end

    test "a good v2 header beside a bad v1 header verifies as v2", %{remote: remote, now: now} do
      {raw, v2_headers} = envelope_v2(remote, "test.ping", %{}, ts: now)
      both = with_signature(v2_headers, "!!!", :v1)

      assert {:ok, %{protocol: "burrow-federation/2"}} = Envelope.verify(raw, both, now)
    end

    test "neither header is :missing_signature; an undecodable v2 header is :bad_signature", %{
      remote: remote,
      now: now
    } do
      {raw, v2_headers} = envelope_v2(remote, "test.ping", %{}, ts: now)

      assert Envelope.verify(raw, [{"content-type", "application/json"}], now) ==
               {:error, :missing_signature}

      assert Envelope.verify(raw, with_signature(v2_headers, "!!!", :v2), now) ==
               {:error, :bad_signature}
    end
  end

  describe "signing protocol choice (task 01a14ba9 stage 2)" do
    @v1_header "suite-federation-signature"
    @v2_header "burrow-federation-signature"
    @dual ["suite-federation/1", "burrow-federation/2"]

    defp signature_headers(headers) do
      for {name, _} <- headers, name in [@v1_header, @v2_header], do: name
    end

    # Signed AS `remote` toward this install, choosing the protocol for
    # `recipient`, so the result can go through the full verifier.
    defp build_for(recipient, remote, now) do
      %{install_id: local_id} = InstallIdentity.current()

      {:ok, env} =
        Envelope.build("test.ping", %{"n" => 1}, recipient,
          from: remote.install_id,
          signer: {remote.kid, remote.private_key},
          to: local_id,
          ts: now
        )

      env
    end

    test "flag unset + peer advertising v2: ONLY suite-federation-signature", %{
      remote: remote,
      peer: peer,
      now: now
    } do
      put_env_restored(:peer_federation_signing_protocol, nil)
      peer = advertise!(peer, @dual)

      {raw, headers} = build_for(peer, remote, now)

      assert signature_headers(headers) == [@v1_header]
      assert Envelope.signing_version(peer) == :v1
      assert {:ok, %{protocol: "suite-federation/1"}} = Envelope.verify(raw, headers, now)
    end

    test "flag v2 + peer advertising v2: ONLY burrow-federation-signature, and it verifies", %{
      remote: remote,
      peer: peer,
      now: now
    } do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")
      peer = advertise!(peer, @dual)

      {raw, headers} = build_for(peer, remote, now)

      assert signature_headers(headers) == [@v2_header]
      assert Envelope.signing_version(peer) == :v2
      assert {:ok, %{protocol: "burrow-federation/2"}} = Envelope.verify(raw, headers, now)
    end

    test "flag v2: this install's own key signs the v2 prefix, not the v1 one", %{peer: peer} do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")
      peer = advertise!(peer, @dual)
      me = InstallIdentity.current()

      {:ok, {raw, headers}} = Envelope.build("test.ping", %{}, peer)
      sig = headers |> signature(:v2) |> Base.url_decode64!(padding: false)

      assert signature_headers(headers) == [@v2_header]
      assert Ed25519.verify(Envelope.signing_prefix(:v2) <> raw, sig, me.public_key)
      refute Ed25519.verify(Envelope.signing_prefix(:v1) <> raw, sig, me.public_key)
    end

    test "flag v2 + a v1-only peer (no protocols metadata, or v1 alone): v1", %{
      remote: remote,
      peer: peer,
      now: now
    } do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")

      # positive control: the same flag signs v2 to the same peer once it advertises v2
      assert Envelope.signing_version(advertise!(peer, @dual)) == :v2

      no_metadata = %{peer | metadata: %{}}
      assert Envelope.signing_version(no_metadata) == :v1
      {raw, headers} = build_for(no_metadata, remote, now)
      assert signature_headers(headers) == [@v1_header]
      assert {:ok, %{protocol: "suite-federation/1"}} = Envelope.verify(raw, headers, now)

      v1_only = advertise!(peer, ["suite-federation/1"])
      assert Envelope.signing_version(v1_only) == :v1
      assert {_raw, headers} = build_for(v1_only, remote, now + 1)
      assert signature_headers(headers) == [@v1_header]
    end

    test "flag v2 + a bare install_id recipient always signs v1", %{
      remote: remote,
      now: now
    } do
      put_env_restored(:peer_federation_signing_protocol, "burrow-federation/2")

      assert Envelope.signing_version(remote.install_id) == :v1
      {_raw, headers} = build_for(remote.install_id, remote, now)
      assert signature_headers(headers) == [@v1_header]
    end

    test "a near-miss flag value signs v1 (app env and PEER_FEDERATION_SIGNING_PROTOCOL)", %{
      peer: peer
    } do
      peer = advertise!(peer, @dual)
      near_misses = ["burrow-federation/2 ", "BURROW-FEDERATION/2", "burrow-federation/1", ""]

      for value <- near_misses do
        put_env_restored(:peer_federation_signing_protocol, value)
        assert Envelope.signing_version(peer) == :v1, "app env #{inspect(value)} selected v2"
      end

      # the environment variable, read when the app env key is absent
      Application.delete_env(:platform, :peer_federation_signing_protocol)
      original = System.get_env("PEER_FEDERATION_SIGNING_PROTOCOL")

      on_exit(fn ->
        if original,
          do: System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", original),
          else: System.delete_env("PEER_FEDERATION_SIGNING_PROTOCOL")
      end)

      for value <- near_misses do
        System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", value)
        assert Envelope.signing_version(peer) == :v1, "env #{inspect(value)} selected v2"
      end

      # positive control: the exact string does select v2 through the variable
      System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", "burrow-federation/2")
      assert Envelope.signing_version(peer) == :v2
      {:ok, {_raw, headers}} = Envelope.build("test.ping", %{}, peer)
      assert signature_headers(headers) == [@v2_header]
    end
  end
end
