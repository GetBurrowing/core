defmodule PlatformWeb.ChatLive.MeetingHumanInvite do
  @moduledoc """
  The name-first Invite control inside the HUMANS section of a live call's
  participant list (task 01a18d0a-ec37 stage 2, design canvas
  `01a18d0b-4f5a`). One module serves both call surfaces: `/meetings`
  (`PlatformWeb.MeetingLive`) and the in-chat quickmeet
  (`PlatformWeb.ChatLive`). Both attach `PlatformWeb.ChatLive.MeetingHooks`,
  whose event hook forwards every `meeting_human_invite_*` event here, and
  both render the control through `CallShell.call_rail/1`'s `:human_invite`
  attr, built by `rail_state/1`. So desktop, phone and quickmeet run one
  code path.

  ## The meeting is the ACTIVE CALL's

  `active_meeting/1` reads `:meeting` (the meeting a `/meetings/:slug` socket
  resolved in `handle_params/3`) and falls back to `:quickmeet_meeting` (the
  live meeting a quickmeet joined). It never reads the calendar selection
  (`:selected_meeting_id`), which belongs to the index page's detail panel.

  ## Dropdown data

  Exactly `Meetings.resolve_invite_candidates/2`, called the way
  `MeetingLive`'s `assign_live_invite_candidates/2` calls it: the meeting's
  written invites are excluded by user id and email. No second query. The
  guest row is NOT data: the component renders it from the typed string
  whenever `String.trim(query) != ""` and a guest host is configured. That
  is the caller-side inversion of the resolver's "guest only when no member
  matches" rule that the architecture review asked for, so the resolver's
  contract is unchanged.

  ## Server-side gates

  Every event re-checks `Meetings.human_inviter?/2` against the socket's
  `:current_user_record`, so a forged event from a viewer without access
  writes nothing. Anonymous guests never reach this module: their sockets
  run `MeetingHooks.attach_guest/1`, whose hook halts these events as
  no-ops. A user id must come from the RENDERED candidate list (an id from
  anywhere else raises, as `deliver_live_invite/4` does). A blank query
  creates nothing. An unset guest host refuses the guest row server-side
  (`Meetings.invite_guest/2` writes no row, space or code).
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting

  @events ~w(meeting_human_invite_search meeting_human_invite_user meeting_human_invite_guest
             meeting_human_invite_dismiss meeting_human_invite_email_open
             meeting_human_invite_email)

  @doc "Every event this module owns. `MeetingHooks` routes on this list."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Seed the control's assigns. `assign_new/3`, so a re-attach keeps state."
  @spec seed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def seed(socket) do
    socket
    |> assign_new(:human_invite_query, fn -> "" end)
    |> assign_new(:human_invite_users, fn -> [] end)
    |> assign_new(:human_invite_result, fn -> nil end)
    |> assign_new(:human_invite_error, fn -> nil end)
    |> assign_new(:human_invite_invited_ids, fn -> MapSet.new() end)
    |> assign_new(:human_invite_gen, fn -> 0 end)
  end

  @doc """
  The meeting of the call this socket is in: `:meeting` on `/meetings`,
  else `:quickmeet_meeting`. `nil` when there is no meetings row (a raw
  LiveKit room), in which case there is nothing an invite row could hang
  off and the control does not render.
  """
  @spec active_meeting(map()) :: Meeting.t() | nil
  def active_meeting(assigns) do
    case assigns[:meeting] do
      %Meeting{} = meeting ->
        meeting

      _ ->
        case assigns[:quickmeet_meeting] do
          %Meeting{} = meeting -> meeting
          _ -> nil
        end
    end
  end

  @doc """
  The `:human_invite` state `CallShell.call_rail/1` forwards to
  `ParticipantRail.participant_rail/1`, or `nil` when this viewer gets no
  control (no signed-in account, or no meeting row).

  Pure: reads assigns and application config only, never the database, so
  it is safe to call during render. The access check happens per event.
  """
  @spec rail_state(map(), String.t()) :: map() | nil
  def rail_state(assigns, id) do
    with %{id: user_id} when is_binary(user_id) <- assigns[:current_user_record],
         %Meeting{} <- active_meeting(assigns) do
      %{
        id: id,
        query: assigns[:human_invite_query] || "",
        users: assigns[:human_invite_users] || [],
        guest_host?: GuestInvite.guest_host_configured?(),
        result: assigns[:human_invite_result],
        error: assigns[:human_invite_error],
        gen: assigns[:human_invite_gen] || 0
      }
    else
      _ -> nil
    end
  end

  @doc """
  Handle one of `events/0`. Always `{:halt, socket}`: neither host LiveView
  has a clause for these events.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:halt, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) when event in @events do
    socket = seed(socket)

    case authorized_meeting(socket) do
      %Meeting{} = meeting -> {:halt, do_event(event, params, meeting, socket)}
      nil -> {:halt, refuse(socket)}
    end
  end

  defp authorized_meeting(socket) do
    meeting = active_meeting(socket.assigns)

    if Meetings.human_inviter?(meeting, socket.assigns[:current_user_record]),
      do: meeting,
      else: nil
  end

  # Nothing is written. The viewer is told, rather than the click looking
  # dead, but the message names no meeting and no person.
  defp refuse(socket) do
    socket
    |> clear_search()
    |> put_flash(:error, "You can't invite people to this meeting.")
  end

  defp do_event("meeting_human_invite_search", params, meeting, socket) do
    query = params |> Map.get("query", Map.get(params, "value", "")) |> to_string()
    assign_candidates(socket, meeting, query)
  end

  # A second click on a row this socket just invited from (a double-click:
  # the first click already closed the list) is a no-op, not a forged id.
  defp do_event("meeting_human_invite_user", %{"id" => user_id}, meeting, socket) do
    if MapSet.member?(socket.assigns.human_invite_invited_ids, {meeting.id, user_id}),
      do: socket,
      else: invite_offered_user(socket, meeting, user_id)
  end

  defp do_event("meeting_human_invite_guest", _params, meeting, socket) do
    name = String.trim(socket.assigns.human_invite_query)

    cond do
      name == "" ->
        socket

      not GuestInvite.guest_host_configured?() ->
        socket
        |> clear_search()
        |> assign(:human_invite_error, "Guest links are not available here.")

      true ->
        invite_guest(socket, meeting, name)
    end
  end

  defp do_event("meeting_human_invite_dismiss", _params, _meeting, socket) do
    socket
    |> assign(:human_invite_result, nil)
    |> assign(:human_invite_error, nil)
  end

  defp do_event("meeting_human_invite_email_open", _params, _meeting, socket) do
    update_result(socket, &Map.merge(&1, %{email_open?: true, email_error: nil}))
  end

  defp do_event("meeting_human_invite_email", params, meeting, socket) do
    case socket.assigns.human_invite_result do
      %{invite: %Invite{} = invite} ->
        case Meetings.add_guest_invite_email(meeting, invite, Map.get(params, "email", "")) do
          {:ok, updated} ->
            update_result(
              socket,
              &Map.merge(&1, %{invite: updated, email_open?: false, email_error: nil})
            )

          {:error, changeset} ->
            update_result(socket, &Map.put(&1, :email_error, email_error(changeset)))
        end

      _ ->
        socket
    end
  end

  # A malformed payload for a known event is a forged one: nothing written.
  defp do_event(_event, _params, _meeting, socket), do: socket

  # The id must name a row this socket RENDERED; anything else is forged and
  # raises, as `MeetingLive`'s `deliver_live_invite/4` does.
  defp invite_offered_user(socket, meeting, user_id) do
    user =
      Enum.find(socket.assigns.human_invite_users, &(&1.id == user_id)) ||
        raise ArgumentError, "cannot invite: no candidate is currently offered for that id"

    case Meetings.invite_user(meeting, user.id,
           display_name: user.name || user.email,
           inviter_user_id: socket.assigns[:current_user_record].id
         ) do
      {:ok, %Invite{}} ->
        socket
        |> clear_search()
        |> assign(
          :human_invite_invited_ids,
          MapSet.put(socket.assigns.human_invite_invited_ids, {meeting.id, user.id})
        )
        |> put_flash(:info, "Invited #{user.name || user.email}.")

      {:error, _changeset} ->
        assign(socket, :human_invite_error, "That invite could not be sent.")
    end
  end

  defp invite_guest(socket, meeting, name) do
    case Meetings.invite_guest(meeting, %{
           display_name: name,
           email: nil,
           host_user_id: socket.assigns[:current_user_record].id
         }) do
      {:ok, %{invite: invite, url: url}} ->
        socket
        |> clear_search()
        |> assign(:human_invite_result, %{
          invite: invite,
          name: invite.display_name,
          url: url,
          email_open?: false,
          email_error: nil
        })

      {:error, :guest_host_not_configured} ->
        socket
        |> clear_search()
        |> assign(:human_invite_error, "Guest links are not available here.")

      {:error, _reason} ->
        assign(socket, :human_invite_error, "That guest link could not be created.")
    end
  end

  # The exclusions come from the WRITTEN rows, exactly as
  # `MeetingLive.assign_live_invite_candidates/2` builds them.
  defp assign_candidates(socket, meeting, query) do
    users =
      if String.trim(query) == "" do
        []
      else
        invites = Meetings.list_invites(meeting.id)

        %{users: users} =
          Meetings.resolve_invite_candidates(query,
            exclude_user_ids: for(%Invite{user_id: id} <- invites, is_binary(id), do: id),
            exclude_emails:
              for(%Invite{email: address} <- invites, is_binary(address), do: address)
          )

        users
      end

    socket
    |> assign(:human_invite_query, query)
    |> assign(:human_invite_users, users)
    |> assign(:human_invite_error, nil)
  end

  # Bumping `:human_invite_gen` re-keys the input (see `InviteControl.
  # human_invite/1`): LiveView never overwrites the value of a FOCUSED input
  # from the server, so without a fresh element the field would keep showing
  # the name that was just invited while the server holds "".
  defp clear_search(socket) do
    socket
    |> assign(:human_invite_gen, (socket.assigns[:human_invite_gen] || 0) + 1)
    |> assign(:human_invite_query, "")
    |> assign(:human_invite_users, [])
    |> assign(:human_invite_error, nil)
  end

  defp update_result(socket, fun) do
    case socket.assigns.human_invite_result do
      %{} = result -> assign(socket, :human_invite_result, fun.(result))
      nil -> socket
    end
  end

  defp email_error(%Ecto.Changeset{errors: errors}) do
    case {Keyword.get(errors, :email), Keyword.get(errors, :id)} do
      {{message, _opts}, _} -> "Email #{message}."
      {nil, {_message, _opts}} -> "That invite no longer exists."
      {nil, nil} -> "That email could not be saved."
    end
  end
end
