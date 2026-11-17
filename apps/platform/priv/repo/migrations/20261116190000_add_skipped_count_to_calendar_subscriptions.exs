defmodule Platform.Repo.Migrations.AddSkippedCountToCalendarSubscriptions do
  @moduledoc """
  Task 01a1e49f stage 2. How many VEVENTs the stored snapshot left out
  because they could not be read. A count above zero means the snapshot is
  partial, so availability for that owner is unknown.

  A typed column rather than a marker inside `snapshot`: that array is read
  element by element as event rows. Existing rows backfill to 0.
  """
  use Ecto.Migration

  # old-code-compatible: additive column with default 0; old code never reads or writes it
  def change do
    alter table(:calendar_subscriptions) do
      add(:skipped_count, :integer, null: false, default: 0)
    end
  end
end
