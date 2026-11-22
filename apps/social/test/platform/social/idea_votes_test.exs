defmodule Platform.Social.IdeaVotesTest do
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Social.{Ideas, Post}

  setup do
    ctx = approval_fixture()
    project = project!(ctx.org_id)
    profile = Repo.update!(Ecto.Changeset.change(ctx.profile, project_id: project.id))
    ctx = %{ctx | profile: profile}

    {:ok, idea} =
      Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Discuss this"}, {:agent, ctx.g.id})

    Map.merge(ctx, %{idea: idea, voter: pinned_agent!(ctx.org_id)})
  end

  defp call(tool, idea, agent) do
    ToolArguments.dispatch(tool, %{"idea_id" => idea.id}, agent_context(agent, idea.org_id))
  end

  defp agent_context(agent, org_id) do
    import Ecto.Query

    owner_id =
      Repo.one!(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.org_id == ^org_id and m.role == "member",
          order_by: [asc: m.inserted_at],
          limit: 1,
          select: m.user_id
        )
      )

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "idea-vote-test-#{System.unique_integer([:positive])}",
        agent_id: agent.id,
        owner_user_id: owner_id,
        status: "active"
      })

    {:ok, _} = Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social"], nil)
    %{agent_id: agent.id, runtime_id: runtime.runtime_id}
  end

  test "repeat votes and withdrawals are idempotent through the real agent tool", ctx do
    assert {:ok, %{idea_id: id, vote_count: 1, voted: true}} =
             call("social_idea_vote", ctx.idea, ctx.voter)

    assert id == ctx.idea.id
    assert {:ok, %{vote_count: 1, voted: true}} = call("social_idea_vote", ctx.idea, ctx.voter)
    assert {:ok, %{vote_count: 0, voted: false}} = call("social_idea_unvote", ctx.idea, ctx.voter)
    assert {:ok, %{vote_count: 0, voted: false}} = call("social_idea_unvote", ctx.idea, ctx.voter)
  end

  test "self, archived and other-org ideas refuse without revealing votes", ctx do
    assert {:error, %{code: :own_idea}} = call("social_idea_vote", ctx.idea, ctx.g)
    outsider = pinned_agent!(org_id!())
    assert {:error, %{code: :not_found}} = call("social_idea_vote", ctx.idea, outsider)
    assert {:error, %{code: :not_found}} = call("social_idea_unvote", ctx.idea, outsider)
    assert {:ok, _} = Ideas.archive(ctx.org_id, ctx.idea.id)
    assert {:error, %{code: :idea_archived}} = call("social_idea_vote", ctx.idea, ctx.voter)
    assert {:error, %{code: :idea_archived}} = call("social_idea_unvote", ctx.idea, ctx.voter)
  end

  test "only the actual creator can archive and any linked post refuses", ctx do
    assert {:error, %{code: :not_idea_author}} = call("social_idea_archive", ctx.idea, ctx.voter)

    {:ok, post} =
      Platform.Social.create_post(ctx.org_id, ctx.a, %{body: "draft", idea_id: ctx.idea.id})

    post = Repo.update!(Ecto.Changeset.change(post, idea_id: ctx.idea.id))
    assert {:error, %{code: :idea_has_posts}} = call("social_idea_archive", ctx.idea, ctx.g)
    assert Repo.get!(Post, post.id).idea_id == ctx.idea.id
    Repo.delete!(post)
    assert {:ok, %{idea_id: id, archived: true}} = call("social_idea_archive", ctx.idea, ctx.g)
    assert id == ctx.idea.id
  end

  test "three votes shortlist, withdrawal restores inbox, posts keep their stage", ctx do
    voters = for _ <- 1..3, do: pinned_agent!(ctx.org_id)

    for voter <- voters do
      assert {:ok, _} =
               Platform.Social.IdeaVotes.vote(ctx.org_id, ctx.idea.id, {:agent, voter.id})
    end

    {:ok, %{ideas: rows}} =
      ToolArguments.dispatch(
        "social_idea_list",
        %{"profile_id" => ctx.profile.id},
        agent_context(ctx.voter, ctx.org_id)
      )

    assert [%{stage: "shortlisted", vote_count: 3, voted: false}] = rows
    refute Map.has_key?(hd(rows), :voter_names)

    assert [%{lane: "shortlisted", vote_count: 3}] =
             Platform.Social.IdeaBoard.cards([ctx.profile], ctx.n.id)

    assert {:ok, _} =
             Platform.Social.IdeaVotes.unvote(
               ctx.org_id,
               ctx.idea.id,
               {:agent, List.last(voters).id}
             )

    assert [%{lane: "inbox", vote_count: 2}] =
             Platform.Social.IdeaBoard.cards([ctx.profile], ctx.n.id)

    {:ok, post} =
      Platform.Social.create_post(ctx.org_id, ctx.a, %{body: "draft", idea_id: ctx.idea.id})

    Repo.update!(Ecto.Changeset.change(post, idea_id: ctx.idea.id))

    assert {:ok, _} =
             Platform.Social.IdeaVotes.vote(
               ctx.org_id,
               ctx.idea.id,
               {:agent, List.last(voters).id}
             )

    assert [%{lane: "drafting", vote_count: 3}] =
             Platform.Social.IdeaBoard.cards([ctx.profile], ctx.n.id)
  end

  test "human actions refuse and current agent status is checked on vote and withdrawal", ctx do
    actor = {:user, ctx.n.id}
    assert {:error, :agent_only} = Platform.Social.IdeaVotes.vote(ctx.org_id, ctx.idea.id, actor)
    import Ecto.Query
    Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^ctx.n.id))
    assert {:error, :agent_only} = Platform.Social.IdeaVotes.unvote(:root, ctx.idea.id, actor)
    assert {:error, :agent_only} = Platform.Social.IdeaVotes.vote(:root, ctx.idea.id, actor)
    Repo.update!(Ecto.Changeset.change(ctx.voter, status: "archived"))
    assert {:error, %{code: :not_found}} = call("social_idea_vote", ctx.idea, ctx.voter)
    assert {:error, %{code: :not_found}} = call("social_idea_unvote", ctx.idea, ctx.voter)
  end

  test "historical human votes stay private and do not count after membership loss", ctx do
    Repo.insert!(%Platform.Social.IdeaVote{
      idea_id: ctx.idea.id,
      profile_id: ctx.profile.id,
      org_id: ctx.org_id,
      voter_user_id: ctx.n.id
    })

    import Ecto.Query
    Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^ctx.n.id))

    {:ok, %{ideas: [idea]}} =
      ToolArguments.dispatch(
        "social_idea_list",
        %{"profile_id" => ctx.profile.id},
        agent_context(ctx.voter, ctx.org_id)
      )

    assert idea.vote_count == 0
    refute Map.has_key?(idea, :voter_names)
    refute inspect(idea) =~ ctx.n.email
  end

  test "inbox and shortlist ties use oldest time then id, with counts first", ctx do
    {:ok, second} =
      Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Second"}, {:agent, ctx.g.id})

    time = DateTime.add(DateTime.utc_now(), -600, :second)
    Repo.update!(Ecto.Changeset.change(ctx.idea, inserted_at: time))
    Repo.update!(Ecto.Changeset.change(second, inserted_at: time))

    assert Enum.map(Platform.Social.IdeaBoard.cards([ctx.profile], ctx.n.id), & &1.id) ==
             Enum.sort([ctx.idea.id, second.id])

    assert {:ok, _} =
             Platform.Social.IdeaVotes.vote(ctx.org_id, second.id, {:agent, ctx.voter.id})

    assert Enum.map(Platform.Social.IdeaBoard.cards([ctx.profile], ctx.n.id), & &1.id) == [
             second.id,
             ctx.idea.id
           ]
  end

  test "malformed idea IDs and an unauthenticated tool call do not query an unscoped idea", ctx do
    for id <- [nil, "bad-id", 12] do
      assert {:error, :not_found} =
               Platform.Social.IdeaVotes.vote(:root, id, {:agent, ctx.voter.id})

      assert {:error, :agent_only} =
               Platform.Social.IdeaVotes.unvote(:root, id, {:user, ctx.n.id})

      assert {:error, :not_found} =
               Platform.Social.IdeaVotes.archive(:root, id, {:agent, ctx.g.id})
    end

    assert {:error, %{code: :no_agent}} =
             ToolArguments.dispatch("social_idea_vote", %{"idea_id" => ctx.idea.id}, %{})
  end

  test "human self-votes refuse; a live root-scoped agent still uses the existing visibility policy",
       ctx do
    {:ok, own} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Mine"}, {:user, ctx.n.id})

    assert {:error, :agent_only} =
             Platform.Social.IdeaVotes.vote(:root, own.id, {:user, ctx.n.id})

    assert {:error, :agent_only} =
             Platform.Social.IdeaVotes.unvote(:root, own.id, {:user, ctx.n.id})

    root =
      Platform.Repo.one!(
        Ecto.Query.from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)
      )

    root_agent = pinned_agent!(root.id)
    assert {:ok, %{vote_count: 1}} = call("social_idea_vote", ctx.idea, root_agent)
  end

  test "revoked agent org and invalid pinned org cannot use an earlier scope", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.voter, metadata: %{"org_id" => org_id!()}))

    assert {:error, :not_found} =
             Platform.Social.IdeaVotes.vote(ctx.org_id, ctx.idea.id, {:agent, ctx.voter.id})

    Repo.update!(Ecto.Changeset.change(ctx.voter, metadata: %{"org_id" => "invalid"}))

    assert {:error, :not_found} =
             Platform.Social.IdeaVotes.unvote(ctx.org_id, ctx.idea.id, {:agent, ctx.voter.id})
  end

  test "agent archive refuses a Studio-linked post too and does not mutate it", ctx do
    {:ok, post} = Platform.Social.create_post(ctx.org_id, ctx.a, %{body: "Studio draft"})
    post = Repo.update!(Ecto.Changeset.change(post, flow: "studio", idea_id: ctx.idea.id))
    assert {:error, %{code: :idea_has_posts}} = call("social_idea_archive", ctx.idea, ctx.g)
    assert Repo.get!(Post, post.id) == post
    assert is_nil(Ideas.get(ctx.org_id, ctx.idea.id).archived_at)
  end

  test "deleting the idea removes only its votes", ctx do
    {:ok, other} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Other"}, {:agent, ctx.g.id})
    assert {:ok, _} = call("social_idea_vote", ctx.idea, ctx.voter)
    assert {:ok, _} = call("social_idea_vote", other, ctx.voter)
    Repo.delete!(ctx.idea)
    import Ecto.Query

    assert Repo.aggregate(
             from(v in Platform.Social.IdeaVote, where: v.idea_id == ^ctx.idea.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(v in Platform.Social.IdeaVote, where: v.idea_id == ^other.id),
             :count
           ) == 1
  end

  for actors <- [:none, :both] do
    @actors actors
    test "database refuses #{@actors} actor identities", ctx do
      vote = %Platform.Social.IdeaVote{
        idea_id: ctx.idea.id,
        org_id: ctx.org_id,
        profile_id: ctx.profile.id
      }

      vote =
        if @actors == :both,
          do: %{vote | voter_user_id: ctx.n.id, voter_agent_id: ctx.voter.id},
          else: vote

      assert_raise Ecto.ConstraintError, ~r/social_idea_votes_one_actor/, fn ->
        Repo.insert!(vote)
      end
    end
  end

  test "a user denied Social can neither withdraw nor appear in voter names", ctx do
    Repo.insert!(%Platform.Social.IdeaVote{
      idea_id: ctx.idea.id,
      profile_id: ctx.profile.id,
      org_id: ctx.org_id,
      voter_user_id: ctx.n.id
    })

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.n.id},
               permission: "social",
               resource: {:module, ctx.org_id}
             })

    assert {:error, :agent_only} =
             Platform.Social.IdeaVotes.unvote(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

    {:ok, %{ideas: [idea]}} =
      ToolArguments.dispatch(
        "social_idea_list",
        %{"profile_id" => ctx.profile.id},
        agent_context(ctx.voter, ctx.org_id)
      )

    assert idea.vote_count == 0
    refute Map.has_key?(idea, :voter_names)
  end

  test "vote summaries disclose only count and the current actor's vote", ctx do
    assert {:ok, _} = call("social_idea_vote", ctx.idea, ctx.voter)
    summary = Platform.Social.IdeaVotes.summaries([ctx.idea], {:agent, ctx.voter.id})[ctx.idea.id]
    assert Enum.sort(Map.keys(summary)) == [:vote_count, :voted]
    assert summary == %{vote_count: 1, voted: true}
  end
end
