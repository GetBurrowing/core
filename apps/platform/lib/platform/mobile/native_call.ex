defmodule Platform.Mobile.NativeCall do
  @moduledoc """
  The native iOS app's meeting join and leave (task 01a10db7), served by
  `PlatformWeb.AppMeetingsController` under `/api/app/meetings/:id`.

  Deliberately thin. Everything that makes a join a join — the external-user
  gate, the chat participant row, the room and its activation, the live
  `meeting_participants` row and the LiveKit token — is
  `Platform.Meetings.join_for_user/3`, the same function the web join
  (`PlatformWeb.ChatLive.MeetingHooks`) calls. This module only resolves the
  meeting the app addressed by id and handles its lifecycle:

    * the meeting must be visible to the user
      (`Meetings.get_meeting_for_user/2`, the listing rule the app's meeting
      list uses), else `{:error, :not_found}`;
    * an `ended` or `cancelled` meeting is `{:error, :meeting_over}`;
    * a `scheduled` meeting is started, stamping `started_by_user_id`, exactly
      as MeetingLive's auto-join does.

  The returned token is a bearer credential for the room: never log it.
  """

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Meeting

  @over_statuses ~w(ended cancelled)

  @type join_result :: %{
          token: String.t(),
          url: String.t() | nil,
          room_name: String.t(),
          identity: String.t(),
          meeting: %{
            id: String.t(),
            slug: String.t(),
            name: String.t(),
            space_id: String.t(),
            status: String.t(),
            started_at: DateTime.t() | nil
          }
        }

  @doc """
  Join `user` to meeting `meeting_id`'s call. See the moduledoc.
  """
  @spec join(User.t(), term()) ::
          {:ok, join_result()}
          | {:error, :not_found | :meeting_over | :join_not_permitted | term()}
  def join(%User{} = user, meeting_id) do
    with {:ok, meeting} <- Meetings.get_meeting_for_user(user, meeting_id),
         :ok <- refuse_over(meeting),
         {:ok, meeting} <- ensure_started(meeting, user),
         {:ok, joined} <-
           Meetings.join_for_user(meeting.chat_space_id, user.id, display_name(user)) do
      {:ok,
       %{
         token: joined.token,
         url: Meetings.livekit_url(),
         room_name: joined.room.livekit_room_name,
         identity: joined.identity,
         meeting: meeting_summary(meeting)
       }}
    end
  end

  @doc """
  Leave meeting `meeting_id`'s call: stamps the user's live participant row
  left through `Meetings.leave_for_user/2`, the web leave's own helper.
  """
  @spec leave(User.t(), term()) :: :ok | {:error, :not_found}
  def leave(%User{} = user, meeting_id) do
    with {:ok, meeting} <- Meetings.get_meeting_for_user(user, meeting_id) do
      Meetings.leave_for_user(meeting.chat_space_id, user.id)
    end
  end

  defp refuse_over(%Meeting{status: status}) when status in @over_statuses,
    do: {:error, :meeting_over}

  defp refuse_over(%Meeting{}), do: :ok

  defp ensure_started(%Meeting{status: "scheduled"} = meeting, %User{id: user_id}) do
    Meetings.start_meeting(meeting, started_by_user_id: user_id)
  end

  defp ensure_started(%Meeting{} = meeting, _user), do: {:ok, meeting}

  # The same fallbacks as the web join's resolved name: the user's name, then
  # email, then a neutral default. A real participant-row name still wins
  # inside `join_for_user/3`.
  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%User{email: email}) when is_binary(email) and email != "", do: email
  defp display_name(%User{}), do: "Guest"

  defp meeting_summary(%Meeting{} = m) do
    %{
      id: m.id,
      slug: m.slug,
      name: m.name,
      space_id: m.chat_space_id,
      status: m.status,
      started_at: m.started_at
    }
  end
end
