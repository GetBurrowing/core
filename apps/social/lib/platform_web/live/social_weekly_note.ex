defmodule PlatformWeb.SocialWeeklyNote do
  @moduledoc "A freshly authorized decision list; delivery Monday labels the preceding reporting week."
  use PlatformWeb, :live_component
  import PlatformWeb.SocialHelpers
  alias Platform.{Repo, Social}
  alias Platform.Social.{WeeklyNote, WeeklyNotes}

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         expanded: MapSet.new(),
         summaries: MapSet.new(),
         confirming: nil,
         opened_target: nil,
         error: nil
       )}

  @impl true
  def update(assigns, socket) do
    changed = socket.assigns[:scope] != assigns.scope
    socket = assign(socket, assigns)

    socket =
      if changed,
        do:
          assign(socket,
            expanded: MapSet.new(),
            summaries: MapSet.new(),
            confirming: nil,
            error: nil
          ),
        else: socket

    {:ok, reload(socket)}
  end

  defp reload(socket) do
    user = fresh_user(socket)
    visible = if human?(user), do: PlatformWeb.SocialScope.visible_profiles(socket), else: []

    profiles =
      case socket.assigns.scope do
        :all -> visible
        {:profile, %{id: id}} -> Enum.filter(visible, &(&1.id == id))
        _ -> []
      end

    rows =
      Enum.map(profiles, fn profile ->
        week = current_week(profile)
        notes = WeeklyNotes.list(scope(user, profile), profile.id)

        %{
          profile: profile,
          current: Enum.find(notes, &(&1.week_start == week)),
          older: Enum.filter(notes, &(Date.compare(&1.week_start, week) == :lt)),
          can_decide: Social.approver_check(profile.org_id, profile, user.id) == :ok
        }
      end)

    target = socket.assigns[:query] || %{}

    facts =
      with "facts" <- target["weekly_note_target"],
           {:ok, week} <- Date.from_iso8601(target["weekly_note_week"] || ""),
           true <- Date.day_of_week(week) == 1,
           %{profile: profile} <-
             Enum.find(rows, &(&1.profile.id == (target["profile"] || target["profile_id"]))) do
        %{profile: profile, data: WeeklyNote.facts(profile, week)}
      else
        _ -> nil
      end

    expanded =
      case target["weekly_note_target"] do
        id when is_binary(id) ->
          if socket.assigns.opened_target != id and
               Enum.any?(rows, fn row -> Enum.any?(row.older, &(&1.id == id)) end),
             do: MapSet.put(socket.assigns.expanded, id),
             else: socket.assigns.expanded

        _ ->
          socket.assigns.expanded
      end

    assign(socket,
      rows: rows,
      facts: facts,
      expanded: expanded,
      opened_target: target["weekly_note_target"]
    )
  end

  defp scope(user, profile),
    do:
      if(Platform.Tenancy.visibility(user) == :root_all,
        do: :root,
        else: {:tenant, profile.org_id}
      )

  defp current_week(profile) do
    today = DateTime.utc_now() |> DateTime.shift_zone!(profile.timezone) |> DateTime.to_date()
    Date.add(today, 1 - Date.day_of_week(today))
  end

  @impl true
  def handle_event(event, params, socket) do
    socket = reload(socket)
    note_id = params["note"]

    row =
      Enum.find(socket.assigns.rows, fn row ->
        Enum.any?([row.current | row.older], &(&1 && &1.id == note_id))
      end)

    note = if row, do: Enum.find([row.current | row.older], &(&1 && &1.id == note_id))
    item = if note, do: Enum.find(note.items, &(&1.id == params["item"]))

    socket =
      case {event, row, note, item} do
        {"older", %{}, %{}, _} ->
          assign(socket, :expanded, toggle(socket.assigns.expanded, note_id))

        {"summary", %{}, %{}, _} ->
          assign(socket, :summaries, toggle(socket.assigns.summaries, note_id))

        {"cancel", _, _, _} ->
          assign(socket, :confirming, nil)

        {"use", %{can_decide: true}, %{}, %{kind: "timing", decision: nil}} ->
          assign(socket, confirming: {note.id, item.id}, error: nil)

        {action, %{can_decide: true} = row, %{} = note, %{} = item}
        when action in ["use", "ignore", "confirm", "undo"] ->
          user = fresh_user(socket)

          result =
            cond do
              action == "undo" ->
                WeeklyNotes.undo(scope(user, row.profile), note.id, item.id, user.id)

              action == "confirm" and socket.assigns.confirming != {note.id, item.id} ->
                {:error, :confirmation_required}

              true ->
                WeeklyNotes.decide(
                  scope(user, row.profile),
                  note.id,
                  item.id,
                  if(action == "ignore", do: "ignore", else: "use"),
                  user.id,
                  confirmed: action == "confirm"
                )
            end

          case result do
            {:ok, _} -> assign(socket, error: nil, confirming: nil)
            {:error, reason} -> assign(socket, :error, error_text(reason))
          end

        _ ->
          assign(
            socket,
            :error,
            "This suggestion is no longer available with your current access. Refresh and try again."
          )
      end

    {:noreply, reload(socket)}
  end

  defp toggle(set, id),
    do: if(MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id))

  defp error_text(:effect_changed),
    do: "This change has been edited since it was used. Undo cannot safely remove it."

  defp error_text(:undo_expired), do: "Undo is available only during this note's delivery week."

  defp error_text(_),
    do: "The decision could not be saved. Your suggestion is unchanged; refresh and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="space-y-3 [font-family:'Public_Sans',sans-serif]"
      data-role="weekly-notes"
      aria-busy="false"
    >
      <p
        :if={@error}
        role="alert"
        class="rounded-box border border-base-300 p-3 text-sm text-base-content"
      >
        {@error}
      </p>
      <div
        :if={@facts}
        data-role="weekly-note-facts"
        class="rounded-box border border-base-300 bg-base-100 p-4 text-sm"
      >
        <h2 class="font-semibold">Measured facts · {@facts.profile.name}</h2>
        <p>
          Reporting week {Date.to_iso8601(@facts.data.reporting_week_start)} · {@facts.data.timezone}. Delivery week {Date.to_iso8601(
            @facts.data.week_start
          )}.
        </p>
        <p>{@facts.data.published_count} published posts</p>
        <details>
          <summary class="cursor-pointer">View measured facts</summary>
          <div
            :for={
              {label, ideas} <- [
                {"Top ideas", @facts.data.top_ideas},
                {"Bottom ideas", @facts.data.bottom_ideas}
              ]
            }
            class="mt-3 space-y-2"
          >
            <h3 class="font-semibold">{label}</h3>
            <div :for={idea <- ideas}>
              <p>{idea.title}</p>
              <p
                :for={{platform, metrics} <- Enum.sort(idea.platform_numbers)}
                class="font-mono text-xs"
              >
                {platform_label(platform)} · {metric_text(metrics)}
              </p>
            </div>
          </div>
          <p :for={bucket <- @facts.data.timing_differences} class="mt-2 font-mono text-xs">
            {platform_label(bucket.platform)} · {Enum.at(
              ~w(Mon Tue Wed Thu Fri Sat Sun),
              bucket.weekday - 1
            )} {bucket.time} · {bucket.sample_count} samples
          </p>
          <p :for={idea <- @facts.data.recycle_candidates} class="mt-2">
            Recycle candidate: {idea.title}
          </p>
          <p :for={goal <- @facts.data.goal_progress} class="mt-2 font-mono text-xs">
            Weekly goal: {goal.published} of {goal.goal}
          </p>
        </details>
      </div>
      <div :for={row <- @rows} class="space-y-2" data-profile={row.profile.id}>
        <.note
          :if={row.current}
          note={row.current}
          row={row}
          target={@myself}
          summaries={@summaries}
          confirming={@confirming}
        />
        <div :for={note <- row.older} data-role="weekly-note-older">
          <button
            type="button"
            class="flex w-full items-center gap-2 py-2 text-left text-xs text-base-content/70"
            phx-click="older"
            phx-target={@myself}
            phx-value-note={note.id}
            aria-expanded={to_string(MapSet.member?(@expanded, note.id))}
          >
            <.icon
              name="hero-chevron-right"
              class={if MapSet.member?(@expanded, note.id), do: "size-3 rotate-90", else: "size-3"}
            /> Week of {Calendar.strftime(note.week_start, "%b %-d")} · {counts(note)}
          </button>
          <.note
            :if={MapSet.member?(@expanded, note.id)}
            note={note}
            row={row}
            target={@myself}
            summaries={@summaries}
            confirming={@confirming}
          />
        </div>
      </div>
    </div>
    """
  end

  defp note(assigns) do
    assigns = assign(assigns, :author, author(assigns.note))

    ~H"""
    <article
      id={"weekly-note-#{@note.id}"}
      data-role="weekly-note"
      class="rounded-box border border-base-300 bg-base-100 text-sm text-base-content"
    >
      <div class="space-y-3 p-4 sm:p-5">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-base font-semibold">This week: what worked</h2>
          <div class="flex min-w-0 items-center gap-3 text-xs">
            <span
              class="min-w-0 truncate text-base-content/70"
              title={"Delivery week in #{@row.profile.timezone}; reports the preceding completed week"}
            >
              Week of {Calendar.strftime(@note.week_start, "%b %-d")} · {@row.profile.name}
            </span>
            <span
              :if={@note.author_kind == "system"}
              class="flex shrink-0 items-center gap-1"
              data-role="system-author"
            >
              <.icon name="hero-information-circle" class="size-4 text-info" />Written by Burrow (system)
            </span>
            <span
              :if={@note.author_kind == "agent"}
              class="flex shrink-0 items-center gap-2"
              data-role="agent-author"
            >
              <img
                :if={@author.avatar_url}
                src={@author.avatar_url}
                alt=""
                class="size-6 rounded-full"
              />
              <span
                :if={!@author.avatar_url}
                class="flex size-6 items-center justify-center rounded-full bg-base-200"
                aria-hidden="true"
              >{initial(@author.name)}</span>{@author.name}
            </span>
          </div>
        </div>
        <p
          data-role="weekly-note-summary"
          class={
            if MapSet.member?(@summaries, @note.id),
              do: "whitespace-pre-wrap",
              else: "line-clamp-3 whitespace-pre-wrap"
          }
        >
          {@note.summary}
        </p>
        <button
          type="button"
          class="text-xs underline"
          phx-click="summary"
          phx-value-note={@note.id}
          phx-target={@target}
          aria-expanded={to_string(MapSet.member?(@summaries, @note.id))}
        >
          {if MapSet.member?(@summaries, @note.id), do: "Show less", else: "Show all"}
        </button>
      </div>
      <div class="divide-y divide-base-300 border-t border-base-300">
        <div
          :for={item <- @note.items}
          data-role="weekly-note-item"
          data-item={item.id}
          class="space-y-3 p-4 sm:p-5"
        >
          <div class="flex flex-col gap-1 sm:flex-row sm:gap-3">
            <span class="shrink-0 text-xs uppercase text-base-content/70">{item.kind}</span>
            <p>{item.text}</p>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <p
              data-role="weekly-note-consequence"
              class="min-w-0 whitespace-normal break-words text-base-content"
            >
              <%= if @confirming == {@note.id, item.id} and @row.can_decide do %>
                Add <span class="font-mono text-xs">{slot_label(item)}</span>
                to {account_name(@row.profile, item)}?
              <% else %>
                <%= if item.kind == "timing" do %>
                  Adds <span class="font-mono text-xs">{slot_label(item)}</span>
                  to {account_name(@row.profile, item)} posting slots
                <% else %>
                  {consequence(@row.profile, item)}
                <% end %>
              <% end %>
            </p>
            <div
              :if={@row.can_decide and is_nil(item.decision)}
              class="grid w-full shrink-0 grid-cols-2 gap-2 sm:w-auto"
              data-role="weekly-note-actions"
            >
              <%= if @confirming == {@note.id, item.id} do %>
                <button
                  type="button"
                  class="btn btn-sm btn-primary text-primary-content rounded-field phx-click-loading:opacity-50"
                  phx-click="confirm"
                  phx-value-note={@note.id}
                  phx-value-item={item.id}
                  phx-target={@target}
                  phx-disable-with="Saving…"
                >
                  Confirm
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost rounded-field"
                  phx-click="cancel"
                  phx-target={@target}
                >
                  Cancel
                </button>
              <% else %>
                <button
                  type="button"
                  class="btn btn-sm btn-primary text-primary-content rounded-field phx-click-loading:opacity-50"
                  phx-click="use"
                  phx-value-note={@note.id}
                  phx-value-item={item.id}
                  phx-target={@target}
                  phx-disable-with="Saving…"
                >
                  Use this
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost rounded-field"
                  phx-click="ignore"
                  phx-value-note={@note.id}
                  phx-value-item={item.id}
                  phx-target={@target}
                  phx-disable-with="Saving…"
                >
                  Ignore
                </button>
              <% end %>
            </div>
          </div>
          <div
            :if={item.decision}
            class="flex items-center gap-2 text-xs"
            data-role="weekly-note-decision"
          >
            <.icon :if={item.decision == "use"} name="hero-check-circle" class="size-4 text-success" />
            <span class={
              if item.decision == "ignore", do: "text-base-content/70", else: "text-base-content"
            }>
              {decision_text(item, @row.profile)}
            </span>
            <button
              :if={@row.can_decide and current_week(@row.profile) == @note.week_start}
              type="button"
              class="ml-auto underline"
              phx-click="undo"
              phx-value-note={@note.id}
              phx-value-item={item.id}
              phx-target={@target}
              phx-disable-with="Saving…"
            >
              Undo
            </button>
          </div>
        </div>
      </div>
    </article>
    """
  end

  defp author(%{author_kind: "agent", author_id: id}) do
    case Repo.get(Platform.Agents.Agent, id) do
      nil -> %{name: "Agent", avatar_url: nil}
      agent -> agent
    end
  end

  defp author(_), do: nil

  defp metric_text(metrics),
    do:
      metrics
      |> Enum.sort()
      |> Enum.map_join(" · ", fn {key, value} ->
        "#{key}: #{if is_nil(value), do: "No data", else: value}"
      end)

  defp counts(note),
    do:
      "#{Enum.count(note.items, &(&1.decision == "use"))} used, #{Enum.count(note.items, &(&1.decision == "ignore"))} ignored"

  defp slot_label(item),
    do:
      "#{Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), item.payload["weekday"] - 1)} #{item.payload["time"]}"

  defp account_name(profile, item) do
    case Social.get_account(profile.org_id, item.payload["account_id"]) do
      %{profile_id: id, platform: platform} when id == profile.id -> platform_label(platform)
      _ -> "posting slots"
    end
  end

  defp consequence(profile, %{kind: "timing"} = item),
    do: "Adds #{slot_label(item)} to #{account_name(profile, item)} posting slots"

  defp consequence(_, %{kind: "voice", payload: payload}),
    do: "Adds to brand voice: #{payload["text"]}"

  defp consequence(profile, %{kind: "recycle", payload: payload}) do
    case Social.Ideas.get(profile.org_id, payload["idea_id"]) do
      %{profile_id: id, title: title} when id == profile.id -> "Queues #{title} for recycling"
      _ -> "Queues this idea for recycling"
    end
  end

  defp consequence(_, _), do: "Records that this suggestion was used; no brand settings change"

  defp decision_text(item, profile) do
    name = Platform.Accounts.get_user(item.decided_by_user_id) |> user_name()

    at =
      item.decided_at |> DateTime.shift_zone!(profile.timezone) |> Calendar.strftime("%a %H:%M")

    "#{if item.decision == "use", do: "Used", else: "Ignored"} by #{name} · #{at}"
  end
end
