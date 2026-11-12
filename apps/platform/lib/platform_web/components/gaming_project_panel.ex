defmodule PlatformWeb.Components.GamingProjectPanel do
  @moduledoc "Read-only game project context beside the existing co-development chat."
  use PlatformWeb, :html
  attr :space, :any, default: nil
  attr :user, :any, default: nil
  attr :participants, :list, default: []
  attr :agents, :map, default: %{}

  def panel(assigns) do
    project = Platform.Gaming.workspace_project(assigns.space, assigns.user)
    engine = if project, do: project.tech_stack["engine"] || project.config["engine"]
    engine = if is_binary(engine), do: String.slice(engine, 0, 80), else: nil
    assigns = assigns |> assign(:project, project) |> assign(:engine, engine)
      |> assign(:project_agents, Enum.filter(assigns.participants, &(&1.participant_type == "agent")))
    ~H"""
    <aside :if={@project} id="gaming-project-context" class="cg-project-context" aria-label="Game project context">
      <span class="cg-badge">IN CREATE</span><h2>{@project.name}</h2>
      <section class="cg-context-card"><h3>Engine</h3><b>{if @engine, do: @engine, else: "Choose your engine"}</b><p>{if @engine, do: "Configured for this project. Engine connection is managed by your workspace tools.", else: "Godot, Unreal or Unity — configure the engine with your project’s agents."}</p></section>
      <section class="cg-context-card"><h3>Project agents</h3>
        <div :for={agent <- @project_agents} class="cg-context-agent"><span class="cg-avatar"><.icon name="hero-cpu-chip" /></span><b>{agent_name(agent, @agents)}</b></div>
        <p :if={@project_agents == []}>Invite your agents to this channel for design, levels, art, sound and code.</p>
        <a class="cg-text-link" href="/control">Manage agents<.icon name="hero-arrow-up-right" /></a>
      </section>
      <a class="cg-button cg-ghost" href={"/files/#{@project.id}"}>Project files</a>
      <a class="cg-button cg-ghost" href="/tasks">Tasks</a>
      <a class="cg-text-link" href="/play?mode=create">All game projects<.icon name="hero-arrow-left" /></a>
    </aside>
    """
  end

  defp agent_name(participant, agents) do
    case Map.get(agents, participant.participant_id) do
      %{name: name} when is_binary(name) -> name
      _ -> participant.display_name || "Project agent"
    end
  end
end
