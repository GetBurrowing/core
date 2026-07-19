defmodule Platform.Repo.Migrations.AddTargetPageKeyToMemoryProposals do
  use Ecto.Migration

  @moduledoc """
  Add `target_page_key` to `memory_proposals` so the promotion pipeline
  (task 019f70e9 stage 8 fix) has a stable, auditable destination for
  each approved proposal without re-deriving from category + body every
  time.

  Filled at ingest time by `Platform.Memory.Proposals.derive_target_page_key/3`
  (category → base directory; slug → first meaningful noun from evidence
  or body). Nullable for backfill compatibility with rows inserted
  before this migration — the promotion pipeline falls through to the
  same derivation function when the column is nil, so pre-migration
  rows still promote successfully.
  """

  def change do
    alter table(:memory_proposals) do
      add(:target_page_key, :text)
    end
  end
end
