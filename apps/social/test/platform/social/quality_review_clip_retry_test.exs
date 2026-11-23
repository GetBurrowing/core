defmodule Platform.Social.QualityReviewClipRetryTest do
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  alias Platform.Social

  alias Platform.Social.{
    AgentDrafts,
    ApprovalCard,
    Clip,
    ClipDecisions,
    Post,
    Publishing,
    RateLimit
  }

  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    w = render_world!()
    reviewer = member!(user!(), w.org_id)

    {:ok, profile} =
      Social.update_profile(w.org_id, w.profile, %{quality_reviewer_user_ids: [reviewer.id]})

    {:ok, account} = Social.update_account(w.org_id, w.tiktok, %{status: "connected"})
    w = %{w | profile: profile, tiktok: account}
    file = stored_file!(w.project, "quality clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        profile.id,
        %{
          "file_id" => file.id,
          "title" => "Title",
          "caption" => "Caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    %{w: w, reviewer: reviewer, clip: clip}
  end

  test "quality reviewer prepares a clip draft even on an account owned by the final approver",
       c do
    Repo.update!(Ecto.Changeset.change(c.w.tiktok, owner_user_id: c.w.approver.id))

    assert {:ok, %{posts: [post]}} =
             ClipDecisions.draft_clip(c.w.org_id, c.clip.id, c.reviewer.id, %{
               "render_id" => render_id!(c.clip),
               "account_ids" => [c.w.tiktok.id]
             })

    assert post.status == "draft"
    assert post.approved_by_user_id == nil and post.approved_at == nil
    assert post.quality_passed_by_user_id == nil and post.quality_passed_at == nil
    assert post.quality_pass_fingerprint == nil
    assert post.scheduled_at == nil and post.publish_after == nil
    refute Repo.exists?(ApprovalCard)
    assert Fake.calls() == []
  end

  test "quality reviewer can reject a pending clip without producing a post", c do
    assert {:ok, clip} =
             ClipDecisions.reject_clip(c.w.org_id, c.clip.id, c.reviewer.id, "Fix the cut")

    assert clip.review_status == "rejected"
    assert clip.review_note == "Fix the cut"
    assert clip.reviewed_by_user_id == c.reviewer.id
    refute Repo.exists?(Post)
    assert Fake.calls() == []
  end

  test "revoked quality membership cannot prepare from an old profile", c do
    {:ok, _} = Social.update_profile(c.w.org_id, c.w.profile, %{quality_reviewer_user_ids: []})

    assert {:error, :not_an_approver} =
             ClipDecisions.draft_clip(c.w.org_id, c.clip.id, c.reviewer.id, %{
               "render_id" => render_id!(c.clip),
               "account_ids" => [c.w.tiktok.id]
             })

    assert {:error, :not_an_approver} =
             ClipDecisions.reject_clip(c.w.org_id, c.clip.id, c.reviewer.id, "Fix")

    assert Repo.get!(Clip, c.clip.id).review_status == "pending"
    refute Repo.exists?(Post)
    assert Fake.calls() == []
  end

  test "a new vendor job on a failed clip post needs a pass and preserves refusal state", c do
    post = historical_clip_post!(c, %{status: "failed", error: "vendor failed"})

    assert {:error, :quality_review_required} =
             Social.retry_post(c.w.org_id, post.id, c.w.approver.id,
               scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
             )

    assert Repo.get!(Post, post.id) == post
    assert Fake.calls() == []
  end

  test "a new vendor job on a refused approved post also needs a pass", c do
    post = historical_clip_post!(c, %{refused_reason: "media_rejected", error: "refused"})

    assert {:error, :quality_review_required} =
             Publishing.retry_publish(c.w.org_id, post.id, c.w.approver.id,
               scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
             )

    assert Repo.get!(Post, post.id) == post
    assert Fake.calls() == []
  end

  test "same vendor job retry keeps the historical exception without a pass or time rewrite", c do
    past = DateTime.add(DateTime.utc_now(), -3600)

    post =
      historical_clip_post!(c, %{
        status: "failed",
        error: "vendor failed",
        external_id: "retained-job",
        scheduled_at: past
      })

    Fake.put_next(:retry, {:ok, %{status: :published, external_id: "retained-job"}})

    assert {:ok, retried} =
             Social.retry_post(c.w.org_id, post.id, c.w.approver.id,
               expected_external_id: "retained-job"
             )

    assert retried.status == "published"
    assert retried.scheduled_at == past
    assert retried.quality_passed_by_user_id == nil and retried.quality_passed_at == nil
    assert retried.quality_pass_fingerprint == nil
    assert [{:retry, [_, "retained-job"], _}] = Fake.calls(:retry)
    assert Fake.calls(:publish) == []
  end

  test "quality membership never grants either kind of retry", c do
    post =
      historical_clip_post!(c, %{status: "failed", error: "vendor failed", external_id: "job"})

    assert {:error, :not_an_approver} = Social.retry_post(c.w.org_id, post.id, c.reviewer.id)
    assert Repo.get!(Post, post.id) == post
    assert Fake.calls() == []
  end

  defp historical_clip_post!(c, attrs) do
    post =
      historical_approved_post!(
        c.w.org_id,
        c.w.tiktok,
        %{
          media_file_ids: [c.clip.render_file_id],
          media_meta: %{
            c.clip.render_file_id => %{"duration_s" => 30.0, "width" => 1080, "height" => 1920}
          }
        },
        c.w.approver
      )

    post |> Ecto.Changeset.change(Map.put(attrs, :clip_id, c.clip.id)) |> Repo.update!()
  end
end
