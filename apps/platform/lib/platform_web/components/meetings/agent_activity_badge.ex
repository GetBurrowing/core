defmodule PlatformWeb.Components.Meetings.AgentActivityBadge do
  @moduledoc """
  What an agent is doing right now, said three ways at once.

  ## Why a component and not a class helper

  It replaces `PlatformWeb.MeetingLive.agent_status_dot_class/3`, which
  rendered `activity != :idle -> "bg-success"` — one green dot for
  every non-idle state. `Platform.Meetings.AgentActivity` resolves
  `:typing`, `:computing` and `:failed` as distinct values and the
  screen collapsed all three back into the same three pixels, so the
  data was there and the answer was thrown away at the last step.

  ## Ring, glyph, word — never colour alone

  Each state carries a **ring colour**, a **glyph** and a **word**.
  Colour alone is a handful of pixels at avatar size, is invisible to a
  colourblind viewer, and collides with the candidate cards' own colour
  language, where colour means *how far along* rather than *what this
  is*. Any one of the three can be missed and the state still reads.

  The word is also the accessible name: it is rendered as text, not as
  a `title` attribute, because a tooltip that only appears on hover is
  not available to a keyboard or screen-reader user and is not visible
  in a screenshot.

  ## The states this renders, and the ones it refuses to

  Only states with a producer are drawn:

    * `:computing` — "Thinking", from a live `IntentQueue` row.
    * `:typing` — "Writing", from the `agent_typing` broadcast.
    * `:heard` — a two-second receipt for one delivered transcript
      segment (`Meetings.deliver_transcript_segment/2`).
    * `:speaking` — core is playing this agent's audio right now
      (`Meetings.say/4` via `SpeakingWindow`).
    * `:delayed` — still working, not progressing, always with the
      specific cause that produced it (`AgentActivity.apply_delays/2`).
    * `:thinking` / `:composing` — the two states a federated runtime
      declares about itself. Drawn as exact aliases of `:computing` and
      `:typing`; see the table below for why that is the canvas read
      literally rather than a shortcut.
    * `:failed` — "Couldn't", from a real failure terminal
      (`IntentQueue.failure_statuses/0`).
    * `:idle` — the absence of the others.

  `:listening` is declared in `AgentActivity` and has **no producer**;
  its own typedoc says so. It is deliberately NOT given a visual here.
  Drawing it would put a label on screen that nothing in the system can
  ever set — a caption that is always false, which is precisely the
  defect this pass exists to remove. "Speaking", "Taking notes" and
  "Adding a card" are absent for the same reason: they need something
  to emit them first, and drawing them is the easy half.

  Since then Saru has ruled `Listening` OFF the rail outright (canvas
  01a05b11-54ff card 6, 2026-09-02): every agent in a call is always
  listening, so a badge that is on for everyone all the time takes a
  row from a state that turns over. It is removed, not deferred, and
  the missing producer is no longer the reason. The atom stays
  declared in `AgentActivity` for the older `agent_tile` surface; if
  the word ever returns it returns as a different word answering a
  different question, on its own ticket.

  ## `:failed` is the one that earns its place

  An avatar left on "Thinking" for three minutes converts a failure
  into a wait for something that is never coming. `:failed` caps that,
  and it outranks the working signals so it cannot be painted over.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  @doc """
  The badge for one resolved activity state.

  `:idle` renders a muted dot and no word: an idle agent is the common
  case and labelling every one of them "Idle" would make the states
  that matter harder to find, not easier. That holds for the accessible
  label too, which is why the sr-only sentence below reads the word off
  the GLYPH's presence rather than off `word` — `meta(:idle)` now
  carries "Idle" for `agent_activity_avatar/1`, which does draw it, and
  this surface must stay exactly as it was.
  """
  attr(:state, :atom, required: true, doc: "a Platform.Meetings.AgentActivity state")
  attr(:name, :string, default: nil, doc: "agent name, used for the accessible label")
  attr(:class, :string, default: nil)

  def agent_activity_badge(assigns) do
    assigns = assign(assigns, :meta, meta(assigns.state))

    ~H"""
    <span
      class={["inline-flex items-center gap-1.5", @class]}
      data-role="agent-activity-badge"
      data-activity-state={@state}
    >
      <span
        class={[
          "inline-flex size-4 flex-shrink-0 items-center justify-center rounded-full border-2 text-[9px] leading-none",
          @meta.ring,
          motion_class(@meta.motion)
        ]}
        aria-hidden="true"
        data-role="agent-activity-ring"
      >
        {@meta.glyph}
      </span>
      <span
        :if={@meta.glyph != ""}
        class={["text-[11px] font-medium", @meta.text]}
        data-role="agent-activity-word"
      >
        {@meta.word}
      </span>
      <span class="sr-only">
        {[@name, (@meta.glyph != "" && @meta.word) || "idle"]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" is ")}
      </span>
    </span>
    """
  end

  @doc """
  The avatar with the state wrapped AROUND it: a ring on the avatar's
  own edge and a glyph pinned to its bottom-right corner.

  The separate `agent_activity_badge/1` puts the ring on a standalone
  empty circle somewhere else in the row, which asks a reader to
  associate two things that are not touching. Saru's canvas (task
  01a05b14) draws the state on the face itself, so the identity and
  what it is doing are one object. This is that construction; the
  state WORD is a separate node the caller renders under the name.

  `:idle` is drawn here, unlike in `agent_activity_badge/1`: a muted
  ring, no glyph, and a dimmed face. It is a resolved state with a real
  producer — `AgentActivity.for_agent/2` computes it from live data —
  so drawing it states a fact. `:listening` still falls through to the
  wordless clause for the reason in the moduledoc: nothing in the
  system can set it, so drawing it would state a falsehood.
  """
  attr(:state, :atom, required: true, doc: "a Platform.Meetings.AgentActivity state")
  attr(:name, :string, required: true)
  attr(:avatar_url, :string, default: nil)
  attr(:class, :any, default: nil)

  attr(:label, :string,
    default: nil,
    doc: """
    Overrides the `sr-only` sentence (task 01a07400 stage 3).

    Two facts this component cannot see make the default sentence wrong on
    the rail, and both are the caller's to know:

      * **The delay reason.** Saru's direction (canvas 01a07402-99e3) rules
        that the sr-only line must carry it — "Octavius is delayed, waiting
        on GitHub", not just "delayed". The reason is gathered per agent by
        the render loop; nothing here has it.
      * **`:heard` does not swap the word.** A heard flash paints THIS
        component's ring while the word under the name keeps saying what the
        agent is actually doing. The spoken sentence must follow the word,
        not the ring, or a screen-reader user hears a two-second receipt
        announced as the agent's state.

    `nil` keeps the sentence this component has always composed, so every
    caller that does not know better is unchanged.
    """
  )

  def agent_activity_avatar(assigns) do
    assigns = assign(assigns, :meta, meta(assigns.state))

    ~H"""
    <span
      class={["relative block size-7 flex-shrink-0", @class]}
      data-role="agent-activity-avatar"
      data-activity-state={@state}
    >
      <.agent_avatar
        name={@name}
        avatar_url={@avatar_url}
        size="xs"
        class={[
          "absolute inset-[3px] flex items-center justify-center",
          @meta.face_dim && "opacity-45"
        ]}
        data-role="agent-activity-face"
      />
      <span
        class={[
          "pointer-events-none absolute inset-0 rounded-full border-2",
          @meta.ring,
          motion_class(@meta.motion)
        ]}
        aria-hidden="true"
        data-role="agent-activity-ring"
      >
      </span>
      <span
        :if={@meta.glyph != ""}
        class={[
          "absolute -bottom-[3px] -right-[3px] inline-flex size-3.5 items-center justify-center",
          "rounded-full border bg-base-100 text-[9px] leading-none",
          @meta.ring
        ]}
        aria-hidden="true"
        data-role="agent-activity-glyph"
      >
        {@meta.glyph}
      </span>
      <span class="sr-only">{@label || "#{@name} is #{@meta.word || "idle"}"}</span>
    </span>
    """
  end

  @doc """
  The presentation table for one state: `ring`, `text`, `glyph`,
  `word`, `face_dim`, `motion`.

  Public so a caller that renders one of these facts on its OWN node —
  `ParticipantRail` puts the state WORD under the agent's name, on a
  different line from the avatar this module draws — reads the same
  table instead of maintaining a second mapping that can drift from it.
  """
  def activity_meta(state), do: meta(state)

  # One table, so a new state is a row rather than an edit to three
  # separate `cond`s that can disagree with each other.
  #
  # ## The two axes (Saru, design direction canvas 01a07402-99e3)
  #
  # **Colour answers "does this need me". Motion answers "is it
  # progressing".** Every row below is an application of those two
  # sentences, and the `warning` slot is deliberately unspent by all of
  # them: on this screen `warning` means exactly one thing, a human is
  # being asked for something, and that was settled after five stages
  # reported it open.
  #
  # `motion` is an atom rather than the boolean `animate` it replaced,
  # because there are now two DIFFERENT motions and the difference is
  # load-bearing — `:pulse` is opacity (the pen moving), `:amplitude` is a
  # ring breathing outward (audio leaving the room). See `motion_class/1`.
  #
  # `:computing` sits on `info`, not `secondary`. Saru's
  # design-direction canvas (task 01a05b14) assigns `info` to
  # "Thinking" and to the `→ role` assignment segment; `secondary`
  # is not in its slot list at all. Changed here so the rail and the
  # tile cannot disagree about what Thinking looks like.
  #
  # `:typing` ("Writing") is on `info` too, DECIDED (Saru, canvas
  # 01a05b11-54ff card 6, 2026-09-02; applied in task 01a05b14 stage 5).
  # It used to sit on `warning`, the same slot as the invite honesty
  # banner, and was reported open by five stages. The ruling: colour
  # answers "does this need me" and both working states answer that
  # identically, so they share the slot; `warning` on this screen now
  # means exactly one thing, a human is being asked for something. The
  # label answers "what is happening" and MOTION separates the two:
  # Thinking is static, Writing moves. That is why `motion` is `:none`
  # for `:computing` and `:pulse` only for `:typing` — the pulse is
  # the pen moving, and a static half-disc is a thought in progress.
  # Saru's mock draws "three dots that travel" for Writing; the ring
  # pulse is that motion at 14px, not a new token.
  defp meta(:computing),
    do: %{
      ring: "border-info text-info",
      text: "text-info",
      glyph: "◐",
      word: "Thinking",
      motion: :none,
      face_dim: false
    }

  defp meta(:typing),
    do: %{
      ring: "border-info text-info",
      text: "text-info",
      glyph: "✎",
      word: "Writing",
      motion: :pulse,
      face_dim: false
    }

  # ── The two agent-DECLARED states (task 01a07400 stage 1) ────────────────
  #
  # `:thinking` and `:composing` are the states a federated runtime pushes
  # about itself; every other row here is something core observed. They are
  # deliberately drawn as EXACT ALIASES of `:computing` and `:typing`.
  #
  # That is Saru's direction read literally rather than a shortcut. The
  # canvas's own wire names its working rows `thinking (◐) static` and
  # `composing (✎) pulses — the pen moving`, and assigns them the words
  # "Thinking" and "Writing" — which is precisely what `:computing` and
  # `:typing` already render. The canvas is describing ONE appearance per
  # message, not one per producer.
  #
  # And the reader cannot act on the difference. "Core dispatched this
  # work" versus "the agent says it is working" is a fact about
  # provenance; the human watching the rail is deciding whether to wait,
  # and the answer is the same either way. Splitting them would spend two
  # rows of a seven-row vocabulary on a distinction nobody can use.
  #
  # What makes this an alias rather than a duplicate: the atoms stay
  # distinguishable in `data-activity-state`, so a test, a screenshot diff
  # and the DOM can all still tell which producer spoke.
  #
  # These rows are NOT optional decoration. Once the rail resolves through
  # `AgentActivity.resolve_at/3` (stage 3 wires it, and must, for
  # `:speaking`), a pushed state reaches this table for the first time —
  # and without a clause it falls through to `meta(:idle)`. An agent that
  # has just declared it is thinking would render as Idle with a dimmed
  # face: a caption that is not merely unhelpful but false, which is the
  # exact defect class this whole module exists to remove.
  defp meta(:thinking), do: meta(:computing)

  defp meta(:composing), do: meta(:typing)

  # `:heard` — a per-utterance receipt, not a resting badge (task
  # `01a06e07` stage 2 gave it a producer and a decay in `resolve_at/2`;
  # this row is what makes it visible — see `Platform.Meetings.AgentActivity`'s
  # moduledoc for why it turns over rather than latching like `:listening`
  # would have). Same `info` slot as Thinking/Writing: the agent is doing
  # something FOR you, not asking anything OF you.
  #
  # The glyph is `○` — an OPEN circle, changed from `✓` in task 01a07400
  # stage 3 to obey the canvas wire (`heard (○) ring flashes once, word
  # unchanged`). A check mark reads as "done", which is a claim about the
  # agent's work; this state claims only that a segment reached its
  # runtime. It also has to stay distinguishable from `:speaking`'s FILLED
  # `●` at 9px, and open-versus-filled is the one contrast that survives
  # that size.
  #
  # `motion: :pulse` reads as "one ring flash" in practice, because the
  # stamp itself only lives `AgentActivity.heard_decay_seconds/0` (2s)
  # before `resolve_at/2` lets it fall back to whatever the agent's other
  # signals say.
  #
  # NOTE the division of labour with `ParticipantRail`: this table still
  # carries the word "Heard" because `agent_activity_badge/1` — the
  # `agent_tile` surface — renders one state on one node and has no
  # underlying state to fall back to. The RAIL is where the canvas's "word
  # unchanged" ruling is implemented, by resolving the word from a
  # heard-free reading. See `ParticipantRail`'s moduledoc.
  defp meta(:heard),
    do: %{
      ring: "border-info text-info",
      text: "text-info",
      glyph: "○",
      word: "Heard",
      motion: :pulse,
      face_dim: false
    }

  # `:speaking` — core is playing this agent's audio right now (task
  # 01a07400 stage 2 produces it; this row draws it).
  #
  # **`success`, and that is obedience rather than a choice.** The ratified
  # slot map already assigns success to LIVE AUDIO; the canvas says so in
  # as many words. It is the one working state that is not on `info`,
  # because it is the one that answers "does this need me" differently:
  # audio is arriving now and the human's decision is whether to start
  # talking over it.
  #
  # **`:amplitude`, explicitly not a pulse.** The canvas reserves the pulse
  # for Writing ("the pen moving") and rules speaking as "amplitude, not a
  # pulse". `motion_class/1` maps it to a ring that breathes OUTWARD — the
  # same idiom `.meeting-tile-speaking` already uses for a speaking human
  # in this app, so this is the room's existing motion vocabulary applied
  # to a 28px avatar rather than a new one invented for it.
  #
  # The glyph is a FILLED `●` against `:heard`'s open `○`, which is what
  # carries the two apart when motion is off — see `motion_class/1`.
  defp meta(:speaking),
    do: %{
      ring: "border-success text-success",
      text: "text-success",
      glyph: "●",
      word: "Speaking",
      motion: :amplitude,
      face_dim: false
    }

  # `:delayed` — still working, not progressing (task 01a07400 stage 2
  # produces it; this row draws it). It is the ONLY state that splits the
  # two colour slots, and the split is the whole idea:
  #
  #   * the WORD keeps `info`, because the agent is still working and
  #     still needs nothing from you;
  #   * the RING drains to the neutral value `:idle` uses, because the
  #     ring is the liveness channel and liveness is what has stopped.
  #
  # **`warning` is refused here, deliberately.** Amber on this screen means
  # a human is being asked for something — settled after five stages
  # reported it open — and a blocked agent is asking nothing of anyone.
  # Spending `warning` here would undo the one hard-won rule on the
  # surface. `motion: :none` for the same reason the canvas gives: "a
  # spinner says progressing; the state means not progressing", so a
  # spinner would assert the opposite of the truth.
  #
  # **The glyph is a judgement call and is recorded as one.** The canvas
  # specifies the drained ring and the stopped motion but names no glyph
  # character for this state. Leaving it empty was rejected twice over:
  # `agent_activity_badge/1` gates the WORD on a non-empty glyph, so an
  # empty one would silently delete "Delayed" from the tile surface; and
  # under `prefers-reduced-motion` — where this app kills every animation
  # globally, see `assets/css/app.css` — the stopped motion is not
  # perceivable at all, leaving nothing but colour to separate a delayed
  # agent from an idle one. `‖` is chosen as the pause mark: it is the
  # stopped half of the play/pause pair `:speaking`'s `●` opens, and it is
  # the only glyph in this table with a vertical silhouette, which is what
  # keeps it legible at 9px beside `◐ ✎ ○ ● !`.
  defp meta(:delayed),
    do: %{
      ring: "border-base-content/25 text-base-content/50",
      text: "text-info",
      glyph: "‖",
      word: "Delayed",
      motion: :none,
      face_dim: false
    }

  defp meta(:failed),
    do: %{
      ring: "border-error text-error",
      text: "text-error",
      glyph: "!",
      word: "Couldn't",
      motion: :none,
      face_dim: false
    }

  # `:idle` is a RESOLVED state, not an absence of information:
  # `AgentActivity.for_agent/2` computes it from live data, so a muted
  # ring and the word "Idle" state a fact. `agent_activity_avatar/1`
  # draws it. `agent_activity_badge/1` still stays quiet for it — that
  # surface is a tile corner where every agent would otherwise carry a
  # caption — which is why the word there is gated on the GLYPH rather
  # than on the word being present.
  defp meta(:idle),
    do: %{
      ring: "border-base-content/25 text-transparent",
      text: "text-base-content/50",
      glyph: "",
      word: "Idle",
      face_dim: true,
      motion: :none
    }

  # Every other value, `:listening` included. `:listening` falling
  # through to the idle presentation is the deliberate refusal described
  # in the moduledoc, not an omission: nothing in the system can set it,
  # so it gets no distinct visual and no word of its own. Do not give it
  # a clause here without first giving it a producer.
  #
  # Reaffirmed by Saru in canvas 01a07402-99e3, which WITHDREW an earlier
  # revision's claim that this fallthrough "should not survive": "Do not
  # add a `meta(:listening)` clause as part of this work." The reasoning
  # it lands on is the rule the rest of this table now follows — a state
  # earns its place by TURNING OVER, not by being true.
  defp meta(_), do: meta(:idle)

  # The class that carries `motion`.
  #
  # Two motions, because the canvas rules two and separating them is the
  # point of the axis:
  #
  #   * `:pulse` — `animate-pulse`, opacity in and out. Writing's "pen
  #     moving", and `:heard`'s single flash.
  #   * `:amplitude` — a success-tinted halo that breathes outward from the
  #     ring, defined in `assets/css/app.css`. Audio leaving the room reads
  #     as spread, not as fade, and this is the same shape
  #     `.meeting-tile-speaking` already gives a speaking human.
  #
  # **Neither survives `prefers-reduced-motion`, by design and globally.**
  # `app.css` carries a universal reduce rule that flattens every animation
  # in the app to 0.01ms and one iteration, so this function's output is
  # inert for a reader who asked for less motion. That is exactly why every
  # row above also carries a distinct GLYPH: the glyph is the channel that
  # still works when this one is switched off, and `:speaking` (`●`) versus
  # `:delayed` (`‖`) — the pair the motion axis would otherwise be alone in
  # separating — is the case that proves it.
  defp motion_class(:pulse), do: "animate-pulse"
  defp motion_class(:amplitude), do: "agent-activity-ring-speaking"
  defp motion_class(_motion), do: nil
end
