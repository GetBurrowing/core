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
