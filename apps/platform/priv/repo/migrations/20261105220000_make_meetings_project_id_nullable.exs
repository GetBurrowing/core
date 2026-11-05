defmodule Platform.Repo.Migrations.MakeMeetingsProjectIdNullable do
  use Ecto.Migration

  @moduledoc """
  Makes `meetings.project_id` nullable so a project-less channel's
  ad-hoc meeting can persist (task 01a04e9e stage 2).

  ## Why nullable rather than optional-metadata

  The channel quick-meet binds its `meetings` row to the channel's
  EXISTING chat space, so there is no meeting-scoped project to derive
  from — chat spaces carry no `project_id` column, and a channel is not
  required to belong to a project at all. The scheduled path is
  untouched: `Platform.Meetings.create_meeting/1` still enforces
  `:project_id` through its `require_present/2` guard and through
  `Meeting.changeset/2`'s `foreign_key_constraint` (dropping the
  `@required_fields` entry does not weaken the FK check for the values
  that DO arrive). A nil `project_id` on an ad-hoc row is the
  project-less channel's supported state, exactly as the "started but
  never scheduled" pair (`scheduled_start_at`/`scheduled_end_at` nil)
  is for every ad-hoc meeting.

  ## Why plain `:binary_id` in `modify` (no `references/2`)

  `meetings.project_id` already carries its FK as
  `meetings_project_id_fkey` from `20260514120000_create_meetings`
  (`references(:projects, type: :binary_id, on_delete: :delete_all)`),
  and that constraint survives this alter untouched. Repassing
  `references/2` here would make Ecto attempt to CREATE the same
  constraint again and fail with `duplicate_object` — the original
  formulation of this migration did exactly that on `mix ecto.migrate`.
  Only the NOT NULL attribute changes; the FK, its name, and its
  delete behavior are all preserved as-is.

  ## Down-migration risk (accepted)

  The inverse re-applies `null: false`. The table holds no rows at this
  worktree's current migration head, but on a deployed database any
  rows minted with nil `project_id` since this migration ran would make
  the down-migration fail with a NOT NULL violation. That is
  deliberate: silently NULL-coercing or deleting real meeting rows to
  win the rollback is worse than failing loudly. If a rollback is ever
  needed, the operator first retro-fills `project_id` for the nil rows
  (the staged fix this ticket explicitly defers) or deletes the
  ad-hoc rows, then rolls back.
  """

  def up do
    alter table(:meetings) do
      modify(:project_id, :binary_id, from: {:binary_id, null: false}, null: true)
    end
  end

  def down do
    alter table(:meetings) do
      modify(:project_id, :binary_id, from: {:binary_id, null: true}, null: false)
    end
  end
end
