defmodule PlatformWeb.GuestShortLinkControllerTest do
  @moduledoc """
  `GET /g/:code` on the `meet.` host (task 01a18d0a-ec37-7000-8a47-108834f2efe2).

  The controller admits nobody itself: a valid code 302s to the existing
  `/<slug>/<token>` guest ingress, which is followed here to prove the guest
  actually lands in the meeting. Every refusal must be byte-identical, so the
  refusal cases are compared against each other, not just against a status.

  Not async: LiveKit credentials are application-global (same reason as
  `meeting_live_test.exs`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.GuestShortCode
  alias Platform.Repo

  @meet_host "meet.example.org"

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  defp meet(conn), do: %{conn | host: @meet_host}

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Short Link Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{project_id: project.id, name: "Short Link Meeting #{n}"})

    meeting
  end

  defp guest_invite!(meeting, name \\ "Jane Doe") do
    {:ok, %{invite: invite, token: token, url: url}} =
      Meetings.invite_guest(meeting, %{display_name: name})

    {invite, token, url}
  end

  defp refusal(conn, code) do
    conn = conn |> meet() |> get("/g/#{code}")
    {conn.status, conn.resp_body, get_resp_header(conn, "content-type")}
  end

  describe "a valid code" do
    test "302s to /<slug>/<token> on the same host with no-store and no-referrer", %{conn: conn} do
      meeting = meeting!()
      {invite, _token, _url} = guest_invite!(meeting)

      conn = conn |> meet() |> get("/g/#{invite.short_code}")

      assert conn.status == 302
      assert ["/" <> rest] = get_resp_header(conn, "location")
      assert [slug, token] = String.split(rest, "/")
      assert slug == meeting.slug
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      assert {:ok, %{invite_id: invite_id, meeting_id: meeting_id}} =
               Platform.Meetings.GuestInvite.verify(token)

      assert invite_id == invite.id
      assert meeting_id == meeting.id
    end

    test "following the redirect lands the named guest in the meeting", %{conn: conn} do
      meeting = meeting!()
      {invite, _token, _url} = guest_invite!(meeting, "Jordan Coombs")

      location =
        conn |> meet() |> get("/g/#{invite.short_code}") |> get_resp_header("location") |> hd()

      {:ok, view, html} = build_conn() |> meet() |> live(location)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.chrome_mode == :none
      assert html =~ ~s(data-role="meeting-mic")
      assert html =~ "Jordan Coombs"
    end

    test "the old long link still admits", %{conn: conn} do
      meeting = meeting!()
      {_invite, token, _url} = guest_invite!(meeting)

      assert {:ok, _view, html} = conn |> meet() |> live("/#{meeting.slug}/#{token}")
      assert html =~ ~s(data-role="meeting-mic")
    end
  end

  describe "every refusal is the same response" do
    test "expired, revoked, deleted meeting, unknown, malformed and wrong-length", %{conn: conn} do
      expired_meeting = meeting!()
      {expired, _, _} = guest_invite!(expired_meeting)

      expired
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      revoked_meeting = meeting!()
      {revoked, _, _} = guest_invite!(revoked_meeting)
      {:ok, _} = Meetings.revoke_invite(revoked)

      deleted_meeting = meeting!()
      {deleted, _, _} = guest_invite!(deleted_meeting)
      Repo.delete!(deleted_meeting)

      codes = [
        expired.short_code,
        revoked.short_code,
        deleted.short_code,
        GuestShortCode.generate(),
        "not-a-code",
        String.duplicate("A", 21),
        String.duplicate("A", 23)
      ]

      responses = Enum.map(codes, &refusal(conn, &1))

      assert [{status, body, _type} = first | _] = responses
      assert status == PlatformWeb.GuestShortLinkController.refusal_status()
      assert body == PlatformWeb.GuestShortLinkController.refusal_body()
      assert Enum.uniq(responses) == [first]

      # Names no meeting, slug or guest.
      for meeting <- [expired_meeting, revoked_meeting, deleted_meeting] do
        refute body =~ meeting.slug
        refute body =~ meeting.name
      end

      refute body =~ "Jane Doe"
    end

    test "a refusal carries no-store and no-referrer too", %{conn: conn} do
      conn = conn |> meet() |> get("/g/#{GuestShortCode.generate()}")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end
end
