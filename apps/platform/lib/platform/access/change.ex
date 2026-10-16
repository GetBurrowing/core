defmodule Platform.Access.Change do
  @moduledoc """
  One committed change to `access_grants` (task 01a1386e-30bd stage 1): the
  row `Platform.Access.Changes` writes in the same transaction as the
  mutation it records.

    * `actor_type` / `actor_id` — who made it (`system` has no id);
      `via_agent_id` — the agent runtime that applied it on that human's
      behalf; `bypass` — `"root_admin"` when the install-level bypass
      authorized it.
    * `action` — `grant`, `deny`, `revoke`, `undo` or `system_repoint`.
    * `before` / `after` — `Platform.Access.Grant.snapshot/1` maps of every
      affected row, ordered by id. Undo restores `before` verbatim.
    * `tuple_keys` — `Platform.Access.Grant.tuple_key/1` of every row in
      `before` and `after`. A later change sharing a key supersedes this one.
    * `undoes_change_id` — the change an `undo` reversed.

  This schema compares no effects. Precedence lives only in `Platform.Access`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @actor_types ~w(user agent system)
  @actions ~w(grant deny revoke undo system_repoint)
  @bypasses ~w(root_admin)

  @type t :: %__MODULE__{}

  schema "access_grant_changes" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:actor_type, :string)
    # Ecto.UUID, not :binary_id: a malformed id is a changeset error (and the
    # change rolls back) rather than a raise at dump time.
    field(:actor_id, Ecto.UUID)
    field(:via_agent_id, Ecto.UUID)
    field(:bypass, :string)
    field(:action, :string)
    field(:before, {:array, :map}, default: [])
    field(:after, {:array, :map}, default: [])
    field(:tuple_keys, {:array, :string}, default: [])
    belongs_to(:undoes_change, __MODULE__)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The actions a change may record."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc false
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :org_id,
      :actor_type,
      :actor_id,
      :via_agent_id,
      :bypass,
      :action,
      :before,
      :after,
      :tuple_keys,
      :undoes_change_id
    ])
    |> validate_required([:org_id, :actor_type, :action, :tuple_keys])
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:bypass, @bypasses)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:undoes_change_id)
    |> unique_constraint(:undoes_change_id,
      name: :access_grant_changes_undoes_change_id_index,
      message: "has already been undone"
    )
  end
end
