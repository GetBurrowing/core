defmodule Platform.Social.IdeaAgentVotesTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  alias Platform.Social.{Ideas, IdeaVote, IdeaVotes}
  alias Platform.Federation.ToolArguments

  test "human vote and withdrawal are refused without changing historical votes" do
    w = approval_fixture()
    {:ok, idea} = Ideas.create(w.org_id, w.profile.id, %{title: "Keep history"}, {:agent, w.g.id})

    old =
      Repo.insert!(%IdeaVote{
        idea_id: idea.id,
        org_id: w.org_id,
        profile_id: w.profile.id,
        voter_user_id: w.n.id
      })

    assert {:error, :agent_only} = IdeaVotes.vote(w.org_id, idea.id, {:user, w.h1.id})
    assert {:error, :agent_only} = IdeaVotes.unvote(w.org_id, idea.id, {:user, w.n.id})
    assert Repo.all(IdeaVote) == [old]
  end

  test "historical human rows do not count, shortlist or change an agent tool result" do
    w = approval_fixture()

    {:ok, idea} =
      Ideas.create(w.org_id, w.profile.id, %{title: "Agent interest"}, {:agent, w.g.id})

    for user <- [w.h1, w.h2, w.n] do
      Repo.insert!(%IdeaVote{
        idea_id: idea.id,
        org_id: w.org_id,
        profile_id: w.profile.id,
        voter_user_id: user.id
      })
    end

    assert %{vote_count: 0, voted: false} = IdeaVotes.summaries([idea], {:user, w.n.id})[idea.id]

    assert [%{lane: "inbox", vote_count: 0}] =
             Platform.Social.IdeaBoard.cards([w.profile], w.n.id)

    voter = pinned_agent!(w.org_id)

    assert {:ok, %{vote_count: 1, voted: true}} =
             ToolArguments.dispatch("social_idea_vote", %{"idea_id" => idea.id}, %{
               agent_id: voter.id
             })

    assert %{vote_count: 1} = IdeaVotes.summaries([idea])[idea.id]

    assert {:ok, %{vote_count: 0, voted: false}} =
             ToolArguments.dispatch("social_idea_unvote", %{"idea_id" => idea.id}, %{
               agent_id: voter.id
             })

    assert Repo.aggregate(IdeaVote, :count) == 3
  end
end
