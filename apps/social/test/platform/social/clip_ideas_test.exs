defmodule Platform.Social.ClipIdeasTest do
  @moduledoc """
  Social authoring 2/11 (task 01a16c4e): `ClipDecisions.approve_clip/5`
  finds or creates ONE idea per clip (source_kind clip, the clip's title)
  and every post it writes joins it, each with a `created` and an
  `approved` change log entry naming the human. One approval still
  publishes. Not async: ClipPublish runs in its own process.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ClipPublish, Idea, Ideas, Post, PostEvents, RateLimit}
  alias Platform.Social.Publisher.Fake

  @publisher :clip_ideas_test_publish

  setup do
    Fake.reset()
    RateLimit.reset()
    w = render_world!()
    start_supervised!({ClipPublish, name: @publisher, interval_ms: :infinity, boot_sweep: false})
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{"file_id" => file.id, "title" => "Clip title", "caption" => "Clip caption"},
        w.agent.id
      )

    %{w: w, clip: clip, t0: DateTime.utc_now()}
  end

  defp approve(ctx) do
    Social.approve_clip(
      ctx.w.org_id,
      ctx.clip.id,
      ctx.w.approver.id,
      %{"account_ids" => [ctx.w.tiktok.id, ctx.w.x.id]},
      now: ctx.t0,
      publish_server: @publisher
    )
  end

  test "an approved clip's posts share one idea, and an undo + re-approve reuses it", ctx do
    assert {:ok, %{posts: [p1, p2]}} = approve(ctx)
    assert p1.idea_id != nil and p1.idea_id == p2.idea_id

    idea = Repo.get!(Idea, p1.idea_id)

    assert {idea.source_kind, idea.clip_id, idea.title, idea.profile_id} ==
             {"clip", ctx.clip.id, "Clip title", ctx.w.profile.id}

    assert idea.created_by_user_id == ctx.w.approver.id
    assert Ideas.stage(idea) == "scheduled"

    for p <- [p1, p2] do
      assert [{"created", "human"}, {"approved", "human"}] =
               p.id |> PostEvents.list_for_post() |> Enum.map(&{&1.action, &1.actor_kind})
    end

    assert {:ok, _} =
             Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, now: ctx.t0)

    assert {:ok, %{posts: [p3 | _]}} = approve(ctx)
    assert p3.idea_id == idea.id

    assert Repo.aggregate(from(i in Idea, where: i.clip_id == ^ctx.clip.id), :count) == 1
    assert Repo.aggregate(from(p in Post, where: p.idea_id == ^idea.id), :count) == 2
  end
end
