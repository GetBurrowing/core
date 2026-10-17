defmodule Platform.Mobile.ApnsDevice do
  @moduledoc """
  An APNs device token registered by a native app install (task 01a10882).

  `token` is the raw APNs device token, which APNs needs to address a push,
  so it is stored as-is but declared `redact: true`: it never appears in
  `inspect/1` of the struct or of a changeset. Never log it, tag telemetry
  with it, or return it in a response body.

  Push type is `alert` only; there is no VoIP / PushKit seam here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @environments ~w(sandbox production)

  schema "apns_devices" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:app_session, Platform.Mobile.AppSession)
    field(:app_install_id, :string)
    field(:token, :string, redact: true)
    field(:environment, :string)
    field(:bundle_id, :string)
    # The install's X25519 public key for sealed previews (task 01a1261e),
    # base64url without padding. Optional: nil means no sealed preview.
    field(:push_public_key, :string)
    # The notification category ids the build registers (task 01a14ba1):
    # nil = legacy SUITE_* only; "burrow" = BURROW_* as well.
    field(:push_category_scheme, :string)
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
      :last_registered_at,
      :push_public_key,
      :push_category_scheme
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
    |> Platform.Mobile.PushPublicKey.validate()
    |> validate_inclusion(:push_category_scheme, Platform.Mobile.push_category_schemes())
    |> validate_length(:bundle_id, max: 200)
    |> unique_constraint(:token)
    |> unique_constraint([:user_id, :app_install_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:app_session_id)
  end
end
