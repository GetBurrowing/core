defmodule Platform.Repo.Migrations.CreateExperiments do
  use Ecto.Migration

  @moduledoc """
  Task 019fe6b9, ADR-0048 (experimentation substrate) — the storage layer for
  prompt experiments.

  Creates the four tables the substrate needs: `experiments`,
  `experiment_variants`, `experiment_assignments` and
  `prompt_template_history`. Tables and the contexts that write them only —
  no metric computation, no policy resolution, no promotion logic.

  Grouped into one migration file deliberately: the four tables reference each
  other and are meaningless apart, so a partial apply has no useful
  intermediate state.

  Two constraints created here are load-bearing and are commented at their
  definitions below, because losing either corrupts results silently rather
  than loudly:

    * the unique index on `experiment_assignments`
      `(experiment_id, subject_type, subject_id)`, which is what makes an
      assignment sticky; and
    * `experiment_variants.content` being the FULL prompt blob, which is what
      makes a concluded experiment reproducible from its own rows.
  """

  def change do
    create table(:experiments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:hypothesis, :text)
      add(:primary_metric, :string)
      # draft | running | stopped | concluded.
      #
      # `stopped` and `concluded` are DIFFERENT statuses and both stay
      # visible. An experiment that made things worse is the most instructive
      # row on the page, so nothing may filter `stopped` out of a listing or
      # map it onto `concluded`.
      add(:status, :string, null: false, default: "draft")
      add(:stop_rule, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:experiments, [:slug]))

    create table(:experiment_variants, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:experiment_id, references(:experiments, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:slug, :string, null: false)
      # The FULL prompt blob, not a structured overlay. A blob is exactly what
      # was dispatched, so a result stays reproducible from the row alone; an
      # overlay reconstructs the prompt at read time, and any later change to
      # the composition rules would silently rewrite history. Rejected
      # deliberately per ADR-0048.
      add(:content, :text, null: false)
      add(:weight, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:experiment_variants, [:experiment_id, :slug]))

    create table(:experiment_assignments, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:experiment_id, references(:experiments, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:subject_type, :string, null: false)
      # Deliberately a plain :uuid, NOT a references/FK — the subject is a
      # task_id today, but dispatch-level subjects must work later without a
      # migration, so there is no single parent table to constrain against.
      # Same reasoning as `inbox_items.source_id`.
      add(:subject_id, :uuid, null: false)
      add(:variant_slug, :string, null: false)
      add(:assigned_at, :utc_datetime_usec, null: false)
      # Nullable. An excluded subject sets a reason and the ROW STAYS —
      # exclusions are never deleted. A subject dropped from the denominator
      # with no record is how a result quietly becomes wrong.
      add(:excluded_reason, :string)

      timestamps(type: :utc_datetime_usec)
    end

    # LOAD-BEARING. An assignment is written once and never recomputed.
    #
    # Stickiness is what stops one task getting variant A at planning and
    # variant B at execution — a contamination no downstream metric can
    # detect, because both rows look legitimate. This index is the backstop
    # under the read-before-write path in Platform.Experiments.Assignments,
    # and it is what makes that path safe under a race.
    #
    # The name is pinned EXPLICITLY. Ecto's derived default would be
    # `experiment_assignments_experiment_id_subject_type_subject_id_index`,
    # which is 66 bytes and so is silently truncated by Postgres at 63 to
    # `..._subject_id_in`. A schema-side `unique_constraint/3` naming the
    # underivable full name would therefore never match, and a racing insert
    # would raise Ecto.ConstraintError instead of returning the changeset
    # error the writer catches. Truncation also depends on the exact table
    # and column spelling, so a later rename would move the cut silently.
    create(
      unique_index(:experiment_assignments, [:experiment_id, :subject_type, :subject_id],
        name: :experiment_assignments_subject_unique_index
      )
    )

    create table(:prompt_template_history, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:template_id, references(:prompt_templates, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:content, :text, null: false)
      add(:captured_at, :utc_datetime_usec, null: false)
      add(:captured_by, :string)
      # The promotion that caused this capture. A plain :uuid for the same
      # reason as subject_id above, and nullable because a capture can be
      # taken outside any promotion.
      add(:promotion_experiment_id, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:prompt_template_history, [:template_id, :captured_at]))
  end
end
