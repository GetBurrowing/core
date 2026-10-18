defmodule Platform.Federation.Peers.ProtocolReadinessTest do
  @moduledoc """
  Task 01a14ba9 stage 2: `Peers.protocol_readiness/0`, the gate for turning
  on `PEER_FEDERATION_SIGNING_PROTOCOL=burrow-federation/2`. Each active
  peer's descriptor is re-fetched; its advertised protocols are stored and
  reported, and `ready` is true only for a peer that advertises v2.
  """

  # async: false — flips global app env.
  use Platform.DataCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.InstallIdentity

  @dual ["suite-federation/1", "burrow-federation/2"]

  setup do
    enable_federation!()
    InstallIdentity.ensure!()
    :ok
  end

  defp host(remote), do: URI.parse(remote.base_url).host

  # Serve one descriptor per pinned IP, so each peer answers for itself.
  defp serve(by_ip) do
    Req.Test.stub(Client, fn conn ->
      case Map.fetch(by_ip, conn.host) do
        {:ok, desc} -> Req.Test.json(conn, desc)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp row(rows, peer), do: Enum.find(rows, &(&1.peer_install_id == peer.peer_install_id))

  test "a v1-only peer is not ready, a dual peer is, and metadata is refreshed" do
    old = remote_install()
    new = remote_install()
    resolve!(%{host(old) => [{93, 184, 216, 34}], host(new) => [{93, 184, 216, 35}]})

    # stored values that the refresh must overwrite, in both directions
    old_peer = old |> peer_for!() |> advertise!(@dual)
    new_peer = peer_for!(new)
    assert new_peer.metadata["protocols"] == nil

    serve(%{
      "93.184.216.34" => descriptor(old),
      "93.184.216.35" => descriptor(new, %{"protocols" => @dual})
    })

    rows = Peers.protocol_readiness()
    assert length(rows) == 2

    assert row(rows, old_peer) == %{
             peer_install_id: old.install_id,
             base_url: old.base_url,
             protocols: ["suite-federation/1"],
             ready: false,
             error: nil
           }

    assert row(rows, new_peer) == %{
             peer_install_id: new.install_id,
             base_url: new.base_url,
             protocols: @dual,
             ready: true,
             error: nil
           }

    assert Peers.get_peer(old_peer.id).metadata["protocols"] == ["suite-federation/1"]
    assert Peers.get_peer(new_peer.id).metadata["protocols"] == @dual
  end

  test "only active peers are checked" do
    pending = remote_install()
    revoked = remote_install()
    resolve!(%{host(pending) => [{93, 184, 216, 34}], host(revoked) => [{93, 184, 216, 35}]})
    _ = peer_for!(pending, "pending_outbound")
    _ = peer_for!(revoked, "revoked")

    serve(%{
      "93.184.216.34" => descriptor(pending, %{"protocols" => @dual}),
      "93.184.216.35" => descriptor(revoked, %{"protocols" => @dual})
    })

    assert Peers.protocol_readiness() == []
  end

  test "an unreachable peer or a descriptor for another install is not ready and keeps metadata" do
    gone = remote_install()
    moved = remote_install()
    # `gone` resolves nowhere (the test resolver map omits it)
    resolve!(%{host(moved) => [{93, 184, 216, 35}]})

    gone_peer = gone |> peer_for!() |> advertise!(@dual)
    moved_peer = moved |> peer_for!() |> advertise!(@dual)

    serve(%{
      "93.184.216.35" =>
        descriptor(moved, %{
          "install_id" => Platform.Types.UUIDv7.generate(),
          "protocols" => @dual
        })
    })

    rows = Peers.protocol_readiness()

    assert %{ready: false, error: :unresolvable, protocols: @dual} = row(rows, gone_peer)
    assert %{ready: false, error: :install_id_mismatch, protocols: @dual} = row(rows, moved_peer)

    assert Peers.get_peer(gone_peer.id).metadata["protocols"] == @dual
    assert Peers.get_peer(moved_peer.id).metadata["protocols"] == @dual
  end

  test "descriptor_protocols bounds what a peer advertises" do
    long = String.duplicate("x", 65)

    assert Peers.descriptor_protocols(%{
             "protocols" => ["burrow-federation/2", 7, long, "", "burrow-federation/2"]
           }) == ["burrow-federation/2"]

    assert Peers.descriptor_protocols(%{"protocol" => "suite-federation/1"}) ==
             ["suite-federation/1"]

    assert length(Peers.descriptor_protocols(%{"protocols" => Enum.map(1..40, &"p#{&1}")})) ==
             16

    assert Peers.descriptor_protocols(%{}) == []
  end
end
