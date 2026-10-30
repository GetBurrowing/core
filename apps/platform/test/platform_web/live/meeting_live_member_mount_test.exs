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
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
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
      # `?no_autojoin=true` reaches the CALL SHELL without a live LiveKit
      # connection (task 01a09415): a member now lands in the pre-join lobby
      # by default, and the identity badge is a call-shell element, so the
      # hatch is how this test asserts against the shell it means to.
      {:ok, view, html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}?no_autojoin=true")

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
      # `?no_autojoin=true`: the positive control below reads a call-shell
      # element (`meeting-controls`), which the default pre-join lobby does
      # not render (task 01a09415).
      {:ok, view, html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}?no_autojoin=true")

      # The specific rail element, not a substring search for "/tasks" —
      # a page can contain a string from somewhere else entirely.
      refute has_element?(view, "#sidebar")
      refute has_element?(view, "[data-sidebar]")
      refute has_element?(view, "[data-role=chat-panel-toggle]")

      # The breadcrumb back to /meetings is shell-only too: on this surface
      # it would link an external member into a route the plug denies.
      refute has_element?(view, "nav[aria-label=Breadcrumb]")

      # Positive control on the same render — the assertions above are only
      # meaningful if the page rendered something.
      assert html =~ meeting.name
      assert has_element?(view, "[data-role=meeting-controls]")
    end

    test "a member lands in the pre-join lobby, NOT straight in the call",
         %{conn: conn, ext: ext, meeting: meeting} do
      # Task 01a09415, Sam's #4 divergence: a member used to be
      # auto-joined straight into the call with no camera preview, while a
      # guest got the prejoin lobby. A member now gets the SAME lobby. The
      # socket must NOT be `:in_meeting` on mount, and the lobby's
      # preview + Join action must be on the page — the guest-parity claim.
      {:ok, view, html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :lobby
      refute assigns.in_meeting

      assert has_element?(view, ~s([data-role="meeting-lobby"]))
      assert has_element?(view, ~s([data-role="meeting-lobby-preview"]))
      assert has_element?(view, ~s([data-role="meeting-lobby-mic"]))
      assert has_element?(view, ~s([data-role="meeting-lobby-camera"]))
      assert has_element?(view, ~s([data-role="meeting-lobby-join"]))

      # A member has no name to enter — the guest's name field is absent.
      refute has_element?(view, ~s(input[name="guest[name]"]))

      # And no LiveKit client is mounted yet: the room does not exist until
      # the member presses Join.
      refute html =~ ~s(id="meeting-client")

      # No participant row has been written either.
      assert Repo.get_by(Room, space_id: meeting.chat_space_id) == nil
    end

    test "pressing Join from the lobby enters the call — the member is in the room",
         %{conn: conn, ext: ext, meeting: meeting} do
      # The other half of the divergence fix: Join actually connects. Both
      # halves asserted — the socket says it joined AND a participant row
      # exists carrying this user's id.
      {:ok, view, _html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      refute :sys.get_state(view.pid).socket.assigns.in_meeting

      view
      |> element(~s([data-role="meeting-lobby-join"]))
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      room = Repo.get_by(Room, space_id: meeting.chat_space_id)
      assert room

      rows = Repo.all(from(p in Participant, where: p.room_id == ^room.id))
      assert [%{user_id: user_id, metadata: metadata}] = rows
      assert user_id == ext.id
      assert metadata["identity"] == "user:" <> ext.id
    end

    test "a mic switched off in the lobby is off in the join payload",
         %{conn: conn, ext: ext, meeting: meeting} do
      # Device choice survives the lobby -> call transition for a member the
      # same way it does for a guest: `do_join/1` reads the live
      # `:mic_enabled`/`:camera_enabled` pair at push time.
      {:ok, view, _html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}")

      view |> element(~s([data-role="meeting-lobby-mic"])) |> render_click()
      assert :sys.get_state(view.pid).socket.assigns.mic_enabled == false

      view |> element(~s([data-role="meeting-lobby-join"])) |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.in_meeting
      assert_push_event(view, "join-meeting", %{mic_enabled: false, camera_enabled: true})
    end

    test "a member who joined and reconnects re-adopts the call instead of the lobby",
         %{conn: conn, ext: ext, meeting: meeting} do
      # Task 01a18d0a stage 2: the joined state is server-held
      # (`Platform.Meetings.State`), so a reconnect, a new LiveView process,
      # restores it rather than dropping the member back to the lobby while
      # their LiveKit connection is still up.
      on_exit(fn -> Platform.Meetings.State.broadcast_left(ext.id) end)
      member_conn = conn |> login(ext) |> on_meet_host()

      {:ok, view, _html} = live(member_conn, "/meetings/#{meeting.slug}")
      view |> element(~s([data-role="meeting-lobby-join"])) |> render_click()
      assert_push_event(view, "join-meeting", %{})

      GenServer.stop(view.pid)
      {:ok, reconnected, _html} = live(member_conn, "/meetings/#{meeting.slug}")
      render(reconnected)

      assigns = :sys.get_state(reconnected.pid).socket.assigns
      assert assigns.in_meeting
      refute assigns.state == :lobby
      assert_push_event(reconnected, "join-meeting", %{token: token})
      assert is_binary(token)
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

      # `?no_autojoin=true` on the GRANTED side reaches the call shell (where
      # the identity badge lives) without a live connection; the denied side
      # renders a terminal card and needs no hatch (task 01a09415).
      {:ok, granted_view, granted_html} =
        conn
        |> login(ext)
        |> on_meet_host()
        |> live("/meetings/#{granted.slug}?no_autojoin=true")

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

      # `?no_autojoin=true` reaches the call shell (chat-panel-toggle,
      # breadcrumb) without a live connection; a member — internal or not —
      # now lands in the pre-join lobby by default (task 01a09415).
      {:ok, view, html} =
        conn
        |> login(int)
        |> live("/meetings/#{meeting.slug}?no_autojoin=true")

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

    test "an internal user's ordinary visit shows Join and does not connect",
         %{conn: conn} do
      # Task 01a18d0a stage 2: the in-app surface used to auto-join on a
      # connected mount. A bare `/meetings/:slug` is not join intent; the
      # call shell renders its Join control and nothing is created.
      org = tenant_org!()
      int = create_user!("int")
      Platform.ExternalUserFixtures.plain_member!(int, org)
      meeting = meeting!(org)

      {:ok, view, _html} = conn |> login(int) |> live("/meetings/#{meeting.slug}")
      render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      refute assigns.in_meeting
      assert is_nil(assigns.state)
      assert has_element?(view, ~s([data-role="meeting-join"]))
      refute_push_event(view, "join-meeting", %{}, 50)
      assert Repo.get_by(Room, space_id: meeting.chat_space_id) == nil
      assert Repo.get!(Platform.Meetings.Meeting, meeting.id).status == "scheduled"

      view |> element(~s([data-role="meeting-join"])) |> render_click()
      assert_push_event(view, "join-meeting", %{token: token})
      assert is_binary(token)
      on_exit(fn -> Platform.Meetings.State.broadcast_left(int.id) end)

      room = Repo.get_by(Room, space_id: meeting.chat_space_id)

      assert [%{user_id: user_id}] =
               Repo.all(from(p in Participant, where: p.room_id == ^room.id))

      assert user_id == int.id
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

      # `?no_autojoin=true`: the member-identity badge is a call-shell
      # element, reached without a live connection (task 01a09415).
      {:ok, view, html} =
        conn
        |> login(int)
        |> on_meet_host()
        |> live("/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ meeting.name
      refute :sys.get_state(view.pid).socket.assigns.shell?
      refute has_element?(view, "#sidebar")
      assert has_element?(view, "[data-role=member-identity-badge]")
      refute has_element?(view, "[data-role=guest-identity-badge]")
    end
  end

  # ── Top-bar width budget (task 019fb955-f8b1 rework) ───────────────────
  #
  # MEASURED DEFECT, not a style preference. At 390x844 the member badge
  # rendered 125.9px wide and collapsed the meeting-title element to width
  # ZERO, while the top bar's content still ran 457px inside a 390px viewport
  # — clipping the Gallery (right edge 415.9) and Whiteboard (456.9)
  # stage-mode buttons off-screen with no page scroll to recover them.
  # Causally isolated by toggling the badge: title width with badge shown vs
  # hidden was 390 -> 0/31, 430 -> 0/71, 768 -> 0/87.7, and 1280 ->
  # 214.9/214.9. The badge is responsible below 1280 and innocent at 1280.
  #
  # WHY THESE ASSERTIONS AND NOT `has_element?`. A test asserting the title
  # element EXISTS cannot fail here — it existed the whole time, at width 0.
  # ExUnit cannot measure pixels, so what is pinned is the RENDERED CONSTRAINT
  # that produces the width: which items may shrink, which may not, and the
  # proportional cap on the badge. Those classes are the mechanism; delete any
  # one of them and the geometry regresses to the measured defect.
  #
  # The constraints are PERCENTAGES, deliberately. A px floor inside a
  # proportional layout is how an earlier defect in this stack happened: the
  # floor cannot see the container it overflows.
  describe "top-bar width budget" do
    setup do
      org = tenant_org!()
      ext = create_user!("width")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

      meeting = meeting!(org)
      {:ok, _invite} = Meetings.invite_external_user(meeting, ext.email)

      %{org: org, ext: ext, meeting: meeting}
    end

    defp class_of(view, selector) do
      view
      |> element(selector)
      |> render()
      |> then(&Regex.run(~r/class="([^"]*)"/, &1))
      |> case do
        [_, class] -> class
        _ -> flunk("no class attribute on #{selector}")
      end
    end

    test "the title may shrink but owns a proportional share of the line",
         %{conn: conn, ext: ext, meeting: meeting} do
      {:ok, view, _html} =
        conn |> login(ext) |> on_meet_host() |> live("/meetings/#{meeting.slug}?no_autojoin=true")

      class = class_of(view, "[data-role=meeting-title]")

      # `min-w-0` alone is what MADE it collapsible to 0; the basis is what
      # stops it being the residue of everyone else's fixed widths. Both, or
      # the title is back to absorbing the entire deficit.
      assert class =~ "min-w-0"
      assert class =~ "basis-[50%]"
      assert class =~ "grow"
    end

    test "the identity badge is capped proportionally and truncates",
         %{conn: conn, ext: ext, meeting: meeting} do
      {:ok, view, _html} =
        conn |> login(ext) |> on_meet_host() |> live("/meetings/#{meeting.slug}?no_autojoin=true")

      class = class_of(view, "[data-role=member-identity-badge]")

      # A `badge` is `white-space: nowrap`, so as a flex item its min-content
      # width IS its full text width: without `min-w-0` it cannot shrink AT
      # ALL, and the cap never binds.
      assert class =~ "max-w-[25%]"
      assert class =~ "min-w-0"
      assert class =~ "overflow-hidden"

      # And the cap has to actually clip rather than overflow the badge box.
      assert view
             |> element("[data-role=member-identity-badge] .truncate")
             |> render() =~ ext.name
    end

    test "the stage-mode control may shrink, so its own scroller engages",
         %{conn: conn, ext: ext, meeting: meeting} do
      {:ok, view, _html} =
        conn |> login(ext) |> on_meet_host() |> live("/meetings/#{meeting.slug}?no_autojoin=true")

      class = class_of(view, "[data-stage-mode-control]")

      # This control always CLAIMED to scroll rather than overflow the bar.
      # `flex-shrink-0` made that impossible — a shrink-0 item is never
      # squeezed, so `overflow-x-auto` never engaged and Gallery/Whiteboard
      # simply left the viewport. It is the largest block in the bar and the
      # only real slack at 390px.
      assert class =~ "overflow-x-auto"
      assert class =~ "min-w-0"
      assert class =~ "shrink"
      refute class =~ "flex-shrink-0"
      refute class =~ "shrink-0"
    end

    # BOTH SURFACES, one assertion. The guest badge is byte-identical markup
    # in the same bar, so a guest on a phone could never read the meeting name
    # either — this is a PRE-EXISTING defect the member badge merely carried
    # to account holders, not a regression stage 5 introduced. Fixing only the
    # member badge would leave the guest surface broken and this test red.
    #
    # Asserted against the template source because the two badges never render
    # on the same mount (`@state == :in_meeting` vs `is_nil(@state)`), so no
    # single DOM can compare them.
    test "the guest badge carries the identical width treatment" do
      source = File.read!("lib/platform_web/live/meeting_live.html.heex")

      width_classes = ["min-w-0", "max-w-[25%]", "shrink", "overflow-hidden"]

      for role <- ["guest-identity-badge", "member-identity-badge"],
          klass <- width_classes do
        [_, class_attr] =
          Regex.run(
            ~r/class="([^"]*)"\s*\n\s*data-role="#{role}"/,
            source
          ) || flunk("no class attribute found for #{role}")

        assert class_attr =~ klass,
               "#{role} is missing #{klass} — the width fix was applied to only one surface"
      end
    end
  end
end
