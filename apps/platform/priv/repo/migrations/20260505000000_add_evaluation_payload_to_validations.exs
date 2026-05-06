defmodule Platform.Repo.Migrations.AddEvaluationPayloadToValidations do
  use Ecto.Migration

  @moduledoc """
  Add the `evaluation_payload` jsonb column to `validations` so the new
  `e2e_behavior` validation kind can carry its planner-authored behavioral
  script (setup / actions / expected / failure_feedback) inline.

  Additive only — existing rows remain untouched (nullable column).
  """
  def change do
    alter table(:validations) do
      add(:evaluation_payload, :map, null: true)
    end
  end
end
