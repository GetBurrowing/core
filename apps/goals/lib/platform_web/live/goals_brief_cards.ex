defmodule PlatformWeb.GoalsBriefCards do
  @moduledoc "Semantic card recipes for the Goals daily brief (Goals 6/8)."
  use PlatformWeb, :html
  @btn "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0"
  @btn_primary @btn <> " btn-primary"
  @btn_secondary @btn <> " border-edge bg-base-300 text-base-content"
  @btn_ghost @btn <> " btn-ghost text-subtle lg:hover:text-base-content"
  @field "w-full rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-subtle"
  @link "focus-visible-ring rounded font-semibold text-interactive"

  defp btn_primary, do: @btn_primary
  defp btn_secondary, do: @btn_secondary
  defp btn_ghost, do: @btn_ghost
  defp field, do: @field
  defp link, do: @link

  attr(:item, :map, required: true)
  attr(:target, :any, required: true)
  attr(:ask_open, :boolean, default: false)
  attr(:blank, :boolean, default: false)

  def card(assigns) do
    assigns = assign(assigns, :tag, tag(assigns.item.kind))

    ~H"""
    <article
      data-role="goals-brief-card"
      data-item-id={@item.id}
      data-kind={@item.kind}
      class="rounded-xl border border-edge bg-base-100 px-4 py-3.5"
    >
      <div class="mb-1.5 flex flex-wrap items-center gap-2">
        <span class={[
          "rounded-md px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content",
          @tag.class
        ]}>
          {@tag.label}
        </span>
      </div>
      <h4 class="text-base font-semibold text-base-content">{@item.goal.title}</h4>
      <.report :if={@item.kind == :report} {assigns} />
      <.offer :if={@item.kind == :offer} {assigns} />
      <.linked_ask :if={@item.kind in [:idea, :question]} {assigns} />
      <.footer item={@item} />
    </article>
    """
  end

  defp report(assigns) do
    ~H"""
    <p class="mt-1 text-sm text-base-content">
      <.coach item={@item} /> did this since {weekday(@item.since_at)}:
    </p>
    <ul class="mt-2 space-y-1.5 text-sm text-base-content">
      <li :for={entry <- @item.entries}>
        <div class="flex items-start gap-2">
          <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0 text-success" />
          <span class="min-w-0 flex-1">{entry.title}</span>
          <button
            :if={entry.undo == :available}
            type="button"
            class={link()}
            phx-click="undo"
            phx-target={@target}
            phx-value-item_id={@item.id}
            phx-value-entry_id={entry.id}
            phx-value-request="undo"
            data-action="undo"
          >
            Undo
          </button>
        </div>
        <div
          :if={entry.undo == :requested}
          class="ml-6 mt-1 text-sm text-subtle"
          data-role="goals-undo-requested"
        >
          <p>Undo asked for. {@item.goal.coach_name || "Your coach"} sees it at the next check-in.</p>
          <p>{entry.undo_note}</p>
          <button
            type="button"
            class={link()}
            phx-click="undo"
            phx-target={@target}
            phx-value-item_id={@item.id}
            phx-value-entry_id={entry.id}
            phx-value-request="keep"
            data-action="undo"
          >
            Cancel undo
          </button>
        </div>
        <a
          :if={entry.takeaway}
          href={"/m/goals?goal=#{@item.goal.id}&read=#{entry.takeaway.id}"}
          class={[link(), "ml-6 text-sm"]}
        >
          From: {entry.takeaway.title}
        </a>
      </li>
    </ul>
    <p :if={@item.number} class="mt-3 text-sm text-base-content">
      <b>Where we are:</b> {number(@item.number.value)} of {number(@item.number.target)} {@item.number.unit}.
    </p>
    <div :if={@item.state == :open} class="mt-3 flex flex-wrap items-center gap-2">
      <button
        type="button"
        class={btn_primary()}
        phx-click="noted"
        phx-target={@target}
        phx-value-item_id={@item.id}
        phx-value-noted="true"
        data-action="noted"
      >
        Looks good
      </button>
      <button
        type="button"
        class={btn_secondary()}
        phx-click="ask-open"
        phx-target={@target}
        phx-value-item_id={@item.id}
        data-action="ask-open"
      >
        Ask {@item.goal.coach_name || "your coach"}
      </button>
    </div>
    <div
      :if={@item.state == :done}
      class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-subtle"
      data-role="goals-brief-receipt"
    >
      <b class="inline-flex items-center gap-1 text-success">
        <.icon name="hero-check" class="size-4" /> Noted
      </b>
      <span :if={@item.next_wake_at}>Next report on {weekday(@item.next_wake_at)}.</span>
      <button
        type="button"
        class={link()}
        phx-click="noted"
        phx-target={@target}
        phx-value-item_id={@item.id}
        phx-value-noted="false"
        data-action="noted"
      >
        Undo
      </button>
      <button
        type="button"
        class={link()}
        phx-click="ask-open"
        phx-target={@target}
        phx-value-item_id={@item.id}
        data-action="ask-open"
      >
        Ask {@item.goal.coach_name || "your coach"}
      </button>
    </div>
    <form
      :if={@ask_open}
      phx-submit="ask-send"
      phx-target={@target}
      data-role="goals-brief-ask"
      class="mt-3 space-y-2"
    >
      <input type="hidden" name="item_id" value={@item.id} />
      <label class="sr-only" for={"goal-question-" <> @item.id}>
        Ask {@item.goal.coach_name || "your coach"} about this
      </label>
      <input
        id={"goal-question-" <> @item.id}
        name="question"
        type="text"
        maxlength="500"
        class={field()}
        placeholder={
          if @blank,
            do: "Type a question first",
            else: "Ask #{@item.goal.coach_name || "your coach"} about this"
        }
      />
      <div class="flex gap-2">
        <button type="submit" class={btn_primary()} data-action="ask-send">Send</button>
        <button
          type="button"
          class={btn_ghost()}
          phx-click="ask-cancel"
          phx-target={@target}
          phx-value-item_id={@item.id}
          data-action="ask-cancel"
        >
          Cancel
        </button>
      </div>
    </form>
    <div
      :for={question <- @item.questions}
      class="mt-3 text-sm text-subtle"
      data-role="goals-question-sent"
    >
      <p>Sent. {@item.goal.coach_name || "Your coach"} answers at the next check-in.</p>
      <blockquote class="mt-1 border-l-2 border-edge pl-3">{question.title}</blockquote>
    </div>
    """
  end

  defp offer(assigns) do
    ~H"""
    <p :if={@item.ask.body} class="mt-1 whitespace-pre-line text-sm text-base-content">
      {@item.ask.body}
    </p>
    <div :if={@item.state == :open} class="mt-3">
      <p class="text-sm font-semibold text-base-content">{@item.ask.title}</p>
      <div class="mt-3 flex flex-wrap items-center gap-2">
        <button
          type="button"
          class={btn_primary()}
          phx-click="answer"
          phx-target={@target}
          phx-value-item_id={@item.id}
          phx-value-answer="used"
          data-action="answer"
        >
          Use it
        </button>
        <button
          type="button"
          class={btn_ghost()}
          phx-click="answer"
          phx-target={@target}
          phx-value-item_id={@item.id}
          phx-value-answer="declined"
          data-action="answer"
        >
          Not now
        </button>
      </div>
    </div>
    <div :if={@item.state == :done} class="mt-3 text-sm" data-role="goals-brief-receipt">
      <div class="flex flex-wrap items-center gap-3">
        <b :if={@item.answer.answer == "used"} class="inline-flex items-center gap-1 text-success">
          <.icon name="hero-check" class="size-4" /> Used
        </b>
        <span :if={@item.answer.answer == "declined"} class="text-subtle">Not now.</span>
        <button
          :if={@item.withdrawable?}
          type="button"
          class={link()}
          phx-click="withdraw"
          phx-target={@target}
          phx-value-item_id={@item.id}
          data-action="withdraw"
        >
          Undo
        </button>
      </div>
      <p
        :if={@item.answer.answer == "used" && is_binary(@item.ask.payload["draft"])}
        class="mt-2 whitespace-pre-line text-base-content"
      >
        {@item.ask.payload["draft"]}
      </p>
      <a
        :if={@item.answer.answer == "used" && safe_url(@item.ask.payload["url"])}
        href={safe_url(@item.ask.payload["url"])}
        class={[link(), "mt-2 inline-block"]}
      >
        Open it
      </a>
    </div>
    """
  end

  defp linked_ask(assigns) do
    ~H"""
    <p class="mt-1 text-sm font-semibold text-base-content">{@item.ask.title}</p>
    <p :if={@item.kind == :idea} class="mt-1 text-sm text-base-content">
      <.coach item={@item} /> has a new idea to try.
    </p>
    <p :if={@item.kind == :question} class="mt-1 text-sm text-base-content">
      <.coach item={@item} /> drafted it. See what moved, and choose what to change.
    </p>
    <div :if={@item.state == :open} class="mt-3">
      <a
        href={"/m/goals?goal=#{@item.goal.id}&#{if @item.kind == :idea, do: "idea", else: "check"}=#{@item.ask.id}"}
        class={btn_primary()}
      >
        {if @item.kind == :idea, do: "Look at the idea", else: "Open the check-in"}
      </a>
    </div>
    <p
      :if={@item.state == :done}
      class={
        if @item.kind == :idea && @item.answer.answer == "declined",
          do: "mt-3 text-sm text-subtle",
          else: "mt-3 text-sm font-bold text-success"
      }
      data-role="goals-brief-receipt"
    >
      {cond do
        @item.kind == :question -> "Check-in done"
        @item.answer.answer == "used" -> "Trying it"
        true -> "Saved for later"
      end}
    </p>
    """
  end

  attr(:item, :map, required: true)

  defp coach(assigns) do
    ~H"""
    <span data-agent-slot={@item.coach_slot} class="font-semibold text-(--ag-text)">
      {@item.goal.coach_name || "Your coach"}
    </span>
    """
  end

  attr(:item, :map, required: true)

  defp footer(assigns) do
    ~H"""
    <div class="mt-3 flex flex-wrap items-center justify-between gap-2 text-sm">
      <span :if={@item.stop} class="text-subtle">
        {if @item.stop.position == 1, do: "First stop", else: "Next stop"}: {@item.stop.label}<span :if={
          Map.has_key?(@item.stop, :percent)
        }> · {@item.stop.percent}%</span>
      </span>
      <a href={"/m/goals?goal=#{@item.goal.id}&from=brief"} class={[link(), "ml-auto"]}>
        See the journey ›
      </a>
    </div>
    """
  end

  defp tag(:report), do: %{label: "Goal · progress report", class: "bg-info-dim"}
  defp tag(:offer), do: %{label: "Goal · offer", class: "bg-warning-dim"}
  defp tag(:idea), do: %{label: "Goal · idea", class: "bg-info-dim"}
  defp tag(:question), do: %{label: "Goal · check-in", class: "bg-warning-dim"}
  defp tag(:practice), do: %{label: "Goal · practice", class: "bg-success-dim"}

  defp weekday(datetime),
    do:
      datetime
      |> DateTime.shift_zone!(Platform.Memory.Insights.Disseminator.timezone())
      |> Calendar.strftime("%A")

  defp number(value) do
    [whole | fraction] = value |> Decimal.to_string(:normal) |> String.split(".")
    whole = String.replace(whole, ~r/\B(?=(\d{3})+(?!\d))/, ",")

    fraction =
      case fraction do
        [f] -> String.trim_trailing(f, "0")
        _ -> ""
      end

    if fraction == "", do: whole, else: whole <> "." <> fraction
  end

  defp safe_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        value

      _ ->
        nil
    end
  end

  defp safe_url(_), do: nil
end
