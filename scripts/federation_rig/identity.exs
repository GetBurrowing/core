# scripts/federation_rig/identity.exs (task 01a199b2 stage 1, ADR 0054)
#
# Run on a rig install through `scripts/federation-two-install-rig.sh rpc <a|b>
# identity.exs`; it is evaluated on the running server node, never with
# `mix run`. Creates the install identity if it does not exist yet and prints
# ONE JSON line carrying public material only: install_id, kid and the
# sha256 fingerprint admins compare out of band. The private key stays in
# Platform.Vault and is never read here.
#
# Every Platform.* call in this directory is checked against the code by
# apps/platform/test/platform/federation/peers/two_install_rig_contract_test.exs.

%{install_id: install_id, kid: kid, fingerprint: fingerprint} =
  Platform.Federation.Peers.InstallIdentity.ensure!()

IO.puts(
  "RIG " <>
    Jason.encode!(%{
      script: "identity",
      install_id: install_id,
      kid: kid,
      fingerprint: fingerprint,
      base_url: Platform.Federation.Peers.Config.base_url(),
      at: DateTime.to_iso8601(DateTime.utc_now())
    })
)
