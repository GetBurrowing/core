defmodule Platform.Repo.Migrations.AddSearchVectorAndTaskReferencesToTasks do
  use Ecto.Migration

  @moduledoc """
  Stage 1 of the vectorize-tasks work: give the `tasks` table the same
  lexical substrate `org_wiki_pages` and `org_wiki_journal_entries` already
  carry (`priv/repo/migrations/20260520020000_add_search_vector_to_org_wiki.exs`),
  and stand up a derived `task_references` table so the follow-up detector
  can index-scan rather than ILIKE the whole `tasks.description` corpus at
  query time.

  ## What lands

    * `tasks.search_vector` — `tsvector GENERATED ALWAYS AS
      (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))) STORED`.
      Metadata JSONB (which carries `feature_area`) is intentionally left
      out — extracting it in the generated expression means a
      `jsonb_extract_path_text` call, and metadata edits are rare enough
      that adding it later (if recall suffers) is cheap. Titles and
      descriptions are the durable text substrate.
    * GIN index `idx_tasks_search` on `search_vector`.
    * `task_references` — derived from `tasks.description`. One row per
      `(source, target)` where `source.description` contains the target's
      UUIDv7. Composite primary key `(source_task_id, target_task_id)`
      double-duties as the uniqueness constraint; a separate
      `idx_task_references_target` index keeps `follow_up_task_ids(target)`
      an index scan.
    * Idempotent backfill of `task_references` from the current
      `tasks.description` corpus. The regex matches the UUIDv7 shape only
      (`019xxxxxx-xxxx-7xxx-xxxx-xxxxxxxxxxxx`); we don't want to
      accidentally reference sponsor/project UUIDs pasted into a
      description. `ON CONFLICT DO NOTHING` makes reruns safe.

  Semantic embeddings live in memory-service (per stage 0 recon) and are
  ingested in stage 2 — nothing pgvector-flavoured lands here.

  `search_vector` is populated for every existing row automatically as
  part of the `ALTER TABLE ... GENERATED ALWAYS AS ... STORED` — no
  separate app-side backfill is needed for the lexical column.
  """

  def up do
    execute("""
    ALTER TABLE tasks
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))
    ) STORED
    """)

    execute("CREATE INDEX idx_tasks_search ON tasks USING gin(search_vector)")

    create table(:task_references, primary_key: false) do
      add(:source_task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:target_task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, default: fragment("now()"), null: false)
    end

    create(index(:task_references, [:target_task_id], name: :idx_task_references_target))

    # Backfill task_references from existing tasks.description text.
    #
    # `regexp_matches(...)` with the `g` flag yields one row per match, so
    # the `SELECT DISTINCT` collapses duplicate mentions inside the same
    # description. We cast the captured string to uuid and constrain to
    # UUIDv7 shape via the regex itself (starts with `019`, version nibble
    # `7`). A self-reference (source = target) is filtered out; a
    # description that mentions a UUID which doesn't actually exist in
    # `tasks` is silently dropped by the INNER JOIN on `tasks target`.
    execute("""
    INSERT INTO task_references (source_task_id, target_task_id)
    SELECT DISTINCT
      source.id AS source_task_id,
      target.id AS target_task_id
    FROM tasks AS source
    CROSS JOIN LATERAL regexp_matches(
      coalesce(source.description, ''),
      '(019[a-f0-9]{5}-[a-f0-9]{4}-7[a-f0-9]{3}-[a-f0-9]{4}-[a-f0-9]{12})',
      'gi'
    ) AS m(captures)
    JOIN tasks AS target ON target.id::text = lower(m.captures[1])
    WHERE source.id <> target.id
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop(table(:task_references))
    execute("DROP INDEX IF EXISTS idx_tasks_search")
    execute("ALTER TABLE tasks DROP COLUMN IF EXISTS search_vector")
  end
end
