defmodule Platform.Social.StudioAgentDraftsTest do
  @moduledoc """
  Social Studio slice A: until slice B supplies versioned Studio edits,
  `AgentDrafts.update_agent_draft/4` REFUSES Studio posts (every status)
  rather than delegating to a save function that does not exist yet.
  """
  use Platform.DataCase, async: false

  import Platform.SocialStudioFixtures

  alias Platform.Social.{AgentDrafts, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  test "an agent cannot edit a Studio post in any status, and nothing is written", %{w: w} do
    for status <- ~w(draft needs_approval approved planned) do
      post = studio_post!(w, w.tiktok, status)
      before = Repo.get!(Post, post.id)
      events = Repo.aggregate(PostEvent, :count)

      assert {:error, :studio_post} =
               AgentDrafts.update_agent_draft(w.scope, post.id, %{"body" => "agent rewrite"},
                 agent_id: w.agent.id
               )

      assert Repo.get!(Post, post.id) == before
      assert Repo.aggregate(PostEvent, :count) == events
    end

    assert Fake.calls() == []
  end

  test "the approval stays current and the version stays put", %{w: w} do
    post = studio_post!(w, w.tiktok, "approved")

    assert {:error, :studio_post} =
             AgentDrafts.update_agent_draft(w.scope, post.id, %{"body" => "agent rewrite"})

    row = Repo.get!(Post, post.id)
    assert {row.status, row.version, row.body} == {"approved", 1, post.body}

    assert [%{state: "current"}] =
             Repo.all(Platform.Social.PostApproval) |> Enum.filter(&(&1.post_id == post.id))
  end

  test "a legacy draft still updates (control)", %{w: w} do
    {:ok, [post | _]} =
      AgentDrafts.create_agent_drafts(w.scope, w.profile.id, %{
        "body" => "legacy draft",
        "account_ids" => [w.x.id],
        "status" => "draft"
      })

    assert {:ok, %Post{body: "edited"}} =
             AgentDrafts.update_agent_draft(w.scope, post.id, %{"body" => "edited"})
  end
end
