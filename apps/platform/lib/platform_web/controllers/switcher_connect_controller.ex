defmodule PlatformWeb.SwitcherConnectController do
  @moduledoc """
  The connect hop of the web install switcher, on install B (task 01a1ccd4
  stage 2). Install A sends the browser here with its own origin:
  `GET /switcher/connect?origin=<A origin>`.

  Behind `:browser` + `:require_auth`, so a signed-out visitor signs in with
  B's own OIDC first and lands back here through the return path
  `PlatformWeb.Plugs.RequireAuth` stores. No token of any kind crosses to A
  for sign-in.

    * `show/2` validates `origin` (`Platform.Switcher.normalize_origin/1`) and
      renders the consent page. An invalid origin renders an error with
      status 400 and never redirects, so this is not an open redirect.
    * `allow/2` (POST, CSRF protected) mints a badge key bound to A and
      redirects to `<A>/switcher/connected#key=...&name=...&host=...`. The key
      is in the FRAGMENT, so A's server never receives it.
    * Cancel is a link to the same address without `key`: A adds the install
      without its unread.
  """
  use PlatformWeb, :controller

  alias Platform.Switcher

  # Task 01a1ccd4 stage 4: the consent page and its redirect back to A carry
  # no Referer, so A learns nothing from the hop but the fragment it asked
  # for (the 302's own Referrer-Policy governs the redirected request).
  plug :no_referrer

  def show(conn, params) do
    case Switcher.normalize_origin(params["origin"]) do
      {:ok, origin} ->
        user = conn.assigns.current_user

        conn
        |> put_view(html: PlatformWeb.SwitcherConnectHTML)
        |> render(:consent,
          page_title: "Show unread in another install",
          origin: origin,
          origin_host: host_of(origin),
          install_name: Platform.Branding.app_name(),
          user_label: user.name || user.email,
          cancel_url: connected_url(conn, origin, %{})
        )

      {:error, :invalid_origin} ->
        invalid(conn)
    end
  end

  def allow(conn, params) do
    with {:ok, origin} <- Switcher.normalize_origin(params["origin"]),
         {:ok, %{token: token}} <- Switcher.mint(conn.assigns.current_user, origin) do
      redirect(conn, external: connected_url(conn, origin, %{key: token}))
    else
      _ -> invalid(conn)
    end
  end

  defp no_referrer(conn, _opts), do: put_resp_header(conn, "referrer-policy", "no-referrer")

  defp invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> put_view(html: PlatformWeb.SwitcherConnectHTML)
    |> render(:invalid, page_title: "This link doesn't work")
  end

  # `<A>/switcher/connected#key=...&name=...&host=...`. `name` and `host`
  # describe THIS install (B) so A can list it.
  defp connected_url(conn, origin, extra) do
    fragment =
      extra
      |> Map.merge(%{name: Platform.Branding.app_name(), host: own_host(conn)})
      |> Enum.sort()
      |> URI.encode_query()

    origin <> "/switcher/connected#" <> fragment
  end

  # The host (and non-default port) the browser used to reach this page
  # (task 01a1ccd4 stage 4). A checks it against the address it sent the
  # browser to, so it must be what the BROWSER sees: the endpoint's
  # configured host is not, on an install served under an alias
  # (OWN_HOST_ALIASES, a second apex) or on the dev rig, and A would refuse
  # every Allow ("This link doesn't work"). The host is `conn.host`; the port
  # is the one in the `Host` header (none means the scheme's default, which
  # is right behind a TLS-terminating proxy), or `conn.port` when the request
  # carried no `Host` header. Anything malformed falls back to the endpoint's
  # host.
  @host_name ~r/\A[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\z/

  defp own_host(conn) do
    host = String.downcase(conn.host || "")

    with true <- Regex.match?(@host_name, host),
         {:ok, suffix} <- port_suffix(conn) do
      host <> suffix
    else
      _ -> endpoint_host()
    end
  end

  defp port_suffix(conn) do
    case get_req_header(conn, "host") do
      [value] ->
        case String.split(value, ":") do
          [_host] -> {:ok, ""}
          [_host, port] -> if port =~ ~r/\A[0-9]{1,5}\z/, do: {:ok, ":" <> port}, else: :error
          _ -> :error
        end

      [] ->
        if {conn.scheme, conn.port} in [{:https, 443}, {:http, 80}],
          do: {:ok, ""},
          else: {:ok, ":#{conn.port}"}

      _ ->
        :error
    end
  end

  defp endpoint_host do
    %URI{host: host, port: port, scheme: scheme} = PlatformWeb.Endpoint.struct_url()

    if is_nil(port) or {scheme, port} in [{"https", 443}, {"http", 80}],
      do: host,
      else: "#{host}:#{port}"
  end

  defp host_of(origin), do: origin |> String.split("://", parts: 2) |> List.last()
end
