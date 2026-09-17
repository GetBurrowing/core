defmodule PlatformWeb.ApiClientRequest do
  @moduledoc """
  Predicate distinguishing a non-browser (API) caller from a browser navigation.

  Used by the auth pipeline so an API/bearer caller can be answered with a
  status code instead of the unconditional `302 -> /auth/login` redirect that
  `PlatformWeb.Plugs.RequireAuth` currently issues to every caller alike.

  ## Rule

    * an `authorization` request header is present (ANY value) -> API caller
    * an `accept` request header is present whose value contains NEITHER
      `text/html` NOR `*/*` -> API caller
    * no `accept` header at all -> NOT an API caller (browser)

  The last clause is deliberate and must not be "simplified" into the more
  obvious *redirect only when `Accept: text/html`* rule.
  `Phoenix.ConnTest.build_conn/0` sets no `accept` header, so a strict rule
  would reclassify every existing redirect-asserting test in the suite as an
  API call. Defaulting a MISSING `accept` to browser keeps the change
  additive: a caller only leaves the redirect path by affirmatively
  identifying itself.
  """

  alias Plug.Conn

  @doc """
  Returns `true` when `conn` looks like a non-browser API caller.
  """
  @spec api_client?(Conn.t()) :: boolean()
  def api_client?(%Conn{} = conn) do
    has_authorization?(conn) or non_browser_accept?(conn)
  end

  defp has_authorization?(conn) do
    Conn.get_req_header(conn, "authorization") != []
  end

  defp non_browser_accept?(conn) do
    case Conn.get_req_header(conn, "accept") do
      [] ->
        false

      values ->
        joined = values |> Enum.join(",") |> String.downcase()

        not (String.contains?(joined, "text/html") or String.contains?(joined, "*/*"))
    end
  end
end
