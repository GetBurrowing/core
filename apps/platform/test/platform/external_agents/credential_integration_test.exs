defmodule Platform.ExternalAgents.CredentialIntegrationTest do
  @moduledoc """
  End-to-end exercise of the full M3 credential surface:
  `Vault.put_inline/2` (stage 1) ↔ `EphemeralCredentials.put/2 /
  delete/1` (stage 2) ↔ `ExternalAgents.resolve_credential/1` dispatch
  (stage 3) ↔ telemetry emission (stage 4).

  These tests deliberately drive the public API only — no Repo
  reads/writes against the underlying schemas except for the
  `vault_credentials` row-count assertion, which exists to guarantee
  decision 6's invariant: **the ephemeral path never touches the DB**.

  `async: false` because the ephemeral store is a global ETS singleton
  and the row-count check is sensitive to sibling test writes against
  `vault_credentials`.
  """

  use Platform.DataCase, async: false

  alias Platform.ExternalAgents
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Vault
  alias Platform.Vault.Credential

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_agent_id, do: Ecto.UUID.generate()

  describe "M3 end-to-end surface" do
    test "vault put_inline → resolve_credential returns the secret" do
      agent_id = unique_agent_id()
      vault_key = unique_slug("m3-int-vault")

      {:ok, _cred} = Vault.put_inline(vault_key, "v1")

      assert {:ok, "v1"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})
    end

    test "vault put_inline upsert overwrites the secret seen by resolve_credential" do
      agent_id = unique_agent_id()
      vault_key = unique_slug("m3-int-upsert")

      {:ok, _first} = Vault.put_inline(vault_key, "v1")

      assert {:ok, "v1"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})

      # Rotate the inline credential — the second put_inline must not
      # insert a duplicate row (slug+platform-scope is unique) and the
      # next resolve must see the new secret.
      {:ok, _second} = Vault.put_inline(vault_key, "v2")

      assert {:ok, "v2"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})
    end

    test "ephemeral put → resolve_credential returns the secret; delete → :not_found" do
      agent_id = unique_agent_id()

      :ok = EphemeralCredentials.put(agent_id, "eph")

      assert {:ok, "eph"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})

      :ok = EphemeralCredentials.delete(agent_id)

      assert {:error, :not_found} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})
    end

    test "ephemeral path NEVER writes to vault_credentials" do
      # Decision 6: the ephemeral branch leaves no DB trail. Verify by
      # counting vault_credentials rows before and after a put + resolve
      # + delete cycle and asserting the count is unchanged.
      before_count = Repo.aggregate(Credential, :count, :id)

      agent_id = unique_agent_id()

      :ok = EphemeralCredentials.put(agent_id, "eph-only")

      assert {:ok, "eph-only"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})

      :ok = EphemeralCredentials.delete(agent_id)

      assert {:error, :not_found} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})

      after_count = Repo.aggregate(Credential, :count, :id)

      assert before_count == after_count,
             "ephemeral path leaked a vault_credentials row " <>
               "(before=#{before_count}, after=#{after_count})"
    end
  end
end
