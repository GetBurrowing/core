defmodule Platform.Social.ClipCopyQualityIntegrationTest do
  @moduledoc """
  Integration of the clip copy-edit tool (`social_clip_update_copy`) with the
  quality-review flow on main.

  How main routes: `ClipDecisions.draft_clip/5` writes legacy `draft` posts
  (never a submission), with or without quality reviewers. A draft becomes a
  submission through `Social.update_post/3` (`QualityReview.route_submission/2`),
  which routes `needs_approval` to `quality_review` when the profile has
  reviewers and leaves it `needs_approval` otherwise. These controls pin that
  the copy-edit path feeds that flow and does not bypass or alter it.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Clip, ClipDecisions, ClipRender}
  alias Platform.Social.{ClipReviewFeed, ClipVersions, Post, PostEvent, QualityReview}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = render_world!()
    reviewer = member!(user!(), w.org_id)
    other_agent = pinned_agent!(w.org_id)

    w = %{
      w
      | profile:
          w.profile |> Ecto.Changeset.change(drafting_agent_id: w.agent.id) |> Repo.update!(),
        tiktok: w.tiktok |> Ecto.Changeset.change(status: "connected") |> Repo.update!()
    }

    %{w: w, reviewer: reviewer, other_agent: other_agent}
  end

  defp with_reviewers(w, reviewer) do
    {:ok, profile} =
      Social.update_profile(w.org_id, w.profile, %{quality_reviewer_user_ids: [reviewer.id]})

    %{w | profile: profile}
  end

  defp clip!(w, title, caption) do
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => title,
          "caption" => caption,
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    clip
  end

  defp rev(clip), do: ClipReviewFeed.copy_rev(Repo.get!(Clip, clip.id))

  defp edit(w, clip, args, agent_id \\ nil) do
    ToolArguments.dispatch(
      "social_clip_update_copy",
      Map.merge(%{"clip_id" => clip.id, "expected_copy_rev" => rev(clip)}, args),
      %{agent_id: agent_id || w.agent.id}
    )
  end

  defp draft(w, clip, render_id, extra) do
    ClipDecisions.draft_clip(
      w.org_id,
      clip.id,
      w.approver.id,
      Map.merge(
        %{
          "render_id" => render_id,
          "account_ids" => [w.tiktok.id],
          "copy_rev" => rev(clip),
          "scheduled_at" => future()
        },
        extra
      )
    )
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

  defp row(%Post{id: id}), do: Repo.get!(Post, id) |> Map.from_struct() |> Map.delete(:__meta__)

  # A second version of the same clip, so the chosen version's media differs
  # from the clip's current one.
  defp add_version!(w, clip) do
    file2 = stored_file!(w.project, "clip bytes v2 #{unique()}", "clip2.mp4", "video/mp4")

    {:ok, _} =
      Repo.transaction(fn ->
        ClipVersions.append!(clip.id, file2, %{}, %{
          headline: "burned v2",
          caption: "burned caption v2",
          source: %{"origin" => "external"},
          provenance: %{"kind" => "test"},
          completion_key: "test:" <> Ecto.UUID.generate()
        })
      end)

    file2
  end

  defp effects(clip) do
    %{
      posts: Repo.aggregate(from(p in Post, where: p.clip_id == ^clip.id), :count),
      events: Repo.aggregate(PostEvent, :count),
      cards: Repo.aggregate(ApprovalCard, :count),
      publisher: Fake.calls(),
      clip: Repo.get!(Clip, clip.id)
    }
  end

  describe "1. edited copy through Create drafts, then submission" do
    test "reviewers configured: draft carries edited copy + selected version media; submitting routes to quality_review",
         %{w: w, reviewer: reviewer} do
      w = with_reviewers(w, reviewer)
      clip = clip!(w, "Original title", "Original caption")
      v1 = render_id!(clip)
      v1_file = Repo.get!(ClipRender, v1).file_id
      v2_file = add_version!(w, clip).id
      assert Repo.get!(Clip, clip.id).render_file_id == v2_file

      assert {:ok, _} = edit(w, clip, %{"title" => "Edited title", "caption" => "Edited caption"})

      # Create drafts for the OLDER version v1: edited copy, v1's media.
      assert {:ok, %{posts: [post]}} = draft(w, clip, v1, %{})
      assert post.body == "Edited caption"
      assert post.media_file_ids == [v1_file]
      assert post.clip_render_id == v1

      # main's draft path writes a legacy draft: no submission, no pass, no card.
      assert post.status == "draft"
      assert post.flow == "legacy"
      assert is_nil(post.quality_passed_by_user_id)
      assert is_nil(post.quality_pass_fingerprint)
      refute Repo.exists?(ApprovalCard)

      # Submitting that draft goes through main's routing.
      assert {:ok, submitted} = Social.update_post(w.org_id, post, %{status: "needs_approval"})
      assert submitted.status == "quality_review"
      assert submitted.body == "Edited caption"
      assert submitted.media_file_ids == [v1_file]
      assert Fake.calls() == []
    end

    test "no reviewers: draft carries edited copy; submitting keeps the existing needs_approval flow",
         %{w: w} do
      clip = clip!(w, "Original title", "Original caption")
      v1 = render_id!(clip)
      assert {:ok, _} = edit(w, clip, %{"caption" => "Edited caption"})

      assert {:ok, %{posts: [post]}} = draft(w, clip, v1, %{})
      assert post.status == "draft"
      assert post.body == "Edited caption"

      assert {:ok, submitted} = Social.update_post(w.org_id, post, %{status: "needs_approval"})
      assert submitted.status == "needs_approval"
      assert submitted.body == "Edited caption"
    end
  end

  describe "2. refusals write nothing (reviewers configured)" do
    setup %{w: w, reviewer: reviewer} do
      w = with_reviewers(w, reviewer)
      clip = clip!(w, "T", "C")
      %{w: w, clip: clip}
    end

    test "missing, blank and stale copy tokens", %{w: w, clip: clip} do
      v1 = render_id!(clip)
      old = rev(clip)
      assert {:ok, _} = edit(w, clip, %{"caption" => "Changed after the page rendered"})
      before = effects(clip)

      for extra <- [%{"copy_rev" => old}, %{"copy_rev" => ""}, %{"copy_rev" => nil}] do
        assert {:error, :stale_copy} = draft(w, clip, v1, extra)
      end

      no_token =
        ClipDecisions.draft_clip(w.org_id, clip.id, w.approver.id, %{
          "render_id" => v1,
          "account_ids" => [w.tiktok.id]
        })

      assert {:error, :stale_copy} = no_token
      assert effects(clip) == before
      assert before.posts == 0
    end

    test "an agent that is not the drafting agent is refused and nothing changes",
         %{w: w, clip: clip, other_agent: other} do
      before = effects(clip)
      assert {:error, _envelope} = edit(w, clip, %{"caption" => "Hijacked"}, other.id)
      assert effects(clip) == before
      assert Repo.get!(Clip, clip.id).caption == "C"
    end
  end

  describe "3. existing posts and quality passes are untouched by the tool" do
    test "a passed post keeps every column; its pass stays valid", %{w: w, reviewer: reviewer} do
      w = with_reviewers(w, reviewer)
      a = clip!(w, "A title", "A caption")
      b = clip!(w, "B title", "B caption")

      assert {:ok, %{posts: [post]}} = draft(w, a, render_id!(a), %{})

      assert {:ok, %{status: "quality_review"}} =
               Social.update_post(w.org_id, post, %{status: "needs_approval"})

      assert {:ok, _passed} = QualityReview.pass(w.org_id, post.id, reviewer.id)

      before = row(post)
      assert QualityReview.valid_pass?(Repo.get!(Post, post.id))
      refute is_nil(before.quality_pass_fingerprint)

      # An edit of another clip, and of the post's own (now decided) clip.
      assert {:ok, _} = edit(w, b, %{"caption" => "B edited"})
      assert {:error, _} = edit(w, a, %{"caption" => "A edited after drafting"})

      assert row(post) == before
      assert QualityReview.valid_pass?(Repo.get!(Post, post.id))
      assert Repo.get!(Post, post.id).body == "A caption"
    end
  end
end
