defmodule Platform.Repo.Migrations.CreateResponsibilities do
  use Ecto.Migration

  @moduledoc """
  Responsibilities & External Agents — M1 stage 1 (task 019ef65b-2099).

  Implements the schema portion of ADR-0041 M1: the `responsibilities` table
  is the registry of declarative "what should the platform do automatically"
  records. Each row pins a feature responsibility (e.g. `meetings.summarize`)
  to a trigger kind, a scope, the context it expects to receive, the output
  contract it must produce, and a default prompt template. Later milestones
  layer a Registry GenServer, the M6 router, and the M8 cutover on top of
  this table — none of those land in this stage.

  Reversible: `change/0` uses `create table` + `create index`, both of which
  Ecto can run in both directions, so `mix ecto.rollback` drops the indices
  then the table cleanly.

  Forbidden in this stage (deferred to M1 stages 2-4):
  - The `Platform.Responsibilities` context module (stage 2).
  - The `Provider` behaviour + Registry GenServer (stage 3).
  - The registration API + supervision wiring (stage 4).
  """

  def change do
    create table(:responsibilities, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:key, :string, null: false)
      add(:feature, :string, null: false)
      add(:trigger_kind, :string, null: false)
      add(:trigger_config, :map, null: false, default: %{})
      add(:scope, :string, null: false)
      add(:context_provided, {:array, :string}, null: false, default: [])
      add(:output_contract, :map, null: false, default: %{})
      add(:default_prompt_template, :string)
      add(:cost_profile, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:responsibilities, [:key]))
    create(index(:responsibilities, [:feature]))
    create(index(:responsibilities, [:trigger_kind]))
    create(index(:responsibilities, [:scope]))

    # DB-side guard rails for the enum-like columns. The Ecto changeset is
    # the primary line of defense, but the check constraints keep raw SQL
    # writes (admin tooling, seed scripts, future MCP tools) honest.
    create(
      constraint(:responsibilities, :responsibilities_trigger_kind_check,
        check: "trigger_kind IN ('cron','event_topic','chat_pattern','webhook')"
      )
    )

    create(
      constraint(:responsibilities, :responsibilities_scope_check,
        check: "scope IN ('global','per_org','per_project','per_space','per_meeting')"
      )
    )

    create(
      constraint(:responsibilities, :responsibilities_cost_profile_check,
        check: "cost_profile IN ('high_freq_low_cost','low_freq_capable')"
      )
    )

    create(
      constraint(:responsibilities, :responsibilities_key_format_check,
        check: "key ~ '^[a-z][a-z0-9_]*\\.[a-z][a-z0-9_]*$'"
      )
    )
  end
end
