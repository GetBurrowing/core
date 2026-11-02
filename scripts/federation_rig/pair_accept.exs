# scripts/federation_rig/pair_accept.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on install B: `federation-two-install-rig.sh rpc b pair_accept.exs
# <A's install_id> <A's fingerprint>`. The fingerprint is the one A printed
# itself (identity.exs on A); comparing it with the key B recorded from the
# proposal stands in for the out-of-band check an admin makes, and it is a
# real assertion: a mismatch raises and nothing is accepted. Then
# Peers.accept(peer, nil) sends relationship.accept and both rows go active.

[install_id, expected_fingerprint] = args

peer =
  Platform.Federation.Peers.get_peer_by_install_id(install_id) ||
    raise "no peer row for install #{install_id}"

peer.status == "pending_inbound" ||
  raise "peer #{peer.id} is #{peer.status}, expected pending_inbound"

fingerprints =
  Enum.map(peer.public_keys, fn key ->
    key.public_key
    |> Base.url_decode64!(padding: false)
    |> Platform.Federation.Ed25519.fingerprint()
  end)

expected_fingerprint in fingerprints ||
  raise "fingerprint mismatch: A printed #{expected_fingerprint}, B recorded #{inspect(fingerprints)}"

case Platform.Federation.Peers.accept(peer, nil) do
  {:ok, active} ->
    IO.puts(
      "RIG " <>
        Jason.encode!(%{
          script: "pair_accept",
          ok: true,
          peer_id: active.id,
          peer_install_id: active.peer_install_id,
          fingerprint_matched: expected_fingerprint,
          status: active.status,
          updated_at: active.updated_at,
          at: DateTime.utc_now()
        })
    )

  {:error, reason} ->
    IO.puts("RIG " <> Jason.encode!(%{script: "pair_accept", ok: false, error: inspect(reason)}))
    raise "pair_accept failed: #{inspect(reason)}"
end
