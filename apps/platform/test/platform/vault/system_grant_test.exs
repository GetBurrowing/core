defmodule Platform.Vault.SystemGrantTest do
  @moduledoc """
  Task 01a18f0c stage 1: a named system reader (`{:system,
  "installs-provisioner"}`) reads a SHARED secret only through its own
  grant, which a root admin adds and removes like an agent grant, with an
  access-log row each. The prod grant comes from a data migration that is
  idempotent and a no-op when the secret is absent.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.VaultFixtures

  alias Platform.Installs.DigitalOcean
  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Shared

  @provisioner {:system, "installs-provisioner"}
  @principal_id "e3ee1349-ca10-46f7-aaa9-65205a820f86"
  @do_slug "digital-ocean-api-infra"
  @fake_token "dop_v1_test_fake_vault_token"

  @migration "priv/repo/migrations/20261031010100_grant_installs_provisioner_do_token.exs"
  @migration_module Platform.Repo.Migrations.GrantInstallsProvisionerDoToken

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

  defp read_via_token_source(slug) do
    previous = Application.get_env(:platform, DigitalOcean, [])

    Application.put_env(
      :platform,
      DigitalOcean,
      Keyword.put(previous, :token_source, {:vault, slug})
    )

    try do
      DigitalOcean.token()
    after
      Application.put_env(:platform, DigitalOcean, previous)
    end
  end

  test "the provisioner's fixed uuid is the one the migration writes" do
    assert Vault.system_principals() == %{"installs-provisioner" => @principal_id}
  end

  test "the provisioner's DO token read is refused without the grant and succeeds with it" do
    secret = shared!(@do_slug, @fake_token)

    assert {:error, :access_denied} = read_via_token_source(@do_slug)

    assert :ok = Shared.grant_system(admin!(), secret.id, "installs-provisioner")
    assert {:ok, @fake_token} = read_via_token_source(@do_slug)

    assert :ok = Shared.revoke_system_grant(admin!(), secret.id, "installs-provisioner")
    assert {:error, :access_denied} = read_via_token_source(@do_slug)
  end

  test "the grant admits exactly that reader, and is logged like an agent grant" do
    slug = unique_slug()
    secret = shared!(slug, "value-#{unique()}")
    admin = admin!()

    assert :ok = Shared.grant_system(admin, secret.id, "installs-provisioner")
    # Idempotent: a second grant writes no second row and no second log row.
    assert :ok = Shared.grant_system(admin, secret.id, "installs-provisioner")
    assert [%AccessGrant{permissions: ["use"], granted_by: granted_by}] = system_grants(secret.id)
    assert granted_by == admin.id

    assert {:ok, _} = Vault.get(slug, accessor: @provisioner)
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:system, "someone-else"})
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:system, nil})
    assert {:error, :access_denied} = Vault.get(slug, accessor: {:platform, nil})

    {:ok, all} = Shared.list(admin)
    assert [listed] = Enum.filter(all, &(&1.slug == slug))

    assert listed.granted_system_principals == ["installs-provisioner"]
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
                   "system_principal" => "installs-provisioner"
                 })
           )

    # The provisioner's own reads are logged under its uuid, not the
    # anonymous system sentinel.
    assert [%{accessor_type: "system", accessor_id: @principal_id}] =
             Enum.filter(logs, &(&1.action == "use"))

    assert :ok = Shared.revoke_system_grant(admin, secret.id, "installs-provisioner")
    assert system_grants(secret.id) == []

    assert Enum.any?(
             logs_for_slug(slug),
             &(&1.metadata == %{
                 "grant" => "removed",
                 "system_principal" => "installs-provisioner"
               })
           )

    assert {:error, :access_denied} = Vault.get(slug, accessor: @provisioner)

    assert [%{accessor_type: "system", accessor_id: @principal_id}] =
             Enum.filter(logs_for_slug(slug), &(&1.action == "denied"))
  end

  test "agent grant edits never touch a system grant" do
    secret = shared!(unique_slug(), "value-#{unique()}")
    admin = admin!()
    agent = agent!()

    :ok = Shared.grant_system(admin, secret.id, "installs-provisioner")
    :ok = Shared.set_grants(admin, secret.id, [agent.id])
    :ok = Shared.set_grants(admin, secret.id, [])

    assert [_] = system_grants(secret.id)
  end

  test "only a root admin may grant or revoke, and only a known reader" do
    secret = shared!(unique_slug(), "value-#{unique()}")

    assert {:error, :unauthorized} =
             Shared.grant_system(non_admin!(), secret.id, "installs-provisioner")

    assert {:error, :unauthorized} =
             Shared.revoke_system_grant(nil, secret.id, "installs-provisioner")

    assert {:error, :unknown_system_principal} =
             Shared.grant_system(admin!(), secret.id, "anything-else")

    assert {:error, :not_found} =
             Shared.grant_system(admin!(), Ecto.UUID.generate(), "installs-provisioner")

    assert system_grants(secret.id) == []
  end

  describe "the prod data migration" do
    setup do
      unless Code.ensure_loaded?(@migration_module), do: Code.require_file(@migration)
      :ok
    end

    test "is a no-op when the secret is absent, and idempotent when present" do
      Repo.query!(@migration_module.grant_sql())

      assert Repo.aggregate(from(g in AccessGrant, where: g.grantee_type == "system"), :count) ==
               0

      secret = shared!(@do_slug, @fake_token)
      assert {:error, :access_denied} = Vault.get(@do_slug, accessor: @provisioner)

      Repo.query!(@migration_module.grant_sql())
      Repo.query!(@migration_module.grant_sql())

      assert [%AccessGrant{permissions: ["use"]}] = system_grants(secret.id)
      assert {:ok, @fake_token} = Vault.get(@do_slug, accessor: @provisioner)

      assert [%{metadata: meta}] =
               Enum.filter(logs_for_slug(@do_slug), &(&1.action == "update"))

      assert meta == %{
               "grant" => "added",
               "system_principal" => "installs-provisioner",
               "via" => "migration"
             }

      # Revocable like any admin-written grant.
      assert :ok = Shared.revoke_system_grant(admin!(), secret.id, "installs-provisioner")
      assert {:error, :access_denied} = Vault.get(@do_slug, accessor: @provisioner)
    end
  end
end
