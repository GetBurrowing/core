defmodule PlatformWeb.GoalsPage do
  @moduledoc """
  The goal page (task 01a1dfc1, Goals 4/8 stage 3), built to canvas
  01a15ef6 node `p` (prototype v4), screens `goal`, `goal-es` and
  `goal-rd`. Desktop shows it in the detail pane beside the list; phone
  shows it full width with a "‹ Goals" back link. Cards, headings, tags,
  buttons, fields and the progress bar copy
  `PlatformWeb.InboxLive.BriefingComponent`'s class recipes; agent names
  and avatars use `data-agent-slot` with `text-(--ag-text)` and
  `PlatformWeb.AvatarComponents.agent_avatar/1`.

  ## Where each piece reads from

  This is the contract later Goals members write to. `load/2` makes every
  read, through `Platform.Goals` only, once per render of the page.

    * **Journey**: `Platform.Goals.list_stops/2`. Reached = `reached_on`
      set. Current = the first stop without `reached_on`. Circle: reached
      "✓"; current shows the whole-number percentage of
      `latest.value / stop.target_value` (capped at 100) when
      `goal_number/2` returns a reading and the stop has a target, else the
      short target; upcoming shows the short target (1,000 -> "1k",
      30,000 -> "30k", 1,000,000 -> "1M"), or the position when the stop
      has no target. Sub-line: "by {day month}" from `due_on`, else
      `caption`.
    * **Number sentence, progress bar and percentage**: ONE call to
      `Platform.Goals.goal_number(user, goal.id)` per render. Target is
      the current stop's `target_value`, else `goals.target_value`; unit
      `goals.unit`.
        * `{:ok, {:reading, r}}`: "**{r.latest.value}** of {target}
          {unit}." then muted "{r.source.label}."; the bar's width is the
          same percentage as the current stop's circle.
        * `{:ok, {:cannot_measure, m}}`: "Target: {target} {unit}." then
          muted "{m.source_label}." when it is not nil. No value, no bar,
          no percentage, no reason text, and nothing from `list_readings`.
        * no unit or target: "No number to follow yet".
    * **Source name in the meta line**: the `label` of the entry in
      `Platform.Goals.list_sources/1` whose `key` is `goals.source_key`;
      omitted, with its separator, when the key is nil or not listed.
      Never derived from the key.
    * **Log a value**: shown where the canvas has "Fix the count", only
      when the card's role is `:owner` or `:coach` AND the source entry has
      `kind: :logged`. Submitting calls
      `Platform.Goals.log_reading(user, goal.id, %{value: <typed string>})`
      for EVERY submit, a crafted one from a viewer included: the refusal
      is the context's. `{:error, changeset}` shows "Enter a number";
      `:source_not_logged`, `:forbidden` and `:not_found` change nothing.
    * **What we're trying**: entries of kind `action`. h4 `title`; sentence
      `prediction`, else `body`; "From: {takeaway title}" when
      `takeaway_id` is set, opening the short read focused on it; the
      doing line (the author agent's avatar and name, then `body`) only
      when the author is an agent AND a prediction is present.
    * **What we've learned** and the short read (`PlatformWeb.GoalsRead`):
      entries of kind `takeaway`: `title`, `body`, `sources` (each map's
      "name") and `details["doing"]`. Address
      `/m/goals?goal=<id>&read=<entry id or all>`.
    * **This stop is about {theme}**: the current stop's `theme` and its
      `criteria` (maps with "text", "needed", "found"); met when found >=
      needed. Absent when the stop has no theme.
    * **How we check in** (every goal): from `rhythm`, `rhythm_weekday`,
      `outreach` and `agent_mode`; the second line is omitted with no
      coach.
    * **Notebook**: `list_entries/3` for kinds wake_up, action, ask, wait,
      retro (default limit), newest first, authors from
      `Platform.Goals.entry_authors/2`. Goals 6/8 adds visible asks and their
      answer receipts, the viewer's practice streak, and Up next from
      `list_my_asks(user, goal_id: goal.id)` with `ask_brief_date/2` for the
      reader's delivering brief. A row citing a takeaway carries the trying
      card's `PlatformWeb.GoalsFromLink` (5/8). No read is in a template.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Goals
  alias PlatformWeb.AvatarComponents
  alias PlatformWeb.Components.InboxItem
  alias PlatformWeb.GoalsComponents
  alias PlatformWeb.GoalsFromLink

  @card "rounded-xl border border-edge bg-base-100 px-4 py-3.5"
  @sec_h "mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
  @tag "rounded-md bg-base-300 px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content"
  @link "focus-visible-ring rounded font-semibold text-interactive"
  @field "w-full rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-subtle"
  @btn_primary "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0 btn-primary"

  @notebook_kinds ~w(wake_up action ask wait retro)
  @notebook_tags %{
    "wake_up" => "Woke up",
    "action" => "Did",
    "ask" => "Asked",
    "wait" => "Waiting",
    "retro" => "Retro"
  }

  @doc "Shared recipes for `PlatformWeb.GoalsRead`."
  def card_class, do: @card
  def tag_class, do: @tag
  def link_class, do: @link

  # ── reads ──────────────────────────────────────────────────────────────

  @doc """
  Everything the page shows for `card`, read through `Platform.Goals`.
  `{:error, _}` when the goal stopped being visible between reads.
  """
  @spec load(term(), map()) :: {:ok, map()} | {:error, term()}
  def load(user, %{goal: goal} = card) do
    with {:ok, stops} <- Goals.list_stops(user, goal.id),
         {:ok, number} <- Goals.goal_number(user, goal.id),
         {:ok, sources} <- Goals.list_sources(user),
         {:ok, actions} <- Goals.list_entries(user, goal.id, kind: "action"),
         {:ok, takeaways} <- Goals.list_entries(user, goal.id, kind: "takeaway"),
         {:ok, notebook} <- Goals.list_entries(user, goal.id, kind: @notebook_kinds),
         {:ok, authors} <- Goals.entry_authors(user, goal.id),
         {:ok, contributors} <- Goals.list_contributors(user, goal.id),
         {:ok, tasks} <- Goals.list_goal_tasks(user, goal.id),
         {:ok, asks} <- Goals.list_asks(user, goal.id),
         {:ok, my_asks} <- Goals.list_my_asks(user, goal_id: goal.id),
         {:ok, clock} <- Goals.clock_status(user, goal.id),
         {:ok, retros} <- Goals.list_retros(user, goal.id),
         {:ok, prediction_states} <- Goals.prediction_states(user, goal.id),
         {:ok, pace} <- Goals.expected_pace(user, goal.id),
         {:ok, streak} <- Goals.practice_streak(user, goal.id) do
      source = Enum.find(sources, &(&1.key == goal.source_key))
      current = Enum.find(stops, &is_nil(&1.reached_on))
      target = target(current, goal)
      reading = reading(number)
      pct = percent(reading, target)

      {:ok,
       %{
         card: card,
         retros: retros,
         prediction_states: prediction_states,
         pace: pace,
         paced_at: clock && clock.paced_at,
         paced_every: clock && clock.paced_every,
         retro_every: Platform.Goals.Retro.effective_every(goal),
         stops: stops,
         current: current,
         number: number_view(goal, number, reading, current, pct),
         source: source,
         can_log?: card.role in [:owner, :coach] and match?(%{kind: :logged}, source),
         actions: actions,
         takeaways: takeaways,
         takeaway_titles: Map.new(takeaways, &{&1.id, &1.title}),
         notebook: notebook,
         authors: authors,
         contributors: contributors,
         tasks: Enum.sort_by(tasks, &{!&1.open, &1.title}),
         up_next: up_next(user, List.first(my_asks)),
         next_wake_at: clock && clock.next_wake_at,
         clock_time_zone: (clock && clock.time_zone) || "Etc/UTC",
         answer_lines: answer_lines(asks),
         streak: if(goal.agent_mode == "coach", do: streak, else: 0),
         coach: goal.coach_agent_id && Map.get(authors.agents, goal.coach_agent_id)
       }}
    end
  end

  @doc "The shared card pieces, without the goal page's private briefing reads."
  def card_data(actor, card, number) do
    with {:ok, sources} <- Goals.list_sources(actor),
         {:ok, authors} <- Goals.entry_authors(actor, card.goal.id) do
      reading = reading(number)
      current = card.current_stop
      pct = percent(reading, target(current, card.goal))

      {:ok,
       %{
         card: card,
         authors: authors,
         coach: card.goal.coach_agent_id && Map.get(authors.agents, card.goal.coach_agent_id),
         source: Enum.find(sources, &(&1.key == card.goal.source_key)),
         number: number_view(card.goal, number, reading, current, pct)
       }}
    end
  end

  defp up_next(_user, nil), do: nil

  defp up_next(user, ask) do
    date =
      case Goals.ask_brief_date(user, ask.id) do
        {:ok, %Date{} = date} -> date
        _ -> nil
      end

    kind = if ask.kind == "offer" and is_map(ask.payload["idea"]), do: :idea, else: ask.kind

    %{
      ask: ask,
      kind: kind,
      brief_href: if(date, do: "/inbox/briefing/" <> Date.to_iso8601(date), else: "/inbox")
    }
  end

  defp answer_lines(asks) do
    Map.new(asks, fn ask ->
      lines =
        Enum.map(ask.answers, fn answer ->
          user = Platform.Accounts.get_user(answer.user_id)
          name = if user, do: user.name, else: "Someone"

          result =
            cond do
              ask.kind == "practice" and answer.answer == "used" ->
                "#{answer.details["got"] || 0} of #{length(ask.payload["cards"] || [])} cards"

              answer.answer == "used" ->
                "Used"

              answer.answer == "declined" ->
                "Not now"

              true ->
                "No answer"
            end

          name <> ": " <> result
        end)

      {ask.id, lines}
    end)
  end

  defp target(%{target_value: %Decimal{} = t}, _goal), do: t
  defp target(_stop, %{target_value: %Decimal{} = t}), do: t
  defp target(_stop, _goal), do: nil

  defp reading({:reading, %{latest: latest} = r}),
    do: %{value: latest.value, measured_at: latest.measured_at, source_label: r.source.label}

  defp reading(_), do: nil

  defp percent(%{value: %Decimal{} = v}, %Decimal{} = t) do
    if Decimal.gt?(t, 0) do
      v
      |> Decimal.mult(100)
      |> Decimal.div(t)
      |> Decimal.round(0, :down)
      |> Decimal.to_integer()
      |> max(0)
      |> min(100)
    end
  end

  defp percent(_reading, _target), do: nil

  # The pieces come from `Platform.Goals.NumberText`, the one number sentence
  # the list and the space update also use; the page adds the source and the
  # percentage.
  defp number_view(goal, number, reading, current, pct) do
    case Platform.Goals.NumberText.parts(goal, current, number) do
      %{kind: :reading} = parts ->
        Map.merge(parts, %{source_label: reading.source_label, pct: pct})

      %{kind: :target} = parts ->
        {:cannot_measure, m} = number
        Map.put(parts, :source_label, m.source_label)

      none ->
        none
    end
  end

  # ── page ───────────────────────────────────────────────────────────────

  @doc "The goal page. `page` is `load/2`'s map; `log_error` the form's error."
  attr(:page, :map, required: true)
  attr(:log_error, :string, default: nil)
  attr(:audience_options, :map, default: %{people: [], teams: [], spaces: []})

  attr(:from_brief, :boolean, default: false)

  def goal_page(assigns) do
    assigns = assign(assigns, :goal, assigns.page.card.goal)

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goal-view" data-goal-id={@goal.id}>
      <p :if={@from_brief} data-role="goal-brief-note" class="mb-3 text-xs text-subtle">
        You came here from today's briefing.
      </p>
      <.link
        navigate="/m/goals"
        class="-ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive focus-visible-ring lg:hidden"
        data-role="goal-back"
      >
        ‹ Goals
      </.link>
      <header>
        <h2 class="text-2xl font-bold text-base-content" data-role="goal-title">
          {@goal.title}
          <span :if={@goal.status != "active"} class="chip-soft chip-neutral" data-role="goal-status">
            {String.capitalize(@goal.status)}
          </span>
        </h2>
        <p :if={present?(@goal.why)} class="mt-1 text-sm text-subtle" data-role="goal-why">
          {@goal.why}
        </p>
        <div class="mt-2.5 flex flex-wrap items-center gap-2 text-sm">
          <span class="text-subtle" data-role="goal-meta"><.meta page={@page} /></span>
          <span class="grow"></span>
          <PlatformWeb.GoalsOpenUp.badge card={@page.card} options={@audience_options} />
        </div>
      </header>

      <div class={[card_class(), "mt-4"]} data-role="goal-number-card">
        <.journey :if={@page.stops != []} page={@page} />
        <span
          :if={@page.number.kind == :reading}
          class="mt-1.5 block h-1.5 w-full overflow-hidden rounded-box bg-base-300"
          data-role="goal-progress"
          aria-hidden="true"
        >
          <i class="block h-full rounded-box bg-success" style={"width: #{@page.number.pct || 0}%"}>
          </i>
        </span>
        <p class="mt-2 text-sm text-base-content" data-role="goal-number">
          <.number_sentence number={@page.number} />
          <span :if={@page.pace} class="text-subtle" data-role="goal-pace">
            {pace_sentence(@page.pace)}
          </span>
        </p>
        <.log_form :if={@page.can_log?} error={@log_error} />
      </div>

      <PlatformWeb.GoalsWork.section page={@page} />
      <.up_next_card page={@page} />

      <section :if={@page.actions != []} data-role="goal-trying">
        <h3 class={sec_h()}>What we're trying · {length(@page.actions)}</h3>
        <ul class="flex flex-col gap-3">
          <li :for={entry <- @page.actions}>
            <.trying entry={entry} page={@page} />
          </li>
        </ul>
      </section>

      <section :if={@page.takeaways != []} data-role="goal-learned">
        <h3 class={sec_h()}>What we've learned</h3>
        <div class={card_class()}>
          <p :if={@page.coach} class="mb-2.5 text-xs text-subtle" data-role="goal-learned-intro">
            From {@page.coach.name}'s research when the goal was set. Everything we try says which of these it came from.
          </p>
          <div
            :for={{entry, i} <- Enum.with_index(@page.takeaways)}
            class={["py-2.5", i > 0 && "border-t border-edge", i == 0 && "pt-0"]}
            data-role="goal-takeaway"
            data-entry-id={entry.id}
          >
            <div class="text-sm font-semibold text-base-content">{entry.title}</div>
            <p :if={entry.sources != []} class="mt-0.5 text-xs text-subtle">
              Sources: {sources(entry)}
            </p>
            <.link
              navigate={read_href(@goal, "all")}
              class={[link_class(), "mt-1 inline-block text-sm"]}
              data-role="goal-read-more"
            >
              Read more
            </.link>
          </div>
        </div>
      </section>

      <section
        :if={@page.current && present?(@page.current.theme)}
        data-role="goal-stop-theme"
      >
        <h3 class={sec_h()}>This stop is about {@page.current.theme}</h3>
        <div class={card_class()}>
          <ul>
            <li
              :for={item <- @page.current.criteria}
              class="flex gap-2 py-1 text-sm text-base-content"
              data-role="goal-criterion"
              data-met={to_string(met?(item))}
            >
              <.icon
                name={if met?(item), do: "hero-check-circle", else: "hero-minus-circle"}
                class={[
                  "mt-0.5 size-4 shrink-0",
                  if(met?(item), do: "text-success", else: "text-subtle")
                ]}
              />
              <span>
                {item["text"]}
                <span class="text-subtle">{criterion_note(item)}</span>
              </span>
            </li>
          </ul>
        </div>
      </section>

      <section data-role="goal-check-in">
        <div class="flex items-baseline justify-between">
          <h3 class={sec_h()}>How we check in</h3>
          <button
            :if={@page.card.role == :owner}
            type="button"
            phx-click="open_settings"
            class={link_class()}
          >
            Edit
          </button>
        </div>
        <div class={card_class()}>
          <p class="text-sm text-base-content" data-role="goal-rhythm">
            {rhythm(@goal)} {nudges(@goal)}
          </p>
          <p :if={@page.coach} class="mt-1 text-xs text-subtle" data-role="goal-roles">
            {roles(@goal, @page.coach.name)}
          </p>
        </div>
      </section>

      <p :if={@page.coach && @page.paced_at} class="mt-1 text-xs text-subtle" data-role="goal-slowed">
        {@page.coach.name} has slowed down until you answer: check-ins come {PlatformWeb.GoalsBriefCards.paced_words(
          %{goal: @goal, every: @page.paced_every}
        )}.
      </p>
      <p :if={@page.coach} class="mt-6 text-sm text-subtle" data-role="goal-retro-rhythm">
        {@page.coach.name} looks back every {@page.retro_every} check-ins.
        <a
          :if={@page.retros != []}
          href={retro_href(@goal, hd(@page.retros).entry_id)}
          class={link_class()}
        >
          Read the last retro
        </a>
      </p>
      <section :if={@page.notebook != []} data-role="goal-notebook">
        <h3 class={sec_h()}>
          Notebook
          <span
            :if={@page.streak > 0}
            data-role="goal-notebook-streak"
            class="ml-2 rounded-full bg-warning-dim px-2 py-0.5 text-[11px] font-bold text-base-content"
          >
            {@page.streak}-day streak
          </span>
        </h3>
        <ul class="flex flex-col gap-3">
          <li :for={entry <- @page.notebook}>
            <article
              class={card_class()}
              data-role="goal-notebook-entry"
              data-kind={entry.kind}
              data-ask-id={entry.details["ask_id"]}
            >
              <div class="mb-1.5 flex items-center gap-2">
                <span class={tag_class()}>{Map.get(notebook_tags(), entry.kind, entry.kind)}</span>
              </div>
              <h4 :if={present?(entry.title)} class="text-base font-semibold text-base-content">
                {entry.title}
              </h4>
              <p :if={present?(entry.body)} class="mt-1 text-sm text-base-content">{entry.body}</p>
              <GoalsFromLink.from_link page={@page} entry={entry} role="goal-notebook-from" />
              <p
                :for={line <- Map.get(@page.answer_lines, entry.details["ask_id"], [])}
                data-role="goal-answer"
                class="mt-1 text-xs text-subtle"
              >
                {line}
              </p>
              <a
                :if={entry.kind == "retro"}
                href={retro_href(@goal, entry.id)}
                class={[link_class(), "mt-2 inline-block text-sm"]}
              >
                Read the retro
              </a>
              <p class="mt-1.5 text-xs text-subtle">
                <.author entry={entry} authors={@page.authors} /> ·
                <time datetime={DateTime.to_iso8601(entry.occurred_at)}>
                  {InboxItem.relative_time(entry.occurred_at)}
                </time>
              </p>
            </article>
          </li>
        </ul>
      </section>
      <footer :if={@page.card.role == :owner} class="mt-6 flex gap-2" data-role="goal-status-controls">
        <button
          :if={@goal.status == "active"}
          type="button"
          phx-click="goal_status"
          phx-value-status="paused"
          class="btn btn-ghost"
        >
          Pause
        </button>
        <button
          :if={@goal.status != "finished"}
          type="button"
          phx-click="goal_status"
          phx-value-status="finished"
          class="btn btn-ghost"
        >
          Finish
        </button>
        <button
          :if={@goal.status == "paused"}
          type="button"
          phx-click="goal_status"
          phx-value-status="active"
          class="btn btn-ghost"
        >
          Resume
        </button>
        <button
          :if={@goal.status == "finished"}
          type="button"
          phx-click="goal_status"
          phx-value-status="active"
          class="btn btn-ghost"
        >
          Reopen
        </button>
      </footer>
    </div>
    """
  end

  attr(:page, :map, required: true)

  defp up_next_card(assigns) do
    ~H"""
    <section
      data-role="goal-up-next"
      data-kind={if @page.up_next, do: @page.up_next.kind, else: "caught-up"}
    >
      <h3 class={sec_h()}>Up next</h3>
      <div class={card_class()}>
        <div :if={@page.up_next}>
          <span class={[
            "rounded-md px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content",
            up_next_tag(@page.up_next.kind).class
          ]}>
            {up_next_tag(@page.up_next.kind).label}
          </span>
          <h4 class="mt-2 text-base font-semibold text-base-content">
            {if @page.up_next.kind == "practice",
              do:
                "Today's #{length(@page.up_next.ask.payload["cards"] || [])} cards are in your briefing",
              else: @page.up_next.ask.title}
          </h4>
          <p :if={@page.up_next.kind == :idea} class="mt-1 text-sm text-base-content">
            <PlatformWeb.GoalsCheckIn.coach coach={@page.coach} /> has a new idea to try.
          </p>
          <p :if={@page.up_next.kind == "question"} class="mt-1 text-sm text-base-content">
            <PlatformWeb.GoalsCheckIn.coach coach={@page.coach} />
            drafted it. See what moved, and choose what to change.
          </p>
          <p
            :if={@page.up_next.kind == "offer" && @page.up_next.ask.body}
            class="mt-1 whitespace-pre-line text-sm text-base-content"
          >
            {@page.up_next.ask.body}
          </p>
          <a href={up_next_href(@page)} class={[btn_primary(), "mt-3"]}>
            {up_next_label(@page.up_next.kind)}
          </a>
        </div>
        <div :if={is_nil(@page.up_next)}>
          <h4 class="text-base font-semibold text-base-content">You're all caught up</h4>
          <a
            :if={@page.retros != []}
            href={retro_href(@page.card.goal, hd(@page.retros).entry_id)}
            class="btn btn-ghost"
          >
            Read the last retro
          </a>
          <p class="mt-1 text-sm text-subtle">
            <span :if={@page.next_wake_at}>The next check-in is ready on {PlatformWeb.GoalsCheckIn.weekday(@page.next_wake_at, @page.clock_time_zone)}. </span>Your agents keep working on the plan in the meantime.
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp up_next_tag(:idea), do: %{label: "Idea", class: "bg-info-dim"}
  defp up_next_tag("question"), do: %{label: "Check-in", class: "bg-warning-dim"}
  defp up_next_tag("practice"), do: %{label: "Practice", class: "bg-success-dim"}
  defp up_next_tag(_), do: %{label: "Offer", class: "bg-warning-dim"}

  defp up_next_href(%{up_next: %{kind: :idea} = next, card: card}),
    do: "/m/goals?goal=#{card.goal.id}&idea=#{next.ask.id}"

  defp up_next_href(%{up_next: %{kind: "question"} = next, card: card}),
    do: "/m/goals?goal=#{card.goal.id}&check=#{next.ask.id}"

  defp up_next_href(%{up_next: next}), do: next.brief_href
  defp up_next_label(:idea), do: "Look at the idea"
  defp up_next_label("question"), do: "Open the check-in"
  defp up_next_label(_), do: "Open your briefing"

  defp notebook_tags, do: @notebook_tags

  # The meta line. Personal: "{Owner}'s goal · {Coach} leads · {source}".
  # Shared: "Shared by {Owner} and {Coach} · {source}".
  attr(:page, :map, required: true)

  def meta(assigns) do
    card = assigns.page.card
    owner = first_name(card.owner_name)
    shared? = card.goal.kind == "shared"

    assigns =
      assign(assigns,
        lead: if(shared?, do: "Shared by #{owner}", else: "#{owner}'s goal"),
        join: if(shared?, do: " and ", else: " · "),
        tail: if(shared?, do: "", else: " " <> verb(card.goal.agent_mode))
      )

    ~H"""
    <span>{@lead}</span><span :if={@page.coach}>{@join}<.agent_name agent={@page.coach} />{@tail}</span><span
      :if={@page.source}
      data-role="goal-meta-source"
    >{" · " <> @page.source.label}</span>
    """
  end

  attr(:agent, :map, required: true)

  defp agent_name(assigns) do
    ~H"""
    <span data-agent-slot={@agent.slot} class="font-semibold text-(--ag-text)" data-role="agent-name">
      {@agent.name}
    </span>
    """
  end

  attr(:page, :map, required: true)

  attr(:small, :boolean, default: false)
  attr(:next_push, :boolean, default: false)

  def journey(assigns) do
    stops = assigns.page.stops
    current_id = assigns.page.current && assigns.page.current.id
    last = length(stops) - 1
    assigns = assign(assigns, stops: Enum.with_index(stops), current_id: current_id, last: last)

    ~H"""
    <div class="mb-2 mt-1 flex items-start" data-role="goal-journey">
      <%= for {stop, i} <- @stops do %>
        <div
          class={["flex-none text-center", if(@small, do: "w-20", else: "w-[76px] lg:w-24")]}
          data-role="goal-stop"
          data-state={stop_state(stop, @current_id)}
        >
          <div class={[
            "mx-auto mb-1.5 flex size-10 items-center justify-center rounded-full text-xs font-bold tabular-nums",
            circle_class(stop_state(stop, @current_id))
          ]}>
            <%= case circle(stop, stop_state(stop, @current_id), @page.number) do %>
              <% :check -> %>
                <.icon name="hero-check" class="size-4" />
                <span class="sr-only">Reached</span>
              <% text -> %>
                {text}
            <% end %>
          </div>
          <div class="text-sm font-semibold text-base-content">{stop.label}</div>
          <div
            :if={sub_line(stop) || (@next_push and stop.id == @current_id)}
            class="text-xs text-subtle"
          >
            {if @next_push and stop.id == @current_id, do: "next push", else: sub_line(stop)}
          </div>
          <a
            :if={!@small && stop.reached_on && retro_for_stop(@page.retros, stop.id)}
            href={retro_href(@page.card.goal, retro_for_stop(@page.retros, stop.id).entry_id)}
            class={[link_class(), "inline-block text-xs"]}
          >
            Read the retro
          </a>
        </div>
        <div
          :if={i < @last}
          class={[
            "mt-5 h-0 flex-1 border-t-2",
            if(stop.reached_on, do: "border-solid border-primary", else: "border-dashed border-edge")
          ]}
          data-role="goal-path"
          aria-hidden="true"
        >
        </div>
      <% end %>
    </div>
    """
  end

  defp stop_state(%{reached_on: %Date{}}, _current_id), do: :reached
  defp stop_state(%{id: id}, id), do: :current
  defp stop_state(_stop, _current_id), do: :upcoming

  defp circle_class(:reached), do: "bg-primary text-primary-content"
  defp circle_class(:current), do: "bg-base-100 text-base-content ring-2 ring-inset ring-primary"
  defp circle_class(:upcoming), do: "bg-base-300 text-subtle"

  defp circle(_stop, :reached, _number), do: :check

  defp circle(%{target_value: %Decimal{}}, :current, %{kind: :reading, pct: pct})
       when is_integer(pct),
       do: "#{pct}%"

  defp circle(stop, _state, _number), do: short_target(stop)

  @doc "A stop's short target: 1,000 -> \"1k\", 30,000 -> \"30k\", 1,000,000 -> \"1M\"; else its position."
  def short_target(%{target_value: %Decimal{} = t}) do
    cond do
      Decimal.compare(t, 1_000_000) != :lt -> scaled(t, 1_000_000) <> "M"
      Decimal.compare(t, 1_000) != :lt -> scaled(t, 1_000) <> "k"
      true -> GoalsComponents.format_number(t)
    end
  end

  def short_target(%{position: position}), do: to_string(position)

  defp scaled(t, by),
    do: t |> Decimal.div(by) |> Decimal.round(1, :down) |> GoalsComponents.format_number()

  defp sub_line(%{due_on: %Date{} = d}), do: "by " <> Calendar.strftime(d, "%-d %b")
  defp sub_line(%{caption: c}) when is_binary(c) and c != "", do: c
  defp sub_line(_stop), do: nil

  attr(:number, :map, required: true)

  def number_sentence(%{number: %{kind: :reading}} = assigns) do
    ~H"""
    <b class="tabular-nums">{@number.value}</b>
    of {@number.target} {@number.unit}.
    <span class="text-subtle" data-role="goal-number-source">{@number.source_label}.</span>
    """
  end

  def number_sentence(%{number: %{kind: :target}} = assigns) do
    ~H"""
    Target: {@number.target} {@number.unit}.<span
      :if={@number.source_label}
      class="text-subtle"
      data-role="goal-number-source"
    > {@number.source_label}.</span>
    """
  end

  def number_sentence(assigns) do
    ~H"""
    No number to follow yet
    """
  end

  attr(:error, :string, default: nil)

  defp log_form(assigns) do
    ~H"""
    <form
      id="goal-log-form"
      phx-submit="log_value"
      class="mt-3 flex flex-wrap items-end gap-2"
      data-role="goal-log-form"
    >
      <div class="w-full min-w-0 sm:w-auto sm:flex-1">
        <label class="mb-1 block text-xs text-subtle" for="goal-log-value">New value</label>
        <input
          id="goal-log-value"
          type="text"
          inputmode="decimal"
          name="value"
          autocomplete="off"
          class={[field_class(), "min-h-11 tabular-nums"]}
        />
      </div>
      <button type="submit" class={btn_primary()} data-role="goal-log-submit">Log a value</button>
      <p :if={@error} class="w-full text-sm text-error" data-role="goal-log-error">{@error}</p>
    </form>
    """
  end

  attr(:entry, :map, required: true)
  attr(:page, :map, required: true)

  defp trying(assigns) do
    entry = assigns.entry
    agent = entry.author_agent_id && Map.get(assigns.page.authors.agents, entry.author_agent_id)

    assigns =
      assign(assigns,
        sentence: if(present?(entry.prediction), do: entry.prediction, else: entry.body),
        doing: agent && present?(entry.prediction) && present?(entry.body) && agent
      )

    ~H"""
    <div class={card_class()} data-role="goal-trying-card" data-entry-id={@entry.id}>
      <h4 class={[
        "text-base font-semibold",
        if(match?({:stopped, _}, @page.prediction_states[@entry.id]),
          do: "text-subtle",
          else: "text-base-content"
        )
      ]}>
        {@entry.title}
      </h4>
      <.prediction_pill state={@page.prediction_states[@entry.id]} />
      <p :if={present?(@sentence)} class="mt-1 text-sm text-subtle">{@sentence}</p>
      <GoalsFromLink.from_link page={@page} entry={@entry} role="goal-trying-from" />
      <div :if={@doing} class="mt-2 flex items-center gap-2 text-sm" data-role="goal-trying-doing">
        <span data-agent-slot={@doing.slot}>
          <AvatarComponents.agent_avatar name={@doing.name} avatar_url={@doing.avatar_url} size="xs" />
        </span>
        <span>
          <.agent_name agent={@doing} /> <span class="text-base-content">{@entry.body}</span>
        </span>
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:authors, :map, required: true)

  defp author(assigns) do
    ~H"""
    <%= cond do %>
      <% agent = @entry.author_agent_id && Map.get(@authors.agents, @entry.author_agent_id) -> %>
        <.agent_name agent={agent} />
      <% user = @entry.author_user_id && Map.get(@authors.users, @entry.author_user_id) -> %>
        <span class="font-semibold">{user.name}</span>
      <% true -> %>
        <span>Someone</span>
    <% end %>
    """
  end

  attr(:state, :any, required: true)

  def prediction_pill(assigns) do
    {label, color} =
      case assigns.state do
        :just_started -> {"Just started", "bg-info-dim"}
        :working -> {"Working", "bg-success-dim"}
        :not_working -> {"Not working", "bg-warning-dim"}
        :too_early -> {"Too early to tell", "bg-warning-dim"}
        {:stopped, date} -> {"Stopped " <> Calendar.strftime(date, "%-d %b"), "bg-base-300"}
        _ -> {nil, ""}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span
      :if={@label}
      class={[
        "inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold text-base-content",
        @color
      ]}
      data-role="goal-prediction-state"
    >
      {@label}
    </span>
    """
  end

  defp pace_sentence(pace),
    do:
      "We'd hoped for about #{GoalsComponents.format_number(pace.hoped)} by today, so we're #{if pace.state == :behind, do: "a little behind", else: "on track"}."

  defp retro_for_stop(retros, stop_id), do: Enum.find(retros, &(&1.stop_id == stop_id))
  def retro_href(goal, entry_id), do: "/m/goals?goal=#{goal.id}&retro=#{entry_id}"

  # ── copy ───────────────────────────────────────────────────────────────

  @doc "The short read's address for `goal`; `read` is an entry id or \"all\"."
  def read_href(goal, read), do: "/m/goals?goal=#{goal.id}&read=#{read}"

  @doc "A takeaway's sources, each map's \"name\", joined with \" · \"."
  def sources(entry),
    do:
      entry.sources
      |> Enum.map(&(&1["name"] || &1[:name]))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

  defp met?(item),
    do: number(item["found"]) >= number(item["needed"]) and not is_nil(item["needed"])

  defp criterion_note(item) do
    cond do
      met?(item) ->
        "(done)"

      not is_nil(item["found"]) ->
        "(#{GoalsComponents.format_number(number(item["found"]))} found)"

      true ->
        nil
    end
  end

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: trunc(n)

  defp number(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp number(_), do: 0

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  defp rhythm(%{rhythm: "daily"}), do: "Every day, in your briefing."
  defp rhythm(%{rhythm: "weekdays"}), do: "On weekdays, in your briefing."

  defp rhythm(%{rhythm: "weekly", rhythm_weekday: d}) when d in 1..7,
    do: "#{Enum.at(@weekdays, d - 1)}s, in your briefing."

  defp rhythm(%{rhythm: "biweekly", rhythm_weekday: d}) when d in 1..7,
    do: "Every other #{Enum.at(@weekdays, d - 1)}, in your briefing."

  defp rhythm(%{rhythm: "biweekly"}), do: "Every other week, in your briefing."
  defp rhythm(_goal), do: "Every week, in your briefing."

  defp nudges(%{outreach: "pushy"}), do: "Nudges: pushy."
  defp nudges(%{outreach: "off"}), do: "Nudges: off."
  defp nudges(_goal), do: "Nudges: gentle."

  def roles(%{agent_mode: "do"}, coach),
    do: "#{coach} does the work and asks before anything goes public."

  def roles(%{agent_mode: "coach"}, coach), do: "You practise. #{coach} plans and prepares."
  def roles(_goal, coach), do: "#{coach} advises. You do the work."

  defp verb("do"), do: "leads"
  defp verb("coach"), do: "coaches"
  defp verb(_), do: "advises"

  defp first_name(name) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> name
    end
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  defp sec_h, do: @sec_h
  defp field_class, do: @field
  defp btn_primary, do: @btn_primary
end
