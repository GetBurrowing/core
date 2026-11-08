defmodule Platform.Repo.Migrations.CreateSharingFriction do
  @moduledoc """
  Task `01a1b678-8bb4-7000-96d2-c691eb9b13b5`, stage 3: agent friction
  reports (`Platform.Sharing.Friction`).

    * `sharing_friction_events`: one row per occurrence of a friction
      fingerprint (a repeated tool failure or a repeated question to an
      agent). Only the fingerprint, its kind and a bounded subject are kept:
      the tool name plus an error code, or a hash of the question. Never the
      message text.
    * `sharing_friction_reports`: one row per occurrence that reached the
      threshold, with what happened to it (`filed`, `deduped`,
      `rate_limited`, `refused`). The per-install experiment metric is a count
      over this table.
  """

  use Ecto.Migration

  def change do
    create table(:sharing_friction_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:fingerprint, :string, size: 64, null: false)
      add(:kind, :string, size: 16, null: false)
      add(:subject, :string, size: 160, null: false)
      add(:agent_id, :binary_id)
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:sharing_friction_events, :sharing_friction_events_kind,
        check: "kind IN ('tool_failure', 'question')"
      )
    )

    create(index(:sharing_friction_events, [:fingerprint, :occurred_at]))

    create table(:sharing_friction_reports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:fingerprint, :string, size: 64, null: false)
      add(:kind, :string, size: 16, null: false)
      add(:outcome, :string, size: 16, null: false)
      add(:detail, :string, size: 64)
      add(:issue_url, :string, size: 512)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:sharing_friction_reports, :sharing_friction_reports_outcome,
        check: "outcome IN ('filed', 'deduped', 'rate_limited', 'refused')"
      )
    )

    create(index(:sharing_friction_reports, [:outcome, :inserted_at]))
    create(index(:sharing_friction_reports, [:fingerprint]))
  end
end
