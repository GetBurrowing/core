defmodule Platform.Repo.Migrations.AddResponsibilityToStages do
  use Ecto.Migration

  @moduledoc """
  Adds a nullable `responsibility` column to `stages`. Later stages of task
  019f5d47 (stage-level responsibility routing) resolve this value at dispatch
  time via `Platform.Roles.agent_id_for_role/1` and route the stage's prompt
  to the corresponding runtime.

  Progressive enhancement — the column is nullable with no default and no
  CHECK constraint. Existing rows stay `responsibility: nil` and their
  dispatch behavior is unchanged.
  """

  def change do
    alter table(:stages) do
      add(:responsibility, :text)
    end
  end
end
