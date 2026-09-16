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
  the `CandidateClock` hook. This module inserts a `meeting_candidates`
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

  alias Platform.Agents.Agent
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.SpokenTarget
  alias Platform.Repo

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

    * `:target_agent_id` — the agent the human PRESSED (per-agent
      hold-to-talk). When it names an active agent, that agent is the
      card's target from the instant the key goes down and stays so
      through classification (the id is recorded on the press window so
      the classifier honours it rather than re-resolving from the
      words). When absent — or naming no active agent — the card takes
      the configured default via `SpokenTarget`, the pre-per-agent
      behaviour. The id is validated against the roster here so a
      crafted `phx-value-` cannot byline a card to a stranger.

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
      {agent_id, agent_slug} =
        case pressed_agent(opts) do
          {:ok, id, slug} ->
            # An EXPLICIT per-agent press. Record it on the window too, so
            # it survives to classification: `Candidates.reconcile/2`
            # overwrites this card's target with whatever the classifier
            # resolved, and the classifier reads the WINDOW (not this row)
            # for a push-to-talk target. The window was just pressed, so
            # the only non-`:ok` here would be a blank identity — which
            # `press/3` already refused, so the `with` never reaches it.
            _ = PressWindow.set_target(meeting_id, identity, id, slug)
            {id, slug}

          :none ->
            # An untargeted press: byline the card to the configured
            # default, but leave the window's target BLANK so the
            # classifier resolves it from the words — the pre-per-agent
            # behaviour, and what the spoken-name path still depends on.
            default_target(meeting_id)
        end

      attrs = %{
        room_id: Keyword.get(opts, :room_id),
        speaker: Keyword.get(opts, :speaker),
        source: :push_to_talk,
        dedupe_key: dedupe_key(window),
        # Who will hear this, known at press time. With per-agent
        # hold-to-talk this is the agent the human PRESSED; without an
        # explicit press it is the configured default. Either way the
        # card says where it is going from the instant the key goes down,
        # rather than after the model answers.
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

  @telemetry_closed_empty [:platform, :meetings, :press_card_closed_empty]

  @doc """
  Close the card an EMPTY press opened (task 01a06638, folds in 01a06668).

  Called by `PressWindow` once a released window's grace has elapsed
  with nothing claimed. Closes the candidate row for `intent_id` with
  disposition `:timed_out` and reason `:unclassified`, on the record and
  through `Candidates.close/2` so the rail narrates it — the same close
  path the sweeper's reaper uses. Operator-visible only (a log line and
  telemetry); no user-facing notice.

  Returns `{:ok, closed}` when a row was closed, or `:noop` when there
  is no row, it is already closed, or it HAS been classified — a
  classified card is not empty, whatever the window's claim count says,
  and this must never close over a real answer. Never raises: a Repo
  failure degrades to a warning, exactly like
  `IntentClassifier.close_skeleton/4`.
  """
  @spec close_silent(binary()) :: {:ok, MeetingCandidate.t()} | :noop
  def close_silent(intent_id) when is_binary(intent_id) do
    case Candidates.get_by_intent_id(intent_id) do
      %MeetingCandidate{state: state, classified_intent: nil} = candidate
      when state != :closed ->
        with {:ok, _} <- Candidates.record_disposition(candidate, :timed_out),
             {:ok, closed} <-
               Candidates.close(candidate, {:unclassified, "nothing was heard during the press"}) do
          Logger.info(
            "[PressCard] empty press closed intent_id=#{intent_id} " <>
              "meeting_id=#{closed.meeting_id} candidate_id=#{closed.id}"
          )

          :telemetry.execute(
            @telemetry_closed_empty,
            %{count: 1},
            %{meeting_id: closed.meeting_id, candidate_id: closed.id}
          )

          {:ok, closed}
        else
          {:error, reason} ->
            log_close_failure(intent_id, inspect(reason))
            :noop
        end

      _ ->
        :noop
    end
  rescue
    error ->
      log_close_failure(intent_id, Exception.message(error))
      :noop
  catch
    :exit, reason ->
      log_close_failure(intent_id, inspect(reason))
      :noop
  end

  def close_silent(_), do: :noop

  @doc "The telemetry event emitted once per empty press whose card was closed."
  @spec closed_empty_telemetry_event() :: [atom()]
  def closed_empty_telemetry_event, do: @telemetry_closed_empty

  defp log_close_failure(intent_id, detail) do
    Logger.warning("[PressCard] empty-press close failed intent_id=#{intent_id} error=#{detail}")
  end

  # The agent the human EXPLICITLY pressed, or `:none` when no agent was
  # pressed or the pressed id names no active agent (a crafted
  # `phx-value-` or a departed agent). `:none` is what routes a press to
  # the default byline and the words-based resolution, exactly like the
  # pre-per-agent single button.
  defp pressed_agent(opts) do
    case Keyword.get(opts, :target_agent_id) do
      id when is_binary(id) and id != "" ->
        case resolve_pressed_agent(id) do
          {:ok, _agent_id, _slug} = ok -> ok
          :error -> :none
        end

      _ ->
        :none
    end
  end

  # The roster is read every call, like `SpokenTarget` — a card must
  # never be bylined to an agent that is not an active participant.
  #
  # `Repo.get/2` casts `agent_id` through `Agent`'s strict UUIDv7 primary
  # key and RAISES `Ecto.Query.CastError` on a malformed id rather than
  # returning nil. This id arrives on the `push_to_talk_press` payload —
  # a user-controlled phx-value / channel message — so a non-UUID id
  # would crash the press instead of falling back. `Platform.UUID.valid?/1`
  # (the strict 36-char check, not a bare `Ecto.UUID.cast/1`) folds a
  # malformed id into `:error`, exactly like an absent one, so both take
  # the default target. See the `:platform_uuid_guard` / `get(Agent)`
  # entries for this file in `repo_lookup_boundary_test.exs`.
  defp resolve_pressed_agent(agent_id) do
    if Platform.UUID.valid?(agent_id) do
      case Repo.get(Agent, agent_id) do
        %Agent{status: "active"} = agent -> {:ok, agent.id, agent.slug}
        _ -> :error
      end
    else
      :error
    end
  rescue
    # Belt and braces: an off-sandbox lookup must not take down the press
    # path either; degrade to the default target, the same posture the
    # classifier takes when its own resolution raises.
    _ -> :error
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
