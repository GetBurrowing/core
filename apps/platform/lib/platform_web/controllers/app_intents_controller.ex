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

  alias Platform.Meetings.CallInvites
  alias Platform.Mobile.AppEntities
  alias Platform.Mobile.AppPeople
  alias Platform.Tasks

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

  # Task 01a111bb: `invitee_user_ids` (at most 10) and `invite_space_id`
  # (capped at 25 people, a product choice) ring people into the new call.
  # Order matters: `CallInvites.authorize/3` runs BEFORE anything is created,
  # so a refused invitee leaves no meeting row behind; then the meeting is
  # created; then the draft invites are written.
  def create_meeting(conn, params) do
    user = conn.assigns.current_user

    with {:ok, invitee_ids} <-
           CallInvites.authorize(user, params["invitee_user_ids"], params["invite_space_id"]),
         {:ok, meeting} <-
           AppEntities.create_meeting(user,
             space_id: params["space_id"],
             project_id: params["project_id"]
           ) do
      {:ok, invites} = CallInvites.invite(meeting, invitee_ids)

      conn
      |> put_status(:created)
      |> json(Map.put(AppEntities.meeting_json(meeting), :invited_count, length(invites)))
    else
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden")
      {:error, :agent_not_callable} -> error(conn, :unprocessable_entity, "agent_not_callable")
      {:error, :too_many_invitees} -> error(conn, :unprocessable_entity, "too_many_invitees")
      {:error, :no_project} -> error(conn, :unprocessable_entity, "no_project")
      {:error, _reason} -> error(conn, :unprocessable_entity, "meeting_not_created")
    end
  end

  # ── projects ─────────────────────────────────────────────────────────

  def projects(conn, _params) do
    json(conn, AppEntities.list_projects(conn.assigns.current_user))
  end

  # ── tasks: create ────────────────────────────────────────────────────

  # Task 01a111bb: Siri's Create Task. Goes through
  # `Tasks.create_from_request/2`, the one creation path the web New Task
  # sheet uses, so a flat assignee lands in `phase_assignees["planning"]`
  # (task 019f42fd bug 1). Never `Tasks.create_task/1` directly.
  def create_task(conn, params) do
    user = conn.assigns.current_user

    with {:ok, project_id} <- visible_project(user, params["project_id"]),
         {:ok, assignee_id, assignee_type} <-
           task_assignee(params["assignee_id"], params["assignee_type"]),
         {:ok, task} <-
           Tasks.create_from_request(%{
             "project_id" => project_id,
             "title" => trim(params["title"]),
             "description" => trim(params["description"]),
             "status" => "backlog",
             "assignee_id" => assignee_id,
             "assignee_type" => assignee_type,
             "reported_by" => reporter(user)
           }) do
      Tasks.broadcast_board({:task_created, task})

      conn
      |> put_status(:created)
      |> json(%{id: task.id, title: task.title, path: "/tasks/#{task.id}"})
    else
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden")
      {:error, :invalid_assignee} -> error(conn, :unprocessable_entity, "invalid_assignee")
      {:error, _reason} -> error(conn, :unprocessable_entity, "task_not_created")
    end
  end

  defp visible_project(user, project_id) when is_binary(project_id) do
    if Enum.any?(Tasks.list_projects_for_user(user), &(&1.id == project_id)),
      do: {:ok, project_id},
      else: {:error, :forbidden}
  end

  defp visible_project(_user, _project_id), do: {:error, :forbidden}

  defp task_assignee(id, _type) when id in [nil, ""], do: {:ok, nil, nil}

  defp task_assignee(id, type) when is_binary(id) and type in ["user", "agent"] do
    if Platform.UUID.valid?(id), do: {:ok, id, type}, else: {:error, :invalid_assignee}
  end

  defp task_assignee(_id, _type), do: {:error, :invalid_assignee}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: nil

  # `reported_by` is the free-form reporter string; the web sheet writes the
  # signed-in person's display name the same way.
  defp reporter(%{name: name}) when is_binary(name) and name != "", do: name
  defp reporter(%{email: email}) when is_binary(email), do: email
  defp reporter(_), do: "user"

  # ── people ───────────────────────────────────────────────────────────

  def people(conn, params) do
    people =
      AppPeople.list_people(conn.assigns.current_user, q: params["q"], limit: params["limit"])

    json(conn, %{people: people})
  end

  def person_dm(conn, %{"user_id" => user_id}) do
    case AppPeople.open_dm(conn.assigns.current_user, user_id) do
      {:ok, dm} -> json(conn, dm)
      {:error, :dm_not_allowed} -> error(conn, :forbidden, "forbidden")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, _reason} -> error(conn, :unprocessable_entity, "dm_not_created")
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
