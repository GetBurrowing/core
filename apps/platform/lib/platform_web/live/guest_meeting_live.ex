defmodule PlatformWeb.GuestMeetingLive do
  @moduledoc """
  Stripped meeting shell for guest ingress via `meet.example.com`.

  Mounted on the `meet.` host scope only (see `PlatformWeb.Router` — the
  `scope "/", host: "meet."` block wires this LV under the `:guest`
  live_session). Renders one of three states:

    * `:invalid` / `:expired` — the invite token failed to verify.
      Shows an apology card with a single "Go to example.com"
      link (no sign-in CTA — guests generally don't have accounts).
    * `:name_entry` — token verified but the invite carries `display_name: nil`.
      Renders a centered card with a single input + submit for the
      guest to type their own name.
    * `:in_meeting` — the LiveKit token has been minted (either from a
      pre-provisioned name in the invite payload, or from the
      name-entry form submit). The LV renders a minimal video stage
      that mounts `phx-hook="MeetingClient"` and pushes `join-meeting`
      with the token bundle.

  ## Token bundle contract

  The `join-meeting` push_event mirrors `ChatLive.MeetingHooks.do_join/1`
  (see `meeting_hooks.ex`): `{token, url, room_name, space_slug}`. The
  MeetingClient JS hook consumes exactly `{token, url}` (see
  `apps/platform/assets/js/hooks/meeting_client.js:457`), so those are
  the load-bearing keys. The extras (`room_name`, `space_slug`) are kept
  for symmetry with the authenticated path and to aid debug logs.

  ## No sidebar / no other chrome

  The `guest_root` + `guest` layouts (see `PlatformWeb.Layouts`) render
  a bare `<html>` document with no shell chrome. That's a hard invariant
  — a guest must not see or reach the sidebar / auth surfaces. Screening
  the tests via `refute html =~ "shell-sidebar"` + `refute html =~ "icon-rail"`
  pins that.
  """
  use PlatformWeb, :live_view

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite

  @impl true
  def mount(%{"slug" => slug, "token" => token}, _session, socket) do
    socket = assign(socket, :meeting_slug, slug)

    case GuestInvite.verify(token) do
      {:error, :expired} ->
        {:ok,
         socket
         |> assign(:page_title, "This invite has expired")
         |> assign(:state, :expired)
         |> assign(:token, token)}

      {:error, :invalid} ->
        {:ok,
         socket
         |> assign(:page_title, "Invite link is not valid")
         |> assign(:state, :invalid)
         |> assign(:token, token)}

      {:ok, %{meeting_slug: payload_slug}} when payload_slug != slug ->
        # Slug tampering: URL says one meeting, payload says another. Treat
        # as invalid rather than trusting the payload — the URL is what the
        # host shared with the guest.
        {:ok,
         socket
         |> assign(:page_title, "Invite link is not valid")
         |> assign(:state, :invalid)
         |> assign(:token, token)}

      {:ok, %{meeting_slug: ^slug, display_name: display_name}} ->
        case Meetings.get_meeting_by_slug(slug) do
          nil ->
            # Signature checked out but the target meeting has been
            # deleted or the slug never existed. Treat as invalid.
            {:ok,
             socket
             |> assign(:page_title, "Invite link is not valid")
             |> assign(:state, :invalid)
             |> assign(:token, token)}

          meeting ->
            mount_verified(socket, meeting, display_name)
        end
    end
  end

  # Verified branch: split by whether the payload carried a display_name.
  # `nil` → render the name-entry form; a binary → mint the LiveKit token
  # immediately and land in :in_meeting.
  defp mount_verified(socket, meeting, nil) do
    {:ok,
     socket
     |> assign(:page_title, "Join #{meeting.name}")
     |> assign(:meeting, meeting)
     |> assign(:state, :name_entry)
     |> assign(:name_error, nil)
     |> assign(:name_value, "")}
  end

  defp mount_verified(socket, meeting, display_name) when is_binary(display_name) do
    case Meetings.guest_livekit_token(meeting, display_name) do
      {:ok, bundle} ->
        {:ok,
         socket
         |> assign(:page_title, meeting.name)
         |> assign(:meeting, meeting)
         |> assign(:state, :in_meeting)
         |> assign(:token, bundle.token)
         |> assign(:identity, bundle.identity)
         |> assign(:room_name, bundle.room_name)
         |> assign(:livekit_url, bundle.livekit_url)
         |> assign(:display_name, display_name)
         |> push_join_event(bundle, meeting)}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:page_title, "Invite link is not valid")
         |> assign(:state, :invalid)
         |> assign(:token_error, reason)}
    end
  end

  # No-slug or no-token param — cover the defensive case so a hand-crafted
  # URL doesn't crash the LV. Router already binds both, so this is
  # belt-and-suspenders.
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Invite link is not valid")
     |> assign(:state, :invalid)
     |> assign(:meeting_slug, nil)}
  end

  @impl true
  def handle_event("submit_name", %{"guest" => %{"name" => name}}, socket) do
    trimmed = name |> to_string() |> String.trim()

    cond do
      trimmed == "" ->
        {:noreply,
         socket
         |> assign(:name_error, "Please enter your name.")
         |> assign(:name_value, name)}

      String.length(trimmed) > 80 ->
        {:noreply,
         socket
         |> assign(:name_error, "Name is too long.")
         |> assign(:name_value, name)}

      true ->
        meeting = socket.assigns.meeting

        case Meetings.guest_livekit_token(meeting, trimmed) do
          {:ok, bundle} ->
            {:noreply,
             socket
             |> assign(:state, :in_meeting)
             |> assign(:name_error, nil)
             |> assign(:token, bundle.token)
             |> assign(:identity, bundle.identity)
             |> assign(:room_name, bundle.room_name)
             |> assign(:livekit_url, bundle.livekit_url)
             |> assign(:display_name, trimmed)
             |> push_join_event(bundle, meeting)}

          {:error, :livekit_not_configured} ->
            {:noreply,
             assign(
               socket,
               :name_error,
               "Meetings are not available right now. Please try again later."
             )}

          {:error, _other} ->
            {:noreply, assign(socket, :name_error, "Something went wrong. Please try again.")}
        end
    end
  end

  def handle_event("submit_name", _params, socket) do
    {:noreply, assign(socket, :name_error, "Please enter your name.")}
  end

  # Push `join-meeting` with the same key set MeetingClient consumes on the
  # authenticated path (see meeting_hooks.ex `do_join/1`). MeetingClient
  # only needs `token` + `url`; `room_name` + `space_slug` are surfaced
  # for parity + debug.
  defp push_join_event(socket, bundle, meeting) do
    push_event(socket, "join-meeting", %{
      token: bundle.token,
      url: bundle.livekit_url,
      room_name: bundle.room_name,
      space_slug: meeting.chat_space && meeting.chat_space.slug
    })
  end
end
