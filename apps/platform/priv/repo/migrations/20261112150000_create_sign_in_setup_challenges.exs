defmodule Platform.Repo.Migrations.CreateSignInSetupChallenges do
  use Ecto.Migration
  # old-code-compatible: a new, short-lived authentication table that older releases never access.
  def change do
    create table(:sign_in_setup_challenges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
      add(:binding_hash, :binary, null: false)
      add(:email_hash, :binary, null: false)
      add(:code_hash, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)
    end
    create(index(:sign_in_setup_challenges, [:expires_at]))
  end
end
