defmodule Platform.Meetings.MeetingCandidateEvent do
  @moduledoc """
  Schema for `meeting_candidate_events` — one row per lifecycle write a
  candidate actually took (task 01a03fba).

  This is the durable half of the card's activity log. The live half is
  the same struct, broadcast on
  `Platform.Meetings.PubSub.candidate_events_topic/1`, so a rail that
  reloads and a rail that stayed connected are reading the same shape
  sorted by the same column.

  ## The six kinds are the six writes

  There is exactly one kind per `Repo` write in
  `Platform.Meetings.Candidates`, and that correspondence is the whole
  design:

    * `:heard` — a candidate row was inserted. The card appeared.
    * `:threaded` — an utterance attached to an existing card.
    * `:classified` — the classifier's answer landed on a skeleton that
      was opened before it (`record_heard/1`'s row, reconciled).
    * `:advanced` — the lifecycle state moved forward.
    * `:disposition_recorded` — the measurement axis was written.
    * `:closed` — the card closed, for one of the five reasons.

  Nothing derives an event from a state; an event exists because a write
  returned `{:ok, _}`. That is what makes "a candidate that closes early
  shows the gates that ran and no others" a property of the mechanism
  rather than an assertion about the renderer.

  ## `detail` carries what the gate computed, not a re-derivation

  A line saying "threading ran" records that a decision happened and
  loses which rule made it — the same argument
  `meeting_candidates.threading_events` was built on. So `detail` holds
  the gate's own output: the resolver's `reason` map for `:threaded`,
  the pre-update state for `:advanced`, the close reason and note for
  `:closed`. A reader can second-guess the gate from the row; a reader
  of "the gate ran" cannot.

  It is jsonb, so entries are built with STRING keys and JSON-safe
  values at write time (`Platform.Meetings.Candidates` does this through
  its existing `jsonable/1`). An atom written into jsonb comes back a
  string, so a map built with atom keys changes shape across a round
  trip — the live broadcast would match and the reloaded row would not,
  which is precisely the divergence this table exists to rule out.

  ## `seq` is read after write

  Postgres assigns it. `read_after_writes: true` means the inserted
  struct carries the real value, so the broadcast and the row agree —
  without it the live listener would see `nil` where the reload sees an
  ordinal, and no consumer could merge the two.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:heard, :threaded, :classified, :advanced, :disposition_recorded, :closed]

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "meeting_candidate_events" do
    # Assigned by Postgres, never by us. See moduledoc.
    field(:seq, :integer, read_after_writes: true)

    field(:meeting_id, :binary_id)
    field(:candidate_id, :binary_id)
    field(:org_id, :binary_id)

    field(:kind, Ecto.Enum, values: @kinds)
    field(:detail, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The event kinds, in no particular order — see the moduledoc for what each means."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Build an event.

  `meeting_id`, `candidate_id` and `kind` are all required: an event
  that cannot name the card it is about is a line the board cannot
  place, and an event with no kind is the hardcoded log this ticket
  exists to remove.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:meeting_id, :candidate_id, :org_id, :kind, :detail])
    |> validate_required([:meeting_id, :candidate_id, :kind])
  end
end
