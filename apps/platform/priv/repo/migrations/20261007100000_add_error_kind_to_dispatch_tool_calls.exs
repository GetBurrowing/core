defmodule Platform.Repo.Migrations.AddErrorKindToDispatchToolCalls do
  @moduledoc """
  Task 01a115b5 stage 1: a `suite_run` ledger row whose run failed records
  an enumerated `error_kind` (one of `Platform.CodeMode.Run.error_kinds/0`).
  Never the error message, the script, its inputs or its result.
  """
  use Ecto.Migration

  def change do
    alter table(:dispatch_tool_calls) do
      add(:error_kind, :text)
    end
  end
end
