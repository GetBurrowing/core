defmodule PlatformWeb.GoalsSpaceCardComponent do
  @moduledoc "Every click re-reads its actor and addresses the card by the renderer's canvas id."
  use Phoenix.LiveComponent
  alias Platform.Goals
  alias PlatformWeb.{GoalsPage, GoalsWork}

  @impl true
  def mount(socket), do: {:ok, assign(socket, notice: nil, view: nil, page: nil)}
  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(Map.take(assigns, [:id, :canvas_id, :viewer])) |> refresh()}

  defp actor({:user, id}), do: Platform.Accounts.get_user(id)
  defp actor({:agent, id}), do: %Platform.Agents.Agent{id: id}
  defp actor(_), do: nil

  defp refresh(socket) do
    actor = actor(socket.assigns.viewer)

    with {:ok, view} <- Goals.space_card(actor, socket.assigns.canvas_id),
         {:ok, page} <- GoalsPage.card_data(actor, view.card, view.number) do
      badge =
        case view.card.audience do
          [%{type: :space, id: id}] when id == view.space.id -> "Shown in ##{view.space.name}"
          audience -> "Shared: " <> Enum.map_join(audience, ", ", & &1.name)
        end

      assign(socket, view: view, page: page, badge: badge)
    else
      _ -> assign(socket, view: nil, page: nil)
    end
  end

  @impl true
  def handle_event(event, _params, socket)
      when event in ["goal_card_hand", "goal_card_take_back"] do
    user =
      case socket.assigns.viewer do
        {:user, id} -> Platform.Accounts.get_user(id)
        _ -> nil
      end

    result =
      with %{} <- user,
           {:ok, view} <- Goals.space_card(user, socket.assigns.canvas_id) do
        if event == "goal_card_hand",
          do: Goals.hand_goal_to_space(user, view.card.goal.id, view.space.id),
          else: Goals.take_goal_back(user, view.card.goal.id, view.space.id)
      end

    notice =
      if match?({:ok, _}, result), do: nil, else: "You can't hand this goal to the agents here."

    {:noreply, socket |> assign(notice: notice) |> refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-edge bg-base-100 px-4 py-3.5" data-role="goal-space-card">
      <%= if @view do %>
        <h4 class="text-base font-semibold text-base-content" data-role="goal-card-title">{@view.card.goal.title}</h4>
        <p class="mt-1 text-sm text-subtle" data-role="goal-card-meta"><GoalsPage.meta page={@page} /></p>
        <span class="chip-soft chip-success mt-2" data-role="goal-card-badge">{@badge}</span>
        <p class="mt-2 text-sm text-base-content" data-role="goal-card-number"><GoalsPage.number_sentence number={@page.number} /></p>
        <span :if={@page.number.kind == :reading} class="mt-1.5 block h-1.5 w-full overflow-hidden rounded-box bg-base-300" data-role="goal-card-progress" aria-hidden="true">
          <i class="block h-full rounded-box bg-success" style={"width: #{@page.number.pct || 0}%"}></i>
        </span>
        <div class="mt-3 space-y-2 text-sm" data-role="goal-card-agents">
          <p class="font-semibold text-base-content">Agents on this goal</p>
          <GoalsWork.agent :if={@page.coach} agent={@page.coach} verb={GoalsWork.verb(@view.card.goal.agent_mode)} />
          <div :if={@view.handed?} class="flex flex-wrap gap-3">
            <GoalsWork.agent :for={contributor <- @view.contributors} agent={Map.fetch!(@page.authors.agents, contributor.agent_id)} />
          </div>
          <p :if={!@view.handed?} class="text-subtle">Not handed to this space's agents yet</p>
        </div>
        <div class="mt-3 flex flex-wrap items-center gap-2" data-role="goal-card-controls">
          <%= if @view.handed? do %>
            <span class="text-sm text-subtle">Handed to this space's agents</span>
            <button :if={@view.can_take_back?} type="button" phx-click="goal_card_take_back" phx-target={@myself} class="btn btn-ghost btn-sm min-h-11 lg:min-h-0">Take back</button>
          <% else %>
            <button :if={@view.can_hand?} type="button" phx-click="goal_card_hand" phx-target={@myself} class="btn btn-primary btn-sm min-h-11 lg:min-h-0">Hand to this space's agents</button>
            <p :if={@view.hand_blocker == :no_coach} class="text-sm text-subtle">Pick a coach on the goal page first</p>
            <p :if={@view.hand_blocker == :coach_not_in_space} class="text-sm text-subtle">Add {@view.card.coach_name} to this space first</p>
          <% end %>
          <.link navigate={"/m/goals?goal=#{@view.card.goal.id}"} class="rounded font-semibold text-interactive focus-visible-ring">Open goal</.link>
        </div>
      <% else %>
        <p class="text-sm text-subtle">This goal isn't shown here.</p>
      <% end %>
      <p :if={@notice} role="alert" class="mt-2 text-sm text-error" data-role="goal-card-notice">{@notice}</p>
    </div>
    """
  end
end
