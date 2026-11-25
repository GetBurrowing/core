defmodule PlatformWeb.SocialCalendarChipTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures, only: [studio_post!: 4]
  alias Platform.Repo
  alias Platform.Social.{Approvals, Post}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture() |> with_ideas_runtime()

    at =
      DateTime.utc_now()
      |> DateTime.add(2, :day)
      |> DateTime.truncate(:second)
      |> Map.put(:microsecond, {0, 6})

    {post, card} = pending_post!(ctx, ctx.a, %{body: "Calendar fixture", scheduled_at: at})
    Map.merge(ctx, %{post: post, card: card, day: DateTime.to_date(at), at: at})
  end

  defp open(conn, user, day) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _} = live(conn, "/calendar?date=#{day}")
    view
  end

  test "an authorized approver sees a day chip and exact Queue link", %{conn: conn} = ctx do
    view = open(conn, ctx.h1, ctx.day)
    chip = "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    assert has_element?(view, chip, "Social · 1")
    view |> element(chip) |> render_click()

    assert has_element?(
             view,
             "[data-role='calendar-extension-list']",
             "Social posts that need you"
           )

    assert has_element?(
             view,
             "[data-role='calendar-extension-list'] a[href*='post=#{ctx.post.id}']",
             "Open in Queue"
           )

    [day] =
      Platform.Social.CalendarDayEntries.list(
        ctx.h1.id,
        DateTime.add(ctx.at, -1, :day),
        DateTime.add(ctx.at, 1, :day),
        "Etc/UTC"
      )

    [item] = day.items
    conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
    {:ok, page, _} = live(conn, item.href)
    social = find_live_child(page, "ext-page-social")
    assert has_element?(social, "[data-role='queue-versions']", "Calendar fixture")
    refute has_element?(social, "[data-role='queue-target-notice']")

    assert Fake.calls() == []
  end

  test "month day chip opens its list without navigating away", %{conn: conn} = ctx do
    conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
    {:ok, view, _} = live(conn, "/calendar?view=month&date=#{ctx.day}")

    view
    |> element(
      "[data-role='calendar-month'] [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    )
    |> render_click()

    assert has_element?(view, "[data-role='calendar-month']")

    assert has_element?(
             view,
             "[data-role='calendar-extension-list']",
             "Social posts that need you"
           )
  end

  # Phone (canvas 01a2111c): the week strip cell carries the count as a
  # marker in its accessible name, with no tap target of its own; picking the
  # date brings the agenda day up, and that day's header chip opens the list.
  test "phone strip cell shows the count; the agenda day header chip opens the dated list",
       %{conn: conn} = ctx do
    view = open(conn, ctx.h1, ctx.day)
    cell = "[data-role='calendar-day-strip'] button[data-date='#{ctx.day}']"

    assert has_element?(
             view,
             "#{cell} [data-role='calendar-extension-count'][data-date='#{ctx.day}']",
             "1"
           )

    assert has_element?(view, "#{cell}[aria-label*='1 Social item']")

    refute has_element?(
             view,
             "[data-role='calendar-day-strip'] [data-role='calendar-extension-chip']"
           )

    view |> element(cell) |> render_click()
    assert_push_event(view, "m-agenda-scroll", %{date: date})
    assert date == Date.to_iso8601(ctx.day)
    assert_phone_header_list(view, ctx)
  end

  test "the phone month picker shows the count and picking the date opens its day",
       %{conn: conn} = ctx do
    view = open(conn, ctx.h1, ctx.day)
    view |> element("[data-role='m-month-button']") |> render_click()
    cell = "[data-role='m-month'] button[data-date='#{ctx.day}']"

    assert has_element?(
             view,
             "#{cell} [data-role='calendar-extension-count'][data-date='#{ctx.day}']",
             "1"
           )

    assert has_element?(view, "#{cell}[aria-label*='1 Social item']")

    view |> element(cell) |> render_click()
    refute has_element?(view, "[data-role='m-month']")
    assert_push_event(view, "m-agenda-scroll", %{date: date})
    assert date == Date.to_iso8601(ctx.day)
    assert_phone_header_list(view, ctx)
  end

  test "phone: permission revoked after render shows no Social items on pick or chip",
       %{conn: conn} = ctx do
    view = open(conn, ctx.h1, ctx.day)
    header_chip = phone_header_chip(ctx)
    assert has_element?(view, header_chip)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    view |> element(header_chip) |> render_click()
    refute has_element?(view, "[data-role='calendar-extension-list']")
    refute has_element?(view, "[data-role='calendar-extension-chip']")
    refute has_element?(view, "[data-role='calendar-extension-count']")

    view
    |> element("[data-role='calendar-day-strip'] button[data-date='#{ctx.day}']")
    |> render_click()

    refute has_element?(view, "[data-role='calendar-extension-chip']")
    refute has_element?(view, "[data-role='calendar-extension-count']")
    refute has_element?(view, "[data-role='calendar-extension-list']")
  end

  defp phone_header_chip(ctx),
    do:
      "#m-agenda [data-role='m-agenda-day-header'] " <>
        "[data-role='calendar-extension-chip'][data-date='#{ctx.day}']"

  # The day header chip on the agenda opens the dated list with the post's
  # exact Queue link, and Escape closes it.
  defp assert_phone_header_list(view, ctx) do
    chip = phone_header_chip(ctx)
    assert has_element?(view, chip, "Social · 1")
    view |> element(chip) |> render_click()

    assert has_element?(
             view,
             "[data-role='calendar-extension-list']",
             Calendar.strftime(ctx.day, "%a %-d %b")
           )

    assert has_element?(
             view,
             "[data-role='calendar-extension-list'] a[href*='post=#{ctx.post.id}']"
           )

    render_keydown(view, "escape", %{"key" => "Escape"})
    refute has_element?(view, "[data-role='calendar-extension-list']")
  end

  test "posts on the same day share a count and retain separate links", %{conn: conn} = ctx do
    {other, _} = pending_post!(ctx, ctx.a, %{body: "Another post", scheduled_at: ctx.at})
    view = open(conn, ctx.h1, ctx.day)
    chip = "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    assert has_element?(view, chip, "Social · 2")
    view |> element(chip) |> render_click()

    assert has_element?(
             view,
             "[data-role='calendar-extension-list'] a[href*='post=#{ctx.post.id}']"
           )

    assert has_element?(view, "[data-role='calendar-extension-list'] a[href*='post=#{other.id}']")
  end

  test "project denial prevents even the count", %{conn: conn} = ctx do
    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "a reader without the action authority sees no count", %{conn: conn} = ctx do
    view = open(conn, ctx.n, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "a reject-only approver gets the actionable chip and exact Queue action",
       %{conn: conn} = ctx do
    owner = named_user!("Former owner") |> member!(ctx.org_id)
    {:ok, account} = Platform.Social.set_account_owner(ctx.org_id, ctx.a, owner.id)
    {:ok, _} = Platform.Accounts.archive_user(owner)

    assert {:error, _} =
             Platform.Social.post_approver_check(ctx.org_id, ctx.profile, account, ctx.h1.id)

    assert :ok = Platform.Social.post_rejecter_check(ctx.org_id, ctx.profile, account, ctx.h1.id)
    view = open(conn, ctx.h1, ctx.day)
    chip = "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    assert has_element?(view, chip, "Social · 1")
    view |> element(chip) |> render_click()

    assert has_element?(
             view,
             "[data-role='calendar-extension-list'] a[href*='post=#{ctx.post.id}']"
           )

    [day] =
      Platform.Social.CalendarDayEntries.list(
        ctx.h1.id,
        DateTime.add(ctx.at, -1, :day),
        DateTime.add(ctx.at, 1, :day),
        "Etc/UTC"
      )

    [item] = day.items
    conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
    {:ok, page, _} = live(conn, item.href)
    social = find_live_child(page, "ext-page-social")
    assert has_element?(social, "[data-role='queue-reject'][phx-value-post-id='#{ctx.post.id}']")
  end

  test "a profile without a live project has no count", %{conn: conn} = ctx do
    Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^ctx.profile.id),
      set: [project_id: nil]
    )

    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "dated Studio posts do not enter the legacy Queue chip", %{conn: conn} = ctx do
    {:ok, _} = Platform.Social.Studio.set_enabled(ctx.org_id, ctx.profile.id, ctx.h1.id, true)
    world = %{org_id: ctx.org_id, approver: ctx.h1}
    pending = studio_post!(world, ctx.a, "needs_approval", %{body: "Studio review"})
    planned = studio_post!(world, ctx.a, "planned", %{body: "Studio plan"})

    # Deliberate fixture-only state: normal Studio review writers leave this undated.
    Repo.update_all(from(p in Post, where: p.id in ^[pending.id, planned.id]),
      set: [scheduled_at: ctx.at]
    )

    assert Repo.get!(Post, pending.id).scheduled_at == ctx.at
    assert Repo.get!(Post, planned.id).scheduled_at == ctx.at

    queue_ids =
      ctx.h1
      |> Platform.Social.QueueFeed.needs_you({:profile, ctx.profile})
      |> Enum.flat_map(&Enum.map(&1.posts, fn post -> post.id end))

    assert ctx.post.id in queue_ids
    refute pending.id in queue_ids
    view = open(conn, ctx.h1, ctx.day)
    chip = "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    assert has_element?(view, chip, "Social · 1")
    view |> element(chip) |> render_click()
    refute has_element?(view, "[data-role='calendar-extension-list']", "Studio review")
    refute has_element?(view, "[data-role='calendar-extension-list']", "Studio plan")
  end

  test "the day and time follow the calendar viewer's zone", ctx do
    at = ~U[2099-01-02 02:30:00.000000Z]
    Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id), set: [scheduled_at: at])

    [day] =
      Platform.Social.CalendarDayEntries.list(
        ctx.h1.id,
        ~U[2099-01-01 00:00:00Z],
        ~U[2099-01-03 00:00:00Z],
        "America/New_York"
      )

    assert day.day == ~D[2099-01-01]
    assert hd(day.items).text =~ "21:30"
  end

  test "the requested time window includes its start and excludes its end", ctx do
    before = DateTime.add(ctx.at, -1, :second)
    after_window = DateTime.add(ctx.at, 3600, :second)
    {earlier, _} = pending_post!(ctx, ctx.a, %{scheduled_at: before})
    {later, _} = pending_post!(ctx, ctx.a, %{scheduled_at: after_window})

    assert [day] =
             Platform.Social.CalendarDayEntries.list(ctx.h1.id, ctx.at, after_window, "Etc/UTC")

    assert [item] = day.items
    assert item.href =~ "post=#{ctx.post.id}"
    refute item.href =~ "post=#{earlier.id}"
    refute item.href =~ "post=#{later.id}"
  end

  test "a refused post with only a read-only exact destination is excluded",
       %{conn: conn} = ctx do
    assert {:ok, _} =
             Approvals.decide_approve(ctx.card.canvas_id, ctx.h1, Approvals.fingerprint(ctx.post))

    Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
      set: [
        status: "approved",
        refused_reason: "media_rejected",
        refused_at: DateTime.utc_now(),
        error: "Try another image"
      ]
    )

    assert [] ==
             Platform.Social.CalendarDayEntries.list(
               ctx.h1.id,
               DateTime.add(ctx.at, -1, :day),
               DateTime.add(ctx.at, 1, :day),
               "Etc/UTC"
             )

    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "a failed clip with only a read-only exact destination is excluded",
       %{conn: conn} = ctx do
    {:ok, clip} =
      Platform.Social.create_clip(ctx.org_id, ctx.profile, %{
        source_url: "https://www.youtube.com/watch?v=abc",
        start_s: 1.0,
        end_s: 2.0
      })

    Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
      set: [
        status: "failed",
        clip_id: clip.id,
        error: "Vendor refused",
        approved_by_user_id: ctx.h1.id,
        approved_at: DateTime.utc_now()
      ]
    )

    assert [] ==
             Platform.Social.CalendarDayEntries.list(
               ctx.h1.id,
               DateTime.add(ctx.at, -1, :day),
               DateTime.add(ctx.at, 1, :day),
               "Etc/UTC"
             )

    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "non-clip failure, cancelled clip and a rate-limited refusal are all excluded",
       %{conn: conn} = ctx do
    {:ok, clip} =
      Platform.Social.create_clip(ctx.org_id, ctx.profile, %{
        source_url: "https://www.youtube.com/watch?v=abc",
        start_s: 1.0,
        end_s: 2.0
      })

    for attrs <- [
          [status: "failed", clip_id: nil, error: "Failed"],
          [status: "failed", clip_id: clip.id, error: "cancelled before publishing"],
          [
            status: "approved",
            clip_id: nil,
            refused_reason: "rate_limited",
            refused_at: DateTime.utc_now(),
            retry_after: DateTime.add(DateTime.utc_now(), 3600, :second)
          ]
        ] do
      Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
        set: attrs ++ [approved_by_user_id: ctx.h1.id, approved_at: DateTime.utc_now()]
      )

      view = open(conn, ctx.h1, ctx.day)
      refute has_element?(view, "[data-role='calendar-extension-chip']")
    end
  end

  test "permission revoked after render is checked again before opening the list",
       %{conn: conn} = ctx do
    view = open(conn, ctx.h1, ctx.day)
    chip = "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']"
    assert has_element?(view, chip)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    view |> element(chip) |> render_click()
    refute has_element?(view, "[data-role='calendar-extension-chip']")
    refute has_element?(view, "[data-role='calendar-extension-list']")
  end

  test "no profile and no extension both produce no chip", %{conn: conn} = ctx do
    outsider_org = org_id!()
    outsider = member!(user!(), outsider_org)
    view = open(conn, outsider, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")

    previous = Application.get_env(:platform, :extensions)
    on_exit(fn -> Application.put_env(:platform, :extensions, previous) end)
    Application.put_env(:platform, :extensions, [])
    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "untimed posts and published posts do not affect the count", %{conn: conn} = ctx do
    # A pending card retained from before completeness checks required a time.
    {untimed, _} = pending_post!(ctx, ctx.a, %{body: "Untimed", scheduled_at: ctx.at})
    Repo.update!(Ecto.Changeset.change(untimed, scheduled_at: nil))
    {published, _} = pending_post!(ctx, ctx.a, %{body: "Already published", scheduled_at: ctx.at})

    Repo.update_all(from(p in Post, where: p.id == ^published.id),
      set: [status: "published", approved_by_user_id: ctx.h1.id, approved_at: DateTime.utc_now()]
    )

    view = open(conn, ctx.h1, ctx.day)

    assert has_element?(
             view,
             "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']",
             "Social · 1"
           )
  end

  test "a visible Social post does not enter agent reads, feeds, list entries or booking", ctx do
    owner = Platform.Access.Scope.for_user(ctx.h1)
    runtime = Repo.get_by!(Platform.Agents.AgentRuntime, agent_id: ctx.g.id)
    agent_scope = Platform.Access.Scope.for_runtime(runtime)

    {:ok, _} =
      Platform.Calendar.AgentAccess.grant(owner, ctx.g.id, %{read: true, read_private: true})

    at = DateTime.new!(ctx.day, ~T[10:00:00], "Etc/UTC")
    Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id), set: [scheduled_at: at])
    from = DateTime.add(at, -1, :day)
    to = DateTime.add(at, 1, :day)

    attrs = %{
      title: "Office hours",
      time_zone: "Etc/UTC",
      duration_minutes: 30,
      start_date: ctx.day,
      end_date: ctx.day,
      windows: [%{"weekday" => Date.day_of_week(ctx.day), "start" => "09:00", "end" => "12:00"}]
    }

    {:ok, link} = Platform.Calendar.BookingLinks.create(owner, attrs)

    assert [%{items: [_]}] =
             Platform.Social.CalendarDayEntries.list(ctx.h1.id, from, to, "Etc/UTC")

    entries_before = Platform.Calendar.list_entries(owner, from, to)
    feed_before = Platform.Calendar.Feed.render(owner)
    {:ok, agent_before} = Platform.Calendar.AgentAccess.read(agent_scope, ctx.h1.id, from, to)
    {:ok, slots_before} = Platform.Calendar.BookingLinks.preview(owner, link.id, ctx.day, 1)
    assert Enum.any?(slots_before, &(DateTime.compare(&1.starts_at, at) == :eq))

    Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
      set: [status: "approved", approved_by_user_id: ctx.h1.id, approved_at: DateTime.utc_now()]
    )

    assert entries_before == Platform.Calendar.list_entries(owner, from, to)
    assert feed_before == Platform.Calendar.Feed.render(owner)

    assert {:ok, ^agent_before} =
             Platform.Calendar.AgentAccess.read(agent_scope, ctx.h1.id, from, to)

    assert {:ok, ^slots_before} =
             Platform.Calendar.BookingLinks.preview(owner, link.id, ctx.day, 1)

    refute feed_before =~ "Calendar fixture"
  end

  test "approving removes the item from a fresh page", %{conn: conn} = ctx do
    before = open(conn, ctx.h1, ctx.day)

    assert has_element?(
             before,
             "#calendar-week [data-role='calendar-extension-chip'][data-date='#{ctx.day}']",
             "Social · 1"
           )

    assert {:ok, _} =
             Approvals.decide_approve(ctx.card.canvas_id, ctx.h1, Approvals.fingerprint(ctx.post))

    assert Repo.get!(Post, ctx.post.id).status in ["approved", "scheduled"]
    view = open(conn, ctx.h1, ctx.day)
    refute has_element?(view, "[data-role='calendar-extension-chip']")
  end

  test "approved-waiting and scheduled posts are both excluded", %{conn: conn} = ctx do
    for status <- ["approved", "scheduled"] do
      Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
        set: [status: status, approved_by_user_id: ctx.h1.id, approved_at: DateTime.utc_now()]
      )

      view = open(conn, ctx.h1, ctx.day)
      refute has_element?(view, "[data-role='calendar-extension-chip']")
    end
  end
end
