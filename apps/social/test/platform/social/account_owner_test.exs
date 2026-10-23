defmodule Platform.Social.AccountOwnerTest do
  @moduledoc """
  The account owner rule (task 01a14ce1, stage 1): on an account with an
  `owner_user_id`, only that user may approve, edit or reject its posts, on
  every path (the card's decide_* transaction, `Social.approve_post/4`
  called directly, the fan-out and the card view). An unowned account keeps
  the profile-approver rule. The one exception: once the owner is archived
  or gone, a profile approver may REJECT (never approve or edit), so a post
  is not stranded.

  `async: false`: the Fake's call log is a global table.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Inbox.Item
  alias Platform.Social
  alias Platform.Social.{Account, Approvals, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()

    # The owner is an org member in the channel but NOT on the profile's
    # approver list: ownership alone is what lets them decide.
    owner = named_user!("Omar Owner")
    member!(owner, ctx.org_id)
    join!(ctx.space.id, :user, owner.id)

    {:ok, owned} = Social.set_account_owner(ctx.org_id, ctx.a, owner.id)
    {post, card} = pending_post!(ctx, owned)

    Map.merge(ctx, %{owner: owner, owned: owned, post: post, card: card})
  end

  defp items(user, post) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and i.source_id == ^post.id and i.kind == "social_post_approval"
      )
    )
  end

  defp snapshot(ctx), do: {row_snapshot(ctx.post), card_snapshot(ctx.card)}

  defp assert_untouched(ctx, before) do
    assert snapshot(ctx) == before
    assert Fake.calls(:publish) == []
  end

  describe "the column" do
    test "is never cast from attrs; Social sets it", ctx do
      {:ok, acct} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "linkedin",
          owner_user_id: ctx.owner.id
        })

      assert acct.owner_user_id == nil

      {:ok, acct} =
        Social.update_account(ctx.org_id, acct, %{owner_user_id: ctx.owner.id})

      assert Repo.get!(Account, acct.id).owner_user_id == nil
      assert Repo.get!(Account, ctx.owned.id).owner_user_id == ctx.owner.id

      {:ok, cleared} = Social.set_account_owner(ctx.org_id, ctx.owned, nil)
      assert cleared.owner_user_id == nil
    end

    test "an id that is not a users row is refused", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Social.set_account_owner(ctx.org_id, ctx.a, ctx.g.id)

      assert cs.errors[:owner_user_id]
    end
  end

  describe "an owned account" do
    test "the owner approves through the card and the post publishes once", ctx do
      assert {:ok, %{post: post}} = Approvals.decide_approve(ctx.card.canvas_id, ctx.owner)
      assert {post.status, post.approved_by_user_id} == {"scheduled", ctx.owner.id}
      assert [{:publish, _, _}] = Fake.calls(:publish)
    end

    test "the owner approves through a direct context call", ctx do
      assert {:ok, post} = Social.approve_post(ctx.org_id, ctx.post, ctx.owner.id)
      assert post.approved_by_user_id == ctx.owner.id
    end

    test "only the owner gets the inbox row and the approver view", ctx do
      assert [_] = items(ctx.owner, ctx.post)
      assert items(ctx.h1, ctx.post) == []
      assert items(ctx.h2, ctx.post) == []

      owner_view = Approvals.card_view(ctx.card.id, {:user, ctx.owner.id})
      assert owner_view.role == :approver
      assert owner_view.actions == [:approve, :edit, :reject]

      # Stage 3: a profile approver now sees the post read-only and waits.
      h1_view = Approvals.card_view(ctx.card.id, {:user, ctx.h1.id})
      assert h1_view.role == :waiting
      assert h1_view.actions == []
      assert h1_view.owner_name == "Omar"

      n_view = Approvals.card_view(ctx.card.id, {:user, ctx.n.id})
      assert n_view.role == :viewer
      refute Map.has_key?(n_view, :body)
    end

    test "a profile approver is refused :not_the_owner on decide_approve/edit/reject", ctx do
      before = snapshot(ctx)
      fp = Approvals.card_view(ctx.card.id, {:user, ctx.owner.id}).fingerprint

      assert {:error, :not_the_owner} = Approvals.decide_approve(ctx.card.canvas_id, ctx.h1, fp)

      assert {:error, :not_the_owner} =
               Approvals.decide_edit(ctx.card.canvas_id, ctx.h1, %{body: "Hijacked"}, fp)

      assert {:error, :not_the_owner} =
               Approvals.decide_reject(ctx.card.canvas_id, ctx.h1, "Not mine to say", fp)

      assert_untouched(ctx, before)
    end

    test "a profile approver is refused :not_the_owner on a direct approve_post call", ctx do
      before = snapshot(ctx)
      assert {:error, :not_the_owner} = Social.approve_post(ctx.org_id, ctx.post, ctx.h1.id)
      assert_untouched(ctx, before)
    end

    test "post_approver_check/4 names the refusal; approver_check/3 still passes", ctx do
      assert :ok = Social.approver_check(ctx.org_id, ctx.profile, ctx.h1.id)

      assert {:error, :not_the_owner} =
               Social.post_approver_check(ctx.org_id, ctx.profile, ctx.owned, ctx.h1.id)

      assert :ok = Social.post_approver_check(ctx.org_id, ctx.profile, ctx.owned, ctx.owner.id)
    end

    test "an agent id is refused", ctx do
      before = snapshot(ctx)

      assert {:error, :not_a_human} =
               Social.post_approver_check(ctx.org_id, ctx.profile, ctx.owned, ctx.g.id)

      assert {:error, :not_a_human} = Approvals.decide_approve(ctx.card.canvas_id, ctx.g.id)

      assert {:error, %Ecto.Changeset{} = cs} =
               Social.approve_post(ctx.org_id, ctx.post, ctx.g.id)

      assert {_, opts} = cs.errors[:approved_by_user_id]
      assert opts[:reason] == :not_a_human
      assert Approvals.card_view(ctx.card.id, {:agent, ctx.g.id}).role == :viewer
      assert_untouched(ctx, before)
    end

    test "an owner who lost org access is refused :approver_no_access", ctx do
      Repo.delete_all(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^ctx.owner.id and m.org_id == ^ctx.org_id
        )
      )

      before = snapshot(ctx)

      assert {:error, :approver_no_access} =
               Approvals.decide_approve(ctx.card.canvas_id, ctx.owner)

      assert_untouched(ctx, before)
    end
  end

  describe "an owned account whose owner is archived" do
    setup ctx do
      {:ok, _} = Platform.Accounts.archive_user(ctx.owner)
      :ok
    end

    test "the owner is refused :approver_archived on every path", ctx do
      before = snapshot(ctx)

      assert {:error, :approver_archived} =
               Approvals.decide_approve(ctx.card.canvas_id, ctx.owner)

      assert {:error, :approver_archived} =
               Social.approve_post(ctx.org_id, ctx.post, ctx.owner.id)

      assert {:error, :approver_archived} =
               Social.post_approver_check(ctx.org_id, ctx.profile, ctx.owned, ctx.owner.id)

      assert_untouched(ctx, before)
    end

    test "no fallback: a profile approver still may not approve or edit", ctx do
      before = snapshot(ctx)
      fp = Approvals.fingerprint(Repo.get!(Post, ctx.post.id))

      assert {:error, :not_the_owner} = Approvals.decide_approve(ctx.card.canvas_id, ctx.h1, fp)

      assert {:error, :not_the_owner} =
               Approvals.decide_edit(ctx.card.canvas_id, ctx.h1, %{body: "Hijacked"}, fp)

      assert {:error, :not_the_owner} = Social.approve_post(ctx.org_id, ctx.post, ctx.h1.id)
      assert_untouched(ctx, before)
    end

    test "a profile approver may reject, so the post is not stranded", ctx do
      view = Approvals.card_view(ctx.card.id, {:user, ctx.h1.id})
      assert view.actions == [:reject]

      assert {:ok, %{post: post}} =
               Approvals.decide_reject(
                 ctx.card.canvas_id,
                 ctx.h1,
                 "Owner has left",
                 view.fingerprint
               )

      assert {post.status, post.rejection_reason} == {"draft", "Owner has left"}
      assert Fake.calls(:publish) == []
    end

    test "a non-approver still may not reject", ctx do
      before = snapshot(ctx)
      fp = Approvals.fingerprint(Repo.get!(Post, ctx.post.id))

      assert {:error, :not_an_approver} =
               Approvals.decide_reject(ctx.card.canvas_id, ctx.n, "Not mine", fp)

      assert_untouched(ctx, before)
    end
  end

  describe "an unowned account" do
    test "is unchanged: any profile approver approves, a non-approver is refused", ctx do
      {:ok, unowned} =
        Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@htc_x"})

      {post, card} = pending_post!(ctx, unowned)
      assert Repo.get!(Account, unowned.id).owner_user_id == nil
      assert [_] = items(ctx.h1, post)
      assert [_] = items(ctx.h2, post)
      assert items(ctx.owner, post) == []

      assert {:error, :not_an_approver} = Social.approve_post(ctx.org_id, post, ctx.owner.id)
      assert {:error, :not_an_approver} = Approvals.decide_reject(card.canvas_id, ctx.n, "No")

      assert :ok = Social.post_approver_check(ctx.org_id, ctx.profile, unowned, ctx.h2.id)
      assert {:ok, approved} = Social.approve_post(ctx.org_id, post, ctx.h2.id)
      assert approved.approved_by_user_id == ctx.h2.id
    end
  end
end
