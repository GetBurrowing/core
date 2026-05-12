defmodule Platform.Repo.Migrations.AddMetadataToTaskStacks do
  use Ecto.Migration

  @moduledoc """
  Task Stacks T5 stage 2 — add a `metadata` jsonb column to `task_stacks`.

  Stage 2 of T5 (per-member rollup merge) needs a place to record
  conflict information when a member branch fails to auto-merge into
  the stack rollup. Per ADR 0041 §"Rollup-branch merge", a conflict
  halts the stack and the offending files are surfaced to the operator.

  The shape we'll write under conflict (illustrative — no schema
  enforcement):

      %{
        "conflict" => %{
          "member_task_id" => "<uuid>",
          "files"          => ["path/a", "path/b"],
          "at"             => "<iso8601>"
        }
      }

  Additional sub-keys (e.g. PR url after stage 4, CI failure marker
  after stage 5) will be added under their own top-level keys without
  needing further migrations.

  T1 stage 1 (the initial `task_stacks` create migration) intentionally
  scoped narrow and deferred this column; landing it here keeps the
  scope creep contained to a single follow-up migration.
  """

  def change do
    alter table(:task_stacks) do
      add(:metadata, :map, null: false, default: %{})
    end
  end
end
