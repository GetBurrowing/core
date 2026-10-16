defmodule PlatformWeb.SocialLiveQueueTest do
  @moduledoc """
  The Social tab's Queue (Social 7/7 stage 2): one row per needs_approval
  post of the selected profile, each the EXISTING approval card component
  (`PlatformWeb.SocialCardComponent`) on the post's live card, so a decision
  here and one in chat are the same code. `async: false`: the Fake's call
  log is global.
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

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    {post, card} = pending_post!(ctx, ctx.a, %{body: "HTC-Q1 SECRET-PREVIEW-BODY"})

    # A second profile in the same org, "Fabrikam" sorting after "HTC".
    fabrikam_space = channel!(ctx.org_id)

    {:ok, fabrikam} =
      Social.create_profile(ctx.org_id, %{
        name: "Fabrikam #{unique()}",
        space_id: fabrikam_space.id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, fabrikam_account} =
      Social.create_account(ctx.org_id, fabrikam, %{platform: "youtube", handle: "Fabrikam channel"})

    {fabrikam_post, fabrikam_card} = pending_post!(ctx, fabrikam_account, %{body: "FABRIKAM-Q1 body"})

    Map.merge(ctx, %{
      post: post,
      card: card,
      fabrikam: fabrikam,
      fabrikam_post: fabrikam_post,
      fabrikam_card: fabrikam_card
    })
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp row(post), do: "#queue-#{post.id}"
  defp in_row(post, sel), do: "#{row(post)} #{sel}"

  defp fingerprint(card, user), do: Approvals.card_view(card.id, {:user, user.id}).fingerprint

  test "an approver sees each queued post as the approval card with preview and actions",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             in_row(ctx.post, "#queue-card-#{ctx.card.id}[data-card-role='approver']")
           )

    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-preview']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-edit']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-reject']"))
    assert render(child) =~ "SECRET-PREVIEW-BODY"
    refute has_element?(child, row(ctx.fabrikam_post))
  end

  test "Approve in the queue publishes once, decides the card the chat card shows, and a second approve is refused",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, "[data-role='social-needs-approval']", "1 need approval")
    fp = fingerprint(ctx.card, ctx.h1)

    child |> element(in_row(ctx.post, "[data-role='social-card-approve']")) |> render_click()

    assert [{:publish, _, _}] = Fake.calls(:publish)
    assert Repo.get!(ApprovalCard, ctx.card.id).state == "decided"
    # What chat renders for the same canvas: card_view on the same card.
    assert Approvals.card_view(ctx.card.id, {:user, ctx.h2.id}).state == "decided"

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Approved by Hana One"
           )

    refute has_element?(child, in_row(ctx.post, "button"))
    # The row stays (decided) until the next profile load; the count drops.
    assert has_element?(child, "[data-role='social-needs-approval']", "0 need approval")
    assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (0)")

    html =
      child
      |> with_target("#queue-card-#{ctx.card.id}")
      |> render_click("social_card_approve", %{
        "canvas-id" => ctx.card.canvas_id,
        "fingerprint" => fp
      })

    assert html =~ "Someone already decided this post."
    assert length(Fake.calls(:publish)) == 1
  end

  test "Edit and Reject go through decide_edit and decide_reject", %{conn: conn} = ctx do
    {post2, _card2} = pending_post!(ctx, ctx.a, %{body: "to be rejected"})
    child = open(conn, ctx.h2)

    child |> element(in_row(ctx.post, "[data-role='social-card-edit']")) |> render_click()

    child
    |> element(in_row(ctx.post, "[data-role='social-card-editor']"))
    |> render_submit(%{"body" => "A tighter line"})

    assert {"A tighter line", "needs_approval"} ==
             (fn p -> {p.body, p.status} end).(Repo.get!(Post, ctx.post.id))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-edited']"),
             "Edited by Hugo Two"
           )

    child |> element(in_row(post2, "[data-role='social-card-reject']")) |> render_click()

    child
    |> element(in_row(post2, "[data-role='social-card-reject-box']"))
    |> render_submit(%{"reason" => "Off brand"})

    p2 = Repo.get!(Post, post2.id)
    assert {p2.status, p2.rejection_reason} == {"draft", "Off brand"}

    assert has_element?(
             child,
             in_row(post2, "[data-role='social-card-status']"),
             "Rejected by Hugo Two"
           )

    assert Fake.calls(:publish) == []
  end

  test "a non-approver sees status lines only: no action element and no body",
       %{conn: conn} = ctx do
    {_d_post, _} = pending_post!(ctx, ctx.d, %{body: "DRAFT-ONLY-BODY"})
    child = open(conn, ctx.n)

    assert has_element?(child, in_row(ctx.post, "[data-card-role='viewer']"))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Needs approval"
           )

    for sel <- ~w(approve edit reject copy) do
      refute has_element?(child, "#social-queue [data-role='social-card-#{sel}']")
    end

    refute has_element?(child, "#social-queue button")
    refute has_element?(child, "#social-queue [data-role='social-card-preview']")
    html = render(child)
    refute html =~ "SECRET-PREVIEW-BODY"
    refute html =~ "DRAFT-ONLY-BODY"
  end

  test "an agent-style viewer of a queued card is role viewer, with no actions or body", ctx do
    view = Approvals.card_view(ctx.card.id, {:agent, ctx.g.id})
    assert view.role == :viewer
    assert Map.get(view, :actions, []) == []
    refute Map.get(view, :body)
  end

  test "a draft_only account's row shows Copy and no Approve", %{conn: conn} = ctx do
    {d_post, d_card} = pending_post!(ctx, ctx.d, %{body: "DRAFT-ONLY-BODY"})
    child = open(conn, ctx.h1)

    assert has_element?(child, in_row(d_post, "[data-role='social-card-copy']"), "Copy text")
    refute has_element?(child, in_row(d_post, "[data-role='social-card-approve']"))

    html =
      child
      |> with_target("#queue-card-#{d_card.id}")
      |> render_click("social_card_approve", %{
        "canvas-id" => d_card.canvas_id,
        "fingerprint" => fingerprint(d_card, ctx.h1)
      })

    assert html =~ "This account is draft-only"
    assert Fake.calls(:publish) == []
  end

  test "switching HTC to Fabrikam leaves no HTC row in the DOM, and back again",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, row(ctx.post))

    child |> form("#social-profile-switcher", %{profile_id: ctx.fabrikam.id}) |> render_change()

    refute has_element?(child, row(ctx.post))
    refute has_element?(child, "#queue-card-#{ctx.card.id}")
    assert has_element?(child, row(ctx.fabrikam_post))
    refute render(child) =~ "SECRET-PREVIEW-BODY"

    child |> form("#social-profile-switcher", %{profile_id: ctx.profile.id}) |> render_change()
    assert has_element?(child, row(ctx.post))
    refute has_element?(child, row(ctx.fabrikam_post))
  end

  test "a decision made in chat updates the queued card and the counts", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))

    h2 = Platform.Accounts.get_user(ctx.h2.id)

    assert {:ok, _} =
             Approvals.decide_approve(ctx.card.canvas_id, h2, fingerprint(ctx.card, ctx.h2))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Approved by Hugo Two"
           )

    refute has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))
    assert has_element?(child, "[data-role='social-needs-approval']", "0 need approval")
  end

  test "an empty queue names the profile; a post with no live card says it is waiting",
       %{conn: conn} = ctx do
    {:ok, empty} =
      Social.create_profile(ctx.org_id, %{
        name: "Aardvark #{unique()}",
        space_id: channel!(ctx.org_id).id
      })

    {:ok, empty_account} = Social.create_account(ctx.org_id, empty, %{platform: "x"})
    child = open(conn, ctx.h1)

    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(
             child,
             "[data-role='social-empty']",
             "Nothing waiting for approval on #{empty.name}."
           )

    # A needs_approval post whose card was never placed (written around the hook).
    {:ok, orphan} = Social.create_post(ctx.org_id, empty_account, %{body: "ORPHAN-BODY"})

    Repo.update_all(from(p in Post, where: p.id == ^orphan.id),
      set: [status: "needs_approval"]
    )

    assert Approvals.live_card(orphan.id) == nil

    child |> form("#social-profile-switcher", %{profile_id: ctx.profile.id}) |> render_change()
    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(
             child,
             in_row(orphan, "[data-role='social-queue-waiting']"),
             "Waiting for its approval card."
           )

    refute has_element?(child, in_row(orphan, "button"))
    refute render(child) =~ "ORPHAN-BODY"
  end
end
