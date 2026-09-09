defmodule Platform.Repo.Migrations.AgentRuntimeMeetingsBundle do
  use Ecto.Migration

  @moduledoc """
  Task 01a066af stage 4 — grant the new `meetings` bundle to every existing
  runtime.

  `agent_runtimes.allowed_bundles` takes its default from the Ecto SCHEMA, not
  from a database column default, so widening
  `AgentRuntime.default_allowed_bundles/0` reaches only rows inserted after the
  change. Without this migration no currently-registered runtime gains
  `meetings`, and — worse — any runtime that was granted `task` specifically to
  reach `meeting_create` LOSES that reach the moment the tool moves out of the
  `task` bundle. Losing a working capability is the regression this UPDATE
  prevents.

  Granting the bundle to everyone is defensible because the bundle is not the
  real gate. `meeting_say` is guarded independently by the private
  `ensure_agent_in_room/2` in `Platform.Meetings`: an agent no human ever
  invited into a room still gets `:not_in_room`, so the grant on its own lets
  it speak nowhere. `meeting_create` was already reachable by every runtime holding
  `task`.

  Idempotent — a re-run matches zero rows, and `array_append` is guarded by the
  `NOT (... = ANY(...))` predicate so a row that already holds the bundle is
  never given a duplicate.

  `down` removes the bundle from every row rather than restoring each row's
  exact prior array, which is recorded nowhere. That is the same shape as the
  `skill` and `attachment` bundle migrations before it, and it is right for the
  case that matters: rolling back the code that registers the bundle, after
  which `validate_subset(:allowed_bundles, @valid_bundles)` would reject every
  changeset on a row still holding a bundle the old code does not know.
  """

  @grant_sql """
  UPDATE agent_runtimes
  SET allowed_bundles = array_append(allowed_bundles, 'meetings')
  WHERE NOT ('meetings' = ANY(allowed_bundles))
  """

  @revoke_sql """
  UPDATE agent_runtimes
  SET allowed_bundles = array_remove(allowed_bundles, 'meetings')
  """

  def up, do: execute(@grant_sql)

  def down, do: execute(@revoke_sql)

  @doc """
  Test hook: the same UPDATE, run directly against `repo` without the migration
  Runner scaffolding.

  Migrations have already run to `:up` before ExUnit boots, so `up/0` cannot be
  exercised through `Ecto.Migrator` inside the sandbox transaction. This is the
  identical SQL, so a test that drives it is testing the migration and not a
  paraphrase of it.
  """
  def grant_meetings_bundle(repo \\ Platform.Repo), do: repo.query!(@grant_sql)
end
