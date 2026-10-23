defmodule Platform.Memory.Insight do
  @moduledoc """
  Ecto schema for one parsed `<synthesis-insight>` block: an EPHEMERAL row.

  Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 1. A row lives until
  `expires_at` and is then hard-deleted by `Platform.Memory.Insights.Purger`,
  whatever its `state`. The durable remains of an insight are its artefact
  (`artefact_ref`, once acted on) and any human verdict on it
  (`Platform.Memory.InsightVerdict`).

  See `Platform.Memory.Insights` for the API and
  `Platform.Memory.Insights.Parser` for the block grammar.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @action_types ~w(page_edit briefing question task)
  @confidences ~w(high medium low)
  @states ~w(open done dismissed)
  @origins ~w(dreaming legacy_proposal)
  @tiers ~w(reversible needs_call)
  @default_ttl_days 7

  @type t :: %__MODULE__{}

  schema "memory_insights" do
    field(:workspace_id, :binary_id)
    field(:org_id, :binary_id)
    field(:journal_path, :string)
    field(:block_hash, :string)
    field(:run_id, :binary_id)
    field(:action_type, :string)
    field(:confidence, :string)
    field(:evidence, :string)
    field(:source_ref, :string)
    field(:body, :string)
    field(:action, :map, default: %{})
    field(:addressee_user_id, :binary_id)
    field(:addressee_reason, :string)
    field(:tier, :string)
    field(:downgraded_from, :string)
    field(:state, :string, default: "open")
    field(:acted_by, :binary_id)
    field(:acted_at, :utc_datetime_usec)
    field(:artefact_ref, :string)
    field(:pre_image, :map)
    field(:delivered_at, :utc_datetime_usec)
    field(:disseminable, :boolean, default: false)
    field(:origin, :string, default: "dreaming")
    field(:expires_at, :utc_datetime_usec)
    # Who wrote the block (task 01a15587 stage 2): the journal entry's
    # `authored_by`, an agent id OR a user id, nil when unknown. No foreign
    # key: it is only compared for equality with the `memory.dreaming`
    # holder (`Platform.Memory.Insights.Unattended.eligible?/1`), never
    # joined on.
    field(:authored_by, :binary_id)
    # In memory only (task 01a15ee1 stage 2): set by the Disseminator on a
    # `task` insight `apply_unattended/2` could not file because no project
    # was inferred (`{:error, :no_project}`). The briefing renders it with a
    # project picker. Never written.
    field(:needs_project, :boolean, virtual: true, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(journal_path block_hash run_id action_type confidence body)a
  @optional ~w(workspace_id org_id evidence source_ref action addressee_user_id addressee_reason
               tier downgraded_from state acted_by acted_at artefact_ref pre_image delivered_at
               disseminable origin expires_at inserted_at authored_by)a

  @doc "Enumerated `action_type` values."
  def action_types, do: @action_types

  @doc "Enumerated `confidence` values, strongest first."
  def confidences, do: @confidences

  @doc "Enumerated `state` values."
  def states, do: @states

  @doc "Enumerated `origin` values."
  def origins, do: @origins

  @doc "Enumerated `tier` values (task 01a13867 stage 2)."
  def tiers, do: @tiers

  @doc "Default TTL in days from insertion to expiry."
  def default_ttl_days, do: @default_ttl_days

  @doc """
  Insert changeset. Validates the enums and fills `expires_at` with
  `inserted_at` (or now) plus the default TTL when the caller gave none.
  """
  def changeset(insight, attrs) do
    insight
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:action_type, @action_types)
    |> validate_inclusion(:confidence, @confidences)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:tier, @tiers)
    |> put_default_expires_at()
    |> unique_constraint([:workspace_id, :block_hash],
      name: :memory_insights_workspace_id_block_hash_index
    )
  end

  @doc """
  Outcome changeset: only the fields an outcome writes. The ingested
  columns are immutable.
  """
  def outcome_changeset(insight, attrs) do
    insight
    |> cast(attrs, [:state, :acted_by, :acted_at, :artefact_ref, :pre_image])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
  end

  @doc """
  Routing changeset (task 01a13867 stage 2): who the insight is for and its
  re-checked tier. Written by Reroute and Edit, never by an outcome.
  """
  def routing_changeset(insight, attrs) do
    insight
    |> cast(attrs, [:addressee_user_id, :addressee_reason, :tier, :action, :body])
    |> validate_required([:body])
    |> validate_inclusion(:tier, @tiers)
  end

  @doc """
  Downgrade changeset (task 01a15587 stage 2): rewrites an open `page_edit`
  whose source no longer resolves into the `question`
  `Platform.Memory.Insights.Grounding.ground/1` produces, at execute time.
  Written only by `Platform.Memory.Insights.Actions.apply_unattended/2`.
  """
  def downgrade_changeset(insight, attrs) do
    insight
    |> cast(attrs, [
      :action_type,
      :downgraded_from,
      :body,
      :action,
      :addressee_user_id,
      :addressee_reason,
      :tier,
      :disseminable
    ])
    |> validate_required([:action_type, :body])
    |> validate_inclusion(:action_type, @action_types)
    |> validate_inclusion(:tier, @tiers)
  end

  @doc """
  Delivery changeset (task 01a13867 stage 3): stamps `delivered_at` when the
  insight first appears in a daily briefing. Written only by
  `Platform.Memory.Insights.mark_delivered/2`.
  """
  def delivery_changeset(insight, attrs) do
    insight
    |> cast(attrs, [:delivered_at])
    |> validate_required([:delivered_at])
  end

  defp put_default_expires_at(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        anchor = get_field(changeset, :inserted_at) || DateTime.utc_now()
        put_change(changeset, :expires_at, DateTime.add(anchor, @default_ttl_days, :day))

      _existing ->
        changeset
    end
  end
end
