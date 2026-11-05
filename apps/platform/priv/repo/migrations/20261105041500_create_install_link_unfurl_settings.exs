defmodule Platform.Repo.Migrations.CreateInstallLinkUnfurlSettings do
  @moduledoc """
  Task 01a1a944-b4fa-7000-b75a-ce138df43002, stage 3: the
  `install_link_unfurl_settings` singleton behind
  `Platform.Chat.LinkUnfurls.Settings`, this install's switch for link
  previews. There is no per-org settings column, so the switch is
  install-level, the same shape as `install_prototype_settings`: a CHECK on
  `singleton` plus a unique index, so two rows can never disagree. The
  default row ships here, ON, so `Settings.get/0` never handles an empty
  table.
  """
  use Ecto.Migration

  def up do
    create table(:install_link_unfurl_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:singleton, :boolean, null: false, default: true)
      add(:enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:install_link_unfurl_settings, :install_link_unfurl_settings_singleton_true,
        check: "singleton"
      )
    )

    create(unique_index(:install_link_unfurl_settings, [:singleton]))

    execute("""
    INSERT INTO install_link_unfurl_settings (id, singleton, enabled, inserted_at, updated_at)
    VALUES (gen_random_uuid(), true, true, now(), now())
    """)
  end

  def down do
    drop(table(:install_link_unfurl_settings))
  end
end
