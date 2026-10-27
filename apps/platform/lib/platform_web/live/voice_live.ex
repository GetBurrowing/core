defmodule PlatformWeb.VoiceLive do
  @moduledoc """
  The Voice tab at `/voice` (task 01a1557a-eab7 stage 2): a 1:1 conversation
  with an agent, the second tab in the phone bar. The masters' screen `home`
  (master-mobile.html :559-589) is the spec.

  Stage 2 built the shell: the two pills and their sheets, the thread line,
  the transcript stream with the partner's greeting and the context notes, and
  the idle mic area. Stage 3 adds the talking: the `VoiceTab` hook
  (`assets/js/hooks/voice_tab.js`) owns the microphone and the LiveKit room,
  and pushes the events below. Stage 4 makes the two sheets popovers at lg.

  ## Hook events (stage 3)

    * `voice_start` (with a reply): `VoiceSession.start/3`. `{:ok, s}` replies
      `%{ok: true, token, url, room}`; `{:error, _}` replies `%{ok: false}`
      and the line reads "{partner} can't talk right now.".
    * `voice_press` / `voice_toggled` / `voice_release` `%{duration_ms}`: a
      turn. Press and release are `VoiceSession.press/2` and `release/2`. A
      release under 400ms with no final caption since the press is "too
      short": no turn, the line returns to idle. Otherwise the agent is
      thinking until a final agent caption arrives, or, after 20s, "Didn't get
      an answer." with "Try again".
    * `voice_turn` `%{who, text}`: a FINAL caption. `who: "me"` is inserted
      and, with a context set, posted there with `VoiceSession.post_transcript/3`
      (the bubble's meta gains " · posted to {ctx}"); with no context nothing
      is posted. `who: "agent"` is inserted and never posted.
    * `voice_mic_blocked`: the browser refused the microphone. The line reads
      "Microphone is blocked. Allow it in your browser or app settings." with "Type
      instead", whose input submits through the same path as `who: "me"`.
    * A context change calls `VoiceSession.set_context/2`; a partner change
      releases the floor if a turn is live and disconnects the old session
      (`voice_disconnect`) before the next press starts a new one.

  ## State

    * `:partner`: `%{agent, slot, reachable?, description}` or nil. On mount it
      is `VoiceSession.default_partner/1` (Burrow); with no Burrow visible the
      pill reads "No voice partner" and the mic is disabled. A partner that
      is not `voice_reachable?` keeps the pill but disables the mic, and the
      listen line reads "{partner} can't talk right now.".
    * `:context`: `%{id, name}` or nil. "No context" or ONE non-archived
      channel the viewer participates in (projects and tasks are out of
      scope). The last pick is remembered on the device by the
      `VoiceContext` hook (`assets/js/hooks/voice_context.js`), which pushes
      it back once on connect.
    * The transcript is the `:turns` STREAM. Picking a partner resets it and
      inserts that partner's greeting; picking a context appends a day note.

  ## The pickers at lg (stage 4)

  `partner_sheet/1` and `context_sheet/1` render with `variant: :popover`
  inside `#partner-anchor` / `#ctx-anchor`: a bottom sheet on a phone, and at
  lg and up a popover anchored under its pill (direction canvas 01a1705c
  state 9; the masters draw no desktop). Same components, same markup, same
  copy; only the variant's classes differ. Escape closes either (the `Sheet`
  hook pushes `close_sheet`), Tab stays inside it, and focus goes back to
  where it was when the picker opened: the pill, or #mic if #mic still held
  focus (a click does not focus a button in Safari), else the pill named in
  `data-return-focus`.

  A partner change during a live turn (held or toggled) calls
  `VoiceSession.release/2` on the OLD session before the session is dropped,
  so the old agent's AskFloor claim (`"voice:<dm id>"`) is released and its
  window gets the `closed` signal; nothing is left listening.

  ## Deliberate deviations from the masters

    * The context sheet lists spaces only: the search placeholder is
      "Search spaces" (the masters' "Search projects, spaces, tasks"), and the
      Projects and Tasks groups are not built. A project has no space to post
      a transcript into.
    * The masters have no desktop layout; the lg popovers follow direction
      canvas 01a1705c state 9. They hide the sheet's handle (there is nothing
      to drag) and close on Escape or a click outside, with no X.
    * Popover rows hover to base-200 (`lg:hover:bg-base-200`), the only
      hover paint on the screen; phone rows keep the pressed state only.
    * The pills' focus-visible ring (not drawn in the masters) is a 2px
      primary outline, offset 2px onto the base-200 ground.
    * The idle mic edge is `--subtle`, not `--edge` (`--edge` fails 3:1 on
      the base-200 ground), and the agent avatar is the slot tint with a slot
      ring and a base-content initial, not a solid slot fill. Both are held
      by `test/platform/design/voice_tab_contrast_guard_test.exs`.
  """
  use PlatformWeb, :live_view

  import PlatformWeb.Components.Voice

  alias Platform.Agents.ColorPalette
  alias Platform.Chat
  alias Platform.Meetings.VoiceSession

  @default_slug "meeting-assistant"
  @burrow_greeting "Morning. Anything on your mind? Hold the mic and just talk — I'll keep the thread."
  @back_greeting "Back with you."
  @toast_text "Same LiveKit + transcription as Meet, private 1:1 — no meeting created"
  @toast_ms 3_000
  @too_short_ms 400
  @answer_timeout_ms 20_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]
    partners = user |> VoiceSession.partners() |> Enum.map(&partner_entry/1)

    partner =
      case VoiceSession.default_partner(user) do
        nil -> nil
        agent -> Enum.find(partners, &(&1.agent.id == agent.id))
      end

    spaces = context_spaces(user, socket.assigns[:access_scope])

    socket =
      socket
      |> assign(:page_title, "Voice")
      |> assign(:partners, partners)
      |> assign(:partner, partner)
      |> assign(:spaces, spaces)
      |> assign(:context, nil)
      |> assign(:context_restored?, false)
      |> assign(:sheet, nil)
      |> assign(:query, "")
      |> assign(:ctx_form, to_form(%{"q" => ""}, as: :ctx))
      |> assign(:toast, nil)
      |> assign(:turn_seq, 0)
      |> assign(:session, nil)
      |> assign(:mic_state, :idle)
      |> assign(:heard?, false)
      |> assign(:answer_ref, nil)
      |> assign(:typing?, false)
      |> assign(:type_form, type_form())
      |> stream(:turns, [])

    {:ok, maybe_greet(socket, partner, @burrow_greeting)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} embedded={true}>
      <div
        id="voice-screen"
        class="clears-tab-bar flex h-full min-h-0 flex-col bg-base-200"
        phx-hook="VoiceContext"
        data-context-id={@context && @context.id}
      >
        <header class="flex h-14 flex-none items-center justify-between gap-2 px-4">
          <div id="partner-anchor" class="relative">
            <.partner_pill partner={@partner} />
            <.partner_sheet
              variant={:popover}
              open={@sheet == :partner}
              partners={@partners}
              current_id={@partner && @partner.agent.id}
              default_slug={default_slug()}
            />
          </div>
          <div id="ctx-anchor" class="relative min-w-0">
            <.context_pill context={@context} />
            <.context_sheet
              variant={:popover}
              open={@sheet == :context}
              spaces={filter_spaces(@spaces, @query)}
              query={@query}
              form={@ctx_form}
              context={@context}
              partner_name={@partner && @partner.agent.name}
            />
          </div>
        </header>
        <.thread_line partner={@partner} context={@context} />

        <div id="voice-scroll" class="min-h-0 flex-1 overflow-y-auto">
          <div id="convo" class="mx-auto flex max-w-2xl flex-col gap-2 px-3.5 pb-3">
            <div class="day mt-2.5 mb-1.5 self-center text-xs text-subtle">Today</div>
            <div id="voice-turns" phx-update="stream" class="flex flex-col gap-2">
              <.turn :for={{id, turn} <- @streams.turns} id={id} turn={turn} />
            </div>
            <.pending_turn state={@mic_state} partner={@partner} />
          </div>
        </div>

        <.voice_area
          partner={@partner}
          toast={@toast}
          state={@mic_state}
          typing?={@typing?}
          type_form={@type_form}
          user_id={@current_user_record && @current_user_record.id}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("open_sheet", %{"sheet" => "partner"}, socket),
    do: {:noreply, assign(socket, :sheet, :partner)}

  def handle_event("open_sheet", %{"sheet" => "context"}, socket) do
    {:noreply,
     socket
     |> assign(:sheet, :context)
     |> assign(:query, "")
     |> assign(:ctx_form, to_form(%{"q" => ""}, as: :ctx))}
  end

  def handle_event("close_sheet", _params, socket), do: {:noreply, assign(socket, :sheet, nil)}

  def handle_event("pick_partner", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.partners, &(&1.agent.id == id)) do
      nil ->
        {:noreply, assign(socket, :sheet, nil)}

      partner ->
        greeting =
          if partner.agent.slug == @default_slug,
            do: @back_greeting,
            else: other_greeting(partner)

        socket =
          socket
          |> end_session()
          |> assign(:partner, partner)
          |> assign(:sheet, nil)
          |> stream(:turns, [], reset: true)

        {:noreply, maybe_greet(socket, partner, greeting)}
    end
  end

  def handle_event("pick_context", %{"id" => id}, socket) do
    context = find_context(socket.assigns.spaces, id)

    note =
      if context,
        do: "now talking about #{context.name} · transcript posts there",
        else: "no context · transcript stays here"

    if socket.assigns.session, do: VoiceSession.set_context(socket.assigns.session, context)

    {:noreply,
     socket
     |> assign(:context, context)
     |> assign(:sheet, nil)
     |> insert_turn(%{kind: :day, text: note})
     |> push_event("voice_ctx_saved", %{id: context && context.id})}
  end

  def handle_event("ctx_search", %{"ctx" => %{"q" => q}}, socket) do
    {:noreply,
     socket
     |> assign(:query, q)
     |> assign(:ctx_form, to_form(%{"q" => q}, as: :ctx))}
  end

  # Enter in the search picks the first space it shows (the masters' keydown).
  def handle_event("ctx_search_submit", %{"ctx" => %{"q" => q}}, socket) do
    case filter_spaces(socket.assigns.spaces, q) do
      [first | _] -> handle_event("pick_context", %{"id" => first.id}, socket)
      [] -> handle_event("ctx_search", %{"ctx" => %{"q" => q}}, socket)
    end
  end

  # The device's remembered context, pushed once by the VoiceContext hook. A
  # stale id (left the space, archived) is cleared on the device, silently.
  def handle_event("voice_restore_context", %{"id" => id}, socket) do
    if socket.assigns.context_restored? do
      {:noreply, socket}
    else
      socket = assign(socket, :context_restored?, true)

      case find_context(socket.assigns.spaces, id) do
        nil -> {:noreply, push_event(socket, "voice_ctx_saved", %{id: nil})}
        context -> {:noreply, assign(socket, :context, context)}
      end
    end
  end

  def handle_event("pipeline_info", _params, socket) do
    Process.send_after(self(), :clear_toast, @toast_ms)
    {:noreply, assign(socket, :toast, @toast_text)}
  end

  # ── talking (the VoiceTab hook) ───────────────────────────────────────

  def handle_event("voice_start", _params, socket) do
    %{partner: partner, session: session, context: context} = socket.assigns
    user = socket.assigns[:current_user_record]

    cond do
      not talkable?(partner) ->
        {:reply, %{ok: false}, assign(socket, :mic_state, :unavailable)}

      session && session.agent_id == partner.agent.id ->
        {:reply, session_reply(session), socket}

      true ->
        case VoiceSession.start(user, partner.agent, context) do
          {:ok, session} ->
            {:reply, session_reply(session), assign(socket, :session, session)}

          {:error, _reason} ->
            {:reply, %{ok: false}, assign(socket, :mic_state, :unavailable)}
        end
    end
  end

  def handle_event("voice_press", _params, %{assigns: %{session: nil}} = socket),
    do: {:noreply, push_event(socket, "voice_reset", %{})}

  def handle_event("voice_press", _params, socket) do
    user = socket.assigns[:current_user_record]

    case VoiceSession.press(socket.assigns.session, user) do
      {:ok, _holder} ->
        {:noreply,
         socket
         |> cancel_answer_timer()
         |> assign(:mic_state, :listening)
         |> assign(:heard?, false)}

      {:error, _reason} ->
        {:noreply, socket |> assign(:mic_state, :idle) |> push_event("voice_reset", %{})}
    end
  end

  def handle_event("voice_toggled", _params, socket) do
    case socket.assigns.mic_state do
      :listening -> {:noreply, assign(socket, :mic_state, :toggled)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("voice_release", params, socket) do
    if socket.assigns.mic_state in [:listening, :toggled] do
      release_floor(socket)
      duration = duration_ms(params)

      if duration < @too_short_ms and not socket.assigns.heard? do
        {:noreply, assign(socket, :mic_state, :idle)}
      else
        {:noreply, socket |> assign(:mic_state, :thinking) |> start_answer_timer()}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("voice_turn", %{"who" => who, "text" => text} = params, socket)
      when who in ["me", "agent"] and is_binary(text) do
    case String.trim(text) do
      "" -> {:noreply, socket}
      text when who == "me" -> {:noreply, my_turn(socket, text, :voice, params["at"])}
      text -> {:noreply, agent_turn(socket, text)}
    end
  end

  def handle_event("voice_turn", _params, socket), do: {:noreply, socket}

  def handle_event("voice_retry", _params, socket) do
    {:noreply,
     socket
     |> cancel_answer_timer()
     |> assign(:mic_state, :idle)
     |> push_event("voice_focus_mic", %{})}
  end

  def handle_event("voice_mic_blocked", _params, socket),
    do: {:noreply, assign(socket, :mic_state, :blocked)}

  def handle_event("voice_connect_failed", _params, socket) do
    {:noreply, socket |> assign(:session, nil) |> assign(:mic_state, :unavailable)}
  end

  def handle_event("voice_type_open", _params, socket),
    do: {:noreply, socket |> assign(:typing?, true) |> assign(:type_form, type_form())}

  def handle_event("voice_type", %{"type" => %{"text" => text}}, socket) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        {:noreply, socket |> my_turn(text, :typed, nil) |> assign(:type_form, type_form())}
    end
  end

  def handle_event("voice_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:clear_toast, socket), do: {:noreply, assign(socket, :toast, nil)}

  def handle_info({:answer_timeout, ref}, %{assigns: %{answer_ref: ref}} = socket)
      when is_reference(ref) do
    socket = assign(socket, :answer_ref, nil)

    case socket.assigns.mic_state do
      :thinking -> {:noreply, assign(socket, :mic_state, :failed)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:answer_timeout, _stale}, socket), do: {:noreply, socket}

  # The shell subscribes this process to the viewer's chat spaces (unread
  # badges, presence), so their broadcasts arrive here too; the Voice screen
  # has nothing to do with them.
  def handle_info(_message, socket), do: {:noreply, socket}

  # ── helpers ───────────────────────────────────────────────────────────

  @doc false
  def default_slug, do: @default_slug

  @doc "Milliseconds a release must reach, with no final caption, to count as a turn."
  def too_short_ms, do: @too_short_ms

  defp answer_timeout_ms,
    do: Application.get_env(:platform, :voice_answer_timeout_ms, @answer_timeout_ms)

  defp session_reply(session) do
    %{ok: true, token: session.token, url: session.livekit_url, room: session.room_name}
  end

  defp type_form, do: to_form(%{"text" => ""}, as: :type)

  defp duration_ms(%{"duration_ms" => d}) when is_integer(d), do: d
  defp duration_ms(%{"duration_ms" => d}) when is_float(d), do: round(d)
  defp duration_ms(_), do: @too_short_ms

  defp release_floor(%{assigns: %{session: nil}}), do: :ok

  defp release_floor(socket) do
    VoiceSession.release(socket.assigns.session, socket.assigns[:current_user_record])
  end

  # A partner change: close a live turn's floor on the OLD agent first, then
  # drop the session and tell the hook to leave the room.
  defp end_session(%{assigns: %{session: nil}} = socket) do
    socket |> cancel_answer_timer() |> assign(:mic_state, :idle)
  end

  defp end_session(socket) do
    if socket.assigns.mic_state in [:listening, :toggled], do: release_floor(socket)

    socket
    |> cancel_answer_timer()
    |> assign(:session, nil)
    |> assign(:mic_state, :idle)
    |> push_event("voice_disconnect", %{})
  end

  defp start_answer_timer(socket) do
    socket = cancel_answer_timer(socket)
    ref = make_ref()
    Process.send_after(self(), {:answer_timeout, ref}, answer_timeout_ms())
    assign(socket, :answer_ref, ref)
  end

  defp cancel_answer_timer(socket), do: assign(socket, :answer_ref, nil)

  # The user's own final turn. Posted only when a context is set, and only
  # as the user (VoiceSession.post_transcript/3 checks write access).
  defp my_turn(socket, text, source, at) do
    user = socket.assigns[:current_user_record]

    posted_to =
      with %{id: id, name: name} <- socket.assigns.context,
           {:ok, _message} <- VoiceSession.post_transcript(user, id, text) do
        name
      else
        _ -> nil
      end

    socket
    |> assign(:heard?, true)
    |> insert_turn(%{kind: :me, text: text, meta: me_meta(source, at, posted_to)})
  end

  defp agent_turn(%{assigns: %{partner: nil}} = socket, _text), do: socket

  defp agent_turn(socket, text) do
    %{partner: partner, mic_state: state} = socket.assigns

    socket =
      if state in [:thinking, :failed],
        do: socket |> cancel_answer_timer() |> assign(:mic_state, :idle),
        else: socket

    insert_turn(socket, %{kind: :agent, from: partner.agent.name, slot: partner.slot, text: text})
  end

  defp me_meta(source, at, posted_to) do
    lead = if source == :typed, do: "typed", else: "🎙️ transcribed"
    base = "#{lead} · #{clock(at)}"
    if posted_to, do: base <> " · posted to #{posted_to}", else: base
  end

  # The hook sends the device's local clock ("9:41 AM"); anything else falls
  # back to the server's UTC clock.
  defp clock(at) when is_binary(at) do
    if Regex.match?(~r/^[0-9]{1,2}[:.][0-9]{2}(\s?[APMapm.]{2,4})?$/u, at),
      do: at,
      else: clock(nil)
  end

  defp clock(_), do: Calendar.strftime(DateTime.utc_now(), "%H:%M")

  defp partner_entry(%{agent: agent, reachable?: reachable?}) do
    %{
      agent: agent,
      reachable?: reachable?,
      slot: ColorPalette.slot_for(agent.color),
      description: description(agent)
    }
  end

  # Agents carry no description column; an operator-set metadata
  # "description" (or "role") is the line, else nothing.
  defp description(%{metadata: %{"description" => d}}) when is_binary(d) and d != "", do: d
  defp description(%{metadata: %{"role" => r}}) when is_binary(r) and r != "", do: r
  defp description(_), do: nil

  defp other_greeting(%{agent: agent, description: nil}), do: "Hey, #{agent.name} here. Go ahead."

  defp other_greeting(%{agent: agent, description: d}),
    do: "Hey, #{agent.name} here — #{d}. Go ahead."

  defp maybe_greet(socket, nil, _text), do: socket

  defp maybe_greet(socket, partner, text) do
    insert_turn(socket, %{
      kind: :agent,
      from: partner.agent.name,
      slot: partner.slot,
      text: text,
      greeting?: true
    })
  end

  defp insert_turn(socket, turn) do
    seq = socket.assigns.turn_seq + 1

    socket
    |> assign(:turn_seq, seq)
    |> stream_insert(:turns, Map.put(turn, :id, "turn-#{seq}"))
  end

  defp context_spaces(%{id: user_id}, scope) do
    user_id
    |> Chat.list_user_conversations(scope: scope)
    |> Enum.filter(&(&1.kind == "channel"))
    |> Enum.map(fn s ->
      %{
        id: s.id,
        name: s.name || "Unnamed channel",
        subtitle: blank_to_nil(s.topic || s.description)
      }
    end)
  end

  defp context_spaces(_user, _scope), do: []

  defp find_context(_spaces, id) when id in [nil, ""], do: nil

  defp find_context(spaces, id) do
    case Enum.find(spaces, &(&1.id == id)) do
      nil -> nil
      s -> %{id: s.id, name: s.name}
    end
  end

  defp filter_spaces(spaces, q) do
    case String.downcase(String.trim(q || "")) do
      "" ->
        spaces

      ql ->
        Enum.filter(spaces, fn s ->
          String.contains?(String.downcase(s.name), ql) or
            (is_binary(s.subtitle) and String.contains?(String.downcase(s.subtitle), ql))
        end)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)
end
