defmodule PlatformWeb.GoalsTalk do
  @moduledoc """
  The goal's own conversation (task 01a20939 stage 4), hosted by GoalsLive
  at `?goal=<id>&talk=1` the way GoalsCheckIn is.

  Owner only: the read goes through `Platform.Goals.goal_conversation/2`,
  which refuses everyone but the owner and the coach, and a user can only
  ever be the owner, so anyone else lands on the goal's not-found path.

  The owner and the coach read the same `Conversation.timeline/2`. This
  module only arranges it: the New goal messages before the proposal's
  confirmation fold under "How this goal was set up", a check-in reply sits
  directly under its record, and day separators split the rest. Nothing is
  copied; it is all the goal's one space. Core system notices are already
  left out by the timeline.
  """
  use PlatformWeb, :html

  alias Platform.Goals
  alias PlatformWeb.{GoalsCheckIn, GoalsPage}

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  def load(user, page, _id) do
    goal = page.card.goal

    with {:ok, read} <- Goals.goal_conversation(user, goal.id) do
      zone = page.clock_time_zone || "Etc/UTC"
      {setup, rest} = split_setup(read.items, read.setup_until)

      {:ok,
       %{
         kind: :talk,
         ask: nil,
         goal: goal,
         coach: page.coach,
         space_id: read.space_id,
         members_line: members_line(read.members, user.id),
         setup: setup,
         setup_on: read.setup_until && day_label(read.setup_until, zone, :date),
         rows: rows(rest, zone),
         empty?: setup == [] and rest == []
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── arranging the timeline ─────────────────────────────────────────────

  defp split_setup(items, nil), do: {[], items}

  defp split_setup(items, until) do
    {setup, rest} =
      Enum.split_with(items, &(&1.type == "message" and DateTime.compare(&1.at, until) != :gt))

    {setup, rest}
  end

  # A check-in reply (a message with metadata ask_id) moves to directly under
  # its record; then day separators go in front of each new day.
  defp rows(items, zone) do
    record_ids = for i <- items, i.type == "check_in", into: MapSet.new(), do: i.id

    replies =
      items
      |> Enum.filter(
        &(&1.type == "message" and MapSet.member?(record_ids, &1.metadata["ask_id"]))
      )
      |> Enum.group_by(& &1.metadata["ask_id"])

    moved = replies |> Map.values() |> List.flatten() |> MapSet.new(& &1.id)

    items
    |> Enum.reject(&(&1.type == "message" and MapSet.member?(moved, &1.id)))
    |> Enum.flat_map(fn
      %{type: "check_in", id: id} = record -> [record | Map.get(replies, id, [])]
      item -> [item]
    end)
    |> Enum.map_reduce(nil, fn item, last_day ->
      day = local_date(item.at, zone)

      if day == last_day,
        do: {[item], day},
        else:
          {[%{type: "day", id: "day-#{day}", label: day_label(item.at, zone, :day)}, item], day}
    end)
    |> elem(0)
    |> List.flatten()
  end

  defp local_date(at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp day_label(at, zone, :date), do: Calendar.strftime(DateTime.shift_zone!(at, zone), "%-d %b")

  defp day_label(at, zone, :day) do
    date = local_date(at, zone)
    today = local_date(DateTime.utc_now(), zone)

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      n when n in 2..6 -> Enum.at(@weekdays, Date.day_of_week(date) - 1)
      _ -> Calendar.strftime(date, "%-d %b")
    end
  end

  @doc """
  The members line, generated from the space's members (never fixed copy):
  "You and {coach} · private to this goal" when they are the owner and one
  agent; otherwise every member is named and the line says who can see it.
  """
  def members_line([], _user_id), do: "Only you, until you write here"

  def members_line(members, user_id) do
    others = for m <- members, m.id != user_id, do: m.display_name || "Someone"

    case {Enum.filter(members, &(&1.type == "agent")), others} do
      {[_], [name]} -> "You and #{name} · private to this goal"
      {_, []} -> "Only you · private to this goal"
      {_, names} -> "You, " <> join(names) <> " can see this"
    end
  end

  defp join([one]), do: one
  defp join(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  @doc "\"You chose: …\" for the owner's recorded answer to a check-in, or nil while open."
  def chose_line(record, owner_id) do
    case Enum.find(record.answers, &(&1.user_id == owner_id)) do
      %{answer: answer, details: details} when answer in ["used", "declined"] ->
        choices = Map.new((details || %{})["choices"] || [], &{&1["index"], &1["choice"]})

        picks =
          record.suggestions
          |> Enum.with_index()
          |> Enum.map(fn {title, i} ->
            verb = if choices[i] == "do", do: "Do it", else: "Not now"
            "#{verb} · #{title}"
          end)

        "You chose: " <> if(picks == [], do: "Done", else: Enum.join(picks, "; "))

      _ ->
        nil
    end
  end

  @setting_names %{
    "rhythm" => "Rhythm",
    "rhythm_weekday" => "Check-in day",
    "target_value" => "Target",
    "outreach" => "Nudges",
    "stops" => "Stops"
  }

  @doc "A proposed change in words, one setting per part."
  def change_words(changes) when is_map(changes) do
    changes
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} ->
      Map.get(@setting_names, key, key) <> ": " <> setting_value(key, value)
    end)
  end

  def change_words(_), do: ""

  defp setting_value("rhythm_weekday", day) when is_integer(day) and day in 1..7,
    do: Enum.at(@weekdays, day - 1)

  defp setting_value("stops", stops) when is_list(stops), do: "#{length(stops)} stops"
  defp setting_value(_key, value) when is_binary(value), do: value
  defp setting_value(_key, value), do: to_string(value)

  @doc false
  def fold_label(open?, n),
    do: "#{if open?, do: "Hide", else: "Show"} #{n} #{if n == 1, do: "message", else: "messages"}"

  defp time(at, zone), do: Calendar.strftime(DateTime.shift_zone!(at, zone), "%-I:%M %p")

  # ── rendering ──────────────────────────────────────────────────────────

  attr(:screen, :map, required: true)
  attr(:owner_id, :string, required: true)
  attr(:zone, :string, default: "Etc/UTC")
  attr(:fold_open, :boolean, default: false)
  attr(:text, :string, default: "")
  attr(:send_error, :boolean, default: false)
  attr(:input_key, :integer, default: 0)

  def screen(assigns) do
    assigns = assign(assigns, :coach_name, GoalsCheckIn.coach_name(assigns.screen.coach))

    ~H"""
    <div class="flex h-full min-h-0 flex-col" data-role="goals-talk" data-goal-id={@screen.goal.id}>
      <header class="border-b border-edge bg-base-100 px-6 py-3">
        <a
          href={GoalsCheckIn.goal_href(@screen.goal)}
          class="focus-visible-ring -ml-2 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive"
          data-role="goal-talk-back"
        >
          ‹ {@screen.goal.title}
        </a>
        <p class="text-xs text-subtle" data-role="goal-talk-members">{@screen.members_line}</p>
      </header>
      <%!-- column-reverse: the thread opens at its newest message and
           stays pinned there as messages arrive, with no scroll script. --%>
      <div class="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto" data-role="goal-talk-scroller">
        <div class="mx-auto w-full max-w-3xl px-6 py-4" data-role="goal-talk-thread">
          <div :if={@screen.empty?} class="py-10 text-center" data-role="goal-talk-empty">
            <p class="text-sm font-semibold text-base-content">No messages yet.</p>
            <p class="mt-1 text-sm text-subtle">
              {@coach_name} gets anything you write here when you send it.
            </p>
          </div>
          <div :if={@screen.setup != []} data-role="goal-talk-setup">
            <button
              type="button"
              phx-click="talk_fold"
              aria-expanded={to_string(@fold_open)}
              class="focus-visible-ring flex min-h-11 w-full items-center justify-between gap-3 rounded-lg border border-dashed border-edge bg-base-100 px-3 text-left text-[13px] text-subtle"
              data-role="goal-talk-fold"
            >
              <span>
                How this goal was set up{if @screen.setup_on, do: " · " <> @screen.setup_on}
              </span>
              <span class="shrink-0 whitespace-nowrap">
                {fold_label(@fold_open, length(@screen.setup))}
              </span>
            </button>
            <div :if={@fold_open} class="mt-2" data-role="goal-talk-setup-messages">
              <.bubble :for={m <- @screen.setup} item={m} zone={@zone} />
            </div>
          </div>
          <%= for row <- @screen.rows do %>
            <.row
              item={row}
              owner_id={@owner_id}
              zone={@zone}
              coach_name={@coach_name}
              goal={@screen.goal}
            />
          <% end %>
        </div>
      </div>
      <form
        id="goal-talk-composer"
        phx-submit="talk_send"
        phx-change="talk_input"
        class="border-t border-edge bg-base-100 px-4 py-3"
        data-role="goal-talk-composer"
      >
        <p
          :if={@send_error}
          id="goal-talk-send-error"
          role="alert"
          tabindex="-1"
          phx-mounted={Phoenix.LiveView.JS.focus()}
          class="mb-2 text-sm text-error"
          data-role="goal-talk-send-error"
        >
          Couldn't send. Your message is still here. Try again.
        </p>
        <div class="mx-auto flex max-w-3xl items-center gap-2">
          <input
            id={"goal-talk-input-#{@input_key}"}
            type="text"
            name="text"
            value={@text}
            maxlength={Platform.Goals.Limits.max_question_chars()}
            placeholder={"Message #{@coach_name} about this goal"}
            aria-label={"Message #{@coach_name} about this goal"}
            autocomplete="off"
            data-role="goal-talk-input"
            data-hides-tab-bar
            class="focus-visible-ring min-h-11 min-w-0 flex-1 rounded-full border border-secondary bg-base-100 px-4 text-base text-base-content"
          />
          <button
            type="submit"
            class="btn btn-primary btn-circle min-h-11 min-w-11 focus-visible-ring"
            aria-label="Send"
            data-action="goal-talk-send"
          >
            <span class="hero-arrow-up size-5" aria-hidden="true"></span>
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:owner_id, :string, required: true)
  attr(:zone, :string, required: true)
  attr(:coach_name, :string, required: true)
  attr(:goal, :map, required: true)

  defp row(%{item: %{type: "day"}} = assigns) do
    ~H"""
    <p class="my-4 text-center text-xs text-subtle" data-role="goal-talk-day">{@item.label}</p>
    """
  end

  defp row(%{item: %{type: "message"}} = assigns) do
    ~H"""
    <.bubble item={@item} zone={@zone} />
    """
  end

  defp row(%{item: %{type: type}} = assigns) when type in ["check_in", "retro"] do
    assigns =
      assign(assigns,
        tag: if(type == "retro", do: "Retro", else: "Check-in"),
        chose: type == "check_in" && chose_line(assigns.item, assigns.owner_id)
      )

    ~H"""
    <div
      role="group"
      aria-label={"#{@tag}, #{day_and_time(@item.at, @zone)}. #{@item.title}. #{@chose || ""}"}
      class="my-3 rounded-lg border border-edge border-l-4 border-l-warning bg-base-100 px-3 py-2.5"
      data-role="goal-talk-record"
      data-record-id={@item.id}
    >
      <span class="rounded-md bg-warning-dim px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide text-base-content">
        {@tag}
      </span>
      <p class="mt-1 text-sm font-semibold text-base-content">{@item.title}</p>
      <p :if={@chose} class="text-xs text-subtle" data-role="goal-talk-chose">{@chose}</p>
      <a
        :if={@item.type == "check_in" and is_nil(@chose)}
        href={"/m/goals?goal=#{@goal.id}&check=#{@item.id}"}
        class={[GoalsPage.link_class(), "text-xs"]}
        data-role="goal-talk-open-check-in"
      >
        Answer the check-in
      </a>
      <a
        :if={@item.type == "retro"}
        href={"/m/goals?goal=#{@goal.id}&retro=#{@item.id}"}
        class={[GoalsPage.link_class(), "text-xs"]}
      >
        Read the retro
      </a>
    </div>
    """
  end

  defp row(%{item: %{type: "log"}} = assigns) do
    ~H"""
    <div
      class="my-2 mr-12 rounded-lg border border-success/40 bg-success-dim px-3 py-2.5 text-sm text-base-content"
      data-role="goal-talk-log"
    >
      <p class="font-semibold">Added to the notebook</p>
      <p>{@item.title}</p>
      <p :if={@item.body} class="text-subtle">{@item.body}</p>
    </div>
    """
  end

  defp row(%{item: %{type: "change"}} = assigns) do
    ~H"""
    <div
      class="my-2 mr-12 rounded-lg border border-info/40 bg-base-100 px-3 py-2.5 text-sm text-base-content"
      data-role="goal-talk-change"
      data-entry-id={@item.id}
      data-status={@item.status}
    >
      <p class="font-semibold">{@coach_name} proposes a change</p>
      <p>{change_words(@item.changes)}</p>
      <p :if={@item.why} class="text-subtle">{@item.why}</p>
      <div :if={@item.status == "pending"} class="mt-2 flex gap-2">
        <button
          type="button"
          phx-click="talk_apply"
          phx-value-entry_id={@item.id}
          class="btn btn-sm btn-primary min-h-11 focus-visible-ring lg:min-h-0"
          data-action="goal-talk-apply"
        >
          Apply
        </button>
        <button
          type="button"
          phx-click="talk_dismiss"
          phx-value-entry_id={@item.id}
          class="focus-visible-ring min-h-11 rounded-full border border-edge px-3 text-sm text-subtle lg:min-h-8"
          data-action="goal-talk-dismiss"
        >
          Not now
        </button>
      </div>
      <p
        :if={@item.status == "applied"}
        class="mt-1 text-xs text-success"
        data-role="goal-talk-change-outcome"
      >
        Applied to the goal.
      </p>
      <p
        :if={@item.status == "declined"}
        class="mt-1 text-xs text-subtle"
        data-role="goal-talk-change-outcome"
      >
        Not applied. Nothing changed.
      </p>
    </div>
    """
  end

  defp row(assigns), do: ~H""

  attr(:item, :map, required: true)
  attr(:zone, :string, required: true)

  defp bubble(%{item: %{from: "person"}} = assigns) do
    ~H"""
    <div
      class="my-2 ml-12 flex justify-end"
      data-role="goal-talk-message"
      data-from="person"
      data-message-id={@item.id}
    >
      <%!-- phx-no-format: pre-line keeps newlines, so the text must not
           pick up the template's indentation. --%>
      <p
        class="whitespace-pre-line rounded-2xl rounded-br-sm bg-base-content px-3.5 py-2.5 text-sm text-base-100"
        phx-no-format
      ><span class="sr-only">You, {day_and_time(@item.at, @zone)}: </span>{@item.text}</p>
    </div>
    """
  end

  defp bubble(assigns) do
    ~H"""
    <div
      class="my-2 mr-12"
      data-role="goal-talk-message"
      data-from={@item.from}
      data-message-id={@item.id}
    >
      <div class="rounded-2xl rounded-bl-sm border border-edge bg-base-100 px-3.5 py-2.5 text-sm text-base-content">
        <p class="text-xs font-bold text-base-content" aria-hidden="true">{@item.author_name}</p>
        <p class="whitespace-pre-line" phx-no-format><span class="sr-only">{@item.author_name}, {day_and_time(@item.at, @zone)}: </span>{@item.text}</p>
      </div>
    </div>
    """
  end

  defp day_and_time(at, zone), do: day_label(at, zone, :day) <> " " <> time(at, zone)
end
