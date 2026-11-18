defmodule Platform.Social.StudioAgentDraftsTest do
  @moduledoc """
  Social Studio slice B: `AgentDrafts.update_agent_draft/4` delegates to
  `Studio.save_version/5` with an agent actor for a Studio post in `draft` and
  `needs_approval` (slice A refused every status). Approved and planned posts
  are `:post_locked`; the approval is never touched by an agent. Legacy
  posts run the unchanged legacy code.
  """
  use Platform.DataCase, async: false

  import Platform.SocialStudioFixtures

  alias Platform.Social.{AgentDrafts, Post, PostApproval, PostEvents}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  defp agent_update(w, post, attrs, opts \\ []),
    do:
      AgentDrafts.update_agent_draft(
        w.scope,
        post.id,
        attrs,
        Keyword.put_new(opts, :agent_id, w.agent.id)
      )

  test "an agent edit of a draft or needs_approval Studio post saves a version", %{w: w} do
    for status <- ~w(draft needs_approval) do
      post = studio_post!(w, w.tiktok, status)

      assert {:ok, %Post{} = saved} =
               agent_update(w, post, %{"body" => "agent rewrite #{status}"})

      assert {saved.body, saved.version, saved.status} == {"agent rewrite #{status}", 2, status}
      assert saved.state_rev == post.state_rev + 1

      assert actions(post) -- ~w(created submitted) == ~w(edited version_saved)

      events =
        Enum.filter(PostEvents.list_for_post(post.id), &(&1.action in ~w(edited version_saved)))

      assert Enum.all?(events, &(&1.actor_kind == "agent" and &1.actor_id == w.agent.id))
    end

    assert send_calls() == []
  end

  test "an agent cannot edit an approved or planned post and the approval stays current", %{w: w} do
    approved = studio_approve!(w, submitted_post!(w, w.x))
    planned = studio_plan!(w, studio_approve!(w, submitted_post!(w, w.tiktok)))
    before = write_counts()

    for post <- [approved, planned] do
      assert {:error, :post_locked} = agent_update(w, post, %{"body" => "agent rewrite"})
      assert fresh(post) == post
    end

    assert write_counts() == before
    assert [%{state: "current"}] = receipts(approved)
    assert [%PostApproval{state: "current"}] = receipts(planned)
  end

  test "content keys only: anything else an agent could cast on a legacy post is refused", %{w: w} do
    post = studio_post!(w, w.x, "needs_approval")
    before = write_counts()

    assert {:error, :field_not_allowed, keys} =
             agent_update(w, post, %{
               "body" => "x",
               "scheduled_at" => "2030-01-01T00:00:00Z",
               "task_id" => nil
             })

    assert Enum.sort(keys) == ["scheduled_at", "task_id"]
    assert {:error, :status_not_allowed} = agent_update(w, post, %{"status" => "draft"})

    assert {:error, :field_not_allowed, ["approved_by_user_id"]} =
             agent_update(w, post, %{"approved_by_user_id" => w.approver.id})

    assert write_counts() == before
  end

  test "status equal to the current one is tolerated; no change is a no-op ok", %{w: w} do
    post = studio_post!(w, w.x, "needs_approval")

    assert {:ok, %Post{version: 2}} =
             agent_update(w, post, %{"body" => "again", "status" => "needs_approval"})

    before = write_counts()
    current = fresh(post)
    assert {:ok, %Post{version: 2}} = agent_update(w, current, %{"body" => "again"})
    assert write_counts() == before
  end

  test "banned phrases still refuse an agent's text and nothing is written", %{w: w} do
    {:ok, _} =
      Platform.Social.update_profile(w.org_id, w.profile, %{voice: %{banned: ["leverage"]}})

    post = studio_post!(w, w.x, "needs_approval")
    before = write_counts()

    assert {:error, :banned_phrase, "leverage"} =
             agent_update(w, post, %{"body" => "We leverage synergy"})

    assert write_counts() == before
  end

  test "a disabled profile refuses the agent too", %{w: w} do
    post = studio_post!(w, w.x, "needs_approval")
    {:ok, _} = Platform.Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    assert {:error, :studio_disabled} = agent_update(w, post, %{"body" => "x"})
  end

  test "no approval card is created for the agent's edit", %{w: w} do
    post = studio_post!(w, w.x, "needs_approval")
    {:ok, _} = agent_update(w, post, %{"body" => "x"})
    assert Repo.aggregate(Platform.Social.ApprovalCard, :count) == 0
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
