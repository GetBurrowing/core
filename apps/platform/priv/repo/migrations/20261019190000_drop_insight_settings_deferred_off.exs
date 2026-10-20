defmodule Platform.Repo.Migrations.DropInsightSettingsDeferredOff do
  @moduledoc """
  Task `01a15587-afc8-7000-b76d-4e1c48eee5ed`, stage 1: lift the deferral on
  `install_insight_settings.apply_page_edits` and `file_tasks`.

  `20261018000300_create_insight_dissemination.exs` created the CHECK
  `install_insight_settings_deferred_off` (`NOT apply_page_edits AND NOT
  file_tasks`) so no write could turn either automatic path on before it
  existed. Both paths now exist, so the CHECK goes. No data changes: both
  columns stay `false` on every install until a root admin turns one on.

  `down` re-creates the CHECK and fails loudly if a row already has either
  switch on, which is correct: rolling back must not silently turn off
  what an admin turned on.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:install_insight_settings, :install_insight_settings_deferred_off))
  end

  def down do
    create(
      constraint(:install_insight_settings, :install_insight_settings_deferred_off,
        check: "NOT apply_page_edits AND NOT file_tasks"
      )
    )
  end
end
