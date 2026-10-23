defmodule PlatformWeb.SocialCardLiveTest do
  @moduledoc """
  The approval card in ChatLive (Social 3/7 stage 3): each human opens the
  profile's channel in their own LiveView session and clicks on the card.
  `async: false`: the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Social.{Approvals, ApprovalCard, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    {post, card} = pending_post!(ctx, ctx.a)
    Map.merge(ctx, %{post: post, card: card})
  end

  defp open(user, ctx, card \\ nil) do
    card = card || ctx.card
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.space.id}", on_error: :warn)
    render_hook(view, "inline_canvas_mount", %{"message_id" => card.message_id})
    view
  end

  defp card_el(card), do: "#inline-canvas-#{card.message_id} [data-role='social-card']"
  defp in_card(card, sel), do: "#inline-canvas-#{card.message_id} #{sel}"

  defp component(view, card) do
    html = view |> element(card_el(card)) |> render()
    [_, id] = Regex.run(~r/id="(social-card-[^"]+)"/, html)
    with_target(view, "##{id}")
  end

  test "an approver's Approve publishes once through the Fake", ctx do
    view = open(ctx.h1, ctx)
    assert has_element?(view, in_card(ctx.card, "[data-role='social-card-preview']"))
    assert render(view) =~ "Episode 12 is live"

    view |> element(in_card(ctx.card, "[data-role='social-card-approve']")) |> render_click()

    assert [{:publish, _, _}] = Fake.calls(:publish)
    post = Repo.get!(Post, ctx.post.id)
    assert {post.status, post.approved_by_user_id} == {"scheduled", ctx.h1.id}
    assert render(view) =~ "Approved by Hana One"
    refute has_element?(view, in_card(ctx.card, "[data-role='social-card-approve']"))
  end

  test "fan-out: H2's open card shows the outcome with no live Approve once H1 decides", ctx do
    h2_view = open(ctx.h2, ctx)
    assert has_element?(h2_view, in_card(ctx.card, "[data-role='social-card-approve']"))
    h1_view = open(ctx.h1, ctx)

    h1_view |> element(in_card(ctx.card, "[data-role='social-card-approve']")) |> render_click()

    assert has_element?(
             h2_view,
             in_card(ctx.card, "[data-role='social-card-status']"),
             "Approved by Hana One"
           )

    refute has_element?(h2_view, in_card(ctx.card, "[data-role='social-card-approve']"))
  end

  test "a second session's Approve is refused as already decided, with no second publish",
       ctx do
    fp = Approvals.card_view(ctx.card.id, {:user, ctx.h2.id}).fingerprint
    h1_view = open(ctx.h1, ctx)
    h1_view |> element(in_card(ctx.card, "[data-role='social-card-approve']")) |> render_click()

    # H2's click arrives after the decision (a stale page or a replayed event).
    h2_view = open(ctx.h2, ctx)

    html =
      render_click(component(h2_view, ctx.card), "social_card_approve", %{
        "canvas-id" => ctx.card.canvas_id,
        "fingerprint" => fp
      })

    assert html =~ "Someone already decided this post."
    assert length(Fake.calls(:publish)) == 1
  end

  test "a non-approver human sees the status line with no buttons, text or media", ctx do
    file = media_file!(ctx.org_id, "image/png")

    {_post, card} =
      pending_post!(ctx, ctx.a, %{body: "SECRET_PREVIEW_TEXT", media_file_ids: [file.id]})

    view = open(ctx.n, ctx, card)

    assert has_element?(view, card_el(card) <> "[data-card-role='viewer']")
    assert has_element?(view, in_card(card, "[data-role='social-card-status']"), "Needs approval")
    refute has_element?(view, in_card(card, "button"))
    refute has_element?(view, in_card(card, "img"))
    refute has_element?(view, in_card(card, "video"))
    refute has_element?(view, in_card(card, "[data-role='social-card-preview']"))
    refute render(view) =~ "SECRET_PREVIEW_TEXT"
  end

  test "an agent's view has no buttons, text or media", ctx do
    file = media_file!(ctx.org_id, "video/mp4")

    {_post, card} =
      pending_post!(ctx, ctx.a, %{body: "AGENT_MUST_NOT_SEE", media_file_ids: [file.id]})

    html =
      render_component(PlatformWeb.SocialCardComponent,
        id: "agent-view",
        card_id: card.id,
        rev: 1,
        canvas_id: card.canvas_id,
        viewer: {:agent, ctx.g.id}
      )

    assert html =~ ~s(data-card-role="viewer")
    assert html =~ "Needs approval"
    refute html =~ "<button"
    refute html =~ "<video"
    refute html =~ "<img"
    refute html =~ "AGENT_MUST_NOT_SEE"
  end

  test "Reject stays disabled until the reason has text, then stores it", ctx do
    view = open(ctx.h1, ctx)
    view |> element(in_card(ctx.card, "[data-role='social-card-reject']")) |> render_click()

    assert has_element?(
             view,
             in_card(ctx.card, "[data-role='social-card-reject-submit'][disabled]")
           )

    assert render(view) =~ "What should change?"

    view
    |> element(in_card(ctx.card, "[data-role='social-card-reject-box']"))
    |> render_change(%{"reason" => "Too salesy, cut the last line"})

    refute has_element?(
             view,
             in_card(ctx.card, "[data-role='social-card-reject-submit'][disabled]")
           )

    view
    |> element(in_card(ctx.card, "[data-role='social-card-reject-box']"))
    |> render_submit(%{"reason" => "Too salesy, cut the last line"})

    post = Repo.get!(Post, ctx.post.id)
    assert {post.status, post.rejection_reason} == {"draft", "Too salesy, cut the last line"}
    assert render(view) =~ "Rejected by Hana One: Too salesy, cut the last line"
    refute has_element?(view, in_card(ctx.card, "button"))
    assert Fake.calls(:publish) == []
  end

  test "Edit saves the text, keeps needs_approval and shows Edited by", ctx do
    view = open(ctx.h2, ctx)
    view |> element(in_card(ctx.card, "[data-role='social-card-edit']")) |> render_click()

    view
    |> element(in_card(ctx.card, "[data-role='social-card-editor']"))
    |> render_submit(%{"body" => "A tighter line"})

    post = Repo.get!(Post, ctx.post.id)
    assert {post.body, post.status} == {"A tighter line", "needs_approval"}

    assert has_element?(
             view,
             in_card(ctx.card, "[data-role='social-card-edited']"),
             "Edited by Hugo Two"
           )

    assert has_element?(view, in_card(ctx.card, "[data-role='social-card-approve']"))
  end

  test "draft_only renders Copy text and no Approve, and never publishes", ctx do
    {_post, card} = pending_post!(ctx, ctx.d)
    view = open(ctx.h1, ctx, card)

    assert has_element?(view, in_card(card, "[data-role='social-card-copy']"), "Copy text")

    assert has_element?(
             view,
             in_card(card, "[data-role='social-card-by-hand']"),
             "Post this by hand on LinkedIn"
           )

    refute has_element?(view, in_card(card, "[data-role='social-card-approve']"))

    html =
      render_click(component(view, card), "social_card_approve", %{
        "canvas-id" => card.canvas_id,
        "fingerprint" => Approvals.card_view(card.id, {:user, ctx.h1.id}).fingerprint
      })

    assert html =~ "This account is draft-only"
    assert Fake.calls(:publish) == []
  end

  test "a lookalike canvas holding a real card_id is refused: the clicked canvas has no card",
       ctx do
    agent_participant = Chat.get_agent_participant(ctx.space.id, ctx.g.id)

    {:ok, _lookalike, message} =
      Chat.create_canvas_with_message(ctx.space.id, agent_participant.id, %{
        title: "Post approval",
        document: Approvals.card_document(ctx.card.id, 1)
      })

    fake_card = %{ctx.card | message_id: message.id}
    view = open(ctx.h1, ctx, fake_card)

    view |> element(in_card(fake_card, "[data-role='social-card-approve']")) |> render_click()

    assert render(view) =~ "This card is not a real approval card."
    assert Fake.calls(:publish) == []
    assert Repo.get!(Post, ctx.post.id).status == "needs_approval"
    assert Repo.get!(ApprovalCard, ctx.card.id).state == "pending"
  end

  test "after an agent canvas_patch of the real card, Approve is refused as card_changed", ctx do
    canvas = Chat.get_canvas(ctx.card.canvas_id)

    {:ok, _} =
      Chat.patch_canvas({:agent, ctx.g.id}, canvas, [{:set_props, "root", %{"rev" => 42}}])

    view = open(ctx.h1, ctx)
    view |> element(in_card(ctx.card, "[data-role='social-card-approve']")) |> render_click()

    assert render(view) =~ "This card changed since it was posted; reload."
    assert Fake.calls(:publish) == []
    assert Repo.get!(Post, ctx.post.id).status == "needs_approval"
  end

  test "a refused publish in chat: the approver gets Retry publish, a viewer the reason only (task 01a165f1)",
       ctx do
    h1 = Platform.Accounts.get_user(ctx.h1.id)
    fp = Approvals.card_view(ctx.card.id, {:user, ctx.h1.id}).fingerprint
    {:ok, _} = Approvals.decide_approve(ctx.card.canvas_id, h1, fp)
    Fake.reset()

    Repo.update_all(
      from(p in Post, where: p.id == ^ctx.post.id),
      set: [
        status: "approved",
        refused_reason: "media_rejected",
        refused_at: DateTime.utc_now(),
        error: "Instagram Reels need a Business or Creator account."
      ]
    )

    view = open(ctx.h1, ctx)

    assert has_element?(
             view,
             in_card(ctx.card, "[data-role='social-card-status']"),
             "Not published"
           )

    action = in_card(ctx.card, "[data-role='social-card-refusal-action']")
    assert has_element?(view, action, "Retry publish")

    viewer = open(ctx.n, ctx)

    assert has_element?(
             viewer,
             in_card(ctx.card, "[data-role='social-card-refusal-reason']"),
             "Instagram Reels need a Business or Creator account."
           )

    refute has_element?(viewer, action)

    view |> element(action) |> render_click()
    assert [{:publish, _, _}] = Fake.calls(:publish)
    assert Repo.get!(Post, ctx.post.id).refused_reason == nil
    refute has_element?(view, in_card(ctx.card, "[data-role='social-card-refusal']"))
  end
end
