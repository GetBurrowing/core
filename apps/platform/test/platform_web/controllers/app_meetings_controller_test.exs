defmodule PlatformWeb.AppMeetingsControllerTest do
  @moduledoc """
  Task 01a10db7 stage 1: the native app's meeting call routes,
  `POST /api/app/meetings/:id/join`, `POST /api/app/meetings/:id/leave` and
  `POST /api/app/voip_devices`.
  """
  # async: false: the log test raises the global Logger level.
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.ExternalUserFixtures

  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Ring
  alias Platform.Mobile
  alias Platform.Mobile.ApnsVoipDevice
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  @voip_token String.duplicate("7c0ff1ce", 8)

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_session!(user, install_id \\ "install-1") do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: install_id})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp meeting!(org) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "App Meetings #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "App Meetings Meeting #{n}",
        slug: "app-meetings-#{n}"
      })

    meeting
  end

  defp voip_params(overrides \\ %{}) do
    Map.merge(
      %{
        "token" => @voip_token,
        "environment" => "sandbox",
        "bundle_id" => "com.kobo-ai.burrow",
        "app_install_id" => "install-1"
      },
      overrides
    )
  end

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    org = Tenancy.get_org_by_slug!("globex")
    user = create_user!()
    plain_member!(user, org)
    %{token: token, session: session} = app_session!(user)

    %{conn: conn, org: org, user: user, token: token, session: session, meeting: meeting!(org)}
  end

  describe "401 without a bearer" do
    test "on every new route", %{conn: conn, meeting: meeting} do
      for {path, params} <- [
            {"/api/app/meetings/#{meeting.id}/join", %{}},
            {"/api/app/meetings/#{meeting.id}/leave", %{}},
            {"/api/app/voip_devices", voip_params()}
          ] do
        conn = post(conn, path, params)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, path
      end

      assert Repo.get!(Meeting, meeting.id).status == "scheduled"
      assert Repo.aggregate(ApnsVoipDevice, :count) == 0
    end
  end

  describe "POST /api/app/meetings/:id/join" do
    test "joins, starts the meeting and returns the LiveKit token", ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> post("/api/app/meetings/#{ctx.meeting.id}/join")
        |> json_response(200)

      assert is_binary(body["token"])
      assert body["url"] == "wss://livekit.test"
      assert body["room_name"] == Meetings.room_name_for_space(ctx.meeting.chat_space_id)
      assert body["identity"] == "user:#{ctx.user.id}"

      assert %{"id" => id, "space_id" => space_id, "status" => "live"} = body["meeting"]
      assert id == ctx.meeting.id
      assert space_id == ctx.meeting.chat_space_id
      assert Repo.get!(Meeting, ctx.meeting.id).started_by_user_id == ctx.user.id
    end

    test "another org's meeting is 404 and is not started", ctx do
      other = meeting!(Tenancy.get_org_by_slug!("initech"))

      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/meetings/#{other.id}/join")

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert Repo.get!(Meeting, other.id).status == "scheduled"
    end

    test "an uninvited external user gets the same 404 as a missing meeting", ctx do
      external = external_user!(ctx.org)
      %{token: ext_token} = app_session!(external)

      # An external user lists only invited meetings, so an uninvited
      # meeting is invisible: 404, indistinguishable from a bogus id.
      conn = ctx.conn |> bearer(ext_token) |> post("/api/app/meetings/#{ctx.meeting.id}/join")
      assert json_response(conn, 404) == %{"error" => "not_found"}

      conn2 =
        ctx.conn
        |> bearer(ext_token)
        |> post("/api/app/meetings/#{Ecto.UUID.generate()}/join")

      assert json_response(conn2, 404) == %{"error" => "not_found"}
    end

    test "an ended meeting is 409 meeting_over", ctx do
      {:ok, live} = Meetings.start_meeting(ctx.meeting)
      {:ok, _} = live |> Meeting.status_changeset("ended") |> Repo.update()

      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/meetings/#{ctx.meeting.id}/join")
      assert json_response(conn, 409) == %{"error" => "meeting_over"}
    end
  end

  describe "POST /api/app/meetings/:id/leave" do
    test "leaves a joined meeting with 204", ctx do
      ctx.conn |> bearer(ctx.token) |> post("/api/app/meetings/#{ctx.meeting.id}/join")

      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/meetings/#{ctx.meeting.id}/leave")
      assert response(conn, 204)
      assert Meetings.active_participants_for_space(ctx.meeting.chat_space_id) == []
    end

    test "another org's meeting is 404", ctx do
      other = meeting!(Tenancy.get_org_by_slug!("initech"))
      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/meetings/#{other.id}/leave")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end

  describe "POST /api/app/voip_devices" do
    test "registers, refreshes in place, and replaces the install's old token", ctx do
      conn1 = ctx.conn |> bearer(ctx.token) |> post("/api/app/voip_devices", voip_params())
      assert json_response(conn1, 200) == %{"registered" => true}
      refute response(conn1, 200) =~ @voip_token
      assert [%ApnsVoipDevice{token: @voip_token} = first] = Mobile.list_voip_devices(ctx.user)
      assert first.app_session_id == ctx.session.id

      # Same token again: one row, refreshed.
      ctx.conn |> bearer(ctx.token) |> post("/api/app/voip_devices", voip_params())
      assert [%ApnsVoipDevice{id: id}] = Mobile.list_voip_devices(ctx.user)
      assert id == first.id

      # A new token for the same install replaces the old one.
      new_token = String.duplicate("abad1dea", 8)

      ctx.conn
      |> bearer(ctx.token)
      |> post("/api/app/voip_devices", voip_params(%{"token" => new_token}))

      assert [%ApnsVoipDevice{token: ^new_token}] = Mobile.list_voip_devices(ctx.user)
    end

    test "a token another user registered is reassigned, not duplicated", ctx do
      other = create_user!()
      %{token: other_bearer, session: other_session} = app_session!(other, "install-other")

      ctx.conn
      |> bearer(other_bearer)
      |> post("/api/app/voip_devices", voip_params(%{"app_install_id" => "install-other"}))

      assert [%ApnsVoipDevice{app_session_id: sid}] = Mobile.list_voip_devices(other)
      assert sid == other_session.id

      ctx.conn |> bearer(ctx.token) |> post("/api/app/voip_devices", voip_params())

      assert Mobile.list_voip_devices(other) == []
      assert [%ApnsVoipDevice{token: @voip_token}] = Mobile.list_voip_devices(ctx.user)
      assert Repo.aggregate(ApnsVoipDevice, :count) == 1
    end

    test "an invalid token is 422 naming the field, never echoing the value", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> post("/api/app/voip_devices", voip_params(%{"token" => "not hex!"}))

      assert %{"error" => "invalid_device", "fields" => fields} = json_response(conn, 422)
      assert "token" in fields
      refute response(conn, 422) =~ "not hex!"
    end
  end

  describe "rings (stage 2)" do
    setup ctx do
      {:ok, live} = Meetings.start_meeting(ctx.meeting)
      inviter = create_user!()

      ring =
        Repo.insert!(%Ring{
          meeting_id: live.id,
          user_id: ctx.user.id,
          inviter_user_id: inviter.id,
          trigger: "live_invite",
          state: "ringing"
        })

      Map.merge(ctx, %{ring: ring, live: live})
    end

    test "401 without a bearer on every ring route", ctx do
      for {method, path} <- [
            {:get, "/api/app/rings/#{ctx.ring.id}"},
            {:post, "/api/app/rings/#{ctx.ring.id}/answer"},
            {:post, "/api/app/rings/#{ctx.ring.id}/decline"},
            {:post, "/api/app/rings/#{ctx.ring.id}/missed"}
          ] do
        conn = dispatch(ctx.conn, @endpoint, method, path, %{})
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, path
      end

      assert Repo.get!(Ring, ctx.ring.id).state == "ringing"
    end

    test "GET reads the ring with its meeting", ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/api/app/rings/#{ctx.ring.id}")
        |> json_response(200)

      assert body["id"] == ctx.ring.id
      assert body["state"] == "ringing"
      assert body["trigger"] == "live_invite"
      assert body["meeting_id"] == ctx.live.id
      assert body["meeting_status"] == "live"
      assert body["space_id"] == ctx.live.chat_space_id
    end

    test "a ring whose meeting ended reads as over", ctx do
      {:ok, _} = ctx.live |> Meeting.status_changeset("ended") |> Repo.update()

      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/api/app/rings/#{ctx.ring.id}")
        |> json_response(200)

      assert body["state"] == "over"
      assert body["meeting_status"] == "ended"
    end

    test "answer is a compare-and-set: the second transition is 409", ctx do
      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/rings/#{ctx.ring.id}/answer")
      assert json_response(conn, 200)["state"] == "answered"

      conn2 = ctx.conn |> bearer(ctx.token) |> post("/api/app/rings/#{ctx.ring.id}/decline")
      assert json_response(conn2, 409) == %{"error" => "not_ringing", "state" => "answered"}
      assert Repo.get!(Ring, ctx.ring.id).state == "answered"
    end

    test "decline twice: the second is 409, and the inviter hears once", ctx do
      Phoenix.PubSub.subscribe(Platform.PubSub, Meetings.PubSub.meeting_topic(ctx.live.id))

      conn = ctx.conn |> bearer(ctx.token) |> post("/api/app/rings/#{ctx.ring.id}/decline")
      assert json_response(conn, 200)["state"] == "declined"

      conn2 = ctx.conn |> bearer(ctx.token) |> post("/api/app/rings/#{ctx.ring.id}/decline")
      assert json_response(conn2, 409)["error"] == "not_ringing"

      assert_received {:ring_declined, %{user_id: user_id}}
      assert user_id == ctx.user.id
      refute_received {:ring_declined, _}
    end

    test "another user's ring is 404 and is not touched", ctx do
      other = create_user!()
      plain_member!(other, ctx.org)
      %{token: other_token} = app_session!(other, "install-other")

      conn = ctx.conn |> bearer(other_token) |> get("/api/app/rings/#{ctx.ring.id}")
      assert json_response(conn, 404) == %{"error" => "not_found"}

      conn2 = ctx.conn |> bearer(other_token) |> post("/api/app/rings/#{ctx.ring.id}/decline")
      assert json_response(conn2, 404) == %{"error" => "not_found"}

      conn3 = ctx.conn |> bearer(ctx.token) |> get("/api/app/rings/not-a-uuid")
      assert json_response(conn3, 404) == %{"error" => "not_found"}

      assert Repo.get!(Ring, ctx.ring.id).state == "ringing"
    end
  end

  describe "secrets never reach the log" do
    test "a join and a VoIP registration log neither the LiveKit JWT nor the VoIP token",
         ctx do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {jwt, log} =
        with_log([level: :debug], fn ->
          ctx.conn
          |> bearer(ctx.token)
          |> post("/api/app/voip_devices", voip_params())
          |> json_response(200)

          ctx.conn
          |> bearer(ctx.token)
          |> post("/api/app/meetings/#{ctx.meeting.id}/join")
          |> json_response(200)
          |> Map.fetch!("token")
        end)

      # Positive controls: the request log AND the Ecto query log were both
      # captured, so a refute below is a statement about content, not about
      # an empty capture.
      assert log =~ "/api/app/voip_devices", "the request log was not captured"
      assert log =~ "/api/app/meetings/#{ctx.meeting.id}/join"
      assert log =~ "meeting_participants", "the Ecto query log was not captured"

      refute log =~ jwt
      refute log =~ @voip_token
      refute log =~ ctx.token
    end

    test "the voip_token body param is filtered by :filter_parameters" do
      # The configured filter (config.exs) is matched by substring, so a
      # `voip_token` key is covered by "token". The non-secret key is the
      # control: a filter that blanked everything would also pass the first
      # two assertions.
      filtered =
        Phoenix.Logger.filter_values(%{
          "voip_token" => @voip_token,
          "token" => @voip_token,
          "environment" => "sandbox"
        })

      assert filtered["voip_token"] == "[FILTERED]"
      assert filtered["token"] == "[FILTERED]"
      assert filtered["environment"] == "sandbox"
    end
  end
end
