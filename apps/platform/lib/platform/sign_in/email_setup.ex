defmodule Platform.SignIn.EmailSetup do
  @moduledoc """
  Same-device first sign-in for an invited, active bundled-provider account
  with no passkey. This never provisions an account or recovers an account
  that already has a passkey. The provider owns token expiry and single use;
  Burrow emails its code and retains only a digest in the browser session.
  """
  import Ecto.Query
  alias Platform.{Accounts, Repo}
  alias Platform.Mail.System, as: SystemMail
  alias Platform.SignInAdmin.{Config, PocketId}
  alias Platform.SignIn.EmailSetupRateLimit

  def enabled?, do: Config.enabled?()
  def mail_available?, do: enabled?() and SystemMail.configured?()

  def request(email, ip) do
    email = if is_binary(email), do: String.downcase(String.trim(email)), else: ""
    # Unknown, disabled and already-enrolled users get the same response and
    # an unredeemable session digest. No account-existence oracle in the UI.
    fallback = digest(Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))

    with true <- mail_available?(),
         true <- byte_size(email) in 3..254,
         :ok <- EmailSetupRateLimit.request(ip, email),
         %Accounts.User{oidc_sub: sub} = user when is_binary(sub) <-
           Repo.one(from u in Accounts.User, where: fragment("lower(?)", u.email) == ^email and is_nil(u.archived_at), limit: 1),
         {:ok, identity} <- PocketId.get_user(sub),
         true <- identity.disabled == false and identity.email_verified == true,
         true <- is_binary(identity.email) and String.downcase(String.trim(identity.email)) == email,
         {:ok, 0} <- PocketId.passkey_count(sub),
         {:ok, %PocketId.Token{value: code}} <- PocketId.one_time_token(sub),
         # Track expiry through Accounts, like admin-issued recovery links.
         {:ok, _} <- Accounts.note_sign_in_link_expiry(user, DateTime.add(DateTime.utc_now(), 1800, :second)),
         {:ok, _} <- SystemMail.deliver(identity.email, "Your Burrow setup code", mail_text(code), nil) do
      digest(code)
    else
      _ -> fallback
    end
  end

  def digest(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  defp mail_text(code) do
    """
    Your Burrow setup code is:

    #{code}

    Return to the Burrow sign-in screen on your device and enter this code.
    It expires in 30 minutes and can be used once. You do not need to scan a QR code.
    You can add a passkey after signing in. If you did not request this, ignore this email.
    """
  end
end
