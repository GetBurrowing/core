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
  in this module that sets `closed_reason`. The board renders all four
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

  alias Platform.Meetings.IntentCorrections
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
    |> MeetingCandidate.changeset(put_derived_org_id(attrs))
    |> Repo.insert()
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

    case ThreadResolver.resolve(
           %{speaker: speaker, text: text, at: at},
           open_for_meeting(meeting_id)
         ) do
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
  end

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
        last_utterance_at: at
      })
      |> Repo.update()
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
      end
    end
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
