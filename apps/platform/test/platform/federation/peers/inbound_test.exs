defmodule Platform.Federation.Peers.InboundTest do
  @moduledoc """
  Task 01a0d90f stage 3 (ADR 0054 section 1): the relationship handshake
  handlers, fed through the real `Envelope.verify/3`.

  The propose binding has a POSITIVE CONTROL: the same proposal with a
  matching `.well-known` is recorded, so the mismatch refusal is not an
  artefact of a descriptor stub that never matches.
  """

  # async: false — flips global app env and uses the named NonceCache table.
  use Platform.DataCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.Inbound
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache

  @public {93, 184, 216, 34}

  setup do
    enable_federation!()
    NonceCache.reset()
    on_exit(&NonceCache.reset/0)
    InstallIdentity.ensure!()
    :ok
  end

  defp deliver(remote, type, payload, opts \\ []) do
    now = System.system_time(:millisecond)
    {raw, headers} = envelope(remote, type, payload, Keyword.put_new(opts, :ts, now))

    with {:ok, verified} <- Envelope.verify(raw, headers, now) do
      Inbound.handle(verified)
    end
  end

  # Serve `descriptor` at every host and report each fetch to the test.
  defp serve_descriptor(descriptor) do
    test_pid = self()

    Req.Test.stub(Client, fn conn ->
      send(test_pid, {:descriptor_fetch, conn.host, conn.request_path})
      Req.Test.json(conn, descriptor)
    end)
  end

  defp host(remote), do: URI.parse(remote.base_url).host

  describe "relationship.propose" do
    test "POSITIVE CONTROL: a proposal whose .well-known matches is recorded pending" do
      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:ok, :proposal_recorded}

      assert_received {:descriptor_fetch, "93.184.216.34", "/.well-known/suite-federation"}

      peer = Peers.get_peer_by_install_id(remote.install_id)
      assert peer.status == "pending_inbound"
      assert peer.base_url == remote.base_url
      assert [%{kid: kid, public_key: pub, status: "current"}] = peer.public_keys
      assert {kid, pub} == {remote.kid, remote.b64}
    end

    test "a recorded proposal stores the protocols its .well-known advertises (01a14ba9)" do
      dual = ["suite-federation/1", "burrow-federation/2"]
      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote, %{"protocols" => dual}))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:ok, :proposal_recorded}

      assert Peers.get_peer_by_install_id(remote.install_id).metadata["protocols"] == dual

      # a proposer whose descriptor has no list is stored v1-only
      old = remote_install()
      resolve!(%{host(old) => [@public]})
      serve_descriptor(descriptor(old))

      assert deliver(old, "relationship.propose", propose_payload(old)) ==
               {:ok, :proposal_recorded}

      assert Peers.get_peer_by_install_id(old.install_id).metadata["protocols"] ==
               ["suite-federation/1"]
    end

    test "a proposal whose key does not match the sender's .well-known is refused" do
      remote = remote_install()
      resolve!(%{host(remote) => [@public]})

      # the domain serves a DIFFERENT key under the same kid
      serve_descriptor(
        descriptor(remote, %{
          "keys" => [
            %{"kid" => remote.kid, "alg" => "ed25519", "public_key" => remote_install().b64}
          ]
        })
      )

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:error, :descriptor_mismatch}

      assert Peers.get_peer_by_install_id(remote.install_id) == nil
    end

    test "a proposal whose .well-known names another install is refused" do
      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote, %{"install_id" => Platform.Types.UUIDv7.generate()}))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:error, :descriptor_mismatch}

      assert Peers.list_peers() == []
    end

    test "a proposal pointing at an internal address is refused with no fetch" do
      remote = remote_install(%{base_url: "https://169.254.169.254"})
      serve_descriptor(descriptor(remote))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:error, :descriptor_unavailable}

      refute_received {:descriptor_fetch, _, _}
      assert Peers.list_peers() == []
    end

    test "the hourly cap is checked BEFORE the fetch" do
      for _ <- 1..Inbound.proposal_cap(), do: peer_for!(remote_install(), "pending_inbound")

      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:error, :proposal_rate_limited}

      refute_received {:descriptor_fetch, _, _}
      assert Peers.get_peer_by_install_id(remote.install_id) == nil
    end

    test "the per-hour FETCH cap also holds when no proposal is ever recorded" do
      now = System.system_time(:millisecond)
      for _ <- 1..Inbound.fetch_cap(), do: NonceCache.count_propose_fetch(now)

      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:error, :proposal_rate_limited}

      refute_received {:descriptor_fetch, _, _}

      # control: after a wipe the same proposal is fetched and recorded
      NonceCache.reset()

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:ok, :proposal_recorded}

      assert_received {:descriptor_fetch, _, _}
    end

    test "a re-delivered proposal is an idempotent no-op; a known active peer's is refused" do
      remote = remote_install()
      resolve!(%{host(remote) => [@public]})
      serve_descriptor(descriptor(remote))

      assert {:ok, :proposal_recorded} =
               deliver(remote, "relationship.propose", propose_payload(remote))

      assert deliver(remote, "relationship.propose", propose_payload(remote)) ==
               {:ok, :already_applied}

      assert length(Peers.list_peers()) == 1

      active = remote_install()
      peer_for!(active)

      assert deliver(active, "relationship.propose", propose_payload(active)) ==
               {:error, :already_known}
    end
  end

  describe "relationship.accept and revoke" do
    test "accept moves our pending_outbound row to active" do
      remote = remote_install()
      peer = peer_for!(remote, "pending_outbound")

      assert deliver(remote, "relationship.accept", %{}) == {:ok, :accepted}
      assert Peers.get_peer(peer.id).status == "active"
    end

    test "a proposer cannot accept its own proposal" do
      remote = remote_install()
      peer = peer_for!(remote, "pending_inbound")

      assert deliver(remote, "relationship.accept", %{}) == {:error, :invalid_transition}
      assert Peers.get_peer(peer.id).status == "pending_inbound"
    end

    test "revoke marks the row revoked by the peer, and nothing verifies after it" do
      remote = remote_install()
      peer = peer_for!(remote)

      assert deliver(remote, "relationship.revoke", %{}) == {:ok, :revoked}

      revoked = Peers.get_peer(peer.id)
      assert {revoked.status, revoked.revoked_by} == {"revoked", "peer"}

      assert deliver(remote, "relationship.accept", %{}) == {:error, :peer_revoked}
    end
  end

  describe "key.rotate" do
    test "signed by a current kid adds the new kid; the old one keeps its overlap" do
      remote = remote_install()
      peer = peer_for!(remote)
      next = remote_install()

      assert deliver(remote, "key.rotate", %{"kid" => next.kid, "public_key" => next.b64}) ==
               {:ok, :key_rotated}

      keys = Map.new(Peers.get_peer(peer.id).public_keys, &{&1.kid, &1})
      assert keys[next.kid].status == "current"
      assert keys[remote.kid].status == "previous"
      assert DateTime.diff(keys[remote.kid].valid_until, DateTime.utc_now()) > 6 * 86_400

      # re-delivery under the demoted kid is refused: it is no longer current
      assert deliver(remote, "key.rotate", %{"kid" => next.kid, "public_key" => next.b64}) ==
               {:error, :rotation_needs_current_kid}

      # the NEW key (now current) re-announcing itself is a no-op
      assert deliver(next |> Map.put(:install_id, remote.install_id), "key.rotate", %{
               "kid" => next.kid,
               "public_key" => next.b64
             }) == {:ok, :already_applied}
    end

    test "signed by a previous kid is refused" do
      remote = remote_install()
      peer = peer_for!(remote)
      {:ok, _} = Peers.add_peer_key(peer, "newer", remote_install().b64, 3600)
      another = remote_install()

      assert deliver(remote, "key.rotate", %{"kid" => another.kid, "public_key" => another.b64}) ==
               {:error, :rotation_needs_current_kid}
    end
  end
end
