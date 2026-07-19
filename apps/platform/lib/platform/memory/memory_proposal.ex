defmodule Platform.Memory.MemoryProposal do
  @moduledoc """
  Ecto schema for a parsed `<synthesis-proposal>` block persisted from a
  journal write.

  See `Platform.Memory.Proposals` for the write/read API and the
  ingestion pipeline. Rows are the durable representation of the
  Historian's dreaming synthesis suggestions — the `/memory/proposals`
  LiveView reads from this table, and Rowan's approve / reject actions
  status-flip rows here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(recurring-theme cross-project-pattern emerging-risk stale-fact-candidate-retirement strategic-insight unresolved-question)
  @confidences ~w(high medium low)
  @statuses ~w(pending approved rejected expired)
  @default_ttl_days 7

  @type t :: %__MODULE__{}

  schema "memory_proposals" do
    field(:workspace_id, :binary_id)
    field(:journal_path, :string)
    field(:block_hash, :string)
    field(:category, :string)
    field(:confidence, :string)
    field(:evidence, :string)
    field(:body, :string)
    field(:status, :string, default: "pending")
    field(:feedback, :string)
    field(:expires_at, :utc_datetime_usec)
    # Filled at ingest time by `Platform.Memory.Proposals` — the wiki
    # page an approved proposal's body promotes into. Nullable so
    # rows inserted before the column landed still work: the promotion
    # pipeline falls back to `derive_target_page_key/3` when this is nil.
    field(:target_page_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(journal_path block_hash category confidence body)a
  @optional ~w(workspace_id evidence status feedback expires_at target_page_key)a

  @doc "Enumerated `category` values."
  def categories, do: @categories

  @doc "Enumerated `confidence` values."
  def confidences, do: @confidences

  @doc "Enumerated `status` values."
  def statuses, do: @statuses

  @doc "Default TTL in days from insertion to expiry."
  def default_ttl_days, do: @default_ttl_days

  @doc """
  Full changeset used for the initial insert.

  Enforces category/confidence/status inclusion and computes a default
  `expires_at` of `now + 7 days` when the caller didn't supply one.
  """
  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:confidence, @confidences)
    |> validate_inclusion(:status, @statuses)
    |> put_default_expires_at()
    |> unique_constraint([:workspace_id, :block_hash],
      name: :memory_proposals_workspace_id_block_hash_index
    )
  end

  @doc """
  Narrow changeset for status transitions (approve/reject/expire).

  Only permits mutating `:status` + `:feedback` — the ingestion columns
  are immutable once written.
  """
  def status_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:status, :feedback])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  defp put_default_expires_at(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        # Anchor to the changeset's `inserted_at` when present; otherwise
        # fall back to now. Tests seeding rows with a specific
        # `inserted_at` (e.g. 8 days ago) rely on this anchor to get an
        # expires_at that reflects the intended age.
        anchor = get_field(changeset, :inserted_at) || DateTime.utc_now()

        put_change(
          changeset,
          :expires_at,
          DateTime.add(anchor, @default_ttl_days * 86_400, :second)
        )

      _existing ->
        changeset
    end
  end
end
