defmodule PlatformWeb.OrgMemoryLive.PageViewer do
  @moduledoc """
  Main-pane page viewer for the Org Memory wiki (ADR-0041 T7).

  Stage-3 stub: renders the selected page's pre-rendered markdown the way
  the old single-file LiveView's viewer panel did (toolbar, prose body,
  metadata footer), plus the "nothing selected" empty state. Stage 4
  rewrites this with wikilink-aware rendering.

  Stateless — receives `@page` (a `Platform.Org.WikiPage` or `nil`) and
  the pre-rendered `@preview_html` from `PlatformWeb.OrgMemoryLive`.
  Emits `"start_edit"`, `"confirm_delete"`, `"cancel_delete"`, and
  `"delete_file"` events handled by the parent LiveView.
  """

  use Phoenix.Component

  import PlatformWeb.OrgMemoryLive.NamespaceTree, only: [file_icon: 1]

  attr(:page, :any, default: nil, doc: "selected Platform.Org.WikiPage or nil")
  attr(:preview_html, :string, default: "")
  attr(:confirm_delete, :string, default: nil)

  def page_viewer(assigns) do
    ~H"""
    <%= if @page do %>
      <div class="flex flex-1 flex-col overflow-hidden">
        <%!-- Toolbar --%>
        <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
          <div class="flex items-center gap-3">
            <span class={[file_icon(@page.file_key), "size-5 text-primary"]}></span>
            <div>
              <h1 class="text-lg font-bold">{@page.file_key}</h1>
              <p class="text-xs text-base-content/40">
                Version {@page.version}
                <span :if={@page.updated_at}>
                  · Updated {format_relative(@page.updated_at)}
                </span>
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="start_edit" class="btn btn-primary btn-sm gap-1">
              <span class="hero-pencil-square size-4"></span> Edit
            </button>
            <div class="relative">
              <button
                phx-click="confirm_delete"
                phx-value-key={@page.file_key}
                class="btn btn-ghost btn-sm text-error/60 hover:text-error"
                title="Delete page"
              >
                <span class="hero-trash size-4"></span>
              </button>
              <%!-- Delete confirmation popover --%>
              <%= if @confirm_delete == @page.file_key do %>
                <div class="absolute right-0 top-full mt-1 z-50 rounded-lg border border-base-300 bg-base-100 p-4 shadow-lg w-64">
                  <p class="text-sm font-medium mb-3">
                    Delete {@page.file_key}?
                  </p>
                  <p class="text-xs text-base-content/50 mb-3">
                    This action cannot be undone.
                  </p>
                  <div class="flex justify-end gap-2">
                    <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                      Cancel
                    </button>
                    <button
                      phx-click="delete_file"
                      phx-value-key={@page.file_key}
                      class="btn btn-error btn-xs"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Rendered preview --%>
        <div class="flex-1 overflow-y-auto px-8 py-6">
          <article class="prose prose-sm max-w-none text-base-content">
            {Phoenix.HTML.raw(@preview_html)}
          </article>
        </div>

        <%!-- Page metadata footer --%>
        <div class="flex items-center gap-4 border-t border-base-300 px-6 py-2 text-xs text-base-content/40">
          <span class="flex items-center gap-1">
            <span class="hero-document size-3.5"></span>
            {byte_size(@page.content)} bytes
          </span>
          <span class="flex items-center gap-1">
            <span class="hero-hashtag size-3.5"></span>
            {line_count(@page.content)} lines
          </span>
          <span class="flex items-center gap-1">
            <span class="hero-arrow-up-circle size-3.5"></span> v{@page.version}
          </span>
          <span :if={@page.inserted_at} class="flex items-center gap-1">
            <span class="hero-clock size-3.5"></span>
            Created {Calendar.strftime(@page.inserted_at, "%b %-d, %Y")}
          </span>
        </div>
      </div>
    <% else %>
      <div class="flex flex-1 items-center justify-center">
        <div class="text-center">
          <span class="hero-document-text mb-3 size-16 text-base-content/20 mx-auto block"></span>
          <h3 class="text-lg font-medium text-base-content/50">Org Memory</h3>
          <p class="mt-1 text-sm text-base-content/40">
            Select a page from the namespace tree to view or edit organizational memory.
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

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

  defp line_count(content) when is_binary(content) do
    content |> String.split("\n") |> length()
  end

  defp line_count(_), do: 0
end
