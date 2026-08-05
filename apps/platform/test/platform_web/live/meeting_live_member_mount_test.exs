defmodule PlatformWeb.MeetingLiveMemberMountTest do
  @moduledoc """
  Task `019fb955-f8b1` stage 5 — the invited member's meeting surface on the
  `meet.` host.

  `chrome_mode: "none"` with NO `token` param is a combination that did not
  exist before this stage. It falls past the guest mount clause into the
  general `mount/3`, which leaves `:state` nil while `:user_id` is a real
  binary — so every render guard that spelled "guest" as `chrome_mode ==
  :none` was, from this stage on, wrong about who it was looking at. This
  file pins the corrected reading.

  ## Two host mechanisms, both required

  Routing here needs the `meet.` PREFIX (Phoenix's `host:` option). Being
  ADMITTED here needs the request host to equal the CONFIGURED `:meet_host`
  (`ExternalSurface`). The fixture host satisfies both deliberately —
  `ExternalUserScope` is fail-closed when `:meet_host` is unset, so a test
  that forgot the config would exercise the denial path and pass vacuously
  while proving nothing about the member surface. The `setup` block sets it
  and `external_user_scope_test.exs` owns the unset-config control.

  `async: false` — app-env mutation plus host-swapped conns, mirroring
  `meeting_live_guest_mount_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  # Satisfies BOTH mechanisms: `meet.` prefix for the router scope, exact
  # match for `ExternalSurface` once `:meet_host` is set to the same string.
  @meet_host "meet.example.com"

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp create_user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "member-mount-#{label}-#{n}@example.com",
      name: "MemberMount #{label} #{n}",
      oidc_sub: "oidc-member-mount-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_member_mount_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  # A real meeting through the real constructor (which mints the bound chat
  # space), in a project owned by `org` so `viewer_meeting_query/3`'s
  # org-membership filter can see it.
  defp meeting!(org) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Member Mount Project #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Member Mount Kickoff #{n}",
        slug: "member-mount-meeting-#{n}"
      })

    meeting
  end

  # A live invite row written DIRECTLY, with no space grant. Used only by the
  # divergence case below; the happy path goes through
  # `Meetings.invite_external_user/3` so it exercises the real grant.
  defp bare_invite!(meeting, user) do
    %Invite{}
    |> Invite.changeset(%{
      meeting_id: meeting.id,
      user_id: user.id,
      display_name: "Member Mount Invitee"
    })
    |> Repo.insert!()
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})

  defp on_meet_host(conn), do: %{conn | host: @meet_host}

  setup do
    original_meet = Application.get_env(:platform, :meet_host)
    Application.put_env(:platform, :meet_host, @meet_host)

    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_meet do
        nil -> Application.delete_env(:platform, :meet_host)
        value -> Application.put_env(:platform, :meet_host, value)
      end
    end)

    :ok
  end

  # ── The invited member ─────────────────────────────────────────────────

  describe "invited external member on the meet host" do
    setup do
      org = tenant_org!()
      ext = create_user!("ext")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

      meeting = meeting!(org)
      {:ok, _invite} = Meetings.invite_external_user(meeting, ext.email)

      %{org: org, ext: ext, meeting: meeting}
    end

    test "renders the meeting with a MEMBER badge naming the account, and no guest badge",
         %{conn: conn, ext: ext, meeting: meeting} do
      {:ok, view, html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      # The room actually rendered — not a denial card.
      assert html =~ meeting.name

      # The member badge is present and names the ACCOUNT. Asserted through
      # the element, not a bare substring: the user's name could reach the
      # DOM from a participant tile and prove nothing about this badge.
      assert has_element?(view, "[data-role=member-identity-badge]")

      assert view
             |> element("[data-role=member-identity-badge]")
             |> render() =~ ext.name

      # And the guest badge is NOT — this viewer is an account, not a guest.
      refute has_element?(view, "[data-role=guest-identity-badge]")
      refute html =~ "(guest)"
    end

    test "carries no internal shell chrome", %{conn: conn, ext: ext, meeting: meeting} do
      {:ok, view, html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      # The specific rail element, not a substring search for "/tasks" —
      # a page can contain a string from somewhere else entirely.
      refute has_element?(view, "#shell-sidebar")
      refute has_element?(view, "[data-icon-rail]")
      refute has_element?(view, "[data-role=chat-panel-toggle]")

      # The breadcrumb back to /meetings is shell-only too: on this surface
      # it would link an external member into a route the plug denies.
      refute has_element?(view, "nav[aria-label=Breadcrumb]")

      # Positive control on the same render — the assertions above are only
      # meaningful if the page rendered something.
      assert html =~ meeting.name
      assert has_element?(view, "[data-role=meeting-controls]")
    end

    test "auto-join runs — the member enters the call, not just the page",
         %{conn: conn, ext: ext, meeting: meeting} do
      # `handle_info(:auto_join, _)` used to no-op on `chrome_mode == :none`,
      # a guard that spelled "guest" wrongly: the stated reason for the skip
      # was the guest surface's nil `:user_id`, and a member has a real one.
      # Under the old guard this page loaded and the member never entered the
      # room — reachable, unusable. Both halves asserted: the socket says it
      # joined AND a participant row exists carrying this user's id.
      {:ok, view, _html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      room = Repo.get_by(Room, space_id: meeting.chat_space_id)
      assert room

      rows = Repo.all(from(p in Participant, where: p.room_id == ^room.id))
      assert [%{user_id: user_id, metadata: metadata}] = rows
      assert user_id == ext.id
      assert metadata["identity"] == "user:" <> ext.id
    end
  end

  # ── The denied member ──────────────────────────────────────────────────

  describe "denied member on the meet host" do
    setup do
      org = tenant_org!()
      ext = create_user!("ext")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

      %{org: org, ext: ext}
    end

    test "an UNINVITED external member is halted by the plug, never reaching the LiveView",
         %{conn: conn, org: org, ext: ext} do
      meeting = meeting!(org)

      # No invite row of any kind for this user.
      assert Repo.get_by(Invite, meeting_id: meeting.id, user_id: ext.id) == nil

      conn =
        conn
        |> login(ext)
        |> on_meet_host()
        |> get("/meetings/#{meeting.slug}")

      # The route gate is the OUTER layer and it fires first: an uninvited
      # member is refused before `MeetingLive.mount/3` runs at all. The
      # in-LiveView invalid card below is the INNER layer, for the case the
      # plug admits and the context still denies.
      assert conn.status == 403
      assert conn.halted
      refute conn.resp_body =~ meeting.name
    end

    test "an invited member the context cannot resolve gets the terminal invalid card, and the meeting name never reaches the DOM",
         %{conn: conn, org: org, ext: ext} do
      # BOTH SIDES IN ONE TEST, so the refute below cannot pass on an empty
      # page: the same principal, on the same surface, sees the name for the
      # meeting they hold a real grant to and does not see it for the one
      # they do not.
      granted = meeting!(org)
      {:ok, _} = Meetings.invite_external_user(granted, ext.email)

      # The divergence stage 2 named: an invite row whose space grant never
      # applied. The plug admits (the row is live), the context denies
      # (`ExternalScope` has no participant row for the bound space). This
      # is the ONLY way to reach the LiveView's denial branch from the
      # router, because the plug catches everything else first.
      ungranted = meeting!(org)
      bare_invite!(ungranted, ext)

      {:ok, granted_view, granted_html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{granted.slug}")

      assert granted_html =~ granted.name
      assert has_element?(granted_view, "[data-role=member-identity-badge]")

      {:ok, denied_view, denied_html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{ungranted.slug}")

      # The SAME card a bad guest link produces — one rendered outcome for
      # both denials, so the surface is not a meeting-existence oracle.
      assert denied_html =~ "Invite link is not valid"
      refute denied_html =~ ungranted.name
      refute has_element?(denied_view, "[data-role=member-identity-badge]")
      refute has_element?(denied_view, "[data-role=meeting-controls]")
    end

    test "the denial is TERMINAL — it does not navigate into a route this surface denies",
         %{conn: conn, org: org, ext: ext} do
      ungranted = meeting!(org)
      bare_invite!(ungranted, ext)

      # `handle_params/3` answers a shell denial with
      # `push_navigate(to: ~p"/meetings")`, which on this host is a route
      # `ExternalUserScope` refuses — the member would be bounced from a
      # closed door into a 403. `live/2` surfaces such a push as
      # `{:error, {:live_redirect, _}}`, so an `{:ok, _, _}` here IS the
      # assertion that no bounce happened.
      assert {:ok, _view, html} =
               conn
               |> login(ext)
               |> on_meet_host()
               |> live("/meetings/#{ungranted.slug}")

      refute html =~ ~s(href="/meetings")
    end
  end

  # ── The internal surface, unchanged ────────────────────────────────────

  describe "internal positive control — the default host still renders the shell" do
    test "an internal user on /meetings/:slug keeps @shell? true and its chrome",
         %{conn: conn} do
      org = tenant_org!()
      int = create_user!("int")
      Platform.ExternalUserFixtures.plain_member!(int, org)

      meeting = meeting!(org)

      {:ok, view, html} =
        conn
        |> login(int)
        |> live("/meetings/#{meeting.slug}")

      assert html =~ meeting.name

      # This is what proves the narrowed heex guards did not strip chrome
      # from the internal surface.
      assert :sys.get_state(view.pid).socket.assigns.shell?
      assert :sys.get_state(view.pid).socket.assigns.chrome_mode == :shell
      assert has_element?(view, "[data-role=chat-panel-toggle]")
      assert has_element?(view, "nav[aria-label=Breadcrumb]")

      # And it is NOT wearing either chrome-less badge.
      refute has_element?(view, "[data-role=member-identity-badge]")
      refute has_element?(view, "[data-role=guest-identity-badge]")
    end

    test "the same internal user on the MEET host gets the chrome-less surface",
         %{conn: conn} do
      # (d) in the router's scope comment, pinned. Internal users are a
      # complete no-op through `ExternalUserScope` on every host, so this
      # is a RENDERING change and not an authorization one — they still
      # reach the meeting, they just reach it without the shell.
      org = tenant_org!()
      int = create_user!("int")
      Platform.ExternalUserFixtures.plain_member!(int, org)

      meeting = meeting!(org)

      {:ok, view, html} =
        conn
        |> login(int)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      assert html =~ meeting.name
      refute :sys.get_state(view.pid).socket.assigns.shell?
      refute has_element?(view, "#shell-sidebar")
      assert has_element?(view, "[data-role=member-identity-badge]")
      refute has_element?(view, "[data-role=guest-identity-badge]")
    end
  end
end
