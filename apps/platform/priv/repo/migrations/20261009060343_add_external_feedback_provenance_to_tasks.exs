defmodule Platform.Repo.Migrations.AddExternalFeedbackProvenanceToTasks do
  @moduledoc """
  Task 01a11ec3 stage 1: independent persisted dimensions for external
  feedback provenance and quarantine trust on `tasks`.

  Four independent columns join the existing `kind` taxonomy rather than
  encoding feedback as a kind:

    * `origin` — `internal` (default) or `external_feedback`. External
      feedback is an origin, never a task kind.
    * `trust` — `trusted` (default) or `quarantined`. Quarantined work
      cannot be planned or executed until an explicit, attributed
      promotion.
    * `external_repository_identity` — canonical repository identity for
      external rows (e.g. `"owner/repo"`).
    * `external_issue_number` — the issue number in that repository.

  Existing rows backfill to `origin = 'internal'` and `trust = 'trusted'`
  via the non-null defaults — no heuristic inference from titles or text.

  A unique partial index over `(lower(external_repository_identity),
  external_issue_number)` for external rows makes intake idempotent:
  retrying the same repository + issue can never create a second task.

  The columns are independent of `kind` (`20261009064000_add_kind_to_tasks`),
  so the two migrations commute; neither reads the other's columns.
  """

  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:origin, :string, null: false, default: "internal")
      add(:trust, :string, null: false, default: "trusted")
      add(:external_repository_identity, :string)
      add(:external_issue_number, :bigint)
    end

    # Board lanes (stage 4) filter on persisted origin; janitor eligibility
    # (follow-up task) selects on kind+origin+trust+status. Independent
    # indexes so both reads stay index-assisted.
    create(index(:tasks, [:origin, :status]))
    create(index(:tasks, [:origin, :trust]))

    create(
      constraint(:tasks, :tasks_origin_valid,
        check: "origin IN ('internal', 'external_feedback')"
      )
    )

    create(constraint(:tasks, :tasks_trust_valid, check: "trust IN ('trusted', 'quarantined')"))

    create(
      constraint(:tasks, :tasks_external_feedback_provenance_complete,
        check: """
        (origin = 'external_feedback' AND external_repository_identity IS NOT NULL AND external_issue_number IS NOT NULL AND external_issue_number > 0)
        OR
        (origin = 'internal' AND external_repository_identity IS NULL AND external_issue_number IS NULL)
        """
      )
    )

    # Deduplication: at most one external task per repository+issue pair.
    # Narrowed with NULL guards so a degenerate external row (which the
    # changeset forbids but a future writer might attempt) never collides.
    # The repository half is lower()-ed: GitHub resolves owner/repo
    # case-insensitively, so `Startup-Suite/core` and `startup-suite/core`
    # name ONE issue tracker and must not yield two tasks for one issue.
    create(
      index(:tasks, ["lower(external_repository_identity)", :external_issue_number],
        where:
          "origin = 'external_feedback' AND external_repository_identity IS NOT NULL AND external_issue_number IS NOT NULL",
        unique: true,
        name: :tasks_external_feedback_identity_unique
      )
    )
  end
end
