defmodule PlatformWeb.MeetingBreadcrumbTest do
  @moduledoc """
  Stage 3 of task 019f62c8 — the shared breadcrumb "take me UP to root"
  escape hatch (built in stage 2 as `PlatformWeb.CoreComponents.breadcrumb/1`)
  applied to the Meetings subpage.

  Two regression guards:

    * The authenticated shell `:show` view (`/meetings/:slug`) renders a
      breadcrumb whose root link up-targets `/meetings` (the meetings list)
      and whose inert current segment names the meeting.

    * The guest surface (`chrome_mode == :none`, `:in_meeting`) — which
      shares the SAME `@meeting != nil` shell tree as the authenticated
      surface — renders NO breadcrumb, so no authenticated back-to-list
      link leaks to guests on the chromeless `meet.` host flow.

  `async: false` because the guest `:in_meeting` path mutates the global
  `:livekit` application env (mirrors `meeting_live_guest_mount_test.exs`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Repo
  alias Platform.Tasks

  # LiveKit config is toggled per-test only for the guest `:in_meeting`
  # path (it mints a real bundle). The shell path does not need it.
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
        name: "Breadcrumb Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    project
  end

  defp create_meeting(attrs \\ %{}) do
    project = Map.get_lazy(attrs, :project, fn -> create_project() end)
    name = Map.get(attrs, :name, "Kickoff Sync")

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    Repo.preload(meeting, :chat_space)
  end

  # `meet.` host prefix so the router's `:guest_meeting` scope wins the match.
  defp with_meet_host(conn, host \\ "meet.localhost") do
    %{conn | host: host}
  end

  describe "shell chrome (:show)" do
    test "renders a breadcrumb whose root link up-targets /meetings", %{conn: conn} do
      meeting = create_meeting(%{name: "Kickoff Sync"})

      user =
        Repo.insert!(%User{
          email: "bc_shell_#{System.unique_integer([:positive])}@example.com",
          name: "Breadcrumb Shell User",
          oidc_sub: "oidc-bc-shell-#{System.unique_integer([:positive])}"
        })

      # Org plumbing (task 019f9b14 stage 2): `/meetings/:slug` resolves
      # through the org-scoped `Meetings.fetch_meeting_for_user/2`, so the
      # viewer needs the Fabrikam-root membership every OIDC signup gets —
      # `create_meeting/1` puts the project in that same org.
      Repo.insert!(
        Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
          user_id: user.id,
          org_id: Platform.TenancyFixtures.fabrikam_org_id(),
          role: "member"
        })
      )

      {:ok, view, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(current_user_id: user.id)
        |> live(~p"/meetings/#{meeting.slug}")

      # The shared breadcrumb nav is present with a root link up-targeting
      # the Meetings module root.
      assert has_element?(
               view,
               ~s(nav[data-role="breadcrumb"] a[data-role="breadcrumb-link"][href="/meetings"])
             )

      # The clickable root ancestor is labelled "Meetings".
      assert view
             |> element(
               ~s(nav[data-role="breadcrumb"] a[data-role="breadcrumb-link"][href="/meetings"])
             )
             |> render() =~ "Meetings"

      # The inert current segment names the meeting.
      assert has_element?(view, ~s(nav[data-role="breadcrumb"] [data-role="breadcrumb-current"]))

      assert view
             |> element(~s(nav[data-role="breadcrumb"] [data-role="breadcrumb-current"]))
             |> render() =~ meeting.name
    end
  end

  describe "guest chrome (chrome_mode: :none)" do
    setup do
      put_livekit_env()
      :ok
    end

    test "the guest :in_meeting shell tree renders NO breadcrumb", %{conn: conn} do
      meeting = create_meeting()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # Confirm we actually reached the shared `@meeting != nil` shell tree
      # (guest :in_meeting), NOT a bail-out card — the meeting controls +
      # guest identity badge render. This is what makes the negative
      # assertion below meaningful: the breadcrumb is gated OUT of the same
      # tree that DOES render, rather than merely absent because a different
      # branch rendered instead.
      assert html =~ ~s(data-role="meeting-controls")
      assert html =~ ~s(data-role="guest-identity-badge")

      # The shell-only breadcrumb must NOT render for guests — no
      # authenticated back-to-list link leaks to the chromeless surface.
      refute has_element?(view, ~s(nav[data-role="breadcrumb"]))
      refute html =~ ~s(data-role="breadcrumb")
    end
  end
end
