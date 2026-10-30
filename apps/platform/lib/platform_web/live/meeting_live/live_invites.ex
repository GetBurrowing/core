defmodule PlatformWeb.MeetingLive.LiveInvites do
  @moduledoc """
  The `:live`-mode invite handlers of
  `PlatformWeb.Components.Meetings.InviteControl`, shared by every LiveView
  that renders a meeting's live invite list (task 01a19e7b stage 1).

  Moved out of `PlatformWeb.MeetingLive` unchanged so `PlatformWeb.CalendarLive`
  can drive the same control. Two LiveViews are separate processes, so one
  cannot delegate events to the other; sharing the handlers as plain
  functions over a socket is the only way both surfaces behave identically.

  ## What the caller owns

  These functions depend on exactly two facts about the caller's socket,
  and both are passed IN rather than read here:

    * which meeting is selected — the caller resolves it from its own
      viewer-scoped assigns and raises when there is none, so a client-sent
      id is never trusted;
    * who the inviter is — the caller's signed-in user id.

  Everything else lives in four assigns this module owns:
  `:meeting_invite_open`, `:meeting_invite_query`,
  `:meeting_invite_candidates` and `:meeting_invite_email`.

  ## No policy here

  This is a move, not a policy change. No host or organizer gate is applied
  (none existed in `MeetingLive`), and no meeting-wide invite link exists:
  invites are minted per person (see the `InviteControl` moduledoc).

  ## In live mode the invite is WRITTEN when chosen

  Unlike the create sheet's `:draft` set, there IS a meeting row here, so
  choosing someone writes a `meeting_invites` row and delivers the invite in
  the same call. Nothing is staged and there is no submit to lose it at.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting

  @guest_host_message "Guest links are not available: MEETING_GUEST_HOST is not configured."
  @undelivered_message "That invite could not be sent."

  @doc "Closed control, empty query, no candidates, no email option."
  def seed(socket) do
    socket
    |> assign(:meeting_invite_open, false)
    |> clear_search()
  end

  @doc "Reset, then open the search expansion (the Add people row)."
  def open(socket) do
    socket
    |> seed()
    |> assign(:meeting_invite_open, true)
  end

  @doc """
  Resolve `query` into candidates for `meeting_or_nil`.

  The exclusions come from the WRITTEN rows, not from a staging list: in
  live mode the invite exists the moment it is chosen, so "already invited"
  is a fact about the database. Without them the picker keeps offering
  someone who is already on the list one row above it.
  """
  def search(socket, meeting_or_nil, query) do
    query = to_string(query)

    invites =
      case meeting_or_nil do
        %Meeting{} = meeting -> Meetings.list_invites(meeting.id)
        nil -> []
      end

    %{users: users, email: email} =
      Meetings.resolve_invite_candidates(query,
        exclude_user_ids: for(%Invite{user_id: id} <- invites, is_binary(id), do: id),
        exclude_emails: for(%Invite{email: address} <- invites, is_binary(address), do: address)
      )

    socket
    |> assign(:meeting_invite_query, query)
    |> assign(:meeting_invite_candidates, users)
    |> assign(:meeting_invite_email, email)
  end

  @doc """
  Deliver one invite chosen in the control, then clear the search.

  A failure is a real runtime outcome, not a caller bug, so it is flashed
  rather than raised. A missing guest host is an OPERATOR fault and gets its
  own wording, so a deployment mistake is distinguishable from a bad email
  address (`invite_guest/2` already logged the same fact).
  """
  def stage(socket, %Meeting{} = meeting, %{"kind" => kind} = params, inviter_user_id) do
    socket =
      case deliver(
             meeting,
             kind,
             params,
             socket.assigns.meeting_invite_candidates,
             inviter_user_id
           ) do
        {:ok, _result} -> socket
        {:error, :guest_host_not_configured} -> put_flash(socket, :error, @guest_host_message)
        {:error, _reason} -> put_flash(socket, :error, @undelivered_message)
      end

    clear_search(socket)
  end

  @doc """
  Enter in the search box (the `InviteSearchEnter` hook, task 01a192d6).

  The hook sends the RAW typed value, because the dropdown only exists after
  the debounced search round trip and a fast type-then-Enter would find no
  option to click. So this re-resolves the query and then stages exactly the
  option the dropdown highlights, through `stage/4`, so every guard on a
  click applies to Enter too. Several candidates is a choice the user has
  to make, so nothing is staged.

  Returns `{:staged, socket}` or `{:noop, socket}`; the caller replies
  `%{staged: true}` on the former so the hook clears the box.
  """
  def commit(socket, meeting, value, inviter_user_id) do
    value = to_string(value)

    if String.trim(value) == "" do
      {:noop, socket}
    else
      socket = search(socket, meeting, value)

      case commit_params(
             socket.assigns.meeting_invite_candidates,
             socket.assigns.meeting_invite_email
           ) do
        nil -> {:noop, socket}
        params -> {:staged, stage(socket, meeting, params, inviter_user_id)}
      end
    end
  end

  @doc """
  The option the invite dropdown highlights, as stage-event params, or nil
  when it highlights none. Mirrors `InviteControl`'s dropdown dispatch: one
  candidate is the only row; no candidates plus an address is the
  `data-default` guest row. Shared with the create sheet's draft mode.
  """
  def commit_params([%{id: id}], _email), do: %{"kind" => "user", "id" => id}

  def commit_params([], email) when is_binary(email),
    do: %{"kind" => "guest", "email" => email}

  def commit_params(_candidates, _email), do: nil

  @doc """
  Write and deliver one invite of `kind` for `meeting`.

  `"user"` resolves against the RENDERED `candidates` rather than the
  database, the same rule the draft path follows: the only legal source of
  that id is a row this socket just drew. An absent id, or an unknown kind,
  did not come from the control and raises.
  """
  def deliver(meeting, "user", %{"id" => user_id}, candidates, inviter_user_id) do
    case Enum.find(candidates, &(&1.id == user_id)) do
      nil ->
        raise ArgumentError,
              "cannot invite: no candidate is currently offered for that id"

      user ->
        # The inviter is named so a meeting that is LIVE right now rings
        # the invitee (task 01a10db7 stage 2, rule R3); for a scheduled
        # meeting this is the same alert-push invite as before.
        Meetings.invite_user(meeting, user.id,
          display_name: user.name || user.email,
          inviter_user_id: inviter_user_id
        )
    end
  end

  def deliver(meeting, "guest", %{"email" => email}, _candidates, inviter_user_id) do
    address = email |> to_string() |> String.trim()

    Meetings.invite_guest(meeting, %{
      display_name: address,
      email: address,
      host_user_id: inviter_user_id
    })
  end

  # A guest chosen by NAME: `invite_guest/2` needs only a display name, so
  # no email-only path is required (task 01a18d0a-ec37 stage 2). A blank
  # name writes nothing.
  def deliver(meeting, "guest", %{"name" => name}, _candidates, inviter_user_id) do
    case String.trim(to_string(name)) do
      "" ->
        {:error, :blank_name}

      trimmed ->
        Meetings.invite_guest(meeting, %{
          display_name: trimmed,
          email: nil,
          host_user_id: inviter_user_id
        })
    end
  end

  def deliver(meeting, "external", %{"email" => email}, _candidates, _inviter_user_id) do
    address = email |> to_string() |> String.trim()

    Meetings.invite_external_user(meeting, address, display_name: address)
  end

  def deliver(_meeting, kind, _params, _candidates, _inviter_user_id) do
    raise ArgumentError, "no live invite kind #{inspect(kind)}"
  end

  defp clear_search(socket) do
    socket
    |> assign(:meeting_invite_query, "")
    |> assign(:meeting_invite_candidates, [])
    |> assign(:meeting_invite_email, nil)
  end
end
