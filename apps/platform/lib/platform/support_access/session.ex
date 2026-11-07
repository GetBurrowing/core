defmodule Platform.SupportAccess.Session do
  @moduledoc """
  One granted vendor support session (`support_sessions`, task 01a1b362
  stage 1, ADR 0059). `kind` is `admin` (a browser session as an install
  admin) or `repair` (a root shell on the host, admitted by the host's sshd
  through the state file). A session is ACTIVE while `ended_at` is nil and
  now is before `not_after`; nothing else makes it active.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(admin repair)
  @end_reasons ~w(expired ended_by_owner access_turned_off)

  @type t :: %__MODULE__{}

  schema "support_sessions" do
    field(:kind, :string)
    field(:operator_name, :string)
    field(:operator_email, :string)
    belongs_to(:user, Platform.Accounts.User)
    field(:not_before, :utc_datetime_usec)
    field(:not_after, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:end_reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def end_reasons, do: @end_reasons

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:kind, :operator_name, :operator_email, :user_id, :not_before, :not_after])
    |> validate_required([:kind, :operator_name, :operator_email, :not_before, :not_after])
    |> validate_inclusion(:kind, @kinds)
    |> check_constraint(:kind, name: :support_sessions_kind)
  end

  @doc "Active at `now`: not ended and before `not_after`."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{ended_at: nil, not_after: not_after}, now),
    do: DateTime.compare(now, not_after) == :lt

  def active?(_, _), do: false
end
