defmodule Platform.Social.ClipDraftTest do
  @moduledoc """
  B3 clip integration: choosing a rendered clip for posting makes DRAFT posts
  (editable caption, title where the platform has one, account, an explicit
  schedule only when the person gave one) and nothing else. The drafts then
  take the normal legacy review path: `Social.update_post/3` to
  `needs_approval` writes the approval card, and only a human approval on that
  path approves. `publish_after` (the old undo window) is never a schedule.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Clip, ClipDecisions, ClipPublish, Post}
  alias Platform.Social.{PostEvents, Publisher.Fake, RateLimit}

  @publisher :clip_draft_test_publish

  setup do
    Fake.reset()
    RateLimit.reset()
    w = render_world!()
    start_supervised!({ClipPublish, name: @publisher, interval_ms: :infinity, boot_sweep: false})
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Agent title",
          "caption" => "Agent caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    %{w: w, clip: clip, t0: DateTime.utc_now()}
  end

  defp draft(ctx, user_id, account_ids, extra \\ %{}, opts \\ []) do
    ClipDecisions.draft_clip(
      ctx.w.org_id,
      ctx.clip.id,
      user_id,
      Map.merge(
        %{
          "render_id" => render_id!(ctx.clip),
          "account_ids" => account_ids,
          "copy_rev" => clip_copy_rev!(ctx.clip)
        },
        extra
      ),
      Keyword.merge([now: ctx.t0], opts)
    )
  end

  defp both(ctx), do: [ctx.w.tiktok.id, ctx.w.x.id]
  defp clip_posts(id), do: Repo.all(from(p in Post, where: p.clip_id == ^id, order_by: p.id))
  defp post_count, do: Repo.aggregate(Post, :count)
  defp card_count, do: Repo.aggregate(ApprovalCard, :count)

  defp assert_untouched(ctx, posts_before) do
    assert post_count() == posts_before
    clip = Repo.get!(Clip, ctx.clip.id)

    assert {clip.review_status, clip.reviewed_by_user_id, clip.reviewed_at} ==
             {"pending", nil, nil}

    assert clip.title == "Agent title" and clip.caption == "Agent caption"
  end

  describe "draft_clip/5" do
    test "writes one draft per account: no approval, no card, no schedule from the window", ctx do
      cards = card_count()

      assert {:ok, %{clip: clip, posts: [p1, p2]}} =
               draft(ctx, ctx.w.approver.id, both(ctx), %{
                 "title" => "Human title",
                 "caption" => "Watch this"
               })

      assert {clip.title, clip.caption} == {"Human title", "Watch this"}
      assert clip.reviewed_by_user_id == ctx.w.approver.id

      posts = clip_posts(ctx.clip.id)
      assert Enum.sort(Enum.map(posts, & &1.id)) == Enum.sort([p1.id, p2.id])
      assert Enum.sort(Enum.map(posts, & &1.account_id)) == Enum.sort(both(ctx))

      for post <- posts do
        assert post.status == "draft"
        assert post.clip_id == ctx.clip.id
        assert post.clip_render_id == render_id!(ctx.clip)
        assert post.approved_by_user_id == nil and post.approved_at == nil
        assert post.publish_after == nil
        assert post.scheduled_at == nil
        # The caption is the body as it stands; the link is its own field.
        assert post.body == "Watch this"
        assert post.link_url == "https://www.youtube.com/@clipshow"
        assert post.media_file_ids == [ctx.clip.render_file_id]
        assert post.generated_by_agent_id == ctx.w.agent.id
        assert post.idea_id != nil
        assert post.media_meta[ctx.clip.render_file_id]["duration_s"] == 30.0
      end

      assert card_count() == cards

      for post <- posts do
        assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) == ["created"]
      end

      assert Fake.calls(:publish) == []
    end

    test "a schedule is set only when the person supplies one, and publish_after stays nil",
         ctx do
      at = DateTime.add(ctx.t0, 3 * 86_400, :second)

      assert {:ok, %{posts: posts}} =
               draft(ctx, ctx.w.approver.id, both(ctx), %{"scheduled_at" => at})

      assert Enum.all?(posts, &(&1.scheduled_at == at and &1.publish_after == nil))
      assert Enum.all?(posts, &(&1.status == "draft"))
    end

    test "a YouTube draft carries the title through the human platform-options path", ctx do
      {:ok, yt} = Social.create_account(ctx.w.org_id, ctx.w.profile, %{platform: "youtube"})

      assert {:ok, %{posts: [post]}} =
               draft(ctx, ctx.w.approver.id, [yt.id], %{"title" => "Reviewed title"})

      assert Repo.get!(Post, post.id).platform_options == %{"title" => "Reviewed title"}

      # Set through the canonical narrow title input at creation, not by a
      # second platform-options write: the history holds only `created`.
      assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) == ["created"]

      # A title over the platform's limit refuses the whole draft: nothing written.
      before = post_count()
      {:ok, c2} = second_clip(ctx)

      assert {:error, {:invalid_options, %{"title" => _}}} =
               ClipDecisions.draft_clip(
                 ctx.w.org_id,
                 c2.id,
                 ctx.w.approver.id,
                 %{
                   "copy_rev" => clip_copy_rev!(c2),
                   "render_id" => render_id!(c2),
                   "account_ids" => [ctx.w.tiktok.id, yt.id],
                   "title" => String.duplicate("t", 101)
                 },
                 now: ctx.t0
               )

      assert post_count() == before
      assert Repo.get!(Clip, c2.id).review_status == "pending"
    end

    test "a non-approver is refused and nothing changes", ctx do
      before = post_count()
      stranger = member!(user!(), ctx.w.org_id)
      assert {:error, :not_an_approver} = draft(ctx, stranger.id, both(ctx))
      assert {:error, :not_an_approver} = draft(ctx, stranger.id, [])
      assert {:error, :not_a_human} = draft(ctx, ctx.w.agent.id, both(ctx))
      assert_untouched(ctx, before)
    end

    test "any account refusal rolls the whole draft back", ctx do
      before = post_count()
      owner = member!(user!(), ctx.w.org_id)
      {:ok, _} = Social.set_account_owner(ctx.w.org_id, ctx.w.x, owner.id)

      # tiktok is fine; the owned x account refuses the non-owner.
      assert {:error, :not_the_owner} = draft(ctx, ctx.w.approver.id, both(ctx))
      assert_untouched(ctx, before)

      other = render_world!()

      assert {:error, :account_not_in_profile} =
               draft(ctx, ctx.w.approver.id, [ctx.w.tiktok.id, other.x.id])

      assert {:error, :no_platforms} = draft(ctx, ctx.w.approver.id, [])
      assert {:error, :no_platforms} = draft(ctx, ctx.w.approver.id, nil)

      assert {:error, :account_not_in_profile} =
               draft(ctx, ctx.w.approver.id, [Ecto.UUID.generate()])

      assert_untouched(ctx, before)
    end

    test "a draft_only account, an archived one and a sibling profile's are refused", ctx do
      before = post_count()

      {:ok, draft_only} =
        Social.create_account(ctx.w.org_id, ctx.w.profile, %{
          platform: "linkedin",
          approval_mode: "draft_only"
        })

      assert {:error, :account_draft_only} =
               draft(ctx, ctx.w.approver.id, [ctx.w.tiktok.id, draft_only.id])

      {_, sibling} = social_account!(ctx.w.org_id, "x")
      assert {:error, :account_not_in_profile} = draft(ctx, ctx.w.approver.id, [sibling.id])
      {:ok, _} = Social.archive_account(ctx.w.org_id, ctx.w.x)
      assert {:error, :account_not_in_profile} = draft(ctx, ctx.w.approver.id, [ctx.w.x.id])
      assert_untouched(ctx, before)
    end

    test "a missing or another org's clip is not_found", ctx do
      assert {:error, :not_found} =
               Social.draft_clip(ctx.w.org_id, Ecto.UUID.generate(), ctx.w.approver.id, %{})

      assert {:error, :not_found} =
               Social.draft_clip(org_id!(), ctx.clip.id, ctx.w.approver.id, %{
                 "account_ids" => both(ctx)
               })
    end

    test "a past or malformed schedule is refused and writes nothing", ctx do
      before = post_count()
      past = DateTime.add(ctx.t0, -60, :second)

      assert {:error, :schedule_in_past} =
               draft(ctx, ctx.w.approver.id, both(ctx), %{"scheduled_at" => past})

      assert {:error, :invalid_schedule} =
               draft(ctx, ctx.w.approver.id, both(ctx), %{"scheduled_at" => "next tuesday"})

      assert_untouched(ctx, before)
    end

    test "an unchosen render and a decided clip are refused", ctx do
      assert {:error, :render_not_found} =
               ClipDecisions.draft_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, %{
                 "copy_rev" => clip_copy_rev!(ctx.clip),
                 "render_id" => Ecto.UUID.generate(),
                 "account_ids" => both(ctx)
               })

      assert {:ok, _} = draft(ctx, ctx.w.approver.id, [ctx.w.tiktok.id])
      assert {:error, :not_pending} = draft(ctx, ctx.w.approver.id, [ctx.w.x.id])
      assert length(clip_posts(ctx.clip.id)) == 1
    end

    test "the old one-click entry no longer exists in either module", _ctx do
      refute function_exported?(ClipDecisions, :approve_clip, 5)
      refute function_exported?(Social, :approve_clip, 5)
    end

    test "the publish sweep never publishes a clip draft, however long it waits", ctx do
      assert {:ok, %{posts: posts}} =
               draft(ctx, ctx.w.approver.id, both(ctx), %{}, publish_server: @publisher)

      assert ClipPublish.due(DateTime.add(ctx.t0, 30 * 86_400, :second)) == []
      assert ClipPublish.sweep_now(@publisher, DateTime.add(ctx.t0, 30 * 86_400, :second)) == []
      assert Fake.calls(:publish) == []
      assert Enum.all?(posts, &(Repo.get!(Post, &1.id).status == "draft"))
    end
  end

  describe "the normal review path" do
    test "a card exists only after the draft is sent for review, and approval stays human", ctx do
      # Sending for review runs the publishing-completeness gate: the account
      # must be connected and the draft needs a time.
      Repo.update!(Ecto.Changeset.change(ctx.w.tiktok, status: "connected"))
      at = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

      assert {:ok, %{posts: [post]}} =
               draft(ctx, ctx.w.approver.id, [ctx.w.tiktok.id], %{"scheduled_at" => at})

      assert card_count() == 0

      assert {:ok, sent} = Social.update_post(ctx.w.org_id, post.id, %{status: "needs_approval"})
      assert sent.status == "needs_approval"
      assert Repo.aggregate(from(c in ApprovalCard, where: c.post_id == ^post.id), :count) == 1
      assert card_count() == 1
      assert sent.approved_by_user_id == nil and sent.publish_after == nil

      assert {:ok, approved} = Social.approve_post(ctx.w.org_id, sent, ctx.w.approver.id)
      assert approved.status == "approved"
      assert approved.approved_by_user_id == ctx.w.approver.id
      assert approved.publish_after == nil
      assert Fake.calls(:publish) == []
    end
  end

  defp second_clip(ctx) do
    file = stored_file!(ctx.w.project, "second #{unique()}", "c2.mp4", "video/mp4")

    AgentDrafts.submit_clip(
      ctx.w.scope,
      ctx.w.profile.id,
      %{
        "file_id" => file.id,
        "title" => "T",
        "caption" => "C",
        "duration_s" => 5.0,
        "width" => 720,
        "height" => 1280
      },
      ctx.w.agent.id
    )
  end
end
