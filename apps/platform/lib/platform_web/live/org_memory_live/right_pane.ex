defmodule PlatformWeb.OrgMemoryLive.RightPane do
  @moduledoc """
  Right-pane stub for the Org Memory wiki (ADR-0041 T7).

  Stage 5 fills this with backlinks + page-meta (`vN · updated by · NN
  ago`). For stage 3 it renders an empty-state placeholder so the
  three-column grid has its third column.
  """

  use Phoenix.Component

  attr(:page, :any, default: nil, doc: "selected Platform.Org.WikiPage or nil")

  def right_pane(assigns) do
    ~H"""
    <aside class="flex min-h-0 flex-col overflow-y-auto border-l border-base-300 bg-base-200/40">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Page Details
        </h2>
      </div>
      <div class="flex flex-1 items-center justify-center px-4 py-8">
        <div class="text-center">
          <span class="hero-link mb-2 size-8 text-base-content/20 mx-auto block"></span>
          <p class="text-xs text-base-content/40">
            <%= if @page do %>
              Backlinks and page metadata arrive in a later stage.
            <% else %>
              Select a page to see its details.
            <% end %>
          </p>
        </div>
      </div>
    </aside>
    """
  end
end
