defmodule PlatformWeb.GoalsLive do
  @moduledoc """
  The Goals screen (task 01a1dfc1, Goals 4/8), nested by core's generic
  `/m/<prefix>` page (`Platform.Extension.live_pages/0`,
  `Platform.Goals.Extension.live_pages/0`).

  ## Nothing is inherited from the parent page

  Core hands this LiveView `%{"user_id" => id}` plus, when the URL carried
  any, `"query"`: the URL's query as untrusted strings. It runs no
  live_session hook on it. `mount/3` re-reads the user
  (`Platform.Accounts.get_user/1`) and reads every goal through
  `Platform.Goals`, which decides who sees what in its queries. This module
  never touches the database itself (`web_layer_guard_test.exs`).

  ## One route, two views

  `/m/goals` lists the goals the user sees (`Platform.Goals.describe_goals/1`).
  `/m/goals?goal=<id>` shows one (`Platform.Goals.describe_goal/2`). Anything
  but `{:ok, card}` there raises `PlatformWeb.ExtensionPageLive.NotFoundError`,
  so a goal the user may not see, a goal that does not exist and a malformed
  id are the same 404 response, with no message that tells them apart. Rows
  link with `navigate`, so opening a goal remounts the page with the new
  query. Any `handle_event/3` a later stage adds re-reads the goal through
  the context before acting and never trusts an id from the client.

  Stage 1 renders a plain list and a plain goal view; stages 2 to 4 match
  the agreed prototype (canvas 01a15ef6, Goals prototype v4).

  ## Design deviations

  The one place deviations from the prototype are recorded; later stages
  append here and copy this list into their evidence canvas.

    1. A goal's address is `/m/goals?goal=<id>`, not a path of its own,
       because core serves one route per module (`/m/:prefix`).
    2. On phone the Goals row follows Voice and Tasks in the More sheet. On
       main Inbox is a bottom-bar tab and not a More row, where the canvas
       shows Inbox as the row above Goals.
    3. Where Social is also visible, Goals follows Social: core keeps
       extension rows in registration order.
    4. Stage 1 only: the list and the goal view are plain (title, whose
       goal, the coach, the next stop, who it is open to). The prototype's
       cards, journey, number and Open up sheet come in stages 2 to 4.
  """
  use PlatformWeb, :live_view

  alias Platform.Goals
  alias PlatformWeb.ExtensionPageLive.NotFoundError

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])

    socket =
      socket
      |> assign(:user, user)
      |> assign(:cards, list_cards(user))

    case goal_param(session["query"]) do
      nil ->
        {:ok, assign(socket, :card, nil)}

      goal_id ->
        case Goals.describe_goal(user, goal_id) do
          {:ok, card} -> {:ok, assign(socket, :card, card)}
          _ -> raise NotFoundError
        end
    end
  end

  defp goal_param(%{"goal" => id}) when is_binary(id), do: id
  defp goal_param(_query), do: nil

  defp list_cards(user) do
    case Goals.describe_goals(user) do
      {:ok, cards} -> cards
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col lg:flex-row" data-role="goals-page">
      <section
        class={[
          "min-h-0 overflow-y-auto px-4 py-4 sm:px-6 lg:w-96 lg:shrink-0 lg:border-r lg:border-base-300",
          @card && "hidden lg:block"
        ]}
        data-role="goals-list"
      >
        <h1 class="text-xl font-semibold text-base-content">Goals</h1>
        <p class="mt-1 text-sm text-base-content/70">
          What you're working towards, and how it's going. Only you see your goals until you open them up.
        </p>

        <p
          :if={@cards == []}
          class="mt-6 text-sm text-base-content/70"
          data-role="goals-empty"
        >
          No goals yet.
        </p>

        <ul :if={@cards != []} class="mt-4 space-y-2">
          <li :for={card <- @cards}>
            <.link
              navigate={"/m/goals?goal=" <> card.goal.id}
              class={[
                "flex items-start gap-3 rounded-lg border border-base-300 px-3 py-3 hover:bg-base-200",
                @card && @card.goal.id == card.goal.id && "bg-base-200"
              ]}
              data-role="goals-row"
              data-goal-id={card.goal.id}
            >
              <span class="hero-flag mt-0.5 size-5 shrink-0 text-base-content/70" aria-hidden="true">
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-xs uppercase tracking-wide text-base-content/60">
                  {byline(card)}
                </span>
                <span class="block truncate font-medium text-base-content">{card.goal.title}</span>
                <span
                  :if={card.current_stop}
                  class="block text-sm text-base-content/70"
                  data-role="goals-row-stop"
                >
                  Next stop: {card.current_stop.label}
                </span>
              </span>
            </.link>
          </li>
        </ul>
      </section>

      <section
        :if={@card}
        class="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:px-6"
        data-role="goal-view"
        data-goal-id={@card.goal.id}
      >
        <.link navigate="/m/goals" class="text-sm text-primary lg:hidden" data-role="goal-back">
          Goals
        </.link>
        <h2 class="mt-2 text-2xl font-semibold text-base-content">{@card.goal.title}</h2>
        <p :if={@card.goal.why} class="mt-1 text-base-content/70">{@card.goal.why}</p>
        <p class="mt-2 text-sm text-base-content/70" data-role="goal-byline">
          {owner_line(@card)}<span :if={@card.coach_name}> · {@card.coach_name} {coach_verb(@card.goal)}</span>
        </p>

        <div class="mt-3 text-sm" data-role="goal-audience">
          <%= cond do %>
            <% @card.audience == :hidden -> %>
              <span class="text-base-content/70">Opened to you</span>
            <% @card.audience == [] -> %>
              <span class="badge badge-ghost">Only you</span>
            <% true -> %>
              <span class="text-base-content/70">Open to</span>
              <span
                :for={item <- @card.audience}
                class="badge badge-ghost ml-1"
                data-role="goal-audience-item"
              >
                {item.name}
              </span>
          <% end %>
        </div>

        <div
          :if={@card.current_stop}
          class="mt-4 rounded-lg border border-base-300 px-3 py-3"
          data-role="goal-current-stop"
        >
          <span class="block text-xs uppercase tracking-wide text-base-content/60">Next stop</span>
          <span class="block font-medium text-base-content">{@card.current_stop.label}</span>
        </div>
      </section>

      <section
        :if={is_nil(@card)}
        class="hidden min-h-0 flex-1 items-start justify-center px-4 py-8 text-sm text-base-content/60 lg:flex"
      >
        Select a goal
      </section>
    </div>
    """
  end

  defp byline(%{role: :owner, coach_name: nil}), do: "Goal · yours"
  defp byline(%{role: :owner, coach_name: coach}), do: "Goal · #{coach} helps"
  defp byline(%{role: :coach, owner_name: owner}), do: "Goal · you coach #{owner}"
  defp byline(%{owner_name: owner}), do: "Goal · #{owner}"

  defp owner_line(%{role: :owner}), do: "Your goal"
  defp owner_line(%{owner_name: owner}), do: "#{owner}'s goal"

  defp coach_verb(%{agent_mode: "do"}), do: "leads"
  defp coach_verb(%{agent_mode: "coach"}), do: "coaches"
  defp coach_verb(_goal), do: "advises"
end
