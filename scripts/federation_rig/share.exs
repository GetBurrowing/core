# scripts/federation_rig/share.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on install A after pairing: `federation-two-install-rig.sh rpc a
# share.exs`. Creates a `channel` space and a user participant with the
# public Chat functions, then Peers.share_space/2. B's
# SharedSpaces.accept_share/2 creates the replica and answers with its id.
# Prints both space ids.

[peer] = Platform.Federation.Peers.list_peers(status: "active")
stamp = System.system_time(:millisecond)
%{install_id: me} = Platform.Federation.Peers.InstallIdentity.ensure!()

{:ok, space} =
  Platform.Chat.create_space(%{
    name: "fed-rig #{stamp}",
    slug: "fed-rig-#{stamp}",
    kind: "channel"
  })

{:ok, _participant} =
  Platform.Chat.add_participant(space.id, %{
    participant_type: "user",
    participant_id: Platform.UUID.deterministic("fed-rig-user-" <> me),
    display_name: "Rig user " <> String.slice(me, 0, 8),
    joined_at: DateTime.utc_now()
  })

case Platform.Federation.Peers.share_space(peer, space.id) do
  {:ok, shared} ->
    IO.puts(
      "RIG " <>
        Jason.encode!(%{
          script: "share",
          ok: true,
          peer_id: peer.id,
          local_space_id: space.id,
          remote_space_id: shared.remote_space_id,
          shared_space_id: shared.id,
          role: shared.role,
          outbound_cursor_message_id: shared.outbound_cursor_message_id,
          at: DateTime.utc_now()
        })
    )

  {:error, reason} ->
    IO.puts("RIG " <> Jason.encode!(%{script: "share", ok: false, error: inspect(reason)}))
    raise "share failed: #{inspect(reason)}"
end
