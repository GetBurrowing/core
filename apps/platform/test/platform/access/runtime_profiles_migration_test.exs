defmodule Platform.Access.RuntimeProfilesMigrationTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo
  alias Platform.RuntimeBundleSnapshot

  @version 20_261_016_010_000
  @migration Platform.Repo.Migrations.CreateAccessRuntimeProfiles
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    [path] =
      Path.wildcard(Path.join(:code.priv_dir(:platform), "repo/migrations/#{@version}_*.exs"))

    unless Code.ensure_loaded?(@migration), do: Code.require_file(path)
    :ok
  end

  test "up copies every snapshot array in order and down leaves runtime bytes unchanged" do
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    owner = root_admin!()

    runtimes =
      for %{key: key, bundles: bundles} <- RuntimeBundleSnapshot.snapshots() do
        runtime =
          Repo.insert!(%AgentRuntime{
            runtime_id: "profile-migration-#{key}",
            owner_user_id: owner.id,
            allowed_bundles: bundles
          })

        {runtime.id, bundles}
      end

    before = runtime_hashes()
    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)

    for {id, bundles} <- runtimes do
      %{rows: [[copied, restricted]]} =
        Repo.query!(
          "SELECT tool_profile, restricted_permissions FROM access_runtime_profiles WHERE runtime_id = $1",
          [Ecto.UUID.dump!(id)]
        )

      assert copied == bundles
      assert restricted == RuntimeProfiles.translated_permissions(bundles)

      runtime = Repo.get!(AgentRuntime, id)
      legacy = RuntimeBundleSnapshot.legacy_tool_names(bundles)

      expected =
        if Enum.member?(bundles, "play"),
          do: Enum.reject(legacy, &String.starts_with?(&1, "play_session_")),
          else: legacy

      assert Tools.tool_names(runtime) == expected
    end

    assert runtime_hashes() == before
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    assert runtime_hashes() == before
    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)
    assert runtime_hashes() == before

    {id, _} = hd(runtimes)

    Repo.query!(
      "UPDATE access_runtime_profiles SET tool_profile = ARRAY[]::text[] WHERE runtime_id = $1",
      [Ecto.UUID.dump!(id)]
    )

    assert_raise RuntimeError, ~r/did not preserve every ordered array/, fn ->
      apply(@migration, :assert_copied!, [Repo])
    end
  end

  defp runtime_hashes do
    Repo.query!("SELECT id, md5(row_to_json(r)::text) FROM agent_runtimes r ORDER BY id").rows
  end
end
