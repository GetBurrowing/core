defmodule PlatformWeb.MeetingLiveGuestInviteTest do
  @moduledoc """
  Tests for the host-side "Copy guest link" affordance shipped in stage 4
  of task 019f2483 (guest meetings).

  Coverage:
    * Non-host viewers do NOT see the "Copy guest link" button — the
      trigger is `host?/2`-gated on the current participant matching
      `meeting.host_participant_id`.
    * Host viewer clicks the trigger, the bottom-sheet opens (dialog
      surface `data-role="guest-invite-sheet"` appears).
    * Generate with an explicit display_name mints a URL of the form
      `https://<host>/<meeting_slug>/<token>`. Verifying the token via
      `Platform.Meetings.GuestInvite.verify/1` returns the payload with
      the same display_name AND the id of the newly-provisioned guest
      chat space.
    * Generate without a display_name — the payload's display_name is
      `nil` (self-entry flow), the sheet's helper text switches to
      "They'll enter their name before joining."
    * Each generate creates exactly one new `guest_meeting`-kind chat
      space (`Meetings.create_guest_chat_space/2` called once per
      submit), verified by counting `Chat.list_spaces`-style delta.
    * The Copy button pushes a `guest_invite_copied` browser event so a
      top-level toast can confirm the copy.

  The rail's "via guest link" annotation is exercised in
  `PlatformWeb.Components.Meetings.ParticipantRailTest` by rendering a
  participant with a `" (guest)"` suffix directly — that unit-level
  render doesn't require the LiveView roundtrip here.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.GuestInvite
  alias Platform.Tasks.Project

  # ─── Fixtures ─────────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "guestinvite_#{System.unique_integer([:positive])}@example.com",
        name: "Guest Invite Host",
        oidc_sub: "oidc-guestinvite-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Guest Invite Space #{System.unique_integer([:positive])}",
        slug: "guest-invite-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_project do
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Guest Invite Project #{System.unique_integer([:positive])}",
        slug: "guest-invite-project-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  defp create_meeting(attrs \\ %{}) do
    space = Map.get_lazy(attrs, :space, fn -> create_space() end)
    project = Map.get_lazy(attrs, :project, fn -> create_project() end)
    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: Map.get(attrs, :slug, "guest-invite-#{System.unique_integer([:positive])}"),
        name: Map.get(attrs, :name, "Guest Invite Meeting"),
        livekit_room_name: "meeting-#{meeting_id}",
        host_participant_id: Map.get(attrs, :host_participant_id)
      })
      |> Repo.insert()

    {meeting, space}
  end

  # Insert a `Chat.Participant` for `user` in `space` and promote them to
  # host by writing `host_participant_id` on the meeting. Returns the
  # updated meeting so tests see the fresh assign after `live/2` mounts.
  defp promote_to_host(meeting, space, %User{id: user_id}) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: "Guest Invite Host",
        joined_at: DateTime.utc_now()
      })

    {:ok, meeting} =
      meeting
      |> Ecto.Changeset.change(host_participant_id: participant.id)
      |> Repo.update()

    {meeting, participant}
  end

  # Count spaces with `kind = "guest_meeting"` that reference this
  # meeting's id in their metadata. Used to assert exactly one new guest
  # space per generate-click.
  defp count_guest_spaces_for_meeting(meeting) do
    import Ecto.Query

    Repo.aggregate(
      from(s in Platform.Chat.Space,
        where: s.kind == "guest_meeting",
        where: fragment("?->>'meeting_id' = ?", s.metadata, ^meeting.id)
      ),
      :count
    )
  end

  # Extract the guest URL from the sheet's rendered HTML. The URL sits in
  # the readonly `<input id="guest-invite-url" value="...">`, so a targeted
  # regex against that input's `value` attribute avoids brittle
  # positional parsing.
  defp extract_guest_invite_url(html) do
    case Regex.run(~r/id="guest-invite-url"[^>]*value="([^"]+)"/, html) do
      [_, url] -> url
      _ -> nil
    end
  end

  # ─── Tests ────────────────────────────────────────────────────────────────

  describe "host visibility of the Copy guest link trigger" do
    test "non-host viewer does NOT see the Copy guest link button", %{conn: conn} do
      {meeting, _space} = create_meeting()
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-role="meeting-copy-guest-link")
    end

    test "host viewer sees the Copy guest link button", %{conn: conn} do
      {meeting, space} = create_meeting()
      {conn, user} = authenticated_conn(conn)
      {_meeting, _participant} = promote_to_host(meeting, space, user)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-role="meeting-copy-guest-link")
      # Hero icon only, no emoji.
      assert html =~ "hero-link"
    end
  end

  describe "opening the sheet" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting()
      {conn, user} = authenticated_conn(conn)
      {meeting, _participant} = promote_to_host(meeting, space, user)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "the sheet is hidden until the host clicks the trigger", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Not present on initial mount.
      refute html =~ ~s(data-role="guest-invite-sheet")

      # Click the trigger.
      open_html =
        view
        |> element(~s([data-role="meeting-copy-guest-link"]))
        |> render_click()

      assert open_html =~ ~s(data-role="guest-invite-sheet")
      assert open_html =~ ~s(id="guest-invite-form")
      assert open_html =~ ~s(name="guest_invite[display_name]")
      assert open_html =~ ~s(name="guest_invite[expires_in_hours]")
    end

    test "backdrop click closes the sheet", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      open_html =
        view
        |> element(~s([data-role="meeting-copy-guest-link"]))
        |> render_click()

      assert open_html =~ ~s(data-role="guest-invite-sheet")

      closed_html =
        view
        |> element(~s([data-role="guest-invite-sheet-backdrop"]))
        |> render_click()

      refute closed_html =~ ~s(data-role="guest-invite-sheet")
    end
  end

  describe "generating an invite" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting()
      {conn, user} = authenticated_conn(conn)
      {meeting, _participant} = promote_to_host(meeting, space, user)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "submit with display_name mints a URL containing the meeting slug + verifiable token",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Open the sheet.
      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      before_count = count_guest_spaces_for_meeting(meeting)

      generated_html =
        view
        |> form("#guest-invite-form", %{
          guest_invite: %{"display_name" => "Juno Fairbanks", "expires_in_hours" => "24"}
        })
        |> render_submit()

      # URL surface is present.
      assert generated_html =~ ~s(data-role="guest-invite-generated")
      assert generated_html =~ ~s(data-role="guest-invite-url")

      url = extract_guest_invite_url(generated_html)
      assert is_binary(url)
      assert url =~ "/#{meeting.slug}/"

      # Token is the third path segment. Verify it round-trips.
      %URI{path: path} = URI.parse(url)
      ["", slug, token] = String.split(path, "/", parts: 3)
      assert slug == meeting.slug

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_slug == meeting.slug
      assert payload.display_name == "Juno Fairbanks"
      assert is_binary(payload.guest_space_id)

      # Exactly one new guest space was provisioned.
      after_count = count_guest_spaces_for_meeting(meeting)
      assert after_count == before_count + 1

      # The payload's guest_space_id points at a real Chat.Space of kind
      # "guest_meeting" whose metadata carries this meeting's id.
      space = Repo.get!(Platform.Chat.Space, payload.guest_space_id)
      assert space.kind == "guest_meeting"
      assert space.metadata["meeting_id"] == meeting.id
    end

    test "submit without display_name yields a token with display_name: nil (self-entry)",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      generated_html =
        view
        |> form("#guest-invite-form", %{
          guest_invite: %{"display_name" => "", "expires_in_hours" => "1"}
        })
        |> render_submit()

      url = extract_guest_invite_url(generated_html)
      assert is_binary(url)

      %URI{path: path} = URI.parse(url)
      ["", _slug, token] = String.split(path, "/", parts: 3)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.display_name)

      # Helper text reflects self-entry mode.
      assert generated_html =~ "They&#39;ll enter their name before joining."
      refute generated_html =~ "will land directly."
    end

    test "submit with display_name shows the direct-land helper text", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      generated_html =
        view
        |> form("#guest-invite-form", %{
          guest_invite: %{"display_name" => "Juno Fairbanks", "expires_in_hours" => "24"}
        })
        |> render_submit()

      assert generated_html =~ "Juno Fairbanks will land directly."
    end

    test "each generate provisions exactly one new guest chat space", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      before_count = count_guest_spaces_for_meeting(meeting)

      view
      |> form("#guest-invite-form", %{
        guest_invite: %{"display_name" => "Juno", "expires_in_hours" => "24"}
      })
      |> render_submit()

      assert count_guest_spaces_for_meeting(meeting) == before_count + 1

      # A second submit provisions a second space (no cross-invite reuse).
      view
      |> form("#guest-invite-form", %{
        guest_invite: %{"display_name" => "Another Guest", "expires_in_hours" => "24"}
      })
      |> render_submit()

      assert count_guest_spaces_for_meeting(meeting) == before_count + 2
    end

    test "expiry hours clamp to the sanctioned windows (1/24/72); malformed → 24", %{
      conn: conn,
      meeting: meeting
    } do
      # The `<select>` in the sheet is constrained to 1/24/72 via its
      # `<option>` values, so a form-submit test can't smuggle "9999" past
      # Phoenix.LiveViewTest's option validation. We exercise the clamp
      # via the raw event push (mimicking a hand-crafted phx-value from a
      # malicious client) — the server-side `parse_expires_hours/1`
      # defense is the real guard against a 10-year token.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      before_gen = :os.system_time(:second)

      generated_html =
        render_hook(view, "generate_guest_invite", %{
          "guest_invite" => %{"display_name" => "Test", "expires_in_hours" => "9999"}
        })

      after_gen = :os.system_time(:second)

      url = extract_guest_invite_url(generated_html)
      assert is_binary(url)
      %URI{path: path} = URI.parse(url)
      ["", _slug, token] = String.split(path, "/", parts: 3)

      assert {:ok, payload} = GuestInvite.verify(token)

      # Malformed "9999" falls back to 24h.
      twenty_four_hours = 24 * 60 * 60
      assert payload.expires_at >= before_gen + twenty_four_hours
      assert payload.expires_at <= after_gen + twenty_four_hours
    end
  end

  describe "copy button" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting()
      {conn, user} = authenticated_conn(conn)
      {meeting, _participant} = promote_to_host(meeting, space, user)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "the Copy button carries the CopyToClipboard hook + clipboard-text data attr", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      generated_html =
        view
        |> form("#guest-invite-form", %{
          guest_invite: %{"display_name" => "Juno", "expires_in_hours" => "24"}
        })
        |> render_submit()

      # The button is wired to the client-side hook (the actual clipboard
      # write is browser-side; we can't exercise it in an LV test).
      assert generated_html =~ ~s(phx-hook="CopyToClipboard")
      assert generated_html =~ ~s(data-role="guest-invite-copy")
      assert generated_html =~ ~s(data-clipboard-text=)

      # And the button carries a phx-click that pushes the confirmation
      # event so a top-level toast hook can react.
      assert generated_html =~ ~s(phx-click="copy_guest_invite")
    end

    test "clicking Copy pushes a guest_invite_copied browser event", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-role="meeting-copy-guest-link"]))
      |> render_click()

      view
      |> form("#guest-invite-form", %{
        guest_invite: %{"display_name" => "Juno", "expires_in_hours" => "24"}
      })
      |> render_submit()

      # phx-click="copy_guest_invite" pushes the browser event.
      view
      |> element(~s([data-role="guest-invite-copy"]))
      |> render_click()

      assert_push_event(view, "guest_invite_copied", %{})
    end
  end
end
