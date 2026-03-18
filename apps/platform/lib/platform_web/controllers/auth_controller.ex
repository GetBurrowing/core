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

    require Logger

    Logger.debug(
      "[auth_callback] session_params=#{inspect(session_params, limit: 5)} " <>
        "params_state=#{String.slice(state, 0, 8)}... " <>
        "session_state=#{inspect(session_params && String.slice(to_string(session_params[:state] || ""), 0, 8))}..."
    )

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
      |> maybe_put_end_session_endpoint(session_params)
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

  def dev_login(conn, _params) do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "dev-local-user",
        email: "dev@localhost",
        name: "Dev User"
      })

    space = Platform.Chat.get_space_by_slug("general")

    if space do
      Platform.Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name || "Dev User",
        joined_at: DateTime.utc_now()
      })
    end

    conn
    |> put_session(:current_user_id, user.id)
    |> put_session(:oidc_id_token, "dev-id-token")
    |> redirect(to: ~p"/chat")
  end

  def logout(conn, _params) do
    id_token_hint = get_session(conn, :oidc_id_token)
    end_session_endpoint = get_session(conn, :oidc_end_session_endpoint)
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
    |> redirect(external: OIDC.logout_url(id_token_hint, end_session_endpoint))
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

  # Store the provider's end_session_endpoint from the OIDC discovery doc so
  # logout_url/2 doesn't need to guess the path (works for any OIDC provider).
  defp maybe_put_end_session_endpoint(conn, session_params) do
    endpoint =
      get_in(session_params, [:openid_configuration, "end_session_endpoint"]) ||
        get_in(session_params, ["openid_configuration", "end_session_endpoint"])

    case endpoint do
      nil -> conn
      url -> put_session(conn, :oidc_end_session_endpoint, url)
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

    name =
      user["name"] ||
        [user["given_name"], user["family_name"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
        |> then(fn s -> if s == "", do: nil, else: s end) ||
        user["preferred_username"] ||
        user["email"]

    case {user["sub"], user["email"], name} do
      {sub, email, n} when is_binary(sub) and is_binary(email) and is_binary(n) ->
        {:ok, %{sub: sub, email: email, name: n}}

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
