defmodule Platform.Repo.Migrations.CreateAccessRuntimeProfiles do
  use Ecto.Migration

  @moduledoc """
  Copy ordered runtime bundles into Access-owned profiles for task
  01a1386e-1710 stage 2. This is a one-time translation of existing rows;
  a fresh database has no runtimes to translate.
  """

  def up do
    create table(:access_runtime_profiles, primary_key: false) do
      add(:runtime_id, references(:agent_runtimes, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:tool_profile, {:array, :text})
      add(:restricted_permissions, :map)
      add(:updated_by, :binary_id)
      timestamps(type: :utc_datetime_usec)
    end

    flush()

    repo().query!("""
    INSERT INTO access_runtime_profiles
      (runtime_id, tool_profile, inserted_at, updated_at)
    SELECT id, allowed_bundles, now(), now() FROM agent_runtimes
    """)

    %{rows: arrays} = repo().query!("SELECT DISTINCT allowed_bundles FROM agent_runtimes")

    Enum.each(arrays, fn [bundles] ->
      permissions =
        bundles
        |> Enum.flat_map(&Platform.Access.ToolPermissions.bundle_permissions/1)
        |> Map.new(&{&1, "all"})

      repo().query!(
        "UPDATE access_runtime_profiles SET restricted_permissions = $1::jsonb WHERE tool_profile = $2::text[]",
        [Jason.encode!(permissions), bundles]
      )
    end)

    assert_copied!(repo())
  end

  @doc false
  def assert_copied!(repository) do
    %{rows: [[runtime_count, profile_count, mismatch_count]]} =
      repository.query!("""
      SELECT (SELECT count(*) FROM agent_runtimes),
             (SELECT count(*) FROM access_runtime_profiles),
             (SELECT count(*) FROM access_runtime_profiles p
                JOIN agent_runtimes r ON r.id = p.runtime_id
               WHERE p.tool_profile IS DISTINCT FROM r.allowed_bundles)
      """)

    if runtime_count != profile_count or mismatch_count != 0,
      do: raise("access runtime profile translation did not preserve every ordered array")
  end

  def down, do: drop(table(:access_runtime_profiles))
end
