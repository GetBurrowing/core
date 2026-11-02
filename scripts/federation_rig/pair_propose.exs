# scripts/federation_rig/pair_propose.exs (task 01a199b2 stage 2, ADR 0054)
#
# Run on install A: `federation-two-install-rig.sh rpc a pair_propose.exs
# <B's base URL>`. Calls the real entry point, Peers.propose/2: A fetches B's
# descriptor, records a pending_outbound row and sends relationship.propose,
# which B verifies and records as pending_inbound. Prints ONE `RIG <json>`
# line: ids, statuses and timestamps only.

[base_url] = args

case Platform.Federation.Peers.propose(base_url) do
  {:ok, peer} ->
    IO.puts(
      "RIG " <>
        Jason.encode!(%{
          script: "pair_propose",
          ok: true,
          peer_id: peer.id,
          peer_install_id: peer.peer_install_id,
          peer_base_url: peer.base_url,
          status: peer.status,
          inserted_at: peer.inserted_at,
          at: DateTime.utc_now()
        })
    )

  {:error, reason} ->
    IO.puts("RIG " <> Jason.encode!(%{script: "pair_propose", ok: false, error: inspect(reason)}))
    raise "pair_propose failed: #{inspect(reason)}"
end
