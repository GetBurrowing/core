defmodule PlatformWeb.AuthController do
  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.OIDC

  def login(conn, _params) do
    :telemetry.execute(
      [:platform, :auth, :login],
      %{system_time: System.system_time()},
      %{action: "redirect", ip_address: format_ip(conn.remote_ip)}
    )

    case OIDC.authorize_url() do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(:oidc_session_params, session_params)
        |> redirect(external: url)

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> text("OIDC login failed: #{inspect(error)}")
    end
  end

  def callback(conn, %{"state" => state, "code" => _code} = params) do
    session_params = get_session(conn, :oidc_session_params)

    with true <- is_map(session_params) and session_params[:state] == state,
         {:ok, auth} <- OIDC.callback(params, session_params),
         {:ok, oidc_user} <- extract_oidc_user(auth),
         {:ok, user} <- Accounts.find_or_create_from_oidc(oidc_user) do
      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user.id,
          actor_type: "user",
          resource_type: "session",
          resource_id: user.id,
          ip_address: format_ip(conn.remote_ip),
          email: user.email
        }
      )

      conn
      |> delete_session(:oidc_session_params)
      |> put_session(:current_user_id, user.id)
      |> maybe_put_id_token(auth)
      |> redirect(to: ~p"/")
    else
      false ->
        emit_callback_failure(conn, :invalid_state)
        invalid_state(conn)

      {:error, reason} ->
        emit_callback_failure(conn, reason)

        conn
        |> put_status(:unauthorized)
        |> text("OIDC callback failed: #{inspect(reason)}")
    end
  end

  def callback(conn, _params) do
    emit_callback_failure(conn, :missing_params)
    invalid_state(conn)
  end

  def logout(conn, _params) do
    id_token_hint = get_session(conn, :oidc_id_token)
    user_id = get_session(conn, :current_user_id)

    :telemetry.execute(
      [:platform, :auth, :logout],
      %{system_time: System.system_time()},
      %{
        action: "logout",
        actor_id: user_id,
        actor_type: if(user_id, do: "user", else: "anonymous"),
        ip_address: format_ip(conn.remote_ip)
      }
    )

    conn
    |> configure_session(drop: true)
    |> redirect(external: OIDC.logout_url(id_token_hint))
  end

  # -- Telemetry helpers --

  defp emit_callback_failure(conn, reason) do
    :telemetry.execute(
      [:platform, :auth, :callback],
      %{system_time: System.system_time()},
      %{
        action: "failure",
        ip_address: format_ip(conn.remote_ip),
        reason: inspect(reason)
      }
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)

  # -- OIDC helpers --

  defp invalid_state(conn) do
    conn
    |> configure_session(drop: true)
    |> put_status(:unauthorized)
    |> text("Invalid OIDC state")
  end

  defp maybe_put_id_token(conn, auth) do
    case extract_id_token(auth) do
      nil -> delete_session(conn, :oidc_id_token)
      id_token -> put_session(conn, :oidc_id_token, id_token)
    end
  end

  defp extract_oidc_user(%{user: user}), do: normalize_oidc_user(user)
  defp extract_oidc_user(%{"user" => user}), do: normalize_oidc_user(user)

  defp extract_oidc_user(%{userinfo: user}), do: normalize_oidc_user(user)
  defp extract_oidc_user(%{"userinfo" => user}), do: normalize_oidc_user(user)

  defp extract_oidc_user(%{id_token: claims}) when is_map(claims), do: normalize_oidc_user(claims)

  defp extract_oidc_user(%{"id_token" => claims}) when is_map(claims),
    do: normalize_oidc_user(claims)

  defp extract_oidc_user(_auth), do: {:error, :missing_oidc_user}

  defp normalize_oidc_user(user) do
    user = for {key, value} <- user, into: %{}, do: {to_string(key), value}

    case {user["sub"], user["email"], user["name"]} do
      {sub, email, name} when is_binary(sub) and is_binary(email) and is_binary(name) ->
        {:ok, %{sub: sub, email: email, name: name}}

      _ ->
        {:error, :invalid_oidc_user}
    end
  end

  defp extract_id_token(%{token: token}), do: extract_id_token(token)
  defp extract_id_token(%{"token" => token}), do: extract_id_token(token)
  defp extract_id_token(%{id_token: id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(%{"id_token" => id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(_auth), do: nil
end
