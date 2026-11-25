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
    * `voice_turn` `%{who, text, final, segment_id}`: a FINAL caption. Both
      sides are recorded in the user<->agent DM with
      `VoiceSession.record_turn/5` (task 01a1b6c3; the rules are in
      `VoiceSession`'s moduledoc): `who: "agent"` as the agent, `who: "me"`
      as the user, or, with a context set, into that context only (the
      bubble's meta gains " · posted to {ctx}") with one pointer row in the
      DM. An explicit `"final" => false` and a segment id already recorded in
      this session insert and post nothing. Typed turns (`voice_type`) are
      recorded with `input: "typed"`. With no session (the mic was refused
      before one started) a typed turn is only posted to the context, as
      before.
    * The session's one summary row is posted by `VoiceSession.finish/1` when
      the session ends here (`end_session/1`, `terminate/2`); the
      `room_finished` webhook is the fallback.
    * `voice_mic_blocked`: the browser refused the microphone. The line reads
      "Microphone is blocked. Allow it in your browser or app settings." with "Type
      instead", whose input submits through the same path as `who: "me"`.
    * `voice_mic_failed` `%{reason}`: the press ended before `voice_press`
      for a reason that is not a refusal (`no_api`, `timeout`, `not_live`,
      `reply_timeout`). `:mic_state` becomes `:mic_failed`, the reason is kept
      in `:mic_failure`, any half-open session is dropped (`voice_disconnect`)
      and the line reads "Couldn't start the microphone. Hold to try again.".
      The mic stays enabled; the next press starts a fresh attempt.
    * A context change calls `VoiceSession.set_context/2`; a partner change
      releases the floor if a turn is live and disconnects the old session
      (`voice_disconnect`) before the next press starts a new one.

  ## The on-device path (task 01a20dc5 stage 2)

  On an iPhone whose `BurrowVoice` plugin can transcribe on the device, the
  hook pushes `voice_native_ready` with `available: true`, and the tab talks
  without LiveKit: the phone turns speech into text, the text is posted as a
  plain DM message (`Platform.Meetings.OnDeviceVoice`), and the agent's text
  reply is pushed back as `voice_native_speak` for the system voice. Nothing
  here changes for any other client: until `voice_native_ready` arrives with
  `available: true` the tab renders exactly as before, and an `available:
  false` only logs its reason code (and, after a "preparing" that never
  finished, puts today's tab back).

    * `voice_native_ready` `%{available, reason, locale, test_build, route}`:
      sets `:on_device?` ONLY when `available` is true, opens the DM
      (`OnDeviceVoice.open/2`) and holds it with `SpaceTopics.hold/3` as
      `:voice`. `test_build` (a debug or TestFlight build) turns on the
      "On this iPhone" caption (canvas state 17).
    * `voice_native_turn` `%{text, client_turn_id}` (with a reply): posts the
      turn and replies `%{ok: true, message_id}` (or `%{ok: false}`); a
      `client_turn_id` already posted replies with that message and posts
      nothing. The confirmed turn is inserted with meta
      "on this iPhone · {clock}", and the agent is thinking until its reply
      lands or `:voice_native_answer_timeout_ms` (default 60s) passes.
    * The agent's reply arrives as `{:new_message, msg}` on the held DM
      topic; `OnDeviceVoice.agent_reply?/2` takes only the agent's message
      after the turn. It is inserted in full and pushed as
      `voice_native_speak %{id, text}` with markdown stripped.
    * `voice_native_speaking` `%{id, state, reason}`: `started` rings
      #partner-avatar until `finished`; `stopped` adds "Stopped" under the
      reply, `unheard` adds "Reply shown as text" (canvas states 9 and 10).
    * `voice_native_mic` `%{state}`: `held` / `toggled` / `idle` drive the mic
      and the listen line ("Release to send", "Tap to send"); `in_use`
      disables the mic with "Microphone in use by another app"; `preparing`
      disables it with "Preparing speech on this iPhone" while iOS fetches
      its speech files (canvas state 13).
    * `voice_native_permission` `%{mic: "denied"}`: the permission card
      replaces the mic, with "Type instead" beneath it (canvas state 12).
    * `voice_native_route` `%{label}`: the test caption's route.
    * A partner or context change pushes `voice_native_stop` (speech stops,
      a half-formed turn is discarded; canvas state 10). A partner change
      also releases the `:voice` hold and opens the new partner's DM.

  ### Streamed replies and Pocket TTS (task 01a20fdd stage 3)

    * `{:agent_reply_chunk, chunk}` on the held DM (cumulative text): the
      first chunk id from the agent while a reply is awaited is this turn's
      stream (`:native_stream %{chunk_id, said, seq, stopped?}`). Each newly
      complete sentence (`OnDeviceVoice.speakable_sentences/3`) is pushed as
      `voice_native_speak_part %{id: chunk_id, seq, text, final: false}`, so
      the phone starts speaking before the reply is posted.
    * The posted reply then speaks only what was not streamed, as one last
      part with `final: true` under the SAME id, and its turn answers to both
      ids, so `voice_native_speaking` lands on it. A posted text that does
      not begin with the streamed sentences pushes `voice_native_stop_speaking`
      instead of reading it again. A stream the phone stopped (the mic) is
      shown "Stopped" and never resumed. With no chunk, the one-shot
      `voice_native_speak` path runs unchanged.
    * A partner or context change, and `voice_native_stop`, drop the stream.
      A new turn retires it: its late chunks are ignored and its posted
      message is shown "Stopped" without touching the new reply.
    * Reply voices may be `neural` (Pocket TTS) with a `model
      %{state, received, total}`; `voice_native_model` updates it while it
      downloads. `voice_native_ttfs %{id, ms}` (test builds only) is logged
      with no reply text.

  The words still forming, "Sending", "Not sent" and Retry are drawn by the
  hook inside `#voice-native-pending` (`phx-update="ignore"`), so they still
  show with the socket down; the server renders only confirmed turns.

  ## State

    * `:partner`: `%{agent, slot, reachable?, description}` or nil. On mount it
      is `VoiceSession.default_partner/1` (Burrow) until the device says
      otherwise: the last pick is remembered per user on the device by the
      `VoiceContext` hook and pushed back on mount AND on every reconnect (a
      reconnect mounts this LiveView afresh, which used to drop the user back
      on Burrow mid-conversation). With no Burrow visible the
      pill reads "No voice partner" and the mic is disabled. A partner that
      is not `voice_reachable?` keeps the pill but disables the mic, and the
      listen line reads "{partner} can't talk right now.".
    * `:context`: `%{id, name}` or nil. "No context" or ONE non-archived
      channel the viewer participates in (projects and tasks are out of
      scope). The last pick is remembered on the device by the
      `VoiceContext` hook (`assets/js/hooks/voice_context.js`), which pushes
      it back on mount and on reconnect (`voice_restore`, keys from
      `data-keys`; `voice_saved` stores a pick or clears a stale id).
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

  require Logger

  alias Platform.Agents.ColorPalette
  alias Platform.Chat
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Meetings.VoiceSession
  alias PlatformWeb.SpaceTopics

  @default_slug "meeting-assistant"
  # VoiceContext's device keys (ClientState namespace "voice").
  @ctx_key "burrow-voice-ctx"
  @partner_key "burrow-voice-partner"
  @burrow_greeting "Morning. Anything on your mind? Hold the mic and just talk — I'll keep the thread."
  @back_greeting "Back with you."
  @too_short_ms 400
  @answer_timeout_ms 20_000
  # A text agent is slower than the voice worker.
  @native_answer_timeout_ms 60_000
  # Reply voices kept from the device: the system voices and, separately,
  # the Pocket TTS rows (20 on the iPhone as of task 01a20fdd stage 4), so
  # Pocket rows never push a system voice out. 72 rows at most.
  @max_system_voices 40
  @max_pocket_voices 32
  @voice_qualities ~w(neural premium enhanced default)
  @model_states ~w(absent downloading compiling ready failed)
  @max_retired 8
  @native_reasons ~w(os_too_old unavailable locale_unsupported speech_permission_denied assets_missing)

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
      |> assign(:partner_restored?, false)
      |> assign(:ctx_key, @ctx_key)
      |> assign(:sheet, nil)
      |> assign(:query, "")
      |> assign(:ctx_form, to_form(%{"q" => ""}, as: :ctx))
      |> assign(:toast, nil)
      |> assign(:turn_seq, 0)
      |> assign(:session, nil)
      |> assign(:mic_state, :idle)
      |> assign(:mic_failure, nil)
      |> assign(:heard?, false)
      |> assign(:answer_ref, nil)
      |> assign(:typing?, false)
      |> assign(:type_form, type_form())
      |> assign(:on_device?, false)
      |> assign(:on_device_caption, nil)
      |> assign(:native_test_build?, false)
      |> assign(:native_route, nil)
      |> assign(:mic_permission, nil)
      |> assign(:native_mic, :ready)
      |> assign(:speaking_id, nil)
      |> assign(:native_conn, nil)
      |> assign(:native_turn_ids, %{})
      |> assign(:native_replies, %{})
      |> assign(:native_announce, nil)
      |> assign(:native_voices, [])
      |> assign(:native_voice, nil)
      |> assign(:native_voice_missing?, false)
      |> assign(:native_pocket_missing?, false)
      |> assign(:native_stream, nil)
      |> assign(:native_retired, [])
      |> SpaceTopics.ensure_holders()
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
        data-keys={"#{@ctx_key} #{partner_key(@current_user_record)}"}
      >
        <header class="flex h-14 flex-none items-center justify-between gap-2 px-4">
          <div id="partner-anchor" class="relative">
            <.partner_pill partner={@partner} speaking={@on_device? and not is_nil(@speaking_id)} />
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
            <.native_pending :if={@on_device?} />
            <.pending_turn state={pending_state(@on_device?, @mic_state)} partner={@partner} />
          </div>
        </div>

        <.voice_area
          partner={@partner}
          toast={@toast}
          state={@mic_state}
          mic_failure={@mic_failure}
          typing?={@typing?}
          type_form={@type_form}
          user_id={@current_user_record && @current_user_record.id}
          on_device?={@on_device?}
          native_mic={@native_mic}
          mic_permission={@mic_permission}
          caption={@on_device_caption}
          announce={@native_announce}
          voices={@native_voices}
          voice={@native_voice}
          voice_missing?={@native_voice_missing?}
          pocket_missing?={@native_pocket_missing?}
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
        {:noreply,
         socket
         |> end_session()
         |> stop_native()
         |> switch_partner(partner)
         |> push_event("voice_saved", %{key: partner_key(socket), id: partner.agent.id})}
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
     |> stop_native()
     |> assign(:context, context)
     |> assign(:sheet, nil)
     |> insert_turn(%{kind: :day, text: note})
     |> push_event("voice_saved", %{key: @ctx_key, id: context && context.id})}
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
  def handle_event("voice_restore_context", %{"id" => id}, socket),
    do: {:noreply, restore_context(socket, id)}

  # What the device remembers (VoiceContext, on mount and on reconnect): the
  # last partner for this user, then the last context. Each is applied once
  # per mount; a stale id is cleared on the device, silently.
  def handle_event("voice_restore", params, socket) when is_map(params) do
    {:noreply,
     socket
     |> restore_partner(params[partner_key(socket)])
     |> restore_context(params[@ctx_key])}
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
    # `final` is passed through: `VoiceSession.record_turn/5` refuses an
    # explicit false (and the no-session clauses below drop it).
    caption = %{final: params["final"] != false, segment_id: params["segment_id"]}

    case String.trim(text) do
      "" -> {:noreply, socket}
      text when who == "me" -> {:noreply, my_turn(socket, text, :voice, params["at"], caption)}
      text -> {:noreply, agent_turn(socket, text, caption)}
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

  def handle_event("voice_mic_failed", params, socket) do
    {:noreply, mic_failed(socket, mic_failure(params))}
  end

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
        {:noreply,
         socket |> my_turn(text, :typed, nil, %{final: true}) |> assign(:type_form, type_form())}
    end
  end

  def handle_event("voice_type", _params, socket), do: {:noreply, socket}

  # ── on device (task 01a20dc5 stage 2) ─────────────────────────────────

  def handle_event("voice_native_ready", %{"available" => true} = params, socket) do
    test_build? = params["test_build"] == true

    socket =
      socket
      |> assign(:native_test_build?, test_build?)
      |> assign(:native_route, route_label(params["route"]))
      |> assign(:on_device?, true)
      |> assign_caption()

    {:noreply, if(socket.assigns.native_conn, do: socket, else: open_native(socket))}
  end

  # The speech files never arrived after "preparing": back to today's tab.
  def handle_event("voice_native_ready", params, %{assigns: %{on_device?: true}} = socket) do
    Logger.info("[VoiceLive] on-device voice unavailable: #{native_reason(params)}")

    {:noreply,
     socket
     |> drop_native()
     |> assign(:on_device?, false)
     |> assign(:native_mic, :ready)
     |> assign(:mic_permission, nil)
     |> assign(:native_test_build?, false)
     |> assign(:native_voices, [])
     |> assign(:native_voice, nil)
     |> assign(:native_voice_missing?, false)
     |> assign_caption()}
  end

  def handle_event("voice_native_ready", params, socket) do
    Logger.info("[VoiceLive] on-device voice unavailable: #{native_reason(params)}")
    {:noreply, socket}
  end

  def handle_event(
        "voice_native_turn",
        %{"text" => text, "client_turn_id" => turn_id} = params,
        %{assigns: %{on_device?: true}} = socket
      )
      when is_binary(text) and is_binary(turn_id) and turn_id != "" do
    case Map.fetch(socket.assigns.native_turn_ids, turn_id) do
      {:ok, message_id} ->
        {:reply, %{ok: true, message_id: message_id}, socket}

      :error ->
        socket = if socket.assigns.native_conn, do: socket, else: open_native(socket)
        native_turn(socket, socket.assigns.native_conn, text, turn_id, params["at"])
    end
  end

  def handle_event("voice_native_turn", _params, socket), do: {:reply, %{ok: false}, socket}

  def handle_event(
        "voice_native_speaking",
        %{"id" => id, "state" => state},
        %{assigns: %{on_device?: true}} = socket
      )
      when is_binary(id) do
    {:noreply, native_speaking(socket, id, state)}
  end

  def handle_event("voice_native_speaking", _params, socket), do: {:noreply, socket}

  def handle_event(
        "voice_native_mic",
        %{"state" => state},
        %{assigns: %{on_device?: true}} = socket
      ) do
    {:noreply, native_mic(socket, state)}
  end

  def handle_event("voice_native_mic", _params, socket), do: {:noreply, socket}

  def handle_event(
        "voice_native_permission",
        %{"mic" => mic},
        %{assigns: %{on_device?: true}} = socket
      ) do
    permission = if mic == "denied", do: :denied, else: nil
    {:noreply, assign(socket, :mic_permission, permission)}
  end

  def handle_event("voice_native_permission", _params, socket), do: {:noreply, socket}

  def handle_event("voice_native_route", params, %{assigns: %{on_device?: true}} = socket) do
    {:noreply, socket |> assign(:native_route, route_label(params["label"])) |> assign_caption()}
  end

  def handle_event("voice_native_route", _params, socket), do: {:noreply, socket}

  # The phone's on-device reply voices (best first) and the one in use; a
  # remembered voice that is gone reads `missing` (the default reads instead).
  def handle_event(
        "voice_native_voices",
        %{"voices" => voices} = params,
        %{assigns: %{on_device?: true}} = socket
      )
      when is_list(voices) do
    {pocket, system} =
      voices |> Enum.flat_map(&voice_entry/1) |> Enum.split_with(&(&1.quality == "neural"))

    voices = Enum.take(pocket, @max_pocket_voices) ++ Enum.take(system, @max_system_voices)
    selected = params["selected"]
    voice = if Enum.any?(voices, &(&1.id == selected)), do: selected, else: first_id(voices)

    {:noreply,
     socket
     |> assign(:native_voices, voices)
     |> assign(:native_voice, voice)
     |> assign(:native_voice_missing?, params["missing"] == true)
     |> assign(:native_pocket_missing?, params["missing_pocket"] == true)}
  end

  def handle_event("voice_native_voices", _params, socket), do: {:noreply, socket}

  # Pocket TTS's model while it downloads (task 01a20fdd stage 3).
  def handle_event("voice_native_model", params, %{assigns: %{on_device?: true}} = socket)
      when is_map(params) do
    case model_entry(params) do
      nil ->
        {:noreply, socket}

      model ->
        voices =
          Enum.map(socket.assigns.native_voices, fn
            %{quality: "neural"} = v -> Map.put(v, :model, model)
            v -> v
          end)

        {:noreply, assign(socket, :native_voices, voices)}
    end
  end

  def handle_event("voice_native_model", _params, socket), do: {:noreply, socket}

  # Time to first sound (test builds only): logged for the device report,
  # with no reply text.
  def handle_event(
        "voice_native_ttfs",
        %{"id" => id, "ms" => ms},
        %{assigns: %{on_device?: true, native_test_build?: true}} = socket
      )
      when is_binary(id) and is_number(ms) do
    Logger.info("[VoiceLive] on-device ttfs ms=#{round(ms)} id=#{String.slice(id, 0, 64)}")
    {:noreply, socket}
  end

  def handle_event("voice_native_ttfs", _params, socket), do: {:noreply, socket}

  def handle_event(
        "voice_native_pick_voice",
        %{"voice" => id},
        %{assigns: %{on_device?: true}} = socket
      ) do
    if Enum.any?(socket.assigns.native_voices, &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(:native_voice, id)
       |> assign(:native_voice_missing?, false)
       |> assign(:native_pocket_missing?, false)
       |> push_event("voice_native_voice", %{id: id})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("voice_native_pick_voice", _params, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    finish_session(socket)
    _ = SpaceTopics.release_all(socket, :voice)
    :ok
  end

  @impl true
  def handle_info({:answer_timeout, ref}, %{assigns: %{answer_ref: ref}} = socket)
      when is_reference(ref) do
    socket = assign(socket, :answer_ref, nil)

    case socket.assigns.mic_state do
      :thinking -> {:noreply, assign(socket, :mic_state, :failed)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:answer_timeout, _stale}, socket), do: {:noreply, socket}

  # The agent's text reply on the held DM (on-device path only). Every other
  # message, and every message when the path is closed, falls through to the
  # catch-all below exactly as before.
  def handle_info(
        {:new_message, %{} = message},
        %{assigns: %{on_device?: true, native_conn: %{} = conn}} = socket
      ) do
    if OnDeviceVoice.agent_reply?(conn, message) and
         not Map.has_key?(socket.assigns.native_replies, message.id) do
      {:noreply, native_reply(socket, message)}
    else
      {:noreply, socket}
    end
  end

  # The agent's reply streaming in (task 01a20fdd stage 3): on the device
  # only, and only the agent's chunks in the held DM.
  def handle_info(
        {:agent_reply_chunk, %{} = chunk},
        %{assigns: %{on_device?: true, native_conn: %{} = conn}} = socket
      ) do
    if OnDeviceVoice.agent_chunk?(conn, chunk),
      do: {:noreply, native_chunk(socket, chunk)},
      else: {:noreply, socket}
  end

  # The shell subscribes this process to the viewer's chat spaces (unread
  # badges, presence), so their broadcasts arrive here too; the Voice screen
  # has nothing to do with them.
  def handle_info(_message, socket), do: {:noreply, socket}

  # ── helpers ───────────────────────────────────────────────────────────

  @doc false
  def default_slug, do: @default_slug

  @doc "Milliseconds a release must reach, with no final caption, to count as a turn."
  def too_short_ms, do: @too_short_ms

  defp answer_timeout_ms(%{assigns: %{on_device?: true}}),
    do: Application.get_env(:platform, :voice_native_answer_timeout_ms, @native_answer_timeout_ms)

  defp answer_timeout_ms(_socket),
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
    finish_session(socket)

    socket
    |> cancel_answer_timer()
    |> assign(:session, nil)
    |> assign(:mic_state, :idle)
    |> push_event("voice_disconnect", %{})
  end

  @mic_failures ~w(no_api timeout not_live reply_timeout)

  defp mic_failure(%{"reason" => reason}) when reason in @mic_failures, do: reason
  defp mic_failure(_params), do: "unknown"

  # A local mic failure: no turn ever started, so there is no floor to
  # release; drop a half-open session so the next press starts fresh.
  defp mic_failed(socket, reason) do
    socket =
      if socket.assigns.session,
        do: socket |> assign(:session, nil) |> push_event("voice_disconnect", %{}),
        else: socket

    socket
    |> cancel_answer_timer()
    |> assign(:mic_state, :mic_failed)
    |> assign(:mic_failure, reason)
  end

  defp start_answer_timer(socket) do
    socket = cancel_answer_timer(socket)
    ref = make_ref()
    Process.send_after(self(), {:answer_timeout, ref}, answer_timeout_ms(socket))
    assign(socket, :answer_ref, ref)
  end

  defp cancel_answer_timer(socket), do: assign(socket, :answer_ref, nil)

  # Best effort: a summary that fails here is posted by the `room_finished`
  # fallback (`VoiceSession.finish_unfinished/1`).
  defp finish_session(%{assigns: %{session: %{} = session}}) do
    VoiceSession.finish(session)
  rescue
    e ->
      Logger.warning("[VoiceLive] voice summary failed: #{Exception.message(e)}")
      :error
  end

  defp finish_session(_socket), do: :ok

  # The user's own final turn, recorded through `VoiceSession.record_turn/5`
  # (DM, or the context with a pointer in the DM). A skipped caption (not
  # final, a repeated segment) inserts no bubble either.
  defp my_turn(%{assigns: %{session: nil}} = socket, _text, _source, _at, %{final: false}),
    do: socket

  defp my_turn(%{assigns: %{session: nil}} = socket, text, source, at, _caption) do
    user = socket.assigns[:current_user_record]

    posted_to =
      with %{id: id, name: name} <- socket.assigns.context,
           {:ok, _message} <- VoiceSession.post_transcript(user, id, text) do
        name
      else
        _ -> nil
      end

    insert_my_turn(socket, text, source, at, posted_to)
  end

  defp my_turn(socket, text, source, at, caption) do
    user = socket.assigns[:current_user_record]

    opts = [
      input: source,
      context: socket.assigns.context,
      segment_id: caption[:segment_id],
      final: caption[:final]
    ]

    case VoiceSession.record_turn(socket.assigns.session, user, :me, text, opts) do
      {:ok, session, %{posted_to: posted_to}} ->
        socket |> assign(:session, session) |> insert_my_turn(text, source, at, posted_to)

      {:skip, session, _reason} ->
        assign(socket, :session, session)

      {:error, _reason, session} ->
        socket |> assign(:session, session) |> insert_my_turn(text, source, at, nil)
    end
  end

  defp insert_my_turn(socket, text, source, at, posted_to) do
    socket
    |> assign(:heard?, true)
    |> insert_turn(%{kind: :me, text: text, meta: me_meta(source, at, posted_to)})
  end

  defp agent_turn(%{assigns: %{partner: nil}} = socket, _text, _caption), do: socket

  defp agent_turn(%{assigns: %{session: nil}} = socket, _text, %{final: false}), do: socket

  defp agent_turn(%{assigns: %{session: nil}} = socket, text, _caption),
    do: insert_agent_turn(socket, text)

  defp agent_turn(socket, text, caption) do
    user = socket.assigns[:current_user_record]
    opts = [segment_id: caption[:segment_id], final: caption[:final]]

    case VoiceSession.record_turn(socket.assigns.session, user, :agent, text, opts) do
      {:skip, session, _reason} ->
        assign(socket, :session, session)

      {_posted_or_error, session, _} ->
        socket |> assign(:session, session) |> insert_agent_turn(text)
    end
  end

  defp insert_agent_turn(socket, text) do
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

  # ── on-device helpers ─────────────────────────────────────────────────

  defp native_reason(%{"reason" => reason}) when reason in @native_reasons, do: reason
  defp native_reason(_params), do: "unknown"

  # The route label is generic ("Bluetooth"), never a device's own name.
  defp route_label(label) when label in ["Bluetooth", "Headphones", "Car"], do: label
  defp route_label(_label), do: nil

  defp assign_caption(%{assigns: %{native_test_build?: true, native_route: route}} = socket) do
    caption = if route, do: "On this iPhone · #{route}", else: "On this iPhone"
    assign(socket, :on_device_caption, caption)
  end

  defp assign_caption(socket), do: assign(socket, :on_device_caption, nil)

  # Opens the partner's DM and holds its topic as `:voice`.
  defp open_native(%{assigns: %{partner: %{agent: agent}}} = socket) do
    user = socket.assigns[:current_user_record]

    case user && OnDeviceVoice.open(user, agent) do
      {:ok, conn} ->
        socket
        |> assign(:native_conn, conn)
        |> SpaceTopics.hold(conn.space_id, :voice)

      _ ->
        assign(socket, :native_conn, nil)
    end
  end

  defp open_native(socket), do: assign(socket, :native_conn, nil)

  defp reopen_native(%{assigns: %{on_device?: true}} = socket), do: open_native(socket)
  defp reopen_native(socket), do: socket

  # A partner or context change: the phone stops speaking and drops a
  # half-formed turn (canvas state 10).
  defp stop_native(%{assigns: %{on_device?: true}} = socket) do
    socket
    |> push_event("voice_native_stop", %{})
    |> retire_stream()
    |> cancel_answer_timer()
    |> assign(:mic_state, :idle)
    |> assign(:speaking_id, nil)
  end

  defp stop_native(socket), do: socket

  # A partner change: the old DM's `:voice` hold is released (the new
  # partner's DM is opened by `reopen_native/1`).
  defp drop_native(%{assigns: %{on_device?: true}} = socket) do
    socket
    |> SpaceTopics.release_all(:voice)
    |> assign(:native_conn, nil)
    |> assign(:native_replies, %{})
    |> assign(:native_announce, nil)
    |> assign(:native_stream, nil)
    |> assign(:native_retired, [])
  end

  defp drop_native(socket), do: socket

  defp native_turn(socket, nil, _text, _turn_id, _at), do: {:reply, %{ok: false}, socket}

  defp native_turn(socket, conn, text, turn_id, at) do
    case OnDeviceVoice.find_turn(conn, turn_id) do
      %{} = posted ->
        conn = OnDeviceVoice.mark_turn(conn, posted)

        {:reply, %{ok: true, message_id: posted.id},
         confirm_native_turn(socket, conn, posted, turn_id, at)}

      nil ->
        case OnDeviceVoice.send_turn(conn, text, turn_id) do
          {:ok, conn, message} ->
            {:reply, %{ok: true, message_id: message.id},
             confirm_native_turn(socket, conn, message, turn_id, at)}

          {:error, _reason} ->
            {:reply, %{ok: false}, socket}
        end
    end
  end

  defp confirm_native_turn(socket, conn, message, turn_id, at) do
    socket
    |> assign(:native_conn, conn)
    |> update(:native_turn_ids, &Map.put(&1, turn_id, message.id))
    |> assign(:heard?, true)
    |> retire_stream()
    |> insert_turn(%{
      kind: :me,
      text: message.content,
      meta: "on this iPhone · #{clock(at)}"
    })
    |> assign(:mic_state, :thinking)
    |> start_answer_timer()
  end

  defp insert_native_reply(socket, message, opts \\ [])

  defp insert_native_reply(%{assigns: %{partner: nil}} = socket, _message, _opts), do: socket

  # `:also` is the speech id when it is not the message's (a streamed reply's
  # chunk id), so the phone's speech events land on this turn too.
  defp insert_native_reply(socket, message, opts) do
    %{partner: partner} = socket.assigns
    seq = socket.assigns.turn_seq + 1

    turn = %{
      id: "turn-#{seq}",
      kind: :agent,
      from: partner.agent.name,
      slot: partner.slot,
      text: message.content
    }

    turn = if note = opts[:note], do: Map.put(turn, :note, note), else: turn
    ids = Enum.reject([message.id, opts[:also]], &is_nil/1)

    socket
    |> cancel_answer_timer()
    |> assign(:mic_state, :idle)
    |> assign(:turn_seq, seq)
    |> update(:native_replies, fn replies -> Enum.reduce(ids, replies, &Map.put(&2, &1, turn)) end)
    |> assign(:native_announce, "#{partner.agent.name} replied")
    |> stream_insert(:turns, turn)
  end

  # ── streamed replies (task 01a20fdd stage 3) ──────────────────────────

  # A chunk of the awaited reply. The first chunk id while the agent is
  # thinking opens the stream; a retired id (an earlier turn's reply) and
  # any other id are ignored.
  defp native_chunk(socket, %{chunk_id: id, text: text} = chunk) do
    %{native_stream: stream, native_retired: retired, mic_state: mic} = socket.assigns

    cond do
      List.keymember?(retired, id, 0) ->
        socket

      is_nil(stream) and mic == :thinking ->
        socket
        |> assign(:native_stream, %{chunk_id: id, said: [], seq: 0, stopped?: false})
        |> speak_chunk(text, chunk[:done] == true)

      match?(%{chunk_id: ^id, stopped?: false}, stream) ->
        speak_chunk(socket, text, chunk[:done] == true)

      true ->
        socket
    end
  end

  defp speak_chunk(socket, text, done?) do
    stream = socket.assigns.native_stream
    {sentences, _count} = OnDeviceVoice.speakable_sentences(length(stream.said), text, done?)

    {socket, stream} =
      Enum.reduce(sentences, {socket, stream}, fn sentence, {socket, stream} ->
        socket =
          push_event(socket, "voice_native_speak_part", %{
            id: stream.chunk_id,
            seq: stream.seq,
            text: sentence,
            final: false
          })

        {socket, %{stream | said: stream.said ++ [sentence], seq: stream.seq + 1}}
      end)

    # Activity: a long streamed answer is not a timed-out one.
    socket = if sentences != [], do: start_answer_timer(socket), else: socket
    assign(socket, :native_stream, stream)
  end

  # The posted reply. Streamed: only what was not spoken, as the final part
  # under the stream's id, or a stop when the text diverged. Not streamed:
  # today's one-shot speak.
  defp native_reply(socket, message) do
    %{native_stream: stream, native_retired: retired} = socket.assigns
    posted = posted_sentences(message.content)

    cond do
      old =
          Enum.find_value(retired, fn {id, said} ->
            (said != [] and prefix?(said, posted)) && id
          end) ->
        socket
        |> update(:native_retired, &List.keydelete(&1, old, 0))
        |> insert_native_reply(message, also: old, note: "Stopped")

      is_map(stream) and stream.stopped? ->
        socket
        |> finish_stream()
        |> insert_native_reply(message, also: stream.chunk_id, note: "Stopped")

      is_map(stream) and prefix?(stream.said, posted) ->
        rest = posted |> Enum.drop(length(stream.said)) |> Enum.join(" ")
        log_reply(length(stream.said) + if(rest == "", do: 0, else: 1), true)

        socket
        |> finish_stream()
        |> insert_native_reply(message, also: stream.chunk_id)
        |> push_event("voice_native_speak_part", %{
          id: stream.chunk_id,
          seq: stream.seq,
          text: rest,
          final: true
        })

      is_map(stream) ->
        Logger.info("[VoiceLive] on-device reply diverged from its stream; speech stopped")

        socket
        |> finish_stream()
        |> insert_native_reply(message, also: stream.chunk_id)
        |> push_event("voice_native_stop_speaking", %{id: stream.chunk_id})

      true ->
        log_reply(1, false)

        socket
        |> insert_native_reply(message)
        |> push_event("voice_native_speak", %{
          id: message.id,
          text: OnDeviceVoice.speakable_text(message.content)
        })
    end
  end

  defp posted_sentences(content) do
    {sentences, _count} = OnDeviceVoice.speakable_sentences(0, content, true)
    sentences
  end

  defp prefix?(said, posted), do: Enum.take(posted, length(said)) == said

  # Parts and streaming per reply, for the device report; never the text.
  defp log_reply(parts, streamed?),
    do: Logger.info("[VoiceLive] on-device reply parts=#{parts} streamed=#{streamed?}")

  defp finish_stream(socket), do: assign(socket, :native_stream, nil)

  # The phone stopped the stream's speech (the mic, a route loss): the rest
  # of it is never spoken.
  defp stop_stream(%{assigns: %{native_stream: %{chunk_id: id} = stream}} = socket, id),
    do: assign(socket, :native_stream, %{stream | stopped?: true})

  defp stop_stream(socket, _id), do: socket

  # A new turn, a context change or a stop: the open stream's later chunks
  # and its posted message must not reach the next reply. The last
  # @max_retired are kept.
  defp retire_stream(%{assigns: %{native_stream: %{chunk_id: id, said: said}}} = socket) do
    socket
    |> update(:native_retired, &Enum.take([{id, said} | &1], @max_retired))
    |> assign(:native_stream, nil)
  end

  defp retire_stream(socket), do: socket

  defp native_speaking(socket, id, "started"), do: assign(socket, :speaking_id, id)

  defp native_speaking(socket, id, "finished"), do: clear_speaking(socket, id)

  defp native_speaking(socket, id, "stopped"),
    do: socket |> clear_speaking(id) |> stop_stream(id) |> mark_reply(id, "Stopped")

  defp native_speaking(socket, id, "unheard"),
    do: socket |> clear_speaking(id) |> mark_reply(id, "Reply shown as text")

  defp native_speaking(socket, _id, _state), do: socket

  defp clear_speaking(%{assigns: %{speaking_id: id}} = socket, id),
    do: assign(socket, :speaking_id, nil)

  defp clear_speaking(socket, _id), do: socket

  defp mark_reply(socket, id, note) do
    case Map.fetch(socket.assigns.native_replies, id) do
      {:ok, turn} ->
        turn = Map.put(turn, :note, note)

        socket
        |> update(:native_replies, &Map.put(&1, id, turn))
        |> stream_insert(:turns, turn)

      :error ->
        socket
    end
  end

  defp native_mic(socket, "held") do
    socket
    |> cancel_answer_timer()
    |> assign(:native_mic, :ready)
    |> assign(:mic_state, :listening)
  end

  defp native_mic(%{assigns: %{mic_state: :listening}} = socket, "toggled"),
    do: assign(socket, :mic_state, :toggled)

  defp native_mic(socket, "toggled"), do: socket

  defp native_mic(socket, "in_use"),
    do: socket |> assign(:native_mic, :in_use) |> assign(:mic_state, :idle)

  defp native_mic(socket, "preparing"),
    do: socket |> assign(:native_mic, :preparing) |> assign(:mic_state, :idle)

  defp native_mic(socket, "idle") do
    state =
      if socket.assigns.mic_state in [:listening, :toggled],
        do: :idle,
        else: socket.assigns.mic_state

    socket |> assign(:native_mic, :ready) |> assign(:mic_state, state)
  end

  defp native_mic(socket, _state), do: socket

  # The hook draws the forming words itself on the on-device path.
  defp pending_state(true, state) when state in [:listening, :toggled], do: :idle
  defp pending_state(_on_device?, state), do: state

  defp voice_entry(%{"id" => id, "name" => name} = v)
       when is_binary(id) and is_binary(name) and id != "" and byte_size(id) <= 200 do
    quality = if v["quality"] in @voice_qualities, do: v["quality"], else: "default"
    entry = %{id: id, name: String.slice(name, 0, 60), quality: quality}

    case quality == "neural" && model_entry(v["model"]) do
      %{} = model -> [Map.put(entry, :model, model)]
      _ -> [entry]
    end
  end

  defp voice_entry(_voice), do: []

  # Pocket TTS's model as the picker shows it; nil for anything malformed.
  defp model_entry(%{"state" => state} = m) when state in @model_states do
    %{state: state, received: count(m["received"]), total: count(m["total"])}
  end

  defp model_entry(_model), do: nil

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(n) when is_float(n) and n >= 0, do: round(n)
  defp count(_n), do: 0

  defp first_id([%{id: id} | _]), do: id
  defp first_id([]), do: nil

  defp partner_key(%Phoenix.LiveView.Socket{} = socket),
    do: partner_key(socket.assigns[:current_user_record])

  defp partner_key(%{id: user_id}), do: "#{@partner_key}:#{user_id}"
  defp partner_key(_user), do: @partner_key

  # A partner pick (or a restored one): a fresh transcript with that
  # partner's greeting, and on the device the partner's DM is held instead.
  defp switch_partner(socket, partner) do
    greeting =
      if partner.agent.slug == @default_slug,
        do: @back_greeting,
        else: other_greeting(partner)

    socket
    |> drop_native()
    |> assign(:partner, partner)
    |> assign(:sheet, nil)
    |> stream(:turns, [], reset: true)
    |> reopen_native()
    |> maybe_greet(partner, greeting)
  end

  defp restore_partner(%{assigns: %{partner_restored?: true}} = socket, _id), do: socket
  defp restore_partner(socket, id) when not is_binary(id), do: socket

  defp restore_partner(socket, id) do
    socket = assign(socket, :partner_restored?, true)

    case Enum.find(socket.assigns.partners, &(&1.agent.id == id)) do
      nil ->
        push_event(socket, "voice_saved", %{key: partner_key(socket), id: nil})

      %{agent: %{id: ^id}} when socket.assigns.partner.agent.id == id ->
        socket

      partner ->
        switch_partner(socket, partner)
    end
  end

  defp restore_context(%{assigns: %{context_restored?: true}} = socket, _id), do: socket
  defp restore_context(socket, id) when not is_binary(id), do: socket

  defp restore_context(socket, id) do
    socket = assign(socket, :context_restored?, true)

    case find_context(socket.assigns.spaces, id) do
      nil -> push_event(socket, "voice_saved", %{key: @ctx_key, id: nil})
      context -> assign(socket, :context, context)
    end
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
