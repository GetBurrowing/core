defmodule Platform.Repo.Migrations.DropHostedInstallsTablesTest do
  @moduledoc """
  Task 01a19249 stage 5: the drop migration runs against a database that
  still holds the old tables and the provisioner grant (prod) and against a
  fresh one that never had them (the IF EXISTS path), deletes only that one
  grant row, leaves the shared credential in place, and refuses `down`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Credential
  alias Platform.Vault.Shared

  @migration Path.expand(
               "../../../../priv/repo/migrations/20261031160000_drop_hosted_installs_tables.exs",
               __DIR__
             )
  Code.require_file(@migration)
  alias Platform.Repo.Migrations.DropHostedInstallsTables, as: Migration

  @principal_id "e3ee1349-ca10-46f7-aaa9-65205a820f86"
  @test_reader_id "5b6195d9-a785-48ac-b3b5-619708e4130e"

  defp table?(name) do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::text", [name])
    oid != nil
  end

  defp run_up, do: Enum.each(Migration.up_sql(), &Repo.query!/1)

  defp old_tables! do
    Repo.query!("""
    CREATE TABLE installs (
      id uuid PRIMARY KEY, slug varchar NOT NULL, status varchar NOT NULL,
      inserted_at timestamp NOT NULL, updated_at timestamp NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE install_request_settings (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), singleton boolean NOT NULL DEFAULT true,
      auto_provision_requests boolean NOT NULL DEFAULT false
    )
    """)

    Repo.query!(
      "INSERT INTO installs VALUES (gen_random_uuid(), 'acme', 'destroyed', now(), now())"
    )

    Repo.query!("INSERT INTO install_request_settings DEFAULT VALUES")
  end

  defp system_grant!(credential_id, grantee_id) do
    Repo.insert!(%AccessGrant{
      credential_id: credential_id,
      grantee_type: "system",
      grantee_id: grantee_id,
      permissions: ["use"]
    })
  end

  defp grants(credential_id) do
    from(g in AccessGrant, where: g.credential_id == ^credential_id, order_by: g.grantee_type)
    |> Repo.all()
    |> Enum.map(&{&1.grantee_type, &1.grantee_id})
  end

  test "on a fresh database (no tables, no grant) it is a no-op that succeeds" do
    refute table?("installs")
    refute table?("install_request_settings")

    run_up()
    run_up()

    refute table?("installs")
    refute table?("install_request_settings")
  end

  test "on a database holding the old tables it drops both and only the provisioner grant" do
    old_tables!()
    assert table?("installs")
    assert table?("install_request_settings")

    admin = admin!()
    agent = agent!()

    {:ok, do_token} =
      Shared.create(admin, %{slug: "digital-ocean-api-infra", value: "dop_v1_fake"}, [])

    {:ok, other} = Shared.create(admin, %{slug: unique_slug(), value: "v-#{unique()}"}, [])

    system_grant!(do_token.id, @principal_id)
    system_grant!(do_token.id, @test_reader_id)
    :ok = Shared.set_grants(admin, do_token.id, [agent.id])
    system_grant!(other.id, @test_reader_id)

    run_up()

    refute table?("installs")
    refute table?("install_request_settings")

    # The provisioner's row is gone; every other grant, on that credential
    # and on any other, is untouched.
    assert grants(do_token.id) == [{"agent", agent.id}, {"system", @test_reader_id}]
    assert grants(other.id) == [{"system", @test_reader_id}]

    refute Repo.exists?(
             from(g in AccessGrant,
               where: g.grantee_type == "system" and g.grantee_id == ^@principal_id
             )
           )

    # The credential itself stays.
    assert Repo.get(Credential, do_token.id)

    assert [%{metadata: meta, accessor_type: "system"}] =
             Enum.filter(
               logs_for_slug("digital-ocean-api-infra"),
               &(&1.action == "update" and &1.metadata["via"] == "migration")
             )

    assert meta == %{
             "grant" => "removed",
             "system_principal" => "installs-provisioner",
             "via" => "migration"
           }

    # Re-running writes no second log row.
    run_up()

    assert [_] =
             Enum.filter(
               logs_for_slug("digital-ocean-api-infra"),
               &(&1.metadata["via"] == "migration")
             )
  end

  test "down raises: the data is not restored into core" do
    assert_raise Ecto.MigrationError, ~r/irreversible/, fn -> Migration.down() end
  end
end
