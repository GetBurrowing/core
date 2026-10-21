defmodule Platform.Repo.Migrations.InsightSettingsFileTasksDefaultOnTest do
  @moduledoc """
  Coverage for `20261021160100_insight_settings_file_tasks_default_on`
  (task 01a15ee1 stage 2): the column default is true, and the row flip
  touches only a never-edited `file_tasks = false` row, so an admin's
  saved choice of false survives.
  """

  use Platform.DataCase, async: false

  alias Platform.Memory.Insights.Settings
  alias Platform.Repo

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.InsightSettingsFileTasksDefaultOn

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261021160100_insight_settings_file_tasks_default_on.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp set_row!(file_tasks, edited?) do
    Repo.query!(
      """
      UPDATE install_insight_settings
         SET file_tasks = $1,
             inserted_at = $2,
             updated_at = $3
      """,
      [
        file_tasks,
        ~U[2026-10-18 12:00:00.000000Z],
        if(edited?, do: ~U[2026-10-20 03:00:00.000000Z], else: ~U[2026-10-18 12:00:00.000000Z])
      ]
    )
  end

  defp flip!, do: Repo.query!(apply(@migration_module, :flip_sql, []))

  test "the column default is true" do
    %Postgrex.Result{rows: [[default]]} =
      Repo.query!("""
      SELECT column_default FROM information_schema.columns
       WHERE table_name = 'install_insight_settings' AND column_name = 'file_tasks'
      """)

    assert default == "true"
  end

  test "a never-edited row at false is flipped to true" do
    set_row!(false, false)
    refute Settings.get().file_tasks

    flip!()
    assert Settings.get().file_tasks
  end

  test "a row an admin saved at false is left alone" do
    set_row!(false, true)

    flip!()
    refute Settings.get().file_tasks
  end

  test "a row already at true stays true, and nothing else in the row moves" do
    set_row!(true, true)
    before = Settings.get()

    flip!()
    assert Settings.get() == before
  end
end
