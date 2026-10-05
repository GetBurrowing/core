defmodule PlatformWeb.OrgMemoryLive.SearchPane do
  @moduledoc """
  Search tab for the Org Memory wiki (ADR-0041 T7 stage 6).

  Search box + corpus / namespace filters, submitted as
  `phx-submit="search_memory"`. The parent LiveView dispatches through
  `Platform.Federation.ToolSurface.execute("memory_search", ...)` — the
  same gate code path agents use — never `Wiki.Search` directly.

  Results render source-tagged (PAGE / JOURNAL / MESSAGE) with the RRF
  score + per-channel ranks, and click through per source:

    * page    → `phx-click="open_result_page"` (patch back to `:pages`)
    * journal → `phx-click="open_result_journal"` (switch to `:journal`,
      focused on the hit's date)
    * message → plain href to `/chat/<space_id>` (`ChatLive` resolves
      slug-or-UUID)

  A Burrow Docs hit (a page hit on a `burrow/` key, task 01a10a44 stage 5)
  keeps the same badge component with the text `DOCS`, shows the topic
  title in Public Sans instead of the mono path, adds a
  "Burrow Docs · <sha>" line and carries the cyan spine on its left edge.
  Ranking stays mixed. The namespace select labels `burrow` "Burrow Docs".

  Stateless — query, filters, and results live on
  `PlatformWeb.OrgMemoryLive`.
  """

  use Phoenix.Component

  alias PlatformWeb.OrgMemoryLive.ProductDocs

  @corpora ["all", "page", "journal", "message"]

  attr(:query, :string, default: "")
  attr(:corpus, :string, default: "all")
  attr(:namespace, :string, default: "all")
  attr(:namespaces, :list, required: true, doc: "top-level namespace prefixes from the tree")
  attr(:results, :list, default: [])
  attr(:performed, :boolean, default: false)
  attr(:truncated, :boolean, default: false)
  attr(:error, :string, default: nil)
  attr(:degraded, :boolean, default: false)

  attr(:dead_channels, :list,
    default: [],
    doc: "channels that did not answer, as [channel, corpus] pairs"
  )

  attr(:results_revealed, :boolean,
    default: false,
    doc: "server-side reveal state for a degraded search's partial hits"
  )

  attr(:burrow_docs, :list, default: [], doc: "ProductDocs entries, for Burrow hit titles")

  def search_pane(assigns) do
    assigns = assign(assigns, :corpora, @corpora)

    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden" data-role="search-pane">
      <%!-- Header --%>
      <div class="border-b border-edge px-6 py-3">
        <h1 class="text-lg font-bold">Search</h1>
        <p class="text-xs text-base-content/40">
          Hybrid search across pages, journal entries, and messages
        </p>
      </div>

      <%!-- Query + filters --%>
      <form
        id="org-memory-search-form"
        phx-submit="search_memory"
        class="flex flex-wrap items-end gap-3 border-b border-edge px-6 py-4"
      >
        <div class="min-w-48 flex-1">
          <label class="mb-1 block text-xs text-base-content/50">Query</label>
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Search org memory…"
            autocomplete="off"
            class="input input-bordered input-sm w-full"
          />
        </div>
        <div>
          <label class="mb-1 block text-xs text-base-content/50">Corpus</label>
          <select name="corpus" class="select select-bordered select-sm">
            <option :for={c <- @corpora} value={c} selected={@corpus == c}>{c}</option>
          </select>
        </div>
        <div>
          <label class="mb-1 block text-xs text-base-content/50">Namespace</label>
          <select name="namespace" class="select select-bordered select-sm">
            <option value="all" selected={@namespace == "all"}>all</option>
            <option :for={ns <- @namespaces} value={ns} selected={@namespace == ns}>
              {namespace_label(ns)}
            </option>
          </select>
        </div>
        <button type="submit" class="btn btn-primary btn-sm gap-1">
          <span class="hero-magnifying-glass size-4"></span> Search
        </button>
      </form>

      <%!-- Orientation strip: pinned to the bottom edge of the search-form
           block, present on EVERY render, healthy or degraded. --%>
      <.channel_strip dead_channels={@dead_channels} />

      <%!-- Results --%>
      <div class="flex-1 overflow-y-auto px-6 py-4">
        <p :if={@error} class="mb-3 text-sm text-error" data-role="search-error">{@error}</p>

        <%= cond do %>
          <% not @performed -> %>
            <div class="flex flex-col items-center justify-center py-16">
              <span class="hero-magnifying-glass mb-3 size-12 text-base-content/20 block"></span>
              <p class="text-sm text-base-content/40">
                Type a query to search the org's memory.
              </p>
            </div>
          <% @degraded -> %>
            <%!-- A degraded search does not render a result list with a
                 caveat attached; it renders what did not run. The hits
                 follow ONLY once the reader has passed through that
                 statement via the reveal control. --%>
            <.degraded_notice results={@results} results_revealed={@results_revealed} />
            <ul :if={@results_revealed and @results != []} class="mt-4 space-y-3">
              <li :for={hit <- @results} data-search-result data-source-tag={hit.source}>
                <.result_hit hit={hit} burrow_docs={@burrow_docs} />
              </li>
            </ul>
          <% @results == [] -> %>
            <div class="flex flex-col items-center justify-center py-16">
              <span class="hero-inbox mb-3 size-12 text-base-content/20 block"></span>
              <p class="text-sm text-base-content/40">No results.</p>
            </div>
          <% true -> %>
            <p :if={@truncated} class="mb-3 text-xs text-base-content/40">
              Some channels hit their result cap — a higher limit may surface more hits.
            </p>
            <ul class="space-y-3">
              <li :for={hit <- @results} data-search-result data-source-tag={hit.source}>
                <.result_hit hit={hit} burrow_docs={@burrow_docs} />
              </li>
            </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Degraded-search surface (task 01a0941e stage 4) ─────────────────────
  #
  # PRINCIPLE: fuse the signal into the answer, never attach it to the
  # answer. Anything ATTACHED — a field, a badge, a banner, a colour, a
  # chip — can be detached by a reader, and eventually is. So the degraded
  # states below do not decorate a result list; they REPLACE it, and the
  # partial hits are reachable only through a control whose own label
  # carries the limitation.
  #
  # Both components are public because `MobileShell.mobile_search/1`
  # renders them too. That is not merely DRY: the acceptance property
  # "the string 'No results' never appears in a degraded empty state"
  # holds in BOTH viewports by construction only while one function owns
  # the string. Two copies would let the mobile one drift silently, and a
  # desktop screenshot would never show it.

  attr(:results, :list, default: [])
  attr(:results_revealed, :boolean, default: false)

  @doc """
  The degraded search result — the replacement for a result list, not a
  caveat attached to one.

  Zero hits renders the statement alone. N hits renders the statement plus
  a reveal control; the caller renders the hit list only when
  `@results_revealed` is true, so the only route to the results runs
  through the sentence.
  """
  def degraded_notice(%{results: []} = assigns) do
    ~H"""
    <div
      class="flex flex-col items-center justify-center gap-3 py-16 text-center"
      data-role="search-degraded-empty"
    >
      <span class="hero-exclamation-triangle size-12 text-warning block"></span>
      <p class="max-w-md text-sm text-base-content">
        Semantic search did not run. Lexical matching alone found nothing, so absence is not established.
      </p>
      <.run_again_control />
    </div>
    """
  end

  def degraded_notice(assigns) do
    ~H"""
    <div
      class="flex flex-col items-center gap-3 py-10 text-center"
      data-role="search-degraded-partial"
    >
      <span class="hero-exclamation-triangle size-12 text-warning block"></span>
      <p class="max-w-md text-sm text-base-content">
        Semantic search did not run. {length(@results)} lexical {match_word(@results)} found. Lexical matching misses wording you did not already guess, so this list is partial.
      </p>
      <div class="flex flex-wrap items-center justify-center gap-2">
        <button
          :if={not @results_revealed}
          type="button"
          phx-click="reveal_degraded_results"
          data-role="reveal-partial-results"
          class="btn btn-sm btn-outline btn-warning"
        >
          Show {length(@results)} lexical {match_word(@results)}
        </button>
        <.run_again_control />
      </div>
    </div>
    """
  end

  # `Run again` — a degraded search is a failed measurement, and a retry is
  # the action that can still establish the absence. Re-submits the live
  # form rather than carrying its own copy of query + facets, so it cannot
  # drift out of sync with the filters actually on screen.
  defp run_again_control(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="search_memory"
      data-role="search-run-again"
      class="btn btn-sm btn-ghost"
    >
      Run again
    </button>
    """
  end

  defp match_word([_one]), do: "match"
  defp match_word(_), do: "matches"

  attr(:dead_channels, :list, default: [])

  @doc """
  Orientation strip: which retrieval channels ran, on EVERY render.

  This is explicitly NOT the guard. It sits beside the answer, so a reader
  who has seen two quiet chips two hundred times will stop resolving them —
  the same habituation that defeats a badge. The false-negative protection
  lives in `degraded_notice/1`, which a reader cannot route around. Do not
  let a later simplification move the protection in here.

  Rendered unconditionally so that its healthy state is a thing readers
  have actually seen; a strip that appears only when degraded is a banner,
  and its absence would carry the signal instead of its content.
  """
  def channel_strip(assigns) do
    ~H"""
    <div
      class="flex items-center gap-3 bg-base-200 px-6 py-1.5"
      data-role="channel-strip"
    >
      <.channel_chip channel="semantic" down={channel_down?(@dead_channels, "semantic")} />
      <.channel_chip channel="lexical" down={channel_down?(@dead_channels, "lexical")} />
    </div>
    """
  end

  attr(:channel, :string, required: true)
  attr(:down, :boolean, required: true)

  # Live-chip text is `text-base-content/70`, and the tier was CHOSEN BY
  # SAMPLING, not derived from tokens. Measured with Chrome's own rasterised
  # pixels on the dev server (task 01a0941e stage 4), on the base-200 ground:
  #
  #   text-base-content/30  light 2.10:1  dark 2.32:1  <- the per-hit rank
  #                                                        tier; fails both
  #   text-neutral          light 6.69:1  dark 2.25:1  <- PRESCRIBED, and it
  #                                                        fails dark
  #   text-base-content/70  light 8.17:1  dark 8.68:1  <- shipped, passes both
  #
  # Alpha tiers are composited over the ground before the ratio is taken;
  # comparing the un-composited colour reports base-content/70 as 18.8:1.
  #
  # `--color-neutral` was the prescribed quiet slot on the strength of a
  # token-derived 2.2:1 figure for base-content/30 in LIGHT. That figure is
  # about right, but neutral is only the fix in light: in the dark palette it
  # resolves to a DARK grey (oklch(0.4 0.01 0)) on an almost-black base-200,
  # landing at 2.25:1 — reproducing, in dark, the very defect it was picked to
  # avoid. A fixed hue cannot be the quiet slot in a two-theme palette; only a
  # tier derived from `base-content`, which flips with the theme, can be.
  # (The brief's own ~2.2:1 figure for base-content/30 was right — 2.10/2.32
  # sampled. The error was not in that number, it was in assuming the
  # replacement inherited its light-mode behaviour in dark.)
  #
  # The strip's ground is `bg-base-200` rather than a `border-base-300` top
  # edge: sampled, base-200 against the pane is 1.12:1 light / 1.20:1 dark —
  # low, but the strip is meant to read as form chrome, and it is the CHIPS
  # that must be legible, not the band. A border-only strip had nothing
  # legible in it at all.
  defp channel_chip(%{down: true} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded bg-warning px-1.5 py-0.5 text-xs font-medium text-warning-content"
      data-role="channel-chip"
      data-channel={@channel}
      data-state="down"
    >
      <span class="hero-exclamation-triangle size-3"></span> {@channel} down
    </span>
    """
  end

  defp channel_chip(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 px-1.5 py-0.5 text-xs text-base-content/70"
      data-role="channel-chip"
      data-channel={@channel}
      data-state="live"
    >
      <span class="size-1.5 rounded-full bg-current"></span> {@channel}
    </span>
    """
  end

  # `dead_channels` entries are `[channel, corpus]` pairs whose channel may
  # arrive as an atom (`:semantic`, in-process) or a string (over the JSON
  # tool surface), so compare on `to_string/1` rather than either literal.
  defp channel_down?(dead_channels, channel) when is_list(dead_channels) do
    Enum.any?(dead_channels, fn
      [c, _corpus] -> to_string(c) == channel
      {c, _corpus} -> to_string(c) == channel
      c -> to_string(c) == channel
    end)
  end

  defp channel_down?(_dead_channels, _channel), do: false

  # ── Per-source result rows ──────────────────────────────────────────────

  attr(:hit, :map, required: true)
  attr(:burrow_docs, :list, default: [])

  defp result_hit(%{hit: %{source: "page", path: "burrow/" <> _}} = assigns) do
    assigns = assign(assigns, :doc, burrow_doc(assigns.hit, assigns.burrow_docs))

    ~H"""
    <button
      phx-click="open_result_page"
      phx-value-file_key={@hit.path}
      data-role="burrow-search-hit"
      class="flex w-full gap-3 rounded-lg border border-edge bg-base-100 p-4 text-left transition-colors hover:border-primary hover:bg-primary/5"
    >
      <ProductDocs.spine />
      <span class="block min-w-0 flex-1">
        <.result_meta hit={@hit} />
        <span class="mt-1 block truncate font-sans text-sm font-medium">{@doc.title}</span>
        <span class="mt-0.5 block text-xs text-base-content/60" data-role="burrow-hit-source">
          Burrow Docs<span :if={@doc.verified_at}> · <span class="whitespace-nowrap font-mono">{@doc.verified_at}</span></span>
        </span>
        <span class="mt-1 line-clamp-3 text-xs text-base-content/60">
          {snippet(ProductDocs.snippet_text(@hit.content, @doc.title))}
        </span>
      </span>
    </button>
    """
  end

  defp result_hit(%{hit: %{source: "page"}} = assigns) do
    ~H"""
    <button
      phx-click="open_result_page"
      phx-value-file_key={@hit.path}
      class="w-full rounded-lg border border-edge bg-base-100 p-4 text-left transition-colors hover:border-primary hover:bg-primary/5"
    >
      <.result_meta hit={@hit} />
      <p class="mt-1 truncate font-mono text-sm font-medium">{@hit.path}</p>
      <p class="mt-1 line-clamp-3 text-xs text-base-content/60">{snippet(@hit.content)}</p>
    </button>
    """
  end

  defp result_hit(%{hit: %{source: "journal"}} = assigns) do
    ~H"""
    <button
      phx-click="open_result_journal"
      phx-value-date={@hit.date_or_inserted_at}
      class="w-full rounded-lg border border-edge bg-base-100 p-4 text-left transition-colors hover:border-primary hover:bg-primary/5"
    >
      <.result_meta hit={@hit} />
      <p class="mt-1 truncate font-mono text-sm font-medium">{@hit.path}</p>
      <p class="mt-1 line-clamp-3 text-xs text-base-content/60">{snippet(@hit.content)}</p>
    </button>
    """
  end

  defp result_hit(%{hit: %{source: "message"}} = assigns) do
    ~H"""
    <a
      href={"/chat/#{@hit.space_id}"}
      class="block w-full rounded-lg border border-edge bg-base-100 p-4 text-left transition-colors hover:border-primary hover:bg-primary/5"
    >
      <.result_meta hit={@hit} />
      <p class="mt-1 line-clamp-3 text-xs text-base-content/60">{snippet(@hit.content)}</p>
    </a>
    """
  end

  # Unknown source tags render inert (no click-through).
  defp result_hit(assigns) do
    ~H"""
    <div class="w-full rounded-lg border border-edge bg-base-100 p-4">
      <.result_meta hit={@hit} />
      <p class="mt-1 line-clamp-3 text-xs text-base-content/60">{snippet(@hit.content)}</p>
    </div>
    """
  end

  attr(:hit, :map, required: true)

  defp result_meta(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class={["badge badge-sm font-semibold", source_badge_class(@hit.source)]}>
        {badge_label(@hit)}
      </span>
      <span class="font-mono text-base-content/40">score {format_score(@hit.score)}</span>
      <span :if={@hit.semantic_rank} class="text-base-content/30">sem #{@hit.semantic_rank}</span>
      <span :if={@hit.lexical_rank} class="text-base-content/30">lex #{@hit.lexical_rank}</span>
      <span class="ml-auto text-base-content/30">{@hit.date_or_inserted_at}</span>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc """
  The source badge text. A page hit on a Burrow Docs key reads `DOCS`; every
  other hit reads its upper-cased source (`PAGE`, `JOURNAL`, `MESSAGE`).
  """
  @spec badge_label(map()) :: String.t()
  def badge_label(%{source: "page", path: "burrow/" <> _}), do: "DOCS"
  def badge_label(%{source: source}) when is_binary(source), do: String.upcase(source)
  def badge_label(_), do: ""

  @doc "The namespace filter label: `burrow` reads \"Burrow Docs\"; others read as-is."
  @spec namespace_label(String.t()) :: String.t()
  def namespace_label("burrow"), do: "Burrow Docs"
  def namespace_label(ns), do: ns

  @doc """
  The ProductDocs entry for a Burrow hit. A hit whose row is not in the
  loaded list (it changed after mount) falls back to an entry built from
  its path, so the hit still renders a title.
  """
  @spec burrow_doc(map(), list()) :: map()
  def burrow_doc(%{path: path}, burrow_docs) do
    ProductDocs.find(burrow_docs, path) ||
      ProductDocs.entry(%{file_key: path, frontmatter: %{}, content: ""})
  end

  defp source_badge_class("page"), do: "badge-primary badge-outline"
  defp source_badge_class("journal"), do: "badge-info badge-outline"
  defp source_badge_class("message"), do: "badge-accent badge-outline"
  defp source_badge_class(_), do: "badge-ghost"

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 4)
  defp format_score(score), do: to_string(score)

  defp snippet(content) when is_binary(content) do
    if String.length(content) > 240 do
      String.slice(content, 0, 240) <> "…"
    else
      content
    end
  end

  defp snippet(_), do: ""
end
