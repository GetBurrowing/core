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

  ## Scope (T2)

  Journal domain logic only. No memory-service calls, no embedding
  triggers, no GenServers. Historian / cursors are T6. Multi-day
  rollups (`ORG_NOTES-YYYY-MM-DD` 2-day windows from V1) are NOT this
  module's responsibility — those belong to `Platform.Org.Wiki.Context`
  in T4.
  """

  @index_topic "org_wiki:index"

  @default_namespace "org"

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

    * `:namespace` — routing namespace (default `"org"`). Stored in
      `metadata["namespace"]` since the schema has no dedicated column.
  """
  @spec append(entry_attrs(), keyword()) ::
          {:ok, Platform.Org.WikiJournalEntry.t()}
          | {:error, Ecto.Changeset.t() | :not_implemented}
  def append(_attrs, _opts \\ []), do: not_implemented()

  @doc """
  All entries for the given date, ordered `inserted_at asc`.

  ## Options
    * `:workspace_id`
    * `:namespace` (default `"org"`)
  """
  @spec get_for_date(Date.t(), keyword()) :: [Platform.Org.WikiJournalEntry.t()]
  def get_for_date(_date, _opts \\ []), do: not_implemented_list()

  @doc """
  Recent journal entries, newest first.

  ## Options
    * `:workspace_id`
    * `:namespace` (default `"org"`)
    * `:days_back` (default 7)
    * `:limit` (default 50)
  """
  @spec list_recent(keyword()) :: [Platform.Org.WikiJournalEntry.t()]
  def list_recent(_opts \\ []), do: not_implemented_list()

  @doc """
  Project a day's journal entries as a virtual page.

  Returns a map shaped per `t:virtual_page/0`. Content is the
  concatenation of every entry for `(workspace, namespace, date)`,
  joined by `\\n\\n---\\n\\n`, in `inserted_at asc` order. Empty
  string when no entries exist.

  ## Options
    * `:workspace_id`
    * `:namespace` (default `"org"`)
  """
  @spec virtual_page_for(Date.t(), keyword()) :: virtual_page()
  def virtual_page_for(date, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)

    %{
      file_key: virtual_file_key(namespace, date),
      content: "",
      date: date,
      workspace_id: workspace_id,
      namespace: namespace,
      entry_ids: []
    }
  end

  @doc """
  Parse a virtual journal path back into its components.

  Matches `^(?<ns>[^/]+)/journal/(?<date>\\d{4}-\\d{2}-\\d{2})\\.md$`.
  Returns `{:ok, %{namespace, date}}` or `:error`.
  """
  @spec parse_virtual_path(String.t()) ::
          {:ok, %{namespace: String.t(), date: Date.t()}} | :error
  def parse_virtual_path(_file_key), do: :error

  # ── Internals ─────────────────────────────────────────────────────────

  @doc false
  @spec index_topic() :: String.t()
  def index_topic, do: @index_topic

  @doc false
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  # Construct the canonical virtual file key for a journal day. Kept
  # public-doc-but-not-promised (`@doc false`) so Stage 4 can reuse it
  # without locking in a third public surface.
  @doc false
  @spec virtual_file_key(String.t(), Date.t()) :: String.t()
  def virtual_file_key(namespace, %Date{} = date) do
    "#{namespace}/journal/#{Date.to_iso8601(date)}.md"
  end

  # Stage-4 broadcast helper. Private until Stage 4 calls it.
  @spec broadcast_index_event(atom(), map()) :: :ok | {:error, term()}
  defp broadcast_index_event(event, payload)
       when is_atom(event) and is_map(payload) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @index_topic, {event, payload})
  end

  @doc false
  def __broadcast_index_event__(event, payload),
    do: broadcast_index_event(event, payload)

  @spec not_implemented() :: {:error, :not_implemented}
  defp not_implemented, do: {:error, :not_implemented}

  @spec not_implemented_list() :: []
  defp not_implemented_list, do: []
end
