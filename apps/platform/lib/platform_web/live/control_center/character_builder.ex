defmodule PlatformWeb.ControlCenter.CharacterBuilder do
  @moduledoc """
  The character builder (task 01a1b6ad stage 2): the comp's `createAgent()`
  (burrow-agents.js) as a LiveComponent. Eight steps: class, name, colour,
  face, personality, voice, AI (task 01a1b84b stage 2), reveal.

  ## State

  The builder holds a `Platform.Agents.Character` map (`cls`, `n`, `color`,
  `portrait`, `sl`, `traits`, `toolkit`, `line`, `vc`, `touched`), the
  step, and the uploaded face as a LiveView upload entry. A class change
  goes through `Character.apply_class/3`, the comp's `applyClass`: it never
  overwrites a field already in `touched`. Back and Next only move the step.

  ## Nothing persists until Bring to life

  Every event before "life" changes assigns only. Cancel, Esc and a click
  outside the modal tell the parent to drop the component, which discards
  the state with it; so does navigating away. "life" calls
  `Character.create/3` (one transaction: agent, SOUL.md, IDENTITY.md,
  TOOLS.md, the creator's DM), then stores the uploaded face through
  `AgentAvatarUpload`, the Control Center's existing avatar path.

  Events here target the component, so the Control Center's event policy
  never sees them. "life" therefore checks
  `Platform.Access.Agents.may_create_ownerless?/1` itself, and a member
  without it sees Bring to life disabled with the reason (the same rule
  task 01a1ae4b applies to the Add chooser's create paths).

  ## The one exception: picking an AI on step 7

  A sign-in needs a real agent on the agent host, so picking a provider
  tile on "Which AI should it use?" brings the character to life early:
  `Character.create/3` with the builder's state, then
  `Platform.Agents.AiConnect.prepare/3` for that provider (the panel runs
  it), then the sign-in starts. The builder keeps the agent; "Bring to
  life" then applies any later edits with `Character.update/3` instead of
  creating a second agent, and keeps the card flip and confetti. Cancel,
  Esc or a scrim click after that closes the builder and opens the agent's
  page: nothing is silently deleted. Skip, or Reveal without a pick,
  creates nothing until Bring to life, and the agent stays unconnected.
  The same `may_create_ownerless?/1` rule gates the tiles.

  ## Layout

  One render serves both layouts. app.css turns the comp's `.desk` class
  into a 768px media query: under it the flow is full screen with the
  `.ba-mini` preview; at and over it, the 980x660 modal with the live card
  in `.ba-bside`.

  The parent (`ControlCenterLive`) receives `{:character_builder, :closed}`,
  `{:character_builder, :advanced}`, `{:character_builder, {:created, agent}}`
  and `{:character_builder, {:left, agent}}` (closed after the early create).
  """
  use PlatformWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Platform.Accounts
  alias Platform.Agents.{Agent, Archetypes, Character, ColorPalette}
  alias PlatformWeb.ConnectAi.Panel
  alias PlatformWeb.ConnectAiLive
  alias PlatformWeb.ControlCenter.AgentAvatarUpload

  import PlatformWeb.AgentPortrait, only: [agent_portrait: 1]

  @steps Archetypes.steps()
  @last length(@steps) - 1
  @typing_ms 420
  @ai_prefix "ba-ai"
  @ai_panel_id "ba-ai-panel"
  @no_ai %{connected?: false, provider: nil, plan: nil, account: nil}
  @ai_tiles %{
    claude_subscription: %{name: "Claude", plan: "Pro or Max plan", mark: "C"},
    codex: %{name: "ChatGPT", plan: "Your ChatGPT plan", mark: "G"}
  }

  @doc "The step ids, in order (the comp's STEPS)."
  def step_ids, do: Enum.map(@steps, &elem(&1, 0))

  @doc "The index of step `id`, or 0 for anything unknown."
  def step_index(id) when is_binary(id),
    do: Enum.find_index(@steps, fn {s, _} -> s == id end) || 0

  def step_index(_), do: 0

  @doc "The AI step's panel component id (the parent refreshes it on agent-host status)."
  def ai_panel_id, do: @ai_panel_id

  @doc "The reason a member sees on a disabled Bring to life."
  def locked_line,
    do: "Only org admins can add agents. Ask an admin to add it or to grant you agent management."

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:b, nil)
     |> assign(:typing, false)
     |> allow_upload(AgentAvatarUpload.upload_name(),
       accept: AgentAvatarUpload.accept(),
       max_entries: 1,
       max_file_size: AgentAvatarUpload.max_file_size(),
       auto_upload: true
     )}
  end

  @doc "The card's \"Runs on\" text for a connection summary, or nil when not connected."
  def runs_on(%{connected?: true, provider: "chatgpt"}), do: "ChatGPT"

  def runs_on(%{connected?: true, provider: "claude", plan: plan}) when is_binary(plan),
    do: "Claude " <> String.capitalize(plan)

  def runs_on(%{connected?: true, provider: "claude"}), do: "Claude"
  def runs_on(_summary), do: nil

  @impl true
  def update(%{typing_done: true}, socket), do: {:ok, assign(socket, :typing, false)}

  def update(%{ai_connect: %{} = summary}, socket), do: {:ok, assign(socket, :ai, summary)}

  def update(assigns, socket) do
    agents = Map.get(assigns, :agents, [])

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:current_user_id, assigns.current_user_id)
      |> assign(:can_create?, Map.get(assigns, :can_create?, false))
      |> assign(:used_names, Enum.map(agents, & &1.name))
      |> assign(:used_by, used_by(agents))
      |> assign(:number, length(agents) + 1)

    socket = if socket.assigns.b, do: socket, else: init(socket, assigns)
    {:ok, socket}
  end

  defp init(socket, assigns) do
    used = socket.assigns.used_names
    b = Character.new("builder", used_names: used)

    b =
      case Archetypes.get(Map.get(assigns, :cls)) do
        nil -> b
        a -> Character.apply_class(b, a.id, used_names: used)
      end

    viewer =
      case Accounts.get_user(assigns.current_user_id) do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    socket
    |> assign(:b, b)
    |> assign(:step, step_index(Map.get(assigns, :step)))
    |> assign(:viewer, viewer)
    |> assign(:agent, nil)
    |> assign(:ai_pick, nil)
    |> assign(:ai, @no_ai)
  end

  # The first agent wearing each slot, for the swatch's small label.
  defp used_by(agents) do
    Enum.reduce(agents, %{}, fn entry, acc ->
      case entry do
        %{agent: %{color: color}, name: name} when is_binary(color) ->
          Map.put_new(acc, ColorPalette.slot_for(color), name)

        _ ->
          acc
      end
    end)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("close", _params, socket) do
    case socket.assigns.agent do
      %Agent{} = agent -> send(self(), {:character_builder, {:left, agent}})
      nil -> send(self(), {:character_builder, :closed})
    end

    {:noreply, socket}
  end

  def handle_event("advanced", _params, socket) do
    send(self(), {:character_builder, :advanced})
    {:noreply, socket}
  end

  def handle_event("back", _params, socket),
    do: {:noreply, assign(socket, :step, max(socket.assigns.step - 1, 0))}

  def handle_event(event, _params, socket) when event in ["next", "skip", "name_enter"],
    do: {:noreply, assign(socket, :step, min(socket.assigns.step + 1, @last))}

  def handle_event("restart", _params, socket), do: {:noreply, assign(socket, :step, 0)}

  def handle_event("pick_class", %{"cls" => cls}, socket) do
    case Archetypes.get(cls) do
      nil ->
        {:noreply, socket}

      a ->
        b = Character.apply_class(socket.assigns.b, a.id, used_names: socket.assigns.used_names)
        {:noreply, assign(socket, :b, b)}
    end
  end

  def handle_event("name", %{"n" => n}, socket) when is_binary(n) do
    b = socket.assigns.b

    n =
      case String.trim(n) do
        "" -> b.n
        trimmed -> String.slice(trimmed, 0, 24)
      end

    {:noreply, assign(socket, :b, touch(%{b | n: n}, "name"))}
  end

  def handle_event("roll", _params, socket) do
    b = socket.assigns.b
    a = Archetypes.fetch(b.cls)
    n = Character.pick_name(a, used_names: socket.assigns.used_names, skip: b.n)
    {:noreply, assign(socket, :b, touch(%{b | n: n}, "name"))}
  end

  def handle_event("pick_name", %{"n" => n}, socket) when is_binary(n) do
    b = socket.assigns.b

    if n in Archetypes.fetch(b.cls).names,
      do: {:noreply, assign(socket, :b, touch(%{b | n: n}, "name"))},
      else: {:noreply, socket}
  end

  def handle_event("pick_color", %{"color" => color}, socket) do
    if color in ColorPalette.ids() do
      b = socket.assigns.b
      {:noreply, assign(socket, :b, touch(%{b | color: color}, "color"))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_portrait", %{"por" => por}, socket) do
    if por in Archetypes.portraits() do
      b = socket.assigns.b

      {:noreply,
       socket
       |> cancel_all_uploads()
       |> assign(:b, touch(%{b | portrait: por}, "portrait"))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    socket =
      if upload_entry(socket.assigns),
        do: assign(socket, :b, touch(socket.assigns.b, "portrait")),
        else: socket

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, AgentAvatarUpload.upload_name(), ref)}

  def handle_event("dials", %{"sl" => sl}, socket) when is_map(sl) do
    b = socket.assigns.b

    new_sl =
      Enum.reduce(Archetypes.sliders(), b.sl, fn s, acc ->
        case Integer.parse(to_string(Map.get(sl, s.k, ""))) do
          {v, ""} when v >= 0 and v <= 100 -> Map.put(acc, s.k, v)
          _ -> acc
        end
      end)

    {:noreply, assign(socket, :b, touch(%{b | sl: new_sl}, "sl"))}
  end

  def handle_event("trait", %{"tr" => tr}, socket) do
    if tr in Archetypes.traits() do
      b = socket.assigns.b

      traits =
        cond do
          tr in b.traits -> List.delete(b.traits, tr)
          length(b.traits) >= 3 -> tl(b.traits) ++ [tr]
          true -> b.traits ++ [tr]
        end

      {:noreply, assign(socket, :b, touch(%{b | traits: traits}, "traits"))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("voice_preset", %{"p" => p}, socket) do
    case Integer.parse(to_string(p)) do
      {p, ""} when p >= 0 and p <= 4 ->
        b = socket.assigns.b
        {:noreply, assign(socket, :b, touch(put_in(b, [:vc, :p], p), "voice"))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("voice_knob", %{"k" => k, "v" => v}, socket) do
    with %{options: options} <- Enum.find(Archetypes.knobs(), &(&1.k == k)),
         {v, ""} when v >= 0 <- Integer.parse(to_string(v)),
         true <- v < length(options) do
      b = socket.assigns.b
      default = Enum.at(Archetypes.vdef(), b.vc.p)[k]
      ov = if default == v, do: Map.delete(b.vc.ov, k), else: Map.put(b.vc.ov, k, v)
      {:noreply, assign(socket, :b, touch(put_in(b, [:vc, :ov], ov), "voice"))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("voice_reset", _params, socket) do
    b = socket.assigns.b
    {:noreply, assign(socket, :b, touch(put_in(b, [:vc, :ov], %{}), "voice"))}
  end

  def handle_event("voice_sample", %{"q" => q}, socket) do
    if Enum.any?(Archetypes.samples(), &(&1.id == q)) do
      b = socket.assigns.b
      vc = %{b.vc | q: q, free: nil}
      {:noreply, socket |> assign(:b, %{b | vc: vc}) |> start_typing()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("voice_free", %{"q" => q}, socket) when is_binary(q) do
    case String.trim(q) do
      "" ->
        {:noreply, socket}

      text ->
        b = socket.assigns.b
        vc = %{b.vc | free: String.slice(text, 0, 500)}
        {:noreply, socket |> assign(:b, %{b | vc: vc}) |> start_typing()}
    end
  end

  # Step 7: a provider tile. The agent is created now (once), and the panel
  # prepares it for the provider and starts the sign-in (`selected`).
  def handle_event("pick_ai", %{"provider" => provider}, socket) do
    option = Enum.find(ConnectAiLive.choices(), &(Atom.to_string(&1) == provider))

    cond do
      is_nil(option) ->
        {:noreply, socket}

      not may_create?(socket) ->
        {:noreply, assign(socket, :can_create?, false)}

      true ->
        case create_early(socket) do
          {:ok, socket} -> {:noreply, assign(socket, :ai_pick, option)}
          {:error, socket} -> {:noreply, socket}
        end
    end
  end

  def handle_event("life", _params, socket) do
    if may_create?(socket) do
      bring_to_life(socket, socket.assigns.current_user_id)
    else
      {:noreply, assign(socket, :can_create?, false)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp may_create?(socket) do
    scope = Platform.Access.Scope.for_user(%{id: socket.assigns.current_user_id})
    Platform.Access.Agents.may_create_ownerless?(scope)
  end

  # The early create (step 7): one agent, kept on the socket; a second pick
  # reuses it.
  defp create_early(%{assigns: %{agent: %Agent{}}} = socket), do: {:ok, socket}

  defp create_early(socket) do
    case Character.create(socket.assigns.b, %{id: socket.assigns.current_user_id}) do
      {:ok, %{agent: agent}} ->
        b = %{socket.assigns.b | n: agent.name}
        {:ok, socket |> assign(:agent, agent) |> assign(:b, b)}

      {:error, _step, reason} ->
        send(self(), {:character_builder, {:error, reason}})
        {:error, socket}
    end
  end

  # Bring to life: create, or, after an early create, apply the edits to the
  # same agent. Never a second agent.
  defp bring_to_life(%{assigns: %{agent: %Agent{} = agent}} = socket, _user_id) do
    b = socket.assigns.b

    case Character.update(
           agent,
           Map.take(b, [:cls, :n, :color, :portrait, :sl, :traits, :toolkit, :vc])
         ) do
      {:ok, %{agent: agent}} ->
        send(self(), {:character_builder, {:created, with_avatar(socket, agent)}})
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:character_builder, {:error, reason}})
        {:noreply, socket}
    end
  end

  defp bring_to_life(socket, user_id) do
    case Character.create(socket.assigns.b, %{id: user_id}) do
      {:ok, %{agent: agent}} ->
        send(self(), {:character_builder, {:created, with_avatar(socket, agent)}})
        {:noreply, socket}

      {:error, _step, reason} ->
        send(self(), {:character_builder, {:error, reason}})
        {:noreply, socket}
    end
  end

  defp with_avatar(socket, agent) do
    with {:ok, attrs} <- AgentAvatarUpload.consume(socket, agent),
         {:ok, updated} <- Character.put_avatar(agent, attrs) do
      updated
    else
      _ -> agent
    end
  end

  defp touch(b, field), do: %{b | touched: MapSet.put(b.touched, field)}

  defp start_typing(socket) do
    send_update_after(__MODULE__, [id: socket.assigns.id, typing_done: true], @typing_ms)
    assign(socket, :typing, true)
  end

  defp cancel_all_uploads(socket) do
    name = AgentAvatarUpload.upload_name()

    Enum.reduce(socket.assigns.uploads[name].entries, socket, fn entry, acc ->
      cancel_upload(acc, name, entry.ref)
    end)
  end

  defp upload_entry(assigns) do
    case assigns.uploads[AgentAvatarUpload.upload_name()].entries do
      [entry | _] -> if entry.valid?, do: entry, else: nil
      _ -> nil
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    b = assigns.b
    a = Archetypes.fetch(b.cls)
    {step_id, _title} = Enum.at(@steps, assigns.step)

    assigns =
      assigns
      |> assign(:a, a)
      |> assign(:step_id, step_id)
      |> assign(:last?, assigns.step == @last)
      |> assign(:steps, Enum.with_index(@steps))
      |> assign(:palette, Enum.find(ColorPalette.all(), &(&1.id == b.color)))
      |> assign(:entry, upload_entry(assigns))
      |> assign(
        :next_label,
        if(assigns.step + 1 == @last, do: "Reveal", else: "Next")
      )
      |> assign(:runs_on, runs_on(assigns.ai))

    ~H"""
    <div
      id={@id}
      class="ba ba-flow"
      data-step={@step_id}
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="ba-modal"
        role="dialog"
        aria-modal="true"
        aria-label="Create an agent"
        data-agent-slot={@b.color}
        phx-click-away="close"
        phx-target={@myself}
      >
        <div class="ba-bwrap">
          <div class="ba-bmain">
            <div class="ba-ftop">
              <span class="l">
                <button
                  :if={@step == 0}
                  id="ba-cancel"
                  type="button"
                  class="tbtn muted"
                  phx-click="close"
                  phx-target={@myself}
                >
                  Cancel
                </button>
                <button
                  :if={@step > 0}
                  id="ba-back"
                  type="button"
                  class="tbtn"
                  phx-click="back"
                  phx-target={@myself}
                >
                  ‹ Back
                </button>
              </span>
              <div class="ba-dots" role="img" aria-label={"Step #{@step + 1} of #{length(@steps)}"}>
                <i
                  :for={{{_id, title}, i} <- @steps}
                  class={
                    cond do
                      i == @step -> "on"
                      i < @step -> "done"
                      true -> nil
                    end
                  }
                  title={title}
                >
                </i>
              </div>
              <span class="r">
                <button
                  :if={!@last?}
                  id="ba-skip"
                  type="button"
                  class="tbtn muted"
                  phx-click="skip"
                  phx-target={@myself}
                >
                  Skip
                </button>
              </span>
            </div>
            <div :if={!@last?} class="ba-mini" id="ba-mini">
              <.face b={@b} entry={@entry} size={56} prefix="mini" />
              <div class="tx">
                <b>{display_name(@b.n)}</b>
                <span>{@a.glyph} {@a.n} · {@palette.label}</span>
                <div class="tr"><i :for={t <- @b.traits}>{t}</i></div>
                <span :if={@runs_on} class="ba-runs-on" id="ba-mini-runs-on">
                  Runs on · {@runs_on}
                </span>
              </div>
            </div>
            <div class="ba-fbody">
              <div class="ba-step" id={"ba-step-" <> @step_id}>
                {step_body(assigns)}
              </div>
            </div>
            <div class="ba-ffoot">
              <%= if @last? do %>
                <button
                  :if={@can_create?}
                  id="ba-life"
                  type="button"
                  class="ba-btn ag full"
                  phx-click="life"
                  phx-target={@myself}
                  phx-disable-with={"✨ Bringing #{@b.n} to life…"}
                >
                  ✨ Bring {@b.n} to life
                </button>
                <button
                  :if={!@can_create?}
                  id="ba-life"
                  type="button"
                  class="ba-btn ag full"
                  aria-disabled="true"
                  aria-describedby="ba-life-locked"
                  data-locked="true"
                >
                  ✨ Bring {@b.n} to life
                </button>
                <p :if={!@can_create?} id="ba-life-locked" class="ba-sub">{locked_line()}</p>
                <button
                  id="ba-restart"
                  type="button"
                  class="ba-link"
                  style="padding:4px"
                  phx-click="restart"
                  phx-target={@myself}
                >
                  Change something
                </button>
              <% else %>
                <button
                  id="ba-next"
                  type="button"
                  class="ba-btn ag full"
                  phx-click="next"
                  phx-target={@myself}
                >
                  {@next_label}
                </button>
              <% end %>
            </div>
          </div>
          <div :if={!@last?} class="ba-bside">
            <small>live preview</small>
            <div id="ba-live">
              <.card
                b={@b}
                number={@number}
                viewer={@viewer}
                entry={@entry}
                w={290}
                prefix="live"
                runs_on={@runs_on}
              />
            </div>
          </div>
        </div>
        <div :if={@last?} class="ba-confetti" aria-hidden="true">
          <i
            :for={i <- 0..25}
            style={"left:#{rem(i * 37, 100)}%;animation-delay:#{Float.round(rem(i, 9) * 0.06 + 0.5, 2)}s"}
          >
          </i>
        </div>
      </div>
    </div>
    """
  end

  defp display_name(n) when n in [nil, ""], do: "…"
  defp display_name(n), do: n

  # ── Steps ──────────────────────────────────────────────────────────

  defp step_body(%{step_id: "class"} = assigns) do
    ~H"""
    <h1 class="ba-h1">Pick a class</h1>
    <p class="ba-sub">Sets its starting toolkit and a vibe. You can change anything later.</p>
    <div class="ba-classes">
      <button
        :for={x <- Archetypes.all()}
        type="button"
        class="ba-class"
        data-cls={x.id}
        aria-pressed={to_string(@b.cls == x.id)}
        data-agent-slot={x.color}
        phx-click="pick_class"
        phx-value-cls={x.id}
        phx-target={@myself}
      >
        <span class="g">{x.glyph}</span>
        <b>{x.n}</b>
        <span>{x.vibe}</span>
        <span class="tk" title="starting toolkit">{toolkit_icons(x.toolkit)}</span>
      </button>
    </div>
    <button
      id="ba-advanced"
      type="button"
      class="ba-link ba-adv"
      phx-click="advanced"
      phx-target={@myself}
    >
      Advanced
    </button>
    """
  end

  defp step_body(%{step_id: "name"} = assigns) do
    ~H"""
    <h1 class="ba-h1">What do you call it?</h1>
    <p class="ba-sub">Roll for a {String.downcase(@a.n)} name, or type your own.</p>
    <form
      id="ba-name-form"
      class="ba-bigname"
      phx-change="name"
      phx-submit="name_enter"
      phx-target={@myself}
    >
      <input
        id="ba-agname"
        name="n"
        value={@b.n}
        maxlength="24"
        aria-label="Agent name"
        autocomplete="off"
        spellcheck="false"
      />
      <button
        id="ba-dice"
        type="button"
        class="ba-dice"
        aria-label="Shuffle name"
        title="Shuffle"
        phx-click={JS.push("roll", target: @myself) |> JS.transition("roll", to: "#ba-dice")}
      >
        🎲
      </button>
    </form>
    <div class="ba-lbl">More {String.downcase(@a.n)} names</div>
    <div class="ba-chips">
      <button
        :for={n <- more_names(@a, @b.n, @used_names)}
        type="button"
        class="ba-chip"
        data-nm={n}
        phx-click="pick_name"
        phx-value-n={n}
        phx-target={@myself}
      >
        {n}
      </button>
    </div>
    <p class="ba-sub" style="margin-top:20px">
      You'll call it in chat as <b style="color:var(--ag)">@{@b.n}</b>
    </p>
    """
  end

  defp step_body(%{step_id: "color"} = assigns) do
    ~H"""
    <h1 class="ba-h1">Pick its colour</h1>
    <p class="ba-sub">Its name, AI pill, avatar ring and message rail all wear it.</p>
    <form
      id="ba-color-form"
      class="ba-swatches"
      role="radiogroup"
      aria-label="Colour"
      phx-change="pick_color"
      phx-target={@myself}
    >
      <label
        :for={c <- ColorPalette.all()}
        class="relative"
        data-col={c.id}
        data-agent-slot={c.id}
      >
        <input
          type="radio"
          name="color"
          value={c.id}
          class="sr-only peer"
          checked={@b.color == c.id}
          aria-label={c.label}
        />
        <i></i>{c.label}<em>{Map.get(@used_by, c.id, "")}</em>
      </label>
    </form>
    <p class="ba-sub" style="margin-top:16px;font-size:12px">
      Ten slots, same as the platform's agent palette. Shared colours are fine; small initials show who else wears one.
    </p>
    """
  end

  defp step_body(%{step_id: "portrait"} = assigns) do
    ~H"""
    <h1 class="ba-h1">Give it a face</h1>
    <p class="ba-sub">Generated in {String.downcase(@palette.label)}. Or bring your own.</p>
    <form
      id="ba-upload-form"
      class="ba-pors"
      phx-change="validate_upload"
      phx-submit="validate_upload"
      phx-target={@myself}
    >
      <button
        :for={x <- Archetypes.portraits()}
        type="button"
        data-por={x}
        aria-pressed={to_string(is_nil(@entry) and @b.portrait == x)}
        aria-label={"Portrait #{x}"}
        phx-click="pick_portrait"
        phx-value-por={x}
        phx-target={@myself}
      >
        <.agent_portrait portrait={x} size={96} />
      </button>
      <label id="ba-upload" class="up relative" data-uploaded={to_string(!is_nil(@entry))}>
        <.live_file_input upload={@uploads.agent_avatar} class="sr-only" aria-label="Upload a face" />
        <%= if @entry do %>
          <span class="ba-por" style="width:96px;height:96px">
            <.live_img_preview entry={@entry} id={"ba-up-" <> @entry.ref} />
          </span>
        <% else %>
          <b>＋</b>Upload
        <% end %>
      </label>
    </form>
    <p :for={err <- upload_errors(@uploads.agent_avatar)} class="ba-sub" role="alert">
      {AgentAvatarUpload.error_message(err)}
    </p>
    """
  end

  defp step_body(%{step_id: "personality"} = assigns) do
    ~H"""
    <h1 class="ba-h1">Personality</h1>
    <p class="ba-sub">Four dials and three traits. That's it.</p>
    <form id="ba-dials-form" phx-change="dials" phx-target={@myself}>
      <div :for={s <- Archetypes.sliders()} class="ba-slider">
        <div class="ends">
          <span class={@b.sl[s.k] < 50 && "lean"}>{s.lo}</span>
          <span class={@b.sl[s.k] >= 50 && "lean"}>{s.hi}</span>
        </div>
        <input
          type="range"
          min="0"
          max="100"
          name={"sl[#{s.k}]"}
          value={@b.sl[s.k]}
          data-sl={s.k}
          aria-label={"#{s.lo} to #{s.hi}"}
        />
      </div>
    </form>
    <div class="ba-lbl">
      Three traits
      <span style="text-transform:none;letter-spacing:0;font-weight:500">
        · {length(@b.traits)}/3
      </span>
    </div>
    <div class="ba-chips">
      <button
        :for={t <- Archetypes.traits()}
        type="button"
        class="ba-chip"
        data-tr={t}
        aria-pressed={to_string(t in @b.traits)}
        phx-click="trait"
        phx-value-tr={t}
        phx-target={@myself}
      >
        {t}
      </button>
    </div>
    <div class="ba-says" id="ba-says">
      <small>FIRST THING IT SAYS</small>“{Character.first_line(@b, @viewer)}”
    </div>
    """
  end

  defp step_body(%{step_id: "voice"} = assigns) do
    vc = assigns.b.vc
    e = Character.v_eff(vc)
    sample = if vc.free, do: nil, else: Enum.find(Archetypes.samples(), &(&1.id == vc.q))
    [k0 | rest] = Character.v_prompt_lines(vc)

    assigns =
      assigns
      |> assign(:vc, vc)
      |> assign(:e, e)
      |> assign(:v, Archetypes.voice(vc.p))
      |> assign(:asked, vc.free || (sample && sample.q) || "")
      |> assign(:reply, Character.v_reply(vc, assigns.b.n, assigns.viewer))
      |> assign(:prompt_head, k0)
      |> assign(:prompt_rest, "\n" <> Enum.join(rest, "\n"))
      |> assign(:tweaks, tweaks(vc))

    ~H"""
    <h1 class="ba-h1">How does {@b.n} talk?</h1>
    <p class="ba-sub">From a quick text to a full formal brief. Slide it, then try it on below.</p>
    <div style="margin-top:16px">
      <div class="ba-voice">
        <div class="ba-vdial">
          <div class="ba-vnow">
            <span class="ic">{@v.ic}</span>
            <span class="tx"><b>{@v.n}</b><small>{@v.blurb}</small></span>
          </div>
          <div class="ends"><span>Texting</span><span>Exhaustive &amp; formal</span></div>
          <form id="ba-vdial-form" phx-change="voice_preset" phx-target={@myself}>
            <input
              type="range"
              class="ba-vrange"
              name="p"
              min="0"
              max="4"
              step="1"
              value={@vc.p}
              style={"--pct:#{@vc.p * 25}%"}
              aria-label={"How #{@b.n} talks, from texting to exhaustive and formal"}
              aria-valuetext={@v.n}
            />
          </form>
          <div class="ba-vstops">
            <button
              :for={{x, i} <- Enum.with_index(Archetypes.voices())}
              type="button"
              data-vp={i}
              aria-pressed={to_string(i == @vc.p)}
              aria-label={x.n}
              phx-click="voice_preset"
              phx-value-p={i}
              phx-target={@myself}
            >
              <span>{x.ic}</span><em>{x.s}</em>
            </button>
          </div>
        </div>
        <details id="ba-vft" class="ba-vft" phx-mounted={JS.ignore_attributes(["open"])}>
          <summary>Fine-tune <small class="ba-vtw">{@tweaks}</small></summary>
          <div :for={knob <- Archetypes.knobs()} class="r">
            <b>{knob.label}</b>
            <div class="ba-seg">
              <button
                :for={{o, i} <- Enum.with_index(knob.options)}
                type="button"
                data-vk={knob.k}
                data-vv={i}
                aria-pressed={to_string(@e[knob.k] == i)}
                phx-click="voice_knob"
                phx-value-k={knob.k}
                phx-value-v={i}
                phx-target={@myself}
              >
                {o}
              </button>
            </div>
          </div>
          <button
            type="button"
            class="ba-link"
            data-vreset
            phx-click="voice_reset"
            phx-target={@myself}
          >
            Reset to preset
          </button>
        </details>
        <div class="ba-vtry">
          <div class="hd"><b>Try it</b><span>tap a prompt or type your own</span></div>
          <div class="ba-chips">
            <button
              :for={s <- Archetypes.samples()}
              type="button"
              class="ba-chip"
              data-vq={s.id}
              aria-pressed={to_string(is_nil(@vc.free) and @vc.q == s.id)}
              phx-click="voice_sample"
              phx-value-q={s.id}
              phx-target={@myself}
            >
              {s.q}
            </button>
          </div>
          <div class="ba-vchat" aria-live="polite">
            <div class="ba-vb me">{@asked}</div>
            <div class="ba-vrow">
              <.face b={@b} entry={@entry} size={28} prefix="vrow" />
              <div :if={@typing} class="ba-vb ag">
                <span class="from">{@b.n}</span><span class="ba-typing"><i></i><i></i><i></i></span>
              </div>
              <div :if={!@typing} class="ba-vb ag" data-vreply>
                <span class="from">{@b.n}</span>
                <p :for={l <- @reply}>{l}</p>
                <span class="meta">{@v.ic} {@v.s} · just now</span>
              </div>
            </div>
          </div>
          <form id="ba-vfree-form" class="ba-addnote" phx-submit="voice_free" phx-target={@myself}>
            <input
              class="ba-vin"
              name="q"
              placeholder={"Ask #{@b.n} anything…"}
              aria-label="Try your own message"
              autocomplete="off"
            />
            <button type="submit" class="ba-btn sm ag" data-vsend>Send</button>
          </form>
        </div>
        <details id="ba-vread" class="ba-vread" phx-mounted={JS.ignore_attributes(["open"])}>
          <summary>What {@b.n} gets <small>· style block in its system prompt</small></summary>
          <pre class="ba-vprompt"><span class="k">{@prompt_head}</span>{@prompt_rest}</pre>
          <p>
            Injected into {@b.n}'s system prompt (<code>SOUL.md</code> · Voice). Applies to every reply from now on — in chat, email and meetings.
          </p>
        </details>
      </div>
    </div>
    """
  end

  # Step 7 (task 01a1b84b stage 2): two provider tiles in provider_order, the
  # panel's #106 steps under the picked one, a skip line. Reveal stays enabled.
  defp step_body(%{step_id: "ai"} = assigns) do
    assigns =
      assigns
      |> assign(:choices, ConnectAiLive.choices())
      |> assign(:tiles, @ai_tiles)
      |> assign(:ai_prefix, @ai_prefix)
      |> assign(:ai_panel_id, @ai_panel_id)
      |> assign(:current_user, Accounts.get_user(assigns.current_user_id))

    ~H"""
    <h1 class="ba-h1">Which AI should {display_name(@b.n)} use?</h1>
    <p class="ba-sub">Sign in with a plan you already pay for. No API key.</p>
    <div class="ba-ai" id="ba-ai">
      <div class="ba-ai-tiles">
        <button
          :for={option <- @choices}
          :if={@can_create?}
          type="button"
          id={"ba-ai-" <> Atom.to_string(option)}
          class="ba-class ba-ai-tile"
          data-provider={option}
          aria-pressed={to_string(@ai_pick == option)}
          phx-click="pick_ai"
          phx-value-provider={option}
          phx-target={@myself}
        >
          <span class="g ba-ai-mark" aria-hidden="true">{@tiles[option].mark}</span>
          <b>{@tiles[option].name}</b>
          <span>{@tiles[option].plan}</span>
        </button>
        <button
          :for={option <- @choices}
          :if={!@can_create?}
          type="button"
          id={"ba-ai-" <> Atom.to_string(option)}
          class="ba-class ba-ai-tile"
          data-provider={option}
          aria-pressed="false"
          aria-disabled="true"
          aria-describedby="ba-ai-locked"
          data-locked="true"
        >
          <span class="g ba-ai-mark" aria-hidden="true">{@tiles[option].mark}</span>
          <b>{@tiles[option].name}</b>
          <span>{@tiles[option].plan}</span>
        </button>
      </div>
      <p :if={!@can_create?} id="ba-ai-locked" class="ba-sub">{locked_line()}</p>
      <div :if={@agent && @ai_pick} class="ba-ai-steps" id="ba-ai-steps">
        <.live_component
          module={Panel}
          id={@ai_panel_id}
          target={@agent}
          current_user={@current_user}
          prefix={@ai_prefix}
          order={@choices}
          picker={false}
          selected={@ai_pick}
          notify={{__MODULE__, @id}}
        />
      </div>
      <p class="ba-sub ba-ai-later">
        <button id="ba-ai-later" type="button" class="ba-link" phx-click="skip" phx-target={@myself}>
          Not now? Connect from {display_name(@b.n)}'s page later.
        </button>
      </p>
    </div>
    """
  end

  defp step_body(%{step_id: "reveal"} = assigns) do
    assigns = assign(assigns, :voice_key, Archetypes.voice(assigns.b.vc.p).key)

    ~H"""
    <div class="ba-revwrap">
      <.card
        b={@b}
        number={@number}
        viewer={@viewer}
        entry={@entry}
        reveal
        prefix="reveal"
        runs_on={@runs_on}
      />
      <div class="ba-writes">
        Creates <code>IDENTITY.md</code>
        · <code>SOUL.md</code>
        · <code>TOOLS.md</code>
        · colour <code>{@b.color}</code>
        · voice <code>{@voice_key}</code>
        · joins a DM with you as <b>works with you</b>
      </div>
    </div>
    """
  end

  defp toolkit_icons(ids) do
    Enum.map_join(ids, " ", fn id -> (Archetypes.tool(id) || %{ic: ""}).ic end)
  end

  defp more_names(a, current, used) do
    a.names
    |> Enum.reject(&(&1 in used or &1 == current))
    |> Enum.take(5)
  end

  defp tweaks(vc) do
    case map_size(vc.ov || %{}) do
      0 -> "· #{Archetypes.voice(vc.p).s} defaults"
      1 -> "· 1 tweak"
      n -> "· #{n} tweaks"
    end
  end

  # ── Shared pieces ──────────────────────────────────────────────────

  attr :b, :map, required: true
  attr :entry, :any, default: nil
  attr :size, :integer, required: true
  attr :prefix, :string, required: true

  # The face: the uploaded image while one is picked, else the portrait.
  defp face(assigns) do
    ~H"""
    <span :if={@entry} class="ba-por" style={"width:#{@size}px;height:#{@size}px"}>
      <.live_img_preview entry={@entry} id={"ba-#{@prefix}-" <> @entry.ref} />
    </span>
    <.agent_portrait :if={!@entry} portrait={@b.portrait} size={@size} />
    """
  end

  @doc """
  The trading card (the comp's `cardHTML`), from `Character.card/2`. The
  builder's live preview and reveal use it; stage 3's "Show its card" will.
  """
  attr :b, :map, required: true
  attr :number, :integer, default: 1
  attr :viewer, :string, default: nil
  attr :entry, :any, default: nil
  attr :reveal, :boolean, default: false
  attr :w, :integer, default: nil
  attr :prefix, :string, default: "card"

  attr :runs_on, :string,
    default: nil,
    doc: "\"Claude Max\" or \"ChatGPT\" once connected, else nil"

  def card(assigns) do
    assigns =
      assigns
      |> assign(:c, Character.card(assigns.b, number: assigns.number, viewer: assigns.viewer))
      |> assign(:a, Archetypes.fetch(assigns.b.cls))

    ~H"""
    <div
      class={["ba-card", @reveal && "reveal"]}
      data-agent-slot={@c.slot}
      style={@w && "--w:#{@w}px"}
      data-card
    >
      <div class="in">
        <div class="ctop"><b>{@c.name}</b><span>{@c.class}</span></div>
        <div class="art">
          <.face b={@b} entry={@entry} size={118} prefix={@prefix} />
          <span class="hue">{@c.colour}</span><span class="tpl">{@c.template}</span>
        </div>
        <div class="typ"><span>Agent · <i>{@a.n}</i></span><span>{@c.vibe}</span></div>
        <div :for={s <- @c.stats} class="ba-stat">
          <span>{s.label}</span><span class="sbar"><i style={"width:#{s.value}%"}></i></span><em>{s.value}</em>
        </div>
        <div class="tr"><i :for={t <- @c.traits}>{t}</i></div>
        <div class="tk"><span :for={t <- @c.toolkit}>{t}</span></div>
        <div class="vc"><span>Talks like</span><b>{@c.talks_like}</b></div>
        <div :if={@runs_on} class="vc" data-runs-on><span>Runs on</span><b>{@runs_on}</b></div>
        <q>“{@c.quote}”</q>
        <div class="ft"><span>{@c.footer}</span><span>№ {@c.number}</span></div>
      </div>
    </div>
    """
  end
end
