defmodule PlatformWeb.OrgMemoryLive.RightPane do
  @moduledoc """
  Right pane for the Org Memory wiki (ADR-0041 T7 stage 5).

  Two sections stacked vertically when a page is selected:

    * **Backlinks** (top) — pages linking TO the selected page, loaded
      by the parent LiveView via `Platform.Org.Wiki.backlinks/2` into
      the `@backlinks` assign. Each entry is a `phx-click="select_page"`
      button (truncated file_key with a hover tooltip + namespace
      badge). Empty state: "No backlinks yet".
    * **Page metadata** (bottom) — the canonical home for the
      `vN · updated by · NN ago` meta (moved out of the page-viewer
      toolbar in this stage): version, updated_by (resolved upstream
      into `@updated_by_display`), inserted_at, updated_at — both
      relative.

  Stateless — selection and backlink loading live on
  `PlatformWeb.OrgMemoryLive`. When no page is selected the pane keeps
  the stage-3 empty-state placeholder.
  """

  use Phoenix.Component

  import PlatformWeb.OrgMemoryLive.NamespaceTree, only: [file_icon: 1]

  attr(:page, :any, default: nil, doc: "selected Platform.Org.WikiPage or nil")
  attr(:backlinks, :list, default: [], doc: "WikiPages linking to @page (Wiki.backlinks/2)")
  attr(:updated_by_display, :string, default: nil)

  def right_pane(assigns) do
    ~H"""
    <aside class="flex min-h-0 flex-col overflow-y-auto border-l border-edge bg-base-200/40">
      <div class="border-b border-edge px-4 py-3">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Page Details
        </h2>
      </div>

      <%= if @page do %>
        <%!-- Backlinks (top) --%>
        <div class="border-b border-edge px-4 py-3" data-role="backlinks">
          <h3 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/40">
            Backlinks
          </h3>
          <%= if @backlinks == [] do %>
            <p class="text-xs text-base-content/40">No backlinks yet</p>
          <% else %>
            <ul class="flex flex-col gap-1">
              <li :for={source <- @backlinks}>
                <button
                  phx-click="select_page"
                  phx-value-file_key={source.file_key}
                  data-backlink={source.file_key}
                  title={source.file_key}
                  class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs hover:bg-base-300/60"
                >
                  <span class={[file_icon(source.file_key), "shrink-0 text-base-content/40"]}></span>
                  <span class="min-w-0 flex-1 truncate font-mono">{source.file_key}</span>
                  <span class="badge badge-ghost badge-xs shrink-0">
                    {namespace_badge(source.file_key)}
                  </span>
                </button>
              </li>
            </ul>
          <% end %>
        </div>

        <%!-- Page metadata (bottom) --%>
        <%!-- Current version only — no version-history list (design lock §5). --%>
        <%!-- # TODO(0041-T7-followup): version history requires org_wiki_page_versions table --%>
        <div class="px-4 py-3" data-role="page-meta">
          <h3 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/40">
            Metadata
          </h3>
          <dl class="flex flex-col gap-1.5 text-xs">
            <div class="flex items-center justify-between gap-2">
              <dt class="text-base-content/40">Version</dt>
              <dd class="font-mono">v{@page.version}</dd>
            </div>
            <div
              :if={@page.updated_by && @updated_by_display}
              class="flex items-center justify-between gap-2"
            >
              <dt class="text-base-content/40">Updated by</dt>
              <dd class="truncate" title={@updated_by_display}>{@updated_by_display}</dd>
            </div>
            <div :if={@page.inserted_at} class="flex items-center justify-between gap-2">
              <dt class="text-base-content/40">Created</dt>
              <dd>{format_relative(@page.inserted_at)}</dd>
            </div>
            <div :if={@page.updated_at} class="flex items-center justify-between gap-2">
              <dt class="text-base-content/40">Updated</dt>
              <dd>{format_relative(@page.updated_at)}</dd>
            </div>
          </dl>
        </div>
      <% else %>
        <div class="flex flex-1 items-center justify-center px-4 py-8">
          <div class="text-center">
            <span class="hero-link mb-2 size-8 text-base-content/20 mx-auto block"></span>
            <p class="text-xs text-base-content/40">
              Select a page to see its details.
            </p>
          </div>
        </div>
      <% end %>
    </aside>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Top-level namespace of a file_key (`org/identity.md` → `org`).
  # Root-level pages with no `/` get the catch-all `root` badge.
  defp namespace_badge(file_key) do
    case String.split(file_key, "/") do
      [_leaf] -> "root"
      [namespace | _rest] -> namespace
    end
  end

  defp format_relative(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end
end
