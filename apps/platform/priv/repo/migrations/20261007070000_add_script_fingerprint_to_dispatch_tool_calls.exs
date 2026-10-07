defmodule Platform.Repo.Migrations.AddScriptFingerprintToDispatchToolCalls do
  @moduledoc """
  Task 01a114a8 stage 2: a `suite_run` ledger row records the sha256 and byte
  length of its script. Never the script, its inputs or its result.
  """
  use Ecto.Migration

  def change do
    alter table(:dispatch_tool_calls) do
      add(:script_sha256, :text)
      add(:script_bytes, :integer)
    end
  end
end
