defmodule PlatformWeb.GoalsBriefComponent do
  @moduledoc """
  The reader's goal section in core's daily brief (Goals 6/8).

  Every update and event reloads the signed reader, goals.use and the dated
  items. Events derive goal and ask identities from those items, including
  action identities from the selected report. Client goal and ask ids have
  no authority. All data goes through public contexts.

  ## Design deviations

  - The canvas kind resolves the renderer’s user tuple through Accounts; the
    shared deck still receives only a User. Nil viewers render no card text.

  - One immutable Undo notebook entry identifies each action's request. Keep
    and Resume undo entries preserve later preference changes, linked to that
    original request; no notebook history or original action is rewritten.
  - Undo is a request for the next check-in, because the coach must perform
    the reversal; Cancel undo cancels that request.
  - The ask box sends a written question for the next check-in; there is no
    instant answer or reply bubble because no synchronous coach exists.
  - There are no canned question pills; the reader writes the question.
  - Offer receipts say Used or Not now: the prototype's sample receipts
    promise additions to notes or a Thursday repeat the code does not do.
  - Not now has no toast: the card itself carries the receipt and Undo.
  - The section note sits at its foot, names "your coach" instead of a
    sample name, and has no Briefing settings link (no destination exists).
  - Retro, change-the-goal and slow-down notice cards are added to the brief,
    the one goal push surface; the canvas has no briefing versions of them.
  - Keep it replaces the canvas's sample-specific second pill labels.
  - Switch changes lists the exact settings written; the canvas's Sunday quiz
    and report choices cannot be represented by these settings.
  - Switch and Keep it have no Undo; settings can be changed on the goal page.
  - The pace clause omits the sample weekly percentage and adds an on-track
    form, which the canvas does not show.
  - One stop footer replaces the sample-specific "9 of 24" and "180 so far"
    variants; later stops say Next stop, and no stop leaves only the link.
  - Idea and check-in cards also appear in the brief, the one goal push
    surface; the prototype reaches their screens only from the goal page.
  - The researching card belongs to the creation conversation (Goals 5/8).
  - A goal with no measurable reading or target has no number sentence;
    the prototype shows only a measured sample.
  - A practice pass is recorded only when it ends, so leaving mid-pass loses
    that pass; unrelated live updates preserve the current pass.
  - The reading sentence (That makes) appears only when the owner logs a
    self-reported practice reading. Done for today remains for every addressed
    reader: the stage's declaration called this the first sentence, but its
    inventory and tests restrict the reading sentence.
  - Practice shares the one stop footer; the prototype's 180 so far is sample.
  - Check-in choices start unselected; the prototype preselects sample
    choices. Untouched suggestions are recorded as Not now on Finish.
  - The done heading says Your choices are in: the page records choices,
    and the coach updates the plan at the next wake-up. The Finish note
    keeps the inventory's wording; it describes those queued choices.
  - A check-in uses the coach's supplied title, summary, moved lines and
    suggestions; with none, it has its title and Finish button.
  - Idea acceptance says the coach starts at the next check-in. There is
    no stop-it-any-time note or Just started action card: no work starts
    until the coach records it.
  - The nested goal view returns from an idea to the goal and its toast
    without a route change; the idea URL is retained so a reload shows its
    answered receipt. No new JavaScript or core navigation seam is added.
  - The caught-up card has no retro preview, which belongs to Goals 8/8.
  - Notebook answer lines and the practice streak pill are additions the
    ticket requires; they are absent from the prototype.
  """
  use PlatformWeb, :live_component
  alias Platform.Goals
  alias PlatformWeb.GoalsBriefCards

  @impl true
  def mount(socket) do
    {:ok, assign(socket, items: [], reader: nil, open_asks: MapSet.new(), blank: MapSet.new())}
  end

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> reload()}

  defp reload(socket) do
    user = Platform.Accounts.get_user(socket.assigns.user_id)

    items =
      with true <- Goals.enabled?(),
           %Platform.Accounts.User{} <- user,
           true <- Platform.Goals.Visibility.may_use?(user),
           {:ok, items} <- Goals.brief_items(user, socket.assigns.date),
           do: items,
           else: (_ -> [])

    items =
      Enum.map(items, fn item ->
        with {:ok, goal} <- Goals.get_goal(user, item.goal.id),
             {:ok, authors} <- Goals.entry_authors(user, goal.id),
             {:ok, stops} <- Goals.list_stops(user, goal.id) do
          slot = get_in(authors, [:agents, goal.coach_agent_id, :slot])
          coach = get_in(authors, [:agents, goal.coach_agent_id, :name])

          item =
            item
            |> Map.put(:coach_slot, slot)
            |> Map.put(:goal, Map.merge(item.goal, %{coach_name: coach, rhythm: goal.rhythm}))
            |> Map.put_new(:stop, Enum.find(stops, &is_nil(&1.reached_on)))

          if item.kind == :retro_change do
            case Goals.get_retro(user, goal.id, item.entry_id) do
              {:ok, retro} -> Map.put(item, :flat_retros, retro.flat_retros)
              _ -> Map.put(item, :flat_retros, 0)
            end
          else
            item
          end
        else
          _ -> Map.put(item, :coach_slot, nil)
        end
      end)

    assign(socket, reader: user, items: items)
  end

  @impl true
  def handle_event(event, params, socket) do
    socket = reload(socket)

    item =
      Enum.find(socket.assigns.items, fn item ->
        item.id == params["item_id"] &&
          (event not in ["retro_switch", "retro_keep"] || item.kind == :retro_change)
      end)

    if item && identities_match?(params, item) do
      event(event, params, item, socket)
    else
      {:noreply, socket}
    end
  end

  defp identities_match?(params, item) do
    goal_matches = not Map.has_key?(params, "goal_id") or params["goal_id"] == item.goal.id

    ask_matches =
      not Map.has_key?(params, "ask_id") or
        params["ask_id"] == Map.get(Map.get(item, :ask) || %{}, :id)

    entry_matches =
      not Map.has_key?(params, "entry_id") or
        item.kind not in [:retro, :retro_change] or params["entry_id"] == item.entry_id

    goal_matches and ask_matches and entry_matches
  end

  defp event("ask-open", _, %{kind: :report} = item, socket),
    do: {:noreply, assign(socket, :open_asks, MapSet.put(socket.assigns.open_asks, item.id))}

  defp event("ask-cancel", _, item, socket),
    do: {:noreply, assign(socket, :open_asks, MapSet.delete(socket.assigns.open_asks, item.id))}

  defp event("ask-send", params, %{kind: :report} = item, socket) do
    text = params["question"] || ""

    if not is_binary(text) or String.trim(text) == "" do
      {:noreply, assign(socket, :blank, MapSet.put(socket.assigns.blank, item.id))}
    else
      result = Goals.ask_coach(socket.assigns.reader, item.goal.id, text, item_id: item.id)

      socket =
        if match?({:ok, _}, result),
          do: assign(socket, :open_asks, MapSet.delete(socket.assigns.open_asks, item.id)),
          else: socket

      written(result, socket)
    end
  end

  defp event("noted", params, %{kind: :report} = item, socket),
    do:
      written(
        Goals.set_report_noted(socket.assigns.reader, item.id, params["noted"] == "true"),
        socket
      )

  defp event("retro_noted", params, %{kind: :retro} = item, socket) do
    result = Goals.set_report_noted(socket.assigns.reader, item.id, params["noted"] == "true")
    retro_written(result, item, socket)
  end

  defp event(event, _, %{kind: :retro_change} = item, socket)
       when event in ["retro_switch", "retro_keep"] do
    decision = if event == "retro_switch", do: "switch", else: "keep"

    result =
      Goals.decide_retro_change(socket.assigns.reader, item.goal.id, item.entry_id, decision)

    retro_written(result, item, socket)
  end

  defp event("undo", params, %{kind: :report} = item, socket) do
    entry = Enum.find(item.entries, &(&1.id == params["entry_id"]))

    if entry && params["request"] in ["undo", "keep"] do
      written(
        Goals.request_undo(socket.assigns.reader, item.goal.id, entry.id, params["request"]),
        socket
      )
    else
      {:noreply, socket}
    end
  end

  defp event("answer", params, %{kind: kind} = item, socket)
       when kind in [:offer, :idea, :question] do
    if params["answer"] in ["used", "declined"],
      do: written(Goals.answer_ask(socket.assigns.reader, item.ask.id, params["answer"]), socket),
      else: {:noreply, socket}
  end

  defp event("withdraw", _, %{kind: kind} = item, socket) when kind in [:offer, :idea, :question],
    do: written(Goals.withdraw_answer(socket.assigns.reader, item.ask.id), socket)

  defp event(_, _, _, socket), do: {:noreply, socket}

  defp retro_written({:ok, _}, item, socket) do
    Goals.refresh_brief(socket.assigns.reader, {:entry, item.entry_id})
    {:noreply, reload(socket)}
  end

  defp retro_written(_, _, socket), do: {:noreply, socket}

  defp written({:ok, _}, socket) do
    Platform.Memory.Insights.BriefingSections.changed(socket.assigns.user_id, socket.assigns.date)
    {:noreply, reload(socket)}
  end

  defp written(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="goals-brief" phx-target={@myself}>
      <section :if={@items != []} aria-labelledby={@id <> "-heading"}>
        <h3
          id={@id <> "-heading"}
          class="mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
        >
          Your goals · {length(@items)}
        </h3>
        <ul role="list" class="space-y-3">
          <li :for={item <- @items}>
            <GoalsBriefCards.card
              item={item}
              target={@myself}
              viewer={@reader}
              ask_open={MapSet.member?(@open_asks, item.id)}
              blank={MapSet.member?(@blank, item.id)}
            />
          </li>
        </ul>
        <p class="mt-6 border-t border-edge pt-3 text-xs text-subtle">
          Each goal sends what fits it: a report when your coach does the work, an offer when you share it, practice when it's yours to do.
        </p>
      </section>
    </div>
    """
  end
end
