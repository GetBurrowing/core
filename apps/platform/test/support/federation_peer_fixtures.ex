defmodule Platform.FederationPeerFixtures do
  @moduledoc """
  Fixtures for install-to-install federation tests (task 01a0d90f stage 3).

  A "remote install" here is a generated Ed25519 keypair plus an install_id,
  held only in the test process. `envelope/4` signs AS that remote with the
  production builder (`Envelope.build/4` and its `:signer` option), so the
  positive controls in the envelope tests exercise the same builder that
  every refusal is measured against.

  Key material stays in test-process memory and is never logged.
  """

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.InstallIdentity

  @doc "Turns federation on for the calling test and restores the prior value on exit."
  def enable_federation!(opts \\ []) do
    for {key, value} <- [
          peer_federation_enabled: true,
          peer_federation_allow_http: Keyword.get(opts, :allow_http, false),
          peer_federation_base_url: Keyword.get(opts, :base_url, "https://local.example.test")
        ] do
      put_env_restored(key, value)
    end

    :ok
  end

  @doc "Sets an :platform app env key for this test and restores it on exit."
  def put_env_restored(key, value) do
    original = Application.fetch_env(:platform, key)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:platform, key, v)
        :error -> Application.delete_env(:platform, key)
      end
    end)

    Application.put_env(:platform, key, value)
  end

  @doc "A fresh remote install: `%{install_id, kid, public_key, private_key, b64}`."
  def remote_install(overrides \\ %{}) do
    {pub, priv} = Ed25519.generate()

    Map.merge(
      %{
        install_id: Platform.Types.UUIDv7.generate(),
        kid: "remote-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        public_key: pub,
        private_key: priv,
        b64: Base.url_encode64(pub, padding: false),
        base_url: "https://remote-#{System.unique_integer([:positive])}.example.test"
      },
      overrides
    )
  end

  @doc "A peer row for `remote` with its key, moved to `status` (default active)."
  def peer_for!(remote, status \\ "active") do
    initial = if status == "pending_inbound", do: "pending_inbound", else: "pending_outbound"

    {:ok, peer} =
      Peers.create_peer(%{
        peer_install_id: remote.install_id,
        base_url: remote.base_url,
        display_name: "Remote",
        status: initial,
        public_keys: [%{kid: remote.kid, public_key: remote.b64}]
      })

    case status do
      s when s in ["pending_outbound", "pending_inbound"] ->
        peer

      "active" ->
        {:ok, peer} = Peers.activate(peer)
        peer

      "revoked" ->
        {:ok, peer} = Peers.activate(peer)
        {:ok, peer} = Peers.mark_revoked(peer, :local)
        peer
    end
  end

  @doc """
  A signed envelope FROM `remote` TO this install. Returns `{raw, headers}`.
  `opts` pass through to `Envelope.build/4` (`:ts`, `:nonce`, `:to`, `:signer`).
  """
  def envelope(remote, type, payload \\ %{}, opts \\ []) do
    %{install_id: local_id} = InstallIdentity.ensure!()

    opts =
      Keyword.merge(
        [from: remote.install_id, signer: {remote.kid, remote.private_key}],
        opts
      )

    {:ok, {raw, headers}} = Envelope.build(type, payload, local_id, opts)
    {raw, headers}
  end

  @doc """
  The same envelope as `envelope/4`, signed under `burrow-federation/2`
  (task 01a14ba9 stage 1): the signature covers the v2 prefix and travels in
  the v2 header ONLY. The body is the builder's, byte for byte. A `:signer`
  in `opts` signs the v2 signature too.
  """
  def envelope_v2(remote, type, payload \\ %{}, opts \\ []) do
    {raw, headers} = envelope(remote, type, payload, opts)
    {_kid, private_key} = Keyword.get(opts, :signer, {remote.kid, remote.private_key})
    {raw, sign_headers(headers, raw, private_key, :v2)}
  end

  @doc """
  `headers` with every signature header removed and one signature over
  `raw` under `version` (`:v1` or `:v2`) added in that version's header.
  """
  def sign_headers(headers, raw, private_key, version) do
    value =
      (Envelope.signing_prefix(version) <> raw)
      |> Ed25519.sign(private_key)
      |> Base.url_encode64(padding: false)

    headers
    |> List.keydelete(Envelope.signature_header(:v1), 0)
    |> List.keydelete(Envelope.signature_header(:v2), 0)
    |> List.keystore(
      Envelope.signature_header(version),
      0,
      {Envelope.signature_header(version), value}
    )
  end

  @doc "The `relationship.propose` payload `remote` would send."
  def propose_payload(remote, overrides \\ %{}) do
    Map.merge(
      %{
        "install_id" => remote.install_id,
        "kid" => remote.kid,
        "public_key" => remote.b64,
        "base_url" => remote.base_url,
        "display_name" => "Remote install"
      },
      overrides
    )
  end

  @doc "The descriptor `remote` would serve at its `.well-known`."
  def descriptor(remote, overrides \\ %{}) do
    Map.merge(
      %{
        "protocol" => "suite-federation/1",
        "install_id" => remote.install_id,
        "display_name" => "Remote install",
        "base_url" => remote.base_url,
        "inbox" => remote.base_url <> "/federation/v1/inbox",
        "keys" => [%{"kid" => remote.kid, "alg" => "ed25519", "public_key" => remote.b64}]
      },
      overrides
    )
  end

  @doc "Signature header value of a header list (`version` `:v1` default, or `:v2`)."
  def signature(headers, version \\ :v1) do
    {_, value} = List.keyfind(headers, Envelope.signature_header(version), 0)
    value
  end

  @doc "Replaces (or adds) the signature header of `version` (`:v1` default, or `:v2`)."
  def with_signature(headers, value, version \\ :v1) do
    header = Envelope.signature_header(version)
    List.keystore(headers, header, 0, {header, value})
  end

  @doc """
  Stores `protocols` as what `peer` advertised (`metadata["protocols"]`,
  task 01a14ba9 stage 2) and returns the updated row.
  """
  def advertise!(peer, protocols) do
    {:ok, peer} =
      peer
      |> Platform.Federation.Peers.Peer.update_changeset(%{
        metadata: Map.put(peer.metadata || %{}, "protocols", protocols)
      })
      |> Platform.Repo.update()

    peer
  end

  @doc "Resolve every host in `map` statically (host => [ip tuple]) for this test."
  def resolve!(map), do: put_env_restored(:peer_federation_resolver, map)
end
