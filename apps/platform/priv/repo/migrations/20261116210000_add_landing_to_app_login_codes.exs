defmodule Platform.Repo.Migrations.AddLandingToAppLoginCodes do
  @moduledoc """
  Task 01a1e58b stage 3. Where the app's web view lands after an app login:
  an exchange code minted by an email-code sign-in carries
  `/settings?passkey=add`, so the person is prompted to add a passkey for the
  new device. The sheet and the web view do not share cookies, so the landing
  rides the exchange-code row, the only thing that crosses between them.

  Nullable: nil means the ordinary landing (`/`). Stored already checked by
  `Platform.Mobile.safe_return_path/1`.
  """
  use Ecto.Migration

  # old-code-compatible: additive nullable column; old code never reads or writes it
  def change do
    alter table(:app_login_codes) do
      add(:landing, :string)
    end
  end
end
