defmodule PlatformWeb.MeetingLiveArchiveTest do
  @moduledoc """
  Tests for the meetings index's **archive** half and the `Calendar · Archive`
  toggle (task `019fb954-c848`).

  Every assertion here goes through the ROUTER — `live(conn, ~p"/meetings?…")`
  — rather than through the LiveView's assigns or a component in isolation.
  Asserting on assigns proves the data shape and nothing about the page: a
  green data test sitting next to a 500 on the route is the exact failure this
  surface keeps producing, and only a real mount catches it.

  Two shapes are load-bearing:

    * **The count is asserted with `==` on its own element**, not with `=~`
      against the page. `html =~ "2 of 47"` is satisfied by a `2 of 47` that
      came from somewhere this code never wrote, and — worse — it cannot tell
      `"2 of 47 · filtered"` from a longer wrong value that contains it. The
      fixture is built to produce exactly two matches out of exactly
      forty-seven in-scope meetings so the string has one correct value.

    * **Section membership is asserted by `data-` attribute containment**, not
      by the order two strings happen to appear in the raw HTML. String order
      is satisfied by markup that renders every row in one undivided list, so
      it would pass on a page that had lost the partition entirely.

  The external-user assertion is a REGRESSION FENCE, not a description of a
  feature: `ExternalUserScope` allowlists `/chat` and `/chat/:slug` only, so
  `/meetings` falls through to its uniform 403 today. It is pinned here so
  that widening the allowlist later BREAKS A TEST instead of quietly exposing
  every archived meeting, its canvases and its transcripts to an external
  user.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Version, as: CanvasVersion
  alias Platform.ExternalUserFixtures
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # The whole archive is forty-seven meetings; two of them answer to
  # "bucket policy". Both numbers are pinned here because the count string
  # under test is built from exactly these two.
  @total 47
  @matched 2
  @query "bucket policy"

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp viewer! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "archive-viewer-#{n}@example.com",
        name: "Archive Viewer #{n}",
        oidc_sub: "oidc-archive-viewer-#{n}"
      })

    # A plain member, not "admin": `Tenancy.fabrikam_admin?/1` reads admin as
    # "sees every org", which would make the archive's org scoping untested.
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp project! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Control Center",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    project
  end

  defp meeting!(project, name) do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  # Both ends supplied explicitly: the canvas revision span is scoped to the
  # meeting's ACTUAL window, so a fixture that let `end_meeting/1` stamp
  # `utc_now()` would decide which revisions land in which chip by accident.
  defp ran!(%Meeting{} = meeting, started_at, ended_at) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: started_at}) |> Repo.update()

    {:ok, ended} =
      live |> Meeting.status_changeset("ended", %{ended_at: ended_at}) |> Repo.update()

    ended
  end

  defp cancelled!(%Meeting{} = meeting, cancelled_at) do
    {:ok, cancelled} =
      meeting
      |> Meeting.status_changeset("cancelled", %{cancelled_at: cancelled_at})
      |> Repo.update()

    cancelled
  end

  defp participant!(%Meeting{} = meeting, display_name) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    participant
  end

  defp host!(%Meeting{} = meeting, display_name) do
    participant = participant!(meeting, display_name)

    meeting
    |> Ecto.Changeset.change(host_participant_id: participant.id)
    |> Repo.update!()
  end

  # Inserted through the schema rather than `Chat.create_canvas/1`, which
  # writes a revision-1 row stamped `utc_now()` — an extra revision the
  # fixture never asked for would land inside whichever meeting window happens
  # to contain "now" and silently widen the span this test asserts on.
  defp canvas!(%Meeting{} = meeting, title) do
    %Canvas{}
    |> Canvas.changeset(%{
      space_id: meeting.chat_space_id,
      created_by: participant!(meeting, "Author").id,
      title: title
    })
    |> Repo.insert!()
  end

  defp version!(%Canvas{} = canvas, revision, written_at) do
    %CanvasVersion{}
    |> CanvasVersion.changeset(%{
      canvas_id: canvas.id,
      revision: revision,
      document: %{"version" => 1, "revision" => revision, "root" => %{}},
      written_by: %{"type" => "user", "id" => Ecto.UUID.generate()},
      written_at: written_at
    })
    |> Repo.insert!()
  end

  defp at(iso), do: DateTime.from_iso8601(iso) |> elem(1)

  # Forty-seven archived meetings in the viewer's org, of which exactly two
  # answer to "bucket policy" — both via a canvas titled for it, which is what
  # the design's matched rows show. The filler names share no lexeme with the
  # query, so the matched partition cannot drift as the filler grows.
  defp archive_world! do
    viewer = viewer!()
    project = project!()

    editor =
      project
      |> meeting!("Experiment editor v2")
      |> host!("Rowan")
      |> ran!(at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

    editor |> canvas!("Bucket policy canvas") |> version!(14, at("2026-07-29T14:41:00Z"))
    participant!(editor, "Dalton")

    spike =
      project
      |> meeting!("Assignment policy spike")
      |> host!("Dalton")
      |> ran!(at("2026-06-11T09:00:00Z"), at("2026-06-11T09:30:00Z"))

    spike_canvas = canvas!(spike, "Bucket policy canvas")
    version!(spike_canvas, 1, at("2026-06-11T09:05:00Z"))
    version!(spike_canvas, 3, at("2026-06-11T09:29:00Z"))

    workshop =
      project
      |> meeting!("Pricing workshop")
      |> host!("Rowan")
      |> cancelled!(at("2026-07-22T10:00:00Z"))

    filler =
      for index <- 1..(@total - 3) do
        project
        |> meeting!("Routine sync #{index}")
        |> ran!(at("2026-05-04T09:00:00Z"), at("2026-05-04T09:25:00Z"))
      end

    %{
      viewer: viewer,
      project: project,
      editor: editor,
      spike: spike,
      workshop: workshop,
      filler: filler
    }
  end

  # `render/1` on an element returns markup; the assertions here are about the
  # STRING a reader sees, so the tags come off and runs of whitespace collapse
  # to the single spaces the template's line breaks stand in for.
  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp element_text(view, selector), do: view |> element(selector) |> render() |> text()

  defp archive_conn(conn) do
    world = archive_world!()
    {login(conn, world.viewer), world}
  end

  # ── 1. The count ───────────────────────────────────────────────────────────

  describe "the archive count" do
    test "reads MATCHED of total, not total of total", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=#{@query}")

      # `==` on the element, not `=~` on the page. A substring assertion is
      # green against "47 of 47 · filtered" for the "of 47" half and cannot
      # see the difference that matters.
      assert element_text(view, "[data-role='archive-count']") ==
               "#{@matched} of #{@total} · filtered"

      # The phone has no room for a count in the header, so the same number
      # renders as the results-section heading. Asserted in the SAME test as
      # its desktop twin: they are one claim about one expression, and
      # splitting them would double the blast radius of any mutation of it.
      assert element_text(view, "[data-role='archive-count-mobile']") ==
               "#{@matched} of #{@total} · by relevance"
    end

    test "an unqueried archive reports a plain total, not zero matches", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      # A blank query has no matched partition at all — reporting "0 of 47"
      # would describe it as a search that found nothing.
      assert element_text(view, "[data-role='archive-count']") == "#{@total} archived"
    end
  end

  # ── 2. The partition ───────────────────────────────────────────────────────

  describe "the two result sections" do
    test "a matching meeting sits under Matches and a non-matching one under Also in this range",
         %{conn: conn} do
      {conn, world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=#{@query}")

      assert element_text(view, "[data-role='archive-matches-heading']") == "Matches"

      assert element_text(view, "[data-role='archive-others-heading']") ==
               "Also in this range, no match"

      # Containment, not string order: a page that lost the partition and
      # rendered one flat list still emits both headings and both rows in the
      # order this fixture creates them.
      assert has_element?(
               view,
               "[data-archive-section='matches'] [data-role='archive-row'][data-meeting-id='#{world.editor.id}']"
             )

      assert has_element?(
               view,
               "[data-archive-section='matches'] [data-role='archive-row'][data-meeting-id='#{world.spike.id}']"
             )

      assert has_element?(
               view,
               "[data-archive-section='others'] [data-role='archive-row'][data-meeting-id='#{world.workshop.id}']"
             )

      # Both directions in the same run: a renderer that put EVERY row in
      # both sections satisfies the three assertions above on their own.
      refute has_element?(
               view,
               "[data-archive-section='others'] [data-role='archive-row'][data-meeting-id='#{world.editor.id}']"
             )

      refute has_element?(
               view,
               "[data-archive-section='matches'] [data-role='archive-row'][data-meeting-id='#{world.workshop.id}']"
             )
    end
  end

  # ── 3. Artifact chips ──────────────────────────────────────────────────────

  describe "artifact chips" do
    test "a canvas chip is a revision SPAN, rendered whole", %{conn: conn} do
      {conn, world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=#{@query}")

      # `==`, never `=~`. Dropping the meeting's window from the span query
      # widens this chip to "rev 1–14", which CONTAINS "rev 14".
      assert element_text(
               view,
               "[data-meeting-id='#{world.editor.id}'] [data-chip-type='canvas'] [data-role='archive-chip-label']"
             ) == "Bucket policy canvas · rev 14"

      assert element_text(
               view,
               "[data-meeting-id='#{world.spike.id}'] [data-chip-type='canvas'] [data-role='archive-chip-label']"
             ) == "Bucket policy canvas · rev 1–3"
    end

    test "a meeting that produced nothing renders as such, not as a crash", %{conn: conn} do
      {conn, world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=#{@query}")

      # A cancelled meeting never ran, so no revision can fall inside its
      # window and it has no chips at all. That is a real state with a real
      # rendering — not an absent row and not a 500.
      assert element_text(
               view,
               "[data-meeting-id='#{world.workshop.id}'] [data-role='archive-no-artifacts']"
             ) == "no artifacts"
    end
  end

  # ── 4. The toggle ──────────────────────────────────────────────────────────

  describe "the Calendar · Archive toggle" do
    test "?view=archive shows the archive and NOT the list, and the default does the converse",
         %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, archive_view, _html} = live(conn, ~p"/meetings?view=archive")

      assert has_element?(archive_view, "[data-region='meetings-archive']")
      refute has_element?(archive_view, "[data-region='meetings-list']")

      # Both directions in the same run. A pane conditional that was always
      # true would pass either half of this on its own.
      {:ok, calendar_view, _html} = live(conn, ~p"/meetings")

      assert has_element?(calendar_view, "[data-region='meetings-list']")
      refute has_element?(calendar_view, "[data-region='meetings-archive']")
    end

    test "both segments are present on both halves", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      for path <- [~p"/meetings", ~p"/meetings?view=archive"] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "[data-role='meetings-view-toggle'] [data-view='calendar']")
        assert has_element?(view, "[data-role='meetings-view-toggle'] [data-view='archive']")
      end
    end

    test "the search box pushes its query into the URL so a result set is linkable", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      view
      |> element("[data-region='meetings-archive'] form")
      |> render_change(%{"q" => @query})

      # The PARAMETERS, not their serialisation order — the builder emits them
      # sorted, and pinning that order would make this test a change-detector
      # for a detail no reader of the URL depends on.
      patched = assert_patch(view)

      assert patched |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() == %{
               "view" => "archive",
               "q" => @query
             }

      # The patch has to RE-RUN the search, not just rewrite the address bar.
      # Asserted on the partition rather than on the count element: the count
      # is the subject of its own test above, and duplicating it here would
      # make two tests fail for one broken expression, which makes each of
      # them a weaker signal about what actually broke.
      assert has_element?(view, "[data-archive-section='matches']")

      refute has_element?(view, "[data-role='archive-no-matches']")
    end
  end

  # ── 5. External users ──────────────────────────────────────────────────────

  describe "external users" do
    test "are denied the archive route outright", %{conn: conn} do
      external = ExternalUserFixtures.create_user!()

      {:ok, _membership} =
        Tenancy.mark_membership_external(%{
          user_id: external.id,
          org_id: Tenancy.get_org_by_slug!("sxi").id
        })

      # The STATUS, not the body: the body is a uniform error page shared with
      # every other denial, and asserting on it would pin the wrong thing.
      # This fence exists so that adding `/meetings` to `ExternalUserScope`'s
      # allowlist fails here rather than shipping the archive to an external
      # user unnoticed.
      assert conn
             |> ExternalUserFixtures.login(external.id)
             |> get(~p"/meetings?view=archive")
             |> Map.fetch!(:status) == 403
    end
  end
end
