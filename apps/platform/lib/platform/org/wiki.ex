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

  ## PubSub

  Index events are broadcast on topic `"org_wiki:index"` so T3's indexer
  can subscribe and translate them into embedding/search calls. T2 emits;
  T2 never indexes.

      {:wiki_page_written, %{page_id, file_key, version, workspace_id}}
      {:wiki_page_deleted, %{file_key, workspace_id}}

  ## Scope (T2)

  Wiki domain only. **Not** in scope: `Platform.Memory.*` calls, the
  indexer GenServer (T3), memory-service HTTP (T3), MCP tool surface
  (T5), LiveView (T7), historian cursors (T6). `Platform.Org.Context`
  is the V1 surface and stays untouched; T5 will retire it.
  """

  @index_topic "org_wiki:index"

  @typedoc """
  Attributes accepted by `upsert_page/3`. `:content` is the only
  required key; `:updated_by`/`:expected_version` are optional. The
  frontmatter map and version are managed by the module — callers do
  not pass them directly.
  """
  @type page_attrs :: %{
          optional(:content) => String.t(),
          optional(:updated_by) => binary() | nil,
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

  @doc "Fetch a wiki page by `file_key`, falling back through `org_wiki_aliases`."
  @spec get_page(String.t(), keyword()) ::
          Platform.Org.WikiPage.t() | nil
  def get_page(_file_key, _opts \\ []), do: not_implemented()

  @doc "List wiki pages in a workspace, ordered by `file_key asc`."
  @spec list_pages(keyword()) :: [Platform.Org.WikiPage.t()]
  def list_pages(_opts \\ []), do: not_implemented_list()

  @doc """
  Create or update a wiki page.

  Parses frontmatter + wikilinks from `attrs.content`, writes the page
  row with optimistic locking, materializes `org_wiki_links` (delete +
  bulk insert), and emits `{:wiki_page_written, …}` on the index topic.
  """
  @spec upsert_page(String.t(), page_attrs(), keyword()) ::
          {:ok, Platform.Org.WikiPage.t()}
          | {:error, Ecto.Changeset.t() | :stale | :not_implemented}
  def upsert_page(_file_key, _attrs, _opts \\ []), do: not_implemented()

  @doc "Delete a wiki page. Cascades `org_wiki_links` rows via the FK."
  @spec delete_page(String.t(), keyword()) ::
          {:ok, Platform.Org.WikiPage.t()} | {:error, :not_found | :not_implemented}
  def delete_page(_file_key, _opts \\ []), do: not_implemented()

  @doc "Pages that link TO `file_key` (via `org_wiki_links.target_path`)."
  @spec backlinks(String.t(), keyword()) :: [Platform.Org.WikiPage.t()]
  def backlinks(_file_key, _opts \\ []), do: not_implemented_list()

  @doc """
  Resolve `file_key` through `org_wiki_aliases`.

  Returns the page the alias points at, or `nil`. Workspace-scoped via
  the composite PK on the alias table (see migration
  `20260519220000_add_workspace_id_to_org_wiki_aliases.exs`).
  """
  @spec resolve_alias(String.t(), keyword()) ::
          Platform.Org.WikiPage.t() | nil
  def resolve_alias(_file_key, _opts \\ []), do: not_implemented()

  # ── Pure parsers (filled in by Stage 2) ───────────────────────────────

  @doc """
  Parse YAML frontmatter from a page body.

  Returns `{frontmatter_map, body_without_frontmatter}`. When no
  frontmatter is present or it cannot be parsed, returns
  `{%{}, original_body}`.
  """
  @spec parse_frontmatter(String.t()) :: {frontmatter(), String.t()}
  def parse_frontmatter(_body), do: not_implemented_pair()

  @doc """
  Extract `[[wikilinks]]` from page body content.

  Links inside fenced code blocks (```` ``` ````) and inline code
  spans are ignored. See `t:wikilink/0`.
  """
  @spec parse_wikilinks(String.t()) :: [wikilink()]
  def parse_wikilinks(_body), do: not_implemented_list()

  # ── Internals ─────────────────────────────────────────────────────────

  @doc false
  @spec index_topic() :: String.t()
  def index_topic, do: @index_topic

  # Broadcast helper used by Stage 3+ once writes are wired. Kept
  # private; the index topic is exposed via `index_topic/0` for tests.
  @spec broadcast_index_event(atom(), map()) :: :ok | {:error, term()}
  defp broadcast_index_event(event, payload)
       when is_atom(event) and is_map(payload) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @index_topic, {event, payload})
  end

  # Silence "unused" warnings until Stage 3 wires the broadcaster.
  @doc false
  def __broadcast_index_event__(event, payload),
    do: broadcast_index_event(event, payload)

  # Tiny helpers so each not-yet-implemented head has a matching return
  # type for `@spec`. Kept private + tagged with the stage that fills
  # them in.
  @spec not_implemented() :: {:error, :not_implemented}
  defp not_implemented, do: {:error, :not_implemented}

  @spec not_implemented_list() :: []
  defp not_implemented_list, do: []

  @spec not_implemented_pair() :: {map(), String.t()}
  defp not_implemented_pair, do: {%{}, ""}
end
