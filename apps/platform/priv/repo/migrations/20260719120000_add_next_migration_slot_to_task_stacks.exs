defmodule Platform.Repo.Migrations.AddNextMigrationSlotToTaskStacks do
  use Ecto.Migration

  @moduledoc """
  Per-stack monotonic migration-slot allocator (task 019f7b7e stage 1).

  Members of a stack each run `mix ecto.gen.migration` independently on
  their own worktree; two members generating in the same second produce
  the SAME `YYYYMMDDHHMMSS` filename prefix. Ecto then silently skips one
  of them. This column is the durable cursor `Stacks.allocate_migration_slot/1`
  advances under a per-stack advisory lock so each member reserves a
  distinct timestamp.

  `null: true` is deliberate: pre-existing stacks have legitimately never
  allocated a slot. Lazy init at first allocation beats a data backfill
  that would invent a meaningless wall-clock anchor for dormant stacks.
  """
  def change do
    alter table(:task_stacks) do
      add :next_migration_slot, :naive_datetime, null: true
    end
  end
end
