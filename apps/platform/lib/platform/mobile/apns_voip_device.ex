defmodule Platform.Mobile.ApnsVoipDevice do
  @moduledoc """
  A PushKit VoIP token registered by a native iOS app install (task 01a10db7),
  used by `Platform.Push.APNs.deliver_voip_to_user/2` to ring the device for
  an incoming meeting.

  The sibling of `Platform.Mobile.ApnsDevice` (alert pushes) and
  `Platform.Mobile.FcmDevice` (Android); see the migration for why it is a
  table of its own.

  `token` is the raw PushKit token, which APNs needs to address the push, so
  it is stored as-is but declared `redact: true`: it never appears in
  `inspect/1` of the struct or of a changeset. Never log it, tag telemetry
  with it, or return it in a response body. Any Ecto statement whose
  parameters include it runs with `log: false`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @environments ~w(sandbox production)

  schema "apns_voip_devices" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:app_session, Platform.Mobile.AppSession)
    field(:app_install_id, :string)
    field(:token, :string, redact: true)
    field(:environment, :string)
    field(:bundle_id, :string)
    field(:last_registered_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def environments, do: @environments

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :user_id,
      :app_session_id,
      :app_install_id,
      :token,
      :environment,
      :bundle_id,
      :last_registered_at
    ])
    |> validate_required([
      :user_id,
      :app_session_id,
      :app_install_id,
      :token,
      :environment,
      :bundle_id,
      :last_registered_at
    ])
    |> validate_inclusion(:environment, @environments)
    |> validate_format(:token, ~r/\A[0-9A-Fa-f]{16,200}\z/)
    |> validate_length(:app_install_id, max: 200)
    |> validate_length(:bundle_id, max: 200)
    |> unique_constraint(:token)
    |> unique_constraint([:user_id, :app_install_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:app_session_id)
  end
end
