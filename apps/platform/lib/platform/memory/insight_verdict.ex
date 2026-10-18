defmodule Platform.Memory.InsightVerdict do
  @moduledoc """
  A human's rejection or flag of an insight: a DURABLE row.

  Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 1. Verdicts outlive the
  insight they judge (`Platform.Memory.Insights.Purger` never touches this
  table). They do two jobs:

    * they are the few-shot exemplars the next dreaming prompt reads
      (`Platform.Memory.Insights.exemplars/1`), so `reason` is required and
      must not be blank: a verdict that does not say why teaches nothing;
    * their `block_hash` is part of the ingest dedup probe, so a rejected
      block never re-ingests.

  `kind` is `rejected` (the insight was wrong before anything happened) or
  `flagged` (it was acted on and a human says it was wrong).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(rejected flagged)
  @origins ~w(dreaming legacy_proposal)

  @type t :: %__MODULE__{}

  schema "memory_insight_verdicts" do
    field(:block_hash, :string)
    field(:kind, :string)
    field(:reason, :string)
    field(:body, :string)
    field(:action_type, :string)
    field(:evidence, :string)
    field(:actor_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:origin, :string, default: "dreaming")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Enumerated `kind` values."
  def kinds, do: @kinds

  @doc """
  Insert changeset. `reason` is trimmed, and a blank one is refused with
  `{:reason, "can't be blank"}`.
  """
  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [
      :block_hash,
      :kind,
      :reason,
      :body,
      :action_type,
      :evidence,
      :actor_id,
      :workspace_id,
      :origin,
      :inserted_at
    ])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:block_hash, :kind, :reason])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:origin, @origins)
    |> check_constraint(:reason, name: :reason_must_not_be_blank)
  end
end
