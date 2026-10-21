defmodule PlatformWeb.SocialCardOwnerLiveTest do
  @moduledoc """
  The approval card on an account with an owner (task 01a14ce1, stages 1
  and 3). The card lives in the OWNER's DM (stage 3); a profile approver
  sees the post read-only in the Social queue. Each click is re-authorized
  at the moment it lands: a profile approver who forges the phx event is
  refused, whatever the page rendered. `async: false`: the Fake's call log
  is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    owner = named_user!("Omar Owner")
    member!(owner, ctx.org_id)
    join!(ctx.space.id, :user, owner.id)
    {:ok, owned} = Social.set_account_owner(ctx.org_id, ctx.a, owner.id)
    {post, card} = pending_post!(ctx, owned)
    dm_id = Repo.get!(Platform.Chat.Message, card.message_id).space_id
    Map.merge(ctx, %{owner: owner, post: post, card: card, dm_id: dm_id})
  end

  # The owner reads the card in their DM.
  defp open(user, ctx) do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.dm_id}", on_error: :warn)
    render_hook(view, "inline_canvas_mount", %{"message_id" => ctx.card.message_id})
    view
  end

  # A profile approver reads the post in the Social queue.
  defp open_queue(user) do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp in_card(card, sel), do: "#inline-canvas-#{card.message_id} #{sel}"
  defp q_card(card), do: "#queue-card-#{card.id}"
  defp in_q(card, sel), do: "#{q_card(card)} #{sel}"

  test "the owner sees Approve and it publishes once", ctx do
    view = open(ctx.owner, ctx)
    assert render(view) =~ "Episode 12 is live"
    view |> element(in_card(ctx.card, "[data-role='social-card-approve']")) |> render_click()

    assert [{:publish, _, _}] = Fake.calls(:publish)
    assert Repo.get!(Post, ctx.post.id).approved_by_user_id == ctx.owner.id
  end

  test "the owner's DM card says whose account it posts as", ctx do
    view = open(ctx.owner, ctx)

    assert view |> element(in_card(ctx.card, "[data-role='social-card-posts-as']")) |> render() =~
             "Posts as you · LinkedIn · for #{ctx.profile.name}"

    assert has_element?(view, in_card(ctx.card, "[data-role='social-card-approve']"))
    assert has_element?(view, in_card(ctx.card, "[data-role='social-card-edit']"))
    assert has_element?(view, in_card(ctx.card, "[data-role='social-card-reject']"))
  end

  test "a profile approver sees the post read-only and waits, and forged events are refused",
       ctx do
    child = open_queue(ctx.h1)
    assert has_element?(child, q_card(ctx.card) <> "[data-card-role='waiting']")
    assert render(child) =~ "Episode 12 is live"

    assert child |> element(in_q(ctx.card, "[data-role='social-card-waiting']")) |> render() =~
             "Waiting for Omar"

    # Hidden, not disabled: no button of any kind on the card.
    refute has_element?(child, in_q(ctx.card, "button"))
    refute has_element?(child, in_q(ctx.card, "[data-role='social-card-posts-as']"))

    fp = Approvals.fingerprint(ctx.post)
    target = with_target(child, q_card(ctx.card))

    html =
      render_click(target, "social_card_approve", %{
        "canvas-id" => ctx.card.canvas_id,
        "fingerprint" => fp
      })

    assert html =~ "Only Omar can approve posts to their account."

    render_click(target, "social_card_edit_save", %{
      "canvas-id" => ctx.card.canvas_id,
      "body" => "Hijacked",
      "fingerprint" => fp
    })

    render_click(target, "social_card_reject_submit", %{
      "canvas-id" => ctx.card.canvas_id,
      "reason" => "Not mine",
      "fingerprint" => fp
    })

    post = Repo.get!(Post, ctx.post.id)
    assert {post.status, post.body} == {"needs_approval", "Episode 12 is live: listen now"}
    assert Fake.calls(:publish) == []
  end

  test "owner archived: a profile approver sees Reject only and can reject", ctx do
    {:ok, _} = Platform.Accounts.archive_user(ctx.owner)
    child = open_queue(ctx.h1)

    assert has_element?(child, in_q(ctx.card, "[data-role='social-card-reject']"))
    refute has_element?(child, in_q(ctx.card, "[data-role='social-card-approve']"))
    refute has_element?(child, in_q(ctx.card, "[data-role='social-card-edit']"))
    refute has_element?(child, in_q(ctx.card, "[data-role='social-card-waiting']"))

    html =
      render_click(with_target(child, q_card(ctx.card)), "social_card_approve", %{
        "canvas-id" => ctx.card.canvas_id,
        "fingerprint" => Approvals.fingerprint(ctx.post)
      })

    assert html =~ "Only Omar can approve posts to their account."
    assert Fake.calls(:publish) == []

    child |> element(in_q(ctx.card, "[data-role='social-card-reject']")) |> render_click()

    child
    |> element(in_q(ctx.card, "[data-role='social-card-reject-box']"))
    |> render_submit(%{"reason" => "Owner has left"})

    assert Repo.get!(Post, ctx.post.id).status == "draft"
  end
end
