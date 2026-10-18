defmodule Platform.Repo.Migrations.CreateMemoryProposals do
  use Ecto.Migration

  @moduledoc """
  Persist parsed `<synthesis-proposal>` blocks extracted from journal
  writes so the `/memory/proposals` LiveView (stage 4) can list without
  re-parsing every journal on every render.

  ## Column notes

    * `journal_path` is the source journal `file_key`
      (e.g. `org/journal/2026-07-17.md`).

    * `block_hash` is a sha256 of the raw `<synthesis-proposal>` block
      body — the (workspace_id, block_hash) unique index gives us
      idempotent re-ingest when the same journal is upserted multiple
      times in a run.

    * `category` and `confidence` are strings with CHECK constraints
      restricting to the enumerated values — string-not-ENUM so a future
      category addition ships in a migration without `ALTER TYPE`
      surgery.

    * `status` transitions:
        pending → approved   (the operator clicks Approve at `/memory/proposals`)
        pending → rejected   (the operator clicks Reject-with-feedback)
        pending → expired    (`Proposals.expire_stale/0` after 7 days)

      Rejected + expired rows persist (acceptance criterion 8) — we
      never DELETE from this table, only status-flip. Rejected rows
      feed few-shot exemplars for the next dreaming run.

    * `expires_at` is written explicitly at insert time
      (`inserted_at + 7 days`) rather than as a fragment default,
      because we want the changeset to be able to see + override it in
      tests that need to seed already-expired rows.

  Admitted by task 019f70e9 stage 2, PR #571 — Historian dreaming:
  synthesis-proposal review flow.
  """

  def change do
    create table(:memory_proposals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_id, :uuid)
      add(:journal_path, :text, null: false)
      add(:block_hash, :text, null: false)
      add(:category, :string, null: false)
      add(:confidence, :string, null: false)
      add(:evidence, :text)
      add(:body, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:feedback, :text)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:memory_proposals, :category_must_be_known,
        check:
          "category IN ('recurring-theme','cross-project-pattern','emerging-risk','stale-fact-candidate-retirement','strategic-insight','unresolved-question')"
      )
    )

    create(
      constraint(:memory_proposals, :confidence_must_be_known,
        check: "confidence IN ('high','medium','low')"
      )
    )

    create(
      constraint(:memory_proposals, :status_must_be_known,
        check: "status IN ('pending','approved','rejected','expired')"
      )
    )

    # Idempotency for re-ingest: the same synthesis block in a journal
    # (matched by workspace_id + sha256(body)) inserts once, ignored on
    # subsequent runs. See `Proposals.ingest_from_journal/3`'s
    # `on_conflict: :nothing`.
    create(unique_index(:memory_proposals, [:workspace_id, :block_hash]))

    # `Proposals.expire_stale/0` scans (status, expires_at) — index tuned
    # for that predicate. `Proposals.list_pending/1` also benefits.
    create(index(:memory_proposals, [:status, :expires_at]))

    # Cheap workspace filter for `list_pending/1` where a workspace is
    # supplied. Composite with inserted_at DESC so the ordered pull is
    # index-only on the hot path.
    create(index(:memory_proposals, [:workspace_id, "inserted_at DESC"]))
  end
end
