defmodule PlatformWeb.ConnectAiPanelHostLive do
  @moduledoc """
  A bare LiveView that hosts one `PlatformWeb.ConnectAi.Panel` for tests
  (task 01a1b84b stage 1), the way the builder step and the agent page do:
  it subscribes to agent-host status and refreshes the panel on each change.

  Session: `"agent_id"` and `"user_id"`; `"prefix"` optional (default
  `"agent-ai"`).
  """
  use PlatformWeb, :live_view

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias PlatformWeb.ConnectAi.Panel

  @panel_id "agent-ai-panel"

  @doc "The panel's component id."
  def panel_id, do: @panel_id

  @impl true
  def mount(_params, %{"agent_id" => agent_id, "user_id" => user_id} = session, socket) do
    if connected?(socket), do: Platform.AgentHost.subscribe()

    {:ok,
     socket
     |> assign(:agent, Repo.get!(Agent, agent_id))
     |> assign(:user, Repo.get!(User, user_id))
     |> assign(:prefix, Map.get(session, "prefix", "agent-ai"))}
  end

  # The page's own events: none. Anything sent here is refused and only its
  # name is logged.
  @impl true
  def handle_event(event, _params, socket) do
    require Logger
    Logger.warning("[ConnectAiPanelHostLive] refused unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_host_status, _event}, socket) do
    Panel.refresh(@panel_id)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={Panel}
      id="agent-ai-panel"
      target={@agent}
      current_user={@user}
      prefix={@prefix}
    />
    """
  end
end
