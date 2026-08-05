defmodule Platform.Repo.Migrations.CoupleIngestIntentToIngestStatus do
  @moduledoc """
  Task 019fd318 — make the incoherent `(intent, status)` pair unrepresentable.

  ## The coupling rule

  `ingest_status = 'not_attempted'` is legal ONLY alongside
  `ingest_intent = 'human_only'`. A row claiming we intended to ingest it
  (`attempt`) while recording that ingestion was never attempted
  (`not_attempted`) describes no reachable history: `request_ingest/1` is the
  single enqueue choke point and it never leaves a row in that pair.

  The expression is written as a disjunction —
  `ingest_status <> 'not_attempted' OR ingest_intent = 'human_only'` — rather
  than a negated conjunction, so it reads as the rule it encodes.

  ## What it deliberately leaves legal

  `human_only` alongside `pending` / `ingested` / `failed`.
  `Platform.Files.withdraw_from_agent_context/1` flips intent to `human_only`
  FIRST and status to `not_attempted` SECOND, inside one transaction, so the
  intermediate row is `human_only` + the prior status. A biconditional
  ("`human_only` implies `not_attempted`") would abort that transaction. The
  ordering of those two updates is load-bearing.

  ## Consumer

  `Platform.Federation.ToolSurface.agent_content_availability/1` matches
  `human_only` against any status, then `attempt` against `ingested`,
  `pending` and `failed`. It has no catch-all clause, deliberately. This
  constraint is what keeps that clause set total: the one pair it does not
  match is now the one pair the database refuses to store.
  """

  use Ecto.Migration

  # Explicit up/down rather than `change/0`: dropping a CHECK constraint is not
  # auto-reversible (Ecto cannot know the expression to restore).
  def up do
    create(
      constraint(
        :platform_files,
        :platform_files_not_attempted_requires_human_only_check,
        check: "ingest_status <> 'not_attempted' OR ingest_intent = 'human_only'"
      )
    )
  end

  def down do
    drop(constraint(:platform_files, :platform_files_not_attempted_requires_human_only_check))
  end
end
