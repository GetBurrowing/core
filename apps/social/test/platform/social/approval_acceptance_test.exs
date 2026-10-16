defmodule Platform.Social.ApprovalAcceptanceTest do
  @moduledoc """
  Social 3/7's "Done when", one describe per line, every refusal paired
  with its success on the same fixture. `async: false`: the Fake's call log
  is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Approvals, Post, Profile, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    approval_fixture()
  end

  describe "(a) draft -> needs_approval -> a human approves -> the post publishes through the Fake" do
    test "the whole loop", ctx do
      {:ok, draft} = Social.create_post(ctx.org_id, ctx.a, %{body: "Episode 13 is live"})
      assert draft.status == "draft"
      assert Repo.all(from(c in ApprovalCard, where: c.post_id == ^draft.id)) == []

      {:ok, pending} = Social.update_post(ctx.org_id, draft, %{status: "needs_approval"})
      assert pending.status == "needs_approval"
      card = live_card!(pending)

      assert {:ok, %{post: post}} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert post.status == "scheduled"
      assert post.approved_by_user_id == ctx.h1.id
      assert post.external_id == "fake_" <> post.id
      assert [{:publish, [_account, %{body: "Episode 13 is live"}], _}] = Fake.calls(:publish)
    end
  end

  describe "(b) approval is refused for an agent, a non-listed human, an archived approver and a revoked one" do
    test "an agent: refused :not_a_human; the listed human then succeeds", ctx do
      Repo.update_all(from(p in Profile, where: p.id == ^ctx.profile.id),
        set: [approver_user_ids: [ctx.h1.id, ctx.h2.id, ctx.g.id]]
      )

      {post, card} = pending_post!(ctx, ctx.a)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :not_a_human} = Approvals.decide_approve(card.canvas_id, ctx.g)
      assert {:error, %Ecto.Changeset{}} = Social.approve_post(ctx.org_id, post, ctx.g.id)
      assert {row_snapshot(post), card_snapshot(card), Fake.calls()} == {bp, bc, []}

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert length(Fake.calls(:publish)) == 1
    end

    test "a human not on the list: refused :not_an_approver; a listed one succeeds", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :not_an_approver} = Approvals.decide_approve(card.canvas_id, ctx.n)
      assert {:error, :not_an_approver} = Social.approve_post(ctx.org_id, post, ctx.n.id)
      assert {row_snapshot(post), card_snapshot(card), Fake.calls()} == {bp, bc, []}

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h2)
    end

    test "an archived approver: refused :approver_archived; the other approver succeeds", ctx do
      {post, card} = pending_post!(ctx, ctx.a)
      {:ok, _} = Platform.Accounts.archive_user(ctx.h1)
      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :approver_archived} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert {:error, :approver_archived} = Social.approve_post(ctx.org_id, post, ctx.h1.id)
      assert {row_snapshot(post), card_snapshot(card), Fake.calls()} == {bp, bc, []}

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h2)
    end

    test "an approver whose access was removed: refused :approver_no_access; the other succeeds",
         ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      Repo.delete_all(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^ctx.h1.id and m.org_id == ^ctx.org_id
        )
      )

      {bp, bc} = {row_snapshot(post), card_snapshot(card)}
      assert {:error, :approver_no_access} = Approvals.decide_approve(card.canvas_id, ctx.h1)
      assert {:error, :approver_no_access} = Social.approve_post(ctx.org_id, post, ctx.h1.id)
      assert {row_snapshot(post), card_snapshot(card), Fake.calls()} == {bp, bc, []}

      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h2)
    end
  end

  describe "(c) reject keeps the reason and leaves the post unpublished" do
    test "rejected with its reason, never published; a resubmitted draft can then be approved",
         ctx do
      {post, card} = pending_post!(ctx, ctx.a)

      assert {:ok, %{post: rejected}} =
               Approvals.decide_reject(card.canvas_id, ctx.h1, "Too salesy, cut the last line")

      row = Repo.get!(Post, post.id)
      assert row.rejection_reason == "Too salesy, cut the last line"
      assert %DateTime{} = row.rejected_at
      assert row.status == "draft"
      assert row.approved_by_user_id == nil
      assert Post.rejected?(rejected)
      assert Fake.calls(:publish) == []

      # The drafting agent revises and resubmits; the new card can be approved.
      {:ok, _} =
        Social.AgentDrafts.update_agent_draft({:tenant, ctx.org_id}, post.id, %{
          "body" => "Episode 12 is out.",
          "status" => "needs_approval"
        })

      new_card = live_card!(row)
      assert new_card.id != card.id
      assert {:ok, _} = Approvals.decide_approve(new_card.canvas_id, ctx.h2)
      assert length(Fake.calls(:publish)) == 1
    end
  end
end
