defmodule Platform.Org.Wiki.Journal do
  @moduledoc """
  Append-only journal entries for the org wiki (ADR-0041).

  Each entry is a short-lived note tied to a date and an optional
  namespace. Reads project entries up to a virtual page at
  `{namespace}/journal/YYYY-MM-DD.md` — there is no row in
  `org_wiki_pages` for journal days; the projection happens in
  `virtual_page_for/2`.

  ## Public surface (stable as of T2)

    * `append/2`           — insert one entry, emit `:wiki_journal_appended`
    * `get_for_date/2`     — entries for `(workspace, namespace, date)`
    * `list_recent/1`      — recent entries, configurable window
    * `virtual_page_for/2` — read-as-page projection of a day's entries
    * `parse_virtual_path/1` — pure helper: file_key → `{ns, date}`

  ## PubSub

  Emits on the same topic as `Platform.Org.Wiki`
  (`#{inspect("org_wiki:index")}`) so the T3 indexer subscribes once
  and routes by message tag:

      {:wiki_journal_appended, %{entry_id, date, workspace_id, namespace}}

  ## Namespace storage

  The schema (`Platform.Org.WikiJournalEntry`) has no dedicated
  namespace column, so we write the namespace into the entry's
  `metadata["namespace"]` jsonb field on every append. Queries that
  scope by namespace add a `metadata->>'namespace' = $namespace`
  filter. The default namespace is `"org"`, written explicitly so
  every entry is namespace-tagged.

  ## Scope (T2)

  Journal domain logic only. No memory-service calls, no embedding
  triggers, no GenServers. Historian / cursors are T6. Multi-day
  rollups (`ORG_NOTES-YYYY-MM-DD` 2-day windows from V1) are NOT this
  module's responsibility — those belong to `Platform.Org.Wiki.Context`
  in T4.
  """

  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 2]

  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo

  @index_topic "org_wiki:index"

  @default_namespace "org"

  @default_days_back 7
  @default_limit 50

  @virtual_path_regex ~r"^(?<namespace>[^/]+(?:/[^/]+)*)/journal/(?<date>\d{4}-\d{2}-\d{2})\.md$"

  @typedoc """
  Attributes accepted by `append/2`. `:content` and `:date` are
  required; `:workspace_id`, `:authored_by`, `:metadata` are optional.
  Namespace is passed via opts (not attrs) so it is uniformly treated
  as a routing dimension, not a payload field.
  """
  @type entry_attrs :: %{
          required(:content) => String.t(),
          required(:date) => Date.t(),
          optional(:workspace_id) => binary() | nil,
          optional(:authored_by) => binary() | nil,
          optional(:metadata) => map()
        }

  @typedoc """
  Virtual-page projection. Not a `WikiPage` struct — the journal day
  has no row in `org_wiki_pages`; this is a read-time aggregation.
  """
  @type virtual_page :: %{
          file_key: String.t(),
          content: String.t(),
          date: Date.t(),
          workspace_id: binary() | nil,
          namespace: String.t(),
          entry_ids: [binary()]
        }

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Append a journal entry.

  ## Options

    * `:namespace` — routing namespace (default `"org"`). Merged into
      `metadata["namespace"]` so reads can filter on it without a
      dedicated column.
  """
  @spec append(entry_attrs(), keyword()) ::
          {:ok, WikiJournalEntry.t()} | {:error, Ecto.Changeset.t()}
  def append(attrs, opts \\ []) when is_map(attrs) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)

    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Kernel.||(%{})
      |> Map.put("namespace", namespace)

    insert_attrs =
      attrs
      |> Map.put(:metadata, metadata)

    result =
      %WikiJournalEntry{}
      |> WikiJournalEntry.changeset(insert_attrs)
      |> Repo.insert()

    case result do
      {:ok, %WikiJournalEntry{} = entry} ->
        :telemetry.execute(
          [:platform, :org, :wiki_journal_appended],
          %{system_time: System.system_time()},
          %{
            entry_id: entry.id,
            date: entry.date,
            workspace_id: entry.workspace_id,
            namespace: namespace
          }
        )

        broadcast_index_event(:wiki_journal_appended, %{
          entry_id: entry.id,
          date: entry.date,
          workspace_id: entry.workspace_id,
          namespace: namespace
        })

        {:ok, entry}

      {:error, _changeset} = err ->
        err
    end
  end

  @doc """
  All entries for the given `date`, ordered `inserted_at asc`.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:namespace` (default `"org"`)
  """
  @spec get_for_date(Date.t(), keyword()) :: [WikiJournalEntry.t()]
  def get_for_date(%Date{} = date, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)

    WikiJournalEntry
    |> where([e], e.date == ^date)
    |> filter_workspace(workspace_id)
    |> filter_namespace(namespace)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> Repo.all()
  end

  @doc """
  Recent journal entries, newest first.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:namespace` (default `"org"`)
    * `:days_back` (default 7)
    * `:limit` (default 50)
  """
  @spec list_recent(keyword()) :: [WikiJournalEntry.t()]
  def list_recent(opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)
    days_back = Keyword.get(opts, :days_back, @default_days_back)
    lim = Keyword.get(opts, :limit, @default_limit)

    date_from = Date.add(Date.utc_today(), -days_back)

    WikiJournalEntry
    |> where([e], e.date >= ^date_from)
    |> filter_workspace(workspace_id)
    |> filter_namespace(namespace)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^lim)
    |> Repo.all()
  end

  @doc """
  Project a day's journal entries as a virtual page.

  Returns a map shaped per `t:virtual_page/0`. Content is the
  concatenation of every entry for `(workspace, namespace, date)`,
  joined by `\\n\\n---\\n\\n`, in `inserted_at asc` order. Empty
  string when no entries exist.

  ## Options
    * `:workspace_id` (default `nil`)
    * `:namespace` (default `"org"`)
  """
  @spec virtual_page_for(Date.t(), keyword()) :: virtual_page()
  def virtual_page_for(%Date{} = date, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)

    entries = get_for_date(date, workspace_id: workspace_id, namespace: namespace)

    content =
      entries
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n---\n\n")

    %{
      file_key: virtual_file_key(namespace, date),
      content: content,
      date: date,
      workspace_id: workspace_id,
      namespace: namespace,
      entry_ids: Enum.map(entries, & &1.id)
    }
  end

  @doc """
  Parse a virtual journal path back into its components.

  Matches `^(?<namespace>[^/]+(?:/[^/]+)*)/journal/(?<date>\\d{4}-\\d{2}-\\d{2})\\.md$`.

  Returns `{:ok, %{namespace, date}}` or `:error`. Multi-segment
  namespaces like `project/abc` are accepted because the project
  namespace dimension is itself path-like.
  """
  @spec parse_virtual_path(String.t()) ::
          {:ok, %{namespace: String.t(), date: Date.t()}} | :error
  def parse_virtual_path(file_key) when is_binary(file_key) do
    case Regex.named_captures(@virtual_path_regex, file_key) do
      %{"namespace" => ns, "date" => date_str} ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> {:ok, %{namespace: ns, date: date}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_virtual_path(_), do: :error

  # ── Internals ─────────────────────────────────────────────────────────

  @doc false
  @spec index_topic() :: String.t()
  def index_topic, do: @index_topic

  @doc false
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  # Construct the canonical virtual file key for a journal day.
  @doc false
  @spec virtual_file_key(String.t(), Date.t()) :: String.t()
  def virtual_file_key(namespace, %Date{} = date) do
    "#{namespace}/journal/#{Date.to_iso8601(date)}.md"
  end

  defp filter_workspace(queryable, nil) do
    where(queryable, [e], is_nil(e.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [e], e.workspace_id == ^workspace_id)
  end

  # Filter by metadata->>'namespace' = $namespace.
  defp filter_namespace(queryable, namespace) when is_binary(namespace) do
    from(e in queryable, where: fragment("? ->> 'namespace'", e.metadata) == ^namespace)
  end

  @spec broadcast_index_event(atom(), map()) :: :ok | {:error, term()}
  defp broadcast_index_event(event, payload)
       when is_atom(event) and is_map(payload) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @index_topic, {event, payload})
  end
end
