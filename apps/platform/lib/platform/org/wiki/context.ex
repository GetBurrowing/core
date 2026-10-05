defmodule Platform.Org.Wiki.Context do
  @moduledoc """
  Budgeted, scope-aware org preamble assembly (ADR-0041 T4).

  Replaces the V1 `Platform.Org.Context.build_context/1` shape (workspace
  files + last-2-days journal notes flattened into one map) with a
  curated wiki-pages preamble bounded by a token budget.

  ## Public API

      Platform.Org.Wiki.Context.build_preamble(task: task)
      Platform.Org.Wiki.Context.build_preamble(space_id: space_id)
      Platform.Org.Wiki.Context.build_preamble([])               # org-only

  `build_preamble/1` returns a plain `%{path => content}` map suitable
  for the existing `:org` field in `Platform.Orchestration.ContextAssembler`
  and `Platform.Chat.ContextPlane`. `build_preamble_with_metadata/1`
  returns the same map plus telemetry-flavoured metadata
  (`used_tokens`, `dropped`, `truncated`) for observability.

  ## Selection

  Pages from `Platform.Org.Wiki.list_pages/1` are filtered to those whose
  frontmatter declares `preamble: true` AND whose `file_key` starts with
  one of the accessible namespace prefixes:

    * `"burrow/"`     — always accessible: Burrow product docs
      (`burrow/page/*`, seeded by `Platform.Org.BurrowDocs`)
    * `"org/"`        — always accessible
    * `"project/<task.project_id>/"` — when `:task` opt with `project_id`
    * `"space/<space_id>/"`          — when `:space_id` opt is set

  Pages outside scope are silently filtered out of the returned map and
  recorded under `dropped` with `reason: :scope` in the metadata form.

  ## Ordering

  Stable sort by `{band(file_key), file_key}` where band assigns -1 to
  `burrow/*` product docs, 0 to `org/*`, 1 to `project/*`, and 2 to
  `space/*`. Product docs sort first, so the budget walk includes them
  before any install page and they survive an overrun. Within a band, lex `asc`
  on `file_key`. Deterministic; no recency weighting (preamble pages are
  curated, not stream-y).

  ## Budget

  Default token budget is 4096; configurable via
  `Application.get_env(:platform, :preamble_token_budget, 4096)`. Per-call
  override via the `:budget` opt (intended for tests).

  V1 token estimator is the well-known char/4 heuristic
  (`div(byte_size(content), 4)`). Anthropic and OpenAI both publish
  ~4 chars/token for English. Cheap and deterministic. Replace with a
  real tokenizer when the wiki holds enough preamble content for the
  heuristic to bite.

  ## Eviction & truncation

  Walking pages in sort order:

    1. If the page fits whole within remaining budget, include it.
    2. Else if NO pages are included yet AND this page alone exceeds
       budget, TRUNCATE the page at the nearest `\\n\\n` paragraph
       boundary at-or-below the budget cliff. Append a literal
       `[truncated]` sentinel after the cut. Include the truncated page;
       record under `truncated`.
    3. Else, DROP this page; record under `dropped` with
       `reason: :budget_overrun`. Continue walking — later, smaller
       pages may still fit.

  The `[truncated]` sentinel (not the HTML-comment form) is per the
  task description AC. Stage 1 recon doc has the rationale.

  ## Annotation

  Each included page's value in the returned map is wrapped:

      <!-- BEGIN org-preamble page="<file_key>" version="<v>" -->
      <body>
      <!-- END org-preamble page="<file_key>" -->

  The HTML-comment markers survive markdown rendering and give agents
  an unambiguous boundary between injected preamble and user input.

  Map KEY is the raw `file_key` (no annotation in the key) so any UI
  code that introspects `Map.keys(context.org)` keeps working.

  ## Telemetry

  Fires `[:platform, :org, :wiki_context, :preamble_built]` on every
  call. Measurements: `%{used_tokens, dropped_count, truncated_count,
  page_count, budget}`. Metadata: `%{caller_kind: :task | :space | :org}`.

  ## Scope (T4 — not in scope)

  * Tool surface (`memory_*` MCP tools) — T5
  * Historian / cursors — T6
  * UI (`OrgMemoryLive`) — T7
  * `Platform.Org.Context` retirement — T5
  """

  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage

  @default_budget 4096
  @telemetry_event [:platform, :org, :wiki_context, :preamble_built]
  @truncated_sentinel "[truncated]"
  @truncated_join "\n\n[truncated]"

  @type opts :: [
          task: struct() | nil,
          space_id: String.t() | nil,
          workspace_id: binary() | nil,
          budget: non_neg_integer(),
          now: DateTime.t()
        ]

  @type metadata :: %{
          pages: %{String.t() => String.t()},
          used_tokens: non_neg_integer(),
          dropped: [%{path: String.t(), reason: :budget_overrun | :scope}],
          truncated: [%{path: String.t(), lost_tokens: non_neg_integer()}]
        }

  @doc """
  Build the org preamble as a `%{path => content}` map.

  Drops metadata; call sites use this for the `:org` key in their context
  bundles. For observability, use `build_preamble_with_metadata/1`.
  """
  @spec build_preamble(opts()) :: %{String.t() => String.t()}
  def build_preamble(opts \\ []) do
    {:ok, %{pages: pages}} = build_preamble_with_metadata(opts)
    pages
  end

  @doc """
  Build the org preamble with full metadata.

  Returns `{:ok, %{pages, used_tokens, dropped, truncated}}`. See module
  docs for the shape of each field.
  """
  @spec build_preamble_with_metadata(opts()) :: {:ok, metadata()}
  def build_preamble_with_metadata(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    budget = Keyword.get(opts, :budget, configured_budget())

    candidates = Wiki.list_pages(workspace_id: workspace_id)

    namespace_prefixes = namespace_prefixes(opts)
    caller_kind = caller_kind(opts)

    {selected, scope_dropped} = filter_and_partition(candidates, namespace_prefixes)
    ordered = sort_pages(selected)

    {pages, used_tokens, budget_dropped, truncated} = walk_budget(ordered, budget)

    metadata = %{
      pages: pages,
      used_tokens: used_tokens,
      dropped: scope_dropped ++ budget_dropped,
      truncated: truncated
    }

    :telemetry.execute(
      @telemetry_event,
      %{
        used_tokens: used_tokens,
        dropped_count: length(metadata.dropped),
        truncated_count: length(truncated),
        page_count: map_size(pages),
        budget: budget
      },
      %{caller_kind: caller_kind}
    )

    {:ok, metadata}
  end

  # ── Selection / scoping ───────────────────────────────────────────────

  @spec namespace_prefixes(opts()) :: [String.t()]
  defp namespace_prefixes(opts) do
    project_prefix =
      case Keyword.get(opts, :task) do
        %{project_id: pid} when is_binary(pid) and pid != "" -> ["project/#{pid}/"]
        _ -> []
      end

    space_prefix =
      case Keyword.get(opts, :space_id) do
        sid when is_binary(sid) and sid != "" -> ["space/#{sid}/"]
        _ -> []
      end

    [Wiki.product_owned_prefix(), "org/"] ++ project_prefix ++ space_prefix
  end

  @spec caller_kind(opts()) :: :task | :space | :org
  defp caller_kind(opts) do
    cond do
      match?(%{project_id: pid} when is_binary(pid), Keyword.get(opts, :task)) -> :task
      is_binary(Keyword.get(opts, :space_id)) -> :space
      true -> :org
    end
  end

  # Filter candidate pages into:
  #   * `selected` — preamble-flagged pages whose `file_key` is in scope
  #   * `scope_dropped` — preamble-flagged pages outside scope (recorded
  #     with reason: :scope for the metadata)
  #
  # Pages without `frontmatter["preamble"] == true` are filtered out
  # entirely — they never enter the candidate set, so they're NOT in
  # `dropped`. Only preamble-flagged-but-out-of-scope pages appear there.
  @spec filter_and_partition([WikiPage.t()], [String.t()]) ::
          {[WikiPage.t()], [%{path: String.t(), reason: :scope}]}
  defp filter_and_partition(candidates, namespace_prefixes) do
    preamble_pages = Enum.filter(candidates, &preamble?/1)

    Enum.reduce(preamble_pages, {[], []}, fn page, {sel, dropped} ->
      if in_scope?(page.file_key, namespace_prefixes) do
        {[page | sel], dropped}
      else
        {sel, [%{path: page.file_key, reason: :scope} | dropped]}
      end
    end)
    |> then(fn {sel, dropped} -> {Enum.reverse(sel), Enum.reverse(dropped)} end)
  end

  @spec preamble?(WikiPage.t()) :: boolean()
  defp preamble?(%WikiPage{frontmatter: %{"preamble" => true}}), do: true
  defp preamble?(_), do: false

  @spec in_scope?(String.t(), [String.t()]) :: boolean()
  defp in_scope?(file_key, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(file_key, &1))
  end

  # ── Ordering ──────────────────────────────────────────────────────────

  @spec sort_pages([WikiPage.t()]) :: [WikiPage.t()]
  defp sort_pages(pages) do
    Enum.sort_by(pages, &{band(&1.file_key), &1.file_key})
  end

  @spec band(String.t()) :: -1 | 0 | 1 | 2 | 3
  defp band("burrow/" <> _), do: -1
  defp band("org/" <> _), do: 0
  defp band("project/" <> _), do: 1
  defp band("space/" <> _), do: 2
  # Anything else sorts last but is in practice filtered out by
  # `in_scope?/2`; defensive default so the comparator never crashes.
  defp band(_), do: 3

  # ── Budget walk ───────────────────────────────────────────────────────

  @spec walk_budget([WikiPage.t()], non_neg_integer()) ::
          {%{String.t() => String.t()}, non_neg_integer(),
           [%{path: String.t(), reason: :budget_overrun}],
           [%{path: String.t(), lost_tokens: non_neg_integer()}]}
  defp walk_budget(ordered, budget) do
    initial = %{
      pages: %{},
      used: 0,
      dropped: [],
      truncated: [],
      any_included?: false
    }

    final =
      Enum.reduce(ordered, initial, fn page, acc ->
        annotated = annotate(page, page.content)
        tokens = estimate_tokens(annotated)
        remaining = budget - acc.used

        cond do
          tokens <= remaining ->
            %{
              acc
              | pages: Map.put(acc.pages, page.file_key, annotated),
                used: acc.used + tokens,
                any_included?: true
            }

          not acc.any_included? and tokens > budget and budget > 0 ->
            # Single-page truncation: cut at paragraph boundary, append
            # the literal [truncated] sentinel, wrap with BEGIN/END.
            # `budget > 0` guard: budget=0 should drop everything (not
            # truncate to an empty body that would still emit annotation
            # overhead). The empty-corpus / zero-budget case lands in the
            # `:budget_overrun` branch below.
            {truncated_body, lost_tokens, used_tokens} =
              truncate_page(page, budget)

            %{
              acc
              | pages: Map.put(acc.pages, page.file_key, truncated_body),
                used: used_tokens,
                truncated: [
                  %{path: page.file_key, lost_tokens: lost_tokens} | acc.truncated
                ],
                any_included?: true
            }

          true ->
            %{
              acc
              | dropped: [%{path: page.file_key, reason: :budget_overrun} | acc.dropped]
            }
        end
      end)

    {
      final.pages,
      final.used,
      Enum.reverse(final.dropped),
      Enum.reverse(final.truncated)
    }
  end

  # Truncate `page.content` so that the annotated+sentinel result fits
  # within `budget` tokens. Cut at the nearest `\n\n` paragraph boundary
  # at-or-below the byte budget. If no such boundary exists, fall back
  # to a hard byte cut.
  @spec truncate_page(WikiPage.t(), non_neg_integer()) ::
          {String.t(), non_neg_integer(), non_neg_integer()}
  defp truncate_page(%WikiPage{} = page, budget) do
    # Fixed-overhead bytes: BEGIN line + closing `\n` after body +
    # `\n\n[truncated]` join + `\n` before END line + END line.
    overhead_bytes =
      byte_size(begin_marker(page)) +
        byte_size("\n") +
        byte_size(@truncated_join) +
        byte_size("\n") +
        byte_size(end_marker(page))

    budget_bytes = budget * 4

    body_byte_budget = max(budget_bytes - overhead_bytes, 0)

    truncated_body = cut_at_paragraph(page.content, body_byte_budget)

    annotated = annotate_truncated(page, truncated_body)
    used_tokens = estimate_tokens(annotated)

    lost_tokens =
      max(estimate_tokens(page.content) - estimate_tokens(truncated_body), 0)

    {annotated, lost_tokens, used_tokens}
  end

  # Find the last `\n\n` whose end-offset is ≤ budget_bytes. If found,
  # cut there (excluding the trailing `\n\n` since the join appends its
  # own `\n\n[truncated]`). If not found, hard-cut at budget_bytes.
  @spec cut_at_paragraph(String.t(), non_neg_integer()) :: String.t()
  defp cut_at_paragraph(_content, 0), do: ""

  defp cut_at_paragraph(content, budget_bytes) when is_binary(content) do
    if byte_size(content) <= budget_bytes do
      content
    else
      head = binary_part(content, 0, budget_bytes)

      case :binary.matches(head, "\n\n") do
        [] ->
          # No paragraph boundary in the head — hard byte cut.
          head

        matches ->
          {boundary, _len} = List.last(matches)
          binary_part(content, 0, boundary)
      end
    end
  end

  # ── Annotation ────────────────────────────────────────────────────────

  @spec annotate(WikiPage.t(), String.t()) :: String.t()
  defp annotate(%WikiPage{} = page, body) do
    begin_marker(page) <> "\n" <> body <> "\n" <> end_marker(page)
  end

  @spec annotate_truncated(WikiPage.t(), String.t()) :: String.t()
  defp annotate_truncated(%WikiPage{} = page, truncated_body) do
    begin_marker(page) <>
      "\n" <> truncated_body <> @truncated_join <> "\n" <> end_marker(page)
  end

  @spec begin_marker(WikiPage.t()) :: String.t()
  defp begin_marker(%WikiPage{file_key: fk, version: v}) do
    ~s(<!-- BEGIN org-preamble page="#{fk}" version="#{v}" -->)
  end

  @spec end_marker(WikiPage.t()) :: String.t()
  defp end_marker(%WikiPage{file_key: fk}) do
    ~s(<!-- END org-preamble page="#{fk}" -->)
  end

  # ── Token estimator ───────────────────────────────────────────────────

  # char/4 heuristic — Anthropic and OpenAI publish ~4 chars/token for
  # English. Cheap and deterministic. Replace with a real tokenizer
  # when the wiki holds enough preamble content for the heuristic to
  # bite.
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  defp estimate_tokens(content) when is_binary(content) do
    div(byte_size(content), 4)
  end

  # ── Config ────────────────────────────────────────────────────────────

  @spec configured_budget() :: non_neg_integer()
  defp configured_budget do
    Application.get_env(:platform, :preamble_token_budget, @default_budget)
  end

  @doc false
  def truncated_sentinel, do: @truncated_sentinel

  @doc false
  def telemetry_event, do: @telemetry_event
end
