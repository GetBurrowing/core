defmodule PlatformWeb.GoalsWork do
  @moduledoc "Coach and contributors shared by the goal page and space card."
  use Phoenix.Component
  alias PlatformWeb.AvatarComponents

  attr :agent, :map, required: true
  attr :verb, :string, default: nil
  def agent(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-sm" data-agent-slot={@agent.slot}>
      <AvatarComponents.agent_avatar name={@agent.name} avatar_url={@agent.avatar_url} size="xs" />
      <span><span class="font-semibold text-(--ag-text)">{@agent.name}</span> <span class="text-subtle">{@verb}</span></span>
    </span>
    """
  end

  def verb("do"), do: "leads"
  def verb("coach"), do: "coaches"
  def verb(_), do: "advises"
  def status("blocked"), do: "Blocked"
  def status("done"), do: "Done"
  def status("cancelled"), do: "Cancelled"
  def status(_), do: "Open"

  attr :page, :map, required: true
  def section(assigns) do
    ~H"""
    <section :if={@page.coach} data-role="goal-workers">
      <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle">Who's working on it</h3>
      <div class={PlatformWeb.GoalsPage.card_class()}>
        <div class="flex flex-wrap items-center gap-3" data-role="goal-worker-agents">
          <.agent agent={@page.coach} verb={verb(@page.card.goal.agent_mode)} />
          <.agent :for={contributor <- @page.contributors} agent={Map.fetch!(@page.authors.agents, contributor.agent_id)} />
        </div>
        <ul :if={@page.tasks != []} class="mt-3 divide-y divide-edge">
          <li :for={task <- @page.tasks} class="py-2 text-sm" data-role="goal-worker-task">
            <span class="font-semibold text-base-content">{task.title}</span>
            <span class="ml-2 text-subtle">{status(task.status)} · {task.assignee_name || "Unassigned"}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end
end
