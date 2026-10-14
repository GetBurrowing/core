defmodule Platform.Mobile.FcmDevice do
  @moduledoc """
  A Firebase Cloud Messaging registration token registered by a native
  Android app install (task 01a10d8e). The Android twin of
  `Platform.Mobile.ApnsDevice`; see the `create_fcm_devices` migration for why
  it is a separate table.

  `token` is the raw FCM registration token, which FCM needs to address a
  push, so it is stored as-is but declared `redact: true`: it never appears in
  `inspect/1` of the struct or of a changeset. Never log it, tag telemetry
  with it, or return it in a response body.

  `package_name` is the Android applicationId. Production is
  `com.koboai.burrow` (no hyphen; it is NOT the iOS bundle id
  `com.kobo-ai.burrow`). `config :platform, :fcm, allowed_packages: [...]`
  adds more, so a debug build (`com.koboai.burrow.debug`) can register on dev.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @package_name "com.koboai.burrow"

  # FCM registration tokens are opaque; observed shapes are an instance id,
  # a colon, then a base64url body, ~150-200 characters.
  @token_format ~r/\A[A-Za-z0-9_:\-]{20,4096}\z/

  schema "fcm_devices" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:app_session, Platform.Mobile.AppSession)
    field(:app_install_id, :string)
    field(:token, :string, redact: true)
    field(:package_name, :string)
    # The install's X25519 public key for sealed previews (task 01a1261e),
    # base64url without padding. Optional: nil means no sealed preview.
    field(:push_public_key, :string)
    field(:last_registered_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The production Android applicationId."
  def package_name, do: @package_name

  @doc "Every applicationId allowed to register: production plus config."
  def allowed_packages do
    extra = Application.get_env(:platform, :fcm, [])[:allowed_packages] || []
    Enum.uniq([@package_name | List.wrap(extra)])
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :user_id,
      :app_session_id,
      :app_install_id,
      :token,
      :package_name,
      :last_registered_at,
      :push_public_key
    ])
    |> validate_required([
      :user_id,
      :app_session_id,
      :app_install_id,
      :token,
      :package_name,
      :last_registered_at
    ])
    |> validate_format(:token, @token_format)
    |> validate_inclusion(:package_name, allowed_packages())
    |> validate_length(:app_install_id, max: 200)
    |> Platform.Mobile.PushPublicKey.validate()
    |> unique_constraint(:token)
    |> unique_constraint([:user_id, :app_install_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:app_session_id)
  end
end
