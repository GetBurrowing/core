defmodule Platform.Repo.Migrations.CreateCalendarDrafts do
  @moduledoc """
  Task 01a1b8a5 stage 3 (scheduling language through a real agent).

  `calendar_drafts` holds the write-free handoff an agent's `calendar_draft`
  tool leaves for a Calendar owner: the structured, resolved fields the
  owner reviews in the ONE Calendar editor, plus any clarification the
  owner must answer. A row is NOT an event, a meeting, an invitation, a
  busy reservation or an Inbox consent; nothing reads it for availability.

    * `token` — the opaque part of the owner-only link. Unique. The link is
      useless to anyone else: every read also requires the signed-in owner.
    * `(owner_id, agent_id, request_key)` — UNIQUE, so a retried tool call
      returns the original draft instead of a second one.
    * `expires_at` — a draft past it is never opened or saved.
    * `saved_at` / `event_id` — set in the same transaction as the one
      explicit Save, so a second Save of the same draft is refused.

  Durable columns, not a parallel-UI shim, so no `parallel-ui:` comment.
  """
  use Ecto.Migration

  # old-code-compatible: a new table nothing in the previous release reads.

  def change do
    create table(:calendar_drafts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token, :string, null: false)
      add(:request_key, :string, null: false)
      add(:attrs, :map, null: false, default: %{})
      add(:clarifications, {:array, :map}, null: false, default: [])
      add(:issues, {:array, :string}, null: false, default: [])
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:saved_at, :utc_datetime_usec)

      add(:event_id, references(:calendar_events, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_drafts, [:token]))
    create(unique_index(:calendar_drafts, [:owner_id, :agent_id, :request_key]))
  end
end
