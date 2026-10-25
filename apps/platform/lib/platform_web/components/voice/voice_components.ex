defmodule PlatformWeb.Components.Voice do
  @moduledoc """
  Function components for the Voice tab, `PlatformWeb.VoiceLive` (task
  01a1557a-eab7 stage 2). Each one is a node of the masters' screen `home`
  (master-mobile.html :559-589, sheets :727-740):

    * `partner_pill/1` (#partner, #partner-avatar) and `context_pill/1` (#ctx);
    * `thread_line/1` (#thread-line);
    * `turn/1`: a transcript stream item, a `.day` note or an agent bubble
      (`.bubble.agent`, the greeting carries `data-partner-greeting`);
    * `turn/1` also renders your own turn (`.bubble.me`, meta
      "🎙️ transcribed · {time}" plus " · posted to {ctx}");
    * `pending_turn/1`: the live bubble while you talk (`.bubble.me.live`),
      the thinking dots and the failed reply (stage 3);
    * `voice_area/1`: #listen-line, #meter, #mic and #pipeline-info, in every
      talk state (idle, listening, toggled, thinking, blocked, unavailable).
      It carries the `VoiceTab` hook (stage 3);
    * `partner_sheet/1` (#partner-sheet) and `context_sheet/1` (#ctx-sheet).
      `variant: :sheet` (the default) is a bottom sheet at every width;
      `variant: :popover` (stage 4, what VoiceLive renders) is the same
      bottom sheet on a phone and, at lg and up, a popover anchored under its
      pill (direction canvas 01a1705c state 9). One component, one markup:
      the variant only stamps `voice-popover` / `data-variant` / `data-anchor`
      (the lg geometry is CSS) and gives the rows `lg:hover:bg-base-200`.
      Escape, the focus trap and focus return are the `Sheet` hook's; each
      sheet names its pill in `data-return-focus` for browsers whose click
      does not focus the pill.

  Colour: semantic tokens only. Agent identity is `data-agent-slot`, which
  app.css turns into `--ag`, `--ag-text` and `--ag-tint`; the `.voice-*`
  rules that read them are held by
  `test/platform/design/voice_tab_contrast_guard_test.exs`. Text is
  text-base-content or text-subtle, plus text-error for the unreachable line.
  No `hover:` classes: these are phone surfaces. The one exception is
  `lg:hover:bg-base-200` on the popover variant's rows, which only exist as
  popovers at lg. The pills' focus-visible ring is a primary outline.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1, input: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  @idle_line "hold to talk · tap to toggle"

  @doc "The listen line's idle copy."
  def idle_line, do: @idle_line

  # ── avatar ────────────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :slot, :string, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: "size-7 text-xs"

  def avatar(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "voice-avatar inline-flex flex-none items-center justify-center rounded-full font-semibold",
        @class
      ]}
      data-agent-slot={@slot}
      aria-hidden="true"
    >
      {initial(@name)}
    </span>
    """
  end

  # ── pills ─────────────────────────────────────────────────────────────

  attr :partner, :map, default: nil, doc: "%{agent, slot, reachable?} or nil"

  def partner_pill(assigns) do
    ~H"""
    <button
      type="button"
      id="partner"
      class="inline-flex h-9 items-center gap-2 rounded-full border border-edge bg-base-100 pl-1 pr-3 text-[15px] text-base-content active:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
      aria-haspopup="dialog"
      aria-label={partner_aria(@partner)}
      phx-click="open_sheet"
      phx-value-sheet="partner"
    >
      <%= if @partner do %>
        <.avatar id="partner-avatar" name={@partner.agent.name} slot={@partner.slot} />
        <b id="partner-name" class="font-semibold">{@partner.agent.name}</b>
      <% else %>
        <b id="partner-name" class="pl-2 font-medium text-subtle">No voice partner</b>
      <% end %>
      <.icon name="hero-chevron-down" class="size-3.5 text-subtle" />
    </button>
    """
  end

  attr :context, :map, default: nil, doc: "%{id, name} or nil"

  def context_pill(assigns) do
    ~H"""
    <button
      type="button"
      id="ctx"
      class="inline-flex h-9 min-w-0 max-w-[190px] items-center gap-2 rounded-full border border-edge bg-base-100 pl-2.5 pr-3 text-[15px] text-base-content active:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
      data-ctx={if @context, do: "set", else: "none"}
      aria-haspopup="dialog"
      aria-label={context_aria(@context)}
      phx-click="open_sheet"
      phx-value-sheet="context"
    >
      <span class="text-sm text-subtle">in:</span>
      <b
        id="ctx-name"
        class={[
          "min-w-0 truncate",
          if(@context, do: "font-semibold", else: "font-medium text-subtle")
        ]}
      >
        {if @context, do: @context.name, else: "No context"}
      </b>
      <.icon name="hero-chevron-down" class="size-3.5 flex-none text-subtle" />
    </button>
    """
  end

  attr :partner, :map, default: nil
  attr :context, :map, default: nil

  def thread_line(assigns) do
    ~H"""
    <div
      id="thread-line"
      class="flex-none truncate px-[18px] pb-1 text-center text-sm text-subtle"
    >
      <b id="thread-pair" class="font-semibold text-base-content">{thread_pair(@partner)}</b><span id="thread-ctx">{thread_ctx(@context)}</span>
    </div>
    """
  end

  # ── transcript ────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :turn, :map, required: true

  def turn(%{turn: %{kind: :day}} = assigns) do
    ~H"""
    <div id={@id} class="day my-1.5 self-center text-xs text-subtle">{@turn.text}</div>
    """
  end

  def turn(%{turn: %{kind: :agent}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="bubble agent voice-bubble-agent max-w-[82%] self-start rounded-2xl rounded-bl-sm px-3.5 py-2.5 text-[15px] leading-snug text-base-content break-words"
      data-agent-slot={@turn.slot}
      data-partner-greeting={@turn[:greeting?] && "true"}
    >
      <span class="from voice-bubble-from mb-0.5 block text-xs font-bold tracking-wide">
        {@turn.from}
      </span>{@turn.text}
    </div>
    """
  end

  def turn(%{turn: %{kind: :me}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="bubble me max-w-[82%] self-end rounded-2xl rounded-br-sm border border-edge bg-base-100 px-3.5 py-2.5 text-[15px] leading-snug text-base-content break-words"
    >
      {@turn.text}<span class="meta mt-1 block text-xs text-subtle">{@turn.meta}</span>
    </div>
    """
  end

  # ── the turn in flight ────────────────────────────────────────────────

  attr :state, :atom, required: true
  attr :partner, :map, default: nil

  @doc """
  What sits under the transcript while a turn is in flight: your live bubble
  (dashed primary edge and a caret) while listening, the partner's thinking
  dots after release, or "Didn't get an answer." with "Try again".
  """
  def pending_turn(%{state: state} = assigns) when state in [:listening, :toggled] do
    ~H"""
    <div
      id="voice-live"
      class="bubble me live voice-bubble-live max-w-[82%] self-end rounded-2xl rounded-br-sm bg-base-100 px-3.5 py-2.5 text-[15px] leading-snug text-base-content"
      aria-live="polite"
      aria-label="listening"
    >
      <span class="voice-caret" aria-hidden="true"></span>
    </div>
    """
  end

  def pending_turn(%{state: :thinking, partner: %{}} = assigns) do
    ~H"""
    <div
      id="voice-thinking"
      class="bubble agent voice-bubble-agent self-start rounded-2xl rounded-bl-sm px-3.5 py-3 text-subtle"
      data-agent-slot={@partner.slot}
      role="status"
      aria-label={"#{@partner.agent.name} is thinking"}
    >
      <span class="voice-dots flex gap-1" aria-hidden="true"><i></i><i></i><i></i></span>
    </div>
    """
  end

  def pending_turn(%{state: :failed, partner: %{}} = assigns) do
    ~H"""
    <div
      id="voice-failed"
      class="bubble agent voice-bubble-agent max-w-[82%] self-start rounded-2xl rounded-bl-sm px-3.5 py-2.5 text-[15px] leading-snug text-base-content"
      data-agent-slot={@partner.slot}
      role="status"
    >
      <span class="from voice-bubble-from mb-0.5 block text-xs font-bold tracking-wide">
        {@partner.agent.name}
      </span>
      Didn't get an answer.
      <button
        type="button"
        id="voice-retry"
        class="mt-2 block rounded-full border border-edge bg-base-100 px-3 py-1 text-sm font-semibold text-base-content active:bg-base-200"
        phx-click="voice_retry"
      >
        Try again
      </button>
    </div>
    """
  end

  def pending_turn(assigns), do: ~H""

  # ── mic area ──────────────────────────────────────────────────────────

  attr :partner, :map, default: nil
  attr :toast, :string, default: nil
  attr :state, :atom, default: :idle
  attr :typing?, :boolean, default: false
  attr :type_form, :any, default: nil
  attr :user_id, :string, default: nil

  def voice_area(assigns) do
    ~H"""
    <div
      id="voice-area"
      class="voice-area relative flex flex-none flex-col items-center gap-2.5 px-[18px] pt-1.5 pb-3"
      phx-hook="VoiceTab"
      data-state={@state}
      data-live={live?(@state) && "true"}
      data-user-id={@user_id}
      data-partner-id={@partner && @partner.agent.id}
    >
      <div
        :if={@toast}
        id="voice-toast"
        role="status"
        class="absolute bottom-full mb-2 max-w-[calc(100%-2rem)] rounded-xl border border-edge bg-base-100 px-3 py-2 text-center text-sm text-base-content shadow-lg"
      >
        {@toast}
      </div>
      <div
        id="listen-line"
        class={[
          "flex min-h-[18px] flex-wrap items-center justify-center gap-x-2 gap-y-1 text-center text-sm text-subtle",
          live?(@state) && "on"
        ]}
        aria-live="polite"
      >
        <span
          :if={@state not in [:blocked, :unavailable]}
          class={[
            "size-[7px] flex-none rounded-full",
            if(live?(@state), do: "bg-primary", else: "bg-edge")
          ]}
          aria-hidden="true"
        >
        </span>
        <span id="listen-text" class={listen_class(@partner, @state)}>
          {listen_text(@partner, @state)}
        </span>
        <button
          :if={@state == :blocked and not @typing?}
          type="button"
          id="voice-type-instead"
          class="rounded-full border border-edge bg-base-100 px-2.5 py-0.5 text-sm font-semibold text-base-content active:bg-base-200"
          phx-click="voice_type_open"
        >
          Type instead
        </button>
      </div>
      <.form
        :if={@typing? and @type_form}
        for={@type_form}
        id="voice-type-form"
        class="flex w-full max-w-md items-center gap-2"
        phx-submit="voice_type"
      >
        <.input
          field={@type_form[:text]}
          id="voice-type-input"
          type="text"
          placeholder="Type to the partner"
          aria-label="Type instead of talking"
          autocomplete="off"
          class="input input-sm w-full rounded-full placeholder:text-subtle"
        />
        <button
          type="submit"
          id="voice-type-send"
          class="flex-none rounded-full bg-primary px-3 py-1 text-sm font-semibold text-primary-content"
        >
          Send
        </button>
      </.form>
      <div
        id="meter"
        class="voice-meter flex h-[30px] items-center gap-[3px]"
        phx-update="ignore"
        aria-hidden="true"
      >
        <i :for={_ <- 1..14} data-meter-bar></i>
      </div>
      <button
        type="button"
        id="mic"
        class={[
          "voice-mic flex size-24 items-center justify-center rounded-full disabled:opacity-60",
          if(live?(@state),
            do: "on scale-[1.06] bg-primary text-primary-content",
            else: "bg-base-100 text-base-content"
          )
        ]}
        aria-pressed={if live?(@state), do: "true", else: "false"}
        aria-label={mic_aria(@partner)}
        disabled={not talkable?(@partner)}
      >
        <.icon name="hero-microphone" class="size-10" />
      </button>
      <div id="voice-audio" class="hidden" phx-update="ignore"></div>
      <button
        type="button"
        id="pipeline-info"
        class="inline-flex items-center gap-1.5 rounded-full border border-dashed border-edge px-2 py-1 text-xs text-subtle active:bg-base-100"
        title="Same LiveKit room + transcription pipeline as Meet, scoped to a private 1:1 — no meeting is created"
        phx-click="pipeline_info"
      >
        <.icon name="hero-information-circle" class="size-3" />
        uses meeting transcription · not a meeting
      </button>
    </div>
    """
  end

  # ── sheets ────────────────────────────────────────────────────────────

  attr :open, :boolean, default: false
  attr :partners, :list, required: true
  attr :current_id, :string, default: nil
  attr :default_slug, :string, required: true

  attr :variant, :atom,
    default: :sheet,
    values: [:sheet, :popover],
    doc: "`:popover` is a bottom sheet on a phone and a popover under #partner at lg"

  def partner_sheet(assigns) do
    ~H"""
    <.sheet
      id="partner-sheet"
      open={@open}
      on_close="close_sheet"
      handle_close
      swipe_dismiss
      class={sheet_class(@variant)}
      data-variant={@variant}
      data-anchor="start"
      data-return-focus="#partner"
    >
      <:title>Voice with</:title>
      <h2 class="px-2.5 pt-1 pb-2.5 text-base font-semibold text-base-content" aria-hidden="true">
        Voice with
      </h2>
      <div id="partner-list" class="flex flex-col">
        <button
          :for={p <- @partners}
          type="button"
          id={"partner-opt-#{p.agent.id}"}
          class={[
            "opt flex w-full items-center gap-3 rounded-lg px-2.5 py-3 text-left active:bg-base-200",
            row_hover(@variant)
          ]}
          data-current={p.agent.id == @current_id && "true"}
          phx-click="pick_partner"
          phx-value-id={p.agent.id}
        >
          <.avatar name={p.agent.name} slot={p.slot} class="size-9 text-sm" />
          <span class="min-w-0 flex-1">
            <b class="block text-[15px] font-semibold text-base-content">{p.agent.name}</b>
            <small class="block text-xs text-subtle">
              {partner_subtitle(p, @default_slug)}
            </small>
          </span>
          <small :if={p.agent.id == @current_id} class="text-sm text-subtle">current</small>
        </button>
      </div>
    </.sheet>
    """
  end

  attr :open, :boolean, default: false
  attr :spaces, :list, required: true, doc: "the spaces matching the search"
  attr :query, :string, default: ""
  attr :form, :any, required: true
  attr :context, :map, default: nil
  attr :partner_name, :string, default: nil

  attr :variant, :atom,
    default: :sheet,
    values: [:sheet, :popover],
    doc: "`:popover` is a bottom sheet on a phone and a popover under #ctx at lg"

  def context_sheet(assigns) do
    ~H"""
    <.sheet
      id="ctx-sheet"
      open={@open}
      on_close="close_sheet"
      handle_close
      swipe_dismiss
      class={sheet_class(@variant)}
      data-variant={@variant}
      data-anchor="end"
      data-return-focus="#ctx"
    >
      <:title>Talking about</:title>
      <h2 class="px-2.5 pt-1 pb-2.5 text-base font-semibold text-base-content" aria-hidden="true">
        Talking about
      </h2>
      <.form for={@form} id="ctx-search-form" phx-change="ctx_search" phx-submit="ctx_search_submit">
        <.input
          field={@form[:q]}
          id="ctx-search"
          type="search"
          placeholder="Search spaces"
          aria-label="Search contexts"
          autocomplete="off"
          phx-debounce="150"
          class="input input-sm mb-2 w-full rounded-full placeholder:text-subtle"
        />
      </.form>
      <div id="ctx-list" class="flex flex-col">
        <button
          :if={blank?(@query)}
          type="button"
          id="ctx-opt-none"
          class={[
            "opt flex w-full items-center gap-3 rounded-lg px-2.5 py-3 text-left text-[15px] text-base-content active:bg-base-200",
            row_hover(@variant),
            is_nil(@context) && "bg-base-200"
          ]}
          data-selected={is_nil(@context) && "true"}
          phx-click="pick_context"
          phx-value-id=""
        >
          <.icon name="hero-no-symbol" class="size-5 text-subtle" />
          <span>No context</span>
          <small class="ml-auto text-sm text-subtle">
            just a chat with {@partner_name || "nobody"}
          </small>
        </button>
        <%= if @spaces != [] do %>
          <div class="section-label px-2.5 pt-2.5 pb-1 text-xs font-semibold uppercase tracking-widest text-subtle">
            Spaces
          </div>
          <button
            :for={s <- @spaces}
            type="button"
            id={"ctx-opt-#{s.id}"}
            class={[
              "opt flex w-full items-center gap-3 rounded-lg px-2.5 py-3 text-left active:bg-base-200",
              row_hover(@variant),
              @context && @context.id == s.id && "bg-base-200"
            ]}
            data-selected={@context && @context.id == s.id && "true"}
            phx-click="pick_context"
            phx-value-id={s.id}
          >
            <span class="min-w-0 flex-1">
              <b class="block truncate text-[15px] font-semibold text-base-content">{s.name}</b>
              <small :if={s.subtitle} class="block truncate text-xs text-subtle">{s.subtitle}</small>
            </span>
            <span class="kind text-xs uppercase tracking-wider text-subtle">space</span>
          </button>
        <% end %>
        <div
          :if={@spaces == [] and not blank?(@query)}
          id="ctx-empty"
          class="empty p-5 text-center text-sm text-subtle"
        >
          No match.
        </div>
      </div>
    </.sheet>
    """
  end

  # ── copy ──────────────────────────────────────────────────────────────

  @doc "The partner pill's accessible name."
  def partner_aria(nil), do: "Voice partner: none. Tap to choose"
  def partner_aria(%{agent: agent}), do: "Voice partner: #{agent.name}. Tap to change"

  @doc "The context pill's accessible name."
  def context_aria(nil), do: "Context: none. Tap to choose where this transcript posts"
  def context_aria(%{name: name}), do: "Context: #{name}. Tap to change"

  defp thread_pair(nil), do: "you"
  defp thread_pair(%{agent: agent}), do: "#{agent.name} ↔ you"

  defp thread_ctx(nil), do: " · nothing posted anywhere — pick a context above"
  defp thread_ctx(%{name: name}), do: " · #{name}"

  @doc "The mic's accessible name."
  def mic_aria(nil), do: "No voice partner"

  def mic_aria(%{agent: agent}),
    do: "Hold to talk to #{agent.name}. Short tap toggles listening."

  @doc "Whether the mic is enabled for this partner."
  def talkable?(%{reachable?: true}), do: true
  def talkable?(_), do: false

  @doc "Whether the talk state is a live turn (the mic is on)."
  def live?(state), do: state in [:listening, :toggled]

  @blocked_line "Microphone is blocked. Allow it in your browser settings."

  @doc "The listen line's copy for a partner in a talk state."
  def listen_text(nil, _state), do: "No voice partner"
  def listen_text(%{reachable?: false, agent: agent}, _state), do: cant_talk(agent)
  def listen_text(%{agent: agent}, :unavailable), do: cant_talk(agent)
  def listen_text(_partner, :blocked), do: @blocked_line
  def listen_text(_partner, :listening), do: "listening…"
  def listen_text(_partner, :toggled), do: "listening… tap again to stop"
  def listen_text(%{agent: agent}, :thinking), do: "#{agent.name} is thinking…"
  def listen_text(_partner, _state), do: @idle_line

  defp cant_talk(agent), do: "#{agent.name} can't talk right now."

  defp listen_class(%{reachable?: false}, _state), do: "text-error"
  defp listen_class(_partner, state) when state in [:unavailable, :blocked], do: "text-error"
  defp listen_class(_partner, _state), do: nil

  defp partner_subtitle(%{agent: %{slug: slug}}, slug), do: "your default · knows every space"
  defp partner_subtitle(p, _), do: p.description || "agent"

  defp initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_), do: "?"

  defp blank?(q), do: String.trim(q || "") == ""

  # The variant is classes only: the popover's lg geometry is CSS
  # (`.voice-popover` in app.css), and its rows hover only at lg.
  defp sheet_class(:popover), do: "voice-sheet voice-popover"
  defp sheet_class(_sheet), do: "voice-sheet"

  defp row_hover(:popover), do: "lg:hover:bg-base-200"
  defp row_hover(_sheet), do: nil
end
