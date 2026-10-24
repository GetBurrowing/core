defmodule Platform.Social.OwnerDmCardTest do
  @moduledoc """
  Task 01a14ce1, stage 3: an OWNED account's approval card is delivered to
  the owner's DM, not the profile's channel.

    * drafted by an agent: the agent's DM with the owner
      (`Platform.Chat.find_or_create_agent_dm/2`), posted by the agent;
    * otherwise: the owner's ONE Social DM (`Approvals.owner_dm/2`), posted
      by the Social system participant;
    * unowned: the profile's channel, unchanged.

  An owned account needs no profile channel, there is ONE live card per
  post, and the inbox row goes to the owner only. `async: false`: the
  Fake's call log is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Chat
  alias Platform.Inbox.Item
  alias Platform.Social
  alias Platform.Social.{Approvals, ApprovalCard, OwnerDm, Profile, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    owner = named_user!("Omar Owner")
    member!(owner, ctx.org_id)
    {:ok, owned} = Social.set_account_owner(ctx.org_id, ctx.a, owner.id)
    Map.merge(ctx, %{owner: owner, owned: owned})
  end

  defp card_space(%ApprovalCard{message_id: message_id}),
    do: Repo.get!(Chat.Message, message_id).space_id

  defp sender(%ApprovalCard{message_id: message_id}) do
    message = Repo.get!(Chat.Message, message_id)
    Repo.get!(Chat.Participant, message.participant_id)
  end

  defp roster(space_id),
    do:
      space_id |> Chat.list_participants() |> Enum.map(&{&1.participant_type, &1.participant_id})

  defp items(user, post) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and i.source_id == ^post.id and i.kind == "social_post_approval"
      )
    )
  end

  describe "no drafting agent: the owner's Social DM" do
    test "the card is in a DM of the owner and the Social sender, not the channel", ctx do
      {_post, card} = pending_post!(ctx, ctx.owned)
      space_id = card_space(card)

      refute space_id == ctx.space.id
      space = Chat.get_space(space_id)
      assert {space.kind, space.is_direct} == {"dm", true}

      assert Enum.sort(roster(space_id)) ==
               Enum.sort([{"user", ctx.owner.id}, {"system", sender(card).participant_id}])

      assert sender(card).participant_type == "system"

      assert Repo.get_by!(OwnerDm, org_id: ctx.org_id, owner_user_id: ctx.owner.id).space_id ==
               space_id
    end

    test "two posts for one owner land in the SAME DM (canonical per owner)", ctx do
      {_p1, c1} = pending_post!(ctx, ctx.owned)
      {_p2, c2} = pending_post!(ctx, ctx.owned, %{body: "Second post"})

      assert card_space(c1) == card_space(c2)

      assert Repo.aggregate(from(d in OwnerDm, where: d.owner_user_id == ^ctx.owner.id), :count) ==
               1
    end

    test "owner_dm/2 is find-or-create and the table refuses a second row per owner", ctx do
      {:ok, s1} = Approvals.owner_dm(ctx.org_id, ctx.owner.id)
      {:ok, s2} = Approvals.owner_dm(ctx.org_id, ctx.owner.id)
      assert s1.id == s2.id

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%OwnerDm{org_id: ctx.org_id, owner_user_id: ctx.owner.id, space_id: s1.id})
      end
    end

    test "an archived DM is replaced, not reused", ctx do
      {:ok, s1} = Approvals.owner_dm(ctx.org_id, ctx.owner.id)
      s1 |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

      {_post, card} = pending_post!(ctx, ctx.owned)
      refute card_space(card) == s1.id
      assert {:ok, %{id: id}} = Approvals.owner_dm(ctx.org_id, ctx.owner.id)
      assert id == card_space(card)
    end
  end

  describe "drafted by an agent: the agent's DM with the owner" do
    test "the card is in find_or_create_agent_dm(agent, owner), posted by the agent", ctx do
      {_post, card} = pending_post!(ctx, ctx.owned, %{generated_by_agent_id: ctx.g.id})

      {:ok, dm} = Chat.find_or_create_agent_dm(ctx.g.id, ctx.owner.id)
      assert card_space(card) == dm.id
      refute card_space(card) == ctx.space.id
      assert {sender(card).participant_type, sender(card).participant_id} == {"agent", ctx.g.id}
    end

    test "two posts by the same agent for one owner land in the SAME agent DM", ctx do
      {_p1, c1} = pending_post!(ctx, ctx.owned, %{generated_by_agent_id: ctx.g.id})

      {_p2, c2} =
        pending_post!(ctx, ctx.owned, %{body: "Second post", generated_by_agent_id: ctx.g.id})

      assert card_space(c1) == card_space(c2)
    end
  end

  describe "unowned accounts are unchanged" do
    test "the card stays in the profile's channel, agent-drafted or not", ctx do
      {_p1, c1} = pending_post!(ctx, ctx.d)
      {_p2, c2} = pending_post!(ctx, ctx.d, %{body: "Agent", generated_by_agent_id: ctx.g.id})
      assert card_space(c1) == ctx.space.id
      assert card_space(c2) == ctx.space.id
    end

    test "a profile with no channel still refuses needs_approval on an unowned account", ctx do
      ctx.profile |> Ecto.Changeset.change(space_id: nil) |> Repo.update!()

      assert {:error, :profile_has_no_channel} =
               Social.create_post(ctx.org_id, ctx.d, %{body: "x", status: "needs_approval"})
    end
  end

  describe "require_channel takes the account" do
    test "an owned account needs no profile channel: the card goes to the owner's DM", ctx do
      ctx.profile |> Ecto.Changeset.change(space_id: nil) |> Repo.update!()
      assert Repo.get!(Profile, ctx.profile.id).space_id == nil

      {post, card} = pending_post!(ctx, ctx.owned)
      assert post.status == "needs_approval"
      assert {:ok, dm} = Approvals.owner_dm(ctx.org_id, ctx.owner.id)
      assert card_space(card) == dm.id
      assert [_] = items(ctx.owner, post)
    end

    test "require_channel/3 per account", ctx do
      nil_profile = %{ctx.profile | space_id: nil}
      assert :ok = Social.require_channel("needs_approval", nil_profile, ctx.owned)

      assert {:error, :profile_has_no_channel} =
               Social.require_channel("needs_approval", nil_profile, ctx.d)

      assert {:error, :profile_has_no_channel} =
               Social.require_channel("needs_approval", nil_profile)
    end
  end

  describe "one card, owner-only inbox" do
    test "the inbox row goes to the owner only, deep-linking into the Queue", ctx do
      {post, _card} = pending_post!(ctx, ctx.owned)

      assert [item] = items(ctx.owner, post)
      assert item.url == Platform.Social.Approvals.queue_url(post, ctx.profile)

      for approver <- [ctx.h1, ctx.h2, ctx.n],
          do: assert(items(approver, post) == [], "#{approver.name} got a row")
    end

    test "an agent re-edit re-renders the ONE live card in the DM, no second card", ctx do
      {post, card} = pending_post!(ctx, ctx.owned)
      {:ok, _} = Social.update_post(ctx.org_id, post, %{body: "Edited by the agent"})

      assert [only] = Repo.all(from(c in ApprovalCard, where: c.post_id == ^post.id))
      assert only.id == card.id
      assert [_] = items(ctx.owner, post)
    end

    test "a decision dismisses the owner's inbox row", ctx do
      {post, card} = pending_post!(ctx, ctx.owned)
      assert {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.owner)
      assert [%Item{} = item] = items(ctx.owner, post)
      assert item.dismissed_at
    end
  end
end
