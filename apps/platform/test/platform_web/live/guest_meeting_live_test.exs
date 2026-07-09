defmodule PlatformWeb.GuestMeetingLiveTest do
  @moduledoc """
  Tests for `PlatformWeb.GuestMeetingLive` (task 019f2483 stage 3).

  Covers the three visible states the guest ingress can land in
  (`:in_meeting`, `:name_entry`, `:expired`, `:invalid`) plus the two
  host-scope contracts:

    * requests carrying `host: "meet.<any>"` route to `GuestMeetingLive`,
    * requests carrying the default `localhost` host do NOT.

  Stub tokens are minted via `Platform.Meetings.GuestInvite` so the
  HMAC path is exercised end-to-end — the same signing key that prod
  uses (config/test.exs sets `:meeting_guest_signing_key`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks

  # LiveKit config toggled per-test so the `guest_livekit_token/2` mint
  # path succeeds (mirrors the pattern in guest_token_test.exs — the
  # global test config leaves LiveKit unset so nothing accidentally
  # picks up a real endpoint).
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
        name: "Guest Meeting Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    project
  end

  # Create a meeting + preload its chat_space so the LV's
  # `push_join_event` (which reads `meeting.chat_space.slug`) doesn't
  # trip on a Ecto.Association.NotLoaded struct.
  defp create_meeting(attrs \\ %{}) do
    project = Map.get_lazy(attrs, :project, fn -> create_project() end)
    name = Map.get(attrs, :name, "Guest Kickoff #{System.unique_integer([:positive])}")

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    Repo.preload(meeting, :chat_space)
  end

  # Point a conn at the `meet.` host so the guest scope resolves. Phoenix's
  # `Router.dispatch/2` matches on `conn.host` starting with the scope
  # prefix — `meet.localhost` and `meet.example.com` both match.
  defp with_meet_host(conn, host \\ "meet.localhost") do
    %{conn | host: host}
  end

  # Decode the second JWT segment so `:name` and `:sub` claim assertions
  # can pin the "(guest)" suffix + `guest:` identity prefix without
  # pulling in JOSE.
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

  # ── Valid pre-provisioned name ───────────────────────────────────────────

  describe "mount/3 — valid token with a pre-provisioned display_name" do
    test "renders the video stage (not the name-entry form)", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      # Stage 2 (task 019f43da) replaced the static `#guest-meeting-stage`
      # "Connecting to X" card with a real gallery + parking-slot surface.
      # Positive signal: the MeetingClient reparent target
      # (`data-role="local-self-view"`) and the JS-populated remote grid
      # (`#meeting-participants`) both render.
      assert html =~ ~s(data-role="local-self-view")
      assert html =~ ~s(id="meeting-participants")
      assert html =~ meeting.name
      refute html =~ ~s(phx-submit="submit_name")
      # Confirm the removed placeholder + the media-sink rename shipped.
      refute html =~ ~s(id="guest-meeting-stage")
      refute html =~ ~s(id="guest-meeting-media")
      assert html =~ ~s(id="meeting-media")
    end

    test "assigns `:token`, `:identity` (guest: prefix), and `:in_meeting` state", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      # Peek at the LV's assigns via the standard test helper. We rely on
      # the LiveView PID here rather than a public API because those
      # assigns are load-bearing for the JS hook contract.
      state = :sys.get_state(view.pid).socket.assigns

      assert state.state == :in_meeting
      assert String.starts_with?(state.identity, "guest:")
      assert is_binary(state.token) and state.token != ""
      assert state.display_name == "Juno Fairbanks"
      # LiveKit URL from `put_livekit_env` — pins the bundle wiring end-to-end.
      assert state.livekit_url == "wss://livekit.test"
    end

    test "the minted JWT's `name` claim is suffixed with `(guest)`", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      state = :sys.get_state(view.pid).socket.assigns

      assert {:ok, claims} = decode_jwt_claims(state.token)
      assert claims["name"] == "Juno Fairbanks (guest)"
      assert String.starts_with?(claims["sub"], "guest:")
    end
  end

  # ── Name-entry form (nil display_name in payload) ────────────────────────

  describe "mount/3 — valid token with nil display_name" do
    test "renders the name-entry form", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      assert html =~ ~s(phx-submit="submit_name")
      # Name-entry form has a name input.
      assert html =~ ~s(name="guest[name]")
      # Meeting name is surfaced in the CTA header.
      assert html =~ meeting.name
      # Video stage marker absent (we're not in-meeting yet).
      refute html =~ ~s(data-role="guest-meeting-stage")
    end

    test "submit_name transitions to :in_meeting with a guest-suffixed name claim",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      html =
        view
        |> form("form[phx-submit=submit_name]", guest: %{name: "Juno Fairbanks"})
        |> render_submit()

      # Post-submit render shows the video stage: gallery grid + local
      # self-view parking slot (stage 2 of task 019f43da).
      assert html =~ ~s(data-role="local-self-view")
      assert html =~ ~s(id="meeting-participants")
      refute html =~ ~s(phx-submit="submit_name")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :in_meeting
      assert state.display_name == "Juno Fairbanks"

      assert {:ok, claims} = decode_jwt_claims(state.token)
      assert claims["name"] == "Juno Fairbanks (guest)"
    end

    test "submitting an empty name shows an inline error", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      html =
        view
        |> form("form[phx-submit=submit_name]", guest: %{name: "   "})
        |> render_submit()

      assert html =~ "Please enter your name."
      # Still on the name-entry form, not the video stage.
      assert html =~ ~s(phx-submit="submit_name")
      refute html =~ ~s(data-role="guest-meeting-stage")
    end
  end

  # ── Expired token ────────────────────────────────────────────────────────

  describe "mount/3 — expired token" do
    test "renders :expired state and does not mint a LiveKit token", %{conn: conn} do
      meeting = create_meeting()

      # 60s in the past → GuestInvite.verify returns {:error, :expired}.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      assert html =~ "This invite has expired"
      # No video stage, no name-entry form.
      refute html =~ ~s(data-role="guest-meeting-stage")
      refute html =~ ~s(phx-submit="submit_name")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :expired
      # No :identity assign means no token was minted.
      refute Map.has_key?(state, :identity)
    end
  end

  # ── Tampered / invalid HMAC ──────────────────────────────────────────────

  describe "mount/3 — tampered token" do
    test "renders :invalid state for an HMAC-corrupted token", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      good_token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      # Flip a random byte in the middle. Plug.Crypto.verify then fails
      # on the signature check and we get {:error, :invalid}.
      tampered = String.replace(good_token, ~r/./, "X", global: false)

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{tampered}")

      assert html =~ "Invite link is not valid"
      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :invalid
    end
  end

  # ── Slug mismatch (URL slug ≠ payload slug) ──────────────────────────────

  describe "mount/3 — slug mismatch" do
    test "renders :invalid when the URL slug differs from the payload slug",
         %{conn: conn} do
      meeting_a = create_meeting()
      meeting_b = create_meeting()

      # Token signed for meeting_a, then hit at meeting_b's URL.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting_a.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting_b.slug}/#{token}")

      assert html =~ "Invite link is not valid"
      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :invalid
    end
  end

  # ── Meeting-not-found ────────────────────────────────────────────────────

  describe "mount/3 — meeting deleted after invite issue" do
    test "renders :invalid when the payload slug no longer resolves to a meeting",
         %{conn: conn} do
      # Sign for a slug that has no Meeting row.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      token =
        GuestInvite.sign(
          "ghost-meeting-#{System.unique_integer([:positive])}",
          expires_at,
          "Juno Fairbanks"
        )

      # URL slug must match the payload slug so we exercise the get_meeting
      # branch (not the tampering branch).
      slug =
        case Plug.Crypto.verify(
               Application.get_env(:platform, :meeting_guest_signing_key),
               "meeting_guest_invite",
               token
             ) do
          {:ok, %{meeting_slug: s}} -> s
        end

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{slug}/#{token}")

      assert html =~ "Invite link is not valid"
      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :invalid
    end
  end

  # ── Host routing contract ────────────────────────────────────────────────

  describe "host: routing" do
    test "requests on host `meet.<any>.<tld>` route to GuestMeetingLive",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, _view, html} =
        conn
        |> with_meet_host("meet.example.com")
        |> live(~p"/#{meeting.slug}/#{token}")

      # If we hit the guest LV, the guest-specific gallery + parking-slot
      # markup shows up (stage 2 of task 019f43da replaced the earlier
      # `data-role="guest-meeting-stage"` placeholder).
      assert html =~ ~s(data-role="local-self-view")
      assert html =~ ~s(id="meeting-participants")
    end

    test "requests on the default `www.example.com` host do NOT route to GuestMeetingLive",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      # Phoenix.ConnTest's default conn carries host "www.example.com",
      # which does NOT start with "meet." — so the guest scope must NOT
      # match. The request path `/:slug/:token` doesn't map to any other
      # authenticated route, so the dispatch bails out with a 404 before
      # any LiveView runs. Use a plain `get/2` so we can inspect the
      # response conn directly (LiveViewTest's `live/2` wraps the
      # NoRouteError in its own FunctionClauseError trying to build a
      # WebSocket connection, which is confusing to pin against).
      response_conn = get(conn, "/#{meeting.slug}/#{token}")
      assert response_conn.status == 404
    end
  end

  # ── Guest layout does not leak shell chrome ──────────────────────────────

  describe "layout: guest layouts are chrome-free" do
    test "rendered document contains no sidebar / icon-rail / bottom-nav markers",
         %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      # The static-render html captures the full document (root + inner).
      # Nothing from the authenticated app shell should leak into it.
      conn = with_meet_host(conn)
      %{resp_body: body} = get(conn, ~p"/#{meeting.slug}/#{token}")

      refute body =~ "shell-sidebar"
      refute body =~ "icon-rail"
      refute body =~ "bottom-nav"
      refute body =~ "chat-sidebar"
    end
  end

  # Belt-and-suspenders: make sure the Meeting row + preloaded chat_space
  # end up on the assigns after mount — the `push_join_event` reads
  # `meeting.chat_space.slug` and would crash if the assoc were unloaded.
  describe "mount/3 — chat_space preload" do
    test "chat_space is preloaded on the :meeting assign", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      state = :sys.get_state(view.pid).socket.assigns
      assert %Meeting{} = state.meeting
      # If chat_space wasn't preloaded this would be Ecto.Association.NotLoaded.
      assert %Chat.Space{} = state.meeting.chat_space
    end
  end

  # ── Live-presence subscription (task 019f43da-5a88 stage 1) ──────────────
  #
  # The guest LV subscribes to the same per-space presence topic MeetingLive
  # uses (`MeetingsPubSub.subscribe_presence/1`) so remote join/leave events
  # flow into `:remote_count` without a page reload. The `:remote_count`
  # assign is what the heex-side gallery hint (stage 2) reads to drive
  # "Waiting for other participants…" visibility.
  describe "mount/3 — meeting presence subscription (:in_meeting)" do
    test "initial :remote_count is 0 when no active room exists yet", %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :in_meeting
      # `active_participant_count/1` returns 0 for a space with no room.
      assert state.remote_count == 0
    end

    test "initial :remote_count reflects existing participants minus self", %{conn: conn} do
      meeting = create_meeting()
      space_id = meeting.chat_space_id

      # Seed two other participants already in the room. The guest's own
      # webhook hasn't landed yet at mount, so `active_participant_count`
      # is 2 and `:remote_count` = 2 - 1 (self clamp).
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, _room} = Meetings.activate_room(room)
      {:ok, _p1} = Meetings.participant_joined(room, %{display_name: "Alice"})
      {:ok, _p2} = Meetings.participant_joined(room, %{display_name: "Bob"})

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      state = :sys.get_state(view.pid).socket.assigns
      # 2 seeded − 1 (self clamp) = 1 remote peer.
      assert state.remote_count == 1
    end

    test "{:participant_joined, _} broadcast on the room topic advances :remote_count",
         %{conn: conn} do
      meeting = create_meeting()
      space_id = meeting.chat_space_id

      # Pre-activate the room and seed one participant so the initial
      # `max(active_count - 1, 0)` sits at 0. Then a second join takes it
      # to 1 — that's the delta we're actually testing (the presence
      # broadcast plumbing, not the count arithmetic).
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _alice} = Meetings.participant_joined(room, %{display_name: "Alice"})

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      # 1 seeded − 1 (self clamp) = 0.
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 0

      # Second participant arrives. `participant_joined` already broadcasts
      # `{:participant_joined, _}` on the room topic — the LV must react.
      {:ok, _bob} = Meetings.participant_joined(room, %{display_name: "Bob"})

      # Let the LV process the message.
      _ = render(view)
      Process.sleep(50)

      # 2 total − 1 (self clamp) = 1 remote peer visible.
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1
    end

    test "{:participant_left, _} broadcast decrements :remote_count", %{conn: conn} do
      meeting = create_meeting()
      space_id = meeting.chat_space_id

      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, alice} = Meetings.participant_joined(room, %{display_name: "Alice"})
      {:ok, _bob} = Meetings.participant_joined(room, %{display_name: "Bob"})

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      # 2 seeded − 1 (self clamp) = 1. One remote peer visible.
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1

      # Alice leaves; the context broadcasts {:participant_left, _} on
      # the room topic.
      alice
      |> Platform.Meetings.Participant.changeset(%{left_at: DateTime.utc_now()})
      |> Repo.update!()

      MeetingsPubSub.broadcast_room(room.id, {:participant_left, alice})
      _ = render(view)
      Process.sleep(50)

      # 1 remaining (Bob) − 1 (self clamp) = 0.
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 0
    end

    test "{:meeting_presence_update, _} on the per-space topic refreshes :remote_count",
         %{conn: conn} do
      meeting = create_meeting()
      space_id = meeting.chat_space_id

      # No active room at mount — the guest lands with :remote_count == 0
      # and subscribes only to the space presence topic (room topic
      # subscription happens later via the presence_update handler).
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      assert :sys.get_state(view.pid).socket.assigns.remote_count == 0

      # Activate the room + seed a participant, then broadcast the presence
      # update on the space topic. The guest LV's handler re-reads
      # `active_participant_count` and updates the assign.
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _p} = Meetings.participant_joined(room, %{display_name: "Alice"})

      MeetingsPubSub.broadcast_presence(
        space_id,
        {:meeting_presence_update, %{space_id: space_id, active: true, count: 1}}
      )

      _ = render(view)
      Process.sleep(50)

      # 1 participant − 1 (self clamp) = 0. Bump to 2 to observe the change.
      {:ok, _p2} = Meetings.participant_joined(room, %{display_name: "Bob"})

      MeetingsPubSub.broadcast_presence(
        space_id,
        {:meeting_presence_update, %{space_id: space_id, active: true, count: 2}}
      )

      _ = render(view)
      Process.sleep(50)

      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1
    end

    test "submit_name transition also assigns :remote_count and subscribes", %{conn: conn} do
      # Cover the name-entry → :in_meeting path (`handle_event submit_name`).
      # Same subscription contract as the pre-provisioned mount path.
      meeting = create_meeting()
      space_id = meeting.chat_space_id

      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _p} = Meetings.participant_joined(room, %{display_name: "Alice"})

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      view
      |> form("form[phx-submit=submit_name]", guest: %{name: "Juno Fairbanks"})
      |> render_submit()

      state = :sys.get_state(view.pid).socket.assigns
      assert state.state == :in_meeting
      # 1 Alice − 1 (self clamp) = 0.
      assert state.remote_count == 0

      # Presence broadcast lands after transition — proves the subscription
      # attached in the transition path (not just the mount-time path).
      {:ok, bob} = Meetings.participant_joined(room, %{display_name: "Bob"})
      MeetingsPubSub.broadcast_room(room.id, {:participant_joined, bob})
      _ = render(view)
      Process.sleep(50)

      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1
    end
  end

  # ── Stage 3 (task 019f43da-5a88): gallery + presence render coverage ─────
  #
  # These tests lock down the DOM contracts stages 1 + 2 put in place — the
  # MeetingClient JS hook binds to these ids/attrs by string, so a stray
  # rename would silently break the guest video surface until a live
  # LiveKit meeting exercises the path. Also adds the explicit
  # `Phoenix.PubSub.broadcast/3`-on-presence-topic case (stage 1's existing
  # coverage drives the room topic via `Meetings.participant_joined/2`;
  # here we hit the per-space presence topic directly to prove the
  # subscription is on the topic name we think it is).
  describe "in_meeting render — gallery + presence contracts" do
    setup %{conn: conn} do
      meeting = create_meeting()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live(~p"/#{meeting.slug}/#{token}")

      {:ok, meeting: meeting, view: view, html: html}
    end

    test "renders #meeting-participants grid + #meeting-media sink", %{html: html} do
      assert html =~ ~s(id="meeting-participants")
      assert html =~ ~s(id="meeting-media")
      # Media-sink rename must have shipped: the old id would silently
      # regress `MeetingClient._mediaContainer()` into `document.body`
      # fallback (meeting_client.js:684).
      refute html =~ ~s(id="guest-meeting-media")
    end

    test "renders 'Waiting for other participants…' hint gated on @remote_count",
         %{meeting: meeting, view: view, html: html} do
      # Zero remote participants at mount → hint present.
      assert html =~ ~s(data-role="guest-waiting-hint")
      assert html =~ "Waiting for other participants"

      # Push the assign past zero via a real broadcast + DB state change so
      # `refresh_remote_count/1` recounts to 1. `Meetings.participant_joined`
      # both inserts a row and broadcasts on the room topic.
      space_id = meeting.chat_space_id
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _alice} = Meetings.participant_joined(room, %{display_name: "Alice"})
      {:ok, _bob} = Meetings.participant_joined(room, %{display_name: "Bob"})

      _ = render(view)
      Process.sleep(50)

      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1

      html_after = render(view)
      refute html_after =~ ~s(data-role="guest-waiting-hint")
      refute html_after =~ "Waiting for other participants"
    end

    test "renders persistent local self-view parking slot with data-role + phx-update=ignore",
         %{html: html} do
      # `MeetingClient._localParkingSlot()` (meeting_client.js:212) finds
      # this off-layout <div> by `[data-role="local-self-view"]` and parks
      # the persistent local <video> here between dock reparents. Without
      # `phx-update="ignore"` morphdom would wipe the injected element on
      # any LV re-render.
      assert html =~ ~s(id="guest-meeting-local-self-view")
      assert html =~ ~s(data-role="local-self-view")

      # Pin the pairing: the parking-slot div must carry both attrs. We
      # match the full opening-tag prefix so we don't accept an unrelated
      # `phx-update="ignore"` elsewhere (the meeting-participants grid also
      # sets it — hence the anchoring on the parking-slot id).
      assert html =~
               ~r/id="guest-meeting-local-self-view"[^>]*phx-update="ignore"[^>]*data-role="local-self-view"/s
    end

    test "renders local-video-dock with data-dock-mode=gallery reparent target",
         %{html: html} do
      # `MeetingClient._dockLocalVideo("gallery")` reparents the persistent
      # local <video> into `[data-local-video-dock][data-dock-mode="gallery"]`
      # on LocalTrackPublished. Both attrs must render together; the id
      # gives us a debug handle.
      assert html =~ ~s(id="guest-meeting-local-video-dock")
      assert html =~ ~s(data-local-video-dock)
      assert html =~ ~s(data-dock-mode="gallery")

      # Same anchoring trick: guarantee the attrs land on the same element,
      # not on the (unrelated) MeetingClient mount div.
      assert html =~
               ~r/id="guest-meeting-local-video-dock"[^>]*data-local-video-dock[^>]*data-dock-mode="gallery"/s
    end

    test "Phoenix.PubSub.broadcast on the presence topic advances :remote_count",
         %{meeting: meeting, view: view} do
      # Stage 1's existing coverage drives the ROOM topic (via
      # `Meetings.participant_joined` which broadcasts on `room_topic/1`).
      # This case drives the PER-SPACE presence topic directly with
      # `Phoenix.PubSub.broadcast/3` — the topic name the LV subscribes
      # to via `MeetingsPubSub.subscribe_presence/1`. If that subscription
      # ever moved to a different topic, this test breaks first.
      space_id = meeting.chat_space_id

      # Seed one participant so `active_participant_count/1` returns 1 →
      # broadcast fires, recount lands at 1 - 1 (self) = 0. Then insert
      # a second directly (bypassing `participant_joined`'s built-in
      # broadcast) and fire a presence-topic broadcast ourselves — that
      # proves the LV's `handle_info({:participant_joined, _}, _)` fires
      # off events landing on the SPACE topic.
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _alice} = Meetings.participant_joined(room, %{display_name: "Alice"})

      # `subscribe_room` in mount only ran if there was an active room at
      # that moment; there wasn't. So the LV is subscribed ONLY to the
      # per-space presence topic here — perfect target for this proof.
      _ = render(view)
      Process.sleep(50)
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 0

      # Second participant into the DB via a raw insert so no auto
      # broadcast fires from the context; the LV only reacts if OUR
      # explicit `Phoenix.PubSub.broadcast/3` reaches its inbox.
      bob =
        %Platform.Meetings.Participant{}
        |> Platform.Meetings.Participant.changeset(%{
          room_id: room.id,
          display_name: "Bob",
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        MeetingsPubSub.presence_topic(space_id),
        {:participant_joined, bob}
      )

      _ = render(view)
      Process.sleep(50)

      # 2 in DB − 1 (self clamp) = 1 remote peer.
      assert :sys.get_state(view.pid).socket.assigns.remote_count == 1
    end

    test "no shell chrome leaks after gallery markup renders", %{html: html} do
      # Parent task 019f2483 asserted these tokens are absent in the
      # guest surface's static render (`get/2` path). Stage 2 replaced
      # the `:in_meeting` inner branch with a much larger gallery + dock
      # layout — re-affirm the invariants against the connected LV
      # render so a stray `<.shell_layout>` / bottom-nav include is
      # caught at this stage rather than at task-level review.
      refute html =~ "shell-sidebar"
      refute html =~ "icon-rail"
      refute html =~ "bottom-nav"
      refute html =~ "chat-sidebar"
    end
  end
end
