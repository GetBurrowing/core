defmodule PlatformWeb.SocialLiveQueueTest do
  @moduledoc """
  The Queue, "Needs you" (Social authoring 5/11, task 01a16c50): one card
  per idea (`PlatformWeb.SocialIdeaCard`) with every account's real preview,
  the suggested time and its reason, and approve / next slot / edit /
  revise / reject / approve all, each through `Approvals.decide_*` or
  `Ideas.request_revision/4`. Below the cards: clips waiting, Scheduled,
  Failed and refused, and Published. One describe per Done-means item.

  Agent drafts arrive through `ToolArguments.dispatch/3`, the door both
  federation transports use. `async: false`: the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, ApprovalCard, NextSlot, Post, PostEvent, RateLimit}
  alias Platform.Social.Publisher.Fake

  @stale "The post changed since you opened it; read the new text and decide again."

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture() |> with_ideas_runtime()

    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@show_x"})

    {:ok, ig} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram", handle: "@show_ig"})

    Map.merge(ctx, %{x: x, ig: ig})
  end

  test "exact post link selects the second platform version rather than version zero",
       %{conn: conn} = ctx do
    {idea, [_first, second | _]} = three!(ctx)

    child =
      open(
        conn,
        ctx.n,
        Platform.Social.PostPresentation.url(second, ctx.profile, {:user, ctx.n.id})
      )

    assert has_element?(child, "[data-role='queue-versions'][data-current='1']")
    assert has_element?(child, "[data-role='queue-title']", idea.title)

    child
    |> element("#queue-card-idea-#{idea.id}-strip")
    |> render_hook("q_version", %{"index" => 0})

    assert has_element?(child, "[data-role='queue-versions'][data-current='0']")
    render_click(child, "select_tab", %{"tab" => "queue"})
    assert has_element?(child, "[data-role='queue-versions'][data-current='0']")
    assert Fake.calls(:publish) == []
  end

  test "authorized rejected and untimed posts have explicit detail instead of unrelated Queue",
       %{conn: conn} = ctx do
    pending_post!(ctx, ctx.x, %{body: "Another waiting post"})
    {post, card} = pending_post!(ctx, ctx.a, %{body: "A draft outside Queue"})

    assert {:ok, _} =
             Approvals.decide_reject(
               card.canvas_id,
               ctx.h1,
               "Please revise",
               Approvals.fingerprint(post)
             )

    child =
      open(
        conn,
        ctx.h1,
        Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id})
      )

    assert has_element?(child, "[data-role='queue-target-notice']", "no longer awaiting approval")
    assert has_element?(child, "[data-role='queue-target-details']", "A draft outside Queue")
    refute has_element?(child, "[data-role='queue-target-details'] button")
    refute has_element?(child, "#social-queue [data-role='queue-idea']")
    assert has_element?(child, "[data-role='queue-browse']")
    assert Fake.calls(:publish) == []
  end

  test "missing and forbidden post links give the same useful unavailable feedback",
       %{conn: conn} = ctx do
    {_idea, [post | _]} = three!(ctx)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    for id <- [post.id, Platform.Types.UUIDv7.generate(), "bad-id"] do
      child = open(conn, ctx.n, "/m/social?profile=#{ctx.profile.id}&tab=queue&post=#{id}")

      assert has_element?(
               child,
               "[data-role='queue-target-notice']",
               "This post is unavailable or you no longer have access."
             )

      refute has_element?(child, "[data-role='queue-target-details']")
      refute has_element?(child, "[data-role='queue-idea']")
    end
  end

  test "a forged profile/post pair is unavailable even when both brands are visible",
       %{conn: conn} = ctx do
    {:ok, other} = Social.create_profile(ctx.org_id, %{name: "Other brand"})
    {post, _} = pending_post!(ctx, ctx.a)

    for profile_id <- [other.id, Platform.Types.UUIDv7.generate()] do
      child = open(conn, ctx.n, "/m/social?profile=#{profile_id}&tab=queue&post=#{post.id}")

      assert has_element?(
               child,
               "[data-role='queue-target-notice']",
               "This post is unavailable or you no longer have access."
             )

      refute has_element?(child, "[data-role='queue-target-details']")
    end
  end

  test "a rendered fallback loses caption access after revocation and a page refresh event",
       %{conn: conn} = ctx do
    {:ok, post} = Social.create_post(ctx.org_id, ctx.a, %{body: "Revocable fallback caption"})

    child =
      open(
        conn,
        ctx.n,
        Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id})
      )

    assert has_element?(child, "[data-role='queue-target-details']", "Revocable fallback caption")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    render_click(child, "select_tab", %{"tab" => "connections"})
    render_click(child, "select_tab", %{"tab" => "queue"})
    refute has_element?(child, "[data-role='queue-target-details']")

    assert has_element?(
             child,
             "[data-role='queue-target-notice']",
             "This post is unavailable or you no longer have access."
           )

    assert Fake.calls(:publish) == []
  end

  test "an exact post landing does not trap Next on its original group", %{conn: conn} = ctx do
    {first, [post | _]} = three!(ctx)
    {second, _} = three!(ctx)

    child =
      open(
        conn,
        ctx.n,
        Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id})
      )

    assert has_element?(
             child,
             "[data-role='queue-idea'][data-idea='#{first.id}'][data-focused='true']"
           )

    render_click(child, "queue_focus", %{"dir" => "next"})

    assert has_element?(
             child,
             "[data-role='queue-idea'][data-idea='#{second.id}'][data-focused='true']"
           )
  end

  test "cold HTTP render never includes the caption for a denied exact target",
       %{conn: conn} = ctx do
    {post, _} = pending_post!(ctx, ctx.a, %{body: "EXACT-TARGET-PRIVATE-CAPTION"})

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    html =
      conn
      |> Plug.Test.init_test_session(current_user_id: ctx.n.id)
      |> get(Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id}))
      |> html_response(200)

    assert html =~ "This post is unavailable or you no longer have access."
    refute html =~ "EXACT-TARGET-PRIVATE-CAPTION"
  end

  test "authorized missing and mismatched exact targets are empty on cold and connected loads",
       %{conn: conn} = ctx do
    {_idea, [post | _]} = three!(ctx)

    for {id, profile_id} <- [
          {Ecto.UUID.generate(), ctx.profile.id},
          {post.id, Ecto.UUID.generate()}
        ] do
      path = "/m/social?profile=#{profile_id}&tab=queue&post=#{id}"
      child = open(conn, ctx.h1, path)

      assert has_element?(
               child,
               "[data-role='queue-target-notice']",
               "This post is unavailable or you no longer have access."
             )

      refute has_element?(child, "[data-role='social-queue-row']")
      refute has_element?(child, "[data-role='queue-idea']")
      refute has_element?(child, "[data-role='social-queue-pane'] [data-role='social-empty']")

      assert has_element?(
               child,
               "[data-role='queue-browse'][href='/m/social?profile=#{profile_id}&tab=queue']"
             )

      html =
        conn
        |> Plug.Test.init_test_session(current_user_id: ctx.h1.id)
        |> get(path)
        |> html_response(200)

      assert html =~ "This post is unavailable or you no longer have access."
      refute html =~ "data-role=\"social-queue-row\""
      refute html =~ "data-role=\"queue-idea\""
      refute html =~ "Nothing is awaiting approval."
    end
  end

  test "component events refresh title authority without a page reload", %{conn: conn} = ctx do
    {post, _} = pending_post!(ctx, ctx.a, %{body: "CURRENT-READ-TITLE"})

    child =
      open(
        conn,
        ctx.n,
        Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.n.id})
      )

    assert has_element?(child, "[data-role='queue-title']", "CURRENT-READ-TITLE")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    child
    |> with_target("#queue-card-idea-#{post.id}")
    |> render_click("q_version", %{"index" => "0"})

    refute has_element?(child, "[data-role='queue-title']", "CURRENT-READ-TITLE")
    assert has_element?(child, "[data-role='queue-target-unavailable']")
  end

  test "scheduled lone-post title is gated for authorized, denied and project-less readers",
       %{conn: conn} = ctx do
    {:ok, post} = Social.create_post(ctx.org_id, ctx.a, %{body: "SCHEDULED-PRIVATE-TITLE"})

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set: [
        status: "scheduled",
        approved_by_user_id: ctx.h1.id,
        approved_at: DateTime.utc_now(),
        scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
      ]
    )

    path = "/m/social?profile=#{ctx.profile.id}&tab=queue"
    child = open(conn, ctx.n, path)
    assert has_element?(child, "#queue-scheduled-#{post.id}", "SCHEDULED-PRIVATE-TITLE")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    child = open(conn, ctx.n, path)
    assert has_element?(child, "#queue-scheduled-#{post.id}", "LinkedIn post")

    refute child |> element("#queue-scheduled-#{post.id}") |> render() =~
             "SCHEDULED-PRIVATE-TITLE"

    Repo.update!(Ecto.Changeset.change(ctx.profile, project_id: nil))
    child = open(conn, ctx.h2, path)
    assert has_element?(child, "#queue-scheduled-#{post.id}", "LinkedIn post")

    refute child |> element("#queue-scheduled-#{post.id}") |> render() =~
             "SCHEDULED-PRIVATE-TITLE"
  end

  test "a Studio post never becomes a legacy exact target", %{conn: conn} do
    w = Platform.SocialStudioFixtures.studio_world!()

    post =
      Platform.SocialStudioFixtures.studio_post!(w, w.tiktok, "draft", %{
        body: "Studio target private text"
      })

    child = open(conn, w.approver, "/m/social?profile=#{w.profile.id}&tab=queue&post=#{post.id}")

    assert has_element?(
             child,
             "[data-role='queue-target-notice']",
             "This post is unavailable or you no longer have access."
           )

    refute has_element?(child, "[data-role='queue-target-details']")
  end

  test "forged approve and malformed version events cannot change a read-only exact detail",
       %{conn: conn} = ctx do
    {:ok, post} = Social.create_post(ctx.org_id, ctx.a, %{body: "Read-only detail"})

    child =
      open(
        conn,
        ctx.h1,
        Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id})
      )

    target = with_target(child, "#notification-post-#{post.id}")
    before = Repo.get!(Post, post.id)
    before_events = Repo.aggregate(from(e in PostEvent, where: e.post_id == ^post.id), :count)

    render_click(target, "q_approve", %{
      "post-id" => post.id,
      "fingerprint" => Approvals.fingerprint(post)
    })

    refute has_element?(child, "#notification-post-#{post.id} [data-role='queue-notice']")
    render_click(target, "q_version", %{"index" => "not-a-version"})
    refute has_element?(child, "#notification-post-#{post.id} [data-role='queue-notice']")
    assert Repo.get!(Post, post.id) == before

    assert Repo.aggregate(from(e in PostEvent, where: e.post_id == ^post.id), :count) ==
             before_events

    assert has_element?(
             child,
             "#notification-post-#{post.id} [data-role='queue-versions'][data-current='0']"
           )

    assert Fake.calls(:publish) == []
  end

  test "Calendar chooses exact or legacy link using the clicking viewer read authority",
       %{conn: conn} = ctx do
    {post, _} = pending_post!(ctx, ctx.a, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)})
    path = "/m/social?profile=#{ctx.profile.id}&tab=calendar"
    allowed = open(conn, ctx.h2, path)
    render_click(allowed, "open_post", %{"id" => post.id})
    assert has_element?(allowed, "a[data-role='calendar-choose-time'][href*='post=']")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    denied = open(conn, ctx.h1, path)
    render_click(denied, "open_post", %{"id" => post.id})
    assert has_element?(denied, "a[data-role='calendar-choose-time']")
    refute has_element?(denied, "a[data-role='calendar-choose-time'][href*='post=']")
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp call(tool, args, agent_ctx), do: ToolArguments.dispatch(tool, args, agent_ctx)

  defp idea!(ctx, title) do
    {:ok, %{idea: idea}} =
      call(
        "social_idea_create",
        %{"profile_id" => ctx.profile.id, "title" => title, "brief" => "Announce it"},
        ctx.agent_ctx
      )

    idea
  end

  # The agent drafts one post per account under `idea`, waiting for a human.
  defp drafts!(ctx, idea, accounts, attrs \\ %{}) do
    {:ok, %{posts: posts}} =
      call(
        "social_draft_create",
        Map.merge(
          %{
            "profile_id" => ctx.profile.id,
            "idea_id" => idea.id,
            "account_ids" => Enum.map(accounts, & &1.id),
            "body" => "Episode 12 is out"
          },
          attrs
        ),
        ctx.agent_ctx
      )

    Enum.map(posts, &Repo.get!(Post, &1.id))
  end

  defp three!(ctx, attrs \\ %{}) do
    idea = idea!(ctx, "Episode 12 launch")
    {idea, drafts!(ctx, idea, [ctx.a, ctx.x, ctx.ig], attrs)}
  end

  defp open(conn, user, path \\ "/m/social") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, path)
    find_live_child(view, "ext-page-social")
  end

  defp card(key), do: "#queue-card-idea-#{key}"
  defp v(post), do: "#queue-#{post.id}"
  defp in_v(post, sel), do: "#{v(post)} #{sel}"

  defp human_approved_events(post_id) do
    Repo.all(
      from(e in PostEvent,
        where: e.post_id == ^post_id and e.action == "approved" and e.actor_kind == "human"
      )
    )
  end

  # ── Done means 1: one card per idea, Approve all ─────────────────────

  describe "an idea with 3 drafts" do
    test "approval consequence is confined to Queue, not idea detail", %{conn: conn} = ctx do
      idea = idea!(ctx, "Review in detail")
      [post] = drafts!(ctx, idea, [ctx.a])
      child = open(conn, ctx.h1, "/m/social?tab=ideas")

      child |> element("#idea-card-#{idea.id} [data-role='idea-card-open']") |> render_click()

      detail = "#idea-detail-card-#{idea.id}"
      assert has_element?(child, "#{detail} #idea-detail-#{post.id} [data-role='queue-approve']")
      refute has_element?(child, "#{detail} [data-role='queue-approval-consequence']")
      refute has_element?(child, "#{detail} [data-role='queue-phone-consequence']")
    end

    test "the approval consequence appears only when the viewer has an Approve action",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Copy-only first")
      [copy] = drafts!(ctx, idea, [ctx.d])
      child = open(conn, ctx.h1)
      note = "Approval submits to the connected account immediately if no future time is set."

      assert has_element?(child, in_v(copy, "[data-role='queue-copy']"))
      refute has_element?(child, "[data-role='social-queue-pane']", note)

      refute has_element?(
               child,
               "[data-role='queue-phone-bar'] [data-role='queue-phone-consequence']"
             )

      [approvable] = drafts!(ctx, idea!(ctx, "Approvable"), [ctx.a])
      assert is_nil(approvable.scheduled_at)
      child |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
      assert has_element?(child, in_v(approvable, "[data-role='queue-approve']"))
      assert has_element?(child, "[data-role='social-queue-pane']", note)

      # Responsive visibility itself is checked in the browser; pin its class tokens here.
      assert [inline_classes] =
               child
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(in_v(approvable, "[data-role='queue-approval-consequence']"))
               |> LazyHTML.attribute("class")

      assert "hidden" in String.split(inline_classes)
      assert "sm:block" in String.split(inline_classes)

      assert has_element?(
               child,
               "[data-role='queue-phone-bar'][data-post='#{approvable.id}'] [data-role='queue-phone-consequence']",
               note
             )
    end

    test "renders one card with 3 real previews, the source, the agent, the title and stage",
         %{conn: conn} = ctx do
      {idea, [li, x, ig]} = three!(ctx)
      child = open(conn, ctx.h1)

      assert [_one] =
               LazyHTML.query(LazyHTML.from_fragment(render(child)), "[data-role='queue-idea']")
               |> Enum.to_list()

      assert has_element?(child, card(idea.id))

      for {post, platform} <- [{li, "linkedin"}, {x, "x"}, {ig, "instagram"}] do
        assert has_element?(
                 child,
                 in_v(post, "[data-role='social-preview'][data-platform='#{platform}']")
               )

        assert has_element?(child, in_v(post, "[data-role='approval-mode']"), "Approve first")
        assert has_element?(child, in_v(post, "[data-role='queue-approve']"))
      end

      assert has_element?(
               child,
               "#{card(idea.id)} [data-role='queue-title']",
               "Episode 12 launch"
             )

      assert has_element?(child, "#{card(idea.id)} [data-role='queue-source']", "Agent idea")

      assert has_element?(
               child,
               "#{card(idea.id)} [data-role='queue-agent']",
               "Drafted by #{ctx.g.name}"
             )

      assert has_element?(child, "#{card(idea.id)} [data-role='queue-stage']", "In review")
      assert has_element?(child, "[data-role='queue-summary']", "1 idea · 3 posts")
    end

    test "Approve all (after one confirm) leaves 3 approved posts, each with a human approved event",
         %{conn: conn} = ctx do
      {idea, posts} = three!(ctx)
      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               "#{card(idea.id)} [data-role='queue-approve-all']",
               "Approve all 3"
             )

      child |> element("#{card(idea.id)} [data-role='queue-approve-all']") |> render_click()
      # The confirm step lists what goes out; nothing is approved yet.
      assert [_, _, _] =
               child
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("[data-role='queue-approve-all-item']")
               |> Enum.to_list()

      assert Fake.calls(:publish) == []

      child |> element("#{card(idea.id)} [data-role='queue-approve-all-go']") |> render_click()

      for post <- posts do
        row = Repo.get!(Post, post.id)
        assert row.status in Post.approved_statuses()
        assert row.approved_by_user_id == ctx.h1.id
        assert [_one] = human_approved_events(post.id)
        assert Repo.get_by!(ApprovalCard, post_id: post.id).state == "decided"
      end

      assert length(Fake.calls(:publish)) == 3

      assert has_element?(
               child,
               "#{card(idea.id)} [data-role='queue-all-result']",
               "Approved 3 of 3."
             )

      refute has_element?(child, "#{card(idea.id)} [data-role='queue-approve']")
      # The chat card shows the same decision.
      [first | _] = posts
      chat = Approvals.card_view(Approvals.latest_card(first.id).id, {:user, ctx.h2.id})
      assert chat.status.text =~ "Approved by Hana One"
    end

    test "Approve all skips a draft-only version and a version owned by someone else",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Mixed")
      [li, d] = drafts!(ctx, idea, [ctx.a, ctx.d])
      child = open(conn, ctx.h1)

      assert has_element?(child, in_v(d, "[data-role='queue-copy']"), "Copy text")
      refute has_element?(child, in_v(d, "[data-role='queue-approve']"))
      # One approvable version: no Approve all.
      refute has_element?(child, "#{card(idea.id)} [data-role='queue-approve-all']")
      assert has_element?(child, in_v(li, "[data-role='queue-approve']"))
    end
  end

  # ── Done means 2: next slot ──────────────────────────────────────────

  describe "Approve into next slot" do
    test "sets scheduled_at to the next free slot shown on the button", %{conn: conn} = ctx do
      at = DateTime.utc_now() |> DateTime.add(3, :day) |> Map.merge(%{minute: 30, second: 0})

      {_idea, [post | _]} =
        three!(ctx, %{
          "scheduled_at" => DateTime.to_iso8601(at),
          "schedule_reason" => "Tuesday mornings get the most replies here."
        })

      # 4/11: the button needs a posting slot on the post's account.
      {:ok, _} =
        Social.update_account_schedule(ctx.org_id, post.account_id, %{
          posting_slots: for(d <- 1..7, do: %{weekday: d, time: "06:15"})
        })

      profile = Social.get_profile(ctx.org_id, ctx.profile.id)
      slot = NextSlot.next_free(profile, post)
      assert %DateTime{minute: 15} = slot

      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               in_v(post, "[data-role='queue-reason']"),
               "Tuesday mornings get the most replies here."
             )

      assert has_element?(child, in_v(post, "[data-role='queue-approve-slot']"), "Next slot")

      child |> element(in_v(post, "[data-role='queue-approve-slot']")) |> render_click()

      row = Repo.get!(Post, post.id)
      assert row.status in Post.approved_statuses()
      assert DateTime.compare(row.scheduled_at, slot) == :eq
      assert [%{note: "Into the next slot, " <> _}] = human_approved_events(post.id)
    end

    test "a slot the human was not shown is refused, in plain words", %{conn: conn} = ctx do
      {idea, [post | _]} = three!(ctx)
      child = open(conn, ctx.h1)

      html =
        child
        |> with_target(card(idea.id))
        |> render_click("q_approve_slot", %{
          "post-id" => post.id,
          "fingerprint" => Approvals.fingerprint(post),
          "slot" => "2031-01-01T09:00:00Z"
        })

      assert html =~ "The next slot moved. Check the new time and approve again."
      assert Repo.get!(Post, post.id).status == "needs_approval"
      assert Fake.calls(:publish) == []
    end

    test "decide_approve_at refuses a time in the past", ctx do
      {_idea, [post | _]} = three!(ctx)
      card = Approvals.live_card(post.id)
      h1 = Platform.Accounts.get_user(ctx.h1.id)

      assert {:error, :slot_passed} =
               Approvals.decide_approve_at(
                 card.canvas_id,
                 h1,
                 Approvals.fingerprint(post),
                 DateTime.add(DateTime.utc_now(), -60)
               )

      assert Repo.get!(Post, post.id).status == "needs_approval"
    end
  end

  # ── Done means 3: revise ─────────────────────────────────────────────

  test "a revise note reaches social_idea_list", %{conn: conn} = ctx do
    {idea, [li | _]} = three!(ctx)
    child = open(conn, ctx.h1)

    child |> element(in_v(li, "[data-role='queue-revise']")) |> render_click()

    child
    |> element(in_v(li, "[data-role='queue-revise-form']"))
    |> render_submit(%{"text" => "Lead with the guest's name."})

    assert has_element?(child, in_v(li, "[data-role='queue-status']"), "Revision asked")
    assert Repo.get!(Post, li.id).status == "needs_approval"

    {:ok, %{ideas: ideas}} =
      call("social_idea_list", %{"profile_id" => ctx.profile.id}, ctx.agent_ctx)

    listed = Enum.find(ideas, &(&1.id == idea.id))

    assert [%{post_id: post_id, note: "Lead with the guest's name."}] = listed.open_revisions
    assert post_id == li.id
  end

  test "Edit saves the text through decide_edit, and Reject needs a reason",
       %{conn: conn} = ctx do
    {_idea, [li, x, _ig]} = three!(ctx)
    child = open(conn, ctx.h2)

    child |> element(in_v(li, "[data-role='queue-edit']")) |> render_click()

    child
    |> element(in_v(li, "[data-role='queue-edit-form']"))
    |> render_submit(%{"text" => "A tighter line"})

    assert {"A tighter line", "needs_approval"} ==
             (fn p -> {p.body, p.status} end).(Repo.get!(Post, li.id))

    assert has_element?(child, in_v(li, "[data-role='queue-edited']"), "Edited by Hugo Two")

    child |> element(in_v(x, "[data-role='queue-reject']")) |> render_click()
    assert has_element?(child, in_v(x, "[data-role='queue-form-submit'][disabled]"))

    child
    |> element(in_v(x, "[data-role='queue-reject-form']"))
    |> render_submit(%{"text" => "Off brand"})

    row = Repo.get!(Post, x.id)
    assert {row.status, row.rejection_reason} == {"draft", "Off brand"}
    assert has_element?(child, in_v(x, "[data-role='queue-status']"), "Rejected by Hugo Two")
    assert Fake.calls(:publish) == []
  end

  # ── Done means 4: a non-approver ─────────────────────────────────────

  test "a non-approver sees previews with no buttons, not disabled ones", %{conn: conn} = ctx do
    {idea, posts} = three!(ctx)
    child = open(conn, ctx.n)

    for post <- posts do
      assert has_element?(child, in_v(post, "[data-role='social-preview']"))
      assert has_element?(child, "#{v(post)}[data-version-role='viewer']")
    end

    assert render(child) =~ "Episode 12 is out"
    refute has_element?(child, "#social-queue button")
    refute has_element?(child, "#social-queue [disabled]")
    refute has_element?(child, "#{card(idea.id)} [data-role='queue-phone-bar']")

    # Forged clicks are refused on the server and change nothing.
    [li | _] = posts

    html =
      child
      |> with_target(card(idea.id))
      |> render_click("q_approve", %{
        "post-id" => li.id,
        "fingerprint" => Approvals.fingerprint(li)
      })

    assert html =~ "You are not an approver for this account."

    render_click(with_target(child, card(idea.id)), "q_all_confirm", %{
      "fps" =>
        PlatformWeb.SocialIdeaCard.fps(
          for p <- posts, do: %{post: p, fingerprint: Approvals.fingerprint(p)}
        )
    })

    assert Enum.all?(posts, &(Repo.get!(Post, &1.id).status == "needs_approval"))
    assert Fake.calls(:publish) == []
  end

  # ── Done means 5 and 8: the stale fingerprint ─────────────────────────

  describe "a stale fingerprint" do
    # An agent edit that lands after the human rendered the card and before
    # the click (written around the card re-render, so the page still shows
    # the old text).
    defp edit_behind_the_card!(post, body) do
      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [body: body])
    end

    test "Approve on the card is refused in plain words", %{conn: conn} = ctx do
      {_idea, [li | _]} = three!(ctx)
      child = open(conn, ctx.h1)
      edit_behind_the_card!(li, "Unseen text")

      child |> element(in_v(li, "[data-role='queue-approve']")) |> render_click()

      assert has_element?(child, in_v(li, "[data-role='queue-notice']"), @stale)
      assert Repo.get!(Post, li.id).status == "needs_approval"
      assert Fake.calls(:publish) == []
    end

    # The mutation probe: Approve all must pass each version's OWN rendered
    # fingerprint. Calling decide_approve/2 (no fingerprint) instead approves
    # the unseen text and turns this red.
    test "Approve all approves the others and refuses the changed one", %{conn: conn} = ctx do
      {idea, [li, x, ig]} = three!(ctx)
      child = open(conn, ctx.h1)
      child |> element("#{card(idea.id)} [data-role='queue-approve-all']") |> render_click()
      edit_behind_the_card!(x, "Unseen text")
      child |> element("#{card(idea.id)} [data-role='queue-approve-all-go']") |> render_click()

      assert Repo.get!(Post, x.id).status == "needs_approval"
      assert human_approved_events(x.id) == []
      assert has_element?(child, in_v(x, "[data-role='queue-notice']"), @stale)

      for post <- [li, ig],
          do: assert(Repo.get!(Post, post.id).status in Post.approved_statuses())

      assert length(Fake.calls(:publish)) == 2
      assert has_element?(child, "[data-role='queue-all-result']", "Approved 2 of 3.")
    end
  end

  # ── Done means 6: the phone ──────────────────────────────────────────

  describe "phone" do
    test "the sticky bar acts on the version on screen, and the strip moves it",
         %{conn: conn} = ctx do
      {idea, [li, x, _ig]} = three!(ctx)
      child = open(conn, ctx.h1)
      bar = "#{card(idea.id)} [data-role='queue-phone-bar']"

      # Fixed at the bottom, phones only (sm:hidden), on the first version.
      assert has_element?(child, bar <> ".fixed.sm\\:hidden[data-post='#{li.id}']")
      assert has_element?(child, bar <> " [data-role='queue-bar-approve']")
      assert has_element?(child, bar <> " [data-role='queue-bar-revise']")
      assert has_element?(child, bar <> " [data-role='queue-bar-reject']")

      assert has_element?(
               child,
               "#{card(idea.id)}-strip[phx-hook='QueueSwipe'][data-current='0']"
             )

      # The QueueSwipe hook reports a swipe to the second version.
      child |> element("#{card(idea.id)}-strip") |> render_hook("q_version", %{"index" => 1})
      assert has_element?(child, bar <> "[data-post='#{x.id}']")
      assert has_element?(child, "#{card(idea.id)}-strip[data-current='1']")

      child |> element(bar <> " [data-role='queue-bar-approve']") |> render_click()

      assert Repo.get!(Post, x.id).status in Post.approved_statuses()
      assert Repo.get!(Post, li.id).status == "needs_approval"
    end

    test "one idea per screen, with Previous / Next", %{conn: conn} = ctx do
      {first, _} = three!(ctx)
      second = idea!(ctx, "Second idea")
      drafts!(ctx, second, [ctx.a])
      child = open(conn, ctx.h1)

      assert has_element?(child, "[data-role='queue-idea-position']", "Idea 1 of 2")
      assert has_element?(child, "#queue-idea-#{first.id}:not(.max-sm\\:hidden)")
      assert has_element?(child, "#queue-idea-#{second.id}.max-sm\\:hidden")

      child |> element("[data-role='queue-next-idea']") |> render_click()

      assert has_element?(child, "[data-role='queue-idea-position']", "Idea 2 of 2")
      assert has_element?(child, "#queue-idea-#{first.id}.max-sm\\:hidden")
      assert has_element?(child, "#queue-idea-#{second.id}:not(.max-sm\\:hidden)")
    end

    test "?tab=queue&idea=<id> opens straight onto the idea, as the inbox row does",
         %{conn: conn} = ctx do
      _first = three!(ctx)
      second = idea!(ctx, "Second idea")
      [post] = drafts!(ctx, second, [ctx.a])

      [item] =
        Repo.all(
          from(i in Platform.Inbox.Item,
            where: i.user_id == ^ctx.h1.id and i.source_id == ^post.id
          )
        )

      assert item.url ==
               Platform.Social.PostPresentation.url(post, ctx.profile, {:user, ctx.h1.id})

      assert item.url =~ "idea=#{second.id}"

      child = open(conn, ctx.h1, item.url)

      assert has_element?(child, "[data-role='queue-idea-position']", "Idea 2 of 2")
      assert has_element?(child, "#queue-idea-#{second.id}:not(.max-sm\\:hidden)")
      assert has_element?(child, "#{card(second.id)}[data-deep-link='true']")
    end
  end

  # ── Live sync with chat ──────────────────────────────────────────────

  test "a decision made in chat updates the card and the counts", %{conn: conn} = ctx do
    {_idea, [li | _]} = three!(ctx)
    child = open(conn, ctx.h1)
    assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (3)")

    h2 = Platform.Accounts.get_user(ctx.h2.id)
    card = Approvals.live_card(li.id)
    assert {:ok, _} = Approvals.decide_approve(card.canvas_id, h2, Approvals.fingerprint(li))

    assert has_element?(child, in_v(li, "[data-role='queue-status']"), "Approved by Hugo Two")
    refute has_element?(child, in_v(li, "[data-role='queue-approve']"))
    assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (2)")
  end

  # ── Scope ────────────────────────────────────────────────────────────

  test "All brands binds each display title to that post's authorized profile",
       %{conn: conn} = ctx do
    {allowed, _} = pending_post!(ctx, ctx.a, %{body: "ALLOWED-BRAND-TITLE"})
    space = channel!(ctx.org_id)
    for user <- [ctx.h1, ctx.h2, ctx.n], do: join!(space.id, :user, user.id)

    {:ok, profile} =
      Social.create_profile(ctx.org_id, %{
        name: "Denied brand",
        space_id: space.id,
        approver_user_ids: [ctx.h1.id, ctx.h2.id]
      })

    project = project!(ctx.org_id)
    profile = Repo.update!(Ecto.Changeset.change(profile, project_id: project.id))

    {:ok, account} =
      Social.create_account(ctx.org_id, profile, %{platform: "linkedin", handle: "@other_brand"})

    {denied, _} = pending_post!(ctx, account, %{body: "DENIED-BRAND-TITLE"})

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, project.id}
      })

    child = open(conn, ctx.n, "/m/social?profile=#{ctx.profile.id}&tab=queue")
    child |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()

    assert has_element?(
             child,
             "#{card(allowed.id)} [data-role='queue-title']",
             "ALLOWED-BRAND-TITLE"
           )

    assert has_element?(child, "#{card(denied.id)} [data-role='queue-title']", "LinkedIn post")

    refute child |> element("#{card(denied.id)} [data-role='queue-title']") |> render() =~
             "DENIED-BRAND-TITLE"

    assert Fake.calls(:publish) == []
  end

  test "switching brands leaves no row of the other brand", %{conn: conn} = ctx do
    {idea, _} = three!(ctx)

    {:ok, legacy} =
      Social.create_profile(ctx.org_id, %{
        name: "Legacy #{unique()}",
        space_id: channel!(ctx.org_id).id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, yt} =
      Social.create_account(ctx.org_id, legacy, %{platform: "youtube", handle: "Legacy"})

    {legacy_post, _} = pending_post!(ctx, yt, %{body: "LEGACY-Q1 body"})

    child = open(conn, ctx.h1)
    assert has_element?(child, card(idea.id))
    refute has_element?(child, v(legacy_post))

    child |> form("#social-profile-switcher", %{profile_id: legacy.id}) |> render_change()
    refute has_element?(child, card(idea.id))
    assert has_element?(child, v(legacy_post))
    refute render(child) =~ "Episode 12 is out"

    child |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(child, card(idea.id))
    assert has_element?(child, v(legacy_post))
    assert has_element?(child, "#{card(legacy_post.id)} [data-role='queue-brand']", legacy.name)
  end

  # ── Empty states and the sections below ──────────────────────────────

  test "an empty queue says Nothing needs you, and still shows Scheduled", %{conn: conn} = ctx do
    {:ok, post} = Social.create_post(ctx.org_id, ctx.a, %{body: "Goes out Friday"})
    at = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set: [
        status: "scheduled",
        scheduled_at: at,
        approved_by_user_id: ctx.h1.id,
        approved_at: DateTime.utc_now()
      ]
    )

    child = open(conn, ctx.h1)
    assert has_element?(child, "[data-role='social-empty']", "Nothing is awaiting approval.")
    refute has_element?(child, "[data-role='social-go-connections']")
    assert has_element?(child, "#queue-scheduled-#{post.id}", "Goes out Friday")

    assert has_element?(
             child,
             "#queue-scheduled-#{post.id} [data-role='queue-scheduled-post']",
             "@htc_official"
           )
  end

  test "a profile with no accounts points at Connections instead", %{conn: conn} = ctx do
    {:ok, empty} =
      Social.create_profile(ctx.org_id, %{
        name: "Aardvark #{unique()}",
        space_id: channel!(ctx.org_id).id,
        approver_user_ids: [ctx.h1.id]
      })

    child = open(conn, ctx.h1)
    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(child, "[data-role='social-empty']", "Connect an account to start.")
    assert has_element?(child, "[data-role='social-empty']", "Nothing is awaiting approval.")
    child |> element("[data-role='social-go-connections']") |> render_click()
    assert has_element?(child, "[data-role='social-tab-body'][data-tab='connections']")
  end

  test "Scheduled groups the next 7 days by idea; Published shows the last 24h with the link out",
       %{conn: conn} = ctx do
    {idea, [li, x, ig]} = three!(ctx)
    soon = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    later = DateTime.utc_now() |> DateTime.add(9, :day) |> DateTime.truncate(:second)

    approve = fn post, at ->
      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [
          status: "scheduled",
          scheduled_at: at,
          approved_by_user_id: ctx.h1.id,
          approved_at: DateTime.utc_now()
        ]
      )
    end

    approve.(li, soon)
    approve.(x, DateTime.add(soon, 3600))
    approve.(ig, later)

    {:ok, done} = Social.create_post(ctx.org_id, ctx.a, %{body: "Went out"})

    Repo.update_all(from(p in Post, where: p.id == ^done.id),
      set: [
        status: "published",
        external_url: "https://www.linkedin.com/feed/update/1",
        published_at: DateTime.add(DateTime.utc_now(), -3600),
        approved_by_user_id: ctx.h1.id,
        approved_at: DateTime.utc_now()
      ]
    )

    child = open(conn, ctx.h1)
    row = "#queue-scheduled-#{idea.id}"
    assert has_element?(child, row, "Episode 12 launch")

    assert [_, _] =
             child
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#{row} [data-role='queue-scheduled-post']")
             |> Enum.to_list()

    assert has_element?(
             child,
             "#queue-published-#{done.id} a[href='https://www.linkedin.com/feed/update/1']",
             "View post"
           )
  end

  test "N clips waiting in Clips links to the Clips tab", %{conn: conn} do
    w = render_world!()
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, _clip} =
      Social.AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{"file_id" => file.id, "title" => "A clip"},
        w.agent.id
      )

    child = open(conn, w.approver)
    assert has_element?(child, "[data-role='queue-clips-waiting']", "1 clip waiting in Clips")
    child |> element("[data-role='queue-clips-waiting']") |> render_click()
    assert has_element?(child, "[data-role='social-tab-body'][data-tab='clips']")
  end

  test "the alt-text flag is one quiet line, not a warning chip", %{conn: conn} = ctx do
    image = media_file!(ctx.org_id, "image/png")
    idea = idea!(ctx, "With an image")
    [post] = drafts!(ctx, idea, [ctx.a], %{"media_file_ids" => [image.id]})
    child = open(conn, ctx.h1)

    assert has_element?(child, in_v(post, "[data-role='queue-alt-note']"), "without alt text")
    refute has_element?(child, in_v(post, "[data-flag='missing_alt']"))
  end

  describe "Failed and refused (task 01a165f1)" do
    defp refused!(ctx, kind, attrs \\ []) do
      {post, card} = pending_post!(ctx, ctx.a, %{body: "REFUSED-#{kind} body"})
      h1 = Platform.Accounts.get_user(ctx.h1.id)
      {:ok, _} = Approvals.decide_approve(card.canvas_id, h1, Approvals.fingerprint(post))
      Fake.reset()

      set =
        Keyword.merge(
          [
            status: "approved",
            external_id: nil,
            external_url: nil,
            refused_reason: kind,
            refused_at: ~U[2026-10-22 23:21:00.000000Z],
            retry_after: nil,
            error: "Instagram Reels need a Business or Creator account."
          ],
          attrs
        )

      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: set)
      {Repo.get!(Post, post.id), card}
    end

    defp action(post), do: in_v(post, "[data-role='social-card-refusal-action']")

    test "each refusal is listed with its reason and its one action", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      {archived, _} = refused!(ctx, "account_archived")
      child = open(conn, ctx.h1)

      assert has_element?(child, "[data-role='queue-failed']", "Failed and refused")

      assert has_element?(
               child,
               in_v(media, "[data-role='social-card-status'][data-dot='error']"),
               "Not published"
             )

      assert has_element?(
               child,
               action(media) <> "[data-action='retry_publish']",
               "Retry publish"
             )

      assert has_element?(
               child,
               action(archived) <> "[data-action='reconnect'][href*='tab=connections']",
               "Reconnect account"
             )
    end

    test "Retry publishes via the Fake and clears the refusal", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      child = open(conn, ctx.h1)

      child |> element(action(media)) |> render_click()

      assert [{:publish, _, _}] = Fake.calls(:publish)
      row = Repo.get!(Post, media.id)
      assert {row.status, row.refused_reason} == {"scheduled", nil}
      refute has_element?(child, in_v(media, "[data-role='social-card-refusal']"))
    end

    test "a viewer gets the reason and no action", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      viewer = open(conn, ctx.n)

      assert has_element?(
               viewer,
               in_v(media, "[data-role='social-card-refusal-reason']"),
               "Instagram Reels need a Business or Creator account."
             )

      refute has_element?(viewer, "[data-role='social-card-refusal-action']")
    end
  end
end
