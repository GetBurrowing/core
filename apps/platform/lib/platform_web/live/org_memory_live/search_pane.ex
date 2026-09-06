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

  Stateless — query, filters, and results live on
  `PlatformWeb.OrgMemoryLive`.
  """

  use Phoenix.Component

  @corpora ["all", "page", "journal", "message"]

  attr(:query, :string, default: "")
  attr(:corpus, :string, default: "all")
  attr(:namespace, :string, default: "all")
  attr(:namespaces, :list, required: true, doc: "top-level namespace prefixes from the tree")
  attr(:results, :list, default: [])
  attr(:performed, :boolean, default: false)
  attr(:truncated, :boolean, default: false)
  attr(:error, :string, default: nil)

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
            <option :for={ns <- @namespaces} value={ns} selected={@namespace == ns}>{ns}</option>
          </select>
        </div>
        <button type="submit" class="btn btn-primary btn-sm gap-1">
          <span class="hero-magnifying-glass size-4"></span> Search
        </button>
      </form>

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
                <.result_hit hit={hit} />
              </li>
            </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Per-source result rows ──────────────────────────────────────────────

  attr(:hit, :map, required: true)

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
        {String.upcase(@hit.source)}
      </span>
      <span class="font-mono text-base-content/40">score {format_score(@hit.score)}</span>
      <span :if={@hit.semantic_rank} class="text-base-content/30">sem #{@hit.semantic_rank}</span>
      <span :if={@hit.lexical_rank} class="text-base-content/30">lex #{@hit.lexical_rank}</span>
      <span class="ml-auto text-base-content/30">{@hit.date_or_inserted_at}</span>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

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
