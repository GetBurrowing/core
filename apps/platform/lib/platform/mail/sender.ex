defmodule Platform.Mail.Sender do
  @moduledoc """
  An account-level dispatch address (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6).

  A sender is keyed by `key` within its account — `"ops"`, `"agents"` — and
  names the From address and display name mail goes out under. There are no
  per-agent addresses. `Platform.Mail.resolve_sender/3` resolves an exact
  `(account_id, key)` pair and never falls back to another sender.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mail_senders" do
    belongs_to(:account, Platform.Mail.Account)
    field(:key, :string)
    field(:address, :string)
    field(:display_name, :string)

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = sender, attrs) do
    sender
    |> cast(attrs, [:key, :address, :display_name])
    |> validate_required([:key, :address])
    |> validate_length(:key, min: 1, max: 64)
    |> validate_format(:address, ~r/^[^\s@]+@[^\s@]+$/)
    |> unique_constraint([:account_id, :key])
    |> foreign_key_constraint(:account_id)
  end
end
