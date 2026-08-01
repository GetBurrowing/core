defmodule Platform.Repo.Migrations.PageGrammarFileKeysAndAliasBackfill do
  use Ecto.Migration

  @moduledoc """
  Stack rollup data migration (Sloane-authorized, 2026-06-11).

  T1's path-style migration (`20260519210000`) produced FLAT page keys
  (`org/identity.md`) — but the T5 policy grammar in
  `Platform.Org.Wiki.Routing` only recognises pages at
  `<ns>/page/<rest>` (ns ∈ org | project/<uuid> | space/<uuid>).
  Flat keys classify `:unknown` → `:rejected_namespace`, so
  `memory_search`'s read-gate hydration silently drops them.

  This migration moves every existing flat page key onto the page
  grammar and backfills `org_wiki_aliases` so old keys (and old
  wikilink targets) keep resolving via `Wiki.resolve_alias/2`.

  ## Mapping rule

      org/identity.md           → org/page/identity.md
      project/<uuid>/runbook.md → project/<uuid>/page/runbook.md
      space/<uuid>/notes/a.md   → space/<uuid>/page/notes/a.md

  Rows whose `<rest>` already starts with `page/`, `journal/`, or
  `private/` are left alone, as are keys whose namespace doesn't match
  the grammar (non-UUID project/space slots, legacy `ORG_*.md`
  stragglers, free-form custom keys without a recognised namespace) —
  those classify `:unknown` either way, and rewriting them would not
  make them gate-recognised.

  ## org_wiki_links

  `org_wiki_links.target_path` stores the RAW wikilink target string
  and `Wiki.backlinks/2` matches it by exact `file_key` equality (no
  alias fallback on the link side). Link rows whose `target_path`
  equals a renamed key are rewritten to the new key so backlinks stay
  intact. The mapping `old → new` is purely syntactic (independent of
  workspace), so the string-keyed rewrite is workspace-safe.
  `target_id` is untouched (page ids don't change). Page CONTENT is
  not rewritten — in-body `[[old-key]]` tokens resolve through the
  alias rows at render time.

  ## Collisions

  If a row already exists at the rename target (e.g. both
  `org/deployment.md` and `org/page/deployment.md` were seeded), the
  flat row is skipped — renaming would violate the unique
  `(workspace, file_key)` index and silently merging two pages is not
  a migration's call. Skipped rows keep classifying `:unknown`, same
  as before this migration.

  ## Idempotency

  Mirrors the T1 idiom (`20260519210000`): raw SQL only, a temp
  mapping table, UPDATE gated on the matched row set, alias INSERT
  with `ON CONFLICT DO NOTHING`. Re-running is a no-op once rows have
  moved (the flat-key pattern no longer matches).

  ## Down

  Strip `/page/` for rows that have a matching alias row produced by
  this migration's pattern (alias old_path = flat key, page file_key =
  its page-grammar rewrite), revert the link-row rewrites, then delete
  those alias rows. Pages created directly under the page grammar
  (no flat alias) are untouched.

  Admitted by PR #433 (ADR-0041 org-memory stack rollup), Sloane-authorized
  2026-06-11 — flat page keys to the `<ns>/page/<rest>` routing grammar plus
  alias backfill.
  """

  # Org-scoped alias rows live under the sentinel workspace UUID
  # (composite PK can't hold NULL) — see 20260519220500.
  @nil_sentinel "00000000-0000-0000-0000-000000000000"

  # Namespace grammar from Platform.Org.Wiki.Routing — org, or
  # project/<uuid> / space/<uuid> with a syntactically valid UUID slot.
  @uuid_re "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  @ns_re "(org|project/#{@uuid_re}|space/#{@uuid_re})"

  def up do
    execute("""
    CREATE TEMP TABLE _page_grammar_renames (
      old_key text NOT NULL,
      new_key text NOT NULL,
      page_id uuid NOT NULL,
      workspace_id uuid NOT NULL
    ) ON COMMIT DROP
    """)

    # Every page whose key is `<ns>/<rest>` with <rest> not already
    # under page/ | journal/ | private/, skipping rows whose rename
    # target already exists in the same workspace (see "Collisions").
    execute("""
    INSERT INTO _page_grammar_renames (old_key, new_key, page_id, workspace_id)
    SELECT
      p.file_key AS old_key,
      regexp_replace(p.file_key, '^#{@ns_re}/', '\\1/page/') AS new_key,
      p.id AS page_id,
      COALESCE(p.workspace_id, '#{@nil_sentinel}'::uuid) AS workspace_id
    FROM org_wiki_pages p
    WHERE p.file_key ~ '^#{@ns_re}/.'
      AND p.file_key !~ '^#{@ns_re}/(page|journal|private)/'
      AND NOT EXISTS (
        SELECT 1 FROM org_wiki_pages q
        WHERE q.file_key = regexp_replace(p.file_key, '^#{@ns_re}/', '\\1/page/')
          AND COALESCE(q.workspace_id, '#{@nil_sentinel}'::uuid) =
              COALESCE(p.workspace_id, '#{@nil_sentinel}'::uuid)
      )
    """)

    # Move the page rows onto the page grammar.
    execute("""
    UPDATE org_wiki_pages p
    SET file_key = r.new_key,
        updated_at = now()
    FROM _page_grammar_renames r
    WHERE p.id = r.page_id
    """)

    # Keep backlinks intact: link rows that targeted a renamed key by
    # its old path follow the rename. (Duplicate old_key rows across
    # workspaces map to the same new_key — the rewrite is syntactic.)
    execute("""
    UPDATE org_wiki_links l
    SET target_path = r.new_key
    FROM _page_grammar_renames r
    WHERE l.target_path = r.old_key
    """)

    # Alias rows: OLD flat key → page id, per workspace, so old keys
    # and old wikilink targets keep resolving via resolve_alias/2.
    execute("""
    INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at)
    SELECT r.workspace_id, r.old_key, r.page_id, now()
    FROM _page_grammar_renames r
    ON CONFLICT (workspace_id, old_path) DO NOTHING
    """)
  end

  def down do
    execute("""
    CREATE TEMP TABLE _page_grammar_reverts (
      old_key text NOT NULL,
      new_key text NOT NULL,
      page_id uuid NOT NULL,
      workspace_id uuid NOT NULL
    ) ON COMMIT DROP
    """)

    # Reverse only renames this migration produced: an alias row whose
    # old_path is a flat `<ns>/<rest>` key pointing at a page whose
    # current file_key is exactly that key's page-grammar rewrite.
    execute("""
    INSERT INTO _page_grammar_reverts (old_key, new_key, page_id, workspace_id)
    SELECT a.old_path, p.file_key, p.id, a.workspace_id
    FROM org_wiki_aliases a
    JOIN org_wiki_pages p ON p.id = a.current_id
    WHERE a.old_path ~ '^#{@ns_re}/.'
      AND a.old_path !~ '^#{@ns_re}/(page|journal|private)/'
      AND p.file_key = regexp_replace(a.old_path, '^#{@ns_re}/', '\\1/page/')
      AND a.workspace_id = COALESCE(p.workspace_id, '#{@nil_sentinel}'::uuid)
    """)

    execute("""
    UPDATE org_wiki_links l
    SET target_path = r.old_key
    FROM _page_grammar_reverts r
    WHERE l.target_path = r.new_key
    """)

    execute("""
    UPDATE org_wiki_pages p
    SET file_key = r.old_key,
        updated_at = now()
    FROM _page_grammar_reverts r
    WHERE p.id = r.page_id
    """)

    execute("""
    DELETE FROM org_wiki_aliases a
    USING _page_grammar_reverts r
    WHERE a.old_path = r.old_key
      AND a.workspace_id = r.workspace_id
    """)
  end
end
