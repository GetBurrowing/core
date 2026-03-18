defmodule Platform.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :participant_id, :binary_id, null: false
      add :endpoint, :string, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:push_subscriptions, [:participant_id])
    create unique_index(:push_subscriptions, [:participant_id, :endpoint])
  end
end
