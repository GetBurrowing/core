defmodule Platform.Federation.PeersTest do
  @moduledoc "Task 01a0d90f stage 2: local peer CRUD and state transitions."

  # async: false — some tests flip the global :env / allow_http app env.
  use Platform.DataCase, async: false

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Peer

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp b64(pub), do: Base.url_encode64(pub, padding: false)

  defp peer_attrs(overrides \\ %{}) do
    {pub, _} = Ed25519.generate()

    Map.merge(
      %{
        peer_install_id: Platform.Types.UUIDv7.generate(),
        base_url: "https://peer.example.test",
        display_name: "Peer",
        status: "pending_outbound",
        public_keys: [%{kid: "k1", public_key: b64(pub)}]
      },
      overrides
    )
  end

  test "creates a pending peer with a stored key" do
    assert {:ok, %Peer{status: "pending_outbound"} = peer} = Peers.create_peer(peer_attrs())
    assert [%{kid: "k1", status: "current", added_at: %DateTime{}}] = peer.public_keys
    assert Peers.get_peer_by_install_id(peer.peer_install_id).id == peer.id
    assert [%Peer{}] = Peers.list_peers(status: "pending_outbound")
  end

  test "peer_install_id is unique" do
    attrs = peer_attrs()
    assert {:ok, _} = Peers.create_peer(attrs)
    assert {:error, changeset} = Peers.create_peer(attrs)
    assert %{peer_install_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "a peer cannot be created active or revoked" do
    assert {:error, cs} = Peers.create_peer(peer_attrs(%{status: "active"}))
    assert %{status: [_]} = errors_on(cs)
  end

  test "a malformed public key is refused" do
    assert {:error, cs} =
             Peers.create_peer(peer_attrs(%{public_keys: [%{kid: "k1", public_key: "nope"}]}))

    assert %{public_keys: [%{public_key: [_]}]} = errors_on(cs)
  end

  test "http base_url is refused unless allow_http? (never in prod)" do
    env = Application.fetch_env!(:platform, :env)
    allow = Application.fetch_env(:platform, :peer_federation_allow_http)

    on_exit(fn ->
      Application.put_env(:platform, :env, env)

      case allow do
        {:ok, v} -> Application.put_env(:platform, :peer_federation_allow_http, v)
        :error -> Application.delete_env(:platform, :peer_federation_allow_http)
      end
    end)

    Application.put_env(:platform, :peer_federation_allow_http, true)
    Application.put_env(:platform, :env, :prod)
    assert {:error, cs} = Peers.create_peer(peer_attrs(%{base_url: "http://peer:4000"}))
    assert %{base_url: ["must be https"]} = errors_on(cs)

    # Positive control: the same attrs are accepted outside prod.
    Application.put_env(:platform, :env, :test)
    assert {:ok, _} = Peers.create_peer(peer_attrs(%{base_url: "http://peer:4000"}))
  end

  test "pending -> active -> revoked, and revoked is terminal" do
    {:ok, peer} = Peers.create_peer(peer_attrs(%{status: "pending_inbound"}))

    assert {:ok, %Peer{status: "active"} = active} = Peers.activate(peer)
    assert {:error, {:invalid_transition, "active", "active"}} = Peers.activate(active)

    assert {:ok, %Peer{status: "revoked", revoked_by: "local", revoked_at: %DateTime{}} = revoked} =
             Peers.mark_revoked(active, :local)

    assert {:error, {:invalid_transition, "revoked", "active"}} = Peers.activate(revoked)

    assert {:error, {:invalid_transition, "revoked", "revoked"}} =
             Peers.mark_revoked(revoked, :peer)
  end

  test "peer key rotation keeps the old kid verifying until its overlap ends" do
    {:ok, peer} = Peers.create_peer(peer_attrs())
    {new_pub, _} = Ed25519.generate()

    assert {:ok, peer} = Peers.add_peer_key(peer, "k2", b64(new_pub), 3600)
    assert {:error, :duplicate_kid} = Peers.add_peer_key(peer, "k2", b64(new_pub), 3600)

    now = DateTime.utc_now()
    assert {:ok, ^new_pub} = Peers.verification_key(peer, "k2", now)
    assert {:ok, _old} = Peers.verification_key(peer, "k1", now)
    assert {:error, :expired_kid} = Peers.verification_key(peer, "k1", DateTime.add(now, 7200))
    assert {:error, :unknown_kid} = Peers.verification_key(peer, "k9", now)

    # Survives a reload from jsonb.
    reloaded = Peers.get_peer(peer.id)

    assert Enum.map(reloaded.public_keys, &{&1.kid, &1.status}) == [
             {"k1", "previous"},
             {"k2", "current"}
           ]

    assert {:ok, retired} = Peers.retire_peer_key(reloaded, "k2")
    assert {:error, :retired_kid} = Peers.verification_key(retired, "k2", now)
    assert {:ok, _} = Peers.verification_key(retired, "k1", now)
  end
end
