defmodule PlatformWeb.PushRelayController do
  @moduledoc """
  `POST /api/push-relay/v1/notifications` (task 01a1261e stage 2): the push
  relay's one endpoint. Behind `PlatformWeb.Plugs.PushRelayAuth` (404 when
  relay mode is off, 401 without a live install credential).

  Body `{"notifications": [...]}`, at most 100 items, each a strict
  allow-list (`Platform.Push.RelayServer.validate/1`). Answers:

    * 200 `{"results": [{"status": "sent" | "unregistered" | "failed"}]}`
      in request order;
    * 422 `{"error": "unknown_field", "field": <key>}`, naming the KEY
      only, never its value;
    * 422 `{"error": "invalid_field", "field": <key>, "index": i}`;
    * 422 `{"error": "too_many"}` / `{"error": "invalid_body"}`;
    * 429 `{"error": "rate_limited"}`.

  The route is mounted with `log: false`: Phoenix's request log would print
  the parameters, and an unknown key's VALUE must never reach a log. The
  relay's only log line is `RelayServer`'s per-batch counts.
  """
  use PlatformWeb, :controller

  alias Platform.Push.RelayServer

  def create(conn, params) do
    install = conn.assigns.relay_install

    with {:ok, items} <- RelayServer.validate(params),
         :ok <- RelayServer.check_rate(install, length(items)) do
      json(conn, %{results: RelayServer.deliver(install, items)})
    else
      {:error, {:unknown_field, key}} ->
        refuse(conn, 422, %{error: "unknown_field", field: String.slice(key, 0, 64)})

      {:error, {:invalid_field, field, index}} ->
        refuse(conn, 422, %{error: "invalid_field", field: field, index: index})

      {:error, :too_many} ->
        refuse(conn, 422, %{error: "too_many", max: RelayServer.max_items()})

      {:error, :rate_limited} ->
        refuse(conn, 429, %{error: "rate_limited"})

      {:error, _} ->
        refuse(conn, 422, %{error: "invalid_body"})
    end
  end

  defp refuse(conn, status, body), do: conn |> put_status(status) |> json(body)
end
