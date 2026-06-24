defmodule Platform.ExternalAgents.ResolveCredentialTest do
  @moduledoc """
  Tests for `Platform.ExternalAgents.resolve_credential/1` — the
  ephemeral-vs-vaulted credential dispatcher (M3 stage 3, decision 6).

  Uses minimal map fixtures (`%{id: ..., vault_key: ...}`) so these
  tests don't depend on the full `Platform.Agents.Agent` struct shape.

  `async: false` — the `EphemeralCredentials` ETS table is a global
  singleton owned by the application supervisor; keying every fixture
  on a unique agent_id keeps cross-test bleed at bay, but we keep the
  sync flag to avoid surprising races with sibling suites that touch
  the same table.
  """

  use Platform.DataCase, async: false

  alias Platform.ExternalAgents
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Vault
  alias Platform.Vault.AccessGrant

  @telemetry_event [:platform, :external_agents, :credential_resolved]

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_agent_id, do: Ecto.UUID.generate()

  # Attach a one-shot handler that forwards the credential_resolved
  # event to the calling test pid; detaches on test exit. Returns the
  # handler id so tests can detach early if they need to.
  defp attach_telemetry_forwarder do
    handler_id = "test-resolve-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  describe "vault_key is a non-empty binary (vaulted path)" do
    test "returns the secret stored in the Vault when the agent owns the row" do
      attach_telemetry_forwarder()
      agent_id = unique_agent_id()
      vault_key = unique_slug("vault-owned")

      {:ok, _cred} =
        Vault.put(vault_key, :api_key, "vault-secret-A", scope: {:agent, agent_id})

      assert {:ok, "vault-secret-A"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})

      assert_receive {:telemetry, %{system_time: _}, %{source: :vault, agent_id: ^agent_id}}
    end

    test "vault wins even when an ETS row exists for the agent_id" do
      # The dispatcher must not fall through to ETS when vault_key is
      # set — otherwise a stale ephemeral row could shadow a freshly
      # provisioned vault credential.
      agent_id = unique_agent_id()
      vault_key = unique_slug("vault-wins")

      {:ok, _cred} =
        Vault.put(vault_key, :api_key, "from-vault", scope: {:agent, agent_id})

      :ok = EphemeralCredentials.put(agent_id, "from-ets-should-be-ignored")

      assert {:ok, "from-vault"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})
    after
      # Don't leak ephemeral rows into sibling tests.
      :ok
    end

    test "normalizes Vault.get/2's {:error, :access_denied} to {:error, :not_found}" do
      # Provision the credential against one agent, then try to resolve
      # it as a *different* agent — vault returns :access_denied which
      # the dispatcher must collapse into :not_found so the M7 UI shows
      # a single "credentials missing" message.
      owner_id = unique_agent_id()
      stranger_id = unique_agent_id()
      vault_key = unique_slug("vault-denied")

      {:ok, _cred} =
        Vault.put(vault_key, :api_key, "owners-only", scope: {:agent, owner_id})

      # Sanity-check the vault still says :access_denied — the
      # normalization happens in the dispatcher, not in the vault.
      assert {:error, :access_denied} =
               Vault.get(vault_key, accessor: {:agent, stranger_id})

      assert {:error, :not_found} =
               ExternalAgents.resolve_credential(%{id: stranger_id, vault_key: vault_key})
    end

    test "passes through Vault.get/2's {:error, :not_found} when the slug doesn't exist" do
      attach_telemetry_forwarder()
      agent_id = unique_agent_id()
      vault_key = unique_slug("vault-missing")

      assert {:error, :not_found} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: vault_key})

      # Telemetry must fire on the :not_found path too — observability
      # on dispatch is more important than success-only signal.
      assert_receive {:telemetry, %{system_time: _}, %{source: :vault, agent_id: ^agent_id}}
    end

    test "honors explicit AccessGrant rows (grantee sees the secret)" do
      owner_id = unique_agent_id()
      grantee_id = unique_agent_id()
      vault_key = unique_slug("vault-grant")

      {:ok, cred} =
        Vault.put(vault_key, :api_key, "shared-secret", scope: {:agent, owner_id})

      Repo.insert!(%AccessGrant{
        credential_id: cred.id,
        grantee_type: "agent",
        grantee_id: grantee_id,
        permissions: ["use"]
      })

      assert {:ok, "shared-secret"} =
               ExternalAgents.resolve_credential(%{id: grantee_id, vault_key: vault_key})
    end
  end

  describe "vault_key is nil (ephemeral path)" do
    test "returns the ETS-stored secret" do
      attach_telemetry_forwarder()
      agent_id = unique_agent_id()
      :ok = EphemeralCredentials.put(agent_id, "ephemeral-bearer")

      assert {:ok, "ephemeral-bearer"} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})

      assert_receive {:telemetry, %{system_time: _}, %{source: :ephemeral, agent_id: ^agent_id}}
    end

    test "returns {:error, :not_found} when no ETS row exists" do
      attach_telemetry_forwarder()
      agent_id = unique_agent_id()

      assert {:error, :not_found} =
               ExternalAgents.resolve_credential(%{id: agent_id, vault_key: nil})

      # Telemetry on the ephemeral path is the only observability
      # signal here — there is no DB row to inspect after the fact.
      assert_receive {:telemetry, %{system_time: _}, %{source: :ephemeral, agent_id: ^agent_id}}
    end
  end
end
