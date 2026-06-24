defmodule Platform.Repo.Migrations.AddEnabledAndMetadataToResponsibilities do
  use Ecto.Migration

  @moduledoc """
  Responsibilities & External Agents — M1 stage 2 (task 019ef65b-2099).

  Adds the two columns the planner specified in stage 1 but which were
  dropped from the stage-1 migration:

  * `enabled :boolean null:false default:true` — operator kill-switch.
    The M6 router pre-filters on this column (`get_by_trigger/1` only
    returns enabled rows). `upsert_by_key/1` deliberately omits this
    field from its replace-set so operator-set values survive boot-time
    re-registration by providers.
  * `metadata :map null:false default:%{}` — free-form provider-specific
    extras (jsonb). Not interpreted by the platform; providers may use
    it for routing hints, feature flags, etc.

  Also adds the `default_prompt_template` index the stage-1 planner spec
  called for. M2 will join `responsibilities` against `prompt_templates`
  on this column, so the index is a cheap insurance policy now.

  Reversible: each `alter table` + `create index` pair has a matching
  `drop` in `down/0`.
  """

  def up do
    alter table(:responsibilities) do
      add(:enabled, :boolean, null: false, default: true)
      add(:metadata, :map, null: false, default: %{})
    end

    create(index(:responsibilities, [:default_prompt_template]))
  end

  def down do
    drop(index(:responsibilities, [:default_prompt_template]))

    alter table(:responsibilities) do
      remove(:metadata)
      remove(:enabled)
    end
  end
end
