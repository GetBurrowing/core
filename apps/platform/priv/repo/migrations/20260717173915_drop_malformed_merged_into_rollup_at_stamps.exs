defmodule Platform.Repo.Migrations.DropMalformedMergedIntoRollupAtStamps do
  @moduledoc """
  Task 019f708f stage 3 — one-shot data cleanup to remove
  `metadata["merged_into_rollup_at"]` stamps that predate bug #3's
  shape enforcement.

  Stage 3 (this task) added `validate_metadata/1` to
  `Platform.Tasks.Task.changeset/2` requiring the stamp to be a map
  with `%{"sha" => <>= 7 hex chars>, "at" => <iso8601>}`. Any row
  written pre-fix carrying a bare string, missing keys, or a
  non-object shape must be scrubbed — otherwise every downstream
  `%{"sha" => sha}` pattern match in `stack_deployer.ex` (lines 885,
  891, 1159, 1331) still risks a FunctionClauseError, and the
  changeset would reject any legitimate update to the same row
  (`Ecto.Changeset` runs validations across the row's full attrs on
  every update).

  ## Predicate

  Drop the `merged_into_rollup_at` key from `tasks.metadata` when:

    * the key exists AT ALL (`metadata ? 'merged_into_rollup_at'`), AND
    * the resolved value at `metadata -> 'merged_into_rollup_at' ->>
      'sha'` is `NULL` — i.e. the value is a scalar (bare string),
      or a JSON object without a `"sha"` key, or a non-object type.

  Well-shaped stamps (`{"sha": "<hex>", "at": "<iso>"}`) resolve
  `->> 'sha'` to a non-null string and are LEFT ALONE — the migration
  is a targeted purge, not a blanket clear.

  ## Idempotence

  Re-invocation is a no-op — after the first pass, no row satisfies
  the predicate. Logged count is 0 on subsequent runs.

  ## One-way door

  `down/0` is a warning-only no-op. Malformed stamps were unusable
  in the first place (that's what motivated bug #3); reinstating them
  would revive the exact FunctionClauseError class we're closing.
  Restore from a database backup if a rollback is ever required.
  """

  use Ecto.Migration

  @migration_id "20260717173915"

  def up do
    {count, _} = drop_malformed_stamps(repo())

    IO.puts(
      "[Migration #{@migration_id}] dropped #{count} malformed " <>
        "merged_into_rollup_at stamps from tasks.metadata"
    )

    :ok
  end

  def down do
    IO.warn(
      "drop_malformed_merged_into_rollup_at_stamps is one-way; deleted " <>
        "stamp values cannot be restored — restore from a database backup " <>
        "taken before #{@migration_id} if regression required"
    )

    :ok
  end

  @doc """
  Strip the malformed `merged_into_rollup_at` entry from every row that
  satisfies the predicate. Returns `{rows_updated, nil}` — the raw
  `Repo.query!/1` result tuple with the affected-row count.
  """
  @spec drop_malformed_stamps(module()) :: {non_neg_integer(), nil}
  def drop_malformed_stamps(repo) do
    %Postgrex.Result{num_rows: n} =
      repo.query!("""
      UPDATE tasks
         SET metadata = metadata - 'merged_into_rollup_at'
       WHERE (metadata -> 'merged_into_rollup_at' ->> 'sha') IS NULL
         AND metadata ? 'merged_into_rollup_at'
      """)

    {n, nil}
  end
end
