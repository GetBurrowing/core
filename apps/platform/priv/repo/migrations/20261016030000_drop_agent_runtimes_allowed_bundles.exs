defmodule Platform.Repo.Migrations.DropAgentRuntimesAllowedBundles do
  use Ecto.Migration

  @moduledoc """
  Task 01a1386e-1710 stage 4 removes the legacy bundle column only after
  verifying that every runtime's ordered array is preserved in its Access
  profile. The down migration restores arrays from those same profiles.
  """

  @defaults ~w(federation space context_read messaging attachment skill meetings mail)

  def up do
    assert_translated!(repo())

    alter table(:agent_runtimes) do
      remove(:allowed_bundles)
    end
  end

  @doc false
  def assert_translated!(repository) do
    %{rows: [[mismatches]]} =
      repository.query!("""
      SELECT count(*)
        FROM agent_runtimes r
        LEFT JOIN access_runtime_profiles p ON p.runtime_id = r.id
       WHERE p.runtime_id IS NULL
          OR p.tool_profile IS DISTINCT FROM r.allowed_bundles::text[]
      """)

    if mismatches != 0,
      do: raise("access runtime profile translation is missing or differs from allowed_bundles")
  end

  def down do
    alter table(:agent_runtimes) do
      add(:allowed_bundles, {:array, :text}, null: false, default: @defaults)
    end

    flush()

    repo().query!("""
    UPDATE agent_runtimes r
       SET allowed_bundles = p.tool_profile
      FROM access_runtime_profiles p
     WHERE p.runtime_id = r.id
       AND p.tool_profile IS NOT NULL
    """)
  end
end
