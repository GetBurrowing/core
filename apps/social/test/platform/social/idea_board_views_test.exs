defmodule Platform.Social.IdeaBoardViewsTest do
  @moduledoc """
  `IdeaBoard.views/2`: the three views derived in memory from ONE idea list and
  ONE `IdeaVotes.summaries/2` call, with the same vote predicate as the agent API
  (agent votes on the idea's own profile and org).
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Social.{IdeaBoard, IdeaVote, IdeaVotes, Ideas}

  setup do
    approval_fixture() |> with_ideas_runtime()
  end

  defp idea!(ctx, title) do
    {:ok, idea} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: title}, {:agent, ctx.g.id})
    idea
  end

  defp insert_vote!(idea, attrs),
    do:
      Repo.insert!(
        struct(
          IdeaVote,
          Map.merge(%{idea_id: idea.id, org_id: idea.org_id, profile_id: idea.profile_id}, attrs)
        )
      )

  # The sources of every query `fun` runs.
  defp sources(fun) do
    id = "views-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      id,
      [:platform, :repo, :query],
      fn _, _, meta, _ -> send(me, {:q, meta.source}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    Stream.repeatedly(fn ->
      receive do
        {:q, source} -> {:ok, source}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.map(fn {:ok, source} -> source end)
  end

  test "the vote predicate is IdeaVotes.summaries': mismatched rows and human rows never count",
       ctx do
    {:ok, other} =
      Platform.Social.create_profile(ctx.org_id, %{
        name: "Other",
        space_id: ctx.space.id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, foreign_org_profile} = Platform.Social.create_profile(org_id!(), %{name: "Foreign"})

    real = idea!(ctx, "Real vote")
    cross_profile = idea!(ctx, "Cross profile")
    cross_org = idea!(ctx, "Cross org")
    human = idea!(ctx, "Human only")

    insert_vote!(real, %{voter_agent_id: pinned_agent!(ctx.org_id).id})

    insert_vote!(cross_profile, %{
      profile_id: other.id,
      voter_agent_id: pinned_agent!(ctx.org_id).id
    })

    insert_vote!(cross_org, %{
      org_id: foreign_org_profile.org_id,
      voter_agent_id: pinned_agent!(ctx.org_id).id
    })

    insert_vote!(human, %{voter_user_id: ctx.n.id})

    views = IdeaBoard.views([ctx.profile], ctx.n.id)
    assert Enum.map(views.voted, & &1.id) == [real.id]
    assert views.counts == %{"all" => 4, "voted" => 1, "selected" => 0}

    ideas = Enum.map(views.all, & &1.idea)
    summaries = IdeaVotes.summaries(ideas, {:user, ctx.n.id})

    assert Map.new(views.all, &{&1.id, &1.vote_count}) ==
             Map.new(summaries, fn {id, s} -> {id, s.vote_count} end)
  end

  test "the queries do not grow with the number of ideas, and votes are read once", ctx do
    for i <- 1..2, do: idea!(ctx, "i#{i}")
    two = sources(fn -> IdeaBoard.views([ctx.profile], ctx.h1.id) end)

    for i <- 3..14 do
      idea = idea!(ctx, "i#{i}")
      if rem(i, 3) == 0, do: insert_vote!(idea, %{voter_agent_id: pinned_agent!(ctx.org_id).id})
    end

    fourteen = sources(fn -> IdeaBoard.views([ctx.profile], ctx.h1.id) end)

    assert length(two) == length(fourteen)
    assert Enum.count(fourteen, &(&1 == "social_idea_votes")) == 1
    assert Enum.count(fourteen, &(&1 == "social_ideas")) == 1
    # The main-branch board read its lanes in 5 queries; three views need no more than 6.
    assert length(fourteen) <= 6
    refute "social_posts" in fourteen
  end

  test "selected is newest selection first and never reads votes for membership", ctx do
    a = idea!(ctx, "a")
    b = idea!(ctx, "b")
    {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, a.id, {:user, ctx.h1.id})
    Process.sleep(5)
    {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, b.id, {:user, ctx.n.id})

    views = IdeaBoard.views([ctx.profile], ctx.h1.id)
    assert Enum.map(views.selected, & &1.id) == [b.id, a.id]
    assert Enum.map(views.selected, & &1.selected_by_name) == [ctx.n.name, ctx.h1.name]
    assert views.voted == []
  end
end
