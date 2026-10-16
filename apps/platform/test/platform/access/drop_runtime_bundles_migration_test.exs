defmodule Platform.Access.DropRuntimeBundlesMigrationTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Federation
  alias Platform.Repo
  alias Platform.RuntimeBundleSnapshot

  @version 20_261_016_030_000
  @migration Platform.Repo.Migrations.DropAgentRuntimesAllowedBundles
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    [path] =
      Path.wildcard(Path.join(:code.priv_dir(:platform), "repo/migrations/#{@version}_*.exs"))

    unless Code.ensure_loaded?(@migration), do: Code.require_file(path)
    :ok
  end

  test "drop verifies profiles and down restores every ordered legacy array without changing other runtime columns" do
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    owner = root_admin!()

    rows =
      for %{key: key, bundles: bundles} <- RuntimeBundleSnapshot.snapshots() do
        {:ok, runtime} =
          Federation.register_runtime(owner.id, %{runtime_id: "drop-profile-#{key}"})

        uuid = Ecto.UUID.dump!(runtime.id)

        Repo.query!("UPDATE agent_runtimes SET allowed_bundles = $1::text[] WHERE id = $2", [
          bundles,
          uuid
        ])

        Repo.query!(
          "UPDATE access_runtime_profiles SET tool_profile = $1::text[] WHERE runtime_id = $2",
          [bundles, uuid]
        )

        {uuid, bundles}
      end

    before = runtime_hashes_without_bundles()
    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)
    assert runtime_hashes_without_bundles() == before
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    assert runtime_hashes_without_bundles() == before

    for {id, bundles} <- rows do
      %{rows: [[restored]]} =
        Repo.query!("SELECT allowed_bundles FROM agent_runtimes WHERE id = $1", [id])

      assert restored == bundles
    end

    {id, _} = hd(rows)

    Repo.query!(
      "UPDATE access_runtime_profiles SET tool_profile = ARRAY[]::text[] WHERE runtime_id = $1",
      [id]
    )

    assert_raise RuntimeError, ~r/translation is missing or differs/, fn ->
      Ecto.Migrator.up(Repo, @version, @migration, @opts)
    end

    Repo.query!("DELETE FROM access_runtime_profiles WHERE runtime_id = $1", [id])

    assert_raise RuntimeError, ~r/translation is missing or differs/, fn ->
      Ecto.Migrator.up(Repo, @version, @migration, @opts)
    end

    {_, bundles} = hd(rows)

    Repo.query!(
      "INSERT INTO access_runtime_profiles (runtime_id, tool_profile, inserted_at, updated_at) VALUES ($1, $2::text[], now(), now())",
      [id, bundles]
    )

    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)
    assert runtime_hashes_without_bundles() == before
  end

  defp runtime_hashes_without_bundles do
    Repo.query!(
      "SELECT id, md5((to_jsonb(r) - 'allowed_bundles')::text) FROM agent_runtimes r ORDER BY id"
    ).rows
  end
end
