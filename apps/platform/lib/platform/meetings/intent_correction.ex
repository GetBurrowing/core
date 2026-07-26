defmodule Platform.Meetings.IntentCorrection do
  @moduledoc """
  Schema for `meeting_intent_corrections` — the durable few-shot corpus
  behind the intent-queue live-tuning loop (task 019f70b8 stage 6).

  One row per time somebody (a human producer via the stage-7 X/pencil,
  or the runtime itself via a rejected ack) told us the classifier got
  an intent wrong. Rows are read back by
  `Platform.Meetings.IntentCorrections.recent_exemplars/2` and injected
  into the `meetings.intent_classify.v1` prompt as few-shot exemplars,
  and are the seed corpus for an eventual fine-tune.

  ## Why this is durable when the queue is not

  The intent queue is meeting-lifetime ETS state that dies with its
  owning GenServer. This table is the deliberate exception: an exemplar
  that vanished with the meeting would teach nothing. `transcript_chunk_excerpt`
  is denormalized in for the same reason — by the time anyone reads the
  corpus, the ETS row that carried the utterance is gone.

  ## Enums

    * `dispatch_outcome` — where the intent had got to when the
      correction was made. `nil` when it never left the queue (a
      `:queued` row pulled by the producer). The values mirror the
      queue's terminal + in-flight statuses, and the distinctions are
      load-bearing for tuning: a correction after `:timed_out` (nobody
      answered) means something different from one after
      `:dispatch_failed` (we never reached a runtime) or
      `:no_ack_spawn_failed` (the runtime answered but could not spawn).
      `:cancelled_late` likewise is a race, not a misclassification.
    * `correction` — `:removed_no_action` (the intent should not have
      existed) vs `:corrected` (it should have existed, differently).
    * `reason` — the producer's stated cause.

  ## The one cross-field rule

  A `:corrected` row that names neither a `corrected_intent` nor a
  `corrected_target_agent_id` records that something was wrong without
  recording what right looks like — it is an exemplar with no target
  and would train the model on nothing. `changeset/2` rejects it.
  `:removed_no_action` carries no such requirement: "this should not
  have been an intent at all" is complete on its own.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @dispatch_outcomes [
    :dispatched,
    :acked,
    :completed,
    :cancelled,
    :cancelled_late,
    :timed_out,
    :dispatch_failed,
    :no_ack_spawn_failed
  ]

  @corrections [:removed_no_action, :corrected]

  @reasons [:wrong_intent, :wrong_target, :not_actionable, :other]

  schema "meeting_intent_corrections" do
    field(:meeting_id, :binary_id)
    field(:org_id, :binary_id)

    field(:transcript_chunk_excerpt, :string)

    field(:classified_intent, :string)
    field(:classified_target_agent_id, :binary_id)

    field(:dispatch_outcome, Ecto.Enum, values: @dispatch_outcomes)
    field(:correction, Ecto.Enum, values: @corrections)

    field(:corrected_intent, :string)
    field(:corrected_target_agent_id, :binary_id)

    field(:reason, Ecto.Enum, values: @reasons)

    field(:actor_participant_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every valid `dispatch_outcome` value."
  @spec dispatch_outcomes() :: [atom()]
  def dispatch_outcomes, do: @dispatch_outcomes

  @doc "Every valid `correction` value."
  @spec corrections() :: [atom()]
  def corrections, do: @corrections

  @doc "Every valid `reason` value."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @cast_fields ~w(meeting_id org_id transcript_chunk_excerpt classified_intent
                  classified_target_agent_id dispatch_outcome correction
                  corrected_intent corrected_target_agent_id reason
                  actor_participant_id)a

  @required_fields ~w(meeting_id classified_intent correction reason)a

  @doc """
  Changeset for a correction row.

  `Ecto.Enum` already rejects out-of-set values on `dispatch_outcome`,
  `correction` and `reason`, so there is no `validate_inclusion/3` here
  duplicating it. `actor_participant_id` is deliberately NOT required —
  the AC14 auto-writes have no human actor.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(correction, attrs) do
    correction
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_correction_target()
  end

  defp validate_correction_target(changeset) do
    case get_field(changeset, :correction) do
      :corrected ->
        if get_field(changeset, :corrected_intent) ||
             get_field(changeset, :corrected_target_agent_id) do
          changeset
        else
          add_error(
            changeset,
            :correction,
            "a :corrected row must carry a corrected_intent or a corrected_target_agent_id"
          )
        end

      _ ->
        changeset
    end
  end
end
