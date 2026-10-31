defmodule PlatformWeb.InstallRequestController do
  @moduledoc """
  `POST /api/install-requests` (task 01a18f0c stage 2): the getburrow.ing
  request form's Pages Function hands a request to
  `Platform.Installs.request/1`. Authenticated by
  `PlatformWeb.Plugs.VerifyInstallIntakeToken`; the route is `log: false`
  because its params ARE the requester's name, email and note.

  Responses:

    * 200 `{"outcome": "created" | "duplicate" | "ignored"}`
    * 422 `{"outcome": "invalid", "field": "<field>"}`

  Only `[install_requests] outcome=<x>` is logged, never a field value.
  """
  use PlatformWeb, :controller

  require Logger

  @fields ~w(name email business note website)

  def create(conn, params) do
    attrs = Map.new(@fields, &{&1, string_or_nil(Map.get(params, &1))})

    case Platform.Installs.request(attrs) do
      {:ok, outcome} when outcome in [:created, :duplicate, :ignored] ->
        respond(conn, 200, %{outcome: outcome})

      {:error, {:invalid, field}} ->
        respond(conn, 422, %{outcome: :invalid, field: field})

      {:error, _other} ->
        respond(conn, 500, %{outcome: :error})
    end
  end

  # A JSON number or object is not a field value; it validates as absent.
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp respond(conn, status, body) do
    Logger.info("[install_requests] outcome=#{body.outcome}")
    conn |> put_status(status) |> json(body)
  end
end
