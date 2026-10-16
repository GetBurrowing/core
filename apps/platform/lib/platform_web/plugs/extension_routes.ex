defmodule PlatformWeb.Plugs.ExtensionRoutes do
  @moduledoc """
  The reader for `c:Platform.Extension.routes/0` (ADR 0055 Follow-up 2):
  ONE generic route, `/api/ext/*`, dispatched at RUNTIME to the extension
  that claims the first path segment.

  Runtime, not router macros: in a with-modules build the module apps
  depend on `:platform`, so core's router compiles before any module and
  cannot call a module's `routes/0` at compile time.

  For `/api/ext/<prefix>/rest...` this plug looks `<prefix>` up through
  `Platform.Extensions.route_for/1` on EVERY request. On a match it moves
  `<prefix>` from `path_info` to `script_name` and calls the extension's plug,
  which then sees only `rest...`. No match is a 404 JSON.

  ## No session, no auth

  The `:extension_api` pipeline accepts JSON and does nothing else: no
  session, no CSRF, no current user. The extension's plug OWNS its
  authentication (a webhook signature, a bearer token) and must halt on
  failure. Route params are not logged (`log: false` in the router).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [prefix | rest]} = conn, _opts) do
    case Platform.Extensions.route_for(prefix) do
      %{plug: plug} = route ->
        conn = %{conn | path_info: rest, script_name: conn.script_name ++ [prefix]}
        plug.call(conn, plug.init(Map.get(route, :opts, [])))

      nil ->
        not_found(conn)
    end
  end

  def call(conn, _opts), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not_found"}))
    |> halt()
  end
end
