defmodule PlatformWeb.SocialAgentOnlyVotingTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  alias Platform.Social.{Ideas, IdeaVote, IdeaVotes}

  test "people see agent counts without vote controls and forged vote/withdraw events do nothing",
       %{conn: conn} do
    w = approval_fixture()

    {:ok, idea} =
      Ideas.create(w.org_id, w.profile.id, %{title: "Agent voted idea"}, {:agent, w.g.id})

    old =
      Platform.Repo.insert!(%IdeaVote{
        idea_id: idea.id,
        org_id: w.org_id,
        profile_id: w.profile.id,
        voter_user_id: w.n.id
      })

    voter = pinned_agent!(w.org_id)
    assert {:ok, _} = IdeaVotes.vote(w.org_id, idea.id, {:agent, voter.id})

    {:ok, parent, _} =
      conn
      |> Plug.Test.init_test_session(current_user_id: w.n.id)
      |> live("/m/social?tab=ideas&profile=#{w.profile.id}")

    view = find_live_child(parent, "ext-page-social")
    assert has_element?(view, "[data-role='idea-vote-count']", "1 agent vote")
    refute has_element?(view, "[data-role='idea-vote']")
    refute has_element?(view, "[data-role='idea-unvote']")

    for action <- ["vote", "unvote"] do
      render_click(view, "ideas_vote", %{"id" => idea.id, "action" => action})
      assert has_element?(view, "[role='status']", "Only agents can vote")
      assert Platform.Repo.get(IdeaVote, old.id) == old
      assert Platform.Repo.aggregate(IdeaVote, :count) == 2
    end

    view |> element("[data-role='idea-card-open'][phx-value-id='#{idea.id}']") |> render_click()
    assert has_element?(view, "[data-role='idea-detail-votes']", "1 agent vote")
    refute has_element?(view, "[data-role='idea-detail-voted']")
  end
end
