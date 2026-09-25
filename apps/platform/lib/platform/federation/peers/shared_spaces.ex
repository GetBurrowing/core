defmodule Platform.Federation.Peers.SharedSpaces do
  @moduledoc """
  Storage for shared spaces and message links (task 01a0d90f stage 5,
  ADR 0054 section 3): the rows `Platform.Federation.Peers.share_space/3`,
  the `space.share` handler, `Platform.Federation.Peers.Ingest` and the
  relay in `Platform.Federation.Peers.PeerConnection` read and write.

  ## Replica creation (`accept_share/2`)

  A `space.share` from an ACTIVE peer creates a local `channel` named
  `"<name> (shared by <peer>)"`, seats the peer row's `accepted_by_user_id`
  (the local admin who accepted the relationship) as its admin, and records a
  `replica` row. All three writes are one transaction, so a failed or racing
  duplicate delivery leaves no orphan channel. A re-delivered share returns
  the space it already created.

  Once the transaction has COMMITTED, a new replica row is announced to the
  peer's running `Platform.Federation.Peers.PeerConnection` with
  `PeerConnection.refresh/1`, so it subscribes to the new channel and relays
  its messages to the owner as `message.submit`. Without that the connection,
  started when the relationship was accepted and before the row existed,
  never learns of the space (task 01a0d90f stage 6). The refresh is a cast
  sent after `Repo.transaction/1` has returned `{:ok, _}`; `accept_share/2`
  is called only from `Platform.Federation.Peers.Inbound`, outside any
  transaction, so that return is the commit and the connection's re-read
  sees the row. An `:already_applied` answer created nothing and refreshes
  nothing.

  A peer may create at most `max_shared_spaces_per_peer/0` replica spaces.

  ## Replay (`replay_messages/3`)

  The messages a restarted connection re-sends: top-level, not deleted,
  `text`, not `federation_inbound`, with an id after the cursor, oldest
  first. The `federation_inbound` filter is in SQL, so a run of ingested
  messages can never fill a replay page and stall the cursor. Chat message
  ids are UUIDv7 with a per-node monotonic counter, so id order is post
  order on one node.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation.Peers.MessageLink
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerConnection
  alias Platform.Federation.Peers.SharedSpace
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @max_shared_spaces_per_peer 100
  @name_cap 120

  @doc "Maximum replica spaces one peer may create here."
  def max_shared_spaces_per_peer, do: @max_shared_spaces_per_peer

  @doc "Active shared spaces for a peer, oldest first."
  @spec list_active(String.t()) :: [SharedSpace.t()]
  def list_active(peer_id) do
    from(s in SharedSpace,
      where: s.peer_id == ^peer_id and s.status == "active",
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Every shared space of a peer, any status (tests, diagnostics)."
  @spec list_for_peer(String.t()) :: [SharedSpace.t()]
  def list_for_peer(peer_id) do
    from(s in SharedSpace, where: s.peer_id == ^peer_id, order_by: [asc: s.inserted_at])
    |> Repo.all()
  end

  @doc """
  The active shared space of `peer_id` whose LOCAL id is `local_space_id`, or
  nil. This is how an incoming message is resolved, so a peer reaches only
  the spaces shared with it.
  """
  @spec get_active(String.t(), String.t()) :: SharedSpace.t() | nil
  def get_active(peer_id, local_space_id) do
    from(s in SharedSpace,
      where:
        s.peer_id == ^peer_id and s.local_space_id == ^local_space_id and
          s.status == "active"
    )
    |> Repo.all()
    |> List.first()
  end

  @doc "The shared-space row of a local space, any peer and status, or nil."
  @spec get_by_local_space(String.t()) :: SharedSpace.t() | nil
  def get_by_local_space(local_space_id) do
    from(s in SharedSpace, where: s.local_space_id == ^local_space_id)
    |> Repo.all()
    |> List.first()
  end

  @doc "Inserts an `owner` row (the local side of `Peers.share_space/3`)."
  @spec create_owner(Peer.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, SharedSpace.t()} | {:error, Ecto.Changeset.t()}
  def create_owner(%Peer{} = peer, local_space_id, remote_space_id, cursor) do
    %SharedSpace{}
    |> SharedSpace.create_changeset(%{
      peer_id: peer.id,
      local_space_id: local_space_id,
      remote_space_id: remote_space_id,
      role: "owner",
      outbound_cursor_message_id: cursor
    })
    |> Repo.insert()
  end

  @doc """
  Handles a verified `space.share` from `peer` (see the moduledoc). Returns
  `{:ok, :space_shared | :already_applied, %{"space_id" => local_id}}`.
  """
  @spec accept_share(Peer.t(), map()) :: {:ok, atom(), map()} | {:error, atom()}
  def accept_share(%Peer{status: "active"} = peer, %{"space_id" => remote_id, "name" => name})
      when is_binary(remote_id) and is_binary(name) do
    if Platform.UUID.valid?(remote_id) do
      case existing_replica(peer.id, remote_id) do
        %SharedSpace{local_space_id: local_id} ->
          {:ok, :already_applied, %{"space_id" => local_id}}

        nil ->
          if count_for_peer(peer.id) >= @max_shared_spaces_per_peer,
            do: {:error, :share_limit_reached},
            else: create_replica(peer, remote_id, name)
      end
    else
      {:error, :invalid_payload}
    end
  end

  def accept_share(%Peer{status: "active"}, _payload), do: {:error, :invalid_payload}
  def accept_share(_peer, _payload), do: {:error, :peer_not_active}

  defp existing_replica(peer_id, remote_id) do
    from(s in SharedSpace, where: s.peer_id == ^peer_id and s.remote_space_id == ^remote_id)
    |> Repo.all()
    |> List.first()
  end

  defp count_for_peer(peer_id) do
    from(s in SharedSpace, where: s.peer_id == ^peer_id) |> Repo.aggregate(:count)
  end

  defp create_replica(%Peer{} = peer, remote_id, name) do
    display = replica_name(name, peer)

    result =
      Repo.transaction(fn ->
        with {:ok, space} <-
               Chat.create_space(%{
                 name: display,
                 slug: "shared-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower),
                 kind: "channel",
                 org_id: admin_org_id(peer.accepted_by_user_id),
                 metadata: %{"federation" => %{"peer_id" => peer.id, "role" => "replica"}}
               }),
             :ok <- seat_admin(space, peer.accepted_by_user_id),
             {:ok, shared} <-
               %SharedSpace{}
               |> SharedSpace.create_changeset(%{
                 peer_id: peer.id,
                 local_space_id: space.id,
                 remote_space_id: remote_id,
                 role: "replica"
               })
               |> Repo.insert() do
          shared
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, shared} ->
        # After the commit (see the moduledoc): the running connection reads
        # the row it is told about.
        PeerConnection.refresh(peer.id)
        {:ok, :space_shared, %{"space_id" => shared.local_space_id}}

      {:error, %Ecto.Changeset{}} ->
        # A racing duplicate delivery won the unique index: answer with the
        # space it created.
        case existing_replica(peer.id, remote_id) do
          %SharedSpace{local_space_id: local_id} ->
            {:ok, :already_applied, %{"space_id" => local_id}}

          nil ->
            {:error, :invalid_payload}
        end

      {:error, _} ->
        {:error, :invalid_payload}
    end
  end

  @doc false
  def replica_name(name, %Peer{} = peer) do
    base =
      name
      |> ExternalContent.sanitize_line()
      |> String.trim()
      |> String.slice(0, 80)

    (base <> " (shared by " <> peer_label(peer) <> ")")
    |> String.slice(0, @name_cap)
    |> ExternalContent.escape_mentions()
  end

  @doc "A one-line, sanitized label for a peer: its display name or its host."
  @spec peer_label(Peer.t()) :: String.t()
  def peer_label(%Peer{display_name: name}) when is_binary(name) and name != "" do
    name |> ExternalContent.sanitize_line() |> String.trim() |> String.slice(0, 60)
  end

  def peer_label(%Peer{base_url: url}) do
    case URI.parse(url || "") do
      %URI{host: host} when is_binary(host) -> ExternalContent.sanitize_line(host)
      _ -> "a Suite peer"
    end
  end

  defp seat_admin(_space, nil), do: :ok

  defp seat_admin(space, user_id) do
    case Chat.add_participant(space.id, %{
           participant_type: "user",
           participant_id: user_id,
           role: "admin",
           joined_at: DateTime.utc_now()
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp admin_org_id(nil), do: nil

  defp admin_org_id(user_id) do
    from(m in Platform.Tenancy.OrgMembership,
      where: m.user_id == ^user_id,
      order_by: [asc: m.inserted_at],
      select: m.org_id,
      limit: 1
    )
    |> Repo.all()
    |> List.first()
  end

  @doc "Marks every shared space of a peer `revoked` (the relationship was revoked)."
  @spec revoke_for_peer(String.t()) :: non_neg_integer()
  def revoke_for_peer(peer_id) do
    {count, _} =
      from(s in SharedSpace, where: s.peer_id == ^peer_id and s.status != "revoked")
      |> Repo.update_all(set: [status: "revoked", updated_at: DateTime.utc_now()])

    count
  end

  @doc """
  Advances a shared space's cursor to `message_id` if that is newer. Called
  only from an acknowledged (2xx) send.
  """
  @spec advance_cursor(String.t(), String.t()) :: :ok
  def advance_cursor(shared_space_id, message_id) do
    from(s in SharedSpace,
      where:
        s.id == ^shared_space_id and
          (is_nil(s.outbound_cursor_message_id) or s.outbound_cursor_message_id < ^message_id)
    )
    |> Repo.update_all(
      set: [outbound_cursor_message_id: message_id, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Up to `limit` relayable local messages of `local_space_id` after `cursor`
  (nil = from the start), oldest first. See the moduledoc.
  """
  @spec replay_messages(String.t(), String.t() | nil, non_neg_integer()) :: [Message.t()]
  def replay_messages(_local_space_id, _cursor, limit) when limit <= 0, do: []

  def replay_messages(local_space_id, cursor, limit) do
    from(m in Message,
      where:
        m.space_id == ^local_space_id and is_nil(m.thread_id) and is_nil(m.deleted_at) and
          m.content_type == "text" and not is_nil(m.content) and
          fragment("coalesce(?->>'source', '') <> 'federation_inbound'", m.metadata),
      order_by: [asc: m.id],
      limit: ^limit
    )
    |> then(fn q -> if cursor, do: where(q, [m], m.id > ^cursor), else: q end)
    |> Repo.all()
  end

  @doc "The newest relayable message id of a space, or nil (a new share's starting cursor)."
  @spec latest_message_id(String.t()) :: String.t() | nil
  def latest_message_id(local_space_id) do
    from(m in Message,
      where: m.space_id == ^local_space_id,
      order_by: [desc: m.id],
      select: m.id,
      limit: 1
    )
    |> Repo.all()
    |> List.first()
  end

  @doc "Records that our `local_message_id` is stored by the peer as `remote_message_id`."
  @spec record_outbound(String.t(), String.t(), String.t()) :: :ok
  def record_outbound(peer_id, local_message_id, remote_message_id) do
    %MessageLink{}
    |> MessageLink.changeset(%{
      peer_id: peer_id,
      local_message_id: local_message_id,
      remote_message_id: remote_message_id,
      direction: "outbound"
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:peer_id, :remote_message_id])

    :ok
  end

  @doc "Links of a peer, oldest first (tests, diagnostics)."
  @spec list_links(String.t()) :: [MessageLink.t()]
  def list_links(peer_id) do
    from(l in MessageLink, where: l.peer_id == ^peer_id, order_by: [asc: l.inserted_at])
    |> Repo.all()
  end
end
