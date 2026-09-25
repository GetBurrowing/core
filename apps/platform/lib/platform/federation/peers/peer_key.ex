defmodule Platform.Federation.Peers.PeerKey do
  @moduledoc """
  One public key of a remote install, embedded in `federation_peers.public_keys`
  (task 01a0d90f stage 2, ADR 0054 section 1).

  Each entry carries its own `status` and `valid_until` so the receiving side
  can end a peer's rotation overlap, or retire one compromised peer kid,
  without dropping the relationship. `public_key` is unpadded base64url, the
  descriptor's encoding.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(current previous retired)

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:kid, :string)
    field(:public_key, :string)
    field(:status, :string, default: "current")
    field(:valid_until, :utc_datetime_usec)
    field(:added_at, :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:kid, :public_key, :status, :valid_until, :added_at])
    |> validate_required([:kid, :public_key, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:public_key, fn :public_key, value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, <<_::256>>} -> []
        _ -> [public_key: "must be a 32-byte Ed25519 key in unpadded base64url"]
      end
    end)
  end
end
