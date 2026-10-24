defmodule PlatformWeb.SocialAcceptanceTest do
  @moduledoc """
  Social 7/7 acceptance (stage 5): one describe per Done-when item, on one
  seeded world: profiles HTC and Legacy in one org with distinct accounts and
  posts. Each case is the target of a named mutation probe (P1-P6; P7 is the
  core boundary test). `async: false`: the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, ApprovalCard, Post, RateLimit}
  alias Platform.Social.Publisher.Fake
  alias PlatformWeb.Components.IconRail
  alias PlatformWeb.SocialCalendar

  setup do
    Fake.reset()
    RateLimit.reset()
    # HTC (ctx.profile): approvers H1, H2; N is a member, not an approver;
    # G is an agent. Accounts A (linkedin, approve_first) and D (draft_only).
    ctx = approval_fixture()
    {htc_q1, htc_card} = pending_post!(ctx, ctx.a, %{body: "HTC-Q1 SECRET-PREVIEW-BODY"})
    {htc_d1, htc_d_card} = pending_post!(ctx, ctx.d, %{body: "HTC-D1 DRAFT-ONLY-BODY"})
    tue = Date.add(SocialCalendar.week_start(Date.utc_today()), 1)
    htc_s1 = placed!(ctx, ctx.a, at(tue, 10), "HTC-S1 scheduled")

    {:ok, legacy} =
      Social.create_profile(ctx.org_id, %{
        name: "Legacy #{unique()}",
        space_id: channel!(ctx.org_id).id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, legacy_yt} =
      Social.create_account(ctx.org_id, legacy, %{platform: "youtube", handle: "Legacy channel"})

    {legacy_q1, _} = pending_post!(ctx, legacy_yt, %{body: "LEGACY-Q1 body"})
    legacy_s1 = placed!(ctx, legacy_yt, at(tue, 14), "LEGACY-S1 scheduled")

    Map.merge(ctx, %{
      htc_q1: htc_q1,
      htc_card: htc_card,
      htc_d1: htc_d1,
      htc_d_card: htc_d_card,
      htc_s1: htc_s1,
      legacy: legacy,
      legacy_yt: legacy_yt,
      legacy_q1: legacy_q1,
      legacy_s1: legacy_s1
    })
  end

  defp at(date, h), do: DateTime.new!(date, Time.new!(h, 0, 0), "Etc/UTC")

  defp placed!(ctx, account, at, body) do
    {:ok, post} = Social.create_post(ctx.org_id, account, %{body: body})

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set: [
        status: "scheduled",
        scheduled_at: at,
        approved_by_user_id: ctx.h1.id,
        approved_at: DateTime.add(at, -1, :day)
      ]
    )

    Repo.get!(Post, post.id)
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp switch(child, profile),
    do: child |> form("#social-profile-switcher", %{profile_id: profile.id}) |> render_change()

  defp tab(child, name),
    do: child |> element("[data-role='social-tab-button'][data-tab='#{name}']") |> render_click()

  defp fp(card, user), do: Approvals.card_view(card.id, {:user, user.id}).fingerprint

  # Every DOM id a profile's posts and accounts can own on this page. The
  # calendar's rows are hours since Social authoring 8/11, so its leak check
  # is the scheduled posts' `data-post-id` (grid and agenda both carry it).
  defp ids_of(%{queued: queued, scheduled: scheduled, accounts: accounts}) do
    Enum.map(queued, &"#queue-#{&1.id}") ++
      Enum.map(scheduled, &"[data-post-id='#{&1.id}']") ++
      Enum.map(accounts, &"#accounts-#{&1.id}")
  end

  describe "1. switching HTC <-> Legacy changes accounts, queue and calendar with no leak" do
    test "nothing of the other profile remains in the DOM, both ways", %{conn: conn} = ctx do
      htc = %{queued: [ctx.htc_q1, ctx.htc_d1], scheduled: [ctx.htc_s1], accounts: [ctx.a, ctx.d]}
      legacy = %{queued: [ctx.legacy_q1], scheduled: [ctx.legacy_s1], accounts: [ctx.legacy_yt]}
      child = open(conn, ctx.h1)
      tab(child, "calendar")

      for sel <- ids_of(htc), do: assert(has_element?(child, sel), "HTC missing #{sel}")
      for sel <- ids_of(legacy), do: refute(has_element?(child, sel), "Legacy leaked #{sel}")

      switch(child, ctx.legacy)
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='calendar']")
      for sel <- ids_of(legacy), do: assert(has_element?(child, sel), "Legacy missing #{sel}")
      for sel <- ids_of(htc), do: refute(has_element?(child, sel), "HTC leaked #{sel}")
      refute render(child) =~ "HTC-"

      switch(child, ctx.profile)
      for sel <- ids_of(htc), do: assert(has_element?(child, sel), "HTC missing #{sel}")
      for sel <- ids_of(legacy), do: refute(has_element?(child, sel), "Legacy leaked #{sel}")
      refute render(child) =~ "LEGACY-"
    end
  end

  describe "2. approve from the queue: one publish, decided everywhere, a second approve refused" do
    test "through decide_approve only", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      shown = fp(ctx.htc_card, ctx.h1)

      child
      |> element("#queue-#{ctx.htc_q1.id} [data-role='queue-approve']")
      |> render_click()

      assert [{:publish, _, _}] = Fake.calls(:publish)
      card = Repo.get!(ApprovalCard, ctx.htc_card.id)

      assert {card.state, card.decision, card.decided_by_user_id} ==
               {"decided", "approve", ctx.h1.id}

      # What chat renders for the same canvas.
      assert Approvals.card_view(ctx.htc_card.id, {:user, ctx.h2.id}).state == "decided"

      html =
        child
        |> with_target("#queue-card-idea-#{ctx.htc_q1.id}")
        |> render_click("q_approve", %{"post-id" => ctx.htc_q1.id, "fingerprint" => shown})

      assert html =~ "Someone already decided this post."
      assert length(Fake.calls(:publish)) == 1
    end
  end

  # Social authoring 5/11 (task 01a16c50): on the Queue a human who can
  # open the profile but is not an approver sees the previews, with no
  # buttons at all (not disabled ones). Agents still get the status line
  # only, through card_view/2 and the chat card.
  describe "3. non-approvers see previews with no actions; agents see status lines only" do
    test "N gets previews and no action; an agent gets no action and no body; H1 (positive control) gets both",
         %{conn: conn} = ctx do
      approver = open(conn, ctx.h1)
      assert has_element?(approver, "#queue-#{ctx.htc_q1.id} [data-role='queue-approve']")
      assert has_element?(approver, "#queue-#{ctx.htc_d1.id} [data-role='queue-copy']")
      assert render(approver) =~ "SECRET-PREVIEW-BODY"
      assert render(approver) =~ "DRAFT-ONLY-BODY"

      viewer = open(conn, ctx.n)
      assert has_element?(viewer, "#queue-#{ctx.htc_q1.id}[data-version-role='viewer']")
      assert has_element?(viewer, "#queue-#{ctx.htc_q1.id} [data-role='social-preview']")

      for a <- ~w(approve approve-slot approve-all edit revise reject copy phone-bar bar-approve) do
        refute has_element?(viewer, "#social-queue [data-role='queue-#{a}']")
      end

      refute has_element?(viewer, "#social-queue [data-role='queue-actions']")
      refute has_element?(viewer, "#social-queue [disabled]")

      for card <- [ctx.htc_card, ctx.htc_d_card] do
        assert %{role: :viewer} = view = Approvals.card_view(card.id, {:agent, ctx.g.id})
        assert Map.get(view, :actions, []) == []

        html =
          render_component(PlatformWeb.SocialCardComponent,
            id: "agent-#{card.id}",
            card_id: card.id,
            rev: 1,
            canvas_id: card.canvas_id,
            viewer: {:agent, ctx.g.id}
          )

        refute html =~ "<button"
        refute html =~ "SECRET-PREVIEW-BODY"
        refute html =~ "DRAFT-ONLY-BODY"
      end

      # The Queue's idea card, rendered for an agent: status only.
      group = %{key: ctx.htc_q1.id, idea: nil, posts: [ctx.htc_q1, ctx.htc_d1], first_at: nil}

      html =
        render_component(PlatformWeb.SocialIdeaCard,
          id: "agent-idea",
          group: group,
          viewer: {:agent, ctx.g.id},
          profiles: %{ctx.profile.id => ctx.profile}
        )

      assert html =~ "queue-status-only"
      refute html =~ "<button"
      refute html =~ "SECRET-PREVIEW-BODY"
      refute html =~ "DRAFT-ONLY-BODY"
    end
  end

  describe "4. a draft_only account's row shows Copy, and a forged approve is refused" do
    test "Copy and no Approve; decide_approve answers :draft_only and nothing publishes",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               "#queue-#{ctx.htc_d1.id} [data-role='queue-copy']",
               "Copy text"
             )

      refute has_element?(child, "#queue-#{ctx.htc_d1.id} [data-role='queue-approve']")

      html =
        child
        |> with_target("#queue-card-idea-#{ctx.htc_d1.id}")
        |> render_click("q_approve", %{
          "post-id" => ctx.htc_d1.id,
          "fingerprint" => fp(ctx.htc_d_card, ctx.h1)
        })

      assert html =~ "This account is draft-only"

      h1 = Platform.Accounts.get_user(ctx.h1.id)

      assert {:error, :draft_only} =
               Approvals.decide_approve(ctx.htc_d_card.canvas_id, h1, fp(ctx.htc_d_card, ctx.h1))

      assert Fake.calls(:publish) == []
      assert Repo.get!(Post, ctx.htc_d1.id).status == "needs_approval"
    end
  end

  describe "5. the rail item" do
    test "is on the desktop rail and in the mobile More sheet, not the bottom bar",
         %{conn: conn} = ctx do
      conn = Plug.Test.init_test_session(conn, current_user_id: ctx.h1.id)
      {:ok, _view, html} = live(conn, "/m/social")
      assert html =~ ~s(href="/m/social")

      assert %{path: "/m/social", cluster: :working} =
               Enum.find(IconRail.destinations(), &(&1.key == :social))

      sheet = render_component(&PlatformWeb.Components.MoreSheet.more_sheet/1, open: true)
      assert sheet =~ "/m/social"
      refute render_component(&IconRail.bottom_rail/1, current_path: "/m/social") =~ "/m/social"
    end
  end
end
