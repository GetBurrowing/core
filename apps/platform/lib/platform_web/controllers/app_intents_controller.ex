defmodule PlatformWeb.AppIntentsController do
  @moduledoc """
  JSON for the native app's App Intents (task 01a10db6): Siri, Shortcuts,
  Spotlight, widgets and controls. Every action runs behind
  `PlatformWeb.Plugs.AppBearerAuth` (`:app_api`) and keys off
  `conn.assigns.current_user` only; the queries live in
  `Platform.Mobile.AppEntities`.

  Kept apart from `PlatformWeb.AppApiController` so the two surfaces can
  change independently.

  Nothing here logs a bearer token, a message body or approval content.
  """
  use PlatformWeb, :controller

  alias Platform.Mobile.AppEntities

  # ── approvals ────────────────────────────────────────────────────────

  def approvals(conn, _params) do
    json(conn, %{approvals: AppEntities.list_approvals(conn.assigns.current_user)})
  end

  def approve(conn, %{"id" => id}) do
    conn.assigns.current_user
    |> AppEntities.approve(id)
    |> approval_response(conn)
  end

  def reject(conn, %{"id" => id} = params) do
    conn.assigns.current_user
    |> AppEntities.reject(id, params["feedback"])
    |> approval_response(conn)
  end

  defp approval_response({:ok, status}, conn), do: json(conn, %{status: status})

  defp approval_response({:error, :already_handled, by}, conn) do
    conn |> put_status(:conflict) |> json(%{error: "already_handled", by: by})
  end

  defp approval_response({:error, :not_found}, conn), do: error(conn, :not_found, "not_found")

  defp approval_response({:error, :feedback_required}, conn),
    do: error(conn, :unprocessable_entity, "feedback_required")

  defp approval_response({:error, _reason}, conn),
    do: error(conn, :unprocessable_entity, "not_handled")

  # ── tasks ────────────────────────────────────────────────────────────

  def tasks(conn, params) do
    tasks =
      AppEntities.list_tasks(conn.assigns.current_user, q: params["q"], limit: params["limit"])

    json(conn, %{tasks: tasks})
  end

  # ── meetings ─────────────────────────────────────────────────────────

  def meetings(conn, _params) do
    json(conn, %{meetings: AppEntities.list_meetings(conn.assigns.current_user)})
  end

  def create_meeting(conn, params) do
    case AppEntities.start_meeting(conn.assigns.current_user,
           space_id: params["space_id"],
           project_id: params["project_id"]
         ) do
      {:ok, meeting} -> conn |> put_status(:created) |> json(meeting)
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden")
      {:error, :no_project} -> error(conn, :unprocessable_entity, "no_project")
      {:error, _reason} -> error(conn, :unprocessable_entity, "meeting_not_created")
    end
  end

  # ── agents ───────────────────────────────────────────────────────────

  def agents(conn, _params) do
    json(conn, %{agents: AppEntities.list_agents(conn.assigns.current_user)})
  end

  def agent_dm(conn, %{"agent_id" => agent_id}) do
    case AppEntities.open_agent_dm(conn.assigns.current_user, agent_id) do
      {:ok, dm} -> json(conn, dm)
      {:error, :dm_not_allowed} -> error(conn, :forbidden, "forbidden")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :agent_not_found} -> error(conn, :not_found, "not_found")
      {:error, _reason} -> error(conn, :unprocessable_entity, "dm_not_created")
    end
  end

  # ── messages poll ────────────────────────────────────────────────────

  def messages(conn, %{"space_id" => space_id} = params) do
    case AppEntities.poll_messages(conn.assigns.current_user, space_id,
           after: params["after"],
           limit: params["limit"]
         ) do
      {:ok, messages} -> json(conn, %{messages: messages})
      # 404, not 403: a space the user is not in is indistinguishable from
      # one that does not exist.
      {:error, :forbidden} -> error(conn, :not_found, "not_found")
      {:error, :invalid_cursor} -> error(conn, :unprocessable_entity, "invalid_cursor")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
