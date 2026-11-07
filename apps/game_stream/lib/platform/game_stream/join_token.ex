defmodule Platform.GameStream.JoinToken do
  @moduledoc "A hashed, single-use admission and capacity reservation."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "native_join_tokens" do
    field :session_id, :binary_id
    field :user_id, :binary_id
    field :channel_id, :binary_id
    field :build_id, :string
    field :generation, :integer
    field :digest, :string, redact: true
    field :slot, :integer
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :connected, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def mint, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
