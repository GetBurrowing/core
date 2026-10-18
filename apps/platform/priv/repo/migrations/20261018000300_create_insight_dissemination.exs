defmodule Platform.Repo.Migrations.CreateInsightDissemination do
  @moduledoc """
  Task `01a13867-3213-7001-a128-6b4c6b34283f` (Insights), stage 3: the two
  tables insight dissemination needs.

    * `install_insight_settings` — a singleton, enforced by the database
      exactly as `install_prototype_settings` is (CHECK on `singleton` plus a
      unique index), so two rows can never disagree about whether
      dissemination is on. The default row ships here so
      `Platform.Memory.Insights.Settings.get/0` never handles an empty table.
      Dissemination defaults OFF (the ticket keeps it off until proven). The
      sub-toggles default as the direction canvas shows: briefings on,
      questions on, page edits off, tasks off. Page edits and tasks are also
      CHECKed off, because no slice ships their automatic path yet.

    * `memory_briefings` — one row per delivered daily briefing canvas: the
      receipt of a sent message, so it is DURABLE (unlike `memory_insights`).
      `items` maps each canvas node key to the insight it renders, so a canvas
      action carries a node key and never an insight id. `(user_id,
      digest_date)` is unique: one digest per person per day.

  No `Platform.Audit.record/1`, no PubSub: migrations run before the
  supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:install_insight_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:singleton, :boolean, null: false, default: true)
      add(:dissemination_enabled, :boolean, null: false, default: false)
      add(:deliver_briefings, :boolean, null: false, default: true)
      add(:deliver_questions, :boolean, null: false, default: true)
      add(:apply_page_edits, :boolean, null: false, default: false)
      add(:file_tasks, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:install_insight_settings, :install_insight_settings_singleton_true,
        check: "singleton"
      )
    )

    create(
      constraint(:install_insight_settings, :install_insight_settings_deferred_off,
        check: "NOT apply_page_edits AND NOT file_tasks"
      )
    )

    create(unique_index(:install_insight_settings, [:singleton]))

    execute(
      """
      INSERT INTO install_insight_settings
        (id, singleton, dissemination_enabled, deliver_briefings, deliver_questions,
         apply_page_edits, file_tasks, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), true, false, true, true, false, false, now(), now())
      """,
      "DELETE FROM install_insight_settings"
    )

    create table(:memory_briefings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:digest_date, :date, null: false)
      add(:items, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:memory_briefings, [:canvas_id]))
    create(unique_index(:memory_briefings, [:user_id, :digest_date]))
  end
end
