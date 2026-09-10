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
  alias Platform.Meetings.AgentActivity
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      assert assigns.display_name == "Jane Doe"
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      assert claims["name"] == "Jane Doe (guest)"
      assert String.starts_with?(claims["sub"], "guest:")
    end

    test "preserves the shell-path assigns MeetingHooks + render tree read (agents_by_id, meeting_canvas, active_space, current_stage_mode)",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.agents_by_id == %{}
      # `:speaking_participant_ids` was deleted by task 01a04a98 — nothing
      # ever wrote it, so asserting it stayed `MapSet.new()` asserted only
      # that a dead assign was still dead. Its replacement is the
      # per-meeting activity value, which the guest surface DOES hydrate.
      assert %Platform.Meetings.AgentActivity{} = assigns.agent_activity
      assert AgentActivity.resolve(assigns.agent_activity) == %{}
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

    # Task 01a06e07 stage 3, correction 1: the tick has to drive the GUEST
    # surface too, and it cannot reuse `MeetingHooks`' hook-owned
    # `:agent_activity_tick` — `attach_guest/1` installs no `:meeting_info`
    # hook by existing design (guest owns its own info handlers directly
    # in `MeetingLive`), so this exercises the guest's OWN scheduler and
    # its OWN `:agent_activity_tick_guest` clause end-to-end, the same way
    # the quickmeet and authenticated `/meetings` tests prove their halves.
    test "a real :agent_activity_tick_guest message advances @agent_activity_now",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      before = :sys.get_state(view.pid).socket.assigns.agent_activity_now
      assert %DateTime{} = before

      send(view.pid, :agent_activity_tick_guest)
      # `render/1` is a synchronous round trip through the SAME mailbox
      # `send/2` just enqueued onto, so by the time it returns the tick's
      # `handle_info/2` clause has already run.
      _ = render(view)

      after_tick = :sys.get_state(view.pid).socket.assigns.agent_activity_now

      assert DateTime.compare(after_tick, before) == :gt,
             "the guest tick fired but @agent_activity_now did not move — a guest's " <>
               "rail would read ages that never advance and a ceiling that never fires"
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
      render_hook(view, "submit_name", %{"guest" => %{"name" => "Jane Doe"}})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.display_name == "Jane Doe"
      assert assigns.in_meeting == true
      assert assigns.name_error == nil

      assert_push_event(view, "join-meeting", %{token: pushed_token})
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert claims["name"] == "Jane Doe (guest)"
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      good_token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")
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
      token = GuestInvite.sign(meeting_a.slug, expires_at, "Jane Doe")

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
      token = GuestInvite.sign(ghost_slug, expires_at, "Jane Doe")

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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ "This invite has expired"
      refute html =~ ~s(id="meeting-client")
      refute html =~ ~s(data-role="meeting-controls")
      # `data-pane="chat-panel"` was the chat drawer, deleted in task
      # 01a084bf stage 3 — refuting it here would pass for free now. The
      # marker that still means "no discussion surface rendered" is the
      # chat BODY, which is where the one `ChatLive.Embedded` mount lives.
      refute html =~ ~s(data-pane="meeting-chat-panel")
    end
  end

  describe "guest render (chrome_mode: :none) — :invalid state" do
    test "renders 'Invite link is not valid' card", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      good = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      assert html =~ ~s(data-pane="call-rail")
      assert html =~ ~s(data-pane="center-stage")
      assert html =~ ~s(data-stage-mode=)
      # Guest identity badge shows on right side of top bar.
      assert html =~ ~s(data-role="guest-identity-badge")
      assert html =~ "Jane Doe (guest)"
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # Re-pointed by task 01a084bf stage 3: the chat drawer
      # (`data-pane="chat-panel"` / `id="meeting-chat-drawer"`) no longer
      # exists on ANY surface, so refuting it proves nothing. The chat body
      # is the marker that still discriminates guest from shell.
      refute html =~ ~s(data-pane="meeting-chat-panel")
      refute html =~ ~s(data-role="chat-panel-toggle")
      refute html =~ ~s(data-role="meeting-copy-guest-link")
      refute html =~ ~s(data-role="chat-pane-toggle")
      refute html =~ ~s(id="meeting-chat-pane-collapse-hook")
    end

    # Task 01a0691d stage 2: the invite section is gated on a signed-in
    # `user_id`, not on `@shell?`. A guest has `user_id: nil` and could
    # never pass `authorize_writer`, so the section is absent — while the
    # rail it would live in IS rendered, which keeps this a statement about
    # the gate rather than about the rail.
    test "renders the call rail but no invite section: a guest may not invite",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ ~s(data-component="call-rail")
      refute html =~ ~s(data-role="meeting-agent-invite")
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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
  # renders a `.video_tile` that MeetingVideoTile can bind to Jane's
  # LiveKit-published track.
  describe "guest presence upsert (chrome_mode: :none) — Bug B fix" do
    alias Platform.Meetings.Participant

    test "guest mount upserts a live participant row keyed on the LiveKit identity",
         %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

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
    # `@shell?` guard from silently disappearing chat + rail toggles from the
    # auth surface.
    #
    # Task 019fb955-1d7b stage 1 flipped the copy-guest-link assertion in this
    # test to a REFUTE. The meeting-wide "Copy guest link" button is gone: it
    # minted one forwardable URL per meeting from an optional display name, so
    # the joiner was unidentifiable and their speech unattributable. Guest
    # admission is per-invite only now.
    #
    # ANTI-VACUITY: a bare refute would pass identically if the top bar failed
    # to render at all, if this mount 500'd, or if the attribute string were
    # mistyped. The assertions below it are the positive control — they read
    # the SAME rendered string and cover the same top bar
    # (`data-role="meeting-controls"` is the button's own parent container,
    # `data-role="meeting-screen-share"` is its immediate sibling). Refute and
    # control must stay in this test together; splitting them re-opens the hole.
    test "authenticated /meetings/:slug renders chat panel + rail toggles, and no meeting-wide guest link",
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

      # Seed a chat participant row for the viewer. This is the assign the
      # removed "Copy guest link" button was gated on (`@current_participant`),
      # so seeding it keeps the refute below meaningful: the button would be
      # rendering under exactly these conditions if it still existed.
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

      # All chat + rail-toggle markers present under :shell. The chat DRAWER
      # is gone (task 01a084bf stage 3) and the discussion is a pane of the
      # rail, so the shell-only marker is the chat body plus the one rail
      # node that hosts it.
      assert html =~ ~s(data-pane="meeting-chat-panel")
      assert html =~ ~s(data-role="chat-panel-toggle")
      assert html =~ ~s(data-role="chat-pane-toggle")
      assert html =~ ~s(id="meeting-chat-pane-collapse-hook")
      assert html =~ ~s(id="meeting-call-rail-pane")
      refute html =~ ~s(id="meeting-chat-drawer")
      # Guest identity badge is NOT rendered on the shell surface.
      refute html =~ ~s(data-role="guest-identity-badge")

      # ── The deletion, with its positive control ──────────────────────────
      # The meeting-wide guest link is gone from the in-room top bar…
      refute html =~ ~s(data-role="meeting-copy-guest-link")
      # …and the sheet it opened is gone with it.
      refute html =~ ~s(data-role="guest-invite-sheet")
      # …but the top bar that CONTAINED it still rendered in this same
      # string, so the two refutes above are reading a live surface rather
      # than an empty page. `meeting-controls` was the button's parent
      # container; `meeting-screen-share` was the sibling immediately after
      # it in the markup.
      assert html =~ ~s(data-role="meeting-controls")
      assert html =~ ~s(data-role="meeting-screen-share")
      assert html =~ ~s(data-role="meeting-mic")
      assert html =~ ~s(data-pane="call-rail")
      assert html =~ ~s(data-pane="center-stage")
    end

    # The button refute above defends the SURFACE. This defends the WIRE.
    # Removing the markup while leaving `generate_guest_invite` reachable
    # would leave the unattributable mint one hand-crafted `phx-click`
    # payload away — the LiveView event surface is public to anyone holding
    # a socket, not just to whoever can see a button.
    test "the LiveView answers no guest-invite mint event", %{conn: conn} do
      user =
        Repo.insert!(%Platform.Accounts.User{
          email: "no_mint_#{System.unique_integer([:positive])}@example.com",
          name: "No Mint User",
          oidc_sub: "oidc-no-mint-#{System.unique_integer([:positive])}"
        })

      Repo.insert!(
        Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
          user_id: user.id,
          org_id: Platform.TenancyFixtures.fabrikam_org_id(),
          role: "member"
        })
      )

      meeting = create_meeting()

      {:ok, _participant} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      conn = Phoenix.ConnTest.init_test_session(conn, current_user_id: user.id)

      # POSITIVE CONTROL, and it has to come first: pushing an unhandled
      # event crashes the LiveView, so a dead socket would make every
      # subsequent push "fail" for the wrong reason and the test would pass
      # against a LiveView that never mounted at all. Prove the event surface
      # is live by pushing an event that IS still handled.
      {:ok, control_view, _html} = live(conn, "/meetings/#{meeting.slug}")
      assert render_click(control_view, "meeting_screen_share_state", %{}) =~ "meeting-controls"

      # An unhandled event raises inside the LiveView, and the test process is
      # LINKED to it, so without trapping the exit signal kills this test
      # instead of being caught. Set after the control push so the control
      # still runs under normal linking.
      Process.flag(:trap_exit, true)

      for event <- [
            "open_guest_invite_sheet",
            "close_guest_invite_sheet",
            "guest_invite_form_change",
            "generate_guest_invite",
            "copy_guest_invite"
          ] do
        {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}")

        # Each event gets a fresh socket: the first unhandled push kills the
        # LiveView, so reusing one view would make events 2..5 vacuous.
        assert catch_exit(
                 render_click(view, event, %{
                   "guest_invite" => %{"display_name" => "Mallory", "expires_in_hours" => "72"}
                 })
               ),
               "#{event} was still handled by MeetingLive — the meeting-wide guest mint is reachable over the wire"
      end
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
        GuestInvite.sign(meeting.slug, expires_at, "Jane Doe",
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
      assert assigns.display_name == "Jane Doe"
      assert assigns.chrome_mode == :none
      assert %Chat.Space{} = assigns.meeting.chat_space
      assert html =~ ~s(id="meeting-client")
      assert html =~ "Jane Doe (guest)"
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

      render_hook(view, "submit_name", %{"guest" => %{"name" => "Jane Doe"}})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.display_name == "Jane Doe"
      assert_push_event(view, "join-meeting", %{token: pushed})
      assert is_binary(pushed) and pushed != ""
    end

    test "expired id-bearing token still lands :expired", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)

      token =
        GuestInvite.sign(meeting.slug, expires_at, "Jane Doe", meeting_id: meeting.id)

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
      good = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe", meeting_id: meeting.id)
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
        GuestInvite.sign(meeting_a.slug, expires_at, "Jane Doe", meeting_id: meeting_b.id)

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
      token = GuestInvite.sign(slug, expires_at, "Jane Doe")

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
        GuestInvite.sign(meeting.slug, expires_at, "Jane Doe",
          guest_space_id: meeting.chat_space_id
        )

      {:ok, view, html} = conn |> with_meet_host() |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.state == :in_meeting
      assert assigns.meeting.id == meeting.id
      assert assigns.display_name == "Jane Doe"
      assert html =~ ~s(id="meeting-client")
    end
  end

  # ── Per-meeting intent mute on the guest surface (task 019fbaac stage 4) ──
  #
  # Guests SEE the muted state, live, and cannot change it. The badge lives
  # in the `data-role="meeting-controls"` cluster, which is NOT `@shell?`-
  # gated, so the guest inherits it from the same shell tree. The toggle
  # lives inside `<.intents_collapse :if={@intents_visible?}>`, which the
  # guest never renders — twice over: `:intents_visible?` is `false` on the
  # guest path AND the whole chat aside that hosts the bar is `@shell?`-
  # gated. Both are asserted below rather than reasoned about.

  defp assign_producer! do
    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "guest-mute-producer-#{System.unique_integer([:positive])}",
        name: "Meeting Producer",
        status: "active"
      })

    {:ok, _} = Platform.Roles.assign_role("meeting_producer", agent.id)
    agent
  end

  # An authenticated conn that can reach `/meetings/:slug` for a meeting
  # built by `create_meeting/1` — i.e. a Fabrikam-root member, mirroring the
  # shell regression test above.
  defp authenticated_meeting_conn do
    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "guest_mute_#{System.unique_integer([:positive])}@example.com",
        name: "Producer User",
        oidc_sub: "oidc-guest-mute-#{System.unique_integer([:positive])}"
      })

    Repo.insert!(
      Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member"
      })
    )

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(current_user_id: user.id)
  end

  defp guest_token(meeting, name \\ "Jane Doe") do
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    GuestInvite.sign(meeting.slug, expires_at, name)
  end

  describe "per-meeting intent mute — guest surface (task 019fbaac stage 4)" do
    test "a guest joining an ALREADY-muted meeting paints the badge and NO toggle",
         %{conn: conn} do
      meeting = create_meeting()
      {:ok, _} = Meetings.set_intent_muted(meeting.id, true)

      {:ok, view, html} =
        conn |> with_meet_host() |> live("/#{meeting.slug}/#{guest_token(meeting)}?tab=canvas")

      # Positive first: the guest can see that the agents are held.
      assert html =~ ~s(data-role="meeting-intent-mute-badge")
      assert html =~ "Agents muted"
      # Negative second, and it means something only because the positive
      # above proves the guest surface rendered at all.
      refute html =~ ~s(data-role="meeting-intent-mute-toggle")

      # The assign resolved on FIRST PAINT, not via a later broadcast —
      # `seed_intent_assigns/1` seeds `false` and `handle_params/3` no-ops
      # for guests, so without the read in `seed_guest_shell_tree_assigns/2`
      # this would be `false` here.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.intent_muted? == true
      # ...and the reason there is no toggle, asserted rather than assumed.
      assert assigns.intents_visible? == false
      assert assigns.shell? == false
    end

    test "a guest joining an UNMUTED meeting gets neither badge nor toggle",
         %{conn: conn} do
      meeting = create_meeting()

      {:ok, view, html} =
        conn |> with_meet_host() |> live("/#{meeting.slug}/#{guest_token(meeting)}?tab=canvas")

      refute html =~ ~s(data-role="meeting-intent-mute-badge")
      refute html =~ ~s(data-role="meeting-intent-mute-toggle")

      # The presence pair for the two refutes above: the guest shell DID
      # render, so "absent" is about the mute state and not about a surface
      # that failed to mount.
      assert html =~ ~s(data-role="meeting-controls")
      assert html =~ ~s(id="meeting-client")
      assert :sys.get_state(view.pid).socket.assigns.intent_muted? == false
    end

    test "LIVE, NO REJOIN: an authenticated toggle reaches an already-connected GUEST",
         %{conn: conn} do
      meeting = create_meeting()
      assign_producer!()
      on_exit(fn -> Platform.Meetings.IntentQueue.stop(meeting.id) end)

      {:ok, guest_view, guest_html} =
        conn |> with_meet_host() |> live("/#{meeting.slug}/#{guest_token(meeting)}?tab=canvas")

      refute guest_html =~ ~s(data-role="meeting-intent-mute-badge")
      guest_pid = guest_view.pid

      {:ok, auth_view, _auth_html} =
        live(authenticated_meeting_conn(), ~p"/meetings/#{meeting.slug}?tab=canvas")

      auth_view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()

      # No reload, no re-mount, no navigation — the guest view we already
      # had simply re-renders. That is the whole requirement.
      guest_html = render(guest_view)
      assert guest_html =~ ~s(data-role="meeting-intent-mute-badge")
      assert guest_view.pid == guest_pid
      # Still no toggle: visibility is not the same as control.
      refute guest_html =~ ~s(data-role="meeting-intent-mute-toggle")

      # Both directions. A badge that appears and never leaves would tell a
      # guest the agents are held for the rest of the meeting.
      auth_view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()

      guest_html = render(guest_view)
      refute guest_html =~ ~s(data-role="meeting-intent-mute-badge")
      assert guest_view.pid == guest_pid
    end

    test "a guest replaying `toggle_intent_mute` cannot change the mute, while a producer can",
         %{conn: conn} do
      meeting = create_meeting()
      assign_producer!()
      on_exit(fn -> Platform.Meetings.IntentQueue.stop(meeting.id) end)

      {:ok, guest_view, _html} =
        conn |> with_meet_host() |> live("/#{meeting.slug}/#{guest_token(meeting)}?tab=canvas")

      # The hand-crafted event a guest console can push. No element exists
      # to click, which is the point — this bypasses the DOM entirely.
      render_click(guest_view, "toggle_intent_mute", %{})
      refute Meetings.intent_muted?(meeting.id)

      # The paired positive, in the same test body: the identical event
      # from an authenticated producer DOES flip the row. Without this, the
      # refute above is satisfiable by a fixture where nothing works.
      {:ok, auth_view, _} =
        live(authenticated_meeting_conn(), ~p"/meetings/#{meeting.slug}?tab=canvas")

      auth_view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()
      assert Meetings.intent_muted?(meeting.id)

      # And the guest still cannot flip it back.
      render_click(guest_view, "toggle_intent_mute", %{})
      assert Meetings.intent_muted?(meeting.id)
    end

    test "the guest rejection holds even with `:intents_visible?` forced true",
         %{conn: conn} do
      # ISOLATION CONTROL. The test above passes with the `chrome_mode ==
      # :none` clause deleted, because `with_intents_gate/2` also blocks a
      # guest today — not by checking the viewer, but incidentally, because
      # `handle_params/3` no-ops for guests and never resolves
      # `:intents_visible?`. Two guards, one assertion, and the mutation
      # cannot tell them apart.
      #
      # So neutralize the incidental one and leave the deliberate one alone.
      # With `:intents_visible?` forced true, `with_intents_gate/2` lets the
      # event through and the `chrome_mode == :none` clause is the ONLY
      # thing standing between a guest console and the meeting's mute state.
      meeting = create_meeting()
      assign_producer!()
      on_exit(fn -> Platform.Meetings.IntentQueue.stop(meeting.id) end)

      {:ok, guest_view, _html} =
        conn |> with_meet_host() |> live("/#{meeting.slug}/#{guest_token(meeting)}")

      :sys.replace_state(guest_view.pid, fn state ->
        put_in(state.socket.assigns.intents_visible?, true)
      end)

      # Prove the neutralization LANDED before relying on it. A silently
      # failed state replacement would leave this test asserting nothing.
      assert :sys.get_state(guest_view.pid).socket.assigns.intents_visible? == true
      assert :sys.get_state(guest_view.pid).socket.assigns.chrome_mode == :none

      render_click(guest_view, "toggle_intent_mute", %{})
      refute Meetings.intent_muted?(meeting.id)

      # Presence pair: the same forced socket DOES still process events, so
      # the refute above is about the guard and not about a wedged process.
      # `toggle_intents_collapse` runs through the very same
      # `with_intents_gate/2` that the mute handler uses, and now passes it.
      before_open = :sys.get_state(guest_view.pid).socket.assigns.intents_open
      render_click(guest_view, "toggle_intents_collapse", %{})
      assert :sys.get_state(guest_view.pid).socket.assigns.intents_open == !before_open
    end
  end
end
