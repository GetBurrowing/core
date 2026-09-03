defmodule Platform.Meetings.PressCard do
  @moduledoc """
  Opens the instant card when someone presses the push-to-talk key
  (task 01a03f4e, plan v2 stage 3).

  ## Why this exists at all

  The classifier cannot produce a card at press time. It holds each
  chunk in a same-speaker debounce and then makes a provider LLM call
  before anything reaches the queue, so the earliest a classified card
  can appear is well after the speaker has started talking. A
  push-to-talk key that shows nothing until the sentence is finished and
  a model has answered does not feel like a button.

  So the press writes the row itself, immediately, with no text and no
  classification — the card appears the instant the key goes down.

  ## This module renders NOTHING

  Task `01a03f4e-78b1` owns how a candidate card looks and shipped that
  in #872: `PlatformWeb.Meetings.CandidateRail`, `CandidateDisplay` and
  the `CandidateRing` hook. This module inserts a `meeting_candidates`
  row and stops. The board already renders every open candidate for the
  meeting, so the card shows up — to every participant, not only the one
  who pressed — without a line of markup here. Two tasks meet at the
  same rows from opposite ends and only one of them decides
  presentation.

  ## And it opens no path of its own

  The row is written by `Platform.Meetings.IntentQueue.enqueue/2` and
  the `mirror_enqueue` hook that already backs every other card. This
  module composes existing calls; it does not insert into
  `meeting_candidates` directly. That is deliberate: the mirror is where
  threading, reconciliation and the durable-state mapping live, and a
  second writer would have to reimplement all three and then drift from
  them.

  ## Idempotence

  A physical press can fire more than one event (`pointerdown` and
  `keydown` for one press; a held key repeating), and
  `PressWindow.press/3` is idempotent while a window is live — a repeat
  returns the existing window with its original `pressed_at` intact.
  This module turns that into queue-level idempotence by deriving the
  `dedupe_key` from that `pressed_at`: a repeat press computes the same
  key, `IntentQueue.enqueue/2` answers `{:duplicate, existing}`, and no
  second row is written. One press, one card, however many events the
  browser sends.
  """

  require Logger

  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.SpokenTarget

  @doc """
  Open a press window for `identity` in `meeting_id` and put its card on
  the board.

  Options:

    * `:at` — the press instant. Defaults to now; tests pass it
      explicitly.
    * `:speaker` — the pressing participant's DISPLAY name, which is
      what the transcript attributes their speech to. See the note below
      on why the identity is the wrong value for this field.
    * `:room_id` — the LiveKit room, when the caller knows it.

  Returns `{:ok, %{window: window, intent: row, duplicate?: boolean}}`,
  or `{:error, reason}` when the identity is blank or the queue is
  unavailable.

  ## Why `:speaker` is a display name and not the identity

  The press knows the participant IDENTITY (`"user:<uuid>"`) — that is
  what the window is keyed on and what stage 2 matches segments against.
  But the `speaker` COLUMN on a candidate is transcript attribution:
  every other writer fills it from `segment_speaker/2`, which prefers
  the transcriber's `speaker_name`. Putting an identity there would make
  this card's speaker incomparable with every other card's, and
  `ThreadResolver`'s same-speaker gate would never match it — which is
  precisely how one press ends up with two cards instead of one.

  The caller therefore supplies the display name. Stage 5, which owns
  the button, is the layer that knows it.
  """
  @spec open(binary(), String.t(), keyword()) ::
          {:ok, %{window: map(), intent: map(), duplicate?: boolean()}}
          | {:error, term()}
  def open(meeting_id, identity, opts \\ []) when is_binary(meeting_id) do
    at = Keyword.get(opts, :at) || DateTime.utc_now()

    with {:ok, window} <- PressWindow.press(meeting_id, identity, at) do
      {agent_id, agent_slug} = default_target(meeting_id)

      attrs = %{
        room_id: Keyword.get(opts, :room_id),
        speaker: Keyword.get(opts, :speaker),
        source: :push_to_talk,
        dedupe_key: dedupe_key(window),
        # Who will hear this, known at press time (task 01a03f4e stage
        # 4). Nothing has been said yet, so nobody has been named and
        # the card takes the configured default — which is what makes
        # the card say where it is going from the instant the key goes
        # down rather than after the model answers. If the speaker then
        # names an agent, the classified intent reconciles over this.
        target_agent_id: agent_id,
        target_agent_slug: agent_slug,
        # No text and no classification: nothing has been said yet. The
        # card is deliberately empty — that emptiness IS the state the
        # board renders while the speaker is still talking.
        chunk_excerpt: nil,
        classified_intent: nil
      }

      case IntentQueue.enqueue(meeting_id, attrs) do
        {:ok, row} ->
          # The window is the join between this press and the card it
          # just opened. Without it the speaker's own utterance, when it
          # arrives, opens a SECOND card — `ThreadResolver` scores on
          # topic overlap and this card has no topic yet.
          {:ok, window} = PressWindow.attach_card(meeting_id, identity, row.id)
          {:ok, %{window: window, intent: row, duplicate?: false}}

        {:duplicate, row} ->
          {:ok, %{window: window, intent: row, duplicate?: true}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # No text yet, so `resolve/1` can only take the default branch.
  # A missing assignment is LOUD and attaches nobody: guessing an agent
  # here would put the wrong name on the card at the most visible
  # possible moment.
  defp default_target(meeting_id) do
    case SpokenTarget.resolve(nil) do
      {:ok, agent_id, agent_slug, _via} ->
        {agent_id, agent_slug}

      {:error, :no_default_target} ->
        Logger.warning(
          "[PressCard] press card has no target: no agent is assigned to responsibility " <>
            "#{SpokenTarget.default_responsibility_key()} meeting_id=#{meeting_id}"
        )

        :telemetry.execute(
          [:platform, :meetings, :push_to_talk_unrouted],
          %{count: 1},
          %{meeting_id: meeting_id, responsibility_key: SpokenTarget.default_responsibility_key()}
        )

        {nil, nil}
    end
  end

  @doc """
  The queue dedupe key for a press window.

  Derived from the window's `pressed_at`, which a repeat press does not
  move — so every event belonging to one physical press computes the
  same key and only the first one writes a row.
  """
  @spec dedupe_key(map()) :: String.t()
  def dedupe_key(%{identity: identity, pressed_at: %DateTime{} = pressed_at}) do
    "push_to_talk:#{identity}:#{DateTime.to_iso8601(pressed_at)}"
  end
end
