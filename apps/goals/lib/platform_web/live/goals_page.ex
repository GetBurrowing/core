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
      `Platform.Goals.entry_authors/2`.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Goals
  alias PlatformWeb.AvatarComponents
  alias PlatformWeb.Components.InboxItem
  alias PlatformWeb.GoalsComponents

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
         {:ok, authors} <- Goals.entry_authors(user, goal.id) do
      source = Enum.find(sources, &(&1.key == goal.source_key))
      current = Enum.find(stops, &is_nil(&1.reached_on))
      target = target(current, goal)
      reading = reading(number)
      pct = percent(reading, target)

      {:ok,
       %{
         card: card,
         stops: stops,
         current: current,
         number: number_view(goal, number, reading, target, pct),
         source: source,
         can_log?: card.role in [:owner, :coach] and match?(%{kind: :logged}, source),
         actions: actions,
         takeaways: takeaways,
         takeaway_titles: Map.new(takeaways, &{&1.id, &1.title}),
         notebook: notebook,
         authors: authors,
         coach: goal.coach_agent_id && Map.get(authors.agents, goal.coach_agent_id)
       }}
    end
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

  defp number_view(goal, number, reading, target, pct) do
    unit = goal.unit

    cond do
      is_nil(target) or is_nil(unit) or String.trim(unit) == "" ->
        %{kind: :none}

      reading ->
        %{
          kind: :reading,
          value: GoalsComponents.format_number(reading.value),
          target: GoalsComponents.format_number(target),
          unit: unit,
          source_label: reading.source_label,
          pct: pct
        }

      true ->
        {:cannot_measure, m} = number

        %{
          kind: :target,
          target: GoalsComponents.format_number(target),
          unit: unit,
          source_label: m.source_label
        }
    end
  end

  # ── page ───────────────────────────────────────────────────────────────

  @doc "The goal page. `page` is `load/2`'s map; `log_error` the form's error."
  attr :page, :map, required: true
  attr :log_error, :string, default: nil

  def goal_page(assigns) do
    assigns = assign(assigns, :goal, assigns.page.card.goal)

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goal-view" data-goal-id={@goal.id}>
      <.link
        navigate="/m/goals"
        class="-ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive focus-visible-ring lg:hidden"
        data-role="goal-back"
      >
        ‹ Goals
      </.link>
      <header>
        <h2 class="text-2xl font-bold text-base-content" data-role="goal-title">{@goal.title}</h2>
        <p :if={present?(@goal.why)} class="mt-1 text-sm text-subtle" data-role="goal-why">
          {@goal.why}
        </p>
        <div class="mt-2.5 flex flex-wrap items-center gap-2 text-sm">
          <span class="text-subtle" data-role="goal-meta"><.meta page={@page} /></span>
          <span class="grow"></span>
          <span data-goals-slot="privacy"></span>
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
        </p>
        <.log_form :if={@page.can_log?} error={@log_error} />
      </div>

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
        <h3 class={sec_h()}>How we check in</h3>
        <div class={card_class()}>
          <p class="text-sm text-base-content" data-role="goal-rhythm">
            {rhythm(@goal)} {nudges(@goal)}
          </p>
          <p :if={@page.coach} class="mt-1 text-xs text-subtle" data-role="goal-roles">
            {roles(@goal, @page.coach.name)}
          </p>
        </div>
      </section>

      <section :if={@page.notebook != []} data-role="goal-notebook">
        <h3 class={sec_h()}>Notebook</h3>
        <ul class="flex flex-col gap-3">
          <li :for={entry <- @page.notebook}>
            <article class={card_class()} data-role="goal-notebook-entry" data-kind={entry.kind}>
              <div class="mb-1.5 flex items-center gap-2">
                <span class={tag_class()}>{Map.get(notebook_tags(), entry.kind, entry.kind)}</span>
              </div>
              <h4 :if={present?(entry.title)} class="text-base font-semibold text-base-content">
                {entry.title}
              </h4>
              <p :if={present?(entry.body)} class="mt-1 text-sm text-base-content">{entry.body}</p>
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
    </div>
    """
  end

  defp notebook_tags, do: @notebook_tags

  # The meta line. Personal: "{Owner}'s goal · {Coach} leads · {source}".
  # Shared: "Shared by {Owner} and {Coach} · {source}".
  attr :page, :map, required: true

  defp meta(assigns) do
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

  attr :agent, :map, required: true

  defp agent_name(assigns) do
    ~H"""
    <span data-agent-slot={@agent.slot} class="font-semibold text-(--ag-text)" data-role="agent-name">
      {@agent.name}
    </span>
    """
  end

  attr :page, :map, required: true

  defp journey(assigns) do
    stops = assigns.page.stops
    current_id = assigns.page.current && assigns.page.current.id
    last = length(stops) - 1
    assigns = assign(assigns, stops: Enum.with_index(stops), current_id: current_id, last: last)

    ~H"""
    <div class="mb-2 mt-1 flex items-start" data-role="goal-journey">
      <%= for {stop, i} <- @stops do %>
        <div
          class="w-[76px] flex-none text-center lg:w-24"
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
          <div :if={sub_line(stop)} class="text-xs text-subtle">{sub_line(stop)}</div>
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

  attr :number, :map, required: true

  defp number_sentence(%{number: %{kind: :reading}} = assigns) do
    ~H"""
    <b class="tabular-nums">{@number.value}</b>
    of {@number.target} {@number.unit}.
    <span class="text-subtle" data-role="goal-number-source">{@number.source_label}.</span>
    """
  end

  defp number_sentence(%{number: %{kind: :target}} = assigns) do
    ~H"""
    Target: {@number.target} {@number.unit}.<span
      :if={@number.source_label}
      class="text-subtle"
      data-role="goal-number-source"
    > {@number.source_label}.</span>
    """
  end

  defp number_sentence(assigns) do
    ~H"""
    No number to follow yet
    """
  end

  attr :error, :string, default: nil

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

  attr :entry, :map, required: true
  attr :page, :map, required: true

  defp trying(assigns) do
    entry = assigns.entry
    agent = entry.author_agent_id && Map.get(assigns.page.authors.agents, entry.author_agent_id)

    assigns =
      assign(assigns,
        sentence: if(present?(entry.prediction), do: entry.prediction, else: entry.body),
        from: entry.takeaway_id && Map.get(assigns.page.takeaway_titles, entry.takeaway_id),
        doing: agent && present?(entry.prediction) && present?(entry.body) && agent
      )

    ~H"""
    <div class={card_class()} data-role="goal-trying-card" data-entry-id={@entry.id}>
      <h4 class="text-base font-semibold text-base-content">{@entry.title}</h4>
      <p :if={present?(@sentence)} class="mt-1 text-sm text-subtle">{@sentence}</p>
      <.link
        :if={@from}
        navigate={read_href(@page.card.goal, @entry.takeaway_id)}
        class={[link_class(), "mt-1 inline-block text-sm"]}
        data-role="goal-trying-from"
      >
        From: {@from}
      </.link>
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

  attr :entry, :map, required: true
  attr :authors, :map, required: true

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

  defp roles(%{agent_mode: "do"}, coach),
    do: "#{coach} does the work and asks before anything goes public."

  defp roles(%{agent_mode: "coach"}, coach), do: "You practise. #{coach} plans and prepares."
  defp roles(_goal, coach), do: "#{coach} advises. You do the work."

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
