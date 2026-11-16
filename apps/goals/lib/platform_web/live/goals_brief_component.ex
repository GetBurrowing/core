defmodule PlatformWeb.GoalsBriefComponent do
  @moduledoc """
  The reader's goal section in core's daily brief (Goals 6/8).

  Every update and event reloads the signed reader, goals.use and the dated
  items. Events derive goal and ask identities from those items, including
  action identities from the selected report. Client goal and ask ids have
  no authority. All data goes through public contexts.

  ## Design deviations

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
  - The pace clause after Where we are belongs to Goals 8/8.
  - One stop footer replaces the sample-specific "9 of 24" and "180 so far"
    variants; later stops say Next stop, and no stop leaves only the link.
  - Idea and check-in cards also appear in the brief, the one goal push
    surface; the prototype reaches their screens only from the goal page.
  - The researching card belongs to the creation conversation (Goals 5/8).
  - A goal with no measurable reading or target has no number sentence;
    the prototype shows only a measured sample.
  - Practice is a queued card here; its playable body is added in stage 4.
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
           true <- Platform.Access.can?(Platform.Access.Scope.for_user(user), "goals.use"),
           {:ok, items} <- Goals.brief_items(user, socket.assigns.date),
           do: items,
           else: (_ -> [])

    items =
      Enum.map(items, fn item ->
        slot =
          with {:ok, goal} <- Goals.get_goal(user, item.goal.id),
               {:ok, authors} <- Goals.entry_authors(user, goal.id),
               %{slot: slot} <- authors.agents[goal.coach_agent_id],
               do: slot,
               else: (_ -> nil)

        Map.put(item, :coach_slot, slot)
      end)

    assign(socket, reader: user, items: items)
  end

  @impl true
  def handle_event(event, params, socket) do
    socket = reload(socket)
    item = Enum.find(socket.assigns.items, &(&1.id == params["item_id"]))

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

    goal_matches and ask_matches
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
