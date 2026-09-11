defmodule Platform.Meetings.MeetingCandidate do
  @moduledoc """
  Schema for `meeting_candidates` — the durable candidate-lifecycle
  store (task 01a03fb8 stage 1).

  One row per thing a meeting produced that might become work. The row
  tracks that thing's arc: `:heard` in the transcript, `:thinking` while
  the classifier considers it, `:shaping` as it becomes a concrete
  deliverable, `:acting` once a runtime is on it, `:closed` when it is
  over. The row outlives the meeting; the intent queue that fed it does
  not.

  ## Why this is durable when the queue is not

  The intent queue is meeting-lifetime ETS state that dies with its
  owning GenServer. This table is the deliberate exception, for the same
  reason `Platform.Meetings.IntentCorrection` is: the measurement this
  ticket exists to serve — accepted vs rejected, by kind, per org — is a
  question about meetings that already ended. `evidence_quote` is
  denormalized in for the same reason: by the time anyone reads a
  candidate, the ETS row that carried the utterance is gone.

  ## Enums

    * `state` — the coarse lifecycle the board renders.
    * `outcome_kind` — whether the deliverable is a task or an artifact.
    * `closed_reason` — why a closed candidate closed. `:unclassified`
      is the reason for a card that closed without ever receiving a
      classifier answer (an orphaned skeleton, or an empty press).
    * `disposition` — the measurement axis: did a human accept it,
      reject it, or did it simply expire unanswered.

  `queue_status` is deliberately a plain string, not an `Ecto.Enum`: it
  is a verbatim echo of whatever `Platform.Meetings.IntentQueue` status
  the stage-3 mirror last observed, kept so a measurement query can
  still distinguish `:timed_out` from `:dispatch_failed` from
  `:no_ack_spawn_failed` after the queue is gone. Mirroring is a
  recording act, and a recording that refuses an unrecognised value
  would drop exactly the new status somebody wants to measure.

  ## Threading columns (task 01a03fb9 stage 1)

  `speaker`, `last_utterance_at` and `threading_events` exist so a later
  stage can decide whether an incoming utterance CONTINUES this candidate
  or starts a new one. Nothing threads yet; these are the slots.

    * `speaker` — the transcript's attribution for the utterance that
      created the row. **nil means unattributed**, and that matters: the
      classifier answers `""` for an unknown speaker, so the mirror
      normalises `""` to nil on the way in. A same-speaker rule comparing
      two empty strings would read them as the same person and thread two
      strangers together; nil is the value that cannot match itself.
    * `last_utterance_at` — deliberately NOT `heard_at`. `heard_at`
      stamps first sight and never moves; this one moves every time an
      utterance attaches, and it is what a time-window rule reads. They
      start equal at enqueue and diverge from the first attachment on.
    * `threading_events` — an append-only jsonb array, one entry per
      threading decision, recording the REASON the rule fired and not
      merely that it did. Attaching to the wrong candidate is the
      failure this feature is warned about, and it is only diagnosable
      afterwards if the reason was written down next to the result.

  ## Countdown columns (task 01a03fba)

  `acts_at` is WHEN this candidate graduates on its own, and `nil` is
  the disarmed state — a stopped card and a card opened while the
  meeting's automation is off are both nil. It is deliberately not
  `last_utterance_at`: that column is a measurement (when we last heard
  something), this one is a decision (when we will act), and the stop
  button would otherwise have to corrupt a measurement to say "never".

  `closed_by_participant_id` names the human who pressed stop. Before it
  the only attribution slot was `closed_note`, a free string — which
  records that somebody typed a name, not that a participant acted.
  Machine closes (the retraction gate, a queue cancellation, the
  sweeper's own `:done`) leave it nil, so a non-nil value means exactly
  one thing: a person took responsibility for this card.

  ## Cross-field rules

  1. A `:closed` candidate must carry a `closed_reason`. A closed card
     with no reason is precisely the row the board cannot render.
  2. An `:artifact` candidate must not carry a `task_id` — its
     deliverable is the canvas.
  3. A `:task` candidate MAY carry a `canvas_id`. This is deliberately
     NOT the mirror image of rule 2: a task candidate can legitimately
     have produced a supporting canvas along the way, so the asymmetry
     is the point and must not be "tidied" into symmetry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:heard, :thinking, :shaping, :acting, :closed]

  @outcome_kinds [:task, :artifact]

  @closed_reasons [:retracted, :duplicate, :vetoed, :done, :dismissed, :unclassified]

  @dispositions [:accepted, :rejected, :timed_out]

  schema "meeting_candidates" do
    field(:meeting_id, :binary_id)
    field(:org_id, :binary_id)
    field(:room_id, :binary_id)

    field(:intent_id, :binary_id)

    field(:transcript_chunk_id, :binary_id)
    field(:transcript_chunk_ids, {:array, :binary_id}, default: [])

    field(:evidence_quote, :string)

    field(:state, Ecto.Enum, values: @states, default: :heard)
    field(:outcome_kind, Ecto.Enum, values: @outcome_kinds, default: :task)

    field(:assigned_agent_id, :binary_id)
    field(:assigned_agent_slug, :string)
    field(:target_role, :string)

    field(:task_id, :binary_id)
    field(:canvas_id, :binary_id)

    field(:closed_reason, Ecto.Enum, values: @closed_reasons)
    field(:closed_note, :string)
    field(:closed_at, :utc_datetime_usec)

    # The participant who pressed stop (task 01a03fba). See the
    # moduledoc's countdown section.
    field(:closed_by_participant_id, :binary_id)

    field(:classified_intent, :string)
    field(:classifier_confidence, :float)
    field(:classifier_model, :string)

    # The intent the evidence gate DOWNGRADED to `off_topic`, or nil
    # when `classified_intent` is the model's own answer (task 01a06575).
    #
    # The demotion preserves the model's confidence, so without this
    # column a demoted row and a genuine decline are byte-identical:
    # same `classified_intent`, same `target_role`, same
    # `classifier_confidence`. `demoted_from IS NULL` is therefore the
    # ONLY thing that says "the model meant this".
    field(:demoted_from, :string)

    field(:disposition, Ecto.Enum, values: @dispositions)
    field(:disposition_at, :utc_datetime_usec)

    field(:queue_status, :string)

    # Threading (task 01a03fb9 stage 1). See the moduledoc section.
    field(:speaker, :string)
    field(:last_utterance_at, :utc_datetime_usec)
    field(:threading_events, {:array, :map}, default: [])

    # Countdown (task 01a03fba). See the moduledoc section.
    field(:acts_at, :utc_datetime_usec)

    field(:heard_at, :utc_datetime_usec)
    field(:dispatched_at, :utc_datetime_usec)
    field(:acted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every valid `state` value."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "Every valid `outcome_kind` value."
  @spec outcome_kinds() :: [atom()]
  def outcome_kinds, do: @outcome_kinds

  @doc "Every valid `closed_reason` value."
  @spec closed_reasons() :: [atom()]
  def closed_reasons, do: @closed_reasons

  @doc "Every valid `disposition` value."
  @spec dispositions() :: [atom()]
  def dispositions, do: @dispositions

  @cast_fields ~w(meeting_id org_id room_id intent_id transcript_chunk_id
                  transcript_chunk_ids evidence_quote state outcome_kind
                  assigned_agent_id assigned_agent_slug target_role task_id
                  canvas_id closed_reason closed_note closed_at
                  classified_intent classifier_confidence classifier_model
                  demoted_from
                  disposition disposition_at queue_status speaker
                  last_utterance_at threading_events acts_at
                  closed_by_participant_id heard_at
                  dispatched_at acted_at)a

  @required_fields ~w(meeting_id state outcome_kind)a

  @doc """
  Changeset for a candidate row.

  `Ecto.Enum` already rejects out-of-set values on the four enum
  columns, so there is no `validate_inclusion/3` here duplicating it.
  `org_id` is deliberately NOT required — it is derived in stage 2, and
  a candidate whose org linkage cannot be resolved still deserves its
  row (it is simply invisible to the org-scoped measurement query until
  backfilled).
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_closed_has_reason()
    |> validate_artifact_has_no_task()
    |> unique_constraint(:intent_id)
  end

  defp validate_closed_has_reason(changeset) do
    case {get_field(changeset, :state), get_field(changeset, :closed_reason)} do
      {:closed, nil} ->
        add_error(
          changeset,
          :closed_reason,
          "a closed candidate must carry a closed_reason"
        )

      _ ->
        changeset
    end
  end

  # Deliberately one-directional — see the moduledoc's rule 3. A :task
  # candidate carrying a canvas_id is legitimate and must stay legal.
  defp validate_artifact_has_no_task(changeset) do
    case {get_field(changeset, :outcome_kind), get_field(changeset, :task_id)} do
      {:artifact, task_id} when not is_nil(task_id) ->
        add_error(
          changeset,
          :task_id,
          "an artifact candidate's deliverable is the canvas; it must not carry a task id"
        )

      _ ->
        changeset
    end
  end
end
