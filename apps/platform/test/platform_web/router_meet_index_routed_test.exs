defmodule PlatformWeb.RouterMeetIndexRoutedTest do
  @moduledoc """
  ROUTED coverage for the external meetings index on the meet host
  (019f9cb7).

  ## Why this module exists at all

  Every test the earlier stages added for this surface drives
  `ExternalUserScope.call/2` DIRECTLY on a `Plug.Test`-built conn (the
  `run_on_host/4` helper in `external_user_scope_test.exs`), or relaxes
  `:host_surface_enforcement` to reach the LiveView. Neither shape issues a
  real request, so neither can observe that the path the plug ADMITS has no
  route on that host. `refute conn.halted` is compatible with a 404: the plug
  said yes to a door that was not there.

  That is exactly the defect that shipped green. An external user got 403 on
  the app host (correct, off-surface) and 404 on the meet host (wrong), and
  the stage-4 allowlist clause `{:meet, ["meetings"]}` was dead code over
  HTTP.

  So every case here goes through `Phoenix.ConnTest.get/2` — endpoint,
  router, full pipeline — with `:host_surface_enforcement` LEFT AT ITS
  PRODUCTION `:on`. Relaxing the fence is precisely what hid the bug; a test
  that switches it off proves nothing about whether the route exists.

  `async: false` — `:meet_host` and the enforcement flag are process-global
  application state.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @meet_host "meet.example.com"
  @app_host "localhost"

  setup do
    previous_host = Application.get_env(:platform, :meet_host)
    previous_fence = Application.get_env(:platform, :host_surface_enforcement, :off)

    Application.put_env(:platform, :meet_host, @meet_host)
    # Deliberately ON. This is the production value (config.exs) and the
    # condition under which the 404 occurred.
    Application.put_env(:platform, :host_surface_enforcement, :on)

    on_exit(fn ->
      Application.put_env(:platform, :host_surface_enforcement, previous_fence)

      if previous_host,
        do: Application.put_env(:platform, :meet_host, previous_host),
        else: Application.delete_env(:platform, :meet_host)
    end)

    :ok
  end

  defp external_user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ext_routed_#{n}@example.com",
        name: "External Viewer #{n}",
        oidc_sub: "oidc-ext-routed-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member",
      external: true
    })
    |> Repo.insert!()

    user
  end

  defp as(conn, user, host) do
    %{conn | host: host}
    |> init_test_session(current_user_id: user.id)
  end

  # A meeting the external user holds NO invite to — the per-meeting gate's
  # subject. Same org as the viewer, so only the missing invite can deny it.
  defp uninvited_meeting! do
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Routed Scope Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    now = DateTime.utc_now()

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Uninvited Routed Session",
        scheduled_start_at: DateTime.add(now, 3600, :second),
        scheduled_end_at: DateTime.add(now, 5400, :second)
      })

    meeting
  end

  describe "the index over a real routed request" do
    test "external user, meet host, /meetings → 200", %{conn: conn} do
      conn = get(as(conn, external_user!(), @meet_host), "/meetings")

      # Spelled out because the two wrong answers are different bugs: 404 is
      # the missing route, 403 is the allowlist clause.
      refute conn.status == 404, "no /meetings route on the meet host"
      refute conn.status == 403, "ExternalUserScope denied the admitted index path"
      assert conn.status == 200
    end

    test "external user, meet host, /meetings?view=archive → 200", %{conn: conn} do
      conn = get(as(conn, external_user!(), @meet_host), "/meetings?view=archive")

      refute conn.status == 404
      assert conn.status == 200
    end

    test "external user, app host, /meetings → still 403 (off-surface, unchanged)",
         %{conn: conn} do
      conn = get(as(conn, external_user!(), @app_host), "/meetings")

      assert conn.status == 403
    end
  end

  describe "the per-meeting gate does not regress" do
    test "external user, meet host, an uninvited /meetings/:slug → 403", %{conn: conn} do
      meeting = uninvited_meeting!()

      conn = get(as(conn, external_user!(), @meet_host), "/meetings/#{meeting.slug}")

      assert conn.status == 403

      # Adding the index must not have widened the SHOW route: the denial is
      # per-meeting and it is not an existence oracle either.
      refute conn.resp_body =~ meeting.name
    end
  end

  describe "the meet surface is fail-closed without a configured meet host" do
    setup do
      Application.delete_env(:platform, :meet_host)
      :ok
    end

    test "unconfigured :meet_host → the index on the meet host is denied, not served",
         %{conn: conn} do
      # Routing here is a `meet.` PREFIX match; ADMISSION matches the
      # CONFIGURED host exactly. With nothing configured there is no meet
      # surface to be on, so the external user must not reach the index —
      # the new route must not become an unconditional hole.
      conn = get(as(conn, external_user!(), @meet_host), "/meetings")

      refute conn.status == 200
      assert conn.status == 403
    end
  end
end
