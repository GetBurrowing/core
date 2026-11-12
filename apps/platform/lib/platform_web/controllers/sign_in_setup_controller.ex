defmodule PlatformWeb.SignInSetupController do
  use PlatformWeb, :controller
  alias Platform.SignIn.{EmailSetup, EmailSetupRateLimit}

  def show(conn, _params) do
    if EmailSetup.enabled?(), do: page(conn), else: redirect(conn, to: "/auth/login")
  end

  def request(conn, params) do
    if EmailSetup.mail_available?() do
      challenge = EmailSetup.request(params["email"], limiter_ip(conn))
      conn
      |> put_session(:email_setup, challenge)
      |> page(sent?: true)
    else
      conn |> put_status(:service_unavailable) |> page()
    end
  end

  def complete(conn, %{"code" => code}) when is_binary(code) do
    code = String.trim(code)

    with true <- EmailSetup.mail_available?(),
         :ok <- EmailSetupRateLimit.verify(limiter_ip(conn)),
         {:ok, %Platform.SignInAdmin.PocketId.Token{value: token}} <- EmailSetup.complete(get_session(conn, :email_setup), code) do
      conn |> delete_session(:email_setup) |> PlatformWeb.AuthController.setup_code_login(token)
    else
      _ -> conn |> put_status(:bad_request) |> page(sent?: true, error?: true)
    end
  end

  def complete(conn, _), do: conn |> put_status(:bad_request) |> page(sent?: true, error?: true)

  def invitation(conn, params) do
    with true <- EmailSetup.enabled?(),
         :ok <- EmailSetupRateLimit.verify(limiter_ip(conn)),
         {:ok, %{token: %Platform.SignInAdmin.PocketId.Token{value: code}, purpose: purpose}} <-
           Platform.SignIn.SetupLink.redeem(params["setup_link"]) do
      PlatformWeb.AuthController.setup_code_login(conn, code, purpose)
    else
      _ -> conn |> put_status(:bad_request) |> page(link_error?: true)
    end
  end

  # Only trust a proxy-added final hop, never a client-supplied leftmost XFF.
  defp limiter_ip(conn) do
    if Application.get_env(:platform, :trust_proxy_headers, false) do
      value = conn |> get_req_header("x-forwarded-for") |> List.last()
      with value when is_binary(value) <- value,
           {:ok, ip} <- value |> String.split(",") |> List.last() |> String.trim() |> String.to_charlist() |> :inet.parse_address(), do: ip, else: (_ -> :unknown_proxy)
    else
      conn.remote_ip
    end
  end

  defp page(conn, opts \\ []) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_layout(false)
    |> put_view(html: PlatformWeb.SignInSetupHTML)
    |> render(:show,
      mail?: EmailSetup.mail_available?(),
      sent?: opts[:sent?] || false,
      error?: opts[:error?] || false,
      link_error?: opts[:link_error?] || false,
      form: Phoenix.Component.to_form(%{})
    )
  end
end
