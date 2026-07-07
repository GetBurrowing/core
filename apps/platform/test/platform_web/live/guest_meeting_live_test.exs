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

      # Video stage marker present, name-entry form absent.
      assert html =~ ~s(data-role="guest-meeting-stage")
      assert html =~ meeting.name
      refute html =~ ~s(phx-submit="submit_name")
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

      # Post-submit render shows the video stage.
      assert html =~ ~s(data-role="guest-meeting-stage")
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

      # If we hit the guest LV, the guest-specific stage marker shows up.
      assert html =~ ~s(data-role="guest-meeting-stage")
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
end
