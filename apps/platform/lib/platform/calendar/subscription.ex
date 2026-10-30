defmodule Platform.Calendar.Subscription do
  @moduledoc "Owner-only read-only calendar subscription; bearer URLs are encrypted and redacted."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_subscriptions" do
    belongs_to(:owner, Platform.Accounts.User)
    field(:name, :string)
    field(:url, Platform.Vault.EncryptedBinary, redact: true)
    field(:snapshot, {:array, :map}, default: [], redact: true)
    field(:refreshed_at, :utc_datetime_usec)
    field(:attempted_at, :utc_datetime_usec)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:name, :url])
    |> validate_required([:name, :url])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:url, max: 4096)
    |> validate_change(:url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
        when is_binary(host) and host != "" ->
          []

        _ ->
          [url: "must be an HTTPS calendar URL without credentials or a fragment"]
      end
    end)
  end
end
