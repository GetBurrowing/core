defmodule PlatformWeb.GoalsRetro do
  @moduledoc "The stored retro, presented through Goals context reads only (Goals 8/8 stage 5)."
  use PlatformWeb, :html
  alias Platform.Goals
  alias PlatformWeb.{GoalsPage, GoalsCheckIn, GoalsComponents, GoalsBriefCards}

  def load(user, page, id) do
    with {:ok, retro} <- Goals.get_retro(user, page.card.goal.id, id) do
      {:ok,
       Map.merge(retro, %{
         kind: :retro,
         page: page,
         goal: page.card.goal,
         coach: page.coach,
         owner?: page.card.role == :owner,
         titles: Map.new(page.actions ++ page.takeaways, &{&1.id, &1.title})
       })}
    end
  end

  attr(:screen, :map, required: true)
  attr(:sent, :boolean, default: false)

  def screen(assigns) do
    details = assigns.screen.entry.details

    assigns =
      assign(assigns,
        details: details,
        worked: details["worked"] || [],
        didnt: details["didnt_work"] || [],
        dropped: details["dropped"] || [],
        learned: details["learned"] || [],
        push: details["next_push"]
      )

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goals-retro" data-entry-id={@screen.entry.id}>
      <a href={goal_href(@screen.goal)} class="focus-visible-ring -ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive">‹ {@screen.goal.title}</a>
      <div><span class={GoalsPage.tag_class()}>Looking back</span></div>
      <h2 class="mt-2 text-2xl font-bold text-base-content">{@screen.entry.title}</h2>
      <p class="mt-1 text-sm text-subtle">Written by <GoalsCheckIn.coach coach={@screen.coach} /></p>
      <div class={[GoalsPage.card_class(), "mt-4"]}>
        <p class="whitespace-pre-line text-base text-base-content">{@screen.entry.body}</p>
        <GoalsPage.journey :if={@screen.page.stops != []} page={@screen.page} small next_push={not is_nil(@push)} />
      </div>
      <section :if={@worked != []} data-role="retro-worked">
        <h3 class={GoalsCheckIn.heading_class()}>{breakdown(@screen.stop)}</h3>
        <div class={GoalsPage.card_class()}>
          <div :for={row <- @worked} class="mb-3 last:mb-0">
            <div class="flex justify-between text-sm text-base-content"><span>{row["label"]}</span><b :if={not is_nil(row["percent"])} class="tabular-nums">{row["percent"]}%</b></div>
            <div :if={not is_nil(row["percent"])} class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-300"><div class="h-full bg-primary" style={"width: #{row["percent"]}%"}></div></div>
            <p :if={row["note"]} class="mt-1 text-xs text-subtle">{row["note"]}</p>
          </div>
        </div>
      </section>
      <section :if={@didnt != [] or @dropped != []} data-role="retro-didnt-work">
        <h3 class={GoalsCheckIn.heading_class()}>What didn't work</h3>
        <ul class={[GoalsPage.card_class(), "space-y-2 text-sm text-base-content"]}>
          <li :for={row <- @didnt}>{row["text"]}</li>
          <li :for={row <- @dropped}>Dropped: {@screen.titles[row["entry_id"]]}<span :if={row["reason"]}> · {row["reason"]}</span></li>
        </ul>
      </section>
      <section :if={@learned != []} data-role="retro-learned">
        <h3 class={GoalsCheckIn.heading_class()}>What we learned</h3>
        <ul class={[GoalsPage.card_class(), "space-y-2 text-sm text-base-content"]}>
          <li :for={line <- @learned} class="flex gap-2"><.icon name="hero-check-circle" class="size-4 shrink-0 text-success" /><span>{line}</span></li>
        </ul>
      </section>
      <section :if={@screen.verdicts != []} data-role="retro-predictions">
        <h3 class={GoalsCheckIn.heading_class()}>How the predictions did</h3>
        <div class={GoalsPage.card_class()}>
          <div :for={row <- @screen.verdicts} class="mb-3 last:mb-0" data-role="retro-prediction" data-verdict={row["verdict"]}>
            <p class="text-sm text-base-content">{row["prediction"]}</p>
            <.verdict_pill verdict={row["verdict"]} />
            <p :if={row["predicted_change"] && row["actual_change"] && row["predicted_by"]} class="mt-1 text-xs text-subtle" data-role="retro-prediction-number">
              Expected {format(row["predicted_change"])} {@screen.goal.unit} by {date(row["predicted_by"])}. It moved {format(row["actual_change"])}.
            </p>
          </div>
        </div>
      </section>
      <section :if={@push} data-role="retro-next-push">
        <h3 class={GoalsCheckIn.heading_class()}>Next push: {@push["title"]} · {GoalsCheckIn.coach_name(@screen.coach)}'s suggestion</h3>
        <ul class="space-y-3">
          <li :for={row <- @push["suggestions"] || []} class={GoalsPage.card_class()}>
            <span class={["rounded-md px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content", suggestion_class(row["tag"])]}>{String.capitalize(row["tag"])}</span>
            <h4 class="mt-2 text-base font-semibold text-base-content">{row["title"]}</h4>
            <p :if={row["why"]} class="mt-1 text-sm text-subtle">{row["why"]}</p>
            <a :if={@screen.page.takeaway_titles[row["takeaway_id"]]} href={GoalsPage.read_href(@screen.goal, row["takeaway_id"])} class={[GoalsPage.link_class(), "mt-1 inline-block text-sm"]}>From: {@screen.page.takeaway_titles[row["takeaway_id"]]}</a>
          </li>
        </ul>
      </section>
      <div :if={@screen.stalled} class={[GoalsPage.card_class(), "mt-6 text-sm font-bold text-base-content"]}>The number has not moved across {@screen.flat_retros} retros.</div>
      <.change :if={@screen.change} screen={@screen} />
      <section :if={@screen.owner? && @screen.coach} data-role="retro-ask">
        <h3 class={GoalsCheckIn.heading_class()}>Ask {GoalsCheckIn.coach_name(@screen.coach)} about this</h3>
        <div class={GoalsPage.card_class()}>
          <GoalsBriefCards.question_box :if={!@sent} id={@screen.entry.id} coach_name={GoalsCheckIn.coach_name(@screen.coach)} event="retro_question" cancel={false} />
          <p :if={@sent} class="text-sm text-subtle">Sent. {GoalsCheckIn.coach_name(@screen.coach)} answers at the next check-in.</p>
        </div>
      </section>
    </div>
    """
  end

  attr(:screen, :map, required: true)

  defp change(assigns) do
    assigns = assign(assigns, :goal?, assigns.screen.change.kind == :goal)

    ~H"""
    <section data-role="retro-change">
      <h3 class={GoalsCheckIn.heading_class()}>{if @goal?, do: "Change the goal?", else: "Change how we check in?"}</h3>
      <div class={GoalsPage.card_class()}>
        <p class="text-sm text-base-content">{@screen.change.summary}</p>
        <div class="mt-2 text-xs text-subtle"><p>Switch changes:</p><p :for={line <- @screen.change.lines}>{line}</p></div>
        <div :if={@screen.can_decide?} class="mt-3 flex gap-2">
          <button :for={{event, label} <- [{"retro_switch", if(@goal?, do: "Change the goal", else: "Switch")}, {"retro_keep", if(@goal?, do: "Keep the goal", else: "Keep it")}]}
            type="button" phx-click={event} phx-value-entry_id={@screen.entry.id}
            class="focus-visible-ring min-h-11 rounded-full border border-edge px-3 text-sm text-subtle lg:min-h-8">{label}</button>
        </div>
        <p class="mt-2 text-xs text-subtle" data-role="retro-change-result">{result(@screen.change, @goal?)}</p>
      </div>
    </section>
    """
  end

  attr(:verdict, :string, required: true)

  def verdict_pill(assigns) do
    {label, color} =
      case assigns.verdict do
        "came_true" -> {"Came true", "bg-success-dim"}
        "did_not" -> {"Didn't happen", "bg-warning-dim"}
        "too_early" -> {"Too early to tell", "bg-warning-dim"}
        "not_scored" -> {"Not scored", "bg-base-300"}
        _ -> {"Couldn't measure", "bg-base-300"}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span class={["inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold text-base-content", @color]}>{@label}</span>
    """
  end

  defp result(%{state: :switched, lines: lines}, goal?),
    do: if(goal?, do: "Changed. ", else: "Switched. ") <> Enum.join(lines, ". ")

  defp result(%{state: :kept}, goal?),
    do: if(goal?, do: "The goal stays as it is.", else: "The check-in stays as it is.")

  defp result(_, goal?),
    do:
      if(goal?,
        do: "The goal stays as it is until you choose.",
        else: "The check-in stays as it is until you choose."
      )

  defp suggestion_class("keep"), do: "bg-success-dim"
  defp suggestion_class("start"), do: "bg-info-dim"
  defp suggestion_class(_), do: "bg-base-300"

  defp breakdown(%{target_value: %Decimal{} = n}),
    do: "Where the #{GoalsComponents.format_number(n)} came from"

  defp breakdown(_), do: "What worked"
  defp format(n), do: n |> Decimal.new() |> GoalsComponents.format_number()
  defp date(d), do: d |> Date.from_iso8601!() |> Calendar.strftime("%-d %b")
  defp goal_href(goal), do: "/m/goals?goal=#{goal.id}"
end
