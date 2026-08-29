defmodule Platform.Meetings.Candidates do
  @moduledoc """
  Context for `meeting_candidates` — the durable candidate-lifecycle
  store (task 01a03fb8 stage 2).

  One row per thing a meeting produced that might become work, and this
  module is the only sanctioned way that row's arc gets written. The arc
  is `:heard -> :thinking -> :shaping -> :acting -> :closed`, and it is
  forward-only: `advance/3` refuses a transition to a state at or before
  the current one rather than silently rewriting history. The single
  exception is `:closed`, which is reachable from anywhere — a card can
  be retracted while it is still merely `:heard`.

  ## `:thinking` has no queue-status counterpart

  Eight of the nine `Platform.Meetings.IntentQueue.Server` statuses map
  onto this lifecycle (see `queue_status_to_state/1`). `:thinking` maps
  from none of them, because classification is synchronous today — a
  chunk is in the model and back out before any queue row exists. The
  state is here so the stage-3 board has something to render during that
  window, and it is written by `advance/3` from the classifier path in
  stage 3. It is deliberately not dead: it is a state the queue simply
  is not the writer of.

  ## Disposition is orthogonal to state

  `record_disposition/3` is its own function, and that is the whole
  point. An accepted candidate and a rejected one BOTH end `:closed`.
  Collapsing the two axes — reading "closed" as "rejected" — is exactly
  the bug that made the existing correction corpus 100% negatives, so
  the measurement axis (`:accepted` / `:rejected` / `:timed_out`) is
  recorded separately from the lifecycle axis and neither derives the
  other.

  ## Close is ONE function

  Retraction, duplicate-detection, veto and dismissal are four CALLERS
  of `close/2`, not four functions. There is exactly one `Repo.update`
  in this module that sets `closed_reason`.

  Three of the four exist as of task 01a03fba: dismissal and
  duplicate-detection call in from
  `Platform.Meetings.IntentClassifier`'s `close_skeleton/4`, and
  retraction calls in from `retract/4` below when a later utterance
  takes an open card back. Veto still has no producer anywhere in
  `lib/`. The board renders all four
  uniformly *because* they took the same write path; a `retract/1`
  convenience wrapper would be the first step in letting them diverge.
  `advance/3` targeting `:closed` therefore delegates here rather than
  writing its own closing update.

  `close/2` is idempotent: closing an already-closed candidate returns
  it unchanged. The first close is the true one — a duplicate cancel
  arriving after a veto must not relabel the veto.

  ## `org_id` is derived, not passed

  Derivation delegates to `Platform.Meetings.IntentCorrections.org_id_for_meeting/1`
  — the `meetings.project_id -> projects.org_id` join already lives
  there and is deliberately not copied. Derivation is non-fatal for the
  same reason it is there: an unresolvable meeting still gets its row,
  with a nil `org_id`, and is simply invisible to the org-scoped
  measurement query until backfilled.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.ThreadResolver
  alias Platform.Repo

  # Lifecycle order. Position in this list — not the atom — is what
  # `advance/3` compares, so inserting a state changes the ordering
  # everywhere at once.
  @order [:heard, :thinking, :shaping, :acting, :closed]

  # The states a new utterance could still attach to: everything before
  # `:acting`. Derived from `@order` by taking the prefix rather than
  # written out again, so inserting a state into the lifecycle lands on
  # the correct side of the open/closed line automatically. `:acting`
  # is excluded because a runtime is already working the candidate —
  # accreting more of the transcript onto it would change the brief
  # under a run that has already read it.
  @open_states Enum.take_while(@order, &(&1 != :acting))

  # First entry into a state stamps its column. `:thinking` and
  # `:closed` are absent on purpose: thinking is a transient the board
  # renders but nobody measures, and closing stamps `closed_at` through
  # `close/2`.
  @state_stamps %{heard: :heard_at, shaping: :dispatched_at, acting: :acted_at}

  # The nine `Platform.Meetings.IntentQueue.Server` statuses, read from
  # its `@statuses` attribute and status table rather than remembered.
  @queue_state_map %{
    queued: :heard,
    dispatched: :shaping,
    acked: :acting,
    completed: :closed,
    cancelled: :closed,
    cancelled_late: :closed,
    timed_out: :closed,
    dispatch_failed: :closed,
    no_ack_spawn_failed: :closed
  }

  @queue_disposition_map %{
    completed: :accepted,
    cancelled: :rejected,
    cancelled_late: :rejected,
    timed_out: :timed_out,
    dispatch_failed: :rejected,
    no_ack_spawn_failed: :rejected
  }

  @queue_closed_reason_map %{
    completed: :done,
    cancelled: :retracted,
    cancelled_late: :retracted,
    timed_out: :dismissed,
    dispatch_failed: :dismissed,
    no_ack_spawn_failed: :dismissed
  }

  @doc "The lifecycle states in forward order."
  @spec order() :: [atom()]
  def order, do: @order

  # ── create ────────────────────────────────────────────────────────────────

  @doc """
  Insert a candidate row.

  When `attrs` carries no `:org_id` (or carries an explicit `nil` —
  that is how "I don't know" arrives), it is derived from `:meeting_id`.
  Returns `{:ok, candidate}` or `{:error, changeset}`.
  """
  @spec create(map()) :: {:ok, MeetingCandidate.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %MeetingCandidate{}
    |> MeetingCandidate.changeset(attrs |> put_derived_org_id() |> put_armed_acts_at())
    |> Repo.insert()
    |> emit(:heard, fn candidate ->
      %{
        "state" => candidate.state,
        "speaker" => candidate.speaker,
        "outcome_kind" => candidate.outcome_kind,
        "transcript_chunk_id" => candidate.transcript_chunk_id
      }
    end)
  end

  # ── threading (task 01a03fb9 stage 4) ─────────────────────────────────────

  @doc """
  Record an utterance: either as a NEW candidate, or by attaching it to
  the open candidate it continues.

  This is the only place threading happens in production, and it takes
  the same `attrs` as `create/1` so the caller does not have to describe
  the utterance twice. The utterance the resolver judges is DERIVED from
  those attrs — `:speaker`, `:evidence_quote` and `:last_utterance_at`
  are exactly the three things the row would have recorded — so the
  thing compared against the open candidates is by construction the same
  thing that would otherwise have been written.

  The open list is read BEFORE anything is inserted, so the row this
  utterance would have created is never in the list it is compared
  against.

  ## Why this lives here and not in the caller

  `Platform.Meetings.IntentQueue.Server` is the only caller today. The
  decision is here anyway because the write half of it —
  `attach_utterance/2` — must stay inside this module for the same
  reason `close/2` is a single function: a candidate's arc is written in
  exactly one place. Splitting the decision from the write is how a
  second caller ends up appending to `threading_events` with its own
  slightly different entry shape.

  ## What an attached utterance does NOT get

  A threaded utterance gets no candidate row of its own, which is the
  whole point — but it is worth stating what follows from it. The queue
  still holds a separate intent row for it, and that intent's later
  transitions (`mirror_transition`, `mirror_ack`) look their candidate
  up by `intent_id` and find nothing, so they are no-ops. The card's
  lifecycle continues to follow the intent that CREATED it. The
  attached intent is not lost — its id is recorded in the
  `threading_events` entry — but it does not drive state. Giving a
  second intent authority over a card somebody else's intent created is
  a bigger decision than this stage, and it is the countdown ticket
  (`01a03fba-7b07`) that has to make it.
  """
  @spec create_or_attach(map()) ::
          {:ok, MeetingCandidate.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_or_attach(attrs) when is_map(attrs) do
    meeting_id = fetch_meeting_id(attrs)
    chunk_id = first_chunk_id(attrs)

    case recorded_chunk(meeting_id, chunk_id) do
      nil ->
        resolve_or_create(attrs, meeting_id)

      %MeetingCandidate{transcript_chunk_id: owner} = row when owner == chunk_id ->
        reconcile(row, attrs)

      %MeetingCandidate{} = host ->
        note_intent(host, chunk_id, Map.get(attrs, :intent_id))
    end
  end

  # The chunk already threaded onto `host` — at ARRIVAL, where there was
  # no intent id yet because the classifier had not been called. This is
  # the first moment one exists, so it is written back into the
  # threading event it belongs to.
  #
  # It is the ONLY place the attached utterance's intent is recoverable
  # from: the attached intent gets no candidate row of its own, so
  # `get_by_intent_id/1` will never find it. Dropping this write does
  # not fail any row count — it silently erases the link between a
  # queue row and the card it landed on.
  defp note_intent(host, chunk_id, intent_id) when is_binary(intent_id) do
    {events, wrote?} =
      Enum.map_reduce(host.threading_events, false, fn
        %{"transcript_chunk_id" => ^chunk_id, "intent_id" => nil} = event, _ ->
          {Map.put(event, "intent_id", intent_id), true}

        event, wrote? ->
          {event, wrote?}
      end)

    if wrote? do
      host
      |> MeetingCandidate.changeset(%{threading_events: events})
      |> Repo.update()
    else
      {:ok, host}
    end
  end

  defp note_intent(host, _chunk_id, _intent_id), do: {:ok, host}

  defp resolve_or_create(attrs, meeting_id) do
    utterance = %{
      speaker: Map.get(attrs, :speaker),
      text: Map.get(attrs, :evidence_quote),
      at: Map.get(attrs, :last_utterance_at)
    }

    open = open_for_meeting(meeting_id)

    case ThreadResolver.resolve(utterance, open) do
      {:thread, candidate, reason} ->
        attach_utterance(candidate, %{
          transcript_chunk_id: first_chunk_id(attrs),
          intent_id: Map.get(attrs, :intent_id),
          at: utterance.at,
          reason: reason
        })

      :new ->
        create(attrs)
    end
  end

  @doc """
  Record a chunk the moment it is HEARD, before the classifier answers.

  This is the pre-classification half of `create_or_attach/1` (task
  01a04a7f). It writes the row Harper asked for — a card that appears
  as soon as something is said, with no title yet — and returns:

    * `{:ok, skeleton}` — a new unclassified row was written, or the one
      already written for this chunk was found. The caller OWNS this row
      and is responsible for closing it if classification never lands.
    * `{:attached, host}` — this utterance continues an open candidate,
      so no row of its own was written. The caller owns nothing.
    * `{:error, reason}` — nothing was written.

  ## Why the threading decision moved HERE

  It used to live in `create_or_attach/1`, at classifier-return time.
  It cannot stay there once a skeleton exists: `create_or_attach/1`
  now reconciles onto the row for its own chunk, so the resolver would
  never be consulted again and threading would silently stop happening.

  Moving it is safe because the resolver reads exactly three things —
  speaker, text and time — and all three are known at arrival. The
  decision is therefore made on identical inputs, just ~1.5-3s earlier
  (the debounce plus the model call). The one thing that does change is
  `at`, which is now the arrival clock rather than the enqueue clock;
  against a 60s window that is a strict improvement, because it is the
  time the human actually spoke.

  ## Idempotence

  Keyed on `transcript_chunk_id`. A chunk already recorded — whether as
  a row of its own or as an entry in some other row's
  `transcript_chunk_ids` — never produces a second row. Without this
  key a retried chunk becomes two cards for one sentence.
  """
  @spec record_heard(map()) ::
          {:ok, MeetingCandidate.t()}
          | {:attached, MeetingCandidate.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :no_meeting_id | :no_chunk_id | :not_found}
  def record_heard(attrs) when is_map(attrs) do
    meeting_id = fetch_meeting_id(attrs)
    chunk_id = first_chunk_id(attrs)

    cond do
      not is_binary(meeting_id) or not Platform.UUID.valid?(meeting_id) ->
        {:error, :no_meeting_id}

      not is_binary(chunk_id) or not Platform.UUID.valid?(chunk_id) ->
        {:error, :no_chunk_id}

      true ->
        do_record_heard(attrs, meeting_id, chunk_id)
    end
  end

  defp do_record_heard(attrs, meeting_id, chunk_id) do
    case recorded_chunk(meeting_id, chunk_id) do
      nil -> thread_or_open(attrs, meeting_id, chunk_id)
      %MeetingCandidate{transcript_chunk_id: owner} = row when owner == chunk_id -> {:ok, row}
      %MeetingCandidate{} = host -> {:attached, host}
    end
  end

  defp thread_or_open(attrs, meeting_id, chunk_id) do
    at = Map.get(attrs, :heard_at) || Map.get(attrs, :last_utterance_at) || DateTime.utc_now()
    speaker = speaker_or_nil(Map.get(attrs, :speaker))
    text = Map.get(attrs, :evidence_quote)
    utterance = %{speaker: speaker, text: text, at: at}

    # Read ONCE and handed to both questions, so the retraction gate and
    # the threading resolver are answering about the same set of open
    # cards. Two reads would let a card close between them.
    open = open_for_meeting(meeting_id)

    # The retraction gate runs BEFORE the resolver, and the order is
    # load-bearing. `105da003` refuses a negation only on the ANAPHORIC
    # path; a longer negation that repeats the candidate's own topic
    # ("don't make the dashboard load faster") scores 1.0 on
    # `:topic_overlap` and threads onto the card it negates. Running the
    # gate second would never see it, because it would already have been
    # absorbed. `RetractionGateTest` asserts that exact string against
    # `resolve/2` so this is a measured ordering, not a defensive one.
    case ThreadResolver.retraction_target(utterance, open) do
      {:retraction, candidate, reason} ->
        retract(candidate, text, chunk_id, reason)

        # The resolver is deliberately NOT consulted afterwards. The gate
        # only fires when exactly one candidate survives the same-speaker
        # + window filter, and that one is now closed — so resolving
        # against what is left is resolving against an empty gated list,
        # which is `:new` by definition. Calling it anyway would let the
        # utterance thread onto the card it just retracted.
        open_new(attrs, meeting_id, chunk_id, text, speaker, at)

      :none ->
        case ThreadResolver.resolve(utterance, open) do
          {:thread, candidate, reason} ->
            case attach_utterance(candidate, %{
                   transcript_chunk_id: chunk_id,
                   intent_id: Map.get(attrs, :intent_id),
                   at: at,
                   reason: reason
                 }) do
              {:ok, host} -> {:attached, host}
              other -> other
            end

          :new ->
            open_new(attrs, meeting_id, chunk_id, text, speaker, at)
        end
    end
  end

  defp open_new(attrs, meeting_id, chunk_id, text, speaker, at) do
    create(%{
      meeting_id: meeting_id,
      # Guarded exactly like `mirror_enqueue/3` guards it: a LiveKit
      # room name is not always a UUID, and letting a non-UUID reach
      # a `:binary_id` cast would fail the whole changeset and turn
      # "no early card for this room" into a silent, room-wide
      # outage of this feature.
      room_id: uuid_or_nil(Map.get(attrs, :room_id)),
      transcript_chunk_id: chunk_id,
      transcript_chunk_ids: [chunk_id],
      evidence_quote: text,
      speaker: speaker,
      state: :heard,
      outcome_kind: Map.get(attrs, :outcome_kind) || :task,
      heard_at: at,
      last_utterance_at: at
    })
  end

  # The machine's second-thoughts check, and the SECOND caller of
  # `close/2` (task 01a03fba). It goes through `close/2` like every
  # other one — no `retract/1` in the public API — so the board renders
  # a machine-detected retraction and a human's cancel identically,
  # which is the whole point of the single close path.
  #
  # `:retracted` already had producers before this: `queue_status_to_state`
  # maps `cancelled`/`cancelled_late` onto it, and `IntentQueue.Server`'s
  # `close_ack` writes it when a human presses stop. Those are the
  # HUMAN's stop button. This is the machine hearing the same decision
  # said out loud, and it deliberately lands on the same reason atom
  # rather than a sixth one — the card was taken back; who noticed is
  # `closed_note`'s job, not the vocabulary's.
  #
  # Non-fatal. A failed close is logged and the retracting utterance
  # still gets its own row: recording a card is a recording act, and
  # losing the new card as well would turn one missed close into two
  # missing cards.
  defp retract(candidate, text, chunk_id, reason) do
    case close(candidate, {:retracted, retraction_note(text, chunk_id, reason)}) do
      {:ok, closed} ->
        {:ok, closed}

      {:error, error} ->
        Logger.warning(
          "meeting candidate retraction close failed: " <>
            "candidate=#{candidate.id} reason=#{inspect(error)}"
        )

        {:error, error}
    end
  end

  # Everything a reader needs to second-guess the gate after the fact:
  # what was said, which chunk said it, how long after, which particle
  # fired and what it shared. `threading_events` is not used for this —
  # that log is per-ATTACHMENT and a retraction attaches nothing.
  defp retraction_note(text, chunk_id, reason) do
    "retracted by a later utterance from the same speaker, " <>
      "#{inspect(reason.elapsed_seconds)}s later: #{inspect(excerpt(text))} " <>
      "(chunk #{chunk_id}; markers #{inspect(reason.markers)}; " <>
      "shared #{inspect(reason.shared)})"
  end

  @note_excerpt_limit 200

  defp excerpt(text) when is_binary(text) do
    if String.length(text) > @note_excerpt_limit,
      do: String.slice(text, 0, @note_excerpt_limit) <> "...",
      else: text
  end

  defp excerpt(text), do: text

  # The classified fields land on the skeleton; everything the skeleton
  # accreted while the model was thinking stays put.
  #
  # `transcript_chunk_ids`, `threading_events` and `last_utterance_at`
  # are dropped from the incoming attrs because `mirror_enqueue` builds
  # them as if it were CREATING the row — a single-element chunk list, an
  # empty event log, `last_utterance_at` equal to the enqueue time. Any
  # utterance that attached to the skeleton in the intervening seconds
  # is recorded in exactly those three columns, so letting the create
  # shape overwrite them would erase the attachment. `heard_at` is
  # dropped for the same reason in the other direction: first sight was
  # arrival, not enqueue.
  @reconcile_drop ~w(transcript_chunk_ids threading_events last_utterance_at heard_at)a

  # Only a SKELETON is reconcilable. A row that already carries a
  # classification, or one that has already closed, is returned
  # untouched: the card belongs to the classification that opened it,
  # and a second intent arriving for the same chunk (a replayed
  # transcript segment) must not be able to relabel somebody else's
  # card or reopen a closed one.
  defp reconcile(%MeetingCandidate{state: :closed} = closed, _attrs), do: {:ok, closed}

  defp reconcile(%MeetingCandidate{classified_intent: intent} = row, _attrs)
       when not is_nil(intent),
       do: {:ok, row}

  defp reconcile(%MeetingCandidate{} = skeleton, attrs) do
    skeleton
    |> MeetingCandidate.changeset(Map.drop(atomize(attrs), @reconcile_drop))
    |> Repo.update()
    # Read off the RECONCILED row, not off `attrs`. The changeset is
    # what decided which of those fields actually landed, so echoing
    # the input would report a classification the row may not carry.
    |> emit(:classified, fn reconciled ->
      %{
        "classified_intent" => reconciled.classified_intent,
        "classifier_confidence" => reconciled.classifier_confidence,
        "target_role" => reconciled.target_role,
        "assigned_agent_slug" => reconciled.assigned_agent_slug,
        "outcome_kind" => reconciled.outcome_kind
      }
    end)
  end

  # The candidate that already owns this chunk, preferring the row the
  # chunk CREATED over a row it merely attached to. Both are lookups
  # that must exist: the singular column answers "is there a skeleton
  # for me", the array answers "did I already thread onto somebody".
  defp recorded_chunk(meeting_id, chunk_id)
       when is_binary(meeting_id) and is_binary(chunk_id) do
    if Platform.UUID.valid?(meeting_id) and Platform.UUID.valid?(chunk_id) do
      rows =
        MeetingCandidate
        |> where([c], c.meeting_id == ^meeting_id)
        |> where(
          [c],
          c.transcript_chunk_id == ^chunk_id or
            fragment("? = ANY(?)", type(^chunk_id, :binary_id), c.transcript_chunk_ids)
        )
        |> Repo.all()

      Enum.find(rows, &(&1.transcript_chunk_id == chunk_id)) || List.first(rows)
    end
  end

  defp recorded_chunk(_meeting_id, _chunk_id), do: nil

  # Same normalisation `Platform.Meetings.IntentQueue.Server` applies on
  # the classified path: `""` is unattributed, and unattributed must be
  # nil so two strangers cannot match each other on an empty string.
  defp speaker_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp speaker_or_nil(_), do: nil

  defp uuid_or_nil(value) do
    if Platform.UUID.valid?(value), do: value
  end

  @doc """
  Attach a continuing utterance to an existing candidate.

  Three writes, and each is load-bearing:

    * `transcript_chunk_ids` gains this utterance's chunk. This is THE
      accretion record and the only durable evidence that two
      utterances landed on one card — the row count alone cannot tell
      "the second utterance attached" apart from "the second utterance
      was never mirrored at all".
    * `threading_events` gains one entry carrying the resolver's reason
      map VERBATIM. Not the rule atom: an atom records *that* a rule
      fired without recording *what it saw*, and attaching to the wrong
      candidate is only diagnosable afterwards from the score, the
      shared tokens and how many candidates were open at the time.
    * `last_utterance_at` moves to the new utterance. `heard_at` is
      deliberately untouched — that is the whole reason they are two
      columns (see `Platform.Meetings.MeetingCandidate`).

  `state` is NOT advanced. An utterance attaching to a `:shaping`
  candidate is more evidence for the same card, not lifecycle
  progress.

  Forward motion of `last_utterance_at` is guaranteed by the caller:
  `Platform.Meetings.ThreadResolver`'s window gate only admits an
  utterance at or after the candidate's current `last_utterance_at`.
  """
  @spec attach_utterance(MeetingCandidate.t() | binary(), map()) ::
          {:ok, MeetingCandidate.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def attach_utterance(candidate_or_id, attrs) when is_map(attrs) do
    with {:ok, candidate} <- fetch(candidate_or_id) do
      at = Map.get(attrs, :at) || DateTime.utc_now()
      chunk_id = Map.get(attrs, :transcript_chunk_id)

      candidate
      |> MeetingCandidate.changeset(%{
        transcript_chunk_ids: candidate.transcript_chunk_ids ++ List.wrap(chunk_id),
        threading_events: candidate.threading_events ++ [threading_event(attrs, at, chunk_id)],
        last_utterance_at: at,
        # The extension (task 01a03fba). This is the ONLY place a
        # countdown moves forward, because an attachment is the only
        # signal in the system that says "this specific card is still
        # being discussed". It rides the same write as
        # `last_utterance_at` on purpose: two writes could leave a card
        # whose last utterance is newer than the deadline it is counting
        # to, which reads as a stuck timer.
        #
        # A DISARMED card is not re-armed here. nil means either a human
        # pressed stop or the meeting's automation is off, and neither
        # of those should be undone by somebody carrying on talking.
        acts_at: extended_acts_at(candidate, at)
      })
      |> Repo.update()
      # The resolver's own reason map, verbatim — the same value that
      # goes into `threading_events`, and for the same argument: "the
      # threading gate ran" records that a decision happened and loses
      # which rule made it.
      |> emit(:threaded, fn _updated ->
        %{
          "reason" => jsonable(Map.get(attrs, :reason)),
          "transcript_chunk_id" => chunk_id,
          "intent_id" => Map.get(attrs, :intent_id)
        }
      end)
    end
  end

  # The column is jsonb, so the entry is built with STRING keys and
  # JSON-safe values HERE rather than left to Ecto's dump. An atom
  # written into jsonb comes back a string, so a map built with atom
  # keys changes shape across a round trip and a reader matching on it
  # works in memory and fails after a reload.
  defp threading_event(attrs, at, chunk_id) do
    %{
      "reason" => jsonable(Map.get(attrs, :reason)),
      "at" => DateTime.to_iso8601(at),
      "intent_id" => Map.get(attrs, :intent_id),
      "transcript_chunk_id" => chunk_id
    }
  end

  # ── activity log (task 01a03fba) ──────────────────────────────────────────

  # Emit one line for one write, and ONLY for a write that succeeded.
  #
  # This wrapper is the mechanism behind the ticket's central assertion —
  # "a candidate that closes early shows the gates that ran and no
  # others". It is not a rule the log obeys; there is structurally no
  # way to produce a line without a `{:ok, _}` from `Repo`, so a gate
  # that did not run cannot have one.
  #
  # The detail is a FUNCTION rather than a map so it is not computed for
  # a write that failed, and so each call site can read off the row the
  # write returned rather than the attrs that went in.
  #
  # Returns the result untouched. Logging must never change what a
  # caller sees, or the log would be able to break the thing it
  # describes.
  defp emit({:ok, %MeetingCandidate{} = candidate} = result, kind, detail_fun) do
    CandidateEvents.record(candidate, kind, jsonable(detail_fun.(candidate)))
    result
  end

  defp emit(result, _kind, _detail_fun), do: result

  defp jsonable(nil), do: nil
  defp jsonable(true), do: true
  defp jsonable(false), do: false
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(%_struct{} = value), do: value

  defp jsonable(%{} = value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), jsonable(inner)} end)

  defp jsonable(value), do: value

  # The chunk this utterance carried, whichever way the caller named it.
  # `mirror_enqueue` seeds the plural on the create path, so the plural
  # is checked first and the singular is the fallback.
  defp first_chunk_id(attrs) do
    case Map.get(attrs, :transcript_chunk_ids) do
      [id | _] -> id
      _ -> Map.get(attrs, :transcript_chunk_id)
    end
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc """
  Fetch one candidate by id, or nil.

  Guarded with `Platform.UUID.valid?/1` rather than left to raise: the
  ids reaching here come from a board's `phx-value-` payload and from
  queue rows keyed by whatever a transcript chunk carried, and the
  contract of this function is already `| nil`.
  """
  @spec get(binary() | nil) :: MeetingCandidate.t() | nil
  def get(id) do
    if Platform.UUID.valid?(id), do: Repo.get(MeetingCandidate, id)
  end

  @doc """
  Fetch the candidate mirroring `intent_id`, or nil.

  Backed by the unique index the stage-3 mirror uses as its idempotence
  key.
  """
  @spec get_by_intent_id(binary() | nil) :: MeetingCandidate.t() | nil
  def get_by_intent_id(intent_id) do
    if Platform.UUID.valid?(intent_id),
      do: Repo.get_by(MeetingCandidate, intent_id: intent_id)
  end

  @doc """
  Candidates for one meeting, OLDEST first.

  Ascending is the board's order — a candidate list is a narrative of
  the meeting, not a newest-first feed.
  """
  @spec list_for_meeting(binary() | nil) :: [MeetingCandidate.t()]
  def list_for_meeting(nil), do: []

  def list_for_meeting(meeting_id) when is_binary(meeting_id) do
    MeetingCandidate
    |> where([c], c.meeting_id == ^meeting_id)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> Repo.all()
  end

  @doc """
  The candidates a new utterance could still attach to, NEWEST FIRST.

  Two filters, and neither subsumes the other:

    * `state in [:heard, :thinking, :shaping]` — see `@open_states`.
    * `closed_reason` is nil. A `:closed` candidate is already excluded
      by the state filter, so this clause exists for the row `close/2`
      never wrote: `closed_reason` is the durable mark that somebody
      retracted, vetoed, dismissed or de-duplicated this card, and a row
      carrying that mark must not be offered as an attachment target
      whatever its `state` column happens to say. Dropping the clause as
      "redundant with the state filter" is how a vetoed candidate starts
      accreting utterances again.

  Descending is the exact inverse of `list_for_meeting/1`, which is
  ascending because a board is a narrative. This one is not a board:
  it answers "what is live right now", so the most recent candidate
  leads. Ordering is by `inserted_at` with `id` (a time-ordered UUIDv7)
  as the tiebreak — NOT by `last_utterance_at`, which is nil on every
  row that did not come through `mirror_enqueue` and would sort those
  rows arbitrarily. A threading rule that wants recency of ACTIVITY
  reads `last_utterance_at` off the struct itself; this order only has
  to be total and stable.
  """
  @spec open_for_meeting(binary() | nil) :: [MeetingCandidate.t()]
  def open_for_meeting(nil), do: []

  def open_for_meeting(meeting_id) when is_binary(meeting_id) do
    MeetingCandidate
    |> where([c], c.meeting_id == ^meeting_id)
    |> where([c], c.state in ^@open_states)
    |> where([c], is_nil(c.closed_reason))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> Repo.all()
  end

  # ── advance ───────────────────────────────────────────────────────────────

  @doc """
  Move a candidate forward to `state`, merging `attrs`.

  Forward-only: a transition to a state at or before the current one
  returns `{:error, {:invalid_transition, from, to}}`. `:closed` is the
  exception and is reachable from any non-closed state — it delegates to
  `close/2` so that the closing write stays a single code path (see the
  moduledoc). The reason comes from `attrs[:closed_reason]`, defaulting
  to `:done`.

  Stamps `heard_at` / `dispatched_at` / `acted_at` on FIRST entry to the
  corresponding state and never overwrites an already-set stamp: the
  interesting number is when a candidate first reached a state, and a
  re-drive must not move it.
  """
  @spec advance(MeetingCandidate.t() | binary(), atom(), map()) ::
          {:ok, MeetingCandidate.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:invalid_transition, atom(), atom()}}
          | {:error, :not_found}
  def advance(candidate_or_id, state, attrs \\ %{})

  def advance(candidate_or_id, :closed, attrs) when is_map(attrs) do
    with {:ok, candidate} <- fetch(candidate_or_id) do
      reason = Map.get(attrs, :closed_reason) || Map.get(attrs, "closed_reason") || :done
      close(candidate, close_reason_with_note(reason, attrs))
    end
  end

  def advance(candidate_or_id, state, attrs) when state in @order and is_map(attrs) do
    with {:ok, candidate} <- fetch(candidate_or_id),
         :ok <- check_forward(candidate.state, state) do
      candidate
      |> MeetingCandidate.changeset(
        attrs
        |> atomize()
        |> Map.put(:state, state)
        |> stamp(candidate, state)
      )
      |> Repo.update()
      # `from` is closed over from the PRE-update row and cannot be
      # re-derived afterwards: once the update lands, nothing on the
      # candidate remembers where it came from.
      |> emit(:advanced, fn advanced ->
        %{"from" => candidate.state, "to" => advanced.state}
      end)
    end
  end

  defp close_reason_with_note(reason, attrs) do
    case Map.get(attrs, :closed_note) || Map.get(attrs, "closed_note") do
      nil -> reason
      note -> {reason, note}
    end
  end

  defp check_forward(from, to) do
    if index(to) > index(from), do: :ok, else: {:error, {:invalid_transition, from, to}}
  end

  defp index(state), do: Enum.find_index(@order, &(&1 == state))

  # Only writes a stamp column the candidate does not already carry.
  defp stamp(attrs, candidate, state) do
    with column when not is_nil(column) <- Map.get(@state_stamps, state),
         nil <- Map.get(candidate, column) do
      Map.put_new(attrs, column, DateTime.utc_now())
    else
      _ -> attrs
    end
  end

  # ── disposition ───────────────────────────────────────────────────────────

  @doc """
  Record the measurement axis — did a human accept this, reject it, or
  did it expire unanswered.

  Deliberately independent of `state`: this may be called on a candidate
  that is still `:acting`, and both `:accepted` and `:rejected`
  candidates end `:closed`. Nothing here touches `state`.
  """
  @spec record_disposition(MeetingCandidate.t() | binary(), atom(), map()) ::
          {:ok, MeetingCandidate.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def record_disposition(candidate_or_id, disposition, attrs \\ %{}) when is_map(attrs) do
    with {:ok, candidate} <- fetch(candidate_or_id) do
      candidate
      |> MeetingCandidate.changeset(
        attrs
        |> atomize()
        |> Map.put(:disposition, disposition)
        |> Map.put_new(:disposition_at, DateTime.utc_now())
      )
      |> Repo.update()
      |> emit(:disposition_recorded, fn updated ->
        %{"disposition" => updated.disposition, "state" => updated.state}
      end)
    end
  end

  # ── close ─────────────────────────────────────────────────────────────────

  @doc """
  Close a candidate. THE only write path that sets `closed_reason`.

  `reason` is a bare atom from `MeetingCandidate.closed_reasons/0`, or
  `{reason, note}` to carry an operator note. Idempotent: an
  already-closed candidate is returned unchanged so a late duplicate
  cancel cannot relabel the close that actually happened.
  """
  @spec close(MeetingCandidate.t() | binary(), atom() | {atom(), String.t()}) ::
          {:ok, MeetingCandidate.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def close(candidate_or_id, reason) do
    {reason, note} =
      case reason do
        {reason, note} -> {reason, note}
        reason -> {reason, nil}
      end

    with {:ok, candidate} <- fetch(candidate_or_id) do
      if candidate.state == :closed do
        # Idempotent, and deliberately SILENT. A second cancel arriving
        # after a veto writes nothing, so it must narrate nothing —
        # emitting here would put a close on the rail that never
        # happened, and would let a duplicate cancel appear to relabel
        # the close that did.
        {:ok, candidate}
      else
        candidate
        |> MeetingCandidate.changeset(%{
          state: :closed,
          closed_reason: reason,
          closed_note: note,
          closed_at: DateTime.utc_now()
        })
        |> Repo.update()
        |> emit(:closed, fn closed ->
          %{
            "reason" => closed.closed_reason,
            "note" => closed.closed_note,
            "from" => candidate.state,
            "disposition" => closed.disposition
          }
        end)
      end
    end
  end

  # ── countdown (task 01a03fba) ─────────────────────────────────────────────

  @doc """
  Stop a candidate's countdown, on the record, naming the human who did
  it.

  This is the server side of the stop button, and the reason it is not
  simply `close/2` with a reason is the sweeper: between a naive
  `SELECT` and a `close/2` the sweeper can claim the same row and mint
  its deliverable, so a human who pressed stop would watch the task
  appear anyway. The disarm is therefore a conditional UPDATE that
  races the claim in `claim_due/2` on the same row, and Postgres row
  locking picks one winner:

      UPDATE meeting_candidates
         SET acts_at = NULL, closed_by_participant_id = $2
       WHERE id = $1 AND state NOT IN ('closed', 'acting')

  Whoever commits first leaves the other's `WHERE` unsatisfiable.

  Returns:

    * `{:ok, candidate}` — this call disarmed it and closed it
      `:dismissed`. Also returned for an already-`:closed` candidate, so
      a double-click is idempotent and does not relabel the close that
      actually happened.
    * `{:error, :already_fired}` — the sweeper won; the deliverable
      exists. Deliberately NOT `{:ok, _}`: the caller has to be able to
      tell the human that the stop was too late. Detected from
      `disposition == :accepted`, which `graduate/2` writes and nothing
      on this path does — a graduated candidate and a stopped one are
      BOTH `:closed`, so state alone cannot tell them apart.
    * `{:error, :not_found}` — no such candidate.

  `participant_id` may be nil for a machine-initiated stop, but the
  human path always carries one — that column is what makes "with the
  human named" a fact about the row rather than a sentence in
  `closed_note`.

  `close/2` is still the only thing that writes `closed_reason`,
  `closed_at` and `state: :closed`; this function writes the two
  countdown columns and then delegates.
  """
  @spec stop(MeetingCandidate.t() | binary(), binary() | nil, keyword()) ::
          {:ok, MeetingCandidate.t()}
          | {:error, :already_fired | :not_found | Ecto.Changeset.t()}
  def stop(candidate_or_id, participant_id \\ nil, opts \\ []) do
    # RE-READ, never the struct handed in — the same call
    # `Platform.Meetings.set_intent_muted/2` makes and for the same
    # reason. `fetch/1`'s struct clause returns its argument untouched,
    # and the struct a stop arrives with came out of a LiveView assign
    # that was loaded when the participant's page rendered. Trusting its
    # `state` made an already-closed candidate look open, so the
    # idempotent branch below was skipped and a second click answered
    # `{:error, :already_fired}` — telling a human a task had been
    # created when nothing of the kind had happened.
    with {:ok, %MeetingCandidate{id: id}} <- fetch(candidate_or_id),
         {:ok, %MeetingCandidate{} = candidate} <- fetch(id) do
      cond do
        # It graduated. `:accepted` is written by `graduate/2` and by
        # nothing on this path, so it is the exact fact that separates
        # "somebody already stopped this" from "this already went ahead"
        # — two outcomes that both leave the row `:closed` and that a
        # human needs told apart, because only one of them means a task
        # now exists.
        candidate.disposition == :accepted ->
          {:error, :already_fired}

        # Already stopped (or otherwise closed). Idempotent and silent,
        # matching `close/2`: a second click must not relabel the close
        # that actually happened.
        candidate.state == :closed ->
          {:ok, candidate}

        true ->
          do_stop(candidate, participant_id, opts)
      end
    end
  end

  defp do_stop(candidate, participant_id, opts) do
    claimed =
      MeetingCandidate
      |> where([c], c.id == ^candidate.id)
      |> where([c], c.state not in [:closed, :acting])
      |> select([c], c.id)
      |> Repo.update_all(
        set: [
          acts_at: nil,
          closed_by_participant_id: uuid_or_nil(participant_id),
          updated_at: DateTime.utc_now()
        ]
      )

    case claimed do
      {1, _} ->
        note = Keyword.get(opts, :note) || stop_note(Keyword.get(opts, :actor_name))

        candidate.id
        |> close({:dismissed, note})
        |> emit(:countdown_stopped, fn stopped ->
          %{
            "closed_by_participant_id" => stopped.closed_by_participant_id,
            "actor_name" => Keyword.get(opts, :actor_name),
            "from" => candidate.state
          }
        end)

      _ ->
        # Nothing matched, and this row was not `:closed` when we read
        # it, so the sweeper took it into `:acting` in between.
        {:error, :already_fired}
    end
  end

  # The note is a courtesy for a reader of `closed_note`;
  # `closed_by_participant_id` is the fact. A stop with no name still
  # says a human did it, because nothing else in the system produces
  # `:dismissed`.
  defp stop_note(nil), do: "Stopped by a participant"
  defp stop_note(name) when is_binary(name), do: "Stopped by #{name}"
  defp stop_note(_), do: "Stopped by a participant"

  @doc """
  Atomically claim every candidate whose countdown is due, and return
  the claimed rows.

  This is the sweeper's whole read-and-write, and it is ONE statement on
  purpose. A `SELECT` followed by a `graduate/2` is not safe here:
  `graduate/2` has no guard of its own, there is no advisory lock,
  leader election or `:global` registration anywhere in `lib/`, and
  every sweeper in this codebase is node-local and boot-flag gated. Two
  nodes sweeping one meeting would both clear the read and both reach
  `mint/1` — one candidate, two tasks. The claim is what makes the fire
  exactly-once, and the idempotence lives in the data exactly as it does
  for every other sweeper here.

  Claiming sets `acts_at` to nil (so the row cannot be re-claimed even
  if the state write were later rolled forward) and moves the row to
  `:acting`, stamping `acted_at` only if it is not already stamped —
  the same first-entry-wins rule `advance/3` applies.

  `automation_mode` is re-checked HERE as well as at arming time. A
  meeting muted after its cards were armed must not fire them, and that
  is the requirement that cannot be traded away, so it is a join in the
  claim rather than a filter the caller could forget.
  """
  @spec claim_due(DateTime.t(), keyword()) :: [MeetingCandidate.t()]
  def claim_due(now \\ DateTime.utc_now(), opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    due_ids =
      MeetingCandidate
      |> join(:inner, [c], m in Meeting, on: m.id == c.meeting_id)
      |> where([c], not is_nil(c.acts_at))
      |> where([c], c.acts_at <= ^now)
      |> where([c], c.state not in [:closed, :acting])
      # `automation_mode == :off` is `intent_muted_at` being set — one
      # switch, not two. See `Platform.Meetings.automation_mode/1`.
      |> where([_c, m], is_nil(m.intent_muted_at))
      |> order_by([c], asc: c.acts_at)
      |> limit(^limit)
      |> select([c], c.id)
      |> Repo.all()

    claim_ids(due_ids, now)
  end

  defp claim_ids([], _now), do: []

  defp claim_ids(ids, now) do
    {_count, claimed} =
      MeetingCandidate
      |> where([c], c.id in ^ids)
      # Re-asserted inside the writing statement. The id list above is a
      # plain read and anything could have happened to those rows since
      # — a stop, another node's claim — so the predicate that actually
      # decides is the one on the UPDATE.
      |> where([c], not is_nil(c.acts_at))
      |> where([c], c.acts_at <= ^now)
      |> where([c], c.state not in [:closed, :acting])
      |> select([c], c)
      |> Repo.update_all(
        set: [acts_at: nil, state: :acting, updated_at: now],
        inc: []
      )
      |> then(fn {count, rows} -> {count, rows || []} end)

    Enum.map(claimed, fn candidate ->
      stamp_acted_at(candidate, now)
    end)
  end

  # `update_all` cannot express "only if null" for one column while
  # setting others unconditionally, and `acted_at` is a first-entry stamp
  # that a re-drive must not move. The claim is already exclusive, so
  # this follow-up write is uncontended.
  defp stamp_acted_at(%MeetingCandidate{acted_at: nil} = candidate, now) do
    case candidate |> MeetingCandidate.changeset(%{acted_at: now}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _} -> candidate
    end
  end

  defp stamp_acted_at(candidate, _now), do: candidate

  @doc """
  Fire one claimed candidate: mint its deliverable and narrate it.

  Separate from `claim_due/2` so the claim stays a single statement and
  the minting — which reaches `Platform.Tasks.create_task/2` and can
  fail on an archived project — happens outside it.

  A failed mint leaves the row `:acting` and DISARMED. It is not
  re-armed: `graduate/2` propagates `{:error, :project_archived}` for a
  frozen project, and a sweeper that re-armed on failure would retry
  that same permanent error every second for the life of the meeting.
  The row stays visible as an `:acting` candidate with no deliverable,
  which is the truthful reading of what happened.
  """
  @spec fire(MeetingCandidate.t()) :: {:ok, MeetingCandidate.t()} | {:error, term()}
  def fire(%MeetingCandidate{} = candidate) do
    case graduate(candidate) do
      {:ok, graduated} ->
        emit({:ok, graduated}, :countdown_fired, fn fired ->
          %{
            "outcome_kind" => fired.outcome_kind,
            "task_id" => fired.task_id,
            "canvas_id" => fired.canvas_id
          }
        end)

      {:error, reason} = error ->
        Logger.warning(
          "meeting candidate countdown fire failed: " <>
            "candidate=#{candidate.id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  # The arming arithmetic, applied to the attrs a create is about to
  # write. Three things have to be true before a card counts down, and
  # each of them is a `nil` here rather than a raise:
  #
  #   * there is an utterance time to count from,
  #   * the row is not being created already closed,
  #   * the meeting's automation is on.
  #
  # The automation check at ARMING time is what stops an "off" meeting
  # becoming a landmine: without it a muted meeting would accumulate
  # cards with deadlines in the past and fire all of them the instant
  # somebody turned automation back on. Cards opened while it is off are
  # simply never armed, so switching on affects what happens next and
  # nothing that already happened.
  defp put_armed_acts_at(attrs) do
    cond do
      Map.has_key?(attrs, :acts_at) or Map.has_key?(attrs, "acts_at") ->
        attrs

      true ->
        from =
          Map.get(attrs, :last_utterance_at) || Map.get(attrs, "last_utterance_at") ||
            Map.get(attrs, :heard_at) || Map.get(attrs, "heard_at")

        state = Map.get(attrs, :state) || Map.get(attrs, "state")
        meeting_id = fetch_meeting_id(attrs)

        armed =
          if state in [:closed, "closed"] or not automated?(meeting_id) do
            nil
          else
            Countdown.acts_at(from)
          end

        if Map.has_key?(attrs, "meeting_id") do
          Map.put(attrs, "acts_at", armed)
        else
          Map.put(attrs, :acts_at, armed)
        end
    end
  end

  # An already-disarmed card stays disarmed — a stop is not undone by
  # somebody carrying on talking, and neither is an "off" meeting.
  defp extended_acts_at(%MeetingCandidate{acts_at: nil}, _at), do: nil

  defp extended_acts_at(%MeetingCandidate{}, at), do: Countdown.acts_at(at)

  defp automated?(meeting_id) do
    Platform.Meetings.automation_mode(meeting_id) == :automated
  end

  # ── graduate ──────────────────────────────────────────────────────────────

  @doc """
  Turn a candidate into its deliverable and close it out.

  The pipeline is identical for both `outcome_kind`s — resolve the
  meeting, mint the deliverable, record `:accepted`, close `:done`.
  ONLY the minting step differs:

    * `:task` — `Platform.Tasks.create_task/2` against the meeting's
      `project_id`; the new task id lands in `task_id` and `canvas_id`
      stays nil.
    * `:artifact` — `Platform.Chat.create_canvas/1` in the meeting's
      `chat_space_id`; the new canvas id lands in `canvas_id` and NO
      TASK IS CREATED. `task_id` stays nil.

  The artifact branch has no code path that reaches `create_task/2`.
  The stage-1 changeset rule (artifact + `task_id` is invalid) is a
  backstop, not the mechanism: an artifact candidate is one where the
  canvas IS the deliverable, so there is nothing to create.

  `create_task/2` goes through `Platform.Tenancy.Lifecycle.ensure_project_writable/1`
  and returns `{:error, :project_archived}` for a frozen project. That
  error is PROPAGATED, and the candidate is left un-closed so the call
  can be retried once the project thaws. Same for a canvas failure.

  ## Options

    * `:project_id` — override the task's project (default: the
      meeting's `project_id`).
    * `:space_id` — override the canvas's space (default: the meeting's
      `chat_space_id` — note `meetings` has NO `space_id` column; the
      chat space is `chat_space_id`).
    * `:created_by` — canvas creator participant (default: the
      meeting's `host_participant_id`).
    * `:title` / `:description` — deliverable copy; both default from
      the candidate's `evidence_quote`.
    * `:task_attrs` / `:canvas_attrs` — merged last over the built
      attrs for a caller with better context.

  Deliberately NOT wired into any LiveView, dispatcher tick or PubSub
  broadcast: this is a context function, and the board that calls it is
  a separate ticket.
  """
  @spec graduate(MeetingCandidate.t() | binary(), keyword() | map()) ::
          {:ok, MeetingCandidate.t()} | {:error, term()}
  def graduate(candidate_or_id, opts \\ []) do
    opts = Map.new(opts)

    with {:ok, candidate} <- fetch(candidate_or_id),
         {:ok, deliverable} <- mint(candidate, candidate.outcome_kind, opts),
         {:ok, candidate} <- record_deliverable(candidate, deliverable),
         {:ok, candidate} <- record_disposition(candidate, :accepted),
         {:ok, candidate} <- advance(candidate, :closed, %{closed_reason: :done}) do
      {:ok, candidate}
    end
  end

  # The one difference between the two kinds.
  defp mint(candidate, :task, opts) do
    meeting = meeting_for(candidate)

    attrs =
      %{
        project_id: Map.get(opts, :project_id) || meeting_field(meeting, :project_id),
        title: deliverable_title(candidate, opts),
        description: Map.get(opts, :description) || candidate.evidence_quote
      }
      |> Map.merge(Map.get(opts, :task_attrs, %{}))

    with {:ok, task} <- Platform.Tasks.create_task(attrs) do
      {:ok, {:task_id, task.id}}
    end
  end

  defp mint(candidate, :artifact, opts) do
    meeting = meeting_for(candidate)

    attrs =
      %{
        space_id: Map.get(opts, :space_id) || meeting_field(meeting, :chat_space_id),
        created_by: Map.get(opts, :created_by) || meeting_field(meeting, :host_participant_id),
        title: deliverable_title(candidate, opts)
      }
      |> Map.merge(Map.get(opts, :canvas_attrs, %{}))

    with {:ok, canvas} <- Platform.Chat.create_canvas(attrs) do
      {:ok, {:canvas_id, canvas.id}}
    end
  end

  defp record_deliverable(candidate, {column, id}) do
    candidate
    |> MeetingCandidate.changeset(%{column => id})
    |> Repo.update()
  end

  defp deliverable_title(candidate, opts) do
    Map.get(opts, :title) || truncate(candidate.evidence_quote) || "Meeting candidate"
  end

  defp truncate(nil), do: nil

  defp truncate(text) when is_binary(text) do
    if String.length(text) > 120, do: String.slice(text, 0, 117) <> "...", else: text
  end

  defp meeting_for(%MeetingCandidate{meeting_id: meeting_id}) when is_binary(meeting_id) do
    Repo.get(Platform.Meetings.Meeting, meeting_id)
  end

  defp meeting_for(_), do: nil

  defp meeting_field(nil, _field), do: nil
  defp meeting_field(meeting, field), do: Map.get(meeting, field)

  # ── queue-status mapping ──────────────────────────────────────────────────

  @doc """
  The lifecycle state a `Platform.Meetings.IntentQueue.Server` status
  corresponds to, or nil for an unrecognised status.

  Mirroring is a recording act: an unknown status returns nil rather
  than raising, so a newly-added queue status degrades the board's
  state column instead of crashing the mirror.
  """
  @spec queue_status_to_state(atom() | String.t() | nil) :: atom() | nil
  def queue_status_to_state(status), do: lookup(@queue_state_map, status)

  @doc """
  The disposition a queue status implies, or nil when it implies none.

  `:queued` / `:dispatched` / `:acked` return nil — an in-flight
  candidate has no disposition yet, and defaulting one is how a corpus
  of 100% negatives gets built.
  """
  @spec queue_status_to_disposition(atom() | String.t() | nil) :: atom() | nil
  def queue_status_to_disposition(status), do: lookup(@queue_disposition_map, status)

  @doc """
  The `closed_reason` a terminal queue status implies, or nil for a
  non-terminal one.
  """
  @spec queue_status_to_closed_reason(atom() | String.t() | nil) :: atom() | nil
  def queue_status_to_closed_reason(status), do: lookup(@queue_closed_reason_map, status)

  defp lookup(map, status) when is_atom(status) and not is_nil(status), do: Map.get(map, status)

  defp lookup(map, status) when is_binary(status) do
    Map.get(map, String.to_existing_atom(status))
  rescue
    ArgumentError -> nil
  end

  defp lookup(_map, _status), do: nil

  # ── internals ─────────────────────────────────────────────────────────────

  defp fetch(%MeetingCandidate{} = candidate), do: {:ok, candidate}

  defp fetch(id) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      candidate -> {:ok, candidate}
    end
  end

  defp fetch(_), do: {:error, :not_found}

  # Callers inside this module always build atom-keyed attrs; a
  # string-keyed map from a LiveView form is normalised rather than
  # mixed, which `cast/3` rejects.
  defp atomize(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  # Caller-supplied org wins; an absent key OR an explicit nil is
  # derived. Delegates the join to IntentCorrections rather than
  # duplicating it.
  defp put_derived_org_id(attrs) do
    case Map.get(attrs, :org_id) || Map.get(attrs, "org_id") do
      org_id when is_binary(org_id) ->
        attrs

      _ ->
        derived = IntentCorrections.org_id_for_meeting(fetch_meeting_id(attrs))

        if Map.has_key?(attrs, "meeting_id") do
          Map.put(attrs, "org_id", derived)
        else
          Map.put(attrs, :org_id, derived)
        end
    end
  end

  defp fetch_meeting_id(attrs) do
    value = Map.get(attrs, :meeting_id) || Map.get(attrs, "meeting_id")
    if is_binary(value), do: value, else: nil
  end
end
