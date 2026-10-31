defmodule Platform.Vault.SystemGrantTest do
  @moduledoc """
  Task 01a18f0c stage 1: a named system reader reads a SHARED secret only
  through its own grant, which a root admin adds and removes like an agent
  grant, with an access-log row each. Core ships no named reader since task
  01a19249 stage 5 (the hosted-installs provisioner moved to Burrow Cloud),
  so the mechanism is pinned with the test-only `"test-reader"` that
  config/test.exs names.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Shared

  @reader {:system, "test-reader"}
  @principal_id "5b6195d9-a785-48ac-b3b5-619708e4130e"

  defp shared!(slug, value) do
    {:ok, secret} = Shared.create(admin!(), %{slug: slug, value: value}, [])
    secret
  end

  defp system_grants(credential_id) do
    from(g in AccessGrant,
      where: g.credential_id == ^credential_id and g.grantee_type == "system"
    )
    |> Repo.all()
  end

  test "the reader's fixed uuid comes from config, and core ships no other" do
    assert Vault.system_principals() == %{"test-reader" => @principal_id}
  end

  test "the grant admits exactly that reader, and is logged like an agent grant" do
    slug = unique_slug()
    secret = shared!(slug, "value-#{unique()}")
    admin = admin!()

    assert :ok = Shared.grant_system(admin, secret.id, "test-reader")
    # Idempotent: a second grant writes no second row and no second log row.
    assert :ok = Shared.grant_system(admin, secret.id, "test-reader")
    assert [%AccessGrant{permissions: ["use"], granted_by: granted_by}] = system_grants(secret.id)
    assert granted_by == admin.id

    assert {:ok, _} = Vault.get(slug, accessor: @reader)
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:system, "someone-else"})
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:system, nil})
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:platform, nil})

    {:ok, all} = Shared.list(admin)
    assert [listed] = Enum.filter(all, &(&1.slug == slug))

    assert listed.granted_system_principals == ["test-reader"]
    assert listed.granted_agent_ids == []

    logs = logs_for_slug(slug)

    assert [%{accessor_type: "platform", accessor_id: admin_id}] =
             Enum.filter(logs, &(&1.action == "update"))

    assert admin_id == admin.id

    assert Enum.any?(
             logs,
             &(&1.action == "update" and
                 &1.metadata == %{
                   "grant" => "added",
                   "system_principal" => "test-reader"
                 })
           )

    # The reader's own reads are logged under its uuid, not the
    # anonymous system sentinel.
    assert [%{accessor_type: "system", accessor_id: @principal_id}] =
             Enum.filter(logs, &(&1.action == "use"))

    assert :ok = Shared.revoke_system_grant(admin, secret.id, "test-reader")
    assert system_grants(secret.id) == []

    assert Enum.any?(
             logs_for_slug(slug),
             &(&1.metadata == %{
                 "grant" => "removed",
                 "system_principal" => "test-reader"
               })
           )

    assert {:error, :access_denied} = Vault.get(slug, accessor: @reader)

    assert [%{accessor_type: "system", accessor_id: @principal_id}] =
             Enum.filter(
               logs_for_slug(slug),
               &(&1.action == "denied" and &1.accessor_id == @principal_id)
             )
  end

  test "agent grant edits never touch a system grant" do
    secret = shared!(unique_slug(), "value-#{unique()}")
    admin = admin!()
    agent = agent!()

    :ok = Shared.grant_system(admin, secret.id, "test-reader")
    :ok = Shared.set_grants(admin, secret.id, [agent.id])
    :ok = Shared.set_grants(admin, secret.id, [])

    assert [_] = system_grants(secret.id)
  end

  test "only a root admin may grant or revoke, and only a known reader" do
    secret = shared!(unique_slug(), "value-#{unique()}")

    assert {:error, :unauthorized} =
             Shared.grant_system(non_admin!(), secret.id, "test-reader")

    assert {:error, :unauthorized} =
             Shared.revoke_system_grant(nil, secret.id, "test-reader")

    assert {:error, :unknown_system_principal} =
             Shared.grant_system(admin!(), secret.id, "anything-else")

    assert {:error, :not_found} =
             Shared.grant_system(admin!(), Ecto.UUID.generate(), "test-reader")

    assert system_grants(secret.id) == []
  end
end
