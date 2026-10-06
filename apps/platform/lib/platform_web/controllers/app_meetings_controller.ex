defmodule PlatformWeb.AppMeetingsController do
  @moduledoc """
  The native iOS app's meeting call surface (task 01a10db7), behind
  `PlatformWeb.Plugs.AppBearerAuth` (`:app_api`):

    * `POST /api/app/meetings/:id/join` — join the meeting's LiveKit call and
      return the token (`Platform.Mobile.NativeCall.join/2`, which runs the
      web join's own `Meetings.join_for_user/3`);
    * `POST /api/app/meetings/:id/leave` — leave it;
    * `POST /api/app/voip_devices` — register the install's PushKit VoIP
      token (`Platform.Mobile.register_voip_device/2`);
    * `GET /api/app/rings/:id` and `POST /api/app/rings/:id/answer`,
      `/decline`, `/missed` — a ring's state and its transitions
      (`Platform.Meetings.Ringing`, stage 2). Owner-only: another user's ring
      is 404. Each transition is a compare-and-set on `ringing`, so a second
      one answers 409 with the state the ring already settled in.

  Kept apart from `AppApiController` and `AppIntentsController` so each
  surface changes independently.

  External users: the `:enforce_external_scope` plug refuses every
  `/api/app` route, so scoping is done here as the sibling controllers do,
  by keying everything off `conn.assigns.current_user`. A meeting the user
  cannot see, and an external user's join without a live invite, both answer
  404 with the same body, so a meeting id is not probeable.

  The join response carries the LiveKit token, a bearer credential for the
  room. Nothing here logs it, the VoIP token, or the app bearer; error
  bodies carry a fixed code only.
  """
  use PlatformWeb, :controller

  alias Platform.Meetings.Ringing
  alias Platform.Mobile
  alias Platform.Mobile.NativeCall

  # ── meetings ─────────────────────────────────────────────────────────

  def join(conn, %{"id" => id}) do
    case NativeCall.join(conn.assigns.current_user, id) do
      {:ok, result} ->
        json(conn, %{
          token: result.token,
          url: result.url,
          room_name: result.room_name,
          identity: result.identity,
          meeting: result.meeting
        })

      {:error, reason} when reason in [:not_found, :join_not_permitted] ->
        error(conn, :not_found, "not_found")

      {:error, :meeting_over} ->
        error(conn, :conflict, "meeting_over")

      {:error, reason} when reason in [:livekit_not_configured, :meetings_disabled] ->
        error(conn, :service_unavailable, "meetings_unavailable")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "join_failed")
    end
  end

  def leave(conn, %{"id" => id}) do
    case NativeCall.leave(conn.assigns.current_user, id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
    end
  end

  # ── rings ────────────────────────────────────────────────────────────

  def ring(conn, %{"id" => id}) do
    with {:ok, ring} <- Ringing.get_ring_for_user(conn.assigns.current_user.id, id) do
      json(conn, ring_json(ring))
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
    end
  end

  def answer_ring(conn, params), do: transition(conn, params, &Ringing.answer/1)
  def decline_ring(conn, params), do: transition(conn, params, &Ringing.decline/1)
  def missed_ring(conn, params), do: transition(conn, params, &Ringing.missed/1)

  defp transition(conn, %{"id" => id}, fun) do
    with {:ok, ring} <- Ringing.get_ring_for_user(conn.assigns.current_user.id, id) do
      case fun.(ring) do
        {:ok, updated} ->
          json(conn, ring_json(updated))

        {:error, :not_ringing} ->
          {:ok, current} = Ringing.get_ring_for_user(conn.assigns.current_user.id, id)

          conn
          |> put_status(:conflict)
          |> json(%{error: "not_ringing", state: Ringing.effective_state(current)})
      end
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
    end
  end

  defp ring_json(ring) do
    %{
      id: ring.id,
      state: Ringing.effective_state(ring),
      trigger: ring.trigger,
      meeting_id: ring.meeting_id,
      meeting_status: ring.meeting.status,
      space_id: ring.meeting.chat_space_id
    }
  end

  # ── VoIP devices ─────────────────────────────────────────────────────

  def register_voip_device(conn, params) do
    attrs = Map.take(params, ~w(token environment bundle_id app_install_id))

    case Mobile.register_voip_device(conn.assigns.app_session, attrs) do
      {:ok, _device} ->
        json(conn, %{registered: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_device", fields: error_fields(changeset)})
    end
  end

  # Field NAMES only, never values: a rejected token must not be echoed.
  defp error_fields(%Ecto.Changeset{errors: errors}),
    do: errors |> Keyword.keys() |> Enum.uniq() |> Enum.map(&Atom.to_string/1)

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
