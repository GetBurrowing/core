defmodule PlatformWeb.ControlCenter.AgentCard do
  @moduledoc """
  Function component for a single agent directory entry in the sidebar list.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ControlCenter.Helpers

  attr :agent, :map, required: true
  attr :selected_slug, :string, default: nil

  def card(assigns) do
    ~H"""
    <article class={[
      "mb-3 rounded-2xl border px-3 py-3 transition-colors",
      @selected_slug == @agent.slug && "border-primary bg-primary/5 shadow-sm",
      @selected_slug != @agent.slug &&
        "border-base-300 bg-base-100 hover:border-primary/30 hover:bg-base-100/80"
    ]}>
      <.link patch={~p"/control/#{@agent.slug}"} class="block text-left">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold text-base-content">{@agent.name}</p>
            <p class="truncate text-xs text-base-content/50">{@agent.slug}</p>
          </div>
          <div class="flex items-center gap-2">
            <span class={[
              "inline-block h-2 w-2 rounded-full",
              @agent.running? && "bg-success",
              !@agent.running? && "bg-base-content/25"
            ]} />
            <span class={agent_badge_class(@agent.status)}>
              {humanize_value(@agent.status)}
            </span>
          </div>
        </div>

        <div class="mt-2 flex flex-wrap gap-2 text-[11px] text-base-content/55">
          <span
            :if={@agent.runtime_type != "external"}
            class="rounded-full bg-base-200 px-2 py-0.5"
          >
            {@agent.primary_model}
          </span>
          <span class={source_badge_class(@agent.source)}>
            {humanize_value(@agent.source_label)}
          </span>
          <span
            :if={@agent.runtime_type == "external"}
            class="inline-flex items-center gap-1 rounded-full bg-info/15 px-2 py-0.5 text-info"
          >
            <span class="hero-globe-alt h-3 w-3" /> Federated
          </span>
        </div>
      </.link>
    </article>
    """
  end
end
