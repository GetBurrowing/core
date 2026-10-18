defmodule Platform.Repo.Migrations.AddExperimentSurfacesAndSignals do
  @moduledoc """
  Task 01a0d415 stage 1 — the storage for the experimentation layer described
  in the experimentation-layer ADR-0052 (`docs/decisions/0052-experimentation-layer.md`), which EXTENDS ADR-0048 and does not supersede it.

  ## What this adds

    * `experiments` gains tenancy COLUMNS (`org_id`, `project_id`, both
      nullable, both `on_delete: :restrict`), the surface binding
      (`surface_key`, `surface_target`), data-defined `metric_spec` and
      `assignment_policy`, the signal plumbing, and an `approval_state` that
      defaults to `not_required` so every existing row is unchanged, plus the
      stop-with-feedback columns (`stop_feedback`, `stopped_by_user_id`,
      `stopped_at`, all nullable).
    * `experiment_variants` gains `payload`; `content` stays for the prompt
      surface.
    * New tables: `experiment_signals`, `experiment_guardrails`,
      `experiment_goals`, `experiment_surface_defaults`.

  ## Null org means install-wide, and the singletons are enforced

  A NULL `org_id` means "the install-wide row". A btree unique index under the
  default `NULLS DISTINCT` never compares two NULLs, so without
  `nulls_distinct: false` a second install-wide row would insert cleanly and
  every reader of "the" install-wide row would get whichever the planner
  returned. Two tables are install-wide SINGLETONS and carry
  `NULLS NOT DISTINCT` unique indexes:

    * `experiment_guardrails` on `(org_id)` — one guardrail row per org, and
      exactly one install-wide row.
    * `experiment_surface_defaults` on
      `(surface_key, surface_target, org_id, seq)` — the history is
      append-only and keyed by `seq`, so two writers computing the same next
      `seq` for the install-wide key collide instead of both inserting. A
      unique index on `org_id` alone would forbid the history this table
      exists to keep.

  `experiment_goals` is deliberately NOT a singleton: many goals per org and
  many install-wide goals are legal, so it has no uniqueness on `org_id`.

  ## Restrict, not nilify

  Every org and project FK here is `on_delete: :restrict`. Nilifying a deleted
  project would silently WIDEN a project-scoped experiment to org-wide, and a
  deleted org to install-wide — the opposite of what deleting it meant.

  ## Postgres 15+

  `NULLS NOT DISTINCT` is Postgres 15 syntax. `require_pg15!/0` runs first so
  an older server fails on a sentence rather than a syntax error, mirroring
  `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes`.
  """

  use Ecto.Migration

  def up do
    require_pg15!()

    create table(:experiment_goals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict))
      add(:project_id, references(:projects, type: :binary_id, on_delete: :restrict))
      add(:statement, :text, null: false)
      add(:metric_spec, :map, null: false, default: %{})
      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime_usec)
    end

    # NOT unique — see the moduledoc. Goals are not a singleton table.
    create(index(:experiment_goals, [:org_id, :status]))

    alter table(:experiments) do
      # null org = install-wide; null project = org-wide.
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict))
      add(:project_id, references(:projects, type: :binary_id, on_delete: :restrict))
      add(:surface_key, :string)
      add(:surface_target, :string)
      add(:metric_spec, :map, null: false, default: %{})
      add(:assignment_policy, :map, null: false, default: %{})
      add(:signal_source, :map)
      add(:observation_window_days, :integer)
      add(:goal_id, references(:experiment_goals, type: :uuid, on_delete: :restrict))
      add(:proposed_by_agent_id, :uuid)
      add(:approval_state, :string, null: false, default: "not_required")
      # Stop-with-feedback. A human stop carries a reason the Scientist must
      # read before proposing the next experiment on the same goal. The
      # changeset only accepts these on the transition INTO `stopped`.
      add(:stop_feedback, :text)
      add(:stopped_by_user_id, :uuid)
      add(:stopped_at, :utc_datetime_usec)
    end

    # The per-org max_live count reads this.
    create(index(:experiments, [:org_id, :status]))
    create(index(:experiments, [:surface_key, :surface_target]))

    create(
      constraint(:experiments, :experiments_approval_state_check,
        check: "approval_state IN ('not_required', 'pending', 'approved')"
      )
    )

    # Every experiment that exists today is a prompt experiment; the ones that
    # have been activated carry their target slug. Drafts that were never
    # activated have no target yet and stay unbound.
    execute("""
    UPDATE experiments
       SET surface_key = 'dispatch.prompt',
           surface_target = target_template_slug
     WHERE target_template_slug IS NOT NULL
    """)

    alter table(:experiment_variants) do
      add(:payload, :map, null: false, default: %{})
      # A non-prompt variant carries its arm in `payload` and has no blob.
      # Prompt variants still always write `content` (the changeset requires
      # it whenever `payload` is empty).
      modify(:content, :text, null: true, from: {:text, null: false})
    end

    create table(:experiment_signals, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:experiment_id, references(:experiments, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:subject_type, :string, null: false)
      # NULLABLE: an unmatched reply is recorded, not dropped.
      add(:subject_id, :uuid)
      # null = unlabelled.
      add(:label, :string)
      add(:confidence, :float)
      add(:reason, :text)
      add(:source_type, :string, null: false)
      add(:source_id, :string, null: false)
      add(:labeler, :string)
      add(:status, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    # None of the three columns is nullable, so NULLS DISTINCT does not arise.
    create(
      unique_index(:experiment_signals, [:experiment_id, :source_type, :source_id],
        name: :experiment_signals_source_unique_index
      )
    )

    create(index(:experiment_signals, [:experiment_id, :subject_type, :subject_id]))

    create(
      constraint(:experiment_signals, :experiment_signals_status_check,
        check: "status IN ('labelled', 'unlabelled', 'rejected_output')"
      )
    )

    create table(:experiment_guardrails, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      # null = THE install-wide row.
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict))
      add(:max_live, :integer, null: false, default: 3)
      add(:allowed_surfaces, {:array, :string}, null: false, default: [])
      # Opt-in per org (product decision, 2026-09-24): launch approval is a guardrail an
      # admin can switch on, off by default. The UI controls are present
      # either way.
      add(:require_human_approval, :boolean, null: false, default: false)
      add(:allow_auto_promote, :boolean, null: false, default: false)
      add(:updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    # The singleton guard. Without `nulls_distinct: false` two install-wide
    # rows insert cleanly.
    create(
      unique_index(:experiment_guardrails, [:org_id],
        nulls_distinct: false,
        name: :experiment_guardrails_org_id_index
      )
    )

    create table(:experiment_surface_defaults, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:surface_key, :string, null: false)
      add(:surface_target, :string, null: false)
      # null = install-wide default.
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict))
      add(:seq, :integer, null: false)
      add(:kind, :string, null: false)
      # null = no default; the surface's control applies.
      add(:payload, :map)
      add(:source_experiment_id, references(:experiments, type: :uuid, on_delete: :restrict))
      add(:reverts_seq, :integer)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(
        :experiment_surface_defaults,
        [:surface_key, :surface_target, :org_id, :seq],
        nulls_distinct: false,
        name: :experiment_surface_defaults_key_seq_index
      )
    )

    create(
      constraint(:experiment_surface_defaults, :experiment_surface_defaults_kind_check,
        check: "kind IN ('promote', 'revert')"
      )
    )
  end

  def down do
    drop(table(:experiment_surface_defaults))
    drop(table(:experiment_guardrails))
    drop(table(:experiment_signals))

    # Down refuses to run over a payload-only variant rather than inventing a
    # blob for it: re-imposing NOT NULL fails on such a row, loudly.
    alter table(:experiment_variants) do
      modify(:content, :text, null: false, from: {:text, null: true})
      remove(:payload)
    end

    drop(constraint(:experiments, :experiments_approval_state_check))
    drop(index(:experiments, [:surface_key, :surface_target]))
    drop(index(:experiments, [:org_id, :status]))

    alter table(:experiments) do
      remove(:stopped_at)
      remove(:stopped_by_user_id)
      remove(:stop_feedback)
      remove(:approval_state)
      remove(:proposed_by_agent_id)
      remove(:goal_id)
      remove(:observation_window_days)
      remove(:signal_source)
      remove(:assignment_policy)
      remove(:metric_spec)
      remove(:surface_target)
      remove(:surface_key)
      remove(:project_id)
      remove(:org_id)
    end

    drop(table(:experiment_goals))
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. The install-wide
      singleton indexes on experiment_guardrails and experiment_surface_defaults
      cannot be built without it. Upgrade the server.
      """
    end
  end
end
