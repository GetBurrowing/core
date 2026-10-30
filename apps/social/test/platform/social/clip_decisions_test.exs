defmodule Platform.Social.ClipDecisionsTest do
  @moduledoc """
  Clip Studio 2/9 (task 01a16662) stage 2: a human's one-step clip decision.
  Approve writes one approved post per account (no approval card, no second
  approval) whose `publish_after` closes an 8s server-side window; a test
  instance of `Platform.Social.ClipPublish` publishes them only after it.
  Undo inside the window takes everything back; reject needs a note.

  The clock is injected with `:now`; nothing sleeps. The Fake's call log is
  global and ClipPublish runs in its own process, so this file is not async
  (the sandbox is shared).
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ApprovalCard, Clip, ClipPublish, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  @publisher :clip_decisions_test_publish

  setup do
    Fake.reset()
    RateLimit.reset()
    world = render_world!()
    start_supervised!({ClipPublish, name: @publisher, interval_ms: :infinity, boot_sweep: false})
    %{w: world, clip: pending_clip!(world, "first-render-v1"), t0: DateTime.utc_now()}
  end

  test "a real vendor status failure retries the existing post through the guard", ctx do
    alias Platform.Social.{Publishing, Publisher.Zernio}
    {:ok, %{posts: [post]}} = approve(ctx, ctx.w.approver.id, [ctx.w.tiktok.id])
    assert [{_, {:ok, scheduled}}] = ClipPublish.sweep_now(@publisher, at(ctx, 8_000))
    assert scheduled.external_id == "fake_" <> post.id

    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "retry-status-test-key",
        scope: {:integration, nil},
        provider: "social"
      )

    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    Req.Test.expect(Zernio, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/posts/" <> scheduled.external_id

      Req.Test.json(conn, %{
        post: %{
          status: "failed",
          platforms: [
            %{
              accountId: ctx.w.tiktok.provider_account_ref,
              status: "failed",
              errorMessage: "platform upload failed"
            }
          ]
        }
      })
    end)

    assert {:ok, failed} = Publishing.refresh_status(ctx.w.org_id, post.id)
    assert failed.status == "failed"
    assert failed.error == "platform upload failed"
    assert failed.external_id == scheduled.external_id

    Application.put_env(:social, :publisher, Fake)
    Fake.reset()

    Fake.put_next(
      :retry,
      {:ok,
       %{
         status: :published,
         external_id: scheduled.external_id,
         external_url: "https://tiktok.example.test/retried",
         platform_post_id: "retry-platform-1"
       }}
    )

    retrier = make_approver!(ctx.w.org_id, ctx.w.profile, member!(user!(), ctx.w.org_id))
    assert {:ok, published} = Social.retry_post(ctx.w.org_id, post.id, retrier.id)
    assert published.status == "published"
    assert published.external_id == scheduled.external_id
    assert published.external_url == "https://tiktok.example.test/retried"
    assert published.platform_post_id == "retry-platform-1"
    assert published.publish_attempts == 2
    assert published.approved_by_user_id == retrier.id
    assert published.error == nil
    assert [{:retry, [_, external_id], _}] = Fake.calls(:retry)
    assert external_id == scheduled.external_id
    assert Fake.calls(:publish) == []
  end

  # An externally rendered clip, review pending, submitted by the world's agent.
  defp pending_clip!(w, bytes \\ "rendered clip #{unique()}") do
    file = stored_file!(w.project, bytes, "clip.mp4", "video/mp4")

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

    clip
  end

  defp approve(ctx, user_id, account_ids, opts \\ []) do
    Social.approve_clip(
      ctx.w.org_id,
      ctx.clip.id,
      user_id,
      %{"render_id" => render_id!(ctx.clip), "account_ids" => account_ids},
      Keyword.merge([now: ctx.t0, publish_server: @publisher], opts)
    )
  end

  defp both(ctx), do: [ctx.w.tiktok.id, ctx.w.x.id]

  defp at(ctx, ms), do: DateTime.add(ctx.t0, ms, :millisecond)

  defp clip_posts(clip_id),
    do: Repo.all(from(p in Post, where: p.clip_id == ^clip_id, order_by: p.inserted_at))

  defp post_count, do: Repo.aggregate(Post, :count)

  defp assert_untouched(ctx, posts_before) do
    assert post_count() == posts_before
    clip = Repo.get!(Clip, ctx.clip.id)

    assert {clip.review_status, clip.reviewed_by_user_id, clip.reviewed_at} ==
             {"pending", nil, nil}

    assert Fake.calls(:publish) == []
  end

  # The selected version differs from the current clip in every publish fact.
  # Literal expectations below must fail if approval ignores render_id.
  test "chosen v1 stays bound through v2 latest and v3 before publish", ctx do
    v1_id = render_id!(ctx.clip)
    v1_file = ctx.clip.render_file_id
    v2_file = stored_file!(ctx.w.project, "v2 bytes", "v2.mp4", "video/mp4")

    {:ok, _} =
      Repo.transaction(fn ->
        Platform.Social.ClipVersions.append!(
          ctx.clip.id,
          v2_file,
          %{
            title: "Second headline",
            caption: "Second caption",
            duration_s: 18.0,
            width: 720,
            height: 1280
          },
          %{headline: "Second headline", caption: "Second caption", completion_key: "test-v2"}
        )
      end)

    assert {:ok, %{clip: approved, posts: [post]}} =
             Social.approve_clip(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               %{"render_id" => v1_id, "account_ids" => [ctx.w.tiktok.id]},
               now: ctx.t0,
               publish_server: @publisher
             )

    assert approved.reviewed_render_id == v1_id
    assert post.clip_render_id == v1_id
    assert post.media_file_ids == [v1_file]
    assert post.body =~ "Agent caption"
    refute post.body =~ "Second caption"
    assert Repo.get!(Platform.Social.Idea, post.idea_id).title == "Agent title"
    assert post.media_meta[v1_file] == %{"duration_s" => 30.0, "width" => 1080, "height" => 1920}

    v3_file = stored_file!(ctx.w.project, "v3 bytes", "v3.mp4", "video/mp4")

    {:ok, _} =
      Repo.transaction(fn ->
        Platform.Social.ClipVersions.append!(
          ctx.clip.id,
          v3_file,
          %{
            title: "Third headline",
            caption: "Third caption",
            duration_s: 9.0,
            width: 540,
            height: 960
          },
          %{headline: "Third headline", caption: "Third caption", completion_key: "test-v3"}
        )
      end)

    assert length(ClipPublish.sweep_now(@publisher, at(ctx, 8_000))) == 1
    [{:publish, [_, request], _}] = Fake.calls(:publish)

    assert [%{url: signed_url, duration_s: 30.0, content_type: "video/mp4", byte_size: 15}] =
             request.media

    assert {:ok, ^v1_file} =
             signed_url |> String.split("/") |> List.last() |> Platform.Files.SignedUrl.verify()

    assert request.body =~ "Agent caption"
    assert Repo.get!(Post, post.id).clip_render_id == v1_id
    assert Repo.get!(Clip, ctx.clip.id).reviewed_render_id == nil
    assert Platform.Files.get_file(v1_file)
  end

  test "undo after a new render cancels only its selected approval and preserves newer review",
       ctx do
    v1 = render_id!(ctx.clip)
    assert {:ok, %{posts: [old_post]}} = approve(ctx, ctx.w.approver.id, [ctx.w.tiktok.id])
    file = stored_file!(ctx.w.project, "new render", "new.mp4", "video/mp4")

    {:ok, current} =
      Repo.transaction(fn ->
        Platform.Social.ClipVersions.append!(
          ctx.clip.id,
          file,
          %{title: "New cut", caption: "New caption", duration_s: 20.0},
          %{headline: "New cut", caption: "New caption", completion_key: "undo-v2"}
        )
      end)

    v2 = render_id!(current)
    other_approver = make_approver!(ctx.w.org_id, ctx.w.profile, user!())

    assert {:ok, %{posts: [new_post]}} =
             Social.approve_clip(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               %{"render_id" => v2, "account_ids" => [ctx.w.tiktok.id]},
               now: ctx.t0,
               publish_server: @publisher
             )

    assert {:error, :not_reviewer} =
             Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, other_approver.id,
               now: ctx.t0,
               render_id: v1
             )

    assert {:ok, clip} =
             Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
               now: ctx.t0,
               render_id: v1
             )

    assert Repo.get(Post, old_post.id) == nil
    assert Repo.get!(Post, new_post.id).clip_render_id == v2

    assert {clip.render_file_id, clip.review_status, clip.reviewed_render_id} ==
             {file.id, "approved", v2}

    assert {:error, :window_closed} =
             Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
               now: at(ctx, 8_000),
               render_id: v2
             )

    assert {:ok, _} =
             Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
               now: ctx.t0,
               render_id: v2
             )

    assert Repo.get(Post, new_post.id) == nil
  end

  test "missing malformed foreign and deleted render identities write nothing", ctx do
    other_clip = pending_clip!(ctx.w)
    other = render_world!()
    foreign = pending_clip!(other)
    original = render_id!(ctx.clip)

    for id <- [nil, "broken", Ecto.UUID.generate(), render_id!(other_clip), render_id!(foreign)] do
      before = post_count()
      attrs = %{"render_id" => id, "account_ids" => [ctx.w.tiktok.id]}

      assert {:error, :render_not_found} =
               Social.approve_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, attrs,
                 publish_server: @publisher
               )

      assert_untouched(ctx, before)
    end

    file = Platform.Files.get_file(ctx.clip.render_file_id)
    Repo.update!(Ecto.Changeset.change(file, deleted_at: DateTime.utc_now()))
    before = post_count()

    assert {:error, :render_not_found} =
             Social.approve_clip(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               %{"render_id" => original, "account_ids" => [ctx.w.tiktok.id]},
               publish_server: @publisher
             )

    assert_untouched(ctx, before)
  end

  test "version identity cannot be injected through editable post attrs", ctx do
    cs = Post.changeset(%Post{}, %{"body" => "body", "clip_render_id" => render_id!(ctx.clip)})
    assert Ecto.Changeset.get_field(cs, :clip_render_id) == nil
  end

  describe "approve_clip/5" do
    test "approve with 2 accounts writes 2 approved posts with clip_id and no approval card",
         ctx do
      assert {:ok, %{clip: clip, posts: [p1, p2]}} =
               Social.approve_clip(
                 ctx.w.org_id,
                 ctx.clip.id,
                 ctx.w.approver.id,
                 %{
                   "render_id" => render_id!(ctx.clip),
                   "account_ids" => both(ctx),
                   "title" => "Human title",
                   "caption" => "Watch this"
                 },
                 now: ctx.t0,
                 publish_server: @publisher
               )

      assert clip.review_status == "approved"
      assert clip.reviewed_by_user_id == ctx.w.approver.id
      assert clip.reviewed_at == ctx.t0
      assert {clip.title, clip.caption} == {"Human title", "Watch this"}

      posts = clip_posts(ctx.clip.id)
      assert Enum.map(posts, & &1.id) |> Enum.sort() == Enum.sort([p1.id, p2.id])
      assert Enum.map(posts, & &1.account_id) |> Enum.sort() == Enum.sort(both(ctx))

      for post <- posts do
        assert post.status == "approved"
        assert post.clip_id == ctx.clip.id
        assert post.approved_by_user_id == ctx.w.approver.id
        assert post.publish_after == at(ctx, 8_000)
        assert post.media_file_ids == [ctx.clip.render_file_id]
        assert post.generated_by_agent_id == ctx.w.agent.id
        assert post.is_aigc == true
        assert post.body =~ "Watch this"
        assert post.link_url == "https://www.youtube.com/@clipshow"
        assert post.body =~ post.link_url
        assert post.media_meta[ctx.clip.render_file_id]["duration_s"] == 30.0
        assert post.publish_attempts == 0
      end

      assert Repo.aggregate(
               from(c in ApprovalCard, where: c.post_id in ^Enum.map(posts, & &1.id)),
               :count
             ) == 0

      assert Fake.calls(:publish) == []
    end

    test "a non-approver cannot approve a clip", ctx do
      before = post_count()
      stranger = member!(user!(), ctx.w.org_id)

      assert {:error, :not_an_approver} = approve(ctx, stranger.id, both(ctx))
      assert_untouched(ctx, before)

      # The approver gate comes first: a non-approver learns nothing about
      # the accounts, not even that the list is empty.
      assert {:error, :not_an_approver} = approve(ctx, stranger.id, [])
      assert_untouched(ctx, before)
    end

    test "an agent id cannot approve a clip", ctx do
      before = post_count()
      assert {:error, :not_a_human} = approve(ctx, ctx.w.agent.id, both(ctx))
      assert_untouched(ctx, before)
    end

    test "a cross-org account is refused and nothing is written", ctx do
      before = post_count()
      other = render_world!()

      assert {:error, :account_not_in_profile} =
               approve(ctx, ctx.w.approver.id, [ctx.w.tiktok.id, other.x.id])

      assert_untouched(ctx, before)

      # An account of another profile in the same org, and an archived one, alike.
      {_, sibling} = social_account!(ctx.w.org_id, "x")
      assert {:error, :account_not_in_profile} = approve(ctx, ctx.w.approver.id, [sibling.id])
      {:ok, _} = Social.archive_account(ctx.w.org_id, ctx.w.x)
      assert {:error, :account_not_in_profile} = approve(ctx, ctx.w.approver.id, [ctx.w.x.id])
      assert_untouched(ctx, before)
    end

    test "no account ids is no_platforms", ctx do
      assert {:error, :no_platforms} = approve(ctx, ctx.w.approver.id, [])
      assert {:error, :no_platforms} = approve(ctx, ctx.w.approver.id, nil)
    end

    test "a non-owner approving an owned account rolls back everything", ctx do
      before = post_count()
      owner = member!(user!(), ctx.w.org_id)
      {:ok, _} = Social.set_account_owner(ctx.w.org_id, ctx.w.x, owner.id)

      # tiktok (unowned) is written and approved first, then x refuses.
      assert {:error, :not_the_owner} = approve(ctx, ctx.w.approver.id, both(ctx))
      assert_untouched(ctx, before)
    end

    test "a draft_only account is refused", ctx do
      before = post_count()

      {:ok, draft_only} =
        Social.create_account(ctx.w.org_id, ctx.w.profile, %{
          platform: "linkedin",
          approval_mode: "draft_only"
        })

      assert {:error, :account_draft_only} =
               approve(ctx, ctx.w.approver.id, [ctx.w.tiktok.id, draft_only.id])

      assert_untouched(ctx, before)
    end

    test "a missing, cross-org or already decided clip is refused", ctx do
      assert {:error, :not_found} =
               Social.approve_clip(ctx.w.org_id, Ecto.UUID.generate(), ctx.w.approver.id, %{})

      assert {:error, :not_found} =
               Social.approve_clip(org_id!(), ctx.clip.id, ctx.w.approver.id, %{
                 "account_ids" => both(ctx)
               })

      assert {:ok, _} = approve(ctx, ctx.w.approver.id, [ctx.w.tiktok.id])
      assert {:error, :not_pending} = approve(ctx, ctx.w.approver.id, [ctx.w.x.id])
      assert length(clip_posts(ctx.clip.id)) == 1
    end
  end

  describe "the publish window" do
    test "nothing publishes before the window closes", ctx do
      {:ok, _} = approve(ctx, ctx.w.approver.id, both(ctx))

      assert ClipPublish.sweep_now(@publisher, ctx.t0) == []
      assert ClipPublish.sweep_now(@publisher, at(ctx, 7_999)) == []
      assert Fake.calls(:publish) == []
      assert Enum.all?(clip_posts(ctx.clip.id), &(&1.status == "approved"))
    end

    test "after the window both posts reach the Fake publisher with no second approval", ctx do
      {:ok, %{posts: posts}} = approve(ctx, ctx.w.approver.id, both(ctx))

      results = ClipPublish.sweep_now(@publisher, at(ctx, 8_000))
      assert length(results) == 2
      assert Enum.all?(results, &match?({_, {:ok, %Post{status: "scheduled"}}}, &1))

      published =
        Fake.calls(:publish) |> Enum.map(fn {:publish, [_, req], _} -> req.idempotency_key end)

      assert Enum.sort(published) == Enum.sort(Enum.map(posts, & &1.id))

      for post <- clip_posts(ctx.clip.id) do
        assert post.status == "scheduled"
        assert post.publish_after == nil
        assert post.publish_attempts == 1
        assert post.approved_by_user_id == ctx.w.approver.id
      end

      # Nothing is due twice.
      assert ClipPublish.sweep_now(@publisher, at(ctx, 60_000)) == []
      assert length(Fake.calls(:publish)) == 2
    end
  end

  describe "undo_clip_decision/4" do
    test "undo inside the window deletes the posts and returns the clip to pending", ctx do
      before = post_count()
      {:ok, _} = approve(ctx, ctx.w.approver.id, both(ctx))

      assert {:ok, %Clip{review_status: "pending"}} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
                 now: at(ctx, 7_000)
               )

      assert clip_posts(ctx.clip.id) == []
      assert post_count() == before
      clip = Repo.get!(Clip, ctx.clip.id)

      assert {clip.review_status, clip.reviewed_by_user_id, clip.reviewed_at} ==
               {"pending", nil, nil}

      # Nothing is left to publish after the window either.
      assert ClipPublish.sweep_now(@publisher, at(ctx, 60_000)) == []
      assert Fake.calls(:publish) == []
    end

    test "undo after the window is window_closed", ctx do
      {:ok, _} = approve(ctx, ctx.w.approver.id, both(ctx))

      assert {:error, :window_closed} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
                 now: at(ctx, 8_000)
               )

      assert length(clip_posts(ctx.clip.id)) == 2
      assert Repo.get!(Clip, ctx.clip.id).review_status == "approved"
    end

    test "only the reviewer may undo, and only a human approver", ctx do
      other = member!(user!(), ctx.w.org_id)
      make_approver!(ctx.w.org_id, ctx.w.profile, other)
      {:ok, _} = approve(ctx, ctx.w.approver.id, both(ctx))

      assert {:error, :not_reviewer} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, other.id, now: ctx.t0)

      assert {:error, :not_a_human} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.agent.id, now: ctx.t0)

      assert length(clip_posts(ctx.clip.id)) == 2
    end

    test "an undo racing the sweep publishes at most once", ctx do
      # Undo first: the sweep finds nothing to claim.
      {:ok, _} = approve(ctx, ctx.w.approver.id, both(ctx))

      assert {:ok, _} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
                 now: at(ctx, 7_999)
               )

      assert ClipPublish.sweep_now(@publisher, at(ctx, 8_000)) == []
      assert Fake.calls(:publish) == []

      # Sweep first: it claims and publishes once; the undo is then refused
      # and a second sweep publishes nothing.
      t1 = at(ctx, 20_000)

      {:ok, %{posts: posts}} =
        Social.approve_clip(
          ctx.w.org_id,
          ctx.clip.id,
          ctx.w.approver.id,
          %{"render_id" => render_id!(ctx.clip), "account_ids" => both(ctx)},
          now: t1,
          publish_server: @publisher
        )

      claim_at = DateTime.add(t1, 8_000, :millisecond)
      assert length(ClipPublish.sweep_now(@publisher, claim_at)) == 2

      assert {:error, :window_closed} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, now: t1)

      assert ClipPublish.sweep_now(@publisher, claim_at) == []

      # A stale claim on an already-claimed post matches no row.
      for p <- posts,
          do: assert({:ok, :skipped} = ClipPublish.publish_due(ctx.w.org_id, p.id, claim_at))

      keys =
        Fake.calls(:publish) |> Enum.map(fn {:publish, [_, req], _} -> req.idempotency_key end)

      assert Enum.sort(keys) == Enum.sort(Enum.map(posts, & &1.id))
      assert Repo.get!(Clip, ctx.clip.id).review_status == "approved"
    end
  end

  describe "reject_clip/5" do
    test "reject without a note is note_required", ctx do
      for note <- [nil, "", "   \n "] do
        assert {:error, :note_required} =
                 Social.reject_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, note)
      end

      assert {:error, :note_too_long} =
               Social.reject_clip(
                 ctx.w.org_id,
                 ctx.clip.id,
                 ctx.w.approver.id,
                 String.duplicate("a", 2_001)
               )

      assert Repo.get!(Clip, ctx.clip.id).review_status == "pending"
    end

    test "reject stores the note and writes no posts", ctx do
      before = post_count()

      assert {:ok, %Clip{review_status: "rejected"} = clip} =
               Social.reject_clip(
                 ctx.w.org_id,
                 ctx.clip.id,
                 ctx.w.approver.id,
                 "  Cut the intro.  ",
                 now: ctx.t0
               )

      assert {clip.review_note, clip.reviewed_by_user_id, clip.reviewed_at} ==
               {"Cut the intro.", ctx.w.approver.id, ctx.t0}

      assert post_count() == before
      assert Fake.calls(:publish) == []

      # An agent id and a non-approver cannot reject.
      fresh = pending_clip!(ctx.w)

      assert {:error, :not_a_human} =
               Social.reject_clip(ctx.w.org_id, fresh.id, ctx.w.agent.id, "no")

      assert {:error, :not_an_approver} =
               Social.reject_clip(ctx.w.org_id, fresh.id, member!(user!(), ctx.w.org_id).id, "no")
    end

    test "undo a reject returns the clip to pending", ctx do
      {:ok, _} =
        Social.reject_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, "Too long", now: ctx.t0)

      assert {:ok, %Clip{review_status: "pending", review_note: nil}} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
                 now: at(ctx, 7_999)
               )

      # Outside the window a reject stands.
      {:ok, _} =
        Social.reject_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, "Too long", now: ctx.t0)

      assert {:error, :window_closed} =
               Social.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id,
                 now: at(ctx, 8_000)
               )

      assert Repo.get!(Clip, ctx.clip.id).review_status == "rejected"
    end
  end
end
