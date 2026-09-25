defmodule Platform.Federation.Peers.SharedSpace do
  @moduledoc """
  A local chat space shared with one peer install (task 01a0d90f stage 5,
  ADR 0054 section 3).

    * `role` — `owner`: this install shared the space and is authoritative
      for it (it sends `message.replicate`). `replica`: the peer shared it and
      this install holds a copy (it sends `message.submit`).
    * `remote_space_id` — the peer's id for the same space. Every relay
      payload names the RECEIVER's space id, so each side resolves an
      incoming message by `(peer_id, local_space_id)` and a peer can reach
      only spaces shared with it.
    * `outbound_cursor_message_id` — the newest local message the peer has
      acknowledged. Advanced only from a 2xx, never optimistically.
    * `status` — `active` or `revoked` (the relationship was revoked).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @roles ~w(owner replica)
  @statuses ~w(active revoked)

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "federation_shared_spaces" do
    field(:peer_id, :binary_id)
    field(:local_space_id, :binary_id)
    field(:remote_space_id, Ecto.UUID)
    field(:role, :string)
    field(:status, :string, default: "active")
    field(:outbound_cursor_message_id, Ecto.UUID)

    timestamps()
  end

  @doc false
  def create_changeset(shared, attrs) do
    shared
    |> cast(attrs, [
      :peer_id,
      :local_space_id,
      :remote_space_id,
      :role,
      :status,
      :outbound_cursor_message_id
    ])
    |> validate_required([:peer_id, :local_space_id, :remote_space_id, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:local_space_id)
    |> unique_constraint([:peer_id, :remote_space_id])
    |> foreign_key_constraint(:peer_id)
    |> foreign_key_constraint(:local_space_id)
    |> check_constraint(:role, name: :federation_shared_spaces_role_check)
    |> check_constraint(:status, name: :federation_shared_spaces_status_check)
  end
end
