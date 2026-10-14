defmodule PlatformWeb.MeetingLiveTopBarLgTest do
  @moduledoc """
  Task 01a0e091 (stages 1, 2 and 3; Saru's design direction, canvas
  01a0e0cf-25c6-7001-a8d0-a2eb14115efe): the meeting top bar at `lg` with
  all three state pills (live, rec, transcribing) showing.

  STRUCTURE ONLY. LiveViewTest renders HTML; it has no layout engine, so
  nothing here measures a pixel, and a green run says nothing about whether
  anything overlaps. The widths live in the header's comment in
  `meeting_live.html.heex`, measured on dev-on-moon with CDP
  `getBoundingClientRect`. What this file pins is the set of structural
  facts those measurements rest on, so that the next pill added to this bar
  (or a class tidy-up) cannot quietly undo them:

    * the grid template stays `1fr auto 1fr`, so the switcher stays centred;
    * the controls are ONE node, in the right track, holding Join;
    * the roster count yields from `lg` until `2xl` (1536px);
    * the truncating title carries its full name as a tooltip;
    * each pill's word is `sr-only` from `lg` until `min-[108.125rem]`
      (1730px) and still in the accessibility tree (never `hidden`), and the
      transcribing pill's icon paints in that band so the pill is never
      colour-only. The short band outlasts the roster's return on purpose:
      at 1536 the roster count and full-word pills leave the title 0px;
    * the stage-mode labels are hidden from `lg` until `xl`, and every
      button keeps its `title` tooltip.

  Each assertion names the class it pins in its failure message; the commit
  that added this file records a per-class mutation check against it.

  `async: false`, mirroring `meeting_live_transcriber_filter_test.exs`,
  whose fixtures this file copies.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @meeting_name "Top Bar Lg Sync"

  # ── Fixtures (mirroring meeting_live_transcriber_filter_test.exs) ───────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "top_bar_lg_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-top-bar-lg-#{n}"
    })
  end

  defp authenticated_conn(conn) do
    viewer = user!("Viewer")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    init_test_session(conn, current_user_id: viewer.id)
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Top Bar Lg Space #{n}",
        slug: "top-bar-lg-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Top Bar Lg Project #{n}",
        slug: "top-bar-lg-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "top-bar-lg-#{n}",
        name: @meeting_name,
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  # All three pills on: an active room (live), a recording row at
  # "recording" (rec) and the transcriber's nil-FK row (transcribing).
  defp seed_all_pills do
    {meeting, space, room} = meeting!()
    user = user!("Ada Human")

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "Ada Human"})

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{
        identity: "transcriber:space-#{space.id}",
        name: "Transcription"
      })

    Repo.insert!(%Platform.Meetings.Recording{
      room_id: room.id,
      space_id: room.space_id,
      status: "recording"
    })

    meeting
  end

  defp classes(doc, selector) do
    case doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") do
      [class] -> String.split(class)
      other -> flunk("expected exactly one #{selector}, got #{length(other)}")
    end
  end

  defp assert_class(doc, selector, class) do
    assert class in classes(doc, selector), "#{selector} lost #{class}"
  end

  setup %{conn: conn} do
    meeting = seed_all_pills()
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
    doc = LazyHTML.from_fragment(html)

    for pill <- ~w(meeting-live-pill meeting-recording-pill meeting-transcribing-pill) do
      assert Enum.count(LazyHTML.query(doc, ~s([data-role="#{pill}"]))) == 1,
             "fixture did not render #{pill}"
    end

    %{doc: doc}
  end

  test "(a) the header grid keeps the centred 1fr auto 1fr template", %{doc: doc} do
    assert_class(doc, "header:has([data-role=meeting-header-end])", "lg:grid-cols-[1fr_auto_1fr]")
  end

  test "(b) the controls are one node in the right track and hold Join", %{doc: doc} do
    assert Enum.count(LazyHTML.query(doc, ~s([data-role="meeting-controls"]))) == 1

    assert Enum.count(
             LazyHTML.query(
               doc,
               ~s([data-role="meeting-header-end"] > [data-role="meeting-controls"] [data-role="meeting-join"])
             )
           ) == 1
  end

  test "(c) the roster count yields from lg until 2xl", %{doc: doc} do
    sel = ~s([data-role="meeting-roster-count"])
    assert_class(doc, sel, "lg:hidden")
    assert_class(doc, sel, "2xl:flex")
  end

  test "(d) the truncating title carries the full meeting name as a tooltip", %{doc: doc} do
    assert doc
           |> LazyHTML.query(~s([data-role="meeting-title"] h1))
           |> LazyHTML.attribute("title") ==
             [@meeting_name]
  end

  test "(e) live: 'meeting ' is sr-only from lg until 1730px", %{doc: doc} do
    sel = ~s([data-role="meeting-live-pill"] > span:last-child > span.sr-only)
    assert_class(doc, sel, "lg:sr-only")
    assert_class(doc, sel, "min-[108.125rem]:not-sr-only")
  end

  test "(e) rec: 'ording' is sr-only from lg until 1730px", %{doc: doc} do
    sel = ~s([data-role="meeting-recording-pill"] > span:last-child > span.sr-only)
    assert_class(doc, sel, "lg:sr-only")
    assert_class(doc, sel, "min-[108.125rem]:not-sr-only")
  end

  test "(e) transcribing: the word is sr-only from lg until 1730px", %{doc: doc} do
    sel = ~s([data-role="meeting-transcribing-pill"] > span.sr-only)
    assert_class(doc, sel, "lg:sr-only")
    assert_class(doc, sel, "min-[108.125rem]:not-sr-only")
  end

  test "(e) transcribing: the document icon paints from lg until 1730px", %{doc: doc} do
    sel = ~s([data-role="meeting-transcribing-pill"] > span.hero-document-text)
    assert_class(doc, sel, "lg:block")
    assert_class(doc, sel, "min-[108.125rem]:hidden")
  end

  test "(f) stage-mode labels hide from lg until xl, and every button keeps its title",
       %{doc: doc} do
    buttons = LazyHTML.query(doc, "[data-stage-mode-button]")
    assert Enum.count(buttons) > 0

    titles = LazyHTML.attribute(buttons, "title")
    assert length(titles) == Enum.count(buttons), "a stage-mode button lost its title"

    for title <- titles do
      assert title != "", "a stage-mode button lost its title"
    end

    labels = LazyHTML.query(doc, "[data-stage-mode-button] > span:nth-child(2)")
    assert Enum.count(labels) == Enum.count(buttons)

    for label_class <- LazyHTML.attribute(labels, "class") do
      label_classes = String.split(label_class)
      assert "lg:hidden" in label_classes, "stage-mode label lost lg:hidden"
      assert "xl:inline" in label_classes, "stage-mode label lost xl:inline"
    end
  end
end
