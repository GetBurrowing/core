defmodule PlatformWeb.SignInSetupController do
  use PlatformWeb, :controller
  alias Platform.SignIn.{EmailSetup, EmailSetupRateLimit}

  def show(conn, _params) do
    if EmailSetup.enabled?(), do: page(conn), else: redirect(conn, to: "/auth/login")
  end

  def request(conn, params) do
    if EmailSetup.mail_available?() do
      hash = EmailSetup.request(params["email"], conn.remote_ip)
      conn
      |> put_session(:email_setup, %{hash: hash, expires_at: System.system_time(:second) + 1800})
      |> page(sent?: true)
    else
      conn |> put_status(:service_unavailable) |> page()
    end
  end

  def complete(conn, %{"code" => code}) when is_binary(code) do
    code = String.trim(code)
    with true <- EmailSetup.mail_available?(),
         :ok <- EmailSetupRateLimit.verify(conn.remote_ip),
         %{hash: hash, expires_at: expires_at} <- get_session(conn, :email_setup),
         true <- expires_at > System.system_time(:second),
         true <- byte_size(code) in 12..64,
         true <- Plug.Crypto.secure_compare(hash, EmailSetup.digest(code)) do
      conn |> delete_session(:email_setup) |> PlatformWeb.AuthController.setup_code_login(code)
    else
      _ -> conn |> put_status(:bad_request) |> page(sent?: true, error?: true)
    end
  end

  def complete(conn, _), do: conn |> put_status(:bad_request) |> page(sent?: true, error?: true)

  def invitation(conn, params) do
    with true <- EmailSetup.enabled?(),
         :ok <- EmailSetupRateLimit.verify(conn.remote_ip),
         {:ok, %Platform.SignInAdmin.PocketId.Token{value: code}} <-
           Platform.SignIn.SetupLink.redeem(params["setup_link"]) do
      PlatformWeb.AuthController.setup_code_login(conn, code)
    else
      _ -> conn |> put_status(:bad_request) |> page(link_error?: true)
    end
  end

  defp page(conn, opts \\ []) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_layout(false)
    |> put_view(html: PlatformWeb.SignInSetupHTML)
    |> render(:show, mail?: EmailSetup.mail_available?(), sent?: opts[:sent?] || false,
      error?: opts[:error?] || false, link_error?: opts[:link_error?] || false,
      form: Phoenix.Component.to_form(%{}))
  end
end
