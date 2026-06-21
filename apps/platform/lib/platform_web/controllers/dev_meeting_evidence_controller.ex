defmodule PlatformWeb.DevMeetingEvidenceController do
  @moduledoc """
  Dev-only HTTP endpoints to seed/clear MeetingState for the logged-in
  dev user so an evidence-capture script can drive the shell's
  `@meeting_active` flag without spinning up a real LiveKit room.

  Used by `tmp/<task-slug>-stage<n>/cdp_evidence.py` to flip
  `#meeting-watchdog` between absent (no meeting) and present (meeting
  active) across non-meeting routes. Gated behind `Mix.env() == :dev`
  in the router; not compiled out, but unreachable in prod because the
  route isn't registered.
  """
  use PlatformWeb, :controller

  alias Platform.Meetings.State, as: MeetingState

  def join(conn, params) do
    case get_session(conn, :current_user_id) do
      nil ->
        send_resp(conn, 401, "no current_user_id in session — visit /dev/login first")

      user_id ->
        space_id = Map.get(params, "space_id") || "00000000-0000-0000-0000-000000000000"
        space_name = Map.get(params, "space_name") || "Dev Evidence Space"
        space_slug = Map.get(params, "space_slug") || "dev-evidence-space"
        meeting_slug = Map.get(params, "meeting_slug") || "dev-evidence-meeting"

        :ok =
          MeetingState.broadcast_joined(user_id, space_id, space_name, space_slug, meeting_slug)

        json(conn, %{
          status: "ok",
          user_id: user_id,
          space_id: space_id,
          meeting_slug: meeting_slug
        })
    end
  end

  def leave(conn, _params) do
    case get_session(conn, :current_user_id) do
      nil ->
        send_resp(conn, 401, "no current_user_id in session — visit /dev/login first")

      user_id ->
        :ok = MeetingState.broadcast_left(user_id)
        json(conn, %{status: "ok", user_id: user_id})
    end
  end
end
