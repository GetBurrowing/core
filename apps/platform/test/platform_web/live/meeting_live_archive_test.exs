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

    # A plain member, not "admin": `Tenancy.root_admin?/1` reads admin as
    # "sees every org", which would make the archive's org scoping untested.
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp project!, do: project!("Control Center")

  defp project!(name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        org_id: Platform.TenancyFixtures.acme_org_id()
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

  # Cancelled WITH an attribution, and — when `notified?` — with the
  # cancellation fan-out's own stamp put on by the function that production
  # uses. `Meeting.status_changeset/3` does not cast
  # `cancellation_notified_at` (it is claimed by a conditional UPDATE, not by
  # a changeset), so writing it here by hand would be testing a column this
  # code never sets that way.
  defp cancelled_by!(%Meeting{} = meeting, canceller, cancelled_at, notified?) do
    {:ok, cancelled} =
      meeting
      |> Meeting.status_changeset("cancelled", %{
        cancelled_at: cancelled_at,
        cancelled_by_participant_id: canceller.id
      })
      |> Repo.update()

    if notified? do
      {:ok, notified} = Meetings.mark_cancellation_notified(cancelled)
      notified
    else
      cancelled
    end
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
      |> host!("Alex")
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
      |> host!("Alex")
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

  # A viewer with a membership and NOTHING archived. Deliberately not
  # `archive_world!/0` with its rows deleted: the empty archive is the state a
  # new org is actually in, and it has to be reachable by building nothing.
  defp empty_conn(conn) do
    viewer = viewer!()
    {login(conn, viewer), viewer}
  end

  # Two rows and no filler — everything below is about ONE row's copy or about
  # which of two cards renders, and forty-seven meetings would only make a
  # failure harder to read.
  #
  #   * `retro` — ended, one canvas revised inside its window. It is the
  #     POSITIVE CONTROL for "the cancelled row has no chips": without a row
  #     that does have chips in the same render, "no chips" is satisfied by a
  #     page where chips never render at all.
  #   * `workshop` — cancelled by Alex, notified, and it produced nothing.
  #
  # Alex is a plain participant rather than the host, so the subtitle under
  # test carries the cancellation clause and the attendee count and no
  # "hosted by" — one fewer moving part in a string asserted with `==`.
  defp cancellation_world! do
    viewer = viewer!()
    project = project!()

    retro =
      project
      |> meeting!("Quarterly retro")
      |> ran!(at("2026-07-28T15:00:00Z"), at("2026-07-28T16:00:00Z"))

    retro |> canvas!("Retro board") |> version!(7, at("2026-07-28T15:30:00Z"))

    workshop = meeting!(project, "Pricing workshop")
    alex = participant!(workshop, "Alex")
    workshop = cancelled_by!(workshop, alex, at("2026-07-22T10:00:00Z"), true)

    %{
      viewer: viewer,
      project: project,
      retro: retro,
      workshop: workshop,
      alex: alex,
      org_name: Tenancy.get_org_by_slug!("acme").name
    }
  end

  # An archive that HAS meetings, plus a real second project that has none —
  # so `?project_id=<empty project>` is a filter a human can produce from the
  # project dropdown and which excludes every row the viewer owns.
  defp filtered_out_world! do
    viewer = viewer!()
    project = project!()
    empty_project = project!("Growth")

    project
    |> meeting!("Quarterly retro")
    |> ran!(at("2026-07-28T15:00:00Z"), at("2026-07-28T16:00:00Z"))

    project
    |> meeting!("Pipeline review")
    |> ran!(at("2026-07-27T15:00:00Z"), at("2026-07-27T15:40:00Z"))

    %{viewer: viewer, project: project, empty_project: empty_project}
  end

  defp chip_count(view, meeting_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "[data-meeting-id='#{meeting_id}'] [data-role='archive-row-chips'] [data-role='archive-chip']"
    )
    |> Enum.count()
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

    test "the list-driven shelf renders exactly its entries, in order", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings")

      # Every entry declared in `meetings_view_shelf/0` renders, and nothing
      # else does — so adding a view is one list entry, and a dropped entry
      # fails here rather than silently vanishing from the shelf.
      shelf_ids =
        PlatformWeb.MeetingLive.meetings_view_shelf() |> Enum.map(& &1.id)

      assert shelf_ids == [:calendar, :archive]

      for id <- shelf_ids do
        assert has_element?(view, "[data-role='meetings-view-toggle'] [data-view='#{id}']")
      end

      rendered_ids =
        view
        |> render()
        |> then(&Regex.scan(~r/data-view="([a-z]+)"/, &1))
        |> Enum.map(fn [_, id] -> id end)

      assert rendered_ids == Enum.map(shelf_ids, &to_string/1)
    end

    test "each shelf entry carries a distinct hero-icon and an aria-label naming it",
         %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings")

      # Calendar gets a calendar glyph, Archive an archive-box glyph — each
      # inside its own segment, each announced by an aria-label.
      assert has_element?(
               view,
               "[data-view='calendar'][aria-label='Calendar'] .hero-calendar-days"
             )

      assert has_element?(
               view,
               "[data-view='archive'][aria-label='Archive'] .hero-archive-box"
             )
    end

    test "the active segment is marked aria-current on each half", %{conn: conn} do
      {conn, _world} = archive_conn(conn)

      {:ok, calendar_view, _html} = live(conn, ~p"/meetings")
      assert has_element?(calendar_view, "[data-view='calendar'][aria-current='page']")
      refute has_element?(calendar_view, "[data-view='archive'][aria-current='page']")

      {:ok, archive_view, _html} = live(conn, ~p"/meetings?view=archive")
      assert has_element?(archive_view, "[data-view='archive'][aria-current='page']")
      refute has_element?(archive_view, "[data-view='calendar'][aria-current='page']")
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

      refute has_element?(view, "[data-empty-state='archive-no-matches']")
    end
  end

  # ── 5. Cancelled rows ──────────────────────────────────────────────────────

  describe "a cancelled meeting's row" do
    test "carries its attribution and no chips, beside a control row that has one",
         %{conn: conn} do
      world = cancellation_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      # A cancellation that vanishes is indistinguishable from a meeting that
      # never existed, so the row is PRESENT — dimmed, not dropped.
      assert has_element?(
               view,
               "[data-role='archive-row'][data-meeting-id='#{world.workshop.id}']"
             )

      # `==`, not `=~`. "Cancelled by Alex" is a proper substring of every
      # wrong-but-longer value this expression can produce — a count nobody
      # can source, a second attribution, a duration for a meeting that never
      # ran — and `=~` is green against all of them.
      assert element_text(
               view,
               "[data-meeting-id='#{world.workshop.id}'] [data-role='archive-row-subtitle']"
             ) ==
               "Cancelled by Alex · attendees notified · 1 attended · " <>
                 "#{world.org_name} / Control Center"

      assert element_text(
               view,
               "[data-meeting-id='#{world.workshop.id}'] [data-role='archive-no-artifacts']"
             ) == "no artifacts"

      # Both halves of one claim, in ONE render. The zero is only evidence
      # that the cancelled row produced nothing if a row in the same render
      # produced something — otherwise it is evidence that chips are broken.
      assert chip_count(view, world.workshop.id) == 0
      assert chip_count(view, world.retro.id) > 0

      # And the converse of the pill: a row WITH chips does not claim it has
      # none.
      refute has_element?(
               view,
               "[data-meeting-id='#{world.retro.id}'] [data-role='archive-no-artifacts']"
             )
    end

    test "claims a notification only when one happened", %{conn: conn} do
      viewer = viewer!()
      project = project!()

      quiet = meeting!(project, "Quiet cancellation")
      quiet_alex = participant!(quiet, "Alex")
      quiet = cancelled_by!(quiet, quiet_alex, at("2026-07-21T10:00:00Z"), false)

      loud = meeting!(project, "Announced cancellation")
      loud_dalton = participant!(loud, "Dalton")
      loud = cancelled_by!(loud, loud_dalton, at("2026-07-20T10:00:00Z"), true)

      org_name = Tenancy.get_org_by_slug!("acme").name
      conn = login(conn, viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      # BOTH directions in one run. A renderer that dropped the notified
      # clause entirely satisfies the nil case on its own; one that always
      # rendered it satisfies the non-nil case on its own.
      assert element_text(
               view,
               "[data-meeting-id='#{quiet.id}'] [data-role='archive-row-subtitle']"
             ) == "Cancelled by Alex · 1 attended · #{org_name} / Control Center"

      assert element_text(
               view,
               "[data-meeting-id='#{loud.id}'] [data-role='archive-row-subtitle']"
             ) ==
               "Cancelled by Dalton · attendees notified · 1 attended · " <>
                 "#{org_name} / Control Center"
    end

    test "falls back to a bare Cancelled when the canceller's row is gone", %{conn: conn} do
      viewer = viewer!()
      project = project!()

      orphan = meeting!(project, "Orphaned cancellation")
      orphan = cancelled_by!(orphan, %{id: nil}, at("2026-07-19T10:00:00Z"), true)

      org_name = Tenancy.get_org_by_slug!("acme").name
      conn = login(conn, viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      # `cancelled_by_participant_id` NILIFIES rather than cascades by design,
      # so an unattributable cancellation is a real state that must render as
      # itself rather than as "Cancelled by " with a hole where a name was.
      # `==` is what catches that hole: "Cancelled by " CONTAINS "Cancelled".
      assert element_text(
               view,
               "[data-meeting-id='#{orphan.id}'] [data-role='archive-row-subtitle']"
             ) == "Cancelled · attendees notified · #{org_name} / Control Center"
    end
  end

  # ── 6. The two empty states ────────────────────────────────────────────────
  #
  # This surface has spent a week removing exactly one defect: two different
  # answers rendered as one card. The pair below is asserted FROM BOTH SIDES
  # every time — a present-only assertion is satisfied by a renderer that
  # shows both states at once, which is the defect wearing the fix's markup.

  describe "the archive's two empty states" do
    test "an archive with nothing in it renders no-meetings and NOT no-matches", %{conn: conn} do
      {conn, _viewer} = empty_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      assert has_element?(view, "[data-empty-state='archive-no-meetings']")
      refute has_element?(view, "[data-empty-state='archive-no-matches']")
    end

    test "a query that matched nothing renders no-matches, over the rows that exist",
         %{conn: conn} do
      world = cancellation_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=quokka")

      assert has_element?(view, "[data-empty-state='archive-no-matches']")

      # The control that gets the reader out. 44px minimum, and it clears the
      # filters as well as the query — see `archive_clear_path/1`.
      assert has_element?(view, "[data-action='archive-clear-filters']")

      # The meetings ARE there, they just did not match — and showing them is
      # what distinguishes this state from an empty archive. A no-matches card
      # rendered over a blank page says the same thing as "No meetings yet".
      assert element_text(view, "[data-role='archive-others-heading']") ==
               "Also in this range, no match"

      assert has_element?(
               view,
               "[data-archive-section='others'] [data-role='archive-row'][data-meeting-id='#{world.retro.id}']"
             )
    end

    # Split from its twin above ON PURPOSE. ExUnit stops at the first failing
    # assertion, so a conflation that made the no-matches branch render the
    # no-meetings card would only ever be scored against whichever of the two
    # came first. As two tests, both sides report.
    test "a query that matched nothing does NOT render no-meetings", %{conn: conn} do
      world = cancellation_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive&q=quokka")

      refute has_element?(view, "[data-empty-state='archive-no-meetings']")
    end

    test "the two states' headings are different strings", %{conn: conn} do
      {blank_conn, _viewer} = empty_conn(conn)
      {:ok, empty_view, _html} = live(blank_conn, ~p"/meetings?view=archive")

      world = cancellation_world!()

      {:ok, queried_view, _html} =
        live(login(conn, world.viewer), ~p"/meetings?view=archive&q=quokka")

      no_meetings = element_text(empty_view, "[data-role='archive-no-meetings-heading']")
      no_matches = element_text(queried_view, "[data-role='archive-no-matches-heading']")

      assert no_meetings == "No meetings yet"
      assert no_matches == "No matches"

      # Compared to EACH OTHER, not just to their literals. A refactor that
      # collapsed the two cards into one shared component with one heading
      # would keep both literals satisfiable only by breaking here.
      refute no_meetings == no_matches
    end

    # ── The FILTER path, with a blank query ──────────────────────────────
    #
    # This is the branch `:unfiltered_total` exists for, and the one the
    # obvious predicate gets wrong. `result.total` already has the person and
    # project filters applied, so a filter that excludes every row drives it
    # to zero exactly as an empty archive does — and an archive full of
    # meetings then reports "No meetings yet", which is the same conflation
    # this pair was built to remove, arriving by a different door.
    #
    # Blank query on purpose: with a query, `matched == 0` would reach the
    # no-matches state anyway and the filter's contribution would be invisible.
    # Split into two tests for the same reason as the query pair above —
    # ExUnit halts at the first failure, so one test can only report one side.

    test "a filter that excludes every meeting renders no-matches, on a blank query", %{
      conn: conn
    } do
      world = filtered_out_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} =
        live(conn, ~p"/meetings?view=archive&project_id=#{world.empty_project.id}")

      assert has_element?(view, "[data-empty-state='archive-no-matches']")

      # And the way back out, since the filter is what the reader has to undo.
      assert has_element?(view, "[data-action='archive-clear-filters']")
    end

    test "a filter that excludes every meeting does NOT render no-meetings", %{conn: conn} do
      world = filtered_out_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} =
        live(conn, ~p"/meetings?view=archive&project_id=#{world.empty_project.id}")

      # The viewer HAS archived meetings — they are one filter away. Telling
      # them they have none is a false statement about their own data.
      refute has_element?(view, "[data-empty-state='archive-no-meetings']")

      # Both directions on the fixture itself, in the same run: without this
      # the pair above is satisfiable by a fixture that seeded no meetings at
      # all, which would make "the archive is not empty" the untested premise
      # the whole claim rests on.
      {:ok, unfiltered, _html} = live(conn, ~p"/meetings?view=archive")

      refute has_element?(unfiltered, "[data-empty-state='archive-no-meetings']")
      assert has_element?(unfiltered, "[data-archive-section='others']")
    end

    test "a blank query over a populated archive is NEITHER empty state", %{conn: conn} do
      world = cancellation_world!()
      conn = login(conn, world.viewer)

      {:ok, view, _html} = live(conn, ~p"/meetings?view=archive")

      refute has_element?(view, "[data-empty-state='archive-no-meetings']")
      refute has_element?(view, "[data-empty-state='archive-no-matches']")

      # It renders the archive itself instead. A blank query has no matched
      # partition at all, so every in-scope row sits in the `others` section
      # — which is the answer, not an empty state.
      assert has_element?(view, "[data-archive-section='others']")

      assert has_element?(
               view,
               "[data-archive-section='others'] [data-role='archive-row'][data-meeting-id='#{world.retro.id}']"
             )
    end
  end

  # ── 7. External users ──────────────────────────────────────────────────────

  describe "external users" do
    test "are denied the archive route outright", %{conn: conn} do
      external = ExternalUserFixtures.create_user!()

      {:ok, _membership} =
        Tenancy.mark_membership_external(%{
          user_id: external.id,
          org_id: Tenancy.get_org_by_slug!("globex").id
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
