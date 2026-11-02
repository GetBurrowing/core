# scripts/federation_rig/list.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on either install: `federation-two-install-rig.sh rpc <a|b> list.exs`.
# Prints ONE `RIG <json>` line with this install's view: every peer row (with
# the fingerprints of the keys it holds), every shared-space row with its
# outbound cursor, the shared space's messages (id, inserted_at, author,
# content, metadata.source), the federation_message_links rows, and the
# PeerConnection status summary (breaker, queue length, last error class).
# Public material, ids and timestamps only.

fingerprint = fn key ->
  key.public_key
  |> Base.url_decode64!(padding: false)
  |> Platform.Federation.Ed25519.fingerprint()
end

peers =
  Enum.map(Platform.Federation.Peers.list_peers(), fn peer ->
    shared = Platform.Federation.Peers.SharedSpaces.list_for_peer(peer.id)

    connection =
      case Platform.Federation.Peers.PeerConnection.status(peer.id) do
        {:ok, status} -> Map.update!(status, :last_error, &inspect/1)
        {:error, reason} -> %{running: false, error: inspect(reason)}
      end

    %{
      peer_id: peer.id,
      peer_install_id: peer.peer_install_id,
      base_url: peer.base_url,
      status: peer.status,
      revoked_by: peer.revoked_by,
      revoked_at: peer.revoked_at,
      fingerprints: Enum.map(peer.public_keys, fingerprint),
      connection: connection,
      shared_spaces:
        Enum.map(shared, fn s ->
          %{
            id: s.id,
            role: s.role,
            status: s.status,
            local_space_id: s.local_space_id,
            remote_space_id: s.remote_space_id,
            outbound_cursor_message_id: s.outbound_cursor_message_id,
            messages:
              s.local_space_id
              |> Platform.Chat.list_messages(limit: 200, order: :asc)
              |> Enum.map(fn m ->
                %{
                  id: m.id,
                  inserted_at: m.inserted_at,
                  author: m.author_display_name,
                  content: m.content,
                  source: (m.metadata || %{})["source"]
                }
              end)
          }
        end),
      links:
        Enum.map(Platform.Federation.Peers.SharedSpaces.list_links(peer.id), fn l ->
          %{
            local_message_id: l.local_message_id,
            remote_message_id: l.remote_message_id,
            direction: l.direction,
            inserted_at: l.inserted_at
          }
        end)
    }
  end)

IO.puts("RIG " <> Jason.encode!(%{script: "list", at: DateTime.utc_now(), peers: peers}))
