defmodule PlatformWeb.MeetingLiveProjectScopeTest do
  @moduledoc """
  The `/meetings` index start-meeting sheet renders a project `<select>`.
  Before this test's companion change it was populated from an unscoped
  `Tasks.list_projects_unscoped/1`, so every authenticated user saw the NAME of
  every project in every org.

  These assertions are deliberately about the RENDERED `<option>` SET, not
  about the return value of `Tasks.list_projects_for_user/2` — that
  context-level coverage lives with the function itself. The point here is
  that the LiveView actually passes a viewer through.

  The positive controls are mandatory: an implementation that assigns `[]`
  to `@projects` for everybody would satisfy the absence assertion alone
  while breaking the feature.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # `@example.com` keeps `Tenancy.derive_role_from_email/1` at `:member`;
  # a `@acme.test` address would derive admin and blanket-bypass the very
  # scope these tests pin.
  defp user!(role, org_id) do
    user =
      Repo.insert!(%User{
        email: "meeting_scope_#{System.unique_integer([:positive])}@example.com",
        name: "Meeting Scope User",
        oidc_sub: "oidc-meeting-scope-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id, name) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: name,
        slug: "meeting-scope-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  defp project_option_texts(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select[data-role=start-meeting-project] option")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp seed do
    acme_org_id = Platform.TenancyFixtures.acme_org_id()
    tenant_org_id = Platform.TenancyFixtures.tenant_org_id("globex")

    own = project!(acme_org_id, "Own Acme Project #{System.unique_integer([:positive])}")
    foreign = project!(tenant_org_id, "Foreign Project #{System.unique_integer([:positive])}")

    %{acme_org_id: acme_org_id, own: own, foreign: foreign}
  end

  describe "start-meeting project picker scoping" do
    # The plain member is seeded into a TENANT org, not the root org. Per
    # Alex's 2026-08-05 sub-orgs ruling, sub-orgs are filtering mechanisms
    # rather than walls, so `Tenancy.visibility/1` returns `:root_all` for a
    # root member at ANY role — a root-org viewer would see every tenant's
    # project and make this absence assertion unsatisfiable by design. Only a
    # non-root viewer exercises the org filter.
    test "a plain member does not see a foreign org's project name", %{conn: conn} do
      own_org_id = Platform.TenancyFixtures.tenant_org_id("initech")
      own = project!(own_org_id, "Own Tenant Project #{System.unique_integer([:positive])}")

      foreign =
        project!(
          Platform.TenancyFixtures.tenant_org_id("globex"),
          "Foreign Project #{System.unique_integer([:positive])}"
        )

      user = user!("member", own_org_id)

      # Preconditions: an admin viewer bypasses the scope by design, and a
      # root-org viewer sees everything by design. Either would make a broken
      # filter look correct.
      refute Tenancy.root_admin?(user)
      refute Tenancy.root_member?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, "/meetings?view=calendar")

      # The picker only renders inside the start-meeting sheet, which the
      # FAB opens (on the calendar half; task 01a18d9f stage 4 gave the list
      # view the v4 modal); the dead render never contains it.
      options =
        view
        |> element("[data-role=start-meeting-fab]")
        |> render_click()
        |> project_option_texts()

      # Positive control — without it, `@projects == []` passes the refute.
      assert own.name in options
      refute foreign.name in options
    end

    test "an Acme root admin sees both orgs' projects", %{conn: conn} do
      %{acme_org_id: acme_org_id, own: own, foreign: foreign} = seed()
      admin = user!("admin", acme_org_id)

      assert Tenancy.root_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, view, _html} = live(conn, "/meetings?view=calendar")

      options =
        view
        |> element("[data-role=start-meeting-fab]")
        |> render_click()
        |> project_option_texts()

      assert own.name in options
      assert foreign.name in options
    end
  end

  # ── Index meeting scoping (task 019f9cb7 stage 2) ─────────────────────────
  #
  # The meetings the index DRAWS, as distinct from the projects its picker
  # offers. Three reads fed this surface unscoped: the `:index` load, the
  # PubSub re-query behind a peer's broadcast, and the calendar week range
  # query. The first two share `@meetings`; the third is what puts a NAME on
  # screen, so the rendered-output assertions here go through the grid.
  #
  # Every denial carries a positive control in the SAME test: an index that
  # renders nothing for everybody satisfies each `refute` on its own.
  describe "index meeting scoping" do
    @index_zone "America/Chicago"

    defp index_conn(conn, user) do
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => @index_zone})
    end

    # Noon on the anchor day, in the viewer's zone: comfortably inside the
    # rendered week and inside any hour window derived from it.
    defp midday_today do
      @index_zone
      |> PlatformWeb.MeetingLive.calendar_today_date()
      |> DateTime.new!(~T[12:00:00], @index_zone)
      |> DateTime.shift_zone!("Etc/UTC")
    end

    defp meeting!(org_id, label) do
      project = project!(org_id, "#{label} Project #{System.unique_integer([:positive])}")
      start_at = midday_today()

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{
          project_id: project.id,
          name: "#{label} Meeting #{System.unique_integer([:positive])}",
          scheduled_start_at: start_at,
          scheduled_end_at: DateTime.add(start_at, 1800, :second)
        })

      {project, meeting}
    end

    # `@meetings` is the assign the `:index` load and the PubSub re-query
    # both write. It has no surface of its own on today's index — the list
    # half was replaced by the calendar, and the count chip counts the
    # WEEK's rows, not this collection — so a rendered assertion cannot
    # distinguish a scoped read from an unscoped one here. It is still
    # carried to the client on every diff and the archive sibling reads it,
    # so it is asserted directly rather than left uncovered.
    defp meeting_assign_ids(view) do
      %{socket: %{assigns: %{meetings: meetings}}} = :sys.get_state(view.pid)
      Enum.map(meetings, & &1.id)
    end

    test "a member sees own-org meetings and not a foreign org's", %{conn: conn} do
      own_org_id = Platform.TenancyFixtures.tenant_org_id("initech")
      foreign_org_id = Platform.TenancyFixtures.tenant_org_id("globex")

      {_own_project, own_meeting} = meeting!(own_org_id, "Own")
      {_foreign_project, foreign_meeting} = meeting!(foreign_org_id, "Foreign")

      user = user!("member", own_org_id)
      refute Tenancy.root_admin?(user)
      refute Tenancy.root_member?(user)

      {:ok, view, html} = live(index_conn(conn, user), "/meetings")

      ids = meeting_assign_ids(view)
      assert own_meeting.id in ids
      refute foreign_meeting.id in ids

      # Positive control first — if this fails the refutes below prove
      # nothing, because an empty index satisfies them.
      assert html =~ own_meeting.name
      refute html =~ foreign_meeting.name
      refute html =~ foreign_meeting.slug

      # The same foreign row IS drawn for a member of ITS org, through the
      # same route and the same fixture. That is what makes the absence
      # above a scoping fact rather than a rendering accident.
      other = user!("member", foreign_org_id)
      {:ok, _other_view, other_html} = live(index_conn(conn, other), "/meetings")

      assert other_html =~ foreign_meeting.name
      refute other_html =~ own_meeting.name
    end

    test "a peer broadcast does not re-leak a foreign meeting into a scoped index",
         %{conn: conn} do
      own_org_id = Platform.TenancyFixtures.tenant_org_id("initech")
      foreign_org_id = Platform.TenancyFixtures.tenant_org_id("globex")

      {own_project, own_meeting} = meeting!(own_org_id, "Own")
      {_foreign_project, foreign_meeting} = meeting!(foreign_org_id, "Foreign")

      user = user!("member", own_org_id)
      {:ok, view, html} = live(index_conn(conn, user), "/meetings")

      assert html =~ own_meeting.name
      refute html =~ foreign_meeting.name

      # The broadcast lands on a topic this view IS subscribed to (its own
      # project's), which is the only way the clause runs at all. What it
      # carries is a foreign meeting — the point is the RE-QUERY the clause
      # performs, which used to be unscoped and so re-leaked into an index
      # that had mounted correctly.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.Meetings.project_meetings_topic(own_project.id),
        {:meeting_created, foreign_meeting}
      )

      updated = render(view)

      assert updated =~ own_meeting.name
      refute updated =~ foreign_meeting.name
      refute updated =~ foreign_meeting.slug

      # The list assign the same clause rewrites, which the render cannot
      # speak for.
      ids = meeting_assign_ids(view)
      assert own_meeting.id in ids
      refute foreign_meeting.id in ids
    end
  end
end
