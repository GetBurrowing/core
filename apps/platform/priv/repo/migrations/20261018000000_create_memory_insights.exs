defmodule Platform.Repo.Migrations.CreateMemoryInsights do
  use Ecto.Migration

  @moduledoc """
  Task `01a13867-3213-7001-a128-6b4c6b34283f` (Insights), stage 1: the two
  tables that replace `memory_proposals` as the home of dreaming synthesis.

  ## `memory_insights` is EPHEMERAL

  One row per parsed `<synthesis-insight>` block. Every row carries an
  `expires_at`, and `Platform.Memory.Insights.Purger` hard-DELETEs every row
  past it, whatever its `state`. Nothing here is a record: what an insight
  did lives in its artefact (`artefact_ref`), and what a human thought of it
  lives in `memory_insight_verdicts`.

    * `action_type`: `page_edit | briefing | question | task`.
    * `state`: `open | done | dismissed`.
    * `origin`: `dreaming` (parsed from a journal) or `legacy_proposal`
      (copied from `memory_proposals` by `20261018000100`).
    * `run_id`: the dreaming run that produced the block, derived
      deterministically from `(workspace_id, journal date)` so the dispatch
      and the ingest agree without the model copying an id.
    * `pre_image`, `tier`, `downgraded_from`, `addressee_*`, `delivered_at`
      and `disseminable` are written by later stages (grounding, routing,
      delivery). They are created here so the table is built once.

  `(workspace_id, block_hash)` is unique, matching `memory_proposals`.

  ## `memory_insight_verdicts` is DURABLE

  One row per human rejection or flag. Never purged: a verdict is the
  calibration signal the next dreaming prompt reads as an exemplar, and the
  dedup probe that keeps a rejected block from re-ingesting. `reason` is
  NOT NULL and CHECKed non-blank, so a verdict always says why.
  """

  def change do
    create table(:memory_insights, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_id, :uuid)
      add(:org_id, :uuid)
      add(:journal_path, :text, null: false)
      add(:block_hash, :text, null: false)
      add(:run_id, :uuid, null: false)
      add(:action_type, :string, null: false)
      add(:confidence, :string, null: false)
      add(:evidence, :text)
      add(:source_ref, :text)
      add(:body, :text, null: false)
      add(:action, :map, null: false, default: %{})
      add(:addressee_user_id, :uuid)
      add(:addressee_reason, :text)
      add(:tier, :string)
      add(:downgraded_from, :string)
      add(:state, :string, null: false, default: "open")
      add(:acted_by, :uuid)
      add(:acted_at, :utc_datetime_usec)
      add(:artefact_ref, :text)
      add(:pre_image, :map)
      add(:delivered_at, :utc_datetime_usec)
      add(:disseminable, :boolean, null: false, default: false)
      add(:origin, :string, null: false, default: "dreaming")
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:memory_insights, :action_type_must_be_known,
        check: "action_type IN ('page_edit','briefing','question','task')"
      )
    )

    create(
      constraint(:memory_insights, :confidence_must_be_known,
        check: "confidence IN ('high','medium','low')"
      )
    )

    create(
      constraint(:memory_insights, :state_must_be_known,
        check: "state IN ('open','done','dismissed')"
      )
    )

    create(
      constraint(:memory_insights, :origin_must_be_known,
        check: "origin IN ('dreaming','legacy_proposal')"
      )
    )

    create(unique_index(:memory_insights, [:workspace_id, :block_hash]))
    create(index(:memory_insights, [:expires_at]))
    create(index(:memory_insights, [:state, :expires_at]))
    create(index(:memory_insights, [:run_id]))

    create table(:memory_insight_verdicts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:block_hash, :text, null: false)
      add(:kind, :string, null: false)
      add(:reason, :text, null: false)
      add(:body, :text)
      add(:action_type, :string)
      add(:evidence, :text)
      add(:actor_id, :uuid)
      add(:workspace_id, :uuid)
      add(:origin, :string, null: false, default: "dreaming")

      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:memory_insight_verdicts, :kind_must_be_known,
        check: "kind IN ('rejected','flagged')"
      )
    )

    create(
      constraint(:memory_insight_verdicts, :reason_must_not_be_blank,
        check: "btrim(reason) <> ''"
      )
    )

    create(
      constraint(:memory_insight_verdicts, :origin_must_be_known,
        check: "origin IN ('dreaming','legacy_proposal')"
      )
    )

    create(index(:memory_insight_verdicts, [:block_hash]))
    create(index(:memory_insight_verdicts, [:workspace_id, "inserted_at DESC"]))
  end
end
