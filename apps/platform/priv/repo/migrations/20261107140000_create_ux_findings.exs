defmodule Platform.Repo.Migrations.CreateUxFindings do
  @moduledoc """
  Create `ux_findings` (task `01a1af00-86ac-7000-94ba-a121d5cb8116` stage 1).

  One row is one question the UX friction watch (`ux.friction_watch`, which joins the
  designer bundle with its handler in stage 2) puts to one human: a `decision` with up to three options,
  exactly one recommended, or an `fyi`. Evidence is a count, at most two
  quotes and `chat:<space_id>:<message_id>` citations. The row carries the
  experiment `variant` that produced it, so the keep-versus-dismiss metric
  (`ux_finding_keep_rate`) can be read per arm.

  The shape rules (option count, one recommended, citation format, the
  trailing `?`) live in `Platform.Ux.Finding.changeset/2`. The partial unique
  index keeps one OPEN finding per recipient and `group_key`, so a repeated
  friction signal folds into the existing ask instead of filing a second one.
  """

  use Ecto.Migration

  def change do
    create table(:ux_findings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all))
      add(:workspace_id, :binary_id)

      add(:recipient_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:question, :text, null: false)
      add(:kind, :string, null: false)
      add(:evidence, :map, null: false, default: %{})
      add(:options, {:array, :map}, null: false, default: [])
      add(:mockup_refs, :map, null: false, default: %{})
      add(:status, :string, null: false, default: "open")
      add(:answer, :text)
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))
      add(:group_key, :string, null: false)
      add(:variant, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:ux_findings, :ux_findings_kind_check, check: "kind IN ('decision', 'fyi')")
    )

    create(
      constraint(:ux_findings, :ux_findings_status_check,
        check: "status IN ('open', 'answered', 'dismissed')"
      )
    )

    create(
      unique_index(:ux_findings, [:recipient_user_id, :group_key],
        where: "status = 'open'",
        name: :ux_findings_open_group_index
      )
    )

    create(index(:ux_findings, [:org_id, :status]))
    create(index(:ux_findings, [:task_id]))
    create(index(:ux_findings, [:variant]))
  end
end
