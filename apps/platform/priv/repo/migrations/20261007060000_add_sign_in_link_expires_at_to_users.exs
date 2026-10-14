defmodule Platform.Repo.Migrations.AddSignInLinkExpiresAtToUsers do
  @moduledoc """
  Task 01a114c1 stage 1: the latest expiry of any sign-in link
  `Platform.SignInAdmin` has minted for the user. `SignInAdmin.enable/2`
  refuses while it is in the future, because pocket-id has no route to revoke
  a one-time token and restores one a disabled user tried to redeem. Only the
  expiry is stored, never the link or its code.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:sign_in_link_expires_at, :utc_datetime)
    end
  end
end
