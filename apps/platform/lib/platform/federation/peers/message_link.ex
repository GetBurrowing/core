defmodule Platform.Federation.Peers.MessageLink do
  @moduledoc """
  One message that crossed a peer relationship (task 01a0d90f stage 5,
  ADR 0054 section 3).

    * `direction: "inbound"` — the peer's message `remote_message_id`,
      ingested here as `local_message_id`. The row is written as a CLAIM
      (with `local_message_id` nil) before the message is posted, and the
      unique index on `(peer_id, remote_message_id)` makes the claim the
      idempotency guard: a duplicate delivery, including one replayed after
      a `NonceCache` wipe inside the timestamp window, finds the row and
      posts nothing.
    * `direction: "outbound"` — our message `local_message_id`, stored by the
      peer as `remote_message_id` (from the peer's 2xx answer).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "federation_message_links" do
    field(:peer_id, :binary_id)
    field(:local_message_id, :binary_id)
    field(:remote_message_id, Ecto.UUID)
    field(:direction, :string)

    timestamps()
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:peer_id, :local_message_id, :remote_message_id, :direction])
    |> validate_required([:peer_id, :remote_message_id, :direction])
    |> validate_inclusion(:direction, ~w(inbound outbound))
    |> unique_constraint([:peer_id, :remote_message_id])
    |> check_constraint(:direction, name: :federation_message_links_direction_check)
  end
end
