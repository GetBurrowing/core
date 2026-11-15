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

  The list (`PlatformWeb.GoalsList`, stage 2) matches the agreed prototype
  (canvas 01a15ef6, Goals prototype v4): Inbox's two panes at `lg` and up,
  the phone list below. The goal view is still stage 1's plain one; stages
  3 and 4 build the goal page and Open up.

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
    4. Stage 1 only: the goal view is plain (title, whose goal, the coach,
       the next stop, who it is open to). The prototype's journey, number
       and Open up sheet come in stages 3 and 4.

  Stage 2 (the list, `PlatformWeb.GoalsList`):

    5. No status pill ("On track", "A little behind"): pacing belongs to
       Goals 8/8.
    6. No "New goal" button (desktop) or chip (phone): Goals 5/8 adds them.
       An empty `data-goals-slot="new-goal"` element marks each place.
    7. Row times read "Updated 3h ago" / "Added Oct 2" (core's
       `InboxItem.relative_time/1`), not the canvas's clock time "7:00":
       the nested page gets no viewer time zone from core.
    8. Every row carries a privacy chip ("Only you", "Shared: {names}",
       "Shared by {owner}"), which the canvas does not show: the ticket
       requires a privacy badge on every row. On phone it sits on line 3
       after the kind words.
    9. Kind line precedence: someone else's goal reads "Shared by {owner}"
       (not in the canvas); an opened goal of yours reads "Shared with
       {names}" even when it has a coach; then "{coach} leads / coaches /
       advises" ("advises" is not in the canvas); else your first name.
   10. A goal with a target but no reading (no source, an unknown source,
       a source that refuses, no reading yet) reads "Target: {target}
       {unit}" (not in the canvas). An empty list shows core's minimal
       empty state "No goals yet" (not in the canvas).
   11. Phone "Back to More" clicks the bottom bar's More tab, because the
       sheet's `open_more_sheet` event belongs to core's parent page and a
       nested LiveView cannot push to it.
  """
  use PlatformWeb, :live_view

  alias Platform.Goals
  alias PlatformWeb.ExtensionPageLive.NotFoundError
  alias PlatformWeb.GoalsList

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])

    socket =
      socket
      |> assign(:user, user)
      |> assign(:rows, GoalsList.rows(user, list_cards(user)))

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
    <div class="relative flex h-full min-h-0" data-role="goals-page">
      <%!-- Below lg the phone list is the screen; with a goal open it steps
           aside for the goal view (Inbox's breakpoints). --%>
      <div :if={is_nil(@card)} class="min-w-0 flex-1 lg:hidden">
        <GoalsList.phone_list rows={@rows} />
      </div>
      <%!-- Two panes at lg and up: the list as a 380px column. --%>
      <div
        class="h-full min-w-0 flex-1 overflow-y-auto clears-tab-bar max-lg:hidden lg:w-95 lg:flex-none lg:border-r lg:border-edge lg:bg-base-100"
        data-role="goals-list"
      >
        <GoalsList.desktop_list rows={@rows} selected_id={@card && @card.goal.id} />
      </div>
      <section
        class={[
          "min-w-0 flex-1 overflow-auto bg-base-200",
          is_nil(@card) && "max-lg:hidden"
        ]}
        data-role="goals-detail-pane"
        aria-label="Goal"
      >
        <p
          :if={is_nil(@card)}
          class="flex h-full items-center justify-center p-6 text-sm text-subtle"
          data-role="goals-detail-empty"
        >
          Select a goal
        </p>
        <.goal_view :if={@card} card={@card} />
      </section>
    </div>
    """
  end

  # Stage 1's plain goal view; stage 3 builds the canvas goal page.
  attr :card, :map, required: true

  defp goal_view(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goal-view" data-goal-id={@card.goal.id}>
      <.link navigate="/m/goals" class="text-sm text-primary lg:hidden" data-role="goal-back">
        Goals
      </.link>
      <h2 class="mt-2 text-2xl font-semibold text-base-content">{@card.goal.title}</h2>
      <p :if={@card.goal.why} class="mt-1 text-subtle">{@card.goal.why}</p>
      <p class="mt-2 text-sm text-subtle" data-role="goal-byline">
        {owner_line(@card)}<span :if={@card.coach_name}> · {@card.coach_name} {coach_verb(@card.goal)}</span>
      </p>

      <div class="mt-3 text-sm" data-role="goal-audience">
        <%= cond do %>
          <% @card.audience == :hidden -> %>
            <span class="text-subtle">Opened to you</span>
          <% @card.audience == [] -> %>
            <span class="badge badge-ghost">Only you</span>
          <% true -> %>
            <span class="text-subtle">Open to</span>
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
        class="mt-4 rounded-lg border border-edge bg-base-100 px-3 py-3"
        data-role="goal-current-stop"
      >
        <span class="block text-xs uppercase tracking-wide text-subtle">Next stop</span>
        <span class="block font-medium text-base-content">{@card.current_stop.label}</span>
      </div>
    </div>
    """
  end

  defp owner_line(%{role: :owner}), do: "Your goal"
  defp owner_line(%{owner_name: owner}), do: "#{owner}'s goal"

  defp coach_verb(%{agent_mode: "do"}), do: "leads"
  defp coach_verb(%{agent_mode: "coach"}), do: "coaches"
  defp coach_verb(_goal), do: "advises"
end
