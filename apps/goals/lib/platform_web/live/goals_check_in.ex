defmodule PlatformWeb.GoalsCheckIn do
  @moduledoc "The queued check-in and its recorded choices, hosted by GoalsLive (Goals 6/8)."
  use PlatformWeb, :html
  alias Platform.Goals
  alias PlatformWeb.GoalsPage

  def load(user, page, id) do
    goal = page.card.goal

    with {:ok, ask} <- Goals.get_ask(user, id),
         true <-
           ask.kind == "question" and ask.goal_id == goal.id and user.id in ask.addressed_user_ids,
         {:ok, clock} <- Goals.clock_status(user, goal.id) do
      owner = Platform.Accounts.get_user(goal.owner_user_id)

      {:ok,
       %{
         kind: :check,
         ask: ask,
         answer: Enum.find(ask.answers, &(&1.user_id == user.id)),
         goal: goal,
         coach: page.coach,
         owner_first: first_name(owner && owner.name),
         takeaways: Map.new(page.takeaways, &{&1.id, &1.title}),
         next_wake_at: clock && clock.next_wake_at
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  attr(:screen, :map, required: true)
  attr(:choices, :map, default: %{})

  def screen(assigns) do
    assigns = assign(assigns, :done, final_answer?(assigns.screen.answer))

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goals-check-in" data-ask-id={@screen.ask.id}>
      <a
        href={goal_href(@screen.goal)}
        class="focus-visible-ring -ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive"
      >
        ‹ {@screen.goal.title}
      </a>
      <div :if={!@done}>
        <span class="rounded-md bg-warning-dim px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content">
          Check-in
        </span>
        <h2 class="mt-2 text-2xl font-bold text-base-content">{@screen.ask.title}</h2>
        <p class="mt-1 text-sm text-subtle">
          Drafted by <.coach coach={@screen.coach} /> for {@screen.owner_first}
        </p>
        <div :if={@screen.ask.body} class={[GoalsPage.card_class(), "mt-4"]}>
          <p class="whitespace-pre-line text-base text-base-content">{@screen.ask.body}</p>
        </div>
        <section :if={(@screen.ask.payload["moved"] || []) != []}>
          <h3 class={heading_class()}>What moved</h3>
          <ul class={[GoalsPage.card_class(), "space-y-2 text-sm text-base-content"]}>
            <li :for={moved <- @screen.ask.payload["moved"]} class="flex gap-2">
              <b class={direction_class(moved["direction"])}>{direction(moved["direction"])}</b><span>{moved["text"]}</span>
            </li>
          </ul>
        </section>
        <section :if={suggestions(@screen) != []}>
          <h3 class={heading_class()}>
            {coach_name(@screen.coach)} suggests · {length(suggestions(@screen))}
          </h3>
          <ul class="space-y-3">
            <li
              :for={{suggestion, index} <- Enum.with_index(suggestions(@screen))}
              data-role="goal-suggestion"
              data-index={index}
            >
              <div class={GoalsPage.card_class()}>
                <h4 class="text-base font-semibold text-base-content">{suggestion["title"]}</h4>
                <p :if={suggestion["why"]} class="mt-1 text-sm text-subtle">{suggestion["why"]}</p>
                <a
                  :if={@screen.takeaways[suggestion["takeaway_id"]]}
                  href={GoalsPage.read_href(@screen.goal, suggestion["takeaway_id"])}
                  class={[GoalsPage.link_class(), "mt-1 inline-block text-sm"]}
                >
                  From: {@screen.takeaways[suggestion["takeaway_id"]]}
                </a>
                <div class="mt-3 flex flex-wrap gap-2">
                  <button
                    :for={{choice, label} <- [{"do", "Do it"}, {"not_now", "Not now"}]}
                    type="button"
                    phx-click="check_choice"
                    phx-value-index={index}
                    phx-value-choice={choice}
                    data-action="check-choice"
                    aria-pressed={@choices[index] == choice}
                    class={[
                      "focus-visible-ring min-h-11 rounded-full px-3 text-sm lg:min-h-8",
                      if(@choices[index] == choice,
                        do: "border border-transparent bg-base-300 text-base-content",
                        else: "border border-edge text-subtle"
                      )
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </section>
        <div class="mt-4 flex flex-wrap items-center gap-3">
          <button
            type="button"
            class={primary_class()}
            phx-click="check_finish"
            data-action="check-finish"
          >
            Finish check-in
          </button>
          <p class="text-xs text-subtle">
            Your choices update the plan. Nothing changes until you finish.
          </p>
        </div>
      </div>
      <div :if={@done} data-role="goals-check-done">
        <div class={GoalsPage.card_class()}>
          <span class="rounded-md bg-success-dim px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content">
            Check-in done
          </span>
          <h4 class="mt-2 text-base font-semibold text-base-content">Your choices are in.</h4>
          <ul class="mt-3 space-y-2 text-sm text-base-content">
            <li :for={{suggestion, index} <- Enum.with_index(suggestions(@screen))}>
              {if recorded_choice(@screen, index) == "do", do: "Do it", else: "Not now"}: {suggestion[
                "title"
              ]}
            </li>
          </ul>
          <p class="mt-3 text-sm text-subtle">
            {coach_name(@screen.coach)} will report back {next_check_in(@screen.next_wake_at)}
          </p>
        </div>
        <a href={goal_href(@screen.goal)} class={[primary_class(), "mt-4"]}>Back to the goal</a>
      </div>
    </div>
    """
  end

  attr(:coach, :any, default: nil)

  def coach(assigns) do
    ~H"""
    <span data-agent-slot={@coach && @coach.slot} class="font-semibold text-(--ag-text)">
      {coach_name(@coach)}
    </span>
    """
  end

  def coach_name(nil), do: "Your coach"
  def coach_name(coach), do: coach.name
  def heading_class, do: "mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
  def primary_class, do: "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0 btn-primary"
  def goal_href(goal), do: "/m/goals?goal=#{goal.id}"
  def suggestions(screen), do: screen.ask.payload["suggestions"] || []
  def final_answer?(answer), do: not is_nil(answer) and answer.answer in ["used", "declined"]

  defp recorded_choice(screen, index),
    do:
      Enum.find_value(screen.answer.details["choices"] || [], "not_now", fn c ->
        if c["index"] == index, do: c["choice"]
      end)

  defp next_check_in(nil), do: "at the next check-in."
  defp next_check_in(datetime), do: "at next " <> weekday(datetime) <> "'s check-in."

  def weekday(datetime),
    do:
      datetime
      |> DateTime.shift_zone!(Platform.Memory.Insights.Disseminator.timezone())
      |> Calendar.strftime("%A")

  defp first_name(name) when is_binary(name), do: name |> String.split() |> List.first()
  defp first_name(_), do: "you"
  defp direction("up"), do: "↑"
  defp direction("down"), do: "↓"
  defp direction(_), do: "→"
  defp direction_class("up"), do: "font-bold text-success"
  defp direction_class("down"), do: "font-bold text-error"
  defp direction_class(_), do: "font-bold text-subtle"
end
