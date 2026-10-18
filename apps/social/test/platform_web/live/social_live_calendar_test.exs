defmodule PlatformWeb.SocialLiveCalendarTest do
  @moduledoc """
  The Social tab's Calendar (Social 7/7 stage 3): a Mon-Sun week in UTC with
  one row per account (desktop) and a day-by-day agenda (mobile), status
  marks with icon and text, week navigation, and a read-only post detail.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.Post
  alias PlatformWeb.SocialCalendar

  # A post on `account` put straight into a calendar status at `at`.
  defp placed!(ctx, account, status, at, attrs \\ %{}) do
    {:ok, post} = Social.create_post(ctx.org_id, account, Map.merge(%{body: "body"}, attrs))

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set:
        [
          status: status,
          scheduled_at: at,
          approved_by_user_id: ctx.h1.id,
          approved_at: DateTime.add(at, -2, :day)
        ] ++ Map.to_list(Map.take(attrs, [:external_url]))
    )

    Repo.get!(Post, post.id)
  end

  defp at(date, h), do: DateTime.new!(date, Time.new!(h, 0, 0), "Etc/UTC")

  setup do
    ctx = approval_fixture()
    monday = SocialCalendar.week_start(Date.utc_today())
    tue = Date.add(monday, 1)
    thu = Date.add(monday, 3)

    scheduled = placed!(ctx, ctx.a, "scheduled", at(tue, 10), %{body: "HTC-S1 SCHEDULED-BODY"})

    published =
      placed!(ctx, ctx.d, "published", at(thu, 9), %{
        body: "PUBLISHED-BODY",
        external_url: "https://example.com/p/1"
      })

    failed = placed!(ctx, ctx.a, "failed", at(Date.add(monday, 4), 15))
    next_week = placed!(ctx, ctx.a, "scheduled", at(Date.add(monday, 8), 12), %{body: "NEXT"})
    _draft = placed!(ctx, ctx.a, "draft", at(tue, 11), %{body: "DRAFT-NOT-ON-CAL"})

    {:ok, legacy} =
      Social.create_profile(ctx.org_id, %{
        name: "Legacy #{unique()}",
        space_id: channel!(ctx.org_id).id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, _} =
      Social.create_account(ctx.org_id, legacy, %{platform: "youtube", handle: "Legacy channel"})

    Map.merge(ctx, %{
      monday: monday,
      tue: tue,
      thu: thu,
      scheduled: scheduled,
      published: published,
      failed: failed,
      next_week: next_week,
      legacy: legacy
    })
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    child
  end

  defp row(account), do: "#calendar_rows-#{account.id}"

  defp cell(account, date),
    do: "#{row(account)} [data-role='social-calendar-cell'][data-date='#{Date.to_iso8601(date)}']"

  defp item(post), do: "[data-role='social-calendar-item'][data-post-id='#{post.id}']"

  test "one row per account, and each item lands on its day with a status label",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(child, row(ctx.a))
    assert has_element?(child, row(ctx.d))

    assert has_element?(
             child,
             "#social-calendar-rows [data-role='social-calendar-row']",
             "@htc_official"
           )

    assert has_element?(child, cell(ctx.a, ctx.tue) <> " " <> item(ctx.scheduled), "10:00")
    assert has_element?(child, cell(ctx.a, ctx.tue) <> " [data-status='scheduled']", "scheduled")
    assert has_element?(child, cell(ctx.d, ctx.thu) <> " [data-status='published']", "published")

    assert has_element?(
             child,
             cell(ctx.a, Date.add(ctx.monday, 4)) <> " [data-status='failed']",
             "failed"
           )

    refute has_element?(child, cell(ctx.a, ctx.thu) <> " " <> item(ctx.published))
    refute has_element?(child, "#social-calendar-rows " <> item(ctx.next_week))
    refute render(child) =~ "DRAFT-NOT-ON-CAL"

    for status <- ~w(scheduled published failed) do
      assert has_element?(
               child,
               "[data-role='social-calendar-legend'] [data-status='#{status}']",
               status
             )
    end

    for day <- ~w(Mon Tue Wed Thu Fri Sat Sun) do
      assert has_element?(child, "[data-role='social-day-head']", day)
    end
  end

  test "the mobile agenda lists only days with items, with platform, time and handle",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             "#agenda_days-#{Date.to_iso8601(ctx.tue)} " <> item(ctx.scheduled),
             "10:00"
           )

    assert has_element?(child, "#agenda_days-#{Date.to_iso8601(ctx.tue)}", "linkedin")
    assert has_element?(child, "#agenda_days-#{Date.to_iso8601(ctx.thu)}", "@htc_drafts")
    refute has_element?(child, "#agenda_days-#{Date.to_iso8601(Date.add(ctx.monday, 2))}")
  end

  test "next/prev/this week re-stream the week", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    child |> element("[data-role='week-next']") |> render_click()
    assert has_element?(child, "#social-calendar-rows " <> item(ctx.next_week))
    refute has_element?(child, item(ctx.scheduled))

    child |> element("[data-role='week-prev']") |> render_click()
    child |> element("[data-role='week-prev']") |> render_click()
    refute has_element?(child, item(ctx.scheduled))
    refute has_element?(child, item(ctx.next_week))
    assert has_element?(child, "[data-role='social-empty']", "Nothing scheduled for")

    child |> element("[data-role='week-this']") |> render_click()
    assert has_element?(child, item(ctx.scheduled))
  end

  test "a profile switch leaves no item of the other profile and keeps Calendar",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, item(ctx.scheduled))

    child |> form("#social-profile-switcher", %{profile_id: ctx.legacy.id}) |> render_change()

    refute has_element?(child, item(ctx.scheduled))
    refute has_element?(child, row(ctx.a))
    assert has_element?(child, "[data-role='social-tab-body'][data-tab='calendar']")

    assert has_element?(
             child,
             "[data-role='social-empty']",
             "Nothing scheduled for #{ctx.legacy.name} this week."
           )
  end

  test "the detail is read-only; it hides a scheduled post's body from a non-approver",
       %{conn: conn} = ctx do
    child = open(conn, ctx.n)
    child |> element("#social-calendar-rows " <> item(ctx.scheduled)) |> render_click()

    assert has_element?(child, "[data-role='social-post-detail']", "scheduled")
    assert has_element?(child, "[data-role='social-post-detail']", "@htc_official")
    refute has_element?(child, "[data-role='social-post-detail-body']")
    refute render(child) =~ "SCHEDULED-BODY"
    refute has_element?(child, "[data-role='social-post-detail'] form")
    refute has_element?(child, "[data-role='social-post-detail'] textarea")

    # Published: body and the link, for anyone who sees the profile.
    child |> element("[data-role='social-post-detail-close']") |> render_click()
    refute has_element?(child, "[data-role='social-post-detail']")
    child |> element("#social-calendar-rows " <> item(ctx.published)) |> render_click()
    assert has_element?(child, "[data-role='social-post-detail-body']", "PUBLISHED-BODY")

    assert has_element?(
             child,
             "[data-role='social-post-detail-link'][href='https://example.com/p/1']",
             "View published post"
           )
  end

  test "an approver sees a scheduled post's body; a forged id from elsewhere opens nothing",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element("#social-calendar-rows " <> item(ctx.scheduled)) |> render_click()
    assert has_element?(child, "[data-role='social-post-detail-body']", "HTC-S1 SCHEDULED-BODY")

    other = approval_fixture()
    foreign = placed!(other, other.a, "scheduled", at(ctx.tue, 8), %{body: "FOREIGN-BODY"})
    render_click(child, "open_post", %{"id" => foreign.id})
    refute render(child) =~ "FOREIGN-BODY"
    refute has_element?(child, "[data-role='social-post-detail']")
  end

  test "list_posts places by scheduled_at, else approved_at, in a half-open range", ctx do
    from = DateTime.new!(ctx.monday, ~T[00:00:00], "Etc/UTC")
    to = DateTime.add(from, 7, :day)

    ids =
      Social.list_posts(ctx.org_id,
        profile_id: ctx.profile.id,
        statuses: SocialCalendar.statuses(),
        placed_from: from,
        placed_to: to
      )
      |> Enum.map(& &1.id)
      |> MapSet.new()

    assert ids == MapSet.new([ctx.scheduled.id, ctx.published.id, ctx.failed.id])

    {:ok, now_pub} = Social.create_post(ctx.org_id, ctx.a, %{body: "immediate"})
    approved_at = at(ctx.tue, 13)

    Repo.update_all(from(p in Post, where: p.id == ^now_pub.id),
      set: [
        status: "published",
        scheduled_at: nil,
        approved_by_user_id: ctx.h1.id,
        approved_at: approved_at
      ]
    )

    assert now_pub.id in Enum.map(
             Social.list_posts(ctx.org_id,
               statuses: ["published"],
               placed_from: from,
               placed_to: to
             ),
             & &1.id
           )
  end
end
