defmodule Platform.Social.ApprovalsQualityReviewTest do
  use Platform.DataCase, async: false

  import Platform.SocialApprovalFixtures
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Approvals, Post}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    {post, card} = pending_post!(ctx, ctx.a)

    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{quality_reviewer_user_ids: [ctx.n.id]})

    Map.merge(ctx, %{profile: profile, post: post, card: card})
  end

  test "historical card cannot fan out an unpassed post again", c do
    before = {Repo.get!(ApprovalCard, c.card.id), Repo.aggregate(Platform.Inbox.Item, :count)}
    assert {:error, :quality_review_required} = Approvals.request_approval(c.post)

    assert {Repo.get!(ApprovalCard, c.card.id), Repo.aggregate(Platform.Inbox.Item, :count)} ==
             before

    assert Fake.calls() == []
  end

  test "historical card lets a preparer request quality without disclosing final preview", c do
    approver = Approvals.card_view(c.card.id, {:user, c.h1.id})
    assert approver.quality_required?
    assert approver.quality_pass == nil
    assert approver.post_id == c.post.id
    assert approver.org_id == c.org_id
    refute :approve in approver.actions
    refute :copy in approver.actions
    assert :return_to_quality_review in approver.actions

    reviewer = Approvals.card_view(c.card.id, {:user, c.n.id})
    assert reviewer.role == :viewer
    assert reviewer.actions == [:return_to_quality_review]
    refute Map.has_key?(reviewer, :body)
    refute Map.has_key?(reviewer, :media)
    refute Map.has_key?(reviewer, :fingerprint)
    assert Fake.calls() == []
  end

  test "a genuinely decided pre-gate approval is not labelled as needing quality review", c do
    {:ok, profile} = Social.update_profile(c.org_id, c.profile, %{quality_reviewer_user_ids: []})
    assert {:ok, %{card: decided}} = Approvals.decide_approve(c.card.canvas_id, c.h1)
    assert decided.state == "decided" and decided.decision == "approve"
    assert Repo.get!(Post, c.post.id).status == "scheduled"
    calls_before = Fake.calls()
    {:ok, _} = Social.update_profile(c.org_id, profile, %{quality_reviewer_user_ids: [c.n.id]})
    view = Approvals.card_view(decided.id, {:user, c.h1.id})
    refute view.quality_required?
    refute :return_to_quality_review in Map.get(view, :actions, [])
    assert Fake.calls() == calls_before
  end

  test "passed card shows pass provenance and edit retires its final approval", c do
    assert {:ok, _} = Social.return_to_quality_review(c.org_id, c.post.id, c.n.id)
    assert {:ok, passed} = Social.pass_quality_review(c.org_id, c.post.id, c.n.id)
    card = Approvals.live_card(passed.id)
    view = Approvals.card_view(card.id, {:user, c.h1.id})
    refute view.quality_required?
    assert view.quality_pass == %{name: c.n.name, at: passed.quality_passed_at}
    assert :approve in view.actions

    assert {:ok, %{post: edited}} =
             Approvals.decide_edit(
               card.canvas_id,
               c.h1,
               %{body: "Edited after quality review"},
               view.fingerprint
             )

    assert edited.status == "quality_review"
    assert edited.quality_passed_at == nil
    assert edited.quality_passed_by_user_id == nil
    assert edited.quality_pass_fingerprint == nil
    assert Repo.get!(ApprovalCard, card.id).state == "superseded"
    assert Approvals.live_card(edited.id) == nil

    assert {:error, :already_decided} =
             Approvals.decide_approve(card.canvas_id, c.h1, view.fingerprint)

    assert Repo.get!(Post, c.post.id).approved_at == nil
    assert Fake.calls() == []
  end
end
