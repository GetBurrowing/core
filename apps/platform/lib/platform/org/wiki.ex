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

  import Ecto.Query, only: [from: 2, where: 3, order_by: 3]

  require Logger

  alias Ecto.Adapters.SQL
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

  @doc """
  Fetch a wiki page by `file_key`.

  Falls back through `org_wiki_aliases` when the direct lookup misses
  so legacy V1 keys (`ORG_IDENTITY.md`, …) keep resolving after T1's
  path-style rename.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
  """
  @spec get_page(String.t(), keyword()) :: WikiPage.t() | nil
  def get_page(file_key, opts \\ []) when is_binary(file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)

    direct =
      WikiPage
      |> where([p], p.file_key == ^file_key)
      |> filter_workspace(workspace_id)
      |> Repo.one()

    direct || lookup_via_alias(file_key, workspace_id)
  end

  @doc """
  List wiki pages in a workspace, ordered by `file_key asc`.

  ## Options
    * `:workspace_id` (default `nil` — org-scoped)
  """
  @spec list_pages(keyword()) :: [WikiPage.t()]
  def list_pages(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    WikiPage
    |> filter_workspace(workspace_id)
    |> order_by([p], asc: p.file_key)
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

  ## Options
    * `:workspace_id` (default `nil`)
    * `:expected_version` — when set, a mismatch returns `{:error, :stale}`
  """
  @spec upsert_page(String.t(), page_attrs(), keyword()) ::
          {:ok, WikiPage.t()} | {:error, Ecto.Changeset.t() | :stale}
  def upsert_page(file_key, attrs, opts \\ []) when is_binary(file_key) and is_map(attrs) do
    workspace_id = Keyword.get(opts, :workspace_id)
    expected_version = Keyword.get(opts, :expected_version)

    content =
      Map.get(attrs, :content) || Map.get(attrs, "content") || ""

    updated_by =
      Map.get(attrs, :updated_by) || Map.get(attrs, "updated_by")

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
              |> WikiPage.changeset(%{
                file_key: file_key,
                workspace_id: workspace_id,
                content: content,
                frontmatter: frontmatter,
                updated_by: updated_by
              })
              |> Repo.insert()
              |> unwrap_or_rollback()

            %WikiPage{} = row ->
              if not is_nil(expected_version) and row.version != expected_version do
                Repo.rollback(:stale)
              end

              row
              |> WikiPage.update_changeset(%{
                content: content,
                frontmatter: frontmatter,
                updated_by: updated_by
              })
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

  @doc """
  Delete a wiki page. `org_wiki_links` rows referencing it cascade via
  the FK's `on_delete: :delete_all`. Emits a `:wiki_page_deleted`
  index event.

  ## Options
    * `:workspace_id` (default `nil`)
  """
  @spec delete_page(String.t(), keyword()) ::
          {:ok, WikiPage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_page(file_key, opts \\ []) when is_binary(file_key) do
    workspace_id = Keyword.get(opts, :workspace_id)

    case get_page(file_key, workspace_id: workspace_id) do
      nil ->
        {:error, :not_found}

      %WikiPage{} = page ->
        case Repo.delete(page) do
          {:ok, deleted} ->
            broadcast_index_event(:wiki_page_deleted, %{
              file_key: deleted.file_key,
              workspace_id: deleted.workspace_id
            })

            {:ok, deleted}

          {:error, _} = err ->
            err
        end
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
