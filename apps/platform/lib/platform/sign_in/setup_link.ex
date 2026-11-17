defmodule Platform.SignIn.SetupLink do
  @moduledoc """
  Accept an existing invitation in the current browser/app login session.
  Only this install's signed links and its configured provider's one-time
  links are recognised. No supplied URL is fetched or used as a redirect.
  """
  alias Platform.SignIn.DurableLink
  alias Platform.SignInAdmin.{Config, PocketId}
  @code ~r/\A[A-Za-z0-9]{12,64}\z/

  def redeem(value) when is_binary(value) and byte_size(value) <= 8192 do
    with true <- Config.enabled?(),
         %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri
         when scheme in ["https", "http"] and is_binary(host) <- URI.parse(String.trim(value)) do
      redeem_uri(uri)
    else
      _ -> {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  def redeem(_), do: {:error, :invalid}

  defp redeem_uri(uri) do
    install = URI.parse(PlatformWeb.Endpoint.url())
    provider = URI.parse(Platform.OIDC.issuer())
    query = URI.decode_query(uri.query || "")

    cond do
      origin(uri) == origin(install) and uri.path == "/auth/link" ->
        with {:ok, %{user: user, purpose: purpose}} <- DurableLink.verify(query["token"]),
             {:ok, token} <- PocketId.one_time_token(user.oidc_sub),
             do: {:ok, %{token: token, purpose: purpose}}

      origin(uri) == origin(install) and uri.path == "/auth/handover" ->
        token(query["code"], :handover)

      origin(uri) == origin(provider) and is_binary(uri.path) and
          String.starts_with?(uri.path, "/lc/") ->
        token(String.replace_prefix(uri.path, "/lc/", ""), :invite)

      true ->
        {:error, :invalid}
    end
  end

  defp token(code, purpose) when is_binary(code) do
    if Regex.match?(@code, code),
      do: {:ok, %{token: %PocketId.Token{value: code}, purpose: purpose}},
      else: {:error, :invalid}
  end

  defp token(_, _), do: {:error, :invalid}
  defp origin(uri), do: {uri.scheme, uri.host, uri.port}
end
