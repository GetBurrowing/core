defmodule PlatformWeb.MeetingLiveIndexExternalTest do
  @moduledoc """
  The EXTERNAL half of the scoped meetings index (019f9cb7 stage 5), reached
  over HTTP the way production reaches it (task 019ffbb3).

  It lives in its own module rather than beside its internal sibling in
  `meeting_live_test.exs` because reaching `/meetings` as an external user
  requires the configured meet host (`ExternalUserScope` admits the index on
  the `:meet` surface only), and setting `:meet_host` is process-global
  application state — unsafe inside an `async: true` module.

  EVERY case here runs with `:host_surface_enforcement` at its configured
  `:on`. That is the point of the module: `/meetings` is declared inside the
  `:meet_member` live_session, so the host fence admits it on the meet host
  and no relaxation is needed. A case that only passed with the fence off
  would be evidence about a configuration production does not run.

  The internal branch is asserted in `meeting_live_test.exs`, and once more
  here as a direction control — without it, a change that broke the app host
  would still show all-green.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @meet_host "meet.example.com"

  # A real IANA zone with a UTC offset, so a fixture that confused local and
  # server time cannot accidentally pass the calendar placement assertion.
  @grid_zone "America/Chicago"

  setup do
    previous = Application.get_env(:platform, :meet_host)
    Application.put_env(:platform, :meet_host, @meet_host)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :meet_host, previous)
      else
        Application.delete_env(:platform, :meet_host)
      end
    end)

    Repo.delete_all(Meeting)
    :ok
  end

  # `ExternalSurface.for_conn/1` matches the CONFIGURED meet host exactly and
  # the setting is unset in test, so the put_env above is load-bearing — it is
  # the host fence being configured, not relaxed.
  defp external_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ext_index_#{n}@doeco.example",
        name: "External Viewer",
        oidc_sub: "oidc-ext-index-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member",
      external: true
    })
    |> Repo.insert!()

    conn = %{conn | host: @meet_host}

    {init_test_session(conn, current_user_id: user.id), user}
  end

  # An INTERNAL viewer on the DEFAULT host — the `conn` is left untouched, so
  # this exercises `:authenticated` under the shell.
  defp internal_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "int_index_#{n}@example.com",
        name: "Internal Viewer",
        oidc_sub: "oidc-int-index-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp meeting!(opts \\ []) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Ext Index Project #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(
        Enum.into(opts, %{
          project_id: project.id,
          name: "Ext Index Meeting #{n}",
          slug: "ext-index-meeting-#{n}"
        })
      )

    meeting
  end

  # A live invite (no expiry, not revoked) keyed on `user_id` — the shape both
  # `viewer_listing_query/1` and `invited_to_slug?/2` admit.
  defp invite!(meeting, user) do
    %Invite{}
    |> Invite.changeset(%{
      meeting_id: meeting.id,
      user_id: user.id,
      display_name: "Ext Index Invitee"
    })
    |> Repo.insert!()
  end

  defp zoned_conn(conn), do: put_connect_params(conn, %{"timezone" => @grid_zone})

  defp zoned_utc(%Date{} = date, hour, minute) do
    date
    |> DateTime.new!(Time.new!(hour, minute, 0), @grid_zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp attach_telemetry do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "ext-index-#{inspect(ref)}",
      [:platform, :auth, :access_blocked],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:access_blocked, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("ext-index-#{inspect(ref)}") end)
    ref
  end

  # ── Admission ──────────────────────────────────────────────────────────

  test "an EXTERNAL viewer reaches /meetings on the meet host with the fence ON",
       %{conn: conn} do
    {conn, _user} = external_conn(conn)

    {:ok, _view, html} = live(conn, ~p"/meetings")

    assert html =~ ~s(data-empty-state="meetings-index")
    assert html =~ "No meetings yet."

    # An external user genuinely IS invite-scoped — the index query answers
    # from their live invites and nothing else — so this copy is true for
    # them, and only for them.
    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(~s([data-role="meetings-index-empty-note"]))
           |> LazyHTML.attribute("data-viewer") == ["external"]

    assert html =~ "once you&#39;ve been invited"
    refute html =~ "Meetings for your organisation will appear here."
  end

  # ── Render under the meet layout ───────────────────────────────────────
  #
  # Stage 1 moved this mount out of `:authenticated` (shell layout,
  # `chrome_mode: :shell`) and into `:meet_member` (`:guest` layout,
  # `chrome_mode: "none"`). The index render path had only ever been
  # exercised under the shell, so a template branch reading a shell-supplied
  # assign would show up here as a KeyError or a blank body.

  test "the index BODY renders under the meet layout with a seeded invited meeting",
       %{conn: conn} do
    {conn, user} = external_conn(conn)

    today = PlatformWeb.MeetingLive.calendar_today_date(@grid_zone)

    meeting =
      meeting!(
        name: "Doeco Kickoff",
        status: "scheduled",
        scheduled_start_at: zoned_utc(today, 9, 0),
        scheduled_end_at: zoned_utc(today, 10, 0)
      )

    invite!(meeting, user)

    {:ok, _view, html} = live(zoned_conn(conn), ~p"/meetings")

    # The list is no longer empty, and the invited row draws.
    refute html =~ ~s(data-empty-state="meetings-index")
    assert html =~ "Doeco Kickoff"

    # The calendar chrome the index is built around is present, i.e. the body
    # is a rendered page and not a stub.
    assert html =~ ~s(data-region="meetings-workspace")
  end

  # ── Direction control ──────────────────────────────────────────────────

  test "an INTERNAL viewer on the app host still gets the shell index and the internal copy",
       %{conn: conn} do
    {conn, _user} = internal_conn(conn)

    {:ok, _view, html} = live(conn, ~p"/meetings")

    assert html =~ ~s(data-empty-state="meetings-index")

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(~s([data-role="meetings-index-empty-note"]))
           |> LazyHTML.attribute("data-viewer") == ["internal"]

    assert html =~ "Meetings for your organisation will appear here."
    refute html =~ "once you&#39;ve been invited"
  end

  # ── The surface was NOT opened generally ───────────────────────────────

  test "the SAME external user on the meet host still cannot reach another app route",
       %{conn: conn} do
    {conn, _user} = external_conn(conn)

    conn = get(conn, "/tasks")

    # Which fence answers first is a routing detail — `ExternalUserScope`'s
    # `{:meet, _}` clause (403) or `HostSurface` (404). Pinning one makes this
    # brittle; what must hold is that it is not a 200.
    refute conn.status == 200
    assert conn.status in [403, 404]
  end

  # ── No existence oracle, still ─────────────────────────────────────────
  #
  # Two cases, one per side, deliberately. A single case cannot see the two
  # outcomes collapsing into each other — which is the property under test.

  test "a REAL meeting the external user holds no invite for is denied", %{conn: conn} do
    attach_telemetry()
    {conn, _user} = external_conn(conn)

    meeting = meeting!()

    conn = get(conn, "/meetings/#{meeting.slug}")

    assert conn.status == 403
    assert_receive {:access_blocked, %{reason: "external_meeting_not_invited"}}
  end

  test "a slug naming NO meeting is denied identically", %{conn: conn} do
    attach_telemetry()
    {conn, _user} = external_conn(conn)

    conn = get(conn, "/meetings/no-such-meeting-at-all")

    assert conn.status == 403
    assert_receive {:access_blocked, %{reason: "external_meeting_not_invited"}}
  end
end
