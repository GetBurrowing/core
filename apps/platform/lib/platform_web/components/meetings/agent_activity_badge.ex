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
          @meta.animate && "animate-pulse"
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
          @meta.animate && "animate-pulse"
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
      <span class="sr-only">{@name} is {@meta.word || "idle"}</span>
    </span>
    """
  end

  @doc """
  The presentation table for one state: `ring`, `text`, `glyph`,
  `word`, `face_dim`, `animate`.

  Public so a caller that renders one of these facts on its OWN node —
  `ParticipantRail` puts the state WORD under the agent's name, on a
  different line from the avatar this module draws — reads the same
  table instead of maintaining a second mapping that can drift from it.
  """
  def activity_meta(state), do: meta(state)

  # One table, so a new state is a row rather than an edit to three
  # separate `cond`s that can disagree with each other.
  #
  # `animate` is false for `:failed` on purpose: a pulse reads as "still
  # going", which is the opposite of what this state says. Only the
  # in-progress states move.
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
  # Thinking is static, Writing moves. That is why `animate` is now
  # false for `:computing` and true only for `:typing` — the pulse is
  # the pen moving, and a static half-disc is a thought in progress.
  # Saru's mock draws "three dots that travel" for Writing; the ring
  # pulse is that motion at 14px, not a new token.
  defp meta(:computing),
    do: %{
      ring: "border-info text-info",
      text: "text-info",
      glyph: "◐",
      word: "Thinking",
      animate: false,
      face_dim: false
    }

  defp meta(:typing),
    do: %{
      ring: "border-info text-info",
      text: "text-info",
      glyph: "✎",
      word: "Writing",
      animate: true,
      face_dim: false
    }

  defp meta(:failed),
    do: %{
      ring: "border-error text-error",
      text: "text-error",
      glyph: "!",
      word: "Couldn't",
      animate: false,
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
      animate: false
    }

  # Every other value, `:listening` included. `:listening` falling
  # through to the idle presentation is the deliberate refusal described
  # in the moduledoc, not an omission: nothing in the system can set it,
  # so it gets no distinct visual and no word of its own. Do not give it
  # a clause here without first giving it a producer.
  defp meta(_), do: meta(:idle)
end
