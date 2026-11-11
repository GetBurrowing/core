defmodule Platform.Repo.Migrations.AddGamingExperience do
  @moduledoc """
  Add an opt-in gaming presentation for the separate games-focused install.
  Admitted by gaming-instance request 01a1c856 to stand up Burrow Play.
  """
  # old-code-compatible: Adds a defaulted field ignored by previous code.
  use Ecto.Migration

  def change do
    alter table(:install_branding) do
      add(:experience, :string, null: false, default: "workspace")
    end

    create(
      constraint(:install_branding, :install_branding_experience,
        check: "experience IN ('workspace', 'gaming')"
      )
    )
  end
end
