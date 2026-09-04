defmodule Platform.Repo.Migrations.AddInteractiveGateToPlatformFiles do
  @moduledoc """
  Task `01a06a20` stage 1 — the gate that decides whether a file may run
  its own code.

  Not a boolean. `interactive_at` (nullable, non-nil means "may run its
  own code") pairs with `interactive_by_user_id` (who flipped it) because
  after an incident the only question that matters is who turned scripts
  on and when — a boolean can't answer that. Mirrors the existing
  `deleted_at` soft-delete shape on this same table
  (`20260720010000_add_deleted_at_to_platform_files.exs`): both columns
  are nullable, move together, and are set/cleared exclusively by
  dedicated `Platform.Files` functions
  (`mark_interactive/2` / `unmark_interactive/2`) rather than through the
  general changeset cast.

  `interactive_by_user_id` nilifies on user delete, same as
  `uploaded_by_user_id` on this table — the file's execution history is
  historical fact and outlives the user who set it.

  No index: like `ingest_failure_count`
  (`20260814160000_add_ingest_failure_count_to_platform_files.exs`), this
  column is read off rows a project-scoped query has already loaded, not
  used as a filter or sort key. Revisit if a later stage adds an
  "all interactive files" admin view.
  """

  use Ecto.Migration

  def change do
    alter table(:platform_files) do
      add(:interactive_at, :utc_datetime_usec, null: true)

      add(
        :interactive_by_user_id,
        references(:users, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end
  end
end
