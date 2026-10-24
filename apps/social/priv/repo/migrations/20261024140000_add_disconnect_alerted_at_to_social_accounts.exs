defmodule Platform.Repo.Migrations.AddDisconnectAlertedAtToSocialAccounts do
  @moduledoc """
  Social authoring 9/11 (task 01a16c51-9cc5): the once-per-disconnect marker
  for the approvers' alert.

    * `social_accounts.disconnect_alerted_at`: nullable. Set, together with
      `status = "reauth_needed"`, by the ONE conditional update in
      `Platform.Social.Health.account_disconnected/2` (only while it is nil,
      so a second failure or a replayed webhook alerts nobody). Cleared when
      the account is connected again, which re-arms the alert.

  Additive; `change/0` is reversible (the rollback drops the column).
  """

  use Ecto.Migration

  def change do
    alter table(:social_accounts) do
      add(:disconnect_alerted_at, :utc_datetime_usec)
    end
  end
end
