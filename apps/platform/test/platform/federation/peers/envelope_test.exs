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
end
