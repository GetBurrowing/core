defmodule PlatformWeb.MeetingLiveGuestMountTest do
  @moduledoc """
  Guest-ingress mount tests for `PlatformWeb.MeetingLive` (task 019f498d
  stage 3).

  Covers the four guest states MeetingLive lands in when the session
  carries `chrome_mode: "none"` (injected by the router's `:guest_meeting`
  live_session block on the `meet.` host scope):

    * `:expired` / `:invalid` — invite token failed to verify or is
      stale. No token is minted; no PubSub subscription; no `#meeting-client`
      hook mounted.
    * `:name_entry` — token verified but the payload carried no
      `display_name`. Renders the name-entry form; `submit_name` transitions
      to `:in_meeting`.
    * `:in_meeting` — token verified AND payload carried a display_name
      (or the guest submitted one). The bundle is minted, a `join-meeting`
      push_event is queued, and the media-toggle event surface is installed
      via `MeetingHooks.attach_guest/1`.

  Tests hit the real guest ingress route `/:slug/:token` under the
  `:guest_meeting` live_session on the `meet.` host scope. Stage 5 of
  this task retired the transitional `_probe/:slug/:token` seam.

  Kept in a separate module (rather than adding to `meeting_live_test.exs`)
  because `put_livekit_env/0` mutates `Application.put_env(:platform, :livekit, …)`
  which is async-unsafe. This module is `async: false`; the parent
  `meeting_live_test.exs` stays `async: true`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # LiveKit config toggled per-test — global test config leaves LiveKit
  # unset so nothing accidentally picks up a real endpoint.
  defp put_livekit_env do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  defp create_project do
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Guest Mount Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    project
  end

  defp create_meeting(attrs \\ %{}) do
    project = Map.get_lazy(attrs, :project, fn -> create_project() end)
    name = Map.get(attrs, :name, "Guest Mount Kickoff #{System.unique_integer([:positive])}")

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    Repo.preload(meeting, :chat_space)
  end

  # `meet.` host prefix so the `:guest_meeting` scope wins the match.
  defp with_meet_host(conn, host \\ "meet.localhost") do
    %{conn | host: host}
  end

  # Decode the JWT payload segment for :name / :sub claim assertions.
  defp decode_jwt_claims(jwt) when is_binary(jwt) do
    with [_h, payload, _sig] <- String.split(jwt, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  setup do
    put_livekit_env()
    :ok
  end

  # ── Valid pre-provisioned name → :in_meeting ─────────────────────────────

  describe "guest mount (chrome_mode: :none) — valid token with display_name" do
    test "lands :in_meeting, seeds :user_id nil + :current_participant nil, mounts #meeting-client",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.user_id == nil
      assert assigns.current_participant == nil
      assert assigns.in_meeting == true
      assert assigns.chrome_mode == :none
      assert assigns.shell? == false
      assert assigns.display_name == "Juno Fairbanks"
      # LiveKit bundle assigns populated end-to-end.
      assert String.starts_with?(assigns.identity, "guest:")
      assert is_binary(assigns.token) and assigns.token != ""
      assert assigns.livekit_url == "wss://livekit.test"
      # Meeting shell markup is present so MeetingClient hook can hydrate
      # (heex :state-branch lands in stage 4 — for now the shell tree
      # renders because `@meeting != nil` gates it).
      assert html =~ ~s(id="meeting-client")
    end

    test "pushes `join-meeting` with the shared guest payload shape",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert_push_event(view, "join-meeting", %{
        token: pushed_token,
        url: url,
        room_name: room_name,
        space_slug: space_slug
      })

      assert is_binary(pushed_token) and pushed_token != ""
      assert url == "wss://livekit.test"
      assert is_binary(room_name)
      assert space_slug == meeting.chat_space.slug

      # Minted JWT carries the `(guest)` suffix + `guest:` identity prefix.
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert claims["name"] == "Juno Fairbanks (guest)"
      assert String.starts_with?(claims["sub"], "guest:")
    end

    test "preserves the shell-path assigns MeetingHooks + render tree read (agents_by_id, meeting_canvas, active_space, current_stage_mode)",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.agents_by_id == %{}
      assert assigns.speaking_participant_ids == MapSet.new()
      assert assigns.current_stage_mode == :gallery
      assert assigns.active_space.id == meeting.chat_space_id
      assert %Chat.Space{} = assigns.meeting.chat_space
      assert is_list(assigns.participants)
      # Media-state assigns (from `MeetingHooks.attach_guest/1`) — the
      # top-bar mic/camera/screen-share buttons render off these.
      assert assigns.mic_enabled == true
      assert assigns.camera_enabled == true
      assert assigns.screen_share_enabled == false
    end
  end

  # ── Valid token with nil display_name → :name_entry ──────────────────────

  describe "guest mount (chrome_mode: :none) — nil display_name" do
    test "lands :name_entry with a submit_name form",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :name_entry
      assert assigns.user_id == nil
      assert assigns.chrome_mode == :none
      assert %Meeting{} = assigns.meeting
      assert assigns.meeting.id == meeting.id
      assert assigns.name_value == ""
      assert assigns.name_error == nil
    end

    test "`submit_name` transitions state to :in_meeting and pushes join-meeting",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # Push the submit_name event directly rather than via the form
      # helper — stage-3 heex does not yet render the guest form (that
      # lands in stage 4). The handler is exercised regardless.
      render_hook(view, "submit_name", %{"guest" => %{"name" => "Juno Fairbanks"}})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.display_name == "Juno Fairbanks"
      assert assigns.in_meeting == true
      assert assigns.name_error == nil

      assert_push_event(view, "join-meeting", %{token: pushed_token})
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert claims["name"] == "Juno Fairbanks (guest)"
    end

    test "submitting an empty name records :name_error and stays :name_entry",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      render_hook(view, "submit_name", %{"guest" => %{"name" => "   "}})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :name_entry
      assert assigns.name_error == "Please enter your name."
      assert assigns.in_meeting == nil or assigns.in_meeting == false
    end
  end

  # ── Expired / invalid / tampered / slug-mismatch ─────────────────────────

  describe "guest mount (chrome_mode: :none) — failure states" do
    test "expired token → :expired state, no #meeting-client mount, no :identity",
         %{conn: conn} do
      meeting = create_meeting()
      # 60s in the past → GuestInvite.verify returns {:error, :expired}.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :expired
      assert assigns.meeting == nil
      assert assigns.page_title == "This invite has expired"
      # No token was minted for the guest surface.
      refute Map.has_key?(assigns, :identity)
    end

    test "HMAC-tampered token → :invalid state",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      good_token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")
      tampered = String.replace(good_token, ~r/./, "X", global: false)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{tampered}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :invalid
      assert assigns.page_title == "Invite link is not valid"
    end

    test "URL slug ≠ payload slug → :invalid state",
         %{conn: conn} do
      meeting_a = create_meeting()
      meeting_b = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      # Signed for meeting_a, hit at meeting_b's slug — the resolver treats
      # this as tampering.
      token = GuestInvite.sign(meeting_a.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting_b.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :invalid
    end

    test "verified token but meeting no longer exists → :invalid state",
         %{conn: conn} do
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      ghost_slug = "ghost-mount-#{System.unique_integer([:positive])}"
      token = GuestInvite.sign(ghost_slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{ghost_slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :invalid
    end
  end

  # ── Stage 4 render coverage ──────────────────────────────────────────────
  #
  # These tests pin the top-level `cond` in meeting_live.html.heex and the
  # `@shell?` gates on shell-only chrome regions (chat panel, Copy guest link,
  # SidebarCollapse hooks). Guest surface (`chrome_mode == :none`) exposes
  # the meeting shell's mic/camera/screen-share controls + participant rail +
  # center stage but hides everything shell-scoped.

  describe "guest render (chrome_mode: :none) — :expired state" do
    test "renders 'This invite has expired' card and NO #meeting-client hook",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ "This invite has expired"
      refute html =~ ~s(id="meeting-client")
      refute html =~ ~s(data-role="meeting-controls")
      refute html =~ ~s(data-pane="chat-panel")
    end
  end

  describe "guest render (chrome_mode: :none) — :invalid state" do
    test "renders 'Invite link is not valid' card", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      good = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")
      tampered = String.replace(good, ~r/./, "X", global: false)

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{tampered}")

      assert html =~ "Invite link is not valid"
      refute html =~ ~s(id="meeting-client")
      refute html =~ ~s(data-role="meeting-controls")
    end
  end

  describe "guest render (chrome_mode: :none) — :name_entry state" do
    test "renders phx-submit=\"submit_name\" form and NO #meeting-client hook",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ ~s(phx-submit="submit_name")
      assert html =~ "Join #{meeting.name}"
      refute html =~ ~s(id="meeting-client")
      refute html =~ ~s(data-role="meeting-controls")
    end
  end

  describe "guest render (chrome_mode: :none) — :in_meeting state" do
    test "renders meeting shell markers", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # Meeting shell + controls are visible on guest surface.
      assert html =~ ~s(id="meeting-client")
      assert html =~ ~s(data-role="meeting-controls")
      assert html =~ ~s(data-role="meeting-mic")
      assert html =~ ~s(data-role="meeting-camera")
      assert html =~ ~s(data-role="meeting-screen-share")
      assert html =~ ~s(data-pane="left-rail")
      assert html =~ ~s(data-pane="center-stage")
      assert html =~ ~s(data-stage-mode=)
      # Guest identity badge shows on right side of top bar.
      assert html =~ ~s(data-role="guest-identity-badge")
      assert html =~ "Juno Fairbanks (guest)"
    end

    test "guest layout wrapper uses definite `h-dvh` (not `min-h-dvh`) so `h-full` propagates to the gallery",
         %{conn: conn} do
      # Regression: `min-h-dvh` on the guest layout main is a MIN
      # height, not a definite one. MeetingLive's outer wrapper is
      # `flex h-full flex-col`, and `h-full` on a min-height-only
      # ancestor resolves to `auto`, cascading indeterminate height
      # down the chain. That collapsed the gallery cell's size query
      # context (`container-type: size` needs a definite size) so the
      # `@container gallery-cell (aspect-ratio: ...)` rules that size
      # tiles NEVER MATCHED — tiles fell back to intrinsic ~300×150
      # px thumbnails floating in a sea of empty stage. Match the
      # auth shell (`h-[100dvh]`) with a definite viewport height.
      # Prod incident 2026-07-10 after the guest-consolidation deploy.
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ ~s(class="h-dvh bg-base-100)
      refute html =~ ~s(class="min-h-dvh)
    end

    test "omits shell-only chrome (chat panel, copy-guest-link, chat-pane toggles)",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      refute html =~ ~s(data-pane="chat-panel")
      refute html =~ ~s(data-role="chat-panel-toggle")
      refute html =~ ~s(data-role="meeting-copy-guest-link")
      refute html =~ ~s(data-role="chat-pane-toggle")
      refute html =~ ~s(id="meeting-participant-rail-collapse-hook")
      refute html =~ ~s(id="meeting-chat-pane-collapse-hook")
      refute html =~ ~s(id="meeting-chat-drawer")
    end

    # Task 019f498d re-dispatch — Bug A fix. The persistent local self-view
    # parking slot (data-role="local-self-view") is gated on `self_view`
    # being truthy. Stage 3 seeded `:current_participant = nil` for guests
    # which made the historical arity-1 helper return nil, hiding the slot
    # entirely — so MeetingClient had no dock and the local camera never
    # painted. The re-dispatch extends the helper to synthesize a
    # participant for guest mode based on `@display_name` + `@identity`.
    test "renders the persistent [data-role=local-self-view] parking slot for guests",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ ~s(id="meeting-local-self-view")
      assert html =~ ~s(data-role="local-self-view")
    end
  end

  # Task 019f498d re-dispatch — Bug B fix. Guests were previously invisible
  # to the auth session because `Meetings.upsert_live_participant/2` was
  # only called from the auth-side `meeting_hooks.ex`. The re-dispatch
  # wires the guest ingress mount to upsert its own row on join so the
  # auth-side MeetingLive (subscribed to the same presence + room topics)
  # renders a `.video_tile` that MeetingVideoTile can bind to Juno's
  # LiveKit-published track.
  describe "guest presence upsert (chrome_mode: :none) — Bug B fix" do
    alias Platform.Meetings.Participant

    test "guest mount upserts a live participant row keyed on the LiveKit identity",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns

      # The identity assigned to the socket must round-trip to the DB
      # row's metadata (Meetings.upsert_live_participant stores it there
      # so the render layer can produce a `data-participant` attribute
      # matching what LiveKit publishes for this guest).
      assert is_binary(assigns.identity)
      assert String.starts_with?(assigns.identity, "guest:")

      # Find the guest's row on the active room. `active_participants_for_space/1`
      # is the same reader the render path uses; if the row lands here
      # the auth side will see it too via `{:participant_joined, _}`
      # broadcast on the room topic + the space presence topic.
      active = Meetings.active_participants_for_space(meeting.chat_space_id)

      assert Enum.any?(active, fn %Participant{} = p ->
               p.user_id == nil and p.agent_id == nil and
                 Map.get(p.metadata || %{}, "identity") == assigns.identity
             end)
    end

    test "renders a gallery tile whose data-participant matches the LiveKit identity",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      identity = :sys.get_state(view.pid).socket.assigns.identity
      assert html =~ ~s(data-participant="#{identity}")
    end
  end

  describe "shell render (chrome_mode: :shell) regression check" do
    # Sanity: authenticated /meetings/:slug still surfaces ALL shell chrome
    # after the stage 4 gates. Prevents an accidental widening of a
    # `@shell?` guard from silently disappearing chat + copy-link + rail
    # toggles from the auth surface.
    test "authenticated /meetings/:slug renders chat panel + copy-link + rail toggles",
         %{conn: conn} do
      # Reach the shell via the standard app host (no `meet.` prefix).
      user =
        Repo.insert!(%Platform.Accounts.User{
          email: "shell_reg_#{System.unique_integer([:positive])}@example.com",
          name: "Shell Reg User",
          oidc_sub: "oidc-shell-reg-#{System.unique_integer([:positive])}"
        })

      # Org plumbing (task 019f9b14 stage 2): `/meetings/:slug` resolves
      # through the org-scoped `Meetings.fetch_meeting_for_user/2`, so the
      # viewer needs the Fabrikam-root membership every real OIDC signup gets.
      # `create_meeting/0` below builds its project in that same org.
      Repo.insert!(
        Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
          user_id: user.id,
          org_id: Platform.TenancyFixtures.fabrikam_org_id(),
          role: "member"
        })
      )

      meeting = create_meeting()

      # Seed a chat participant row for the viewer so the host-only
      # "Copy guest link" button (gated on `@current_participant`) renders.
      {:ok, _participant} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, _view, html} =
        conn
        |> Phoenix.ConnTest.init_test_session(current_user_id: user.id)
        |> live("/meetings/#{meeting.slug}")

      # All chat-panel + copy-link + rail-toggle markers present under :shell.
      assert html =~ ~s(data-pane="chat-panel")
      assert html =~ ~s(data-role="chat-panel-toggle")
      assert html =~ ~s(data-role="meeting-copy-guest-link")
      assert html =~ ~s(data-role="chat-pane-toggle")
      assert html =~ ~s(id="meeting-participant-rail-collapse-hook")
      assert html =~ ~s(id="meeting-chat-pane-collapse-hook")
      assert html =~ ~s(id="meeting-chat-drawer")
      # Guest identity badge is NOT rendered on the shell surface.
      refute html =~ ~s(data-role="guest-identity-badge")
      # Standard meeting controls are still present.
      assert html =~ ~s(data-role="meeting-controls")
      assert html =~ ~s(data-role="meeting-mic")
      assert html =~ ~s(data-pane="left-rail")
      assert html =~ ~s(data-pane="center-stage")
    end
  end

  # ── Both token shapes land the same four states (task 019f9b14 stage 3) ──
  #
  # Every OTHER test in this module mints with `GuestInvite.sign(slug,
  # expires_at, name)` — i.e. the LEGACY, slug-only shape — so the legacy
  # path is already covered across all four states above. This block is the
  # id-bearing parallel: `meeting_id` in the payload, which is what
  # `MeetingLive`'s "Copy guest link" now mints. Guest ingress must be
  # byte-for-byte identical between the two.
  #
  # It also pins the collision case, which is the reason `meeting_id` exists:
  # `unique_index(:meetings, [:project_id, :slug])` makes a slug unique per
  # project only, so the same URL can name two meetings in two orgs. An
  # id-bearing token resolves to ITS meeting; a legacy token refuses rather
  # than guessing, and — the bug this stage closes — neither one 500s.

  describe "guest mount — meeting_id-bearing tokens (task 019f9b14 stage 3)" do
    defp meeting_in_new_project(slug) do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Guest Collision Project #{System.unique_integer([:positive])}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Collision Standup #{System.unique_integer([:positive])}",
          slug: slug
        })

      Repo.preload(meeting, :chat_space)
    end

    test "id-bearing token with a display_name lands :in_meeting, same as legacy",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      token =
        GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks",
          guest_space_id: meeting.chat_space_id,
          meeting_id: meeting.id
        )

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.meeting.id == meeting.id
      assert assigns.display_name == "Juno Fairbanks"
      assert assigns.chrome_mode == :none
      assert %Chat.Space{} = assigns.meeting.chat_space
      assert html =~ ~s(id="meeting-client")
      assert html =~ "Juno Fairbanks (guest)"
    end

    test "id-bearing token with nil display_name lands :name_entry and submits through",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil, meeting_id: meeting.id)

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ ~s(phx-submit="submit_name")
      assert %Meeting{} = :sys.get_state(view.pid).socket.assigns.meeting
      assert :sys.get_state(view.pid).socket.assigns.state == :name_entry

      render_hook(view, "submit_name", %{"guest" => %{"name" => "Juno Fairbanks"}})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.display_name == "Juno Fairbanks"
      assert_push_event(view, "join-meeting", %{token: pushed})
      assert is_binary(pushed) and pushed != ""
    end

    test "expired id-bearing token still lands :expired", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)

      token =
        GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks", meeting_id: meeting.id)

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert :sys.get_state(view.pid).socket.assigns.state == :expired
      assert html =~ "This invite has expired"
      refute html =~ ~s(id="meeting-client")
    end

    test "tampered id-bearing token still lands :invalid", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      good = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks", meeting_id: meeting.id)
      tampered = String.replace(good, ~r/./, "X", global: false)

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{tampered}")

      assert :sys.get_state(view.pid).socket.assigns.state == :invalid
      assert html =~ "Invite link is not valid"
    end

    test "id-bearing token whose id names a DIFFERENT meeting than the URL slug is :invalid",
         %{conn: conn} do
      meeting_a = create_meeting()
      meeting_b = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      # Payload slug agrees with the URL, so the pre-existing tamper guard
      # passes; the id disagrees. Both identifiers must line up.
      token =
        GuestInvite.sign(meeting_a.slug, expires_at, "Juno Fairbanks", meeting_id: meeting_b.id)

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting_a.slug}/#{token}")

      assert :sys.get_state(view.pid).socket.assigns.state == :invalid
      assert html =~ "Invite link is not valid"
    end

    test "colliding slug: each id-bearing token admits to ITS OWN meeting, no 500",
         %{conn: conn} do
      slug = "guest-collision-#{System.unique_integer([:positive])}"
      meeting_a = meeting_in_new_project(slug)
      meeting_b = meeting_in_new_project(slug)

      refute meeting_a.id == meeting_b.id
      assert meeting_a.slug == meeting_b.slug

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token_a = GuestInvite.sign(slug, expires_at, "Guest A", meeting_id: meeting_a.id)
      token_b = GuestInvite.sign(slug, expires_at, "Guest B", meeting_id: meeting_b.id)

      {:ok, view_a, _html} = conn |> with_meet_host() |> live("/#{slug}/#{token_a}")
      {:ok, view_b, _html} = conn |> with_meet_host() |> live("/#{slug}/#{token_b}")

      assigns_a = :sys.get_state(view_a.pid).socket.assigns
      assigns_b = :sys.get_state(view_b.pid).socket.assigns

      assert assigns_a.state == :in_meeting
      assert assigns_b.state == :in_meeting
      assert assigns_a.meeting.id == meeting_a.id
      assert assigns_b.meeting.id == meeting_b.id
      # The LiveKit rooms are distinct — this is the cross-org admission
      # path the id closes.
      refute assigns_a.meeting.chat_space_id == assigns_b.meeting.chat_space_id
    end

    test "colliding slug + LEGACY slug-only token: :invalid, and the ingress does not crash",
         %{conn: conn} do
      slug = "guest-legacy-collision-#{System.unique_integer([:positive])}"
      _meeting_a = meeting_in_new_project(slug)
      _meeting_b = meeting_in_new_project(slug)

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      # No meeting_id — a token minted before this stage.
      token = GuestInvite.sign(slug, expires_at, "Juno Fairbanks")

      # Pre-fix this mount raised `Ecto.MultipleResultsError` from
      # `Repo.get_by(Meeting, slug: slug)` — a 500 on the public guest
      # ingress. It must now render the ordinary invalid card instead.
      {:ok, view, html} = conn |> with_meet_host() |> live("/#{slug}/#{token}")

      assert :sys.get_state(view.pid).socket.assigns.state == :invalid
      assert html =~ "Invite link is not valid"
    end

    test "LEGACY slug-only token on a unique slug is unaffected by the change",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      # The exact pre-019f9b14 mint shape from MeetingLive: guest_space_id
      # present, meeting_id absent.
      token =
        GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks",
          guest_space_id: meeting.chat_space_id
        )

      {:ok, view, html} = conn |> with_meet_host() |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.meeting.id == meeting.id
      assert assigns.display_name == "Juno Fairbanks"
      assert html =~ ~s(id="meeting-client")
    end
  end
end
