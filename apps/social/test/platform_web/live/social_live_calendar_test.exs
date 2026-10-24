defmodule PlatformWeb.SocialLiveCalendarTest do
  @moduledoc """
  The Social tab's Calendar (Social 7/7 stage 3, reworked by Social
  authoring 8/11): a Mon-Sun week in a named zone, time rows by day columns
  (desktop) and a day-by-day agenda (phone), per-post states shown as text
  plus a border pattern, All brands with a colour per brand and a legend
  that toggles, posting slots shaded, and the post detail with approve.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Ideas, Post}
  alias PlatformWeb.SocialCalendar
  alias PlatformWeb.SocialCalendarClock, as: Clock

  # A post on `account` put straight into a calendar status at `at`.
  defp placed!(ctx, account, status, at, attrs) do
    {:ok, post} =
      Social.create_post(
        ctx.org_id,
        account,
        Map.merge(%{body: "body"}, Map.take(attrs, [:body]))
      )

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set:
        [
          status: status,
          scheduled_at: at,
          approved_by_user_id: ctx.h1.id,
          approved_at: DateTime.add(at, -2, :day)
        ] ++ Map.to_list(Map.drop(attrs, [:body]))
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

    failed =
      placed!(ctx, ctx.a, "failed", at(Date.add(monday, 4), 15), %{error: "Token expired"})

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

  defp all_brands(child),
    do: child |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()

  defp hh(h), do: h |> Integer.to_string() |> String.pad_leading(2, "0")

  defp cell(date, h),
    do:
      "#calendar_rows-h#{hh(h)} [data-role='social-calendar-cell'][data-date='#{Date.to_iso8601(date)}']"

  defp item(post), do: "[data-role='social-calendar-item'][data-post-id='#{post.id}']"
  defp grid_item(post), do: "#social-calendar-rows " <> item(post)

  test "each item lands in its day and hour with a state label; the week names its zone",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(child, cell(ctx.tue, 10) <> " " <> item(ctx.scheduled), "10:00")
    assert has_element?(child, cell(ctx.tue, 10) <> " [data-state='scheduled']", "scheduled")
    assert has_element?(child, cell(ctx.thu, 9) <> " [data-state='published']", "published")

    assert has_element?(
             child,
             cell(Date.add(ctx.monday, 4), 15) <> " [data-state='failed']",
             "failed"
           )

    refute has_element?(child, cell(ctx.thu, 10) <> " " <> item(ctx.published))
    refute has_element?(child, grid_item(ctx.next_week))
    refute render(child) =~ "DRAFT-NOT-ON-CAL"

    for state <- ~w(waiting scheduled published failed) do
      assert has_element?(child, "[data-role='social-calendar-legend'] [data-state='#{state}']")
    end

    for day <- ~w(Mon Tue Wed Thu Fri Sat Sun) do
      assert has_element?(child, "[data-role='social-day-head']", day)
    end

    # No profile timezone yet (4/11): the label names UTC, never a bare note.
    assert has_element?(child, "[data-role='social-week-zone'][data-zone='Etc/UTC']", "UTC")
  end

  test "the phone agenda lists only days with items, with state and handle",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             "#agenda_days-#{Date.to_iso8601(ctx.tue)} " <> item(ctx.scheduled),
             "10:00"
           )

    assert has_element?(
             child,
             "#agenda_days-#{Date.to_iso8601(ctx.tue)} [data-state='scheduled']",
             "scheduled"
           )

    assert has_element?(child, "#agenda_days-#{Date.to_iso8601(ctx.thu)}", "@htc_drafts")
    refute has_element?(child, "#agenda_days-#{Date.to_iso8601(Date.add(ctx.monday, 2))}")
  end

  test "next/prev/this week re-stream the week", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    child |> element("[data-role='week-next']") |> render_click()
    assert has_element?(child, grid_item(ctx.next_week))
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
    assert has_element?(child, "[data-role='social-tab-body'][data-tab='calendar']")

    assert has_element?(
             child,
             "[data-role='social-empty']",
             "Nothing scheduled for #{ctx.legacy.name} this week."
           )
  end

  describe "states" do
    test "a needs_approval post with scheduled_at is dashed and Waiting on you; approving it from the item makes it solid with no reload",
         %{conn: conn} = ctx do
      wed = Date.add(ctx.monday, 2)
      {post, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: at(wed, 14)})
      {unplaced, _card} = pending_post!(ctx, ctx.a, %{body: "NO-TIME-YET"})

      child = open(conn, ctx.h1)

      assert has_element?(child, cell(wed, 14) <> " " <> item(post) <> "[data-state='waiting']")
      assert has_element?(child, cell(wed, 14) <> " " <> item(post) <> ".border-dashed")
      assert has_element?(child, cell(wed, 14) <> " " <> item(post), "Waiting on you")
      refute has_element?(child, item(unplaced))

      child |> element(grid_item(post)) |> render_click()
      child |> element("[data-role='social-calendar-approve']") |> render_click()

      assert %Post{status: status} = Repo.get!(Post, post.id)
      assert status in ~w(approved scheduled published)
      refute has_element?(child, item(post) <> "[data-state='waiting']")
      assert has_element?(child, grid_item(post) <> ".border-solid")
      refute has_element?(child, "[data-role='social-calendar-approve']")
    end

    test "a non-approver sees Waiting on approval and gets no approve; an owned account names its owner",
         %{conn: conn} = ctx do
      wed = Date.add(ctx.monday, 2)
      {post, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: at(wed, 14)})

      child = open(conn, ctx.n)
      assert has_element?(child, grid_item(post), "Waiting on approval")
      child |> element(grid_item(post)) |> render_click()
      refute has_element?(child, "[data-role='social-calendar-approve']")

      render_click(child, "calendar_approve", %{"id" => post.id})
      assert Repo.get!(Post, post.id).status == "needs_approval"

      owner = named_user!("Omar Owner")
      member!(owner, ctx.org_id)
      {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, owner.id)

      child = open(Phoenix.ConnTest.build_conn(), ctx.h1)
      assert has_element?(child, grid_item(post), "Waiting on Omar Owner")
      child = open(Phoenix.ConnTest.build_conn(), owner)
      assert has_element?(child, grid_item(post), "Waiting on you")
    end

    test "a failed post shows the error tone and its reason; a refused one too",
         %{conn: conn} = ctx do
      refused =
        placed!(ctx, ctx.a, "approved", at(ctx.tue, 16), %{
          refused_reason: "rate_limited",
          refused_at: DateTime.utc_now()
        })

      child = open(conn, ctx.h1)

      failed = grid_item(ctx.failed)
      assert has_element?(child, failed <> ".border-error[data-state='failed']")
      assert has_element?(child, failed <> " .badge-error", "failed")

      assert has_element?(
               child,
               failed <> " [data-role='social-calendar-reason']",
               "Token expired"
             )

      assert has_element?(child, "[data-tip='Token expired'] " <> item(ctx.failed))

      assert has_element?(child, grid_item(refused) <> ".border-error[data-state='refused']")
      assert has_element?(child, grid_item(refused), "Refused: rate limited")

      child |> element(failed) |> render_click()
      assert has_element?(child, "[data-role='social-post-detail-reason']", "Token expired")
    end

    test "a published post with no metrics shows no result chip", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      assert has_element?(child, grid_item(ctx.published) <> "[data-state='published']")

      refute has_element?(
               child,
               grid_item(ctx.published) <> " [data-role='social-calendar-result']"
             )

      refute has_element?(child, "[data-role='social-calendar-result']")
    end

    test "a published post with metrics views 12400 shows 12.4k (render of the item chip)", ctx do
      post = Map.put(ctx.published, :metrics, %{"views" => 12_400})

      item = %{
        post: post,
        account: ctx.d,
        at: ctx.published.scheduled_at,
        state: :published,
        waiting_on: nil,
        brand: nil
      }

      html = render_component(&SocialCalendar.item_chip/1, item: item)
      assert html =~ "12.4k views"

      html = render_component(&SocialCalendar.item_chip/1, item: %{item | post: ctx.published})
      refute html =~ "views"
      refute html =~ "social-calendar-result"

      assert SocialCalendar.result_views(%{metrics: %{views: 950}}) == "950"
      assert SocialCalendar.result_views(%{metrics: %{"views" => 12_000}}) == "12k"
      assert SocialCalendar.result_views(%{metrics: %{"views" => 1_250_000}}) == "1.3M"
      assert SocialCalendar.result_views(%{metrics: %{}}) == nil
      assert SocialCalendar.result_views(%{metrics: nil}) == nil
      assert SocialCalendar.result_views(ctx.published) == nil
    end

    test "a published post is placed by published_at", %{conn: conn} = ctx do
      late =
        placed!(ctx, ctx.a, "published", at(ctx.tue, 8), %{
          published_at: at(Date.add(ctx.monday, 5), 18)
        })

      child = open(conn, ctx.h1)
      assert has_element?(child, cell(Date.add(ctx.monday, 5), 18) <> " " <> item(late))
      refute has_element?(child, cell(ctx.tue, 8) <> " " <> item(late))
    end

    test "posts of one idea on one day stack into one chip with a glyph per post",
         %{conn: conn} = ctx do
      {:ok, idea} =
        Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Launch"}, {:user, ctx.h1.id})

      wed = Date.add(ctx.monday, 2)
      one = placed!(ctx, ctx.a, "scheduled", at(wed, 11), %{idea_id: idea.id})

      two =
        placed!(ctx, ctx.d, "scheduled", DateTime.add(at(wed, 11), 20, :minute), %{
          idea_id: idea.id
        })

      child = open(conn, ctx.h1)
      group = cell(wed, 11) <> " [data-role='social-calendar-group'][data-count='2']"
      assert has_element?(child, group <> " " <> item(one))
      assert has_element?(child, group <> " " <> item(two))
      assert has_element?(child, group, "LinkedIn")
    end
  end

  describe "All brands" do
    setup ctx do
      {:ok, second} =
        Social.create_profile(ctx.org_id, %{
          name: "Second brand #{unique()}",
          space_id: ctx.space.id,
          approver_user_ids: [ctx.h1.id]
        })

      {:ok, acct} = Social.create_account(ctx.org_id, second, %{platform: "x", handle: "@second"})
      other = placed!(ctx, acct, "scheduled", at(ctx.tue, 13), %{body: "SECOND-BODY"})
      %{second: second, other: other}
    end

    test "shows two profiles' items in two colours with a legend; toggling one off hides its items",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      all_brands(child)

      assert has_element?(child, grid_item(ctx.scheduled))
      assert has_element?(child, grid_item(ctx.other))

      brands = SocialCalendar.brands([ctx.profile, ctx.second, ctx.legacy])
      colour = fn id -> Enum.find(brands, &(&1.id == id)).colour end
      cls = fn id -> colour.(id) |> String.split() |> hd() end
      assert colour.(ctx.profile.id) != colour.(ctx.second.id)

      assert has_element?(
               child,
               grid_item(ctx.scheduled) <>
                 " [data-role='social-calendar-brand'][data-brand-id='#{ctx.profile.id}'].#{cls.(ctx.profile.id)}"
             )

      assert has_element?(
               child,
               grid_item(ctx.other) <>
                 " [data-role='social-calendar-brand'][data-brand-id='#{ctx.second.id}'].#{cls.(ctx.second.id)}"
             )

      for p <- [ctx.profile, ctx.second] do
        assert has_element?(
                 child,
                 "[data-role='social-calendar-brand-toggle'][data-brand-id='#{p.id}']",
                 p.name
               )
      end

      child
      |> element("[data-role='social-calendar-brand-toggle'][data-brand-id='#{ctx.second.id}']")
      |> render_click()

      refute has_element?(child, item(ctx.other))
      assert has_element?(child, grid_item(ctx.scheduled))

      assert has_element?(
               child,
               "[data-role='social-calendar-brand-toggle'][data-brand-id='#{ctx.second.id}'][aria-pressed='false']"
             )

      child
      |> element("[data-role='social-calendar-brand-toggle'][data-brand-id='#{ctx.second.id}']")
      |> render_click()

      assert has_element?(child, grid_item(ctx.other))
    end

    test "a forged profile id in the scope is ignored", %{conn: conn} = ctx do
      foreign = approval_fixture()
      foreign_post = placed!(foreign, foreign.a, "scheduled", at(ctx.tue, 9), %{body: "FOREIGN"})

      child = open(conn, ctx.h1)
      all_brands(child)
      before = render(child)

      render_click(child, "calendar_toggle_brand", %{"id" => foreign.profile.id})
      assert render(child) == before
      refute has_element?(child, item(foreign_post))
      refute has_element?(child, "[data-brand-id='#{foreign.profile.id}']")

      render_click(child, "open_post", %{"id" => foreign_post.id})
      refute has_element?(child, "[data-role='social-post-detail']")
      refute render(child) =~ "FOREIGN"
    end

    test "the week is drawn in the browser zone the hook sends; an unknown zone stays UTC",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      all_brands(child)

      render_click(child, "calendar_zone", %{"zone" => "Mars/Olympus"})
      assert has_element?(child, "[data-role='social-week-zone'][data-zone='Etc/UTC']")

      render_click(child, "calendar_zone", %{"zone" => "Asia/Tokyo"})
      assert has_element?(child, "[data-role='social-week-zone'][data-zone='Asia/Tokyo']")
      # 10:00Z on Tuesday is 19:00 in Tokyo.
      assert has_element?(child, cell(ctx.tue, 19) <> " " <> item(ctx.scheduled), "19:00")
    end
  end

  describe "posting slots and zones (4/11 data at the Clock boundary)" do
    @denver "America/Denver"
    @slot %{id: "acct", posting_slots: [%{"weekday" => 1, "time" => "09:00"}]}

    test "a Denver 09:00 slot shades the 09:00 row in Denver time on both sides of 2026-11-01" do
      for monday <- [~D[2026-10-26], ~D[2026-11-02]] do
        slots = Clock.slots_in_week(@slot, @denver, monday, @denver)
        assert [%{date: ^monday, hour: 9, time: "09:00"}] = slots

        [row] = SocialCalendar.rows([], slots, monday)
        assert row.label == "09:00"
        assert [%{date: ^monday, slots: [_]} | rest] = row.days
        assert Enum.all?(rest, &(&1.slots == []))
      end

      # The same slot drawn in UTC moves with the clock change.
      assert [%{time: "15:00"}] = Clock.slots_in_week(@slot, @denver, ~D[2026-10-26], "Etc/UTC")
      assert [%{time: "16:00"}] = Clock.slots_in_week(@slot, @denver, ~D[2026-11-02], "Etc/UTC")
    end

    test "the week's bounds are local midnights, and zones are validated" do
      assert {from, to} = Clock.week_bounds(~D[2026-10-26], @denver)
      assert from == ~U[2026-10-26 06:00:00Z]
      assert to == ~U[2026-11-02 07:00:00Z]

      assert Clock.valid_zone("America/Denver") == "America/Denver"
      assert Clock.valid_zone("Mars/Olympus") == nil
      assert Clock.valid_zone(nil) == nil
      assert Clock.profile_zone(%{timezone: "nope"}) == "Etc/UTC"
      assert Clock.profile_zone(%{timezone: @denver}) == @denver
      assert Clock.account_slots(%{posting_slots: [%{weekday: 9, time: "09:00"}]}) == []
      assert Clock.account_slots(%{}) == []
    end

    test "with no slot data nothing is shaded", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      refute has_element?(child, "[data-role='social-slot']")
      refute has_element?(child, "[data-role='social-calendar-cell'][data-slot='true']")
    end
  end

  test "the detail is read-only; it hides a scheduled post's body from a non-approver",
       %{conn: conn} = ctx do
    child = open(conn, ctx.n)
    child |> element(grid_item(ctx.scheduled)) |> render_click()

    assert has_element?(child, "[data-role='social-post-detail']", "scheduled")
    assert has_element?(child, "[data-role='social-post-detail']", "@htc_official")
    refute has_element?(child, "[data-role='social-post-detail-body']")
    refute render(child) =~ "SCHEDULED-BODY"
    refute has_element?(child, "[data-role='social-post-detail'] form")
    refute has_element?(child, "[data-role='social-post-detail'] textarea")

    child |> element("[data-role='social-post-detail-close']") |> render_click()
    refute has_element?(child, "[data-role='social-post-detail']")
    child |> element(grid_item(ctx.published)) |> render_click()
    assert has_element?(child, "[data-role='social-post-detail-body']", "PUBLISHED-BODY")

    assert has_element?(
             child,
             "[data-role='social-post-detail-link'][href='https://example.com/p/1']",
             "View published post"
           )
  end

  test "on an owned account the owner sees a scheduled post's body; a profile approver does not",
       %{conn: conn} = ctx do
    owner = named_user!("Omar Owner")
    member!(owner, ctx.org_id)
    {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, owner.id)

    child = open(conn, owner)
    child |> element(grid_item(ctx.scheduled)) |> render_click()
    assert has_element?(child, "[data-role='social-post-detail-body']", "HTC-S1 SCHEDULED-BODY")

    child = open(Phoenix.ConnTest.build_conn(), ctx.h1)
    child |> element(grid_item(ctx.scheduled)) |> render_click()
    assert has_element?(child, "[data-role='social-post-detail']", "scheduled")
    refute has_element?(child, "[data-role='social-post-detail-body']")
  end

  test "an approver sees a scheduled post's body; a forged id from elsewhere opens nothing",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(grid_item(ctx.scheduled)) |> render_click()
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

    assert now_pub.id in Enum.map(
             Social.list_posts(ctx.org_id,
               statuses: ["published"],
               calendar_from: from,
               calendar_to: to
             ),
             & &1.id
           )
  end
end
