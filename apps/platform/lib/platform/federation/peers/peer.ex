defmodule Platform.Federation.Peers.Peer do
  @moduledoc """
  A remote install this install has (or is negotiating) a federation
  relationship with (task 01a0d90f stage 2, ADR 0054).

  Status vocabulary:

    * `pending_outbound` — we proposed; waiting for the peer to accept.
    * `pending_inbound` — the peer proposed; waiting for a local admin.
    * `active` — both sides accepted.
    * `revoked` — terminal. `revoked_by` says which side ended it.

  Transitions live in `Platform.Federation.Peers`; this schema only validates
  shape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Federation.Peers.PeerKey

  @statuses ~w(pending_outbound pending_inbound active revoked)
  @revoked_by ~w(local peer)

  @type t :: %__MODULE__{}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "federation_peers" do
    field(:peer_install_id, Ecto.UUID)
    field(:base_url, :string)
    field(:display_name, :string)
    embeds_many(:public_keys, PeerKey, on_replace: :delete)
    field(:status, :string)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by, :string)
    field(:accepted_by_user_id, :binary_id)
    field(:last_seen_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def statuses, do: @statuses

  @doc false
  def create_changeset(peer, attrs) do
    peer
    |> cast(attrs, [:peer_install_id, :base_url, :display_name, :status, :metadata])
    |> cast_embed(:public_keys, with: &PeerKey.changeset/2)
    |> validate_required([:peer_install_id, :base_url, :status])
    |> validate_inclusion(:status, ~w(pending_outbound pending_inbound))
    |> validate_base_url()
    |> unique_constraint(:peer_install_id)
    |> check_constraint(:status, name: :federation_peers_status_check)
  end

  @doc false
  def update_changeset(peer, attrs) do
    peer
    |> cast(attrs, [
      :display_name,
      :status,
      :revoked_at,
      :revoked_by,
      :accepted_by_user_id,
      :last_seen_at,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:revoked_by, @revoked_by)
    |> check_constraint(:status, name: :federation_peers_status_check)
    |> check_constraint(:revoked_by, name: :federation_peers_revoked_by_check)
  end

  @doc false
  def keys_changeset(peer, keys) do
    peer
    |> change()
    |> put_embed(:public_keys, keys)
  end

  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [base_url: "must be an absolute http(s) URL"]
      end
    end)
  end
end
