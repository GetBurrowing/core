defmodule PlatformWeb.GoalsNew do
  @moduledoc """
  The New goal screen (task 01a1dfc1-7625, Goals 5/8 stage 3) at
  `/m/goals?new=1`, built to canvas 01a15ef6 node `p` (prototype v4), screen
  `create`. `PlatformWeb.GoalsLive` mounts it, forwards every `new_*` event
  and every PubSub message here, and draws it in the detail pane.

  ## The conversation

  It is the proposal's own conversation space with the install's lead agent
  (never the person's DM with it; task 01a1eab6 stage 2), created by
  `Platform.Goals.start_goal_conversation/2`. This page
  renders that conversation itself. It does not call
  `PlatformWeb.ChatLive` or `PlatformWeb.Components.ChatMessage.chat_message/1`
  (a nested page gets no `handle_params`, and the component needs ChatLive's
  assigns and events). The message row's class recipe is COPIED from
  `apps/platform/lib/platform_web/components/chat_message.ex`
  (`chat_message/1`: the `msg-agent` row, `msg-agent-avatar`,
  `msg-agent-name`, `msg-agent-badge`, the own-row `bg-base-200/60`, the
  `text-sm text-base-content break-words chat-markdown` body). When core's
  row changes, grep for that path. Bodies go through
  `Platform.Chat.ContentRenderer.render_message/1`; avatars through
  `PlatformWeb.AvatarComponents`.

  ## Trust

  Every read goes through `Platform.Goals` (and core's public chat
  functions). Every event takes the proposal from
  `Platform.Goals.current_proposal/1` on the server; a proposal id, goal id
  or setting sent by the client is never read. A quick reply is sent by its
  index into the server's `replies`. Create goal calls
  `Platform.Goals.confirm_proposal/3` with the revision the page last
  RENDERED, carried in the click; if the agent rewrote the proposal since,
  the context answers `:proposal_changed` and nothing is written.
  PubSub messages (`{:new_message, _}` on the conversation space,
  `{:goal_proposal_changed, _}` on the proposal and on the person's own
  `"goals:proposals:user:<user_id>"`) only trigger a re-read; their payload is never rendered.

  After Create the proposal is no longer open, so the page keeps the id of
  the proposal IT confirmed (a server value) and re-reads it with
  `Platform.Goals.get_proposal/2`. It also keeps the id of the last message
  it showed before the click: messages after it (the coach's researching
  message, stage 4) are drawn after "Goal created · only you can see it",
  where the canvas puts them, as they arrive in the conversation space.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Goals
  alias PlatformWeb.AvatarComponents
  alias PlatformWeb.GoalsComponents
  alias PlatformWeb.GoalsPage

  @examples [
    %{
      key: "yt",
      label: "Grow How to Computer",
      text: "I want How to Computer to be a big channel. Really big."
    },
    %{key: "es", label: "Learn Spanish", text: "I want to learn Spanish."}
  ]
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @settings ~w(source agent_mode rhythm outreach)

  @empty_toast "Say what you want to achieve, or try an example"
  @changed_toast "The goal changed. Have another look before you create it."

  @chip "focus-visible-ring inline-flex h-8 cursor-pointer items-center rounded-full border border-edge bg-transparent px-3 text-sm text-subtle transition-colors lg:hover:text-base-content disabled:opacity-50"
  @field "w-full min-w-0 flex-1 rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-subtle"

  # ── state ──────────────────────────────────────────────────────────────

  @doc "Sets up the screen for `user` on `socket` (assign `:new`)."
  def mount(socket, user) do
    # A screen open before the person starts a goal (here or in another
    # window) has no proposal to subscribe to; the person's own topic tells
    # it one started, and `refresh/1` then subscribes to the proposal and its
    # space (task 01a1eab6 stage 5). Mounted once per LiveView process.
    if Phoenix.LiveView.connected?(socket), do: Goals.subscribe_proposals(user)

    socket
    |> Phoenix.Component.assign(:new, %{
      user: user,
      text: "",
      fill: 0,
      refused: false,
      created: nil,
      subscribed: MapSet.new()
    })
    |> refresh()
  end

  @doc "Re-reads everything through the context."
  def refresh(%{assigns: %{new: %{user: user} = new}} = socket) do
    lead =
      case Goals.lead_agent(user) do
        {:ok, agent} -> agent
        _ -> nil
      end

    proposal = shown_proposal(user, new.created)

    messages =
      with %{id: id} <- proposal, {:ok, messages} <- Goals.conversation(user, id) do
        messages
      else
        _ -> []
      end

    sources =
      case Goals.list_sources(user) do
        {:ok, sources} -> sources
        _ -> []
      end

    new =
      Map.merge(new, %{
        lead: lead,
        proposal: proposal,
        agent: agent_view(lead, proposal),
        messages: messages,
        sources: sources
      })

    socket
    |> Phoenix.Component.assign(:new, new)
    |> subscribe(proposal)
  end

  def refresh(socket), do: socket

  # The open proposal, else the one this page confirmed (id held server-side).
  defp shown_proposal(user, created) do
    case Goals.current_proposal(user) do
      {:ok, %{} = proposal} ->
        proposal

      _ ->
        with %{proposal_id: id} <- created, {:ok, proposal} <- Goals.get_proposal(user, id) do
          proposal
        else
          _ -> nil
        end
    end
  end

  defp acting_proposal(%{assigns: %{new: new}}), do: shown_proposal(new.user, new.created)

  defp subscribe(socket, %{id: id, space_id: space_id}) do
    new = socket.assigns.new

    if Phoenix.LiveView.connected?(socket) and not MapSet.member?(new.subscribed, id) do
      with :ok <- Goals.subscribe_proposal(new.user, id) do
        Platform.Chat.PubSub.subscribe(space_id)
      end

      Phoenix.Component.assign(socket, :new, %{new | subscribed: MapSet.put(new.subscribed, id)})
    else
      socket
    end
  end

  defp subscribe(socket, _proposal), do: socket

  defp agent_view(%{id: id} = agent, proposal)
       when is_nil(proposal) or (is_map(proposal) and :erlang.map_get(:agent_id, proposal) == id),
       do: %{
         name: agent.name,
         slot: Platform.Agents.ColorPalette.slot_for(agent.color),
         avatar_url: agent.avatar_url
       }

  # The role moved after the conversation started: name the agent from its
  # participant row in the conversation space.
  defp agent_view(_lead, %{space_id: space_id, agent_id: agent_id}) do
    case Platform.Chat.get_agent_participant(space_id, agent_id) do
      %{display_name: name, avatar_url: url} ->
        %{
          name: name || "Agent",
          slot: Platform.Agents.ColorPalette.slot_for(nil),
          avatar_url: url
        }

      _ ->
        %{name: "Agent", slot: Platform.Agents.ColorPalette.slot_for(nil), avatar_url: nil}
    end
  end

  defp agent_view(_lead, _proposal), do: nil

  # ── events ─────────────────────────────────────────────────────────────

  @doc "Handles a `new_*` event. Ids and settings in `params` are never read."
  def handle_event(_event, _params, %{assigns: %{new: nil}} = socket), do: {:noreply, socket}

  def handle_event("new_type", params, socket),
    do: {:noreply, put_new(socket, text: to_string(params["text"] || ""))}

  def handle_event("new_example", %{"example" => key}, socket) do
    case Enum.find(@examples, &(&1.key == key)) do
      %{text: text} -> {:noreply, put_new(socket, text: text, fill: socket.assigns.new.fill + 1)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("new_send", params, socket) do
    text = params |> Map.get("text", "") |> to_string()

    if String.trim(text) == "" do
      {:noreply, toast(socket, @empty_toast)}
    else
      send_text(socket, text)
    end
  end

  def handle_event("new_reply", %{"index" => index}, socket) do
    with %{} = proposal <- acting_proposal(socket),
         true <- proposal.status == "open",
         {:ok, i} <- parse_int(index),
         {:ok, messages} <- Goals.conversation(socket.assigns.new.user, proposal.id),
         true <- replies_open?(messages),
         label when is_binary(label) <- Enum.at(proposal.replies, i) do
      send_text(socket, label)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("new_create", params, socket) do
    user = socket.assigns.new.user

    seen = socket.assigns.new.messages |> List.last() |> then(&(&1 && &1.id))

    with {:ok, %{} = proposal} <- Goals.current_proposal(user),
         {:ok, revision} <- parse_int(params["revision"]) do
      case Goals.confirm_proposal(user, proposal.id, revision) do
        {:ok, %{goal: goal, proposal: confirmed}} ->
          {:noreply,
           socket
           |> put_new(created: %{goal_id: goal.id, proposal_id: confirmed.id, seen: seen})
           |> refresh()
           |> refresh_rows()}

        {:error, :proposal_changed} ->
          {:noreply, socket |> refresh() |> toast(@changed_toast)}

        _ ->
          {:noreply, refresh(socket)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("new_start_over", _params, socket) do
    user = socket.assigns.new.user

    with {:ok, %{} = proposal} <- Goals.current_proposal(user) do
      Goals.cancel_proposal(user, proposal.id)
    end

    {:noreply,
     socket |> put_new(created: nil, text: "", fill: socket.assigns.new.fill + 1) |> refresh()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The list beside the screen gains the new goal.
  defp refresh_rows(socket) do
    user = socket.assigns.new.user

    case Goals.describe_goals(user) do
      {:ok, cards} ->
        Phoenix.Component.assign(socket, :rows, PlatformWeb.GoalsList.rows(user, cards))

      _ ->
        socket
    end
  end

  defp send_text(socket, text) do
    user = socket.assigns.new.user

    result =
      case acting_proposal(socket) do
        nil -> Goals.start_goal_conversation(user, text)
        proposal -> Goals.say_in_conversation(user, proposal.id, text)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_new(text: "", fill: socket.assigns.new.fill + 1, refused: false)
         |> refresh()}

      # The lead's runtime cannot use the Goals tools (task 01a1eab6 stage
      # 3): nothing was written, so keep what the person typed and say why.
      {:error, :lead_missing_goals_tools} ->
        {:noreply, socket |> put_new(text: text, refused: true) |> refresh()}

      {:error, :text_required} ->
        {:noreply, toast(socket, @empty_toast)}

      _ ->
        {:noreply, refresh(socket)}
    end
  end

  @doc "PubSub: a conversation message or a proposal change re-reads the screen."
  def handle_info({:new_message, _}, %{assigns: %{new: %{}}} = socket), do: refresh(socket)

  def handle_info({:goal_proposal_changed, _}, %{assigns: %{new: %{}}} = socket),
    do: refresh(socket)

  def handle_info(_msg, socket), do: socket

  defp put_new(socket, kv),
    do: Phoenix.Component.assign(socket, :new, Map.merge(socket.assigns.new, Map.new(kv)))

  defp toast(socket, message),
    do: Phoenix.Component.assign(socket, :toast, %{message: message, undo: nil})

  defp parse_int(n) when is_integer(n), do: {:ok, n}

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  # ── the stream ─────────────────────────────────────────────────────────

  defp replies_open?(messages) do
    case List.last(messages) do
      %{from: :agent} -> true
      _ -> false
    end
  end

  @doc false
  # The stream after the greeting, ordered by time: messages, the journey
  # card at settled["stops"], one settled line per setting at its time.
  def stream_items(new) do
    proposal = new.proposal

    messages = for m <- new.messages, do: {m.at, {:message, m}}

    settled =
      if proposal do
        draft = proposal.draft

        journey =
          with stamp when is_binary(stamp) <- proposal.settled["stops"],
               {:ok, at} <- time(stamp),
               [_ | _] = stops <- stops(draft) do
            [{at, {:journey, stops}}]
          else
            _ -> []
          end

        lines =
          for setting <- @settings,
              stamp <- [proposal.settled[setting]],
              is_binary(stamp),
              {:ok, at} <- [time(stamp)],
              do: {at, {:settled, setting, settled_line(setting, draft, new)}}

        journey ++ lines
      else
        []
      end

    (messages ++ settled)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{at, _}, i} -> {DateTime.to_unix(at, :microsecond), i} end)
    |> Enum.map(fn {{_, item}, _} -> item end)
  end

  # Messages the page had when its person pressed Create goal stay above the
  # "Goal created" line; later ones (the agent's researching message) follow it.
  defp split_at_created(messages, %{seen: seen}) when is_binary(seen) do
    case Enum.find_index(messages, &(&1.id == seen)) do
      nil -> {messages, []}
      i -> Enum.split(messages, i + 1)
    end
  end

  defp split_at_created(messages, _created), do: {messages, []}

  defp time(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> {:ok, at}
      _ -> :error
    end
  end

  defp stops(%{"stops" => stops}) when is_list(stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.map(fn {stop, i} ->
      %{
        id: i,
        position: i,
        label: stop["label"],
        target_value: decimal(stop["target_value"]),
        due_on: date(stop["due_on"]),
        caption: stop["caption"],
        theme: stop["theme"],
        reached_on: nil
      }
    end)
  end

  defp stops(_draft), do: []

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)

  defp decimal(n) when is_binary(n) do
    case Decimal.parse(n) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp decimal(_), do: nil

  defp date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil

  # ── settled lines ──────────────────────────────────────────────────────

  @doc "The settled line's copy for `setting` (source, agent_mode, rhythm, outreach)."
  def settled_line("source", draft, new) do
    unit = if present?(draft["unit"]), do: draft["unit"] <> ", ", else: ""

    case Enum.find(new.sources, &(&1.key == draft["source_key"])) do
      %{kind: :logged} -> "Number: #{unit}you enter it by hand"
      %{kind: :measured, label: label} -> "Number: #{unit}#{lower_first(label)}"
      _ -> "Number: none yet"
    end
  end

  def settled_line("agent_mode", draft, new),
    do: GoalsPage.roles(%{agent_mode: draft["agent_mode"]}, agent_name(new))

  def settled_line("rhythm", draft, _new) do
    day = weekday(draft["rhythm_weekday"])

    case {draft["rhythm"], day} do
      {"daily", _} -> "Check-in: every day, in your briefing"
      {"weekdays", _} -> "Check-in: on weekdays, in your briefing"
      {"weekly", day} when is_binary(day) -> "Check-in: #{day}s, in your briefing"
      {"biweekly", day} when is_binary(day) -> "Check-in: every other #{day}, in your briefing"
      {"biweekly", _} -> "Check-in: every other week, in your briefing"
      _ -> "Check-in: every week, in your briefing"
    end
  end

  def settled_line("outreach", draft, new) do
    case draft["outreach"] do
      "pushy" -> "Nudges: pushy, a message when something is overdue"
      "off" -> "Nudges: off. #{agent_name(new)} only reports."
      _ -> "Nudges: gentle, one line in your briefing"
    end
  end

  defp weekday(d) when is_integer(d) and d in 1..7, do: Enum.at(@weekdays, d - 1)
  defp weekday(_), do: nil

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(other), do: other

  defp agent_name(%{agent: %{name: name}}), do: name
  defp agent_name(_), do: "Your agent"

  defp first_stop_line(draft) do
    case stops(draft) do
      [%{target_value: %Decimal{} = t, due_on: %Date{} = d} | _] ->
        unit = if present?(draft["unit"]), do: " " <> draft["unit"], else: ""

        "First stop: #{GoalsComponents.format_number(t)}#{unit} by #{Calendar.strftime(d, "%-d %b")}"

      [%{label: label} | _] ->
        "First stop: #{label}"

      [] ->
        nil
    end
  end

  defp privacy_line(%{"kind" => "shared"}, new),
    do:
      "Only you can see it. #{agent_name(new)} suggests sharing it: use Open up on the goal page."

  defp privacy_line(_draft, _new), do: "Only you can see it. You can open it up later."

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  defp first_name(%{name: name}) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> name
    end
  end

  defp first_name(_), do: "there"

  # ── render ─────────────────────────────────────────────────────────────

  @doc "The New goal screen."
  attr :new, :map, required: true

  def screen(assigns) do
    new = assigns.new
    proposal = new.proposal
    open? = match?(%{status: "open"}, proposal)
    created = if(match?(%{status: "confirmed"}, proposal), do: new.created)
    {earlier, later} = split_at_created(Map.get(new, :messages, []), created)

    assigns =
      assign(assigns,
        agent: new.agent,
        proposal: proposal,
        open?: open?,
        stream: stream_items(Map.put(new, :messages, earlier)),
        later: later,
        replies:
          if(open? and replies_open?(new.messages),
            do: Enum.with_index(proposal.replies),
            else: []
          ),
        ready?: open? and proposal.ready,
        created: created,
        offline?: match?(%{delivery: d} when d in ["offline", "no_runtime"], proposal),
        examples: @examples,
        settings: @settings
      )

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goals-new">
      <.link
        navigate="/m/goals"
        class="-ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive focus-visible-ring lg:hidden"
        data-role="goals-new-back"
      >
        ‹ Goals
      </.link>

      <%= if is_nil(@agent) do %>
        <header class="mb-3">
          <h2 class="text-2xl font-bold text-base-content">New goal</h2>
        </header>
        <div data-role="goals-new-no-lead">
          <PlatformWeb.Components.EmptyState.empty_state variant={:minimal}>
            <:body>
              <span class="block font-semibold">No agent leads this install yet</span>
              <span class="mt-1 block">
                An admin can give an agent the agents leader role. Then come back and start again.
              </span>
            </:body>
          </PlatformWeb.Components.EmptyState.empty_state>
        </div>
      <% else %>
        <header class="mb-3 flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 class="text-2xl font-bold text-base-content">New goal</h2>
            <p class="mt-1 text-sm text-subtle" data-role="goals-new-meta">
              A conversation with <span
                data-agent-slot={@agent.slot}
                class="font-semibold text-(--ag-text)"
                data-role="agent-name"
              >{@agent.name}</span>. It can be anything.
            </p>
          </div>
          <button
            :if={@open?}
            type="button"
            phx-click="new_start_over"
            class="focus-visible-ring min-h-11 shrink-0 rounded px-1 text-sm font-semibold text-interactive"
            data-role="goals-new-start-over"
          >
            Start over
          </button>
        </header>

        <div class="flex flex-col gap-2" data-role="goals-new-stream">
          <.agent_message agent={@agent} id="goals-new-greeting" role="goals-new-greeting">
            Hi {first_name(@new.user)}. What do you want to achieve? It can be anything. Say it however it comes to mind, and I'll help turn it into something we can steer by.
          </.agent_message>

          <%= for item <- @stream do %>
            <%= case item do %>
              <% {:message, %{from: :agent} = m} -> %>
                <.agent_message
                  agent={@agent}
                  id={"goals-new-msg-#{m.id}"}
                  at={m.at}
                  role="goals-new-message"
                >
                  {Platform.Chat.ContentRenderer.render_message(m.content)}
                </.agent_message>
              <% {:message, m} -> %>
                <.person_message user={@new.user} message={m} />
              <% {:journey, stops} -> %>
                <div
                  class={[GoalsPage.card_class(), "ml-[52px] overflow-x-auto"]}
                  data-role="goals-new-journey"
                >
                  <GoalsPage.journey
                    page={%{stops: stops, current: hd(stops), number: nil, retros: [], card: nil}}
                    small
                  />
                </div>
              <% {:settled, setting, line} -> %>
                <.settled_line setting={setting} line={line} />
            <% end %>
          <% end %>

          <div
            :if={@replies != []}
            class="flex flex-wrap gap-2 pl-[52px]"
            data-role="goals-new-replies"
          >
            <button
              :for={{label, i} <- @replies}
              type="button"
              phx-click="new_reply"
              phx-value-index={i}
              class={chip_class()}
              data-role="goals-new-reply"
            >
              {label}
            </button>
          </div>

          <div
            :if={@ready? or @created}
            class={[GoalsPage.card_class(), "ml-[52px]"]}
            data-role="goals-new-summary"
          >
            <h4 class="text-base font-bold text-base-content" data-role="goals-new-summary-title">
              {@proposal.draft["title"]}
            </h4>
            <p
              :if={first_stop_line(@proposal.draft)}
              class="mt-1 text-sm text-base-content"
              data-role="goals-new-first-stop"
            >
              {first_stop_line(@proposal.draft)}
            </p>
            <ul class="mt-2 flex flex-col gap-1">
              <li
                :for={setting <- @settings}
                class="flex items-start gap-2 text-sm text-base-content"
                data-role="goals-new-summary-line"
                data-setting={setting}
              >
                <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
                <span>{settled_line(setting, @proposal.draft, @new)}</span>
              </li>
            </ul>
            <p
              class="mt-2 flex items-center gap-1.5 text-xs text-subtle"
              data-role="goals-new-privacy"
            >
              <.icon name="hero-lock-closed" class="size-3.5 shrink-0" />
              <span>{privacy_line(@proposal.draft, @new)}</span>
            </p>
          </div>

          <div :if={@ready? and is_nil(@created)} class="flex flex-wrap gap-2 pl-[52px]">
            <button
              type="button"
              phx-click="new_create"
              phx-value-revision={@proposal.revision}
              phx-disable-with="Create goal"
              class={chip_class()}
              data-role="goals-new-create"
            >
              Create goal
            </button>
          </div>

          <div :if={@created} class="flex flex-col gap-2" data-role="goals-new-created">
            <.settled_line setting="created" line="Goal created · only you can see it" />
            <%= for m <- @later do %>
              <.agent_message
                :if={m.from == :agent}
                agent={@agent}
                id={"goals-new-msg-#{m.id}"}
                at={m.at}
                role="goals-new-message"
              >
                {Platform.Chat.ContentRenderer.render_message(m.content)}
              </.agent_message>
              <.person_message :if={m.from != :agent} user={@new.user} message={m} />
            <% end %>
            <div class="flex flex-wrap gap-2 pl-[52px]">
              <.link
                navigate={"/m/goals?goal=" <> @created.goal_id}
                class={chip_class()}
                data-role="goals-new-open"
              >
                Open the goal
              </.link>
            </div>
          </div>
        </div>

        <p :if={@offline?} class="mt-2 text-xs text-subtle" data-role="goals-new-offline">
          {@agent.name} is offline and will answer when it is back.
        </p>

        <div
          :if={is_nil(@proposal)}
          class="mt-4 flex flex-wrap items-center gap-2 text-sm"
          data-role="goals-new-examples"
        >
          <span class="text-subtle">Try an example:</span>
          <button
            :for={example <- @examples}
            type="button"
            phx-click={JS.push("new_example", value: %{example: example.key})}
            class="focus-visible-ring rounded font-semibold text-interactive"
            data-role="goals-new-example"
            data-example={example.key}
          >
            {example.label}
          </button>
        </div>

        <div :if={@new[:refused]} class="mt-4" role="status" data-role="goals-new-refused">
          <PlatformWeb.Components.EmptyState.empty_state variant={:minimal}>
            <:body>
              <span class="block font-semibold">
                {@agent.name} can't take new goals yet: its runtime doesn't have the Goals tools.
              </span>
              <span class="mt-1 block">
                Ask an admin to turn on Goals for {@agent.name}.
              </span>
            </:body>
          </PlatformWeb.Components.EmptyState.empty_state>
        </div>

        <form
          phx-submit="new_send"
          phx-change="new_type"
          class="mt-4 flex items-center gap-2"
          data-role="goals-new-box"
        >
          <input
            id={"goals-new-text-#{@new.fill}"}
            type="text"
            name="text"
            value={@new.text}
            aria-label="What do you want to achieve?"
            placeholder="For example: start a small woodworking business, run a half marathon by spring, or get our first 10 paying customers"
            autocomplete="off"
            phx-mounted={@new.fill > 0 && JS.focus()}
            class={field_class()}
          />
          <button
            type="submit"
            phx-disable-with="Send"
            class="btn btn-primary min-h-11 shrink-0 focus-visible-ring lg:h-9 lg:min-h-9"
            data-role="goals-new-send"
          >
            Send
          </button>
        </form>
      <% end %>
    </div>
    """
  end

  defp chip_class, do: @chip
  defp field_class, do: @field

  attr :agent, :map, required: true
  attr :id, :string, required: true
  attr :role, :string, required: true
  attr :at, :any, default: nil
  slot :inner_block, required: true

  # Copied from chat_message.ex's agent row (see the moduledoc).
  defp agent_message(assigns) do
    ~H"""
    <div
      id={@id}
      class="msg-agent group relative rounded-2xl"
      data-agent-slot={@agent.slot}
      data-role={@role}
      data-from="agent"
    >
      <div class="relative flex gap-3 rounded-2xl px-2 py-2">
        <div class="mt-0.5 flex-shrink-0">
          <AvatarComponents.agent_avatar
            name={@agent.name}
            avatar_url={@agent.avatar_url}
            size="md"
            class="msg-agent-avatar"
          />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-2">
            <span class="msg-agent-name">
              {@agent.name} <span class="msg-agent-badge">AI</span>
            </span>
            <.clock :if={@at} id={@id <> "-time"} at={@at} />
          </div>
          <div class="text-sm text-base-content break-words chat-markdown">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :message, :map, required: true

  # Copied from chat_message.ex's own (human) row.
  defp person_message(assigns) do
    ~H"""
    <div
      id={"goals-new-msg-#{@message.id}"}
      class="group relative rounded-2xl bg-base-200/60"
      data-role="goals-new-message"
      data-from="person"
    >
      <div class="relative flex gap-3 rounded-2xl px-2 py-2">
        <div class="mt-0.5 flex-shrink-0">
          <AvatarComponents.human_avatar
            name={@user.name || ""}
            avatar_url={@user.avatar_url}
            seed={@user.id}
            size="md"
          />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-2">
            <span class="text-sm font-bold text-base-content">{@user.name}</span>
            <.clock id={"goals-new-msg-#{@message.id}-time"} at={@message.at} />
          </div>
          <div class="text-sm text-base-content break-words chat-markdown">
            {Platform.Chat.ContentRenderer.render_message(@message.content)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :at, :any, required: true

  # core's `LocalTime` hook turns the UTC clock into the viewer's local time.
  defp clock(assigns) do
    ~H"""
    <time
      :if={match?(%DateTime{}, @at)}
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      data-local-time={DateTime.to_iso8601(@at)}
      phx-hook="LocalTime"
      class="text-[10px] text-subtle"
    >
      {Calendar.strftime(@at, "%I:%M %p")}
    </time>
    """
  end

  attr :setting, :string, required: true
  attr :line, :string, required: true

  defp settled_line(assigns) do
    ~H"""
    <p
      class="flex items-center gap-2 pl-[52px] text-sm text-subtle"
      data-role="goals-new-settled"
      data-setting={@setting}
    >
      <.icon name="hero-check-circle" class="size-[18px] shrink-0 text-success" />
      <span data-conf={@setting}>{@line}</span>
    </p>
    """
  end
end
