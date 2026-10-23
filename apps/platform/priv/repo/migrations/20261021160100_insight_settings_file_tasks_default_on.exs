defmodule Platform.Repo.Migrations.InsightSettingsFileTasksDefaultOn do
  use Ecto.Migration

  @moduledoc """
  Task `01a15ee1-48c8-7000-a8f1-33a5586cb458`, stage 2: task insights are
  filed unattended by default, so `install_insight_settings.file_tasks`
  defaults to TRUE.

  The sponsor, 2026-10-21: "the tasks should already have been filed to the
  presumed appropriate project. those should be in the easily reversible
  column". With `file_tasks` off, `Platform.Memory.Insights.Digest` drops
  every task insight and nothing is filed, so the shipped default changes.
  `apply_page_edits` and `dissemination_enabled` are NOT touched.

  ## An admin's deliberate choice is never overwritten

  The singleton row is flipped only when `file_tasks` is false AND the row
  was never edited (`updated_at = inserted_at`, i.e. it still holds the
  values the seeding migration wrote). A row an admin has saved since keeps
  whatever they chose, including false. With no row at all, the column
  default covers the next seed.

  Measured read-only on 2026-10-21 around 16:00Z on both deployed installs
  (columns `file_tasks`, `dissemination_enabled`, `apply_page_edits`,
  `inserted_at`, `updated_at` only):

  | install   | file_tasks | dissemination_enabled | apply_page_edits | edited since seed | this migration |
  | --------- | ---------- | --------------------- | ---------------- | ----------------- | -------------- |
  | install 1 | true       | true                  | true             | yes (2026-10-20)  | no change      |
  | install 2 | false      | false                 | false            | no                | flips to true  |

  `down/0` restores the column default to false. It does not flip the row
  back: after `up/0` a flipped row is indistinguishable from an admin's
  choice of true, and guessing would overwrite one.
  """

  def up do
    alter table(:install_insight_settings) do
      modify(:file_tasks, :boolean, null: false, default: true)
    end

    execute(flip_sql())
  end

  @doc """
  The row flip, public so a test can run it against rows of its own: only a
  `file_tasks = false` row that was never edited since its seed.
  """
  def flip_sql do
    """
    UPDATE install_insight_settings
       SET file_tasks = true
     WHERE file_tasks = false
       AND updated_at = inserted_at
    """
  end

  def down do
    alter table(:install_insight_settings) do
      modify(:file_tasks, :boolean, null: false, default: false)
    end
  end
end
