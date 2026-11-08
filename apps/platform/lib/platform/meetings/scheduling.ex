defmodule Platform.Meetings.Scheduling do
  @moduledoc """
  The scheduling sheet's create path, extracted from
  `PlatformWeb.MeetingLive`'s `create_from_sheet/7` (task 01a1b8a5 stage 1)
  so `Platform.Calendar.Authoring` commits a new call the same way the
  Meetings sheet always has.

  Two steps and nothing else:

    1. `Platform.Meetings.create_meeting/1`, which owns the backing chat
       space, the `meeting-<uuid>` LiveKit room name and the project
       broadcast.
    2. The staged invitees replayed through `invite_user/3`,
       `invite_guest/2` and `invite_external_user/3`, in order, each taking
       its own `InviteDelivery` claim. An entry that produced no invite is
       returned as undelivered; it does not fail the create, exactly as the
       sheet's "N invites could not be sent." flash has always reported it.

  What the viewer sees afterwards (flash, navigation, `:enter` into the
  room) stays in the LiveView: that is presentation, not the commit.

  Staged entries are the sheet's shape, atom keys:
  `%{kind: :user, user_id: id, display_name: name}`,
  `%{kind: :guest, display_name: name, email: email}`,
  `%{kind: :external, email: email, display_name: name}`.
  """

  alias Platform.Meetings

  @type entry :: map()

  @doc """
  Create a meeting from `attrs` (`Meetings.create_meeting/1`'s) and replay
  `entries`. Returns `{:ok, meeting, undelivered}` or the create's error.
  """
  @spec create_with_invites(map(), [entry()]) ::
          {:ok, Meetings.Meeting.t(), [entry()]} | {:error, term()}
  def create_with_invites(attrs, entries) when is_map(attrs) and is_list(entries) do
    with {:ok, meeting} <- Meetings.create_meeting(attrs) do
      {:ok, meeting, replay_invites(meeting, entries)}
    end
  end

  @doc "Deliver each staged entry; return the ones that produced no invite."
  @spec replay_invites(Meetings.Meeting.t(), [entry()]) :: [entry()]
  def replay_invites(meeting, entries) do
    Enum.reject(entries, &match?({:ok, _}, deliver(meeting, &1)))
  end

  defp deliver(meeting, %{kind: :user} = entry),
    do: Meetings.invite_user(meeting, entry.user_id, display_name: entry[:display_name])

  defp deliver(meeting, %{kind: :guest} = entry),
    do: Meetings.invite_guest(meeting, %{display_name: entry.display_name, email: entry.email})

  defp deliver(meeting, %{kind: :external} = entry),
    do: Meetings.invite_external_user(meeting, entry.email, display_name: entry[:display_name])

  defp deliver(_meeting, _entry), do: {:error, :invalid_entry}
end
