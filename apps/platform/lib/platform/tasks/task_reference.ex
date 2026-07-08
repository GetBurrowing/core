defmodule Platform.Tasks.TaskReference do
  @moduledoc """
  A derived row: `source_task`'s description mentions `target_task`'s UUID.

  Populated by `Platform.Tasks.References` (stage 2) synchronously on task
  create/update, and by the migration's one-shot backfill for anything that
  existed before the write-path hook shipped. One row per unique
  `(source, target)` pair — `ON CONFLICT DO NOTHING` on insert.

  The composite primary key `(source_task_id, target_task_id)` is the
  uniqueness constraint. A separate `idx_task_references_target` index makes
  `follow_up_task_ids(target)` (stage 3) an index scan, not a seq scan.

  Both foreign keys are `ON DELETE CASCADE`: if either the source or the
  target task is hard-deleted, the reference row goes with it. This module
  intentionally has no `changeset/2` for updates because the row is
  insert-only — the app either re-computes the set of references from the
  current description text and inserts new rows / deletes stale ones, or it
  does nothing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.Task

  @primary_key false
  @foreign_key_type :binary_id

  schema "task_references" do
    belongs_to(:source_task, Task, primary_key: true)
    belongs_to(:target_task, Task, primary_key: true)

    field(:inserted_at, :utc_datetime_usec)
  end

  @doc """
  Insert-only changeset. Enforces the two-column shape and forbids
  self-references at the changeset layer (the DB accepts them but they
  are a bug — a task cannot be its own follow-up).
  """
  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [:source_task_id, :target_task_id])
    |> validate_required([:source_task_id, :target_task_id])
    |> validate_not_self_reference()
    |> foreign_key_constraint(:source_task_id)
    |> foreign_key_constraint(:target_task_id)
    |> unique_constraint([:source_task_id, :target_task_id],
      name: :task_references_pkey,
      message: "already references this target"
    )
  end

  defp validate_not_self_reference(changeset) do
    source = get_field(changeset, :source_task_id)
    target = get_field(changeset, :target_task_id)

    if source && target && source == target do
      add_error(changeset, :target_task_id, "cannot equal source_task_id")
    else
      changeset
    end
  end
end
