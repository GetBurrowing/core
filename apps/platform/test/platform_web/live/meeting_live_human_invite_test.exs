defmodule PlatformWeb.MeetingLiveHumanInviteTest do
  @moduledoc """
  Task 01a18d0a-ec37 stage 2: the name-first Invite control inside the
  HUMANS section of the live call's participant list on `/meetings`.

  Driven through a real mounted `MeetingLive` and the real events, so each
  claim is about what the page draws and what a click writes. The stage's
  named fixture person is replaced by a neutral name here, because
  `InstallIdentityGuardTest` refuses real personal names in tracked files.

  Every "writes nothing" assertion reads the `meeting_invites` table, not the
  page: a refusal that only hides a button is not a refusal.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.GuestShortCode
  alias Platform.Meetings.Invite
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @control ~s(#meeting-call-rail [data-section="humans"] [data-role="meeting-human-invite"])
  @form "#meeting-call-rail-human-invite-form"

  setup %{conn: conn} do
    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    original_host = Application.get_env(:platform, :meeting_guest_host)
    Application.put_env(:platform, :meeting_guest_host, "meet.example.test")

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_host do
        nil -> Application.delete_env(:platform, :meeting_guest_host)
        value -> Application.put_env(:platform, :meeting_guest_host, value)
      end
    end)

    n = System.unique_integer([:positive])
    viewer = member!("viewer")
    # The "type their name" fixture: an internal user with a long email.
    target =
      Repo.insert!(%User{
        email: "dana.whitfield.#{n}.with.a.long.mailbox.name@example.test",
        name: "Dana Whitfield #{n}",
        oidc_sub: "oidc-human-invite-target-#{n}"
      })

    meeting = meeting!(viewer)
    conn = init_test_session(conn, current_user_id: viewer.id)

    {:ok, conn: conn, viewer: viewer, target: target, meeting: meeting}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp member!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "human-invite-#{label}-#{n}@example.test",
        name: "Human Invite #{label} #{n}",
        oidc_sub: "oidc-human-invite-#{label}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  # The viewer is a space participant but NOT the host: the control is for
  # any human with access, not host-only.
  defp meeting!(viewer) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Human Invite Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Human Invite Meeting #{n}",
        slug: "human-invite-meeting-#{n}"
      })

    {:ok, _participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: viewer.id,
        display_name: viewer.name,
        joined_at: DateTime.utc_now()
      })

    meeting
  end

  defp mount(conn, meeting) do
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")
    view
  end

  defp type(view, query), do: view |> form(@form, %{query: query}) |> render_change()

  defp invites(meeting) do
    Repo.all(from(i in Invite, where: i.meeting_id == ^meeting.id, order_by: i.inserted_at))
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp roles_in_dropdown(html) do
    html
    |> doc()
    |> LazyHTML.query(~s([data-role="meeting-human-invite-dropdown"] > button))
    |> Enum.map(&(&1 |> LazyHTML.attribute("data-role") |> List.first()))
  end

  # ── Placement ─────────────────────────────────────────────────────────

  describe "placement" do
    test "the Invite control sits inside the humans section, even when that section is empty",
         %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)

      # Nobody has joined the LiveKit room, so the human list is empty.
      assert has_element?(view, ~s(#meeting-call-rail [data-section="humans"]), "No people yet.")
      assert has_element?(view, @control)
      assert has_element?(view, ~s(#{@control} input[placeholder="Type a name…"]))
      # Exactly once in the document: the desktop left rail carries none.
      assert view
             |> render()
             |> doc()
             |> LazyHTML.query(~s([data-role="meeting-human-invite"]))
             |> Enum.count() == 1
    end
  end

  # ── The dropdown ──────────────────────────────────────────────────────

  describe "typing a name" do
    test "offers the user row AND the guest row, guest last",
         %{conn: conn, meeting: meeting, target: target} do
      view = mount(conn, meeting)
      html = type(view, target.name)

      assert has_element?(
               view,
               ~s([data-role="meeting-human-invite-user"][data-user-id="#{target.id}"])
             )

      assert List.last(roles_in_dropdown(html)) == "meeting-human-invite-guest"
      assert "meeting-human-invite-user" in roles_in_dropdown(html)

      assert has_element?(
               view,
               ~s([data-role="meeting-human-invite-guest-label"]),
               ~s(Invite "#{target.name}" as guest)
             )
    end

    test "a name matching nobody still shows the guest row", %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)
      html = type(view, "Nobody Matches This #{System.unique_integer([:positive])}")

      assert roles_in_dropdown(html) == ["meeting-human-invite-guest"]
    end

    test "the external-email option never appears beside a member match",
         %{conn: conn, meeting: meeting, target: target} do
      view = mount(conn, meeting)
      html = type(view, target.email)

      assert has_element?(
               view,
               ~s([data-role="meeting-human-invite-user"][data-user-id="#{target.id}"])
             )

      refute html =~ ~s(data-option="external")
      # The resolver's mutual exclusion is unchanged.
      assert %{users: [_ | _], email: nil} = Meetings.resolve_invite_candidates(target.email)
    end
  end

  # ── Choosing ──────────────────────────────────────────────────────────

  describe "choosing the user row" do
    test "writes a user invite, and a second submit is idempotent",
         %{conn: conn, meeting: meeting, target: target, viewer: viewer} do
      view = mount(conn, meeting)

      type(view, target.name)
      render_click(view, "meeting_human_invite_user", %{"id" => target.id})

      assert [%Invite{user_id: user_id, display_name: name}] = invites(meeting)
      assert user_id == target.id
      assert name == target.name
      refute user_id == viewer.id

      # A duplicate submit (a double-click: the list already closed) is a
      # no-op, not a crash and not a second row.
      render_click(view, "meeting_human_invite_user", %{"id" => target.id})
      assert Process.alive?(view.pid)
      assert length(invites(meeting)) == 1

      # Already invited: the resolver drops him, the guest row stays.
      html = type(view, target.name)
      assert roles_in_dropdown(html) == ["meeting-human-invite-guest"]
    end
  end

  describe "choosing the guest row" do
    test "writes a guest invite with no email and shows the persistent /g/ result",
         %{conn: conn, meeting: meeting, target: target} do
      view = mount(conn, meeting)

      type(view, "  #{target.name}  ")
      html = render_click(view, "meeting_human_invite_guest", %{})

      assert [%Invite{user_id: nil, email: nil} = invite] = invites(meeting)
      assert invite.display_name == target.name
      assert GuestShortCode.valid_format?(invite.short_code)

      link =
        html
        |> doc()
        |> LazyHTML.query(~s([data-role="meeting-human-invite-link"]))
        |> LazyHTML.text()

      assert String.trim(link) == "https://meet.example.test/g/" <> invite.short_code
      assert byte_size(invite.short_code) == 22

      assert has_element?(view, ~s([data-role="meeting-human-invite-copy"]), "Copy link")
      assert has_element?(view, ~s([data-role="meeting-human-invite-add-email"]))
      refute has_element?(view, ~s([data-role="meeting-human-invite-email-form"]))
      # The guest row is replaced: the dropdown has closed.
      refute has_element?(view, ~s([data-role="meeting-human-invite-dropdown"]))

      # Persistent: a later render (typing again) keeps it until dismissed.
      type(view, "someone else")
      assert has_element?(view, ~s([data-role="meeting-human-invite-result"]))
      render_click(view, "meeting_human_invite_dismiss", %{})
      refute has_element?(view, ~s([data-role="meeting-human-invite-result"]))
    end

    test "an already-invited user still gets a separate guest invite by name",
         %{conn: conn, meeting: meeting, target: target} do
      {:ok, _} = Meetings.invite_user(meeting, target.id)
      view = mount(conn, meeting)

      html = type(view, target.name)
      assert roles_in_dropdown(html) == ["meeting-human-invite-guest"]
      render_click(view, "meeting_human_invite_guest", %{})

      assert [%Invite{user_id: uid}, %Invite{user_id: nil, email: nil}] = invites(meeting)
      assert uid == target.id
    end

    test "whitespace creates nothing", %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)

      html = type(view, "    ")
      refute html =~ ~s(data-role="meeting-human-invite-dropdown")
      render_click(view, "meeting_human_invite_guest", %{})

      assert invites(meeting) == []
    end
  end

  # ── + Add email (optional) ────────────────────────────────────────────

  describe "+ Add email (optional)" do
    test "a valid address saves on the same row; an invalid one errors and keeps the link",
         %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)
      type(view, "Guest With Mail")
      render_click(view, "meeting_human_invite_guest", %{})
      [invite] = invites(meeting)

      render_click(view, "meeting_human_invite_email_open", %{})
      assert has_element?(view, ~s([data-role="meeting-human-invite-email-form"]))

      html =
        view
        |> form("#meeting-call-rail-human-invite-email-form", %{email: "not an address"})
        |> render_submit()

      assert html =~ ~s(data-role="meeting-human-invite-email-error")
      assert has_element?(view, ~s([data-role="meeting-human-invite-link"]))
      assert Repo.get!(Invite, invite.id).email == nil

      view
      |> form("#meeting-call-rail-human-invite-email-form", %{email: "guest@example.test"})
      |> render_submit()

      assert [%Invite{id: same_id, email: "guest@example.test"}] = invites(meeting)
      assert same_id == invite.id

      assert has_element?(
               view,
               ~s([data-role="meeting-human-invite-email-saved"]),
               "guest@example.test"
             )
    end
  end

  # ── Server-side gates ─────────────────────────────────────────────────

  describe "forged events" do
    test "a user id that was not rendered writes nothing",
         %{conn: conn, meeting: meeting, target: target} do
      stranger = member!("stranger")
      view = mount(conn, meeting)
      type(view, target.name)

      Process.flag(:trap_exit, true)
      catch_exit(render_click(view, "meeting_human_invite_user", %{"id" => stranger.id}))

      assert invites(meeting) == []
    end

    test "a meeting id in the payload is ignored: the invite lands on the ACTIVE call only",
         %{conn: conn, meeting: meeting, viewer: viewer} do
      other = meeting!(viewer)
      view = mount(conn, meeting)

      type(view, "Guest For This Call")
      render_click(view, "meeting_human_invite_guest", %{"meeting_id" => other.id})

      assert [_one] = invites(meeting)
      assert invites(other) == []
    end

    test "a viewer who lost access writes nothing", %{
      conn: conn,
      meeting: meeting,
      viewer: viewer
    } do
      view = mount(conn, meeting)
      type(view, "Guest After Revocation")

      Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^viewer.id))

      Repo.delete_all(
        from(p in Chat.Participant,
          where: p.space_id == ^meeting.chat_space_id and p.participant_id == ^viewer.id
        )
      )

      refute Meetings.human_inviter?(meeting, Repo.get!(User, viewer.id))

      render_click(view, "meeting_human_invite_guest", %{})

      assert :sys.get_state(view.pid).socket.assigns.flash["error"] ==
               "You can't invite people to this meeting."

      assert invites(meeting) == []
    end

    test "an anonymous guest gets no control and its forged events write nothing",
         %{meeting: meeting} do
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Anon Guest")

      {:ok, view, _html} =
        build_conn()
        |> Map.put(:host, "meet.localhost")
        |> live("/#{meeting.slug}/#{token}")

      refute has_element?(view, ~s([data-role="meeting-human-invite"]))

      render_click(view, "meeting_human_invite_search", %{"query" => "Anyone"})
      render_click(view, "meeting_human_invite_guest", %{})
      assert Process.alive?(view.pid)
      assert invites(meeting) == []
    end
  end

  describe "guest host unset" do
    test "hides the guest row and the server refuses: no invite, no code",
         %{conn: conn, meeting: meeting} do
      Application.delete_env(:platform, :meeting_guest_host)
      view = mount(conn, meeting)

      html = type(view, "Guest Without Host")
      refute html =~ ~s(data-role="meeting-human-invite-guest")

      render_click(view, "meeting_human_invite_guest", %{})
      assert invites(meeting) == []
    end
  end

  describe "Meetings.human_inviter?/2" do
    test "is not host-only, and refuses nil and a no-access user",
         %{meeting: meeting, viewer: viewer} do
      outsider =
        Repo.insert!(%User{
          email: "human-invite-outsider-#{System.unique_integer([:positive])}@example.test",
          name: "Outsider",
          oidc_sub: "oidc-human-invite-outsider-#{System.unique_integer([:positive])}"
        })

      assert Meetings.human_inviter?(meeting, viewer)
      refute Meetings.human_inviter?(meeting, nil)
      refute Meetings.human_inviter?(meeting, outsider)
      refute Meetings.human_inviter?(nil, viewer)
    end
  end
end
