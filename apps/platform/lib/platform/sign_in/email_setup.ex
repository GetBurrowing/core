defmodule Platform.SignIn.EmailSetup do
  @moduledoc """
  Same-device first sign-in for an active bundled-provider account with no
  passkey. Requests allocate a browser-bound challenge and queue eligibility
  and mail work independently of the response. Only the browser that requested
  the code can redeem it, once, with at most five guesses. Eligibility is
  checked again before a provider token is minted. Provider tokens are never
  emailed. This does not provision accounts or recover passkey-enrolled users.
  """
  import Ecto.Query
  alias Platform.{Accounts, Repo}
  alias Platform.Mail.System, as: SystemMail
  alias Platform.SignInAdmin.{Config, PocketId}
  alias Platform.SignIn.{EmailSetupRateLimit, SetupChallenge}

  def enabled?, do: Config.enabled?()
  def mail_available?, do: enabled?() and SystemMail.configured?()

  def request(email, ip) do
    email = if is_binary(email), do: String.downcase(String.trim(email)), else: ""
    binding = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fake = %{id: Ecto.UUID.generate(), binding: binding}
    with true <- mail_available?(),
         true <- byte_size(email) in 3..254,
         :ok <- EmailSetupRateLimit.request(ip, email) do
      now = DateTime.utc_now()
      Repo.delete_all(from c in SetupChallenge, where: c.expires_at < ^now)
      code = Base.encode32(:crypto.strong_rand_bytes(5), padding: false)
      row = Repo.insert!(%SetupChallenge{binding_hash: digest(binding), email_hash: digest(email),
        code_hash: code_hash(binding, code), expires_at: DateTime.add(now, 1800, :second)})
      # No provider or SMTP work runs in the request process, for any account.
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> deliver_code(row, email, code) end)
      %{id: row.id, binding: binding}
    else
      _ -> fake
    end
  end

  def complete(%{id: id, binding: binding}, code)
      when is_binary(binding) and is_binary(code) and byte_size(binding) <= 128 and byte_size(code) <= 64 do
    with true <- mail_available?(),
         true <- Platform.UUID.valid?(id),
         {:ok, %SetupChallenge{user_id: user_id, email_hash: email_hash}} <- consume(id, binding, String.upcase(String.trim(code))),
         %Accounts.User{archived_at: nil} = user <- Accounts.get_user(user_id),
         true <- digest(String.downcase(String.trim(user.email))) == email_hash,
         {:ok, _} <- eligible(user),
         {:ok, %PocketId.Token{} = token} <- PocketId.one_time_token(user.oidc_sub),
         {:ok, _} <- Accounts.note_sign_in_link_expiry(user, DateTime.add(DateTime.utc_now(), 1800, :second)) do
      {:ok, token}
    else
      _ -> {:error, :invalid}
    end
  end
  def complete(_, _), do: {:error, :invalid}

  defp consume(id, binding, code) do
    Repo.transaction(fn ->
      row = Repo.one(from c in SetupChallenge, where: c.id == ^id, lock: "FOR UPDATE")
      now = DateTime.utc_now()
      if row && is_nil(row.consumed_at) && row.attempts < 5 && DateTime.after?(row.expires_at, now) &&
           Plug.Crypto.secure_compare(row.binding_hash, digest(binding)) do
        matches = Plug.Crypto.secure_compare(row.code_hash, code_hash(binding, code))
        row = Repo.update!(Ecto.Changeset.change(row, attempts: row.attempts + 1,
          consumed_at: if(matches, do: now, else: nil)))
        if matches && row.user_id, do: row, else: nil
      end
    end)
  end

  defp deliver_code(row, email, code) do
    result =
      with true <- mail_available?(),
           %Accounts.User{} = user <- Repo.one(from u in Accounts.User,
             where: fragment("lower(?)", u.email) == ^email and is_nil(u.archived_at), limit: 1),
           {:ok, identity} <- eligible(user),
           true <- String.downcase(String.trim(identity.email)) == email,
           {:ok, _} <- Repo.update(Ecto.Changeset.change(row, user_id: user.id)),
           {:ok, _} <- SystemMail.deliver(identity.email, "Your Burrow setup code", mail_text(code), nil) do
        :sent
      else
        _ -> :skipped
      end
    :telemetry.execute([:platform, :sign_in, :setup, :delivery], %{}, %{challenge_id: row.id, result: result})
  end

  defp eligible(%Accounts.User{archived_at: nil, oidc_sub: sub, email: email}) when is_binary(sub) and is_binary(email) do
    with {:ok, identity} <- PocketId.get_user(sub),
         true <- identity.disabled == false and identity.email_verified == true,
         true <- is_binary(identity.email) and String.downcase(String.trim(identity.email)) == String.downcase(String.trim(email)),
         {:ok, 0} <- PocketId.passkey_count(sub), do: {:ok, identity}
  end
  defp eligible(_), do: {:error, :invalid}
  defp digest(value), do: :crypto.hash(:sha256, value)
  defp code_hash(binding, code), do: :crypto.mac(:hmac, :sha256, binding, code)
  defp mail_text(code), do: """
  Your Burrow setup code is:

  #{code}

  Return to the SAME Burrow sign-in screen on your device and enter this code.
  It expires in 30 minutes and can be used once. No QR scan is needed.
  This is not a passkey or an invitation link. Do not share the code.
  You can add a passkey after signing in. If you did not request this, ignore this email.
  """
end
