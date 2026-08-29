defmodule Platform.Meetings.CandidateEvents do
  @moduledoc """
  The candidate activity log (task 01a03fba) — write one line, broadcast
  the same line.

  Stage 2 of the meeting card shows a short "thinking" log:
  *"re-reading the last few minutes"*, *"checking if this was
  retracted"*. Written into the template those lines are a progress bar
  that lies — identical whether the gate ran, failed, or never fired.
  This module is the producer that makes them real.

  ## What was missing, precisely

  `Platform.Meetings.PubSub` broadcasts nine `intent_*` events on
  `intents_topic/1`, and it is easy to mistake them for this. They are
  not. Their payload is an `IntentQueue` row map and they narrate that
  ROW's nine statuses. The candidate is a different record, written by
  `Platform.Meetings.Candidates`, and before this module it emitted
  nothing at all — no `Phoenix.PubSub` call and no telemetry anywhere in
  `candidates.ex`, and `IntentClassifier` only ever subscribes.

  Since `5b507f92` the candidate row is opened at ARRIVAL by
  `Candidates.record_heard/1`, before classification, so a whole
  sequence now runs against a card that no intent row exists for yet:
  the retraction gate `58a19028` added, the threading resolver, and
  every close on `:parse_error`, `:model_error`, `:empty_output` or a
  dedupe hit. None of those could ever produce an `intent_*` event,
  because there is no intent.

  ## One write, one broadcast, or neither

  `record/3` inserts and then broadcasts the inserted struct. It never
  broadcasts a line it failed to persist, because the two acceptance
  properties are a pair: *the log survives a reload* and *two
  participants see the same sequence*. A broadcast without a row makes a
  connected rail show a line that a reloading rail cannot, which is the
  same class of untruth as the hardcoded template.

  ## Failure is recorded, not raised

  A failed insert logs and returns `{:error, changeset}`. Writing an
  activity line is a recording act — the same posture
  `IntentQueue.Server`'s mirror and `IntentClassifier`'s
  `record_heard/5` wrapper take — and losing a card because its log line
  would not write is a strictly worse outcome than a log with a hole.

  That is safe here in a way it would not be for the mirror, because
  the suite does not read this module's success from a silence. Every
  test asserts the event — a received broadcast or a reloaded row — so a
  swallowed failure turns those assertions RED. The failure mode
  `1458e2f0` armed the mirror against (a suite that wrote nothing and
  passed) is not reachable for a producer whose tests assert the
  product.

  ## Reads are ordered by `seq`, never by `inserted_at`

  `close/2` immediately after `record_disposition/3` lands both inside
  one microsecond on the classifier's `close_skeleton/4` path. `seq` is
  the bigserial Postgres assigns; it is the only strict order these
  rows have, and it is what the broadcast payload carries too so a live
  listener can merge into a reloaded list.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Platform.Meetings.MeetingCandidateEvent
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @doc """
  Record one lifecycle event against a candidate and broadcast it.

  `candidate` is the row AFTER the write that occasioned the event, so
  `meeting_id` and `org_id` come off it rather than being passed
  separately and risking disagreement with the row.

  `detail` must already be JSON-safe — the column is jsonb, and an atom
  written into it comes back a string, so a map built with atom keys
  would match a live subscriber's pattern and fail the reloading one.
  `Platform.Meetings.Candidates` normalises through its existing
  `jsonable/1` before calling here.
  """
  @spec record(struct(), atom(), map()) ::
          {:ok, MeetingCandidateEvent.t()} | {:error, Ecto.Changeset.t() | :no_meeting_id}
  def record(candidate, kind, detail \\ %{})

  def record(%{id: candidate_id, meeting_id: meeting_id} = candidate, kind, detail)
      when is_binary(meeting_id) and is_atom(kind) and is_map(detail) do
    %MeetingCandidateEvent{}
    |> MeetingCandidateEvent.changeset(%{
      meeting_id: meeting_id,
      candidate_id: candidate_id,
      org_id: Map.get(candidate, :org_id),
      kind: kind,
      detail: detail
    })
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        MeetingsPubSub.broadcast_candidate_event(meeting_id, event)
        {:ok, event}

      {:error, changeset} ->
        Logger.warning(
          "meeting candidate event write failed: candidate=#{candidate_id} " <>
            "kind=#{kind} errors=#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # A candidate whose meeting_id is not a binary cannot be placed on any
  # rail. `Candidates.create/1` requires `meeting_id`, so this is
  # unreachable from production; it exists so a hand-built struct in a
  # test fails loudly at the log rather than at a `Phoenix.PubSub`
  # topic interpolation three frames later.
  def record(candidate, kind, _detail) do
    Logger.warning(
      "meeting candidate event skipped, no meeting_id: " <>
        "candidate=#{inspect(Map.get(candidate, :id))} kind=#{inspect(kind)}"
    )

    {:error, :no_meeting_id}
  end

  @doc """
  Every event for one candidate, oldest first. This is the card's log.
  """
  @spec list_for_candidate(binary() | nil) :: [MeetingCandidateEvent.t()]
  def list_for_candidate(nil), do: []

  def list_for_candidate(candidate_id) when is_binary(candidate_id) do
    if Platform.UUID.valid?(candidate_id) do
      MeetingCandidateEvent
      |> where([e], e.candidate_id == ^candidate_id)
      |> order_by([e], asc: e.seq)
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Every event for one meeting, oldest first — the whole rail, and what a
  board mounting mid-meeting hydrates from.
  """
  @spec list_for_meeting(binary() | nil) :: [MeetingCandidateEvent.t()]
  def list_for_meeting(nil), do: []

  def list_for_meeting(meeting_id) when is_binary(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      MeetingCandidateEvent
      |> where([e], e.meeting_id == ^meeting_id)
      |> order_by([e], asc: e.seq)
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  The ordered `kind` sequence for one candidate.

  A convenience for the assertion this feature actually has to support —
  "a candidate that closes early shows the gates that ran and no others"
  is a claim about this list.
  """
  @spec kinds_for_candidate(binary() | nil) :: [atom()]
  def kinds_for_candidate(candidate_id) do
    candidate_id |> list_for_candidate() |> Enum.map(& &1.kind)
  end
end
