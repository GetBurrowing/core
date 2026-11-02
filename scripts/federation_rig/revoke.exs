# scripts/federation_rig/revoke.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on install A: `federation-two-install-rig.sh rpc a revoke.exs`.
# Peers.revoke(peer, notify: false): A persists `revoked`, stops its
# PeerConnection and revokes the shared rows, and does NOT tell B. B keeps
# sending; the proof is that A's inbox refuses B from now on.

[peer] = Platform.Federation.Peers.list_peers(status: "active")

case Platform.Federation.Peers.revoke(peer, notify: false) do
  {:ok, revoked} ->
    IO.puts(
      "RIG " <>
        Jason.encode!(%{
          script: "revoke",
          ok: true,
          peer_id: revoked.id,
          status: revoked.status,
          revoked_by: revoked.revoked_by,
          revoked_at: revoked.revoked_at,
          connection_running: Platform.Federation.Peers.PeerConnection.whereis(revoked.id) != nil,
          shared_statuses:
            Enum.map(
              Platform.Federation.Peers.SharedSpaces.list_for_peer(revoked.id),
              & &1.status
            )
        })
    )

  {:error, reason} ->
    IO.puts("RIG " <> Jason.encode!(%{script: "revoke", ok: false, error: inspect(reason)}))
    raise "revoke failed: #{inspect(reason)}"
end
