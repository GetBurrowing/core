defmodule Platform.Repo.Migrations.AddCardColumnsToPlatformFiles do
  @moduledoc """
  Task 01a0008c stage 1 — give a file a place to record its catalog card.

  Documents go through ADR-0042's extract → dedup → chunk → embed path and
  then stop: no card, no page, no backlinks. This task adds `files` as a
  fifth Historian corpus, and a card is a wiki page at
  `project/<project_id>/page/files/<slug>.md`. These two columns are the
  link back from the file row to that page.

  Both nullable, and NULL is meaningful rather than a backfill gap:
  `card_file_key` NULL means "no card yet", which is what the stage-3
  backfill selects on and what a failed LLM pass leaves behind (the retry
  strategy is deliberately "retry by backfill", so a provider error must
  be indistinguishable from never-attempted).

  `card_generated_at` is `utc_datetime_usec` to match the precision the
  rest of this table's timestamps already carry.
  """
  use Ecto.Migration

  def change do
    alter table(:platform_files) do
      # The wiki file_key of this file's catalog card. Plain :text, not
      # a varchar: file_keys are `<ns>/page/<rest>` where ns can be
      # `project/<uuid>`, so the uuid alone eats 36 of a varchar(255)
      # before the slug — which is derived from a filename — is counted.
      add(:card_file_key, :text, null: true)
      add(:card_generated_at, :utc_datetime_usec, null: true)
    end
  end
end
