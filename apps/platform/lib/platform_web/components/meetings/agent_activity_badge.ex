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

  ## `:failed` is the one that earns its place

  An avatar left on "Thinking" for three minutes converts a failure
  into a wait for something that is never coming. `:failed` caps that,
  and it outranks the working signals so it cannot be painted over.
  """

  use Phoenix.Component

  @doc """
  The badge for one resolved activity state.

  `:idle` renders a muted dot and no word: an idle agent is the common
  case and labelling every one of them "Idle" would make the states
  that matter harder to find, not easier.
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
        :if={@meta.word}
        class={["text-[11px] font-medium", @meta.text]}
        data-role="agent-activity-word"
      >
        {@meta.word}
      </span>
      <span class="sr-only">
        {[@name, @meta.word || "idle"] |> Enum.reject(&is_nil/1) |> Enum.join(" is ")}
      </span>
    </span>
    """
  end

  # One table, so a new state is a row rather than an edit to three
  # separate `cond`s that can disagree with each other.
  #
  # `animate` is false for `:failed` on purpose: a pulse reads as "still
  # going", which is the opposite of what this state says. Only the
  # in-progress states move.
  defp meta(:computing),
    do: %{
      ring: "border-secondary text-secondary",
      text: "text-secondary",
      glyph: "◐",
      word: "Thinking",
      animate: true
    }

  defp meta(:typing),
    do: %{
      ring: "border-warning text-warning",
      text: "text-warning",
      glyph: "✎",
      word: "Writing",
      animate: true
    }

  defp meta(:failed),
    do: %{
      ring: "border-error text-error",
      text: "text-error",
      glyph: "!",
      word: "Couldn't",
      animate: false
    }

  # Every other value, `:idle` and `:listening` included. `:listening`
  # falling through to idle is the deliberate refusal described in the
  # moduledoc, not an omission.
  defp meta(_),
    do: %{
      ring: "border-base-content/25 text-transparent",
      text: "text-base-content/50",
      glyph: "",
      word: nil,
      animate: false
    }
end
