defmodule Platform.Org.Wiki do
  @moduledoc """
  Wiki domain logic for org-level pages (ADR-0041).

  Owns CRUD on `org_wiki_pages`, frontmatter parsing, `[[wikilink]]`
  extraction, backlink materialization into `org_wiki_links`, alias
  resolution via `org_wiki_aliases`, and PubSub `:index` events that the
  T3 indexer GenServer subscribes to.

  ## Public surface (stable as of T2)

    * `get_page/2`           — fetch one page (with alias fallback)
    * `list_pages/1`         — list pages in a workspace, ordered by file_key
    * `upsert_page/3`        — create-or-update with optimistic locking
    * `delete_page/2`        — delete a page (links cascade)
    * `backlinks/2`          — pages linking to the given file_key
    * `parse_frontmatter/1`  — pure: {map, body_without_frontmatter}
    * `parse_wikilinks/1`    — pure: list of link descriptors
    * `resolve_alias/2`      — alias-table lookup
    * `resolve_basename/2`   — unique-basename fallback (added on the
      stack rollup under Sloane's 2026-06-11 authorization)

  ## PubSub

  Index events are broadcast on topic `"org_wiki:index"` so T3's indexer
  can subscribe and translate them into embedding/search calls. T2 emits;
  T2 never indexes.

      {:wiki_page_written, %{page_id, file_key, version, workspace_id}}
      {:wiki_page_deleted, %{page_id, file_key, workspace_id}}

  ## Scope (T2)

  Wiki domain only. **Not** in scope: `Platform.Memory.*` calls, the
  indexer GenServer (T3), memory-service HTTP (T3), MCP tool surface
  (T5), LiveView (T7), historian cursors (T6). `Platform.Org.Context`
  is the V1 surface and stays untouched; T5 will retire it.
  """

  import Ecto.Query, only: [from: 2, where: 3, order_by: 3]

  require Logger

  alias Ecto.Adapters.SQL
  alias Platform.Files
  alias Platform.Org.Wiki.Nodes
  alias Platform.Org.Wiki.Routing
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @index_topic "org_wiki:index"

  # Sentinel UUID for `org_wiki_aliases.workspace_id` when the alias
  # is org-scoped (no workspace). Mirrors the migration that swapped
  # the alias table to a composite (workspace_id, old_path) PK.
  @alias_nil_sentinel "00000000-0000-0000-0000-000000000000"

  @typedoc """
  Attributes accepted by `upsert_page/3`. `:content` is the only
  required key; `:updated_by`/`:expected_version` are optional. The
  frontmatter map and version are managed by the module — callers do
  not pass them directly.

  `:org_id` / `:project_id` are the ADR-0042 tenancy columns (task
  `01a0008c` stage 2). They are **opt-in**: a caller that omits them
  keeps the historical behaviour exactly, which for `:org_id` means
  `WikiPage.changeset/2` attaching the row to the root org. A
  caller that writes under a tenant-scoped path — anything shaped
  `project/<uuid>/…` — must pass both, or the row's tenancy will
  disagree with its own `file_key`.
  """
  @type page_attrs :: %{
          optional(:content) => String.t(),
          optional(:updated_by) => binary() | nil,
          optional(:org_id) => binary() | nil,
          optional(:project_id) => binary() | nil,
          optional(String.t()) => term()
        }

  @typedoc """
  A single parsed wikilink. `position` is the 0-indexed occurrence
  within the page body (post-frontmatter).
  """
  @type wikilink :: %{
          target_path: String.t(),
          display_text: String.t() | nil,
          position: non_neg_integer()
        }

  @typedoc "Parsed YAML frontmatter map."
  @type frontmatter :: %{optional(String.t()) => term()}

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Fetch a wiki page by `file_key`.

  Falls back through `org_wiki_aliases` when the direct lookup misses
  so legacy V1 keys (`ORG_IDENTITY.md`, …) keep resolving after T1's
  path-style rename.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
    * `:access_scope` — optional `%Platform.Access.Scope{}` (task
      01a1386d-e528 stage 4). Given, a page the scope may not
      `memory.read` (`scope_by/3`) answers `nil`, exactly as an absent page
      does, whether it was reached directly or through an alias. Absent,
      the lookup is unchanged.
  """
  @spec get_page(String.t(), keyword()) :: WikiPage.t() | nil
  def get_page(file_key, opts \\ []) when is_binary(file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)
    access_scope = Keyword.get(opts, :access_scope)

    direct =
      WikiPage
      |> where([p], p.file_key == ^file_key)
      |> filter_workspace(workspace_id)
      |> maybe_scope_by(access_scope)
      |> Repo.one()

    direct || readable_or_nil(lookup_via_alias(file_key, workspace_id), access_scope)
  end

  @doc """
  List wiki pages in a workspace, ordered by `file_key asc`.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
    * `:access_scope` — optional `%Platform.Access.Scope{}` (task
      01a1386d-e528 stage 4): only the pages it may `memory.read`
      (`scope_by/3`). Absent, the listing is unchanged.
  """
  @spec list_pages(keyword()) :: [WikiPage.t()]
  def list_pages(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    WikiPage
    |> filter_workspace(workspace_id)
    |> maybe_scope_by(Keyword.get(opts, :access_scope))
    |> order_by([p], asc: p.file_key)
    |> Repo.all()
  end

  @doc """
  Restrict a `WikiPage` query (its root binding) to the pages `scope` may
  `memory.read` (task 01a1386d-e528 stage 4,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  A thin call to `Platform.Access.Query.where_readable/5` over
  `file_key` and `workspace_id`. Grants name org-memory NODES
  (`Platform.Org.Wiki.Nodes`), never a path string; the query reads which
  node covers each page's path now. Precedence (deny wins, downward only)
  is decided in `Platform.Access`. With no `memory.read` grant on the scope
  the query is returned unchanged.
  """
  @spec scope_by(Ecto.Queryable.t(), Platform.Access.Scope.t(), :memory_page) ::
          Ecto.Queryable.t()
  def scope_by(query, %Platform.Access.Scope{} = scope, :memory_page) do
    Platform.Access.Query.where_readable(query, scope, "memory.read", :memory_page, %{
      path: :file_key,
      workspace_id: :workspace_id
    })
  end

  @doc false
  # The optional `:access_scope` seam shared with `Platform.Org.Wiki.Search`.
  def maybe_scope_by(query, %Platform.Access.Scope{} = scope),
    do: scope_by(query, scope, :memory_page)

  def maybe_scope_by(query, _scope), do: query

  # An alias hit is a page at ANOTHER key, so it is checked against the
  # scope on its own row: a denied page is never reachable by its old name.
  defp readable_or_nil(nil, _scope), do: nil
  defp readable_or_nil(%WikiPage{} = page, nil), do: page

  defp readable_or_nil(%WikiPage{id: id} = page, scope) do
    readable =
      WikiPage
      |> where([p], p.id == ^id)
      |> maybe_scope_by(scope)
      |> Repo.exists?()

    if readable, do: page, else: nil
  end

  # ── The pages / files corpus partition (task 01a0008c stage 4) ───────────
  #
  # A catalog card is a wiki page at `project/<uuid>/page/files/<slug>.md`,
  # so the moment `files` became the Historian's fifth corpus, every card
  # was sitting in TWO corpora at once. The Historian charges bytes for
  # what the renderer renders (the `019fa1cc` invariant), and a card
  # rendered twice is charged twice — the same 100k-token threshold fires
  # on doubled bytes and the Historian digests the same card in a `pages`
  # window and again in a `files` window.
  #
  # These two composers ARE the partition. They are complements over one
  # predicate — `Platform.Files.card_page_keys_query/0` — so `pages` and
  # `files` cannot disagree about which side a card falls on. Every
  # `pages` site composes `exclude_card_pages/1`; every `files` site
  # composes `only_card_pages/1`. An exclusion applied at some pages
  # sites and not others is worse than none: it double-charges the sites
  # that forgot and drops nothing anywhere, which reads as a byte signal
  # that is merely "a bit high".

  @doc """
  Narrows a wiki-page query to rows that are NOT catalog cards.

  The `pages` half of the pages/files corpus partition. See the note
  above this function and `Platform.Files.card_page_keys_query/0`.

  Composes on `file_key`, so it works against both `WikiPage` and the
  schemaless `from(p in "org_wiki_pages")` sources the Historian's
  byte-sum queries use.
  """
  @spec exclude_card_pages(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_card_pages(query) do
    where(query, [p], p.file_key not in subquery(Files.card_page_keys_query()))
  end

  @doc """
  Narrows a wiki-page query to rows that ARE catalog cards.

  The `files` half of the pages/files corpus partition — the exact
  complement of `exclude_card_pages/1`.
  """
  @spec only_card_pages(Ecto.Queryable.t()) :: Ecto.Query.t()
  def only_card_pages(query) do
    where(query, [p], p.file_key in subquery(Files.card_page_keys_query()))
  end

  # ── Product-owned docs: the `burrow/` namespace (task 01a10a44 stage 2) ──
  #
  # `burrow/page/*` rows are Burrow product documentation, seeded from the
  # repo by `Platform.Org.BurrowDocs` on every boot. They are read-only to
  # every agent and member. `Wiki.Routing` refuses them on the memory_*
  # tool surface; the checks below are the DOMAIN backstop for the writers
  # that never pass through Routing (the org-memory LiveView, memory
  # proposals, the maintenance subagent, file supersession, the cataloger).
  #
  # A write to any `burrow/` key is refused with `{:error, :product_owned}`
  # unless the caller passes the `:product_docs` opt set to `true`, and only
  # `Platform.Org.BurrowDocs` does (a guard test pins that).

  @product_owned_prefix "burrow/"

  @doc """
  True when `file_key` sits in the product-owned `burrow/` namespace.
  """
  @spec product_owned_key?(term()) :: boolean()
  def product_owned_key?(file_key) when is_binary(file_key),
    do: String.starts_with?(file_key, @product_owned_prefix)

  def product_owned_key?(_), do: false

  @doc """
  The `file_key` prefix of the product-owned namespace (`"burrow/"`).
  """
  @spec product_owned_prefix() :: String.t()
  def product_owned_prefix, do: @product_owned_prefix

  @doc """
  The `file_key` prefix of product-owned PAGES (`"burrow/page/"`).

  The one name for the global, cross-tenant pages exception: search's
  org scoping and the dispatch preamble's org-independent product band
  both read it, so a later global namespace changes one place.
  """
  @spec product_docs_page_prefix() :: String.t()
  def product_docs_page_prefix, do: @product_owned_prefix <> "page/"

  @doc """
  Narrows a wiki-page query to rows OUTSIDE the product-owned `burrow/`
  namespace.

  Composed at every Historian `pages` site next to `exclude_card_pages/1`:
  a deploy that rewrites a doc bumps its `updated_at`, and without this
  each release would feed product docs into a digest window.

  Composes on `file_key`, so it works against `WikiPage` and the
  schemaless `"org_wiki_pages"` sources alike.
  """
  @spec exclude_product_docs(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_product_docs(query) do
    pattern = @product_owned_prefix <> "%"
    where(query, [p], not like(p.file_key, ^pattern))
  end

  # The backstop. `:ok` unless a product-owned key is written without the
  # BurrowDocs opt.
  defp check_product_owned(keys, opts) do
    if Keyword.get(opts, :product_docs) == true or not Enum.any?(keys, &product_owned_key?/1),
      do: :ok,
      else: {:error, :product_owned}
  end

  @doc """
  List wiki pages updated in `[window_start, window_end)`, ordered by
  `updated_at asc`.

  Used by the Historian's `ActivityDigest.build_windowed/1` (task 019f4f55
  stage 2) so the pages corpus can be sliced into the same per-window
  digests the messages / transcripts corpora already support via
  `Platform.Chat.list_messages_since/2` /
  `Platform.Meetings.list_transcripts_since/2`.

  **Catalog cards are excluded** (task 01a0008c stage 4): they are the
  `files` corpus, not the `pages` corpus. This function is the digest's
  sole `pages` accessor, so the exclusion lands here rather than being
  post-filtered by the caller — a second predicate at the call site is
  how the byte signal and the renderer drifted apart in `019fa1cc`.
  Callers that want every page regardless of card status want
  `list_pages/1`.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped; matches rows with
      `is_nil(workspace_id)`)
    * `:window_end`   (default `DateTime.utc_now/0`)
    * `:access_scope` — optional (task 01a1386d-e528 stage 4): only the
      pages the scope may `memory.read` (`scope_by/3`). Absent, unchanged.
  """
  @spec list_pages_updated_since(DateTime.t(), keyword()) :: [WikiPage.t()]
  def list_pages_updated_since(%DateTime{} = window_start, opts \\ []) do
    window_start
    |> pages_updated_since_query(opts)
    |> exclude_card_pages()
    |> exclude_product_docs()
    |> Repo.all()
  end

  @doc """
  List catalog-card wiki pages updated in `[window_start, window_end)`,
  ordered by `updated_at asc` — the `files` corpus accessor
  (task 01a0008c stage 4).

  The exact complement of `list_pages_updated_since/2`: same table, same
  clock, same ordering, opposite side of the card partition. Every wiki
  page in the span is returned by exactly one of the two.

  **This is why the `files` corpus is weighted by CARD bytes, not
  document bytes.** What a `files` window renders is these rows, and the
  byte signal must charge for what the renderer renders. Weighting by
  `platform_file_texts.text` instead would read as hundreds of thousands
  of tokens against the window budget while producing a body of a few
  KB — and would put the document text back into the Historian's context,
  which is the entire thing the catalog exists to remove.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
    * `:window_end`   (default `DateTime.utc_now/0`)
  """
  @spec list_card_pages_updated_since(DateTime.t(), keyword()) :: [WikiPage.t()]
  def list_card_pages_updated_since(%DateTime{} = window_start, opts \\ []) do
    window_start
    |> pages_updated_since_query(opts)
    |> only_card_pages()
    |> Repo.all()
  end

  defp pages_updated_since_query(%DateTime{} = window_start, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    window_end = Keyword.get(opts, :window_end, DateTime.utc_now())

    WikiPage
    |> where(
      [p],
      p.updated_at >= ^window_start and p.updated_at < ^window_end
    )
    |> filter_workspace(workspace_id)
    |> maybe_scope_by(Keyword.get(opts, :access_scope))
    |> order_by([p], asc: p.updated_at)
  end

  @doc """
  List wiki journal entries authored in `[window_start, window_end)`,
  ordered by `inserted_at asc`.

  Journal entries are append-only (their schema disables `updated_at`)
  so `inserted_at` is the right corpus timestamp — matches the byte
  accounting `Platform.Agents.Historian.sum_corpus_bytes("journal", ...)`
  uses for its cursor filter.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
    * `:window_end`   (default `DateTime.utc_now/0`)
  """
  @spec list_journal_entries_since(DateTime.t(), keyword()) ::
          [WikiJournalEntry.t()]
  def list_journal_entries_since(%DateTime{} = window_start, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    window_end = Keyword.get(opts, :window_end, DateTime.utc_now())

    WikiJournalEntry
    |> where(
      [e],
      e.inserted_at >= ^window_start and e.inserted_at < ^window_end
    )
    |> filter_workspace(workspace_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Create or update a wiki page.

  Single transaction:

    1. Resolve the existing row (direct file_key, or via alias for V1
       compatibility — the write lands on the canonical path-style row
       in that case).
    2. Parse frontmatter from `attrs.content`; store the parsed map in
       `WikiPage.frontmatter` while keeping the ORIGINAL body
       (delimiters and all) in `content`.
    3. Insert/update with optimistic locking on `version`.
    4. Replace `org_wiki_links` rows for the page (delete-all + bulk
       insert from parsed wikilinks). Targets are resolved by
       `file_key IN (...)` within the same workspace; unresolved
       targets get `target_id: nil` and preserve `target_path`.
    5. Emit telemetry `[:platform, :org, :wiki_page_written]` and
       PubSub `{:wiki_page_written, payload}` on `"org_wiki:index"`.

  ## Tenancy (`:org_id` / `:project_id`) — task 01a0008c stage 2

  Until this change, `upsert_page/3` read only `:content` and
  `:updated_by` out of `attrs`. Every other column — including the
  ADR-0042 tenancy pair — was unreachable through this function, so a
  page written at `project/<uuid>/page/…` landed as a **root-org row
  with a nil `project_id`**: `WikiPage.changeset/2`'s
  `maybe_default_org_id/1` fills a nil `org_id` with the org named by
  `Platform.Tenancy.root_org_slug/0` by design, as a legacy-caller
  accommodation. The path said one tenant, the row said another, and
  because `update_changeset/2` cast neither column, no later write
  through this path could repair it.

  Both keys are now read from `attrs` and forwarded to the changeset —
  on insert AND on update, so an existing mis-tenanted row is
  repairable by rewriting it with the right pair. Only keys the caller
  actually supplies are forwarded: omit them and behaviour is
  byte-identical to before, root-org default included. Nothing here
  *requires* them, because most callers legitimately write org-level
  pages; the requirement belongs to whoever owns a tenant-scoped path.
  `Platform.Files.Cataloger` is the reference caller.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:expected_version` — when set, a mismatch returns `{:error, :stale}`
  """
  @spec upsert_page(String.t(), page_attrs(), keyword()) ::
          {:ok, WikiPage.t()} | {:error, Ecto.Changeset.t() | :stale | :product_owned}
  def upsert_page(file_key, attrs, opts \\ []) when is_binary(file_key) and is_map(attrs) do
    case check_product_owned([file_key], opts) do
      :ok -> do_upsert_page(file_key, attrs, opts)
      {:error, _} = err -> err
    end
  end

  defp do_upsert_page(file_key, attrs, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    expected_version = Keyword.get(opts, :expected_version)

    content =
      Map.get(attrs, :content) || Map.get(attrs, "content") || ""

    updated_by =
      Map.get(attrs, :updated_by) || Map.get(attrs, "updated_by")

    tenancy_attrs = tenancy_attrs(attrs)

    {frontmatter, _body_after_fm} = parse_frontmatter(content)
    parsed_links = parse_wikilinks(content)

    result =
      Repo.transaction(fn ->
        existing =
          WikiPage
          |> where([p], p.file_key == ^file_key)
          |> filter_workspace(workspace_id)
          |> Repo.one() ||
            lookup_via_alias(file_key, workspace_id)

        page =
          case existing do
            nil ->
              %WikiPage{}
              |> WikiPage.changeset(
                Map.merge(tenancy_attrs, %{
                  file_key: file_key,
                  workspace_id: workspace_id,
                  content: content,
                  frontmatter: frontmatter,
                  updated_by: updated_by
                })
              )
              |> Repo.insert()
              |> unwrap_or_rollback()

            %WikiPage{} = row ->
              # An alias can resolve a non-product key onto a product row.
              if check_product_owned([row.file_key], opts) != :ok do
                Repo.rollback(:product_owned)
              end

              if not is_nil(expected_version) and row.version != expected_version do
                Repo.rollback(:stale)
              end

              row
              |> WikiPage.update_changeset(
                Map.merge(tenancy_attrs, %{
                  content: content,
                  frontmatter: frontmatter,
                  updated_by: updated_by
                })
              )
              |> Repo.update()
              |> case do
                {:ok, updated} -> updated
                {:error, %Ecto.Changeset{errors: [version: _]}} -> Repo.rollback(:stale)
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end

        materialize_links(page, parsed_links)

        page
      end)

    case result do
      {:ok, %WikiPage{} = page} ->
        :telemetry.execute(
          [:platform, :org, :wiki_page_written],
          %{system_time: System.system_time()},
          %{
            page_id: page.id,
            file_key: page.file_key,
            version: page.version,
            workspace_id: page.workspace_id
          }
        )

        broadcast_index_event(:wiki_page_written, %{
          page_id: page.id,
          file_key: page.file_key,
          version: page.version,
          workspace_id: page.workspace_id
        })

        {:ok, page}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Collect only the tenancy keys the caller actually supplied.
  #
  # Absence and an explicit nil are deliberately NOT the same thing
  # here. Absence means "I have no opinion" and must leave the legacy
  # behaviour untouched, including the root-org default on insert. An
  # explicit nil means "unset this", which is a legitimate thing to ask
  # for on `project_id` and which the changeset will reject on `org_id`
  # (it is `validate_required`) rather than silently re-defaulting.
  defp tenancy_attrs(attrs) do
    [:org_id, :project_id]
    |> Enum.reduce(%{}, fn key, acc ->
      cond do
        Map.has_key?(attrs, key) -> Map.put(acc, key, Map.fetch!(attrs, key))
        Map.has_key?(attrs, Atom.to_string(key)) -> Map.put(acc, key, attrs[Atom.to_string(key)])
        true -> acc
      end
    end)
  end

  @doc """
  Delete a wiki page. `org_wiki_links` rows referencing it cascade via
  the FK's `on_delete: :delete_all`. Emits a `:wiki_page_deleted`
  index event.

  ## Options
    * `:workspace_id` (default `nil`)
  """
  @spec delete_page(String.t(), keyword()) ::
          {:ok, WikiPage.t()} | {:error, :not_found | :product_owned | Ecto.Changeset.t()}
  def delete_page(file_key, opts \\ []) when is_binary(file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)

    with :ok <- check_product_owned([file_key], opts),
         %WikiPage{} = page <-
           get_page(file_key, workspace_id: workspace_id) || {:error, :not_found},
         :ok <- check_product_owned([page.file_key], opts) do
      do_delete_page(page)
    end
  end

  defp do_delete_page(%WikiPage{} = page) do
    case Repo.delete(page) do
      {:ok, deleted} ->
        broadcast_index_event(:wiki_page_deleted, %{
          page_id: deleted.id,
          file_key: deleted.file_key,
          workspace_id: deleted.workspace_id
        })

        {:ok, deleted}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Pages that link TO `file_key` (via `org_wiki_links.target_path`).

  Two-step query: collect `source_id`s from link rows whose
  `target_path` equals `file_key`, then load the distinct source page
  rows in the caller's workspace. Workspace boundary is enforced on
  the source page row so cross-tenant link rows can never leak.

  ## Options
    * `:workspace_id` (default `nil`)
  """
  @spec backlinks(String.t(), keyword()) :: [WikiPage.t()]
  def backlinks(file_key, opts \\ []) when is_binary(file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)

    # Raw SQL for the link side — `org_wiki_links` has no schema, so
    # we can't lean on Ecto's auto-cast for `source_id`. Load the
    # 16-byte binaries back to UUID strings before threading them
    # into the `WikiPage` query.
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT DISTINCT source_id FROM org_wiki_links WHERE target_path = $1",
        [file_key]
      )

    source_ids = Enum.map(rows, fn [bin] -> Ecto.UUID.load!(bin) end)

    if source_ids == [] do
      []
    else
      WikiPage
      |> where([p], p.id in ^source_ids)
      |> filter_workspace(workspace_id)
      |> order_by([p], asc: p.file_key)
      |> Repo.all()
    end
  end

  @doc """
  Resolve `file_key` through `org_wiki_aliases`.

  Workspace-scoped via the composite PK on the alias table. Returns
  the target page or `nil`.

  ## Options
    * `:workspace_id` (default `nil`)
  """
  @spec resolve_alias(String.t(), keyword()) :: WikiPage.t() | nil
  def resolve_alias(file_key, opts \\ []) when is_binary(file_key) do
    lookup_via_alias(file_key, Keyword.get(opts, :workspace_id))
  end

  @doc """
  Resolve a bare wikilink target by basename, when exactly ONE page in
  scope matches.

  Fallback ordered AFTER exact-key and alias lookup (callers — e.g.
  the LiveView's wikilink lookup builder — try those first):
  `[[identity]]` resolves to `org/page/identity.md` when that is the
  only page whose basename matches. Zero matches or 2+ matches return
  `nil`, so ambiguous links stay dangling.

  Matching rule: directories are stripped (only the final path segment
  of each `file_key` is compared), the `.md` extension is optional on
  both sides (`[[identity]]` and `[[identity.md]]` both match
  `org/page/identity.md`), comparison is case-sensitive. Targets that
  contain a `/` never basename-match — path-shaped targets belong to
  the exact-key/alias steps.

  Link materialization is unaffected: `upsert_page/3` keeps recording
  RAW wikilink targets in `org_wiki_links.target_path` and
  `backlinks/2` matches those raw strings, so basename resolution is a
  read-time (render) concern only.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
  """
  @spec resolve_basename(String.t(), keyword()) :: WikiPage.t() | nil
  def resolve_basename(target, opts \\ []) when is_binary(target) do
    workspace_id = Keyword.get(opts, :workspace_id)
    stem = String.replace_suffix(target, ".md", "")

    if stem == "" or String.contains?(stem, "/") do
      nil
    else
      WikiPage
      |> filter_workspace(workspace_id)
      |> Repo.all()
      |> Enum.filter(fn page -> basename_stem(page.file_key) == stem end)
      |> case do
        [page] -> page
        _zero_or_ambiguous -> nil
      end
    end
  end

  @doc """
  Rename a page from `old_file_key` to `new_file_key` within a single
  `Repo.transaction/1`.

  The transaction reads the source row, upserts a new row at
  `new_file_key` carrying the source content + `updated_by`, and
  deletes the source row. A partial failure rolls back both sides so
  we never orphan a half-renamed page.

  Two `:wiki_page_written` + one `:wiki_page_deleted` index events
  fire downstream (one per `upsert_page/3` + `delete_page/2`). The T3
  indexer translates those into a vector-store delete + re-ingest so
  the embedding lands against the new path.

  Routing/ACL checks (Historian-only on page paths, owner-only on
  private paths) belong to the caller. T5 stage 3's `memory_rename`
  tool clause gates BOTH `old_file_key` and `new_file_key` against
  `Platform.Org.Wiki.Routing.gate_write/3` before invoking.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:updated_by`   — UUID written to the new row's `updated_by`
      column. Defaults to the source row's existing `updated_by`.
  """
  @spec rename_page(String.t(), String.t(), keyword()) ::
          {:ok, WikiPage.t()}
          | {:error, :not_found | :stale | :product_owned | Ecto.Changeset.t() | term()}
  def rename_page(old_file_key, new_file_key, opts \\ [])
      when is_binary(old_file_key) and is_binary(new_file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      check_product_owned([old_file_key, new_file_key], opts) != :ok ->
        {:error, :product_owned}

      old_file_key == new_file_key ->
        {:error, :same_path}

      true ->
        do_rename(old_file_key, new_file_key, workspace_id, opts)
    end
  end

  defp do_rename(old_file_key, new_file_key, workspace_id, opts) do
    # Outer transaction ensures the upsert + delete commit atomically.
    # We pre-resolve the source row so a missing source short-circuits
    # before any write, and we keep `upsert_page/3`'s own transaction
    # nested (Ecto treats nested `Repo.transaction/1` as a savepoint
    # on the outer transaction, so an inner `Repo.rollback/1` aborts
    # the whole rename — which is the behaviour we want).
    case Repo.transaction(fn ->
           source =
             WikiPage
             |> where([p], p.file_key == ^old_file_key)
             |> filter_workspace(workspace_id)
             |> Repo.one() ||
               lookup_via_alias(old_file_key, workspace_id)

           case source do
             nil ->
               Repo.rollback(:not_found)

             %WikiPage{} = page ->
               # An alias can resolve the old key onto a product row.
               if check_product_owned([page.file_key], opts) != :ok do
                 Repo.rollback(:product_owned)
               end

               updated_by = Keyword.get(opts, :updated_by, page.updated_by)

               # Upsert the new path inside the outer transaction.
               case upsert_page(
                      new_file_key,
                      %{content: page.content, updated_by: updated_by},
                      workspace_id: workspace_id
                    ) do
                 {:ok, new_page} ->
                   # Delete the source row. Skip the public
                   # `delete_page/2` to avoid a redundant `get_page/2`
                   # round-trip (we already loaded the row above).
                   case Repo.delete(page) do
                     {:ok, deleted} ->
                       broadcast_index_event(:wiki_page_deleted, %{
                         page_id: deleted.id,
                         file_key: deleted.file_key,
                         workspace_id: deleted.workspace_id
                       })

                       # The location identity follows the page, only once
                       # both page writes succeeded, inside this same
                       # transaction. See Platform.Org.Wiki.Nodes.
                       move_node!(deleted.file_key, new_file_key, workspace_id)

                       new_page

                     {:error, reason} ->
                       Repo.rollback(reason)
                   end

                 {:error, reason} ->
                   Repo.rollback(reason)
               end
           end
         end) do
      {:ok, %WikiPage{} = page} -> {:ok, page}
      {:error, _} = err -> err
    end
  end

  defp move_node!(old_key, new_key, workspace_id) do
    case Nodes.move(old_key, new_key, workspace_id: workspace_id) do
      {:ok, _count} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Pages whose `file_key` starts with `prefix`, ordered by `file_key asc`.
  Exact keys only: no alias fallback.

  ## Options
    * `:workspace_id` (default `nil`)
  """
  @spec list_pages_under(String.t(), keyword()) :: [WikiPage.t()]
  def list_pages_under(prefix, opts \\ []) when is_binary(prefix) do
    WikiPage
    |> where([p], fragment("starts_with(?, ?)", p.file_key, ^prefix))
    |> filter_workspace(Keyword.get(opts, :workspace_id))
    |> order_by([p], asc: p.file_key)
    |> Repo.all()
  end

  @doc """
  Rename a directory prefix: every page under `old_prefix` moves to the same
  relative key under `new_prefix`, then every memory node still under
  `old_prefix` (the prefix node itself, nodes of deleted pages) moves too
  (task 01a1386d-e528, `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  All-or-nothing in ONE transaction. Each page goes through the same
  `do_rename/4` a single `rename_page/3` uses, so per-page content,
  `version` and `updated_by` are what N single renames would produce.

  Refusals, checked before any write:
    * `{:error, :not_a_prefix}` unless both end in `/`;
    * `{:error, :same_path}` when they are equal;
    * `{:error, :product_owned}` for `burrow/`, as `check_product_owned/2`;
    * `{:error, :ambiguous_kind}` unless both classify as Historian page
      namespaces;
    * `{:error, {:conflict, paths}}` when ANY target location already holds
      a page or a memory node. The target locations are `new_prefix` itself
      and the new key of every page and node under `old_prefix`. A subtree
      rename never overwrites, so the single-page overwrite semantic (and its
      node merge) never applies here;
    * `{:error, :not_found}` when there is no page and no node under
      `old_prefix`, the answer a trailing-slash `rename_page/3` gave before
      this existed.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:updated_by` — as `rename_page/3`
  """
  @spec rename_prefix(String.t(), String.t(), keyword()) ::
          {:ok, [{String.t(), WikiPage.t()}]}
          | {:error,
             :not_a_prefix
             | :same_path
             | :product_owned
             | :ambiguous_kind
             | :not_found
             | {:conflict, [String.t()]}
             | term()}
  def rename_prefix(old_prefix, new_prefix, opts \\ [])
      when is_binary(old_prefix) and is_binary(new_prefix) do
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      not (String.ends_with?(old_prefix, "/") and String.ends_with?(new_prefix, "/")) ->
        {:error, :not_a_prefix}

      old_prefix == new_prefix ->
        {:error, :same_path}

      check_product_owned([old_prefix, new_prefix], opts) != :ok ->
        {:error, :product_owned}

      not (historian_page_prefix?(old_prefix) and historian_page_prefix?(new_prefix)) ->
        {:error, :ambiguous_kind}

      true ->
        do_rename_prefix(old_prefix, new_prefix, workspace_id, opts)
    end
  end

  defp historian_page_prefix?(prefix),
    do: match?(%{kind: :page, write_role: :historian}, Routing.classify(prefix))

  defp do_rename_prefix(old_prefix, new_prefix, workspace_id, opts) do
    Repo.transaction(fn ->
      pages = list_pages_under(old_prefix, workspace_id: workspace_id)
      nodes = Nodes.current_under(old_prefix, workspace_id: workspace_id)

      if pages == [] and nodes == [] do
        Repo.rollback(:not_found)
      end

      retarget = &(new_prefix <> String.replace_prefix(&1, old_prefix, ""))
      page_moves = Enum.map(pages, &{&1.file_key, retarget.(&1.file_key)})
      page_targets = Enum.map(page_moves, &elem(&1, 1))
      node_targets = Enum.map(nodes, &retarget.(&1.path))
      # The target prefix itself is a target location: a node already there
      # would otherwise be merged into silently.
      targets = Enum.uniq([new_prefix | page_targets ++ node_targets])

      case prefix_conflicts(targets, workspace_id) do
        [] -> :ok
        conflicts -> Repo.rollback({:conflict, conflicts})
      end

      renamed =
        Enum.map(page_moves, fn {from, to} ->
          case do_rename(from, to, workspace_id, opts) do
            {:ok, page} -> {from, page}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      # Whatever is still under the old prefix: the prefix node itself and
      # nodes of pages that no longer exist.
      case Nodes.move(old_prefix, new_prefix, workspace_id: workspace_id) do
        {:ok, _} -> renamed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp prefix_conflicts(targets, workspace_id) do
    pages =
      WikiPage
      |> where([p], p.file_key in ^targets)
      |> filter_workspace(workspace_id)
      |> Repo.all()
      |> Enum.map(& &1.file_key)

    Enum.sort(Enum.uniq(pages ++ Nodes.occupied(targets, workspace_id: workspace_id)))
  end

  # ── Pure parsers (filled in by Stage 2) ───────────────────────────────

  @doc """
  Parse YAML frontmatter from a page body.

  Detects a leading YAML block delimited by `---\\n` ... `\\n---\\n`
  (or `\\n---` at end-of-string). Returns
  `{frontmatter_map, body_without_frontmatter}`. When no frontmatter
  is present, returns `{%{}, original_body}`. When the delimiter is
  malformed or YAML parsing fails, logs a warning and returns
  `{%{}, original_body}` — never raises.

  Map keys are coerced to strings (Yaml elixir returns binary keys by
  default). Control characters in keys are rejected (the offending
  key is dropped from the result).
  """
  @spec parse_frontmatter(String.t()) :: {frontmatter(), String.t()}
  def parse_frontmatter(body) when is_binary(body) do
    case detect_frontmatter(body) do
      {:none, _} ->
        {%{}, body}

      {:found, yaml_block, rest} ->
        case YamlElixir.read_from_string(yaml_block) do
          {:ok, parsed} when is_map(parsed) ->
            {sanitize_frontmatter_keys(parsed), rest}

          {:ok, _non_map} ->
            # YAML parsed but isn't a map (e.g. top-level scalar). We
            # only accept map-shaped frontmatter; degrade silently.
            {%{}, body}

          {:error, reason} ->
            require Logger
            Logger.warning("Org.Wiki: malformed frontmatter: #{inspect(reason)}")
            {%{}, body}
        end
    end
  end

  def parse_frontmatter(_), do: {%{}, ""}

  @doc """
  Extract `[[wikilinks]]` from page body content.

  Two forms:

    * `[[path/to/page]]` → `%{target_path: "path/to/page", display_text: nil, position: N}`
    * `[[alias|display text]]` → `%{target_path: "alias", display_text: "display text", position: N}`

  `position` is the 0-indexed order of occurrence within the body.

  Links inside fenced code blocks (```` ``` ````) and inline code
  spans (`` `…` ``) are ignored. Empty / whitespace-only targets are
  skipped silently. Targets containing newlines are rejected.
  """
  @spec parse_wikilinks(String.t()) :: [wikilink()]
  def parse_wikilinks(body) when is_binary(body) do
    body
    |> strip_code_regions()
    |> extract_wikilink_tokens()
    |> Enum.flat_map(&parse_link_token_to_partial/1)
    |> Enum.with_index()
    |> Enum.map(fn {{target, display}, idx} ->
      %{target_path: target, display_text: display, position: idx}
    end)
  end

  def parse_wikilinks(_), do: []

  # ── Internals ─────────────────────────────────────────────────────────

  @doc false
  @spec index_topic() :: String.t()
  def index_topic, do: @index_topic

  # Broadcast index events. Kept private; the index topic is exposed
  # via `index_topic/0` so test code can subscribe.
  @spec broadcast_index_event(atom(), map()) :: :ok | {:error, term()}
  defp broadcast_index_event(event, payload)
       when is_atom(event) and is_map(payload) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @index_topic, {event, payload})
  end

  # ── Query helpers ─────────────────────────────────────────────────────

  defp filter_workspace(queryable, nil) do
    where(queryable, [p], is_nil(p.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [p], p.workspace_id == ^workspace_id)
  end

  # ── Basename resolution ───────────────────────────────────────────────

  # Final path segment with the optional `.md` extension stripped —
  # the comparison form for `resolve_basename/2`.
  @spec basename_stem(String.t()) :: String.t()
  defp basename_stem(file_key) do
    file_key
    |> String.split("/")
    |> List.last()
    |> String.replace_suffix(".md", "")
  end

  # ── Alias resolution ──────────────────────────────────────────────────

  # Workspace-scoped alias lookup. The alias table has a composite PK
  # (workspace_id, old_path); org-scoped rows live under a sentinel
  # UUID because Postgres can't store NULL in a PK column. The join
  # to `org_wiki_pages` also filters by workspace so a malformed
  # alias row can never leak a cross-tenant page.
  @spec lookup_via_alias(String.t(), binary() | nil) :: WikiPage.t() | nil
  defp lookup_via_alias(file_key, nil) do
    sentinel = @alias_nil_sentinel

    from(a in "org_wiki_aliases",
      join: p in WikiPage,
      on: p.id == a.current_id,
      where:
        a.old_path == ^file_key and
          a.workspace_id == type(^sentinel, :binary_id) and
          is_nil(p.workspace_id),
      select: p
    )
    |> Repo.one()
  end

  defp lookup_via_alias(file_key, workspace_id) do
    from(a in "org_wiki_aliases",
      join: p in WikiPage,
      on: p.id == a.current_id,
      where:
        a.old_path == ^file_key and
          a.workspace_id == type(^workspace_id, :binary_id) and
          p.workspace_id == ^workspace_id,
      select: p
    )
    |> Repo.one()
  end

  # ── Link materialisation ──────────────────────────────────────────────

  # Replace `org_wiki_links` rows for the page: delete all current
  # rows for the source, then bulk-insert one row per parsed
  # wikilink. Resolve `target_id` by file_key lookup within the
  # source page's workspace; unresolved targets keep `target_id: nil`
  # and `target_path` set so backlinks still work and a later upsert
  # of the target leaves them for the next write to reconcile.
  @spec materialize_links(WikiPage.t(), [wikilink()]) :: :ok
  defp materialize_links(%WikiPage{} = page, parsed_links) do
    # `org_wiki_links` has no Ecto schema (raw migration). For DELETE
    # we drop to plain SQL — that keeps the UUID handling explicit and
    # avoids Ecto's schemaless-query dump dance. For INSERT we use
    # `Repo.insert_all/2` with hand-dumped 16-byte UUID binaries, which
    # Postgrex accepts directly for `uuid` columns.
    source_id_bin = Ecto.UUID.dump!(page.id)

    SQL.query!(
      Repo,
      "DELETE FROM org_wiki_links WHERE source_id = $1",
      [source_id_bin]
    )

    if parsed_links == [] do
      :ok
    else
      target_paths = parsed_links |> Enum.map(& &1.target_path) |> Enum.uniq()
      target_index = lookup_target_ids(target_paths, page.workspace_id)

      now = DateTime.utc_now()

      rows =
        Enum.map(parsed_links, fn link ->
          target_id_bin =
            case Map.get(target_index, link.target_path) do
              nil -> nil
              id when is_binary(id) -> Ecto.UUID.dump!(id)
            end

          %{
            id: Ecto.UUID.bingenerate(),
            source_id: source_id_bin,
            target_path: link.target_path,
            target_id: target_id_bin,
            display_text: link.display_text,
            position: link.position,
            inserted_at: now
          }
        end)

      {_count, _} = Repo.insert_all("org_wiki_links", rows)
      :ok
    end
  end

  # Single workspace-scoped lookup for the set of target paths. Returns a
  # map of `target_path => target_id`. Paths with no matching page are
  # absent from the map (callers default to `nil`).
  @spec lookup_target_ids([String.t()], binary() | nil) :: %{String.t() => binary()}
  defp lookup_target_ids([], _workspace_id), do: %{}

  defp lookup_target_ids(paths, workspace_id) do
    WikiPage
    |> where([p], p.file_key in ^paths)
    |> filter_workspace(workspace_id)
    |> Repo.all()
    |> Map.new(fn p -> {p.file_key, p.id} end)
  end

  # Used inside `Repo.transaction/1` to either return the value or
  # short-circuit by rolling back with the changeset error.
  @spec unwrap_or_rollback({:ok, term()} | {:error, term()}) :: term()
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  # ── Frontmatter parser internals ──────────────────────────────────────

  # Detect a leading frontmatter block. The opening delimiter must be
  # exactly `---\n` at position 0. The closing delimiter is `\n---\n`
  # — the first occurrence after the opener — or `\n---` at end of
  # string. Anything else returns `:none`, which the caller maps to
  # `{%{}, body}`.
  @spec detect_frontmatter(String.t()) ::
          {:none, String.t()} | {:found, String.t(), String.t()}
  defp detect_frontmatter("---\n" <> rest) do
    case split_on_close(rest, "") do
      :no_close -> {:none, "---\n" <> rest}
      {:close, yaml_block, body_rest} -> {:found, yaml_block, body_rest}
    end
  end

  defp detect_frontmatter(body), do: {:none, body}

  # Walk `rest` looking for the first line whose entire contents is
  # `---`. The accumulator `acc` collects the YAML body up to (but
  # not including) the close delimiter.
  @spec split_on_close(String.t(), String.t()) ::
          :no_close | {:close, String.t(), String.t()}
  defp split_on_close(rest, acc) do
    case rest do
      "" ->
        :no_close

      "---\n" <> tail ->
        {:close, acc, tail}

      "---" ->
        # EOF immediately after a `---` line — accept it as a close.
        {:close, acc, ""}

      _ ->
        {line, tail} = take_line(rest)
        split_on_close(tail, acc <> line)
    end
  end

  # Take one line (including its trailing newline if present). When
  # `rest` has no newline left, return it entirely with an empty
  # remainder.
  @spec take_line(String.t()) :: {String.t(), String.t()}
  defp take_line(rest) do
    case :binary.split(rest, "\n") do
      [line, tail] -> {line <> "\n", tail}
      [line] -> {line, ""}
    end
  end

  # Yaml elixir already returns string-keyed maps; this step exists to
  # reject keys with control characters and to be defensive about
  # unexpected key types.
  @spec sanitize_frontmatter_keys(map()) :: map()
  defp sanitize_frontmatter_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) ->
        if String.match?(k, ~r/[[:cntrl:]]/u) do
          acc
        else
          Map.put(acc, k, v)
        end

      {k, v}, acc ->
        Map.put(acc, to_string(k), v)
    end)
  end

  # ── Wikilink parser internals ─────────────────────────────────────────

  # Replace fenced-code regions and inline-code spans with whitespace
  # of the same length so character positions remain stable but the
  # contents can't match `[[...]]`. We don't actually need positions
  # to be stable (we use ordinal indexes), but length-preserving
  # substitution keeps the implementation simple and predictable.
  @spec strip_code_regions(String.t()) :: String.t()
  defp strip_code_regions(body) do
    body
    |> strip_fenced_blocks()
    |> strip_inline_code()
  end

  # Match ``` ... ``` regions across multiple lines. The fence must
  # appear at the start of a line (after any whitespace). Replace
  # the entire region with spaces and newlines (preserve line breaks
  # to keep subsequent regex behavior unsurprising).
  @spec strip_fenced_blocks(String.t()) :: String.t()
  defp strip_fenced_blocks(body) do
    Regex.replace(~r/(?ms)^\s*```.*?^\s*```\s*$/, body, fn match ->
      blank_preserving_newlines(match)
    end)
  end

  # Match backtick-delimited inline code: `…` (no newline inside).
  @spec strip_inline_code(String.t()) :: String.t()
  defp strip_inline_code(body) do
    Regex.replace(~r/`[^`\n]*`/, body, fn match -> String.duplicate(" ", String.length(match)) end)
  end

  # Replace a multiline blob with spaces, preserving newlines so line
  # numbers in downstream tooling don't drift.
  @spec blank_preserving_newlines(String.t()) :: String.t()
  defp blank_preserving_newlines(blob) do
    blob
    |> String.graphemes()
    |> Enum.map_join(fn
      "\n" -> "\n"
      _ -> " "
    end)
  end

  # Find every `[[...]]` token in `body`. Returns the raw inner text
  # of each token (between the brackets), in order of appearance.
  # Tokens whose inner text contains a newline are rejected.
  @spec extract_wikilink_tokens(String.t()) :: [String.t()]
  defp extract_wikilink_tokens(body) do
    ~r/\[\[([^\]\n]*)\]\]/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  end

  # Convert one raw inner token into `[{target, display}]` (list of
  # zero or one element so callers can `flat_map`). Skipped tokens
  # (empty target, etc.) produce `[]` and DO NOT advance the
  # position counter — `position` is the 0-indexed ordinal of the
  # retained wikilinks, not of all `[[...]]` tokens.
  @spec parse_link_token_to_partial(String.t()) :: [{String.t(), String.t() | nil}]
  defp parse_link_token_to_partial(token) do
    case parse_link_token(token) do
      :skip -> []
      {target, display} -> [{target, display}]
    end
  end

  @spec parse_link_token(String.t()) :: :skip | {String.t(), String.t() | nil}
  defp parse_link_token(token) do
    case :binary.split(token, "|") do
      [target] ->
        case sanitize_target(target) do
          :skip -> :skip
          clean -> {clean, nil}
        end

      [target, display_rest] ->
        case sanitize_target(target) do
          :skip ->
            :skip

          clean ->
            display = sanitize_display(display_rest)
            {clean, display}
        end
    end
  end

  @spec sanitize_target(String.t()) :: :skip | String.t()
  defp sanitize_target(target) do
    trimmed = String.trim(target)

    cond do
      trimmed == "" -> :skip
      String.contains?(trimmed, "\n") -> :skip
      true -> trimmed
    end
  end

  @spec sanitize_display(String.t()) :: String.t() | nil
  defp sanitize_display(display) do
    trimmed = String.trim(display)
    if trimmed == "", do: nil, else: trimmed
  end
end
