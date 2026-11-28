defmodule PlatformWeb.AppVoiceController do
  @moduledoc """
  JSON for the native Voice turn (task 01a21e75 stage 2): a Voice control,
  Action button or widget that starts a turn with no web view. Every action
  runs behind `PlatformWeb.Plugs.AppBearerAuth` (`:app_api`) and keys off
  `conn.assigns.current_user` only; the logic lives in
  `Platform.Mobile.VoiceTurns`.

    * `GET /api/app/voice/partner`: the most recently used Voice partner.
    * `POST /api/app/voice/turns`: `agent_id`, `text`, `client_turn_id`.
    * `GET /api/app/voice/turns/:client_turn_id?spoken=N&wait_ms=M`: the
      reply's sentences after the `spoken` ones, waiting up to `wait_ms`
      (default and cap `VoiceTurns.max_wait_ms/0`).

  The turn routes are `log: false` in the router: the POST body carries the
  spoken words. Nothing here logs the text, the reply, a name or an agent
  name.
  """
  use PlatformWeb, :controller

  alias Platform.Mobile.VoiceTurns

  def partner(conn, _params) do
    partner =
      case VoiceTurns.last_partner(conn.assigns.current_user) do
        nil ->
          nil

        p ->
          %{agent_id: p.agent_id, name: p.name, last_used_at: DateTime.to_iso8601(p.last_used_at)}
      end

    json(conn, %{partner: partner})
  end

  def create_turn(conn, params) do
    case VoiceTurns.send_turn(
           conn.assigns.current_user,
           params["agent_id"],
           params["text"],
           params["client_turn_id"]
         ) do
      {:ok, turn} ->
        conn
        |> put_status(:created)
        |> json(%{
          space_id: turn.space_id,
          path_segment: turn.path_segment,
          client_turn_id: params["client_turn_id"]
        })

      {:error, :blank} ->
        error(conn, :unprocessable_entity, "blank")

      {:error, :invalid} ->
        error(conn, :unprocessable_entity, "invalid_client_turn_id")

      {:error, :not_found} ->
        error(conn, :not_found, "not_found")

      {:error, :forbidden} ->
        error(conn, :forbidden, "forbidden")
    end
  end

  def reply(conn, %{"client_turn_id" => client_turn_id} = params) do
    spoken = int(params["spoken"], 0)
    wait_ms = int(params["wait_ms"], VoiceTurns.max_wait_ms())

    case VoiceTurns.await_reply(conn.assigns.current_user, client_turn_id, spoken, wait_ms) do
      {:ok, reply} -> json(conn, reply)
      {:error, :not_found} -> error(conn, :not_found, "not_found")
    end
  end

  defp int(value, _default) when is_integer(value) and value >= 0, do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp int(_value, default), do: default

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
