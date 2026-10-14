defmodule PlatformWeb.MeetingLiveIndexMobileCardsTest do
  @moduledoc """
  FE-17 stage 7 (task 01a07410) — the meetings index at 390px.

  Below `lg` the index draws one card per meeting on the selected day,
  and each card is a `navigate` link to `/meetings/<slug>`; at `lg` the
  week grid is the only surface. A LiveView test cannot measure a
  viewport, so the width claims are pinned the only way the server can
  see them: by the breakpoint classes on the elements. Both halves of
  each pair are asserted, because each alone admits a build that draws
  both at 390px (see `meeting_live_test`'s responsive pair test).

  ANTI-VACUITY (stage 7 spec): remove `lg:hidden` from the card list and
  the `assert "lg:hidden" in list_classes` line detonates; remove `hidden`
  from the week grid and the grid pair detonates.
  """

  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @zone "America/Chicago"

  setup %{conn: conn} do
    {conn, _user} = authenticated_conn(conn)
    Repo.delete_all(Meeting)
    project = create_project()
    {:ok, conn: conn, project: project}
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "meeting_cards_#{System.unique_integer([:positive])}@example.com",
        name: "Meeting Cards User",
        oidc_sub: "oidc-meeting-cards-#{System.unique_integer([:positive])}"
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

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Meeting Cards Space #{System.unique_integer([:positive])}",
        slug: "meeting-cards-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_project do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Meeting Cards Project #{System.unique_integer([:positive])}",
        slug: "meeting-cards-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    project
  end

  defp grid_conn(conn), do: put_connect_params(conn, %{"timezone" => @zone})
  defp today, do: PlatformWeb.MeetingLive.calendar_today_date(@zone)

  defp zoned_utc(%Date{} = date, hour, minute) do
    date
    |> DateTime.new!(Time.new!(hour, minute, 0), @zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp seed_meeting(project, opts) do
    space = create_space()
    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: Keyword.fetch!(opts, :slug),
        name: Keyword.get(opts, :name, "Meeting #{Keyword.fetch!(opts, :slug)}"),
        livekit_room_name: "meeting-#{meeting_id}",
        status: Keyword.get(opts, :status, "scheduled"),
        scheduled_start_at: Keyword.fetch!(opts, :scheduled_start_at),
        scheduled_end_at: Keyword.fetch!(opts, :scheduled_end_at)
      })
      |> Repo.insert()

    meeting
  end

  defp attrs_of(html, selector, attribute) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end

  defp classes(html, selector) do
    html |> attrs_of(selector, "class") |> List.first() |> String.split()
  end

  describe "the mobile card list" do
    test "renders below lg with one card per meeting carrying state chip and time, while the week grid is lg-only",
         %{conn: conn, project: project} do
      live =
        seed_meeting(project,
          slug: "cards-live",
          name: "Standup",
          status: "live",
          scheduled_start_at: zoned_utc(today(), 9, 0),
          scheduled_end_at: zoned_utc(today(), 9, 30)
        )

      later =
        seed_meeting(project,
          slug: "cards-later",
          name: "Retro",
          scheduled_start_at: zoned_utc(today(), 14, 15),
          scheduled_end_at: zoned_utc(today(), 15, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The width pair: the list is `lg:hidden` and NOT also `hidden`; the
      # grid is `hidden` and `lg:grid`. Each half alone admits a build that
      # draws both surfaces at 390px or neither at 1280px.
      list_classes = classes(html, ~s([data-role="meeting-card-list"]))
      assert "lg:hidden" in list_classes
      refute "hidden" in list_classes

      grid_classes = classes(html, ~s([data-role="calendar-week-grid"]))
      assert "hidden" in grid_classes
      assert "lg:grid" in grid_classes

      # One card per meeting on the selected day, in start order, each a
      # navigate link to the meeting page.
      assert attrs_of(html, ~s([data-role="meeting-card"]), "data-meeting-id") ==
               [live.id, later.id]

      assert attrs_of(html, ~s([data-role="meeting-card"]), "href") ==
               ["/meetings/cards-live", "/meetings/cards-later"]

      assert attrs_of(html, ~s([data-role="meeting-card"]), "data-phx-link") == [
               "redirect",
               "redirect"
             ]

      # The state chip is a WORD, and the time is the zoned wall clock.
      card = fn id -> ~s([data-role="meeting-card"][data-meeting-id="#{id}"]) end

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(card.(live.id) <> ~s( [data-role="meeting-card-status"]))
             |> LazyHTML.text()
             |> String.trim() ==
               "Live"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(card.(later.id) <> ~s( [data-role="meeting-card-status"]))
             |> LazyHTML.text()
             |> String.trim() ==
               "Scheduled"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(card.(later.id) <> ~s( [data-role="meeting-card-time"]))
             |> LazyHTML.text()
             |> String.trim() ==
               "14:15"

      # The desktop week grid is untouched by the cards: the same two
      # meetings are still drawn as event blocks inside it.
      assert length(
               attrs_of(
                 html,
                 ~s([data-role="calendar-week-grid"] [data-role="calendar-event"]),
                 "data-meeting-id"
               )
             ) == 2
    end

    test "is absent entirely when the selected day has no meetings, and the heading still says so",
         %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, ~s([data-role="meeting-card-list"]), "data-role") == []
      assert html =~ "No meetings"
    end

    test "tapping a card routes to the meeting page for that slug", %{
      conn: conn,
      project: project
    } do
      meeting =
        seed_meeting(project,
          slug: "cards-tap",
          name: "Tap Target",
          scheduled_start_at: zoned_utc(today(), 11, 0),
          scheduled_end_at: zoned_utc(today(), 12, 0)
        )

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> element(~s([data-role="meeting-card"][data-meeting-id="#{meeting.id}"]))
        |> render_click()

      assert to == "/meetings/cards-tap"

      {:ok, _show, show_html} = live(grid_conn(conn), to)
      assert show_html =~ "Tap Target"
      assert show_html =~ ~s(data-role="meeting-join")
    end
  end
end
