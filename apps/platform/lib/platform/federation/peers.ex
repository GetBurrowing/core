defmodule Platform.Federation.Peers do
  @moduledoc """
  Peer installs for install-to-install federation (task 01a0d90f, ADR 0054).

  Local state (stage 2): this module creates, reads and transitions
  `federation_peers` rows and manages each peer's stored public keys.

  The signed handshake (stage 3) sits on top: `propose/2`, `accept/2`,
  `revoke/2` and `rotate_key/0` send envelopes through
  `Platform.Federation.Peers.Client`; the receiving side's handlers live in
  `Platform.Federation.Peers.Inbound`.

  ## Revocation holds without the peer

  `revoke/2` persists `revoked` BEFORE it sends the best-effort notice, and
  `Platform.Federation.Peers.Envelope.verify/3` refuses every envelope from a
  revoked peer. So inbound stops the moment the row is written, whether or
  not the notice arrives. A pending peer may send only the handshake types
  (`Envelope.handshake_types/0`).

  ## Transitions

      pending_outbound ──activate──▶ active
      pending_inbound  ──activate──▶ active
      any non-revoked  ──revoke────▶ revoked   (terminal)

  Everything else is refused with `{:error, {:invalid_transition, from, to}}`.

  ## Connections (stage 4)

  `activate/2` starts the peer's `Platform.Federation.Peers.PeerConnection`
  (through `Platform.Federation.Peers.Boot`, so only when federation is on)
  and `mark_revoked/2` stops it, dropping its queue.
  Revocation is terminal on purpose: re-establishing trust with a revoked
  install is a fresh proposal, not an un-revoke.

  ## Shared spaces (stage 5)

  `share_space/3` shares a local channel with an active peer (this install
  becomes its `owner`); the peer's `space.share` handler creates the replica.
  `mark_revoked/2` also marks every shared space of the relationship
  `revoked`. The relay itself runs in the peer's `PeerConnection`.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Federation.Peers.Boot
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.PeerKey
  alias Platform.Federation.Peers.SharedSpace
  alias Platform.Federation.Peers.SharedSpaces
  alias Platform.Federation.Peers.Supervisor, as: PeerSupervisor
  alias Platform.Repo

  @doc """
  Creates a peer row. `attrs` needs `peer_install_id`, `base_url` and
  `status` (`pending_outbound` or `pending_inbound`), and may carry
  `display_name`, `metadata` and `public_keys` (`[%{kid, public_key}]`,
  public_key in unpadded base64url).

  `base_url` must be https unless `Config.allow_http?/0`.
  """
  @spec create_peer(map()) :: {:ok, Peer.t()} | {:error, Ecto.Changeset.t()}
  def create_peer(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.update("public_keys", [], fn keys ->
        Enum.map(keys, fn key ->
          key
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.put_new("added_at", now)
        end)
      end)

    %Peer{}
    |> Peer.create_changeset(attrs)
    |> require_https_unless_allowed()
    |> Repo.insert()
  end

  @spec get_peer(String.t()) :: Peer.t() | nil
  def get_peer(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Peer, id)
  end

  @spec get_peer_by_install_id(String.t()) :: Peer.t() | nil
  def get_peer_by_install_id(install_id) do
    if Platform.UUID.valid?(install_id), do: Repo.get_by(Peer, peer_install_id: install_id)
  end

  @doc "Lists peers, optionally filtered by `status:`."
  @spec list_peers(keyword()) :: [Peer.t()]
  def list_peers(opts \\ []) do
    Peer
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [p], p.status == ^status)
      end
    end)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  Moves a pending peer to `active`. `accepted_by_user_id` records the local
  admin who accepted, or nil when the peer accepted our proposal.
  """
  @spec activate(Peer.t(), String.t() | nil) ::
          {:ok, Peer.t()} | {:error, term()}
  def activate(peer, accepted_by_user_id \\ nil)

  def activate(%Peer{status: status} = peer, accepted_by_user_id)
      when status in ["pending_outbound", "pending_inbound"] do
    result =
      peer
      |> Peer.update_changeset(%{status: "active", accepted_by_user_id: accepted_by_user_id})
      |> Repo.update()

    # Stage 4: an activated peer gets its connection now rather than at the
    # next re-scan. A no-op when federation is off (Boot is not running).
    with {:ok, active} <- result, do: Boot.peer_activated(active)

    result
  end

  def activate(%Peer{status: status}, _), do: {:error, {:invalid_transition, status, "active"}}

  @doc """
  Marks a peer `revoked`. `by` is `:local` (this install revoked) or `:peer`
  (the peer told us it revoked). Terminal.
  """
  @spec mark_revoked(Peer.t(), :local | :peer) :: {:ok, Peer.t()} | {:error, term()}
  def mark_revoked(%Peer{status: "revoked"}, _by),
    do: {:error, {:invalid_transition, "revoked", "revoked"}}

  def mark_revoked(%Peer{} = peer, by) when by in [:local, :peer] do
    result =
      peer
      |> Peer.update_changeset(%{
        status: "revoked",
        revoked_by: to_string(by),
        revoked_at: DateTime.utc_now()
      })
      |> Repo.update()

    # Stage 4: the peer's connection, and with it its queue, stops once the
    # row says revoked. Both revoke paths (ours, `revoke/2`, and the peer's
    # `relationship.revoke`) pass through here.
    with {:ok, _revoked} <- result do
      PeerSupervisor.stop_peer(peer.id)
      # Stage 5: the relationship's shared spaces stop relaying with it.
      SharedSpaces.revoke_for_peer(peer.id)
    end

    result
  end

  @spec touch_last_seen(Peer.t()) :: {:ok, Peer.t()} | {:error, Ecto.Changeset.t()}
  def touch_last_seen(%Peer{} = peer) do
    peer
    |> Peer.update_changeset(%{last_seen_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Adds a new current key for a peer (its rotation). Every existing `current`
  key becomes `previous` with `valid_until` = now + `overlap_seconds`.
  Adding a kid the peer already has is refused.
  """
  @spec add_peer_key(Peer.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, Peer.t()} | {:error, term()}
  def add_peer_key(%Peer{} = peer, kid, public_key_b64url, overlap_seconds) do
    if Enum.any?(peer.public_keys, &(&1.kid == kid)) do
      {:error, :duplicate_kid}
    else
      now = DateTime.utc_now()
      valid_until = DateTime.add(now, overlap_seconds, :second)

      demoted =
        Enum.map(peer.public_keys, fn
          %PeerKey{status: "current"} = key ->
            PeerKey.changeset(key, %{status: "previous", valid_until: valid_until})

          key ->
            key
        end)

      new_key =
        PeerKey.changeset(%PeerKey{}, %{
          kid: kid,
          public_key: public_key_b64url,
          status: "current",
          added_at: now
        })

      if new_key.valid? do
        peer
        |> Peer.keys_changeset(demoted ++ [new_key])
        |> Repo.update()
      else
        {:error, new_key}
      end
    end
  end

  @doc "Retires one peer kid immediately, leaving the relationship intact."
  @spec retire_peer_key(Peer.t(), String.t()) :: {:ok, Peer.t()} | {:error, term()}
  def retire_peer_key(%Peer{} = peer, kid) do
    if Enum.any?(peer.public_keys, &(&1.kid == kid)) do
      keys =
        Enum.map(peer.public_keys, fn
          %PeerKey{kid: ^kid} = key -> PeerKey.changeset(key, %{status: "retired"})
          key -> key
        end)

      peer |> Peer.keys_changeset(keys) |> Repo.update()
    else
      {:error, :unknown_kid}
    end
  end

  @doc """
  The raw public key that verifies `kid` for `peer` at `now`, or an error
  naming why not. A `current` key verifies; a `previous` key verifies until
  its `valid_until`; a `retired` key never does.
  """
  @spec verification_key(Peer.t(), String.t(), DateTime.t()) ::
          {:ok, binary()} | {:error, :unknown_kid | :retired_kid | :expired_kid | :malformed_key}
  def verification_key(%Peer{public_keys: keys}, kid, now \\ DateTime.utc_now()) do
    case Enum.find(keys, &(&1.kid == kid)) do
      nil ->
        {:error, :unknown_kid}

      %PeerKey{status: "retired"} ->
        {:error, :retired_kid}

      %PeerKey{status: "previous", valid_until: until}
      when is_nil(until) ->
        {:error, :expired_kid}

      %PeerKey{status: "previous", valid_until: until} = key ->
        if DateTime.compare(now, until) == :lt, do: decode(key), else: {:error, :expired_kid}

      %PeerKey{} = key ->
        decode(key)
    end
  end

  @doc "Deletes a peer row. Used to undo a proposal that never reached the peer."
  @spec delete_peer(Peer.t()) :: {:ok, Peer.t()} | {:error, Ecto.Changeset.t()}
  def delete_peer(%Peer{} = peer), do: Repo.delete(peer)

  @doc "How many `pending_inbound` rows were created at or after `since`."
  @spec count_inbound_proposals_since(DateTime.t()) :: non_neg_integer()
  def count_inbound_proposals_since(%DateTime{} = since) do
    from(p in Peer, where: p.status == "pending_inbound" and p.inserted_at >= ^since)
    |> Repo.aggregate(:count)
  end

  # ── Signed handshake (stage 3) ─────────────────────────────────────────

  @doc """
  Proposes a relationship to the install at `base_url`.

  Fetches its descriptor, records a `pending_outbound` row holding the
  descriptor's keys, and sends a `relationship.propose` envelope carrying this
  install's id, kid, public key and base URL. If the peer does not accept the
  delivery (non-2xx or transport error) the row is deleted, so a later retry
  starts clean. `opts` may carry `:display_name` for the local row.
  """
  @spec propose(String.t(), keyword()) :: {:ok, Peer.t()} | {:error, term()}
  def propose(base_url, opts \\ []) when is_binary(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    with :ok <- require_enabled(),
         me = InstallIdentity.ensure!(),
         {:ok, descriptor} <- Client.fetch_descriptor(base_url),
         {:ok, keys} <- descriptor_keys(descriptor),
         :ok <- not_self(descriptor, me),
         {:ok, peer} <-
           create_peer(%{
             peer_install_id: descriptor["install_id"],
             base_url: base_url,
             display_name: Keyword.get(opts, :display_name, descriptor["display_name"]),
             status: "pending_outbound",
             public_keys: keys
           }) do
      payload = %{
        "install_id" => me.install_id,
        "kid" => me.kid,
        "public_key" => Base.url_encode64(me.public_key, padding: false),
        "base_url" => Config.base_url(),
        "display_name" => me.display_name
      }

      case deliver("relationship.propose", payload, peer, []) do
        :ok ->
          {:ok, peer}

        {:error, reason} ->
          _ = delete_peer(peer)
          {:error, reason}
      end
    end
  end

  @doc """
  Accepts a `pending_inbound` proposal. Call only after a local admin has
  compared the peer's fingerprint out of band. Sends `relationship.accept`
  and activates the row once the peer has taken delivery, so both sides move
  to `active` together; a failed delivery leaves the row pending for a retry.
  """
  @spec accept(Peer.t(), String.t() | nil) :: {:ok, Peer.t()} | {:error, term()}
  def accept(%Peer{status: "pending_inbound"} = peer, accepted_by_user_id) do
    with :ok <- require_enabled(),
         :ok <- deliver("relationship.accept", %{}, peer, []) do
      activate(peer, accepted_by_user_id)
    end
  end

  def accept(%Peer{status: status}, _), do: {:error, {:invalid_transition, status, "active"}}

  @doc """
  Revokes a relationship unilaterally. `revoked` is PERSISTED FIRST; the
  `relationship.revoke` notice is sent afterwards on a best-effort basis and
  its outcome does not change the result. From the moment the row is written
  this install refuses the peer's envelopes (see the moduledoc).

  `opts`: `notify: false` skips the notice.
  """
  @spec revoke(Peer.t(), keyword()) :: {:ok, Peer.t()} | {:error, term()}
  def revoke(%Peer{} = peer, opts \\ []) do
    with {:ok, revoked} <- mark_revoked(peer, :local) do
      if Keyword.get(opts, :notify, true) and Config.enabled?() do
        case deliver("relationship.revoke", %{}, revoked, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.info(
              "[federation] revoke notice not delivered peer_install_id=" <>
                "#{revoked.peer_install_id} reason=#{inspect(reason)}"
            )
        end
      end

      {:ok, revoked}
    end
  end

  @doc """
  Rotates this install's signing key and announces the new kid to every
  active peer with a `key.rotate` envelope signed by the OLD key, the key
  those peers currently trust. Returns the new identity and one delivery
  result per active peer.
  """
  @spec rotate_key() ::
          {:ok, InstallIdentity.current(), [{String.t(), :ok | {:error, term()}}]}
  def rotate_key do
    old = InstallIdentity.ensure!()
    new = InstallIdentity.rotate!()

    payload = %{
      "kid" => new.kid,
      "public_key" => Base.url_encode64(new.public_key, padding: false)
    }

    results =
      for peer <- list_peers(status: "active") do
        {peer.id, deliver("key.rotate", payload, peer, signer: {:install, old.kid})}
      end

    {:ok, new, results}
  end

  # ── Shared spaces (stage 5) ────────────────────────────────────────────

  @shareable_kinds ~w(channel group)

  @doc """
  Shares the local space `space_id` with the active `peer`. This install
  becomes the space's `owner`.

  Sends `space.share` (the space's id and name) synchronously through
  `Client.send_envelope/3`, like the handshake, because the answer carries
  the peer's replica space id; the `owner` row is recorded only after the
  peer has created the replica. Its cursor starts at the space's newest
  message at the time of the share, so earlier history is not replicated in
  v1; a message posted while the share is in flight is after that cursor and
  is replayed once the connection picks the row up.

  Refused: a revoked or pending peer, a DM or execution space, an archived
  space, or a space already shared (v1 shares a space with one peer).
  `opts`: `:name` overrides the name sent to the peer.
  """
  @spec share_space(Peer.t(), String.t(), keyword()) ::
          {:ok, SharedSpace.t()} | {:error, term()}
  def share_space(peer, space_id, opts \\ [])

  def share_space(%Peer{status: "active"} = peer, space_id, opts) do
    with :ok <- require_enabled(),
         {:ok, space} <- shareable_space(space_id),
         :ok <- not_already_shared(space.id) do
      cursor = SharedSpaces.latest_message_id(space.id)
      payload = %{"space_id" => space.id, "name" => Keyword.get(opts, :name, space.name)}

      with {:ok, {raw, headers}} <- Envelope.build("space.share", payload, peer, []),
           {:ok, response} <- Client.send_envelope(peer, raw, headers),
           {:ok, remote_space_id} <- replica_space_id(response),
           {:ok, shared} <- SharedSpaces.create_owner(peer, space.id, remote_space_id, cursor) do
        PeerConnection.refresh(peer.id)
        {:ok, shared}
      end
    end
  end

  def share_space(%Peer{status: status}, _space_id, _opts),
    do: {:error, {:peer_not_active, status}}

  defp shareable_space(space_id) do
    case Chat.get_space(space_id) do
      nil -> {:error, :space_not_found}
      %Space{archived_at: archived} when not is_nil(archived) -> {:error, :space_archived}
      %Space{kind: kind} = space when kind in @shareable_kinds -> {:ok, space}
      %Space{} -> {:error, :space_not_shareable}
    end
  end

  defp not_already_shared(space_id) do
    case SharedSpaces.get_by_local_space(space_id) do
      nil -> :ok
      _ -> {:error, :already_shared}
    end
  end

  defp replica_space_id(%{body: %{"data" => %{"space_id" => id}}}) when is_binary(id) do
    if Platform.UUID.valid?(id), do: {:ok, String.downcase(id)}, else: {:error, :invalid_answer}
  end

  defp replica_space_id(_), do: {:error, :invalid_answer}

  defp deliver(type, payload, %Peer{} = peer, build_opts) do
    with {:ok, {raw, headers}} <- Envelope.build(type, payload, peer, build_opts),
         {:ok, _response} <- Client.send_envelope(peer, raw, headers) do
      :ok
    end
  end

  defp require_enabled do
    if Config.enabled?(), do: :ok, else: {:error, :federation_disabled}
  end

  defp descriptor_keys(%{"keys" => keys}) do
    parsed =
      for %{"kid" => kid, "public_key" => pub} = key <- keys,
          is_binary(kid) and is_binary(pub),
          Map.get(key, "status", "current") == "current" do
        %{kid: kid, public_key: pub}
      end

    if parsed == [], do: {:error, :invalid_descriptor}, else: {:ok, parsed}
  end

  defp not_self(%{"install_id" => id}, %{install_id: id}), do: {:error, :cannot_peer_with_self}
  defp not_self(_, _), do: :ok

  defp decode(%PeerKey{public_key: b64}) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, <<_::256>> = raw} -> {:ok, raw}
      _ -> {:error, :malformed_key}
    end
  end

  defp require_https_unless_allowed(changeset) do
    Ecto.Changeset.validate_change(changeset, :base_url, fn :base_url, url ->
      case URI.parse(url) do
        %URI{scheme: "https"} -> []
        %URI{scheme: "http"} -> if Config.allow_http?(), do: [], else: [base_url: "must be https"]
        _ -> []
      end
    end)
  end
end
