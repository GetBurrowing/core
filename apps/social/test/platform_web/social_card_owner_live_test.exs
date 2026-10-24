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

  # Social authoring 5/11: the Queue is one idea card per idea; a post with
  # no idea is its own card, keyed by the post id.
  defp q_idea(post), do: "#queue-card-idea-#{post.id}"
  defp in_v(post, sel), do: "#queue-#{post.id} #{sel}"

  test "a profile approver sees the post read-only and waits, and forged events are refused",
       ctx do
    child = open_queue(ctx.h1)
    assert has_element?(child, "#queue-#{ctx.post.id}[data-version-role='waiting']")
    assert render(child) =~ "Episode 12 is live"

    assert child |> element(in_v(ctx.post, "[data-role='queue-waiting']")) |> render() =~
             "Waiting for Omar"

    # Hidden, not disabled: no button of any kind on the version.
    refute has_element?(child, in_v(ctx.post, "button"))
    refute has_element?(child, "#{q_idea(ctx.post)} [data-role='queue-approve-all']")

    fp = Approvals.fingerprint(ctx.post)
    target = with_target(child, q_idea(ctx.post))

    html = render_click(target, "q_approve", %{"post-id" => ctx.post.id, "fingerprint" => fp})
    assert html =~ "Only Omar can approve posts to their account."

    render_click(target, "q_edit_save", %{
      "post-id" => ctx.post.id,
      "text" => "Hijacked",
      "fingerprint" => fp
    })

    render_click(target, "q_reject_submit", %{
      "post-id" => ctx.post.id,
      "text" => "Not mine",
      "fingerprint" => fp
    })

    render_click(target, "q_revise_submit", %{"post-id" => ctx.post.id, "text" => "Not mine"})

    post = Repo.get!(Post, ctx.post.id)
    assert {post.status, post.body} == {"needs_approval", "Episode 12 is live: listen now"}
    assert Platform.Social.PostEvents.list_for_post(post.id) |> Enum.map(& &1.action) == []
    assert Fake.calls(:publish) == []
  end

  test "owner archived: a profile approver sees Reject only and can reject", ctx do
    {:ok, _} = Platform.Accounts.archive_user(ctx.owner)
    child = open_queue(ctx.h1)

    assert has_element?(child, in_v(ctx.post, "[data-role='queue-reject']"))
    refute has_element?(child, in_v(ctx.post, "[data-role='queue-approve']"))
    refute has_element?(child, in_v(ctx.post, "[data-role='queue-edit']"))
    refute has_element?(child, in_v(ctx.post, "[data-role='queue-waiting']"))

    html =
      render_click(with_target(child, q_idea(ctx.post)), "q_approve", %{
        "post-id" => ctx.post.id,
        "fingerprint" => Approvals.fingerprint(ctx.post)
      })

    assert html =~ "Only Omar can approve posts to their account."
    assert Fake.calls(:publish) == []

    child |> element(in_v(ctx.post, "[data-role='queue-reject']")) |> render_click()

    child
    |> element(in_v(ctx.post, "[data-role='queue-reject-form']"))
    |> render_submit(%{"text" => "Owner has left"})

    assert Repo.get!(Post, ctx.post.id).status == "draft"
  end
end
