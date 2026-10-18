defmodule Platform.Org.Context do
  @moduledoc """
  Business logic for org-level context files and memory entries.

  Provides CRUD for versioned context files (`org/identity.md`, etc.),
  append-only short-term memory entries, and a `build_context/1` function
  that assembles workspace files and the last 2 days of memory entries into
  a map suitable for injection into agent sessions.

  Curated long-term knowledge lives in `org/memory.md` (a context file),
  not in memory entries.

  ## V1 alias-compat

  Legacy uppercase keys (`ORG_IDENTITY.md`, `ORG_MEMORY.md`, `ORG_AGENTS.md`)
  continue to resolve transparently via the `org_wiki_aliases` table that
  is backfilled by migration `20260519210000`. `get_context_file/2` and
  `upsert_context_file/3` both fall back through the alias table when a
  direct lookup misses, so V1 federation tools (`org_context_*`) keep
  working until T5 retires them.

  ## Quick reference

      Platform.Org.Context.list_files()
      Platform.Org.Context.get_file("org/identity.md")
      Platform.Org.Context.upsert_file(%{file_key: "org/identity.md", content: "# Our Org", updated_by: user_id})
      Platform.Org.Context.delete_file("custom/file.md")
  """

  import Ecto.Query
  require Logger

  alias Platform.Memory
  alias Platform.Memory.Insights
  alias Platform.MemoryFeedback
  alias Platform.Org.Wiki
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Default templates ─────────────────────────────────────────────────

  # Template keys follow the T5 routing page grammar (`<ns>/page/<rest>`)
  # so seeded defaults are recognised by the memory_* gates — flat keys
  # (`org/identity.md`) classify :unknown and get dropped by
  # memory_search's read-gate hydration. Keys migrated from the flat
  # form by 20260611120000_page_grammar_file_keys_and_alias_backfill
  # (Sloane-authorized change, 2026-06-11).
  @default_templates %{
    "org/page/identity.md" => """
    # Organization Identity

    ## Mission
    _What is your organization's mission?_

    ## Values
    _What principles guide your team?_

    ## Product Summary
    _Brief description of what you're building._

    ## Team
    _Who are the key people and what are their roles?_
    """,
    "org/page/memory.md" => """
    # Organization Memory

    Long-term curated knowledge for the organization. Agents reference this
    for persistent context about decisions, patterns, and institutional knowledge.

    ## Key Decisions
    _Record important decisions and their rationale here._

    ## Patterns & Conventions
    _Document recurring patterns, naming conventions, and standards._

    ## Lessons Learned
    _Capture insights from past experiences._
    """,
    "org/page/agents.md" => """
    # Organization Agents

    Registry of agents and their roles within the organization.

    ## Active Agents

    | Agent | Role | Capabilities |
    |-------|------|-------------|
    | _agent-name_ | _role_ | _what it does_ |

    ## Agent Guidelines
    _Shared guidelines for how agents should behave._
    """
  }

  @doc "Returns the default template content for a given file key, or nil."
  def default_template(file_key), do: Map.get(@default_templates, file_key)

  @doc "Returns the map of all default templates."
  def default_templates, do: @default_templates

  # ── Context files ────────────────────────────────────────────────────

  @doc """
  Fetch a single context file by file_key, optionally scoped to a workspace.

  Falls back through `org_wiki_aliases` when the direct lookup misses so
  legacy V1 keys (`ORG_IDENTITY.md`, …) keep resolving after T1 migrated
  pages to path-style keys.
  """
  @spec get_context_file(String.t(), binary() | nil) :: WikiPage.t() | nil
  def get_context_file(file_key, workspace_id \\ nil) do
    direct =
      WikiPage
      |> where([f], f.file_key == ^file_key)
      |> filter_workspace(workspace_id)
      |> Repo.one()

    case direct do
      nil -> resolve_via_alias(file_key, workspace_id)
      page -> page
    end
  end

  # Sentinel used in `org_wiki_aliases.workspace_id` for org-scoped rows
  # (no workspace). The migration that introduces the composite PK
  # (`20260519220000_add_workspace_id_to_org_wiki_aliases.exs`) explains
  # why a sentinel is required — Postgres can't keep NULL in a PK column.
  @alias_nil_sentinel "00000000-0000-0000-0000-000000000000"

  # Look up `file_key` in `org_wiki_aliases` and return the page it points
  # at. Aliases are now per-workspace via composite PK
  # `(workspace_id, old_path)`, so we filter the alias row itself by the
  # caller's workspace. Org-scoped lookups (workspace_id == nil) match
  # the sentinel UUID. The join still filters the page row to keep
  # multi-tenant boundaries belt-and-suspenders tight.
  #
  # `org_wiki_aliases` has no Ecto schema (the migration is raw SQL), so
  # the query needs an explicit `type(..., :binary_id)` cast on the
  # workspace_id pin — without it Postgrex sees a 36-char string and
  # rejects it for a `uuid` column.
  @spec resolve_via_alias(String.t(), binary() | nil) :: WikiPage.t() | nil
  defp resolve_via_alias(file_key, nil) do
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

  defp resolve_via_alias(file_key, workspace_id) do
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

  @doc "Gets a single org context file by file_key. Alias for `get_context_file/2`."
  def get_file(file_key, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    get_context_file(file_key, workspace_id)
  end

  @doc "Gets a single org context file by ID."
  def get_file_by_id(id) do
    # Reachable from the memory MCP tools with a caller-supplied page id.
    if Platform.UUID.valid?(id), do: Repo.get(WikiPage, id), else: nil
  end

  @doc """
  List all context files, optionally scoped to a workspace.

  ## Options

    * `:workspace_id` - scope to a specific workspace (default: nil)
  """
  @spec list_context_files(keyword()) :: [WikiPage.t()]
  def list_context_files(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    WikiPage
    |> filter_workspace(workspace_id)
    |> order_by([f], asc: f.file_key)
    |> Repo.all()
  end

  @doc "Lists all org context files, ordered by file_key. Alias for `list_context_files/1`."
  def list_files(opts \\ []), do: list_context_files(opts)

  @doc """
  Create or update a context file with optimistic locking.

  New files start at version 1. Existing files increment their version on
  each successful write. When `:expected_version` is supplied, a mismatch
  returns `{:error, :stale}`.
  """
  @spec upsert_context_file(String.t(), map(), keyword()) ::
          {:ok, WikiPage.t()} | {:error, Ecto.Changeset.t() | :stale | :product_owned}
  def upsert_context_file(file_key, attrs, opts \\ []) do
    case check_product_owned(file_key, opts) do
      :ok -> do_upsert_context_file(file_key, attrs, opts)
      {:error, _} = err -> err
    end
  end

  defp do_upsert_context_file(file_key, attrs, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    expected_version = Keyword.get(opts, :expected_version)

    Repo.transaction(fn ->
      direct =
        WikiPage
        |> where([f], f.file_key == ^file_key)
        |> filter_workspace(workspace_id)
        |> Repo.one()

      # If the caller passed a legacy V1 key (ORG_IDENTITY.md, …) and no
      # direct row exists, resolve through the alias table so the write
      # lands on the canonical path-style row instead of creating a
      # duplicate. The page row keeps its current file_key — we don't
      # rewrite it on the caller's behalf.
      existing = direct || resolve_via_alias(file_key, workspace_id)

      case existing do
        nil ->
          %WikiPage{}
          |> WikiPage.changeset(
            Map.merge(attrs, %{file_key: file_key, workspace_id: workspace_id})
          )
          |> Repo.insert()
          |> unwrap_or_rollback()

        %WikiPage{} = file ->
          cond do
            # An alias can resolve a non-product key onto a product row.
            check_product_owned(file.file_key, opts) != :ok ->
              Repo.rollback(:product_owned)

            not is_nil(expected_version) and file.version != expected_version ->
              Repo.rollback(:stale)

            true ->
              new_content = Map.get(attrs, :content, Map.get(attrs, "content"))
              editor_id = Map.get(attrs, :updated_by, Map.get(attrs, "updated_by"))

              updated =
                file
                |> WikiPage.changeset(%{
                  content: new_content,
                  updated_by: editor_id,
                  version: file.version + 1
                })
                |> Repo.update()
                |> unwrap_or_rollback()

              # Capture the edit signal *inside* the same transaction: if
              # the feedback insert fails we roll the file update back too.
              # That way a mutation and its training-corpus row land (or
              # don't) atomically — no silent mutations, no orphan rows.
              feedback_attrs = %{
                original_content: file.content,
                edited_content: new_content,
                original_author_id: file.updated_by,
                editor_id: editor_id,
                path: file_key,
                namespace: "org_context",
                workspace_id: workspace_id,
                reason_text: Keyword.get(opts, :reason)
              }

              case MemoryFeedback.record_edit(feedback_attrs) do
                {:ok, _entry} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end
      end
    end)
    |> tap_ok(fn file ->
      :telemetry.execute(
        [:platform, :org, :context_file_written],
        %{system_time: System.system_time()},
        %{file_key: file.file_key, version: file.version, workspace_id: file.workspace_id}
      )

      maybe_sweep_journal_for_insights(file)
    end)
    |> normalize_transaction_result()
  end

  # Post-write sweep hook: parse the just-persisted content for
  # `<synthesis-insight>` blocks and ingest them via
  # `Platform.Memory.Insights` (task 01a13867 stage 1; `<synthesis-proposal>`
  # blocks are no longer ingested). Runs OUTSIDE the write transaction so a
  # parser bug or DB constraint failure on the insights side can't roll
  # a journal write back — the journal is the source of truth, insights
  # are a derived surface.
  #
  # Only fires for journal file_keys per the sweep-hook regex; page
  # writes flow through the same upsert path but shouldn't be swept.
  defp maybe_sweep_journal_for_insights(%WikiPage{file_key: file_key} = file) do
    if Insights.journal_path?(file_key) do
      case Insights.ingest_from_journal(file.workspace_id, file.file_key, file.content) do
        {:ok, count} when count > 0 ->
          Logger.debug(
            "[memory.insights] ingested #{count} block(s) from #{file.file_key} " <>
              "(workspace_id=#{inspect(file.workspace_id)})"
          )

          :ok

        {:ok, 0} ->
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      # A crash in the sweep hook must never surface as a write failure
      # — the journal is already durably in Postgres. Log and move on.
      Logger.error(
        "[memory.insights] sweep hook crashed for #{file.file_key}: #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Creates or updates an org context file (simple interface).
  On update, the version is incremented.
  """
  def upsert_file(attrs, opts \\ []) do
    file_key = Map.get(attrs, :file_key) || Map.get(attrs, "file_key")
    content = Map.get(attrs, :content) || Map.get(attrs, "content")
    updated_by = Map.get(attrs, :updated_by) || Map.get(attrs, "updated_by")

    upsert_context_file(file_key, %{content: content, updated_by: updated_by}, opts)
  end

  @doc """
  Deletes a context file and captures a `feedback_kind: "delete"` row.

  ## Options

    * `:editor_id` - UUID of the user or agent performing the delete
      (surfaces in the feedback row's `editor_id` column). Defaults to
      `nil` if omitted.
    * `:reason` - optional human-supplied justification, stored on the
      feedback row's `reason_text` column.

  The delete + capture run in a single `Repo.transaction`: a failure on
  the feedback insert rolls the file delete back too. Returns
  `{:ok, file}` on success, `{:error, :not_found}` if the file didn't
  exist, or `{:error, changeset}` if the feedback insert failed.
  """
  def delete_file(file_key, opts \\ []) do
    case check_product_owned(file_key, opts) do
      :ok -> do_delete_file(file_key, opts)
      {:error, _} = err -> err
    end
  end

  defp do_delete_file(file_key, opts) do
    editor_id = Keyword.get(opts, :editor_id)
    reason = Keyword.get(opts, :reason)

    Repo.transaction(fn ->
      case get_file(file_key) do
        nil ->
          Repo.rollback(:not_found)

        %WikiPage{file_key: resolved_key} = file ->
          if check_product_owned(resolved_key, opts) != :ok,
            do: Repo.rollback(:product_owned)

          feedback_attrs = %{
            original_content: file.content,
            path: file_key,
            namespace: "org_context",
            workspace_id: file.workspace_id,
            original_author_id: file.updated_by,
            editor_id: editor_id,
            reason_text: reason
          }

          # Capture BEFORE the delete so the pre-mutation row is still
          # queryable if the delete itself fails and we roll back. The
          # transaction guarantees no orphan feedback rows either way.
          with {:ok, _entry} <- MemoryFeedback.record_delete(feedback_attrs),
               {:ok, deleted} <- Repo.delete(file) do
            deleted
          else
            {:error, changeset_or_reason} -> Repo.rollback(changeset_or_reason)
          end
      end
    end)
    |> tap_ok(fn deleted ->
      # Mirror `Wiki.delete_page/2`'s index event so the T3 indexer
      # cleans up the vector-store entry for user-initiated deletes
      # routed through this path (e.g. the org-memory LiveView).
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        "org_wiki:index",
        {:wiki_page_deleted,
         %{
           page_id: deleted.id,
           file_key: deleted.file_key,
           workspace_id: deleted.workspace_id
         }}
      )
    end)
    |> normalize_transaction_result()
  end

  @doc """
  Seeds default org context files if they don't already exist.
  Typically called during application startup or from a migration seed.
  """
  def seed_defaults(opts \\ []) do
    updated_by = Keyword.get(opts, :updated_by)

    Enum.each(@default_templates, fn {file_key, template} ->
      case get_file(file_key) do
        nil ->
          %WikiPage{}
          |> WikiPage.changeset(%{
            file_key: file_key,
            content: template,
            updated_by: updated_by
          })
          |> Repo.insert!()

        _exists ->
          :ok
      end
    end)
  end

  # ── Memory entries ───────────────────────────────────────────────────

  @doc """
  Append a memory entry.

  Attrs should include `:content`, `:date`, and optionally `:workspace_id`,
  `:authored_by`, `:metadata`.
  """
  @spec append_memory_entry(map(), keyword()) ::
          {:ok, WikiJournalEntry.t()} | {:error, Ecto.Changeset.t()}
  def append_memory_entry(attrs, opts \\ []) do
    attrs = maybe_put_workspace(attrs, Keyword.get(opts, :workspace_id))

    result =
      %WikiJournalEntry{}
      |> WikiJournalEntry.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        :telemetry.execute(
          [:platform, :org, :memory_entry_written],
          %{system_time: System.system_time()},
          %{
            memory_entry_id: entry.id,
            date: entry.date,
            workspace_id: entry.workspace_id
          }
        )

        # Fire-and-forget: embed + index via memory-service if configured.
        # Entry is already durably in Postgres; failures are logged and can
        # be backfilled later via the /sync endpoint.
        Memory.ingest_async([entry])

        {:ok, entry}

      error ->
        error
    end
  end

  @doc "Appends a new memory entry. Alias for `append_memory_entry/2`."
  def append_memory(attrs), do: append_memory_entry(attrs)

  @doc """
  Search memory entries with optional filters.

  When `:query` is provided and a memory-service provider is configured
  (see `Platform.Memory`), results are ranked by semantic similarity via
  vector search. Without `:query` — or when memory-service is unreachable
  — this falls back to plain SQL filters ordered by `inserted_at desc`.

  ## Options

    * `:query` - natural-language query for semantic retrieval (falls back
      to case-insensitive substring match if memory-service is unavailable)
    * `:date_from` - include entries on/after this date
    * `:date_to` - include entries on/before this date
    * `:workspace_id` - legacy workspace scope (kept for back-compat)
    * `:org_id` - ADR-0042 tenant filter (scopes to a single org)
    * `:project_id` - ADR-0042 project filter (scopes to a single project)
    * `:limit` - max results (default: 50)
  """
  @spec search_memory_entries(keyword()) :: [WikiJournalEntry.t()]
  def search_memory_entries(opts \\ []) do
    query = Keyword.get(opts, :query)

    if is_binary(query) and query != "" and Memory.enabled?() do
      vector_search_memory_entries(query, opts) || sql_search_memory_entries(opts)
    else
      sql_search_memory_entries(opts)
    end
  end

  @doc """
  Vector-search variant that returns `[{entry, score}]` for callers that
  need the similarity score alongside the entry (e.g. the `memory_search`
  tool). Returns `nil` when memory-service is unavailable so callers can
  decide whether to fall back.
  """
  @spec search_memory_with_scores(String.t(), keyword()) ::
          [{WikiJournalEntry.t(), float()}] | nil
  def search_memory_with_scores(query, opts \\ []) when is_binary(query) do
    with true <- Memory.enabled?(),
         {:ok, hits} <- Memory.search(query, memory_search_opts(opts)) do
      entries_by_id =
        hits
        |> Enum.map(& &1.entry_id)
        |> fetch_entries_by_ids(Keyword.get(opts, :workspace_id))
        |> Map.new(fn entry -> {entry.id, entry} end)

      hits
      |> Enum.flat_map(fn %{entry_id: id, score: score} ->
        case Map.get(entries_by_id, id) do
          nil -> []
          entry -> [{entry, score}]
        end
      end)
    else
      false ->
        nil

      {:error, reason} ->
        Logger.warning("Platform.Memory.search failed: #{inspect(reason)}")
        nil
    end
  end

  defp vector_search_memory_entries(query, opts) do
    case search_memory_with_scores(query, opts) do
      nil -> nil
      results -> Enum.map(results, fn {entry, _score} -> entry end)
    end
  end

  defp sql_search_memory_entries(opts) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)

    WikiJournalEntry
    |> filter_workspace(workspace_id)
    |> scope_org(Keyword.get(opts, :org_id))
    |> filter_project(Keyword.get(opts, :project_id))
    |> maybe_filter_date_from(Keyword.get(opts, :date_from))
    |> maybe_filter_date_to(Keyword.get(opts, :date_to))
    |> maybe_filter_query(Keyword.get(opts, :query))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_entries_by_ids([], _workspace_id), do: []

  defp fetch_entries_by_ids(ids, workspace_id) do
    WikiJournalEntry
    |> where([m], m.id in ^ids)
    |> filter_workspace(workspace_id)
    |> Repo.all()
  end

  defp memory_search_opts(opts) do
    opts
    |> Keyword.take([:workspace_id, :date_from, :date_to, :limit])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Searches org memory entries. Alias for `search_memory_entries/1`."
  def search_memory(opts \\ []), do: search_memory_entries(opts)

  @doc "Returns recent memory entries grouped by date (last N days)."
  def recent_memory(days \\ 7, opts \\ []) do
    date_from = Date.add(Date.utc_today(), -days)

    search_memory_entries(Keyword.merge(opts, date_from: date_from))
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
  end

  @doc "Fetches memory entries by a list of IDs."
  @spec get_memory_entries_by_ids([binary()]) :: [WikiJournalEntry.t()]
  def get_memory_entries_by_ids([]), do: []

  def get_memory_entries_by_ids(ids) do
    WikiJournalEntry
    |> where([m], m.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Resolve `authored_by` ids on a list of memory entries (or the grouped
  `[{date, [entries]}]` form returned by `recent_memory/2`) to a lookup map:

      %{author_id => %{kind: :agent | :user, name: String.t(), color: String.t() | nil}}

  Unknown ids are omitted — callers should fall back to displaying the raw id.
  """
  @spec resolve_authors([WikiJournalEntry.t()] | [{Date.t(), [WikiJournalEntry.t()]}]) ::
          %{binary() => %{kind: :agent | :user, name: String.t(), color: String.t() | nil}}
  def resolve_authors(entries) when is_list(entries) do
    ids = entries |> Enum.flat_map(&extract_author_ids/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      agents =
        from(a in Platform.Agents.Agent, where: a.id in ^ids)
        |> Repo.all()
        |> Map.new(fn agent ->
          {agent.id, %{kind: :agent, name: agent.name, color: agent.color}}
        end)

      remaining = Enum.reject(ids, &Map.has_key?(agents, &1))

      # Historical attribution: memory entries authored by an archived user
      # must still resolve to that user's display name. Overrides the
      # `include_archived: false` default flipped in Stage 1 of the archival
      # rollout (`Accounts.get_users_map/1`).
      users =
        remaining
        |> Platform.Accounts.get_users_map(include_archived: true)
        |> Map.new(fn {id, user} ->
          {id, %{kind: :user, name: user_name(user), color: nil}}
        end)

      Map.merge(agents, users)
    end
  end

  defp extract_author_ids(%WikiJournalEntry{authored_by: nil}), do: []
  defp extract_author_ids(%WikiJournalEntry{authored_by: id}), do: [id]
  defp extract_author_ids({_date, entries}), do: Enum.flat_map(entries, &extract_author_ids/1)
  defp extract_author_ids(_), do: []

  defp user_name(user) do
    case user do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  # ── Build context ────────────────────────────────────────────────────

  @doc """
  Assemble org context for injection into an agent session.

  Returns a map of filename => content, including workspace context files
  and the last 2 days of memory entries as `ORG_NOTES-YYYY-MM-DD`.

  ## Options

    * `:workspace_id` - scope to a workspace (default: nil)
  """
  @spec build_context(keyword()) :: %{String.t() => String.t()}
  def build_context(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    files =
      list_context_files(workspace_id: workspace_id)
      |> Map.new(fn f -> {f.file_key, f.content} end)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    daily_entries =
      search_memory_entries(
        workspace_id: workspace_id,
        date_from: yesterday,
        date_to: today,
        limit: 1000
      )

    notes =
      daily_entries
      |> Enum.group_by(& &1.date)
      |> Enum.into(%{}, fn {date, entries} ->
        content =
          entries
          |> Enum.sort_by(& &1.inserted_at, DateTime)
          |> Enum.map_join("\n", & &1.content)

        {"ORG_NOTES-#{Date.to_iso8601(date)}", content}
      end)

    Map.merge(files, notes)
  end

  # ── Private helpers ──────────────────────────────────────────────────

  # Domain backstop for the product-owned `burrow/` namespace (task 01a10a44
  # stage 2). Same rule as `Platform.Org.Wiki`: refused with
  # `{:error, :product_owned}` unless the caller passes the `:product_docs`
  # opt set to `true`, which only `Platform.Org.BurrowDocs` does.
  defp check_product_owned(file_key, opts) do
    if Keyword.get(opts, :product_docs) == true or not Wiki.product_owned_key?(file_key),
      do: :ok,
      else: {:error, :product_owned}
  end

  defp filter_workspace(queryable, nil) do
    where(queryable, [r], is_nil(r.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [r], r.workspace_id == ^workspace_id)
  end

  # ADR-0042: additive org filter, mapped onto the shared choke point
  # `Tenancy.scope/3`. A list value is an `IN` clause so tenant agents can
  # scope to their own + inherited-root content without leaking siblings.
  #
  # `nil` and `[]` are NOT the same question:
  #
  #   * `nil` is the ABSENCE of a question — the legacy workspace-only
  #     call path did not ask to filter by org, so we do not filter.
  #   * `[]` is a RESOLVED answer meaning "no orgs", so it maps to
  #     `:none` and matches nothing. It used to return the queryable
  #     untouched. A fail-open default is wrong regardless of how wide
  #     the intended audience is, because a deliberate wide audience and
  #     an accidental one are different things and only the first is a
  #     decision.
  defp scope_org(queryable, nil), do: queryable

  defp scope_org(queryable, org_id) when is_binary(org_id) do
    Tenancy.scope(queryable, {:orgs, [org_id]})
  end

  defp scope_org(queryable, org_ids) when is_list(org_ids) do
    Tenancy.scope(queryable, {:orgs, Enum.filter(org_ids, &is_binary/1)})
  end

  defp filter_project(queryable, nil), do: queryable

  defp filter_project(queryable, project_id) when is_binary(project_id) do
    where(queryable, [r], r.project_id == ^project_id)
  end

  defp maybe_filter_date_from(query, nil), do: query
  defp maybe_filter_date_from(query, %Date{} = d), do: where(query, [m], m.date >= ^d)

  defp maybe_filter_date_from(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_from(query, date)
      _ -> query
    end
  end

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, %Date{} = d), do: where(query, [m], m.date <= ^d)

  defp maybe_filter_date_to(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_to(query, date)
      _ -> query
    end
  end

  defp maybe_filter_query(queryable, nil), do: queryable
  defp maybe_filter_query(queryable, ""), do: queryable

  defp maybe_filter_query(queryable, query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      queryable
    else
      pattern = "%#{trimmed}%"
      where(queryable, [m], ilike(m.content, ^pattern))
    end
  end

  defp maybe_put_workspace(attrs, nil), do: attrs

  defp maybe_put_workspace(attrs, workspace_id) when is_map(attrs) do
    Map.put(attrs, :workspace_id, workspace_id)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp tap_ok({:ok, value}, fun) do
    fun.(value)
    {:ok, value}
  end

  defp tap_ok(error, _fun), do: error

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
