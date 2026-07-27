defmodule Platform.Repo.Migrations.RenameDreamConsolidationBundleKey do
  @moduledoc """
  Repoints the historian's dreaming duty from the stale seed key
  `memory.dream_consolidation` to the key the runtime actually fires,
  `memory.dreaming` (task `019fa230` stage 2).

  ## Why a migration and not just the seed edit

  `Platform.Roles.Seeds.seed_defaults/0` inserts bundle rows with
  `on_conflict: :nothing` against `role_responsibilities_pair_idx`.
  Re-seeding therefore ADDS the `memory.dreaming` pair row and leaves
  the stale `memory.dream_consolidation` pair row exactly where it was —
  the Control Center advanced panel would then render BOTH, one of which
  is still dead. The stale row has to be deleted explicitly.

  ## Order of operations in `up/0`

    1. Repoint `responsibility_overrides` rows from the stale key to
       the live key. `responsibility_overrides_responsibility_key_index`
       is UNIQUE on `responsibility_key`, so a naive
       `UPDATE ... SET responsibility_key = 'memory.dreaming'` raises
       whenever an override already exists on the live key. Handled by
       deleting the STALE row first when both are present: the live-key
       row is the one an operator's override could actually have taken
       effect through, so it wins, and the discarded stale pin is
       logged rather than silently overwritten.
    2. Delete the stale `role_responsibilities` pair row.
    3. Re-run `Seeds.seed_defaults/1` (scoped to `historian`) to insert
       the `memory.dreaming` pair row on already-migrated environments.
       Mirrors `20260702200500_seed_meeting_producer_role.exs`; the
       `only_keys:` gate keeps this migration from tripping a future
       `roles_key_check` extension for a role added after this
       timestamp.

  A census of how many override rows were repointed (and how many were
  discarded as colliding) is logged at `:info` so an operator can see
  whether anyone had actually set this knob. A census inside `up/0`
  terminates; a drain period would not.

  `down/0` reverses the pair row only. Override repointing is NOT
  reversed: after `up/0` the two pins are indistinguishable, so guessing
  which rows to send back to the stale key would fabricate history. The
  stale key is dead on the way down anyway.
  """

  use Ecto.Migration

  require Logger

  @stale_key "memory.dream_consolidation"
  @live_key "memory.dreaming"
  @role_key "historian"

  def up do
    repo = Platform.Repo

    # (a) Resolve the unique-index collision BEFORE the UPDATE. If an
    # override already exists on the live key, the stale row cannot be
    # repointed onto it — drop the stale pin and say so.
    %{num_rows: discarded} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        DELETE FROM responsibility_overrides
        WHERE responsibility_key = $1
          AND EXISTS (
            SELECT 1 FROM responsibility_overrides WHERE responsibility_key = $2
          )
        """,
        [@stale_key, @live_key]
      )

    %{num_rows: repointed} =
      Ecto.Adapters.SQL.query!(
        repo,
        "UPDATE responsibility_overrides SET responsibility_key = $1, updated_at = NOW() WHERE responsibility_key = $2",
        [@live_key, @stale_key]
      )

    # (b) Drop the stale bundle row so the panel stops offering it.
    %{num_rows: unbundled} =
      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
        [@role_key, @stale_key]
      )

    # (c) Insert the live pair row on environments that already ran the
    # original seed migration.
    Platform.Roles.Seeds.seed_defaults(only_keys: [@role_key])

    Logger.info(
      "[019fa230] #{@stale_key} -> #{@live_key}: " <>
        "#{repointed} override row(s) repointed, " <>
        "#{discarded} colliding stale override row(s) discarded (live-key pin kept), " <>
        "#{unbundled} stale bundle row(s) removed from role `#{@role_key}`"
    )
  end

  def down do
    repo = Platform.Repo

    Ecto.Adapters.SQL.query!(
      repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      [@role_key, @live_key]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO role_responsibilities (id, role_key, responsibility_key, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, NOW(), NOW())
      ON CONFLICT DO NOTHING
      """,
      [@role_key, @stale_key]
    )
  end
end
