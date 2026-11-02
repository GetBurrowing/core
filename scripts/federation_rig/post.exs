# scripts/federation_rig/post.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on either install: `federation-two-install-rig.sh rpc <a|b> post.exs
# <text>`. Posts <text> with Chat.post_message/2 into this install's side of
# the shared space, as a local user participant (added on first use). The
# PeerConnection relays it from the PubSub broadcast: message.replicate from
# the owner, message.submit from the replica. The space is found through the
# install's only peer, whatever the peer's status, so a post still lands
# locally after a revoke.

[content] = args
[peer] = Platform.Federation.Peers.list_peers()
[shared | _] = Platform.Federation.Peers.SharedSpaces.list_for_peer(peer.id)
space_id = shared.local_space_id
%{install_id: me} = Platform.Federation.Peers.InstallIdentity.ensure!()
user_id = Platform.UUID.deterministic("fed-rig-user-" <> me)

participant =
  Enum.find(Platform.Chat.list_participants(space_id), &(&1.participant_id == user_id)) ||
    elem(
      Platform.Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: "Rig user " <> String.slice(me, 0, 8),
        joined_at: DateTime.utc_now()
      }),
      1
    )

{:ok, message} =
  Platform.Chat.post_message(%{
    space_id: space_id,
    participant_id: participant.id,
    content_type: "text",
    content: content
  })

IO.puts(
  "RIG " <>
    Jason.encode!(%{
      script: "post",
      space_id: space_id,
      role: shared.role,
      message_id: message.id,
      content: message.content,
      inserted_at: message.inserted_at
    })
)
