defmodule Platform.Repo.Migrations.CreateSwitcherBadgeKeys do
  @moduledoc """
  Task 01a1ccd4 stage 2: badge keys for the web install switcher.

  A badge key is minted on THIS install (B) at a first-party consent visit and
  handed to another install's origin (A), whose switcher uses it to read one
  number: the signed-in user's unread total, from `GET /api/switcher/unread`.
  It authenticates nothing else.

  Deliberately a separate table from `app_sessions`: an `app_sessions` bearer
  can post messages, a badge key must not, so the two can never be confused
  by a lookup. Only the SHA-256 of the key is stored (`token_hash`).
  `bound_origin` is the normalized `scheme://host[:port]` of A; a request
  whose `Origin` differs is refused. `expires_at` is 90 days after minting;
  `revoked_at` set means the key no longer answers.
  """
  use Ecto.Migration

  # old-code-compatible: a new table (and its own indexes) that no earlier release reads or writes.

  def change do
    create table(:switcher_badge_keys, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:bound_origin, :text, null: false)
      add(:label, :text)
      add(:last_used_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:switcher_badge_keys, [:token_hash]))
    create(index(:switcher_badge_keys, [:user_id]))
  end
end
