defmodule PlatformWeb.GoalsFlashCardsComponent do
  @moduledoc "One reader-scoped practice deck for brief and canvas (Goals 6/8). A complete pass is the unit of writing."
  use PlatformWeb, :live_component
  alias Platform.Goals

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       ask: nil,
       fingerprint: nil,
       deck: [],
       cursor: 0,
       flipped: false,
       results: [],
       done: false,
       reading: nil,
       got: 0,
       missed: 0,
       streak: 0,
       coach_mode: false
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> reload()}

  defp reload(socket) do
    viewer = socket.assigns.viewer

    loaded =
      with %Platform.Accounts.User{} <- viewer,
           %Platform.Accounts.User{} = user <- Platform.Accounts.get_user(viewer.id),
           true <- Goals.enabled?(),
           true <- Platform.Goals.Visibility.may_use?(user),
           {:ok, ask} <- Goals.get_ask(user, socket.assigns.ask_id),
           true <- ask.kind == "practice" and user.id in ask.addressed_user_ids,
           {:ok, goal} <- Goals.get_goal(user, ask.goal_id),
           {:ok, streak} <- Goals.practice_streak(user, goal.id) do
        {:ok, user, ask, goal, streak}
      else
        _ -> :hidden
      end

    case loaded do
      {:ok, user, ask, goal, streak} ->
        answer = Enum.find(ask.answers, &(&1.user_id == user.id))

        fingerprint =
          {user.id, ask.id, ask.payload,
           answer && Map.take(answer, [:id, :details, :answer, :answered_at])}

        socket =
          assign(socket,
            viewer: user,
            ask: ask,
            coach_mode: goal.agent_mode == "coach",
            streak: streak
          )

        if socket.assigns.fingerprint == fingerprint do
          socket
        else
          details = if answer && answer.answer == "used", do: answer.details, else: %{}

          assign(socket,
            fingerprint: fingerprint,
            deck: cards(ask),
            cursor: 0,
            flipped: false,
            results: [],
            done: not is_nil(answer) and answer.answer == "used",
            reading: nil,
            got: details["got"] || 0,
            missed: details["missed"] || 0
          )
        end

      :hidden ->
        assign(socket,
          ask: nil,
          fingerprint: nil,
          deck: [],
          cursor: 0,
          flipped: false,
          results: [],
          done: false,
          reading: nil,
          got: 0,
          missed: 0,
          streak: 0,
          coach_mode: false
        )
    end
  end

  defp cards(ask) do
    ask.payload["cards"]
    |> Enum.with_index()
    |> Enum.map(fn {card, index} -> %{index: index, front: card["front"], back: card["back"]} end)
  end

  @impl true
  def handle_event(event, params, socket) do
    socket = reload(socket)
    conflicting = Map.has_key?(params, "ask_id") and params["ask_id"] != socket.assigns.ask_id

    cond do
      socket.assigns.ask && not conflicting ->
        event(event, params, socket)

      is_nil(socket.assigns.ask) ->
        # Refused (a revoked goals.use, a closed goal): the deck hides, and
        # the brief around it reloads so no goal title or body stays on the
        # page until the brief's own next event (task 01a1e229 stage 2).
        if parent = socket.assigns[:parent], do: send_update(parent, %{})
        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  defp event("flip-key", %{"key" => key}, socket) when key in ["Enter", " ", "Spacebar"],
    do: event("flip", %{}, socket)

  defp event("flip", _, socket) do
    {:noreply, if(socket.assigns.done, do: socket, else: assign(socket, :flipped, true))}
  end

  defp event(result, _, socket) when result in ["got", "missed"] do
    if socket.assigns.flipped && not socket.assigns.done do
      card = Enum.at(socket.assigns.deck, socket.assigns.cursor)
      results = socket.assigns.results ++ [%{"index" => card.index, "result" => result}]

      if socket.assigns.cursor + 1 == length(socket.assigns.deck) do
        finish(socket, results)
      else
        {:noreply,
         assign(socket, results: results, cursor: socket.assigns.cursor + 1, flipped: false)}
      end
    else
      {:noreply, socket}
    end
  end

  defp event("retry", _, socket) do
    answer = Enum.find(socket.assigns.ask.answers, &(&1.user_id == socket.assigns.viewer.id))

    missed =
      if answer && answer.answer == "used",
        do:
          for(
            card <- answer.details["cards"] || [],
            card["result"] == "missed",
            do: card["index"]
          ),
        else: []

    if socket.assigns.done && missed != [] do
      deck = Enum.filter(cards(socket.assigns.ask), &(&1.index in missed))

      {:noreply,
       assign(socket,
         deck: deck,
         cursor: 0,
         flipped: false,
         results: [],
         done: false,
         reading: nil
       )}
    else
      {:noreply, socket}
    end
  end

  defp event(_, _, socket), do: {:noreply, socket}

  defp finish(socket, results) do
    case Goals.record_practice(socket.assigns.viewer, socket.assigns.ask.id, results) do
      {:ok, result} ->
        {:noreply,
         socket
         |> reload()
         |> assign(
           reading: result.reading,
           got: result.got,
           missed: result.missed,
           streak: result.streak,
           done: true
         )}

      {:error, _} ->
        {:noreply, assign(socket, cursor: 0, flipped: false, results: []) |> reload()}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :card, Enum.at(assigns.deck, assigns.cursor))

    ~H"""
    <div id={@id} data-role="goals-flash-cards" data-ask-id={@ask && @ask.id} phx-target={@myself}>
      <div :if={@ask} class="mt-3">
        <button
          :if={!@done && @card}
          type="button"
          data-role="flash-card"
          aria-label="Turn the card over"
          phx-click="flip"
          phx-keydown="flip-key"
          phx-target={@myself}
          class="focus-visible-ring flex min-h-32 w-full flex-col items-center justify-center rounded-xl border border-edge bg-base-200 px-4 py-6 text-center"
        >
          <span class="text-2xl font-bold text-base-content">
            {if @flipped, do: @card.back, else: @card.front}
          </span>
          <span class="mt-2 text-xs text-subtle">
            {if @flipped, do: @card.front, else: "Tap to turn it over"}
          </span>
        </button>
        <div :if={!@done} class="mt-3 flex flex-wrap items-center justify-between gap-2">
          <span class="text-xs text-subtle">Card {@cursor + 1} of {length(@deck)}</span>
          <button
            :if={!@flipped}
            type="button"
            class="btn btn-sm min-h-11 focus-visible-ring btn-primary lg:min-h-0"
            phx-click="flip"
            phx-target={@myself}
            data-action="flip"
          >
            Turn it over
          </button>
          <div :if={@flipped} class="flex gap-2">
            <button
              type="button"
              class="btn btn-sm min-h-11 focus-visible-ring border-edge bg-base-300 text-base-content lg:min-h-0"
              phx-click="missed"
              phx-target={@myself}
              data-action="missed"
            >
              Missed it
            </button>
            <button
              type="button"
              class="btn btn-sm min-h-11 focus-visible-ring btn-primary lg:min-h-0"
              phx-click="got"
              phx-target={@myself}
              data-action="got"
            >
              Got it
            </button>
          </div>
        </div>
        <div
          :if={@done}
          data-role="flash-card-done"
          class="flex min-h-32 flex-col items-center justify-center rounded-xl border border-edge bg-base-200 px-4 py-6 text-center"
        >
          <p class="text-base font-semibold text-base-content">
            Done for today: {@got} of {length(cards(@ask))}
          </p>
          <p :if={@reading} class="mt-2 text-sm text-subtle">
            That makes {number(@reading.value)} {@reading.unit}.
          </p>
          <p :if={@coach_mode && @streak > 0} class="mt-1 text-sm text-subtle">
            {@streak} {if @streak == 1, do: "day", else: "days"} in a row.
          </p>
        </div>
        <button
          :if={@done && @missed > 0}
          type="button"
          class="btn btn-sm min-h-11 focus-visible-ring mt-3 border-edge bg-base-300 text-base-content lg:min-h-0"
          phx-click="retry"
          phx-target={@myself}
          data-action="retry"
        >
          Practise the {@missed} you missed
        </button>
      </div>
    </div>
    """
  end

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
end
