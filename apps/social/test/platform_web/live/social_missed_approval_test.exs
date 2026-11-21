defmodule PlatformWeb.SocialMissedApprovalTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures
  alias Platform.Repo
  alias Platform.Social.{ApprovalCard, Approvals, Post, Profile, RateLimit}
  alias Platform.Social.Publisher.Fake
  alias PlatformWeb.SocialCalendar

  setup do
    Fake.reset()
    RateLimit.reset()
    approval_fixture()
  end

  defp open(conn, ctx, tab) do
    conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
    {:ok, parent, _} = live(conn, "/m/social?tab=#{tab}&profile=#{ctx.profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  test "a cached Calendar item derives its missed state again when rendered", ctx do
    at = DateTime.add(DateTime.utc_now(), -60)
    {post, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: at})

    html =
      render_component(&SocialCalendar.item_chip/1,
        item: %{
          post: post,
          account: ctx.a,
          at: at,
          state: :waiting,
          waiting_on: "Waiting on you",
          brand: nil
        }
      )

    assert html =~ ~s(data-state="missed")
    assert html =~ "Missed: not approved in time"
    refute html =~ "Waiting on you"
  end

  test "Calendar retains a missed approval with a distinct accessible label and its original slot",
       %{conn: conn} = ctx do
    at = DateTime.add(DateTime.utc_now(), -60)
    {post, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: at})
    view = open(conn, ctx, "calendar")

    if SocialCalendar.week_start(DateTime.to_date(at)) !=
         SocialCalendar.week_start(Date.utc_today()) do
      view |> element("[phx-click='week_prev']") |> render_click()
    end

    assert has_element?(
             view,
             "[data-role='social-calendar-item'][data-post-id='#{post.id}'][data-state='missed']",
             "Missed: not approved in time"
           )

    assert render(view) =~ "It was not posted. Choose a new time to approve it."
    assert Repo.get!(Post, post.id).scheduled_at == post.scheduled_at
    assert Fake.calls(:publish) == []
  end

  test "Queue shows the miss and a human future-time control even without posting slots",
       %{conn: conn} = ctx do
    {post, _card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})

    view = open(conn, ctx, "queue")

    assert has_element?(
             view,
             "#queue-#{post.id} [data-role='approval-missed']",
             "Missed: not approved in time. It was not posted."
           )

    refute has_element?(view, "#queue-#{post.id} [data-role='queue-approve']")

    assert has_element?(
             view,
             "#queue-approve-time-#{post.id} input[name='at'][type='datetime-local']"
           )

    assert has_element?(view, "#queue-approve-time-#{post.id}", "New time (UTC)")

    assert has_element?(
             view,
             "[data-role='queue-phone-bar'][data-post='#{post.id}'] [data-role='queue-bar-missed']",
             "Missed: not approved in time"
           )

    assert has_element?(view, "#queue-#{post.id} [data-role='queue-suggested']")
    refute has_element?(view, "#queue-#{post.id} [data-role='queue-approval-consequence']")

    refute has_element?(
             view,
             "[data-role='queue-phone-bar'][data-post='#{post.id}'] [data-role='queue-phone-consequence']"
           )

    # Responsive class contract only; the browser check proves readability.
    html = render(view) |> LazyHTML.from_fragment()

    [classes] =
      html |> LazyHTML.query("#queue-approve-time-#{post.id}") |> LazyHTML.attribute("class")

    assert "flex-col" in String.split(classes)

    [classes] =
      html
      |> LazyHTML.query("#queue-approve-time-#{post.id} label")
      |> LazyHTML.attribute("class")

    assert "w-full" in String.split(classes)

    at = DateTime.add(DateTime.utc_now(), 86400) |> DateTime.truncate(:second)
    value = Calendar.strftime(at, "%Y-%m-%dT%H:%M:%S")
    view |> form("#queue-approve-time-#{post.id}", %{at: value}) |> render_submit()
    updated = Repo.get!(Post, post.id)
    assert DateTime.compare(updated.scheduled_at, at) == :eq
    assert length(Fake.calls(:publish)) == 1
  end

  test "a non-approver sees no replacement-time action", %{conn: conn} = ctx do
    {post, _card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})

    conn = Plug.Test.init_test_session(conn, current_user_id: ctx.n.id)
    {:ok, parent, _} = live(conn, "/m/social?tab=queue&profile=#{ctx.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    refute has_element?(view, "#queue-approve-time-#{post.id}")
    assert Fake.calls(:publish) == []
  end

  test "a future timed post does not show a missed line on its phone bar", %{conn: conn} = ctx do
    {post, _card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), 7200)})

    view = open(conn, ctx, "queue")
    bar = "[data-role='queue-phone-bar'][data-post='#{post.id}']"

    assert has_element?(view, bar)
    assert has_element?(view, "#{bar} [data-role='queue-bar-approve']")

    assert has_element?(
             view,
             "#{bar} [data-role='queue-phone-consequence']",
             "Approval submits to the connected account immediately if no future time is set."
           )

    assert has_element?(view, "#queue-#{post.id} [data-role='queue-approval-consequence']")
    refute has_element?(view, "#{bar} [data-role='queue-bar-missed']")
    refute has_element?(view, "#queue-#{post.id} [data-role='approval-missed']")
    assert Fake.calls(:publish) == []
  end

  test "chat approval card describes the miss without a direct late approve control", ctx do
    {post, card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})

    html =
      render_component(PlatformWeb.SocialCardComponent,
        id: "deadline-card",
        card_id: card.id,
        canvas_id: card.canvas_id,
        rev: 1,
        viewer: {:user, ctx.h1.id}
      )

    assert html =~ "Missed: not approved in time. It was not posted."
    refute html =~ "data-role=\"social-card-approve\""
    assert html =~ "Choose a new time in Queue"
    assert Repo.get!(ApprovalCard, card.id).state == "pending"
    assert post.status == "needs_approval"
  end

  test "invalid or past replacement times do not decide or publish", %{conn: conn} = ctx do
    {post, card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})

    view = open(conn, ctx, "queue")

    for value <- ["not-a-time", "2020-01-01T00:00:00", "2099-01-01T12:00:00+02:00"] do
      view |> form("#queue-approve-time-#{post.id}", %{at: value}) |> render_submit()
      assert Repo.get!(Post, post.id).scheduled_at == post.scheduled_at
      assert Repo.get!(ApprovalCard, card.id).state == "pending"
      assert Fake.calls(:publish) == []
    end
  end

  test "a replacement-time submission rechecks revoked approval authority", %{conn: conn} = ctx do
    {post, card} =
      pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})

    view = open(conn, ctx, "queue")
    profile = Repo.get!(Profile, ctx.profile.id)

    {:ok, _} =
      Platform.Social.update_profile(ctx.org_id, profile, %{approver_user_ids: [ctx.h2.id]})

    at = Calendar.strftime(DateTime.add(DateTime.utc_now(), 86400), "%Y-%m-%dT%H:%M:%S")
    view |> form("#queue-approve-time-#{post.id}", %{at: at}) |> render_submit()
    assert Repo.get!(ApprovalCard, card.id).state == "pending"
    assert Repo.get!(Post, post.id).scheduled_at == post.scheduled_at
    assert Fake.calls(:publish) == []
  end

  for surface <- [:queue, :calendar, :chat] do
    @surface surface
    test "a stale #{@surface} approval control is refused after its deadline",
         %{conn: conn} = ctx do
      at = DateTime.add(DateTime.utc_now(), 4)
      {post, card} = pending_post!(ctx, ctx.a, %{scheduled_at: at})

      {view, target, event, params} =
        case @surface do
          :queue ->
            view = open(conn, ctx, "queue")
            assert has_element?(view, "#queue-#{post.id} [data-role='queue-approve']")

            [id] =
              render(view)
              |> LazyHTML.from_fragment()
              |> LazyHTML.query("[data-role='queue-idea']")
              |> LazyHTML.attribute("id")

            {view, "##{id}", "q_approve",
             %{"post-id" => post.id, "fingerprint" => Approvals.fingerprint(post)}}

          :calendar ->
            view = open(conn, ctx, "calendar")

            if SocialCalendar.week_start(DateTime.to_date(at)) !=
                 SocialCalendar.week_start(Date.utc_today()),
               do: view |> element("[phx-click='week_next']") |> render_click()

            view |> element("#social-calendar-rows [data-post-id='#{post.id}']") |> render_click()
            assert has_element?(view, "[data-role='social-calendar-approve']")

            {view, nil, "calendar_approve",
             %{"id" => post.id, "fingerprint" => Approvals.fingerprint(post)}}

          :chat ->
            conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
            {:ok, view, _} = live(conn, "/chat/#{ctx.space.id}", on_error: :warn)
            render_hook(view, "inline_canvas_mount", %{"message_id" => card.message_id})
            assert has_element?(view, "[data-role='social-card-approve']")

            [id] =
              render(view)
              |> LazyHTML.from_fragment()
              |> LazyHTML.query("[data-role='social-card']")
              |> LazyHTML.attribute("id")

            {view, "##{id}", "social_card_approve",
             %{"canvas-id" => card.canvas_id, "fingerprint" => Approvals.fingerprint(post)}}
        end

      assert DateTime.compare(DateTime.utc_now(), at) == :lt
      await_deadline!(at, 600)
      html = render_click(if(target, do: with_target(view, target), else: view), event, params)
      assert html |> LazyHTML.from_fragment() |> LazyHTML.text() =~ "This post's time has passed"
      assert html =~ "Missed: not approved in time"

      if @surface == :calendar do
        assert has_element?(view, "[data-role='social-post-detail'] [data-state='missed']")

        assert has_element?(
                 view,
                 "[data-role='social-post-detail'] [data-role='calendar-approval-notice'][role='alert']",
                 "This post's time has passed, so it was not approved. Choose a new time first."
               )

        assert has_element?(
                 view,
                 "[data-role='social-post-detail'] [data-role='social-post-detail-reason']",
                 "It was not posted. Choose a new time to approve it."
               )

        render_click(view, "select_tab", %{"tab" => "not-a-tab"})
        assert has_element?(view, "[data-role='calendar-approval-notice']")
        render_click(view, "select_tab", %{"tab" => "connections"})
        refute has_element?(view, "[data-role='social-post-detail']")
        refute has_element?(view, "[data-role='social-notice']", "This post's time has passed")
        render_click(view, "select_tab", %{"tab" => "calendar"})
        view |> element("#social-calendar-rows [data-post-id='#{post.id}']") |> render_click()
        refute has_element?(view, "[data-role='calendar-approval-notice']")
        assert has_element?(view, "[data-role='social-post-detail-reason']")
        view |> element("[data-role='social-post-detail-close']") |> render_click()
        refute has_element?(view, "[data-role='social-post-detail']")
      end

      assert Repo.get!(ApprovalCard, card.id).state == "pending"
      assert Repo.get!(Post, post.id).approved_at == nil
      assert Fake.calls(:publish) == []
    end
  end

  defp await_deadline!(_at, 0), do: flunk("deadline did not pass in bounded wait")

  defp await_deadline!(at, attempts) do
    if DateTime.compare(DateTime.utc_now(), at) == :lt do
      Process.sleep(10)
      await_deadline!(at, attempts - 1)
    else
      :ok
    end
  end
end
