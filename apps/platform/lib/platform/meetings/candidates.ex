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
  alias Platform.Repo

  # Lifecycle order. Position in this list — not the atom — is what
  # `advance/3` compares, so inserting a state changes the ordering
  # everywhere at once.
  @order [:heard, :thinking, :shaping, :acting, :closed]

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
