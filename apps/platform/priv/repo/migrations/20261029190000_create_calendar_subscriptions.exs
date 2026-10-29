defmodule Platform.Repo.Migrations.CreateCalendarSubscriptions do
  @moduledoc "Calendar task 01a16991-b7ae-7000-923f-54cd0b8cd7f7 stage 3: owner-only external snapshots."
  use Ecto.Migration

  def change do
    create table(:calendar_subscriptions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :text, null: false)
      add(:url, :binary, null: false)
      add(:snapshot, {:array, :map}, null: false, default: [])
      add(:refreshed_at, :utc_datetime_usec)
      add(:attempted_at, :utc_datetime_usec)
      add(:error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:calendar_subscriptions, [:owner_id]))
  end
end
