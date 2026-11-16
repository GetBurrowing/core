defmodule PlatformWeb.GoalsIdea do
  @moduledoc "The coach's queued idea, recording intent before the next check-in (Goals 6/8)."
  use PlatformWeb, :html
  alias Platform.Goals
  alias PlatformWeb.{GoalsCheckIn, GoalsPage}

  def load(user, page, id) do
    goal = page.card.goal

    with {:ok, ask} <- Goals.get_ask(user, id),
         true <-
           ask.kind == "offer" and ask.goal_id == goal.id and user.id in ask.addressed_user_ids and
             is_map(ask.payload["idea"]) do
      {:ok,
       %{
         kind: :idea,
         ask: ask,
         answer: Enum.find(ask.answers, &(&1.user_id == user.id)),
         goal: goal,
         coach: page.coach,
         takeaways: Map.new(page.takeaways, &{&1.id, &1.title})
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  attr(:screen, :map, required: true)

  def screen(assigns) do
    assigns =
      assign(assigns,
        idea: assigns.screen.ask.payload["idea"],
        done: GoalsCheckIn.final_answer?(assigns.screen.answer)
      )

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goals-idea" data-ask-id={@screen.ask.id}>
      <a
        href={GoalsCheckIn.goal_href(@screen.goal)}
        class="focus-visible-ring -ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive"
      >
        ‹ {@screen.goal.title}
      </a>
      <span class="rounded-md bg-info-dim px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content">
        Idea
      </span>
      <h2 class="mt-2 text-2xl font-bold text-base-content">{@screen.ask.title}</h2>
      <p class="mt-1 text-sm text-subtle">
        An idea from <GoalsCheckIn.coach coach={@screen.coach} />
      </p>
      <h3 class={GoalsCheckIn.heading_class()}>Why</h3>
      <div class={GoalsPage.card_class()}>
        <p class="whitespace-pre-line text-sm text-base-content">{@idea["why"]}</p>
        <a
          :if={@screen.takeaways[@idea["takeaway_id"]]}
          href={GoalsPage.read_href(@screen.goal, @idea["takeaway_id"])}
          class={[GoalsPage.link_class(), "mt-1 inline-block text-sm"]}
        >
          From: {@screen.takeaways[@idea["takeaway_id"]]}
        </a>
      </div>
      <h3 class={GoalsCheckIn.heading_class()}>How we'll know it works</h3>
      <div class={GoalsPage.card_class()}>
        <p class="whitespace-pre-line text-sm text-base-content">{@idea["measure"]}</p>
      </div>
      <h3 class={GoalsCheckIn.heading_class()}>
        What {GoalsCheckIn.coach_name(@screen.coach)} would do first
      </h3>
      <div class={GoalsPage.card_class()}>
        <ul class="space-y-2 text-sm text-base-content">
          <li :for={step <- @idea["steps"]} class="flex gap-2">
            <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0 text-subtle" /><span>
              {step}
            </span>
          </li>
        </ul>
      </div>
      <div :if={!@done} class="mt-4 flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="idea_answer"
          phx-value-answer="used"
          data-action="idea-used"
          class={GoalsCheckIn.primary_class()}
        >
          Start trying it
        </button>
        <button
          type="button"
          phx-click="idea_answer"
          phx-value-answer="declined"
          data-action="idea-declined"
          class="btn btn-sm min-h-11 focus-visible-ring btn-ghost text-subtle lg:min-h-0 lg:hover:text-base-content"
        >
          Not now
        </button>
      </div>
      <p
        :if={@done}
        data-role="goal-idea-receipt"
        class={
          if @screen.answer.answer == "used",
            do: "mt-4 flex items-center gap-1 text-sm font-bold text-success",
            else: "mt-4 text-sm text-subtle"
        }
      >
        <.icon :if={@screen.answer.answer == "used"} name="hero-check" class="size-4" />{if @screen.answer.answer ==
                                                                                              "used",
                                                                                            do:
                                                                                              "Trying it",
                                                                                            else:
                                                                                              "Saved for later"}
      </p>
    </div>
    """
  end
end
