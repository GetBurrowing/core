defmodule Platform.Social.ApprovalDeadlineTest do
  use Platform.DataCase, async: false

  import Platform.SocialApprovalFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Approvals, Post, PostEvents, RateLimit}
  alias Platform.Social.Publisher.Fake
  alias Platform.SocialApprovalWriteProbe, as: Writes

  setup do
    Fake.reset()
    RateLimit.reset()
    approval_fixture()
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -3600)
  defp future, do: DateTime.add(DateTime.utc_now(), 3600)

  defp historical_pending!(ctx, account, attrs) do
    {post, card} = pending_post!(ctx, account)
    {Repo.update!(Ecto.Changeset.change(post, attrs)), card}
  end

  defp untouched(post, card, before_post, before_card, before_events) do
    assert Repo.get!(Post, post.id) == before_post
    assert Repo.get!(ApprovalCard, card.id) == before_card
    assert PostEvents.list_for_post(post.id) == before_events
    assert Fake.calls(:publish) == []
  end

  test "ordinary overdue approval refuses without deciding, approving or publishing", ctx do
    {post, card} = historical_pending!(ctx, ctx.a, %{scheduled_at: past()})
    before_post = Repo.get!(Post, post.id)
    before_card = Repo.get!(ApprovalCard, card.id)
    before_events = PostEvents.list_for_post(post.id)

    assert {{:error, :slot_passed}, queries} =
             Writes.capture(fn ->
               Approvals.decide_approve(card.canvas_id, ctx.h1, Approvals.fingerprint(post))
             end)

    assert queries == []

    untouched(post, card, before_post, before_card, before_events)
  end

  test "a direct approval cannot bypass an expired scheduled draft", ctx do
    {:ok, post} =
      Social.create_post(ctx.org_id, ctx.a, %{body: "Timed draft", scheduled_at: past()})

    before = Repo.get!(Post, post.id)
    assert {:error, :slot_passed} = Social.approve_post(ctx.org_id, post, ctx.h1.id)
    assert Repo.get!(Post, post.id) == before
    assert Fake.calls(:publish) == []
  end

  test "a historical untimed approval now requires an explicit publish time", ctx do
    {post, card} = historical_pending!(ctx, ctx.a, %{scheduled_at: nil})

    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Approvals.decide_approve(card.canvas_id, ctx.h1, Approvals.fingerprint(post))

    assert Fake.calls(:publish) == []
    assert Repo.get!(Post, post.id) == post
    assert Repo.get!(ApprovalCard, card.id) == card
  end

  test "future stored time still approves and invokes the publisher", ctx do
    {post, card} = pending_post!(ctx, ctx.a, %{scheduled_at: future()})

    assert {{:ok, _}, queries} =
             Writes.capture(fn ->
               Approvals.decide_approve(card.canvas_id, ctx.h1, Approvals.fingerprint(post))
             end)

    assert Enum.any?(queries, &String.starts_with?(&1, ~s(UPDATE "social_approval_cards")))
    assert Enum.any?(queries, &String.starts_with?(&1, ~s(UPDATE "social_posts")))
    assert Enum.any?(queries, &String.starts_with?(&1, ~s(INSERT INTO "social_post_events")))

    assert length(Fake.calls(:publish)) == 1
  end

  test "a human can replace a missed time explicitly with a future one", ctx do
    {post, card} = historical_pending!(ctx, ctx.a, %{scheduled_at: past()})
    at = future()

    assert {:ok, %{post: approved}} =
             Approvals.decide_approve_at(card.canvas_id, ctx.h1, Approvals.fingerprint(post), at)

    assert DateTime.compare(approved.scheduled_at, at) == :eq
    assert length(Fake.calls(:publish)) == 1
  end

  test "an agent cannot move or clear a missed deadline", ctx do
    {post, card} = historical_pending!(ctx, ctx.a, %{scheduled_at: past()})
    before_post = Repo.get!(Post, post.id)
    before_card = Repo.get!(ApprovalCard, card.id)
    before_events = PostEvents.list_for_post(post.id)

    for attrs <- [
          %{"scheduled_at" => future()},
          %{"scheduled_at" => ""},
          %{"scheduled_at" => nil}
        ] do
      assert {:error, :human_retime_required} =
               AgentDrafts.update_agent_draft({:tenant, ctx.org_id}, post.id, attrs,
                 agent_id: ctx.g.id
               )

      untouched(post, card, before_post, before_card, before_events)
    end
  end

  test "agent body edits preserve a missed deadline and cannot hide it in draft", ctx do
    {post, _card} = historical_pending!(ctx, ctx.a, %{scheduled_at: past()})

    assert {:ok, edited} =
             AgentDrafts.update_agent_draft(
               {:tenant, ctx.org_id},
               post.id,
               %{"body" => "Corrected caption"},
               agent_id: ctx.g.id
             )

    assert edited.scheduled_at == post.scheduled_at
    assert edited.status == "needs_approval"

    assert {:error, _} =
             AgentDrafts.update_agent_draft(
               {:tenant, ctx.org_id},
               post.id,
               %{"status" => "draft"},
               agent_id: ctx.g.id
             )

    assert Repo.get!(Post, post.id).scheduled_at == post.scheduled_at
  end

  test "ordinary future-item agent retiming remains available", ctx do
    {post, _card} = pending_post!(ctx, ctx.a, %{scheduled_at: future()})
    at = DateTime.add(future(), 3600)

    assert {:ok, updated} =
             AgentDrafts.update_agent_draft(
               {:tenant, ctx.org_id},
               post.id,
               %{"scheduled_at" => at},
               agent_id: ctx.g.id
             )

    assert DateTime.compare(updated.scheduled_at, at) == :eq
  end

  test "a human rejection does not let an agent erase the original missed time", ctx do
    {post, card} = historical_pending!(ctx, ctx.a, %{scheduled_at: past()})

    assert {:ok, _} =
             Approvals.decide_reject(
               card.canvas_id,
               ctx.h1,
               "Revise the caption",
               Approvals.fingerprint(post)
             )

    assert Repo.get!(Post, post.id).status == "draft"

    assert {:error, :human_retime_required} =
             AgentDrafts.update_agent_draft(
               {:tenant, ctx.org_id},
               post.id,
               %{"scheduled_at" => future()},
               agent_id: ctx.g.id
             )

    assert Repo.get!(Post, post.id).scheduled_at == post.scheduled_at
  end
end
