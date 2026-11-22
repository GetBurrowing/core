defmodule Platform.Social.PublishingCompletenessTest do
  use Platform.DataCase, async: false
  require Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures, only: [media_file!: 2]
  alias Platform.Social

  alias Platform.Social.{
    AgentDrafts,
    ApprovalCard,
    Approvals,
    Post,
    PostEvents,
    PublishingCompleteness,
    Publishing,
    Composer
  }

  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    a = Repo.update!(Ecto.Changeset.change(ctx.a, status: "connected"))
    Map.put(ctx, :a, a)
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3600)

  defp failed_clip!(ctx, external_id) do
    clip = Repo.insert!(%Platform.Social.Clip{profile_id: ctx.profile.id, origin: "external"})

    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{body: "Previously reviewed", scheduled_at: future()})

    {:ok, p} = Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    Repo.update!(
      Ecto.Changeset.change(p,
        clip_id: clip.id,
        status: "failed",
        external_id: external_id,
        error: "Vendor failure"
      )
    )
  end

  test "incomplete new review is refused before a post or card is created", ctx do
    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Social.create_post(ctx.org_id, ctx.a, %{body: "Ready text", status: "needs_approval"})

    assert Repo.aggregate(Post, :count) == 0
    assert Repo.aggregate(ApprovalCard, :count) == 0
    assert Fake.calls(:publish) == []
  end

  test "draft can stay incomplete but update cannot submit it", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{})
    before = Repo.get!(Post, p.id)

    assert {:error, {:incomplete_post, ["Add the post text.", "Choose a publish time."]}} =
             Social.update_post(ctx.org_id, p.id, %{status: "needs_approval"})

    assert Repo.get!(Post, p.id) == before
    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "direct approval refuses an existing untimed draft without writing", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Ready text"})

    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    assert Repo.get!(Post, p.id) == p
  end

  test "agent incomplete review is atomic and reports all missing fields", ctx do
    assert {:error, {:incomplete_post, ["Add the post text.", "Choose a publish time."]}} =
             AgentDrafts.create_agent_drafts(
               {:tenant, ctx.org_id},
               ctx.profile.id,
               %{account_ids: [ctx.a.id]},
               agent_id: ctx.g.id
             )

    assert Repo.aggregate(Post, :count) == 0
    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "complete LinkedIn text needs no title or media", ctx do
    assert {:ok, p} =
             Social.create_post(ctx.org_id, ctx.a, %{
               body: "Ready",
               scheduled_at: future(),
               status: "needs_approval"
             })

    assert %ApprovalCard{} = Approvals.live_card(p.id)
  end

  test "title missing and time missing are ordered for YouTube", ctx do
    a = Repo.update!(Ecto.Changeset.change(ctx.a, platform: "youtube"))
    video = media_file!(ctx.org_id, "video/mp4")

    assert {:error,
            {:incomplete_post,
             [
               "Add a video title (YouTube needs one, up to 100 characters).",
               "Choose a publish time."
             ]}} =
             Social.create_post(ctx.org_id, a, %{
               body: "Description",
               media_file_ids: [video.id],
               status: "needs_approval"
             })
  end

  test "submission authority is evaluated before completeness", ctx do
    assert {:error, :not_found} =
             Social.create_post(Ecto.UUID.generate(), ctx.a.id, %{status: "needs_approval"})

    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{})
    assert {:error, :not_an_approver} = Social.approve_post(ctx.org_id, p.id, ctx.n.id)
  end

  test "Instagram media presence is required for review", ctx do
    a = Repo.update!(Ecto.Changeset.change(ctx.a, platform: "instagram"))

    assert {:error, {:incomplete_post, ["Add a video or an image."]}} =
             Social.create_post(ctx.org_id, a, %{
               body: "Caption",
               scheduled_at: future(),
               status: "needs_approval"
             })
  end

  test "controlled deadline boundary and all destination text limits", ctx do
    now = ~U[2026-11-22 12:00:00Z]

    for platform <- ["linkedin", "x"] do
      a = %{ctx.a | platform: platform}
      max = Platform.Social.PlatformLimits.get(platform).max_body
      p = %Post{body: String.duplicate("a", max), scheduled_at: DateTime.add(now, 1)}
      assert :ok = PublishingCompleteness.check(p, a, now)

      assert {:error, {:incomplete_post, [_]}} =
               PublishingCompleteness.check(%{p | body: p.body <> "a"}, a, now)

      assert {:error, {:incomplete_post, ["The publish time has passed. Choose a new one."]}} =
               PublishingCompleteness.check(%{p | scheduled_at: now}, a, now)
    end
  end

  test "YouTube narrow title input stores only the title and preserves other options", ctx do
    a = Repo.update!(Ecto.Changeset.change(ctx.a, platform: "youtube"))

    for title <- ["X", String.duplicate("x", 100)] do
      assert {:ok, [p]} =
               AgentDrafts.create_agent_drafts(
                 {:tenant, ctx.org_id},
                 ctx.profile.id,
                 %{account_ids: [a.id], status: "draft", title: title},
                 agent_id: ctx.g.id
               )

      assert p.platform_options == %{"title" => title}
    end

    assert {:error, %Ecto.Changeset{}} =
             AgentDrafts.create_agent_drafts(
               {:tenant, ctx.org_id},
               ctx.profile.id,
               %{account_ids: [a.id], status: "draft", title: String.duplicate("x", 101)},
               agent_id: ctx.g.id
             )

    assert {:error, :field_not_allowed, ["platform_options"]} =
             AgentDrafts.create_agent_drafts(
               {:tenant, ctx.org_id},
               ctx.profile.id,
               %{
                 account_ids: [a.id],
                 status: "draft",
                 platform_options: %{"title" => "unrestricted"}
               },
               agent_id: ctx.g.id
             )

    p = Repo.insert!(%Post{account_id: a.id, platform_options: %{"first_comment" => "Keep me"}})

    assert {:ok, updated} =
             AgentDrafts.update_agent_draft(
               {:tenant, ctx.org_id},
               p.id,
               %{title: "Publishing title"},
               agent_id: ctx.g.id
             )

    assert updated.platform_options == %{
             "title" => "Publishing title",
             "first_comment" => "Keep me"
           }
  end

  test "an existing incomplete card survives approval refusal unchanged", ctx do
    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Existing",
        status: "needs_approval",
        scheduled_at: future()
      })

    card = Approvals.live_card(p.id)
    p = Repo.update!(Ecto.Changeset.change(p, scheduled_at: nil))
    before_events = PostEvents.list_for_post(p.id)

    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Approvals.decide_approve(card.canvas_id, ctx.h1, Approvals.fingerprint(p))

    assert Repo.get!(Post, p.id) == p
    assert Repo.get!(ApprovalCard, card.id) == card
    assert PostEvents.list_for_post(p.id) == before_events
    assert Fake.calls(:publish) == []
  end

  test "explicit future replacement is checked and saved atomically", ctx do
    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Existing",
        status: "needs_approval",
        scheduled_at: future()
      })

    card = Approvals.live_card(p.id)
    p = Repo.update!(Ecto.Changeset.change(p, scheduled_at: nil))
    at = future()

    assert {:ok, %{post: approved}} =
             Approvals.decide_approve_at(card.canvas_id, ctx.h1, Approvals.fingerprint(p), at)

    assert DateTime.compare(approved.scheduled_at, at) == :eq
    assert length(Fake.calls(:publish)) == 1
  end

  test "direct request_approval cannot create a card for a historical incomplete row", ctx do
    p =
      Repo.insert!(
        Post.changeset(%Post{account_id: ctx.a.id}, %{body: "Existing", status: "needs_approval"})
      )

    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Approvals.request_approval(p)

    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "media deletion and disconnected account are rechecked on locked approval", ctx do
    a = Repo.update!(Ecto.Changeset.change(ctx.a, platform: "youtube"))
    file = media_file!(ctx.org_id, "video/mp4")

    {:ok, p} =
      Social.create_post(ctx.org_id, a, %{
        body: "Description",
        title: "The real title",
        media_file_ids: [file.id],
        scheduled_at: future(),
        status: "needs_approval"
      })

    Repo.update!(Ecto.Changeset.change(a, status: "reauth_needed"))

    assert {:error, {:incomplete_post, ["Reconnect the account."]}} =
             Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    assert Repo.get!(Post, p.id) == p
  end

  test "already-approved retry without external id requires explicit future confirmation", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Approved", scheduled_at: future()})
    {:ok, p} = Social.approve_post(ctx.org_id, p.id, ctx.h1.id)
    p = Repo.update!(Post.refusal_changeset(p, "media_rejected", "fix media", nil))

    assert {:error, :publish_time_required} =
             Publishing.retry_publish(ctx.org_id, p.id, ctx.h1.id)

    assert Repo.get!(Post, p.id) == p
    assert Fake.calls(:publish) == []
    at = DateTime.truncate(future(), :second)

    assert {:ok, retried} =
             apply(Publishing, :retry_publish, [ctx.org_id, p.id, ctx.h1.id, [scheduled_at: at]])

    assert DateTime.compare(retried.scheduled_at, at) == :eq
    assert length(Fake.calls(:publish)) == 1
  end

  test "existing-job retry preserves job id and never creates a new one", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Approved", scheduled_at: future()})
    {:ok, p} = Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    p =
      Repo.update!(
        Ecto.Changeset.change(p,
          external_id: "existing-job",
          scheduled_at: nil,
          refused_reason: "media_rejected"
        )
      )

    assert {:ok, _} = Publishing.retry_publish(ctx.org_id, p.id, ctx.h1.id)
    assert Fake.calls(:publish) == []
    assert length(Fake.calls(:retry)) == 1
  end

  test "composer stores the publishing title and reviewed media rather than only provenance",
       ctx do
    a = Repo.update!(Ecto.Changeset.change(ctx.a, platform: "youtube"))
    video = media_file!(ctx.org_id, "video/mp4")

    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{project_id: video.project_id})

    assert {:ok, %{posts: [p]}} =
             Composer.send(profile, ctx.n.id, %{
               idea: %{title: "An idea"},
               drafts: [
                 %{
                   account_id: a.id,
                   text: "Description",
                   title: "What actually ships",
                   media_file_ids: [video.id],
                   scheduled_at: future()
                 }
               ]
             })

    assert p.platform_options["title"] == "What actually ships"
    assert p.media_file_ids == [video.id]

    assert Platform.Social.PlatformOptions.zernio_platform_data("youtube", p.platform_options).title ==
             "What actually ships"

    card = Approvals.live_card(p.id)

    html =
      Phoenix.LiveViewTest.render_component(PlatformWeb.SocialCardComponent,
        id: "publishing-title",
        card_id: card.id,
        rev: 1,
        canvas_id: card.canvas_id,
        viewer: {:user, ctx.h1.id}
      )

    assert html =~ "Title (sent to YouTube)"
    assert html =~ "What actually ships"

    {:ok, p} =
      Social.set_platform_options(ctx.org_id, ctx.h1.id, p.id, %{
        "title" => "What actually ships",
        "first_comment" => "A reviewed extra"
      })

    Repo.update!(Ecto.Changeset.change(p, is_aigc: true, ai_disclosure: "Disclosure for review"))

    html =
      Phoenix.LiveViewTest.render_component(PlatformWeb.SocialCardComponent,
        id: "review-extras",
        card_id: card.id,
        rev: 2,
        canvas_id: card.canvas_id,
        viewer: {:user, ctx.h1.id}
      )

    assert html =~ "First comment"
    assert html =~ "A reviewed extra"
    assert html =~ "Disclosure for review"
    assert html =~ "UTC"
  end

  test "existing pending edits remain possible but never waive approval completeness", ctx do
    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Ready",
        scheduled_at: future(),
        status: "needs_approval"
      })

    p = Repo.update!(Ecto.Changeset.change(p, scheduled_at: nil))
    card = Approvals.live_card(p.id)
    assert {:ok, _} = Social.set_cover(ctx.org_id, ctx.h1.id, p.id, :clear)

    assert {:ok, updated} =
             Social.set_platform_options(ctx.org_id, ctx.h1.id, p.id, %{
               "first_comment" => "Extra"
             })

    assert {:error, {:incomplete_post, ["Choose a publish time."]}} =
             Social.approve_post(ctx.org_id, updated.id, ctx.h1.id)

    assert Approvals.live_card(p.id).id == card.id
    assert Repo.get!(Post, p.id).status == "needs_approval"
  end

  test "by-hand copy request remains separate and cannot be approved to publish", ctx do
    assert {:ok, p} =
             Social.create_post(ctx.org_id, ctx.d, %{body: "Copy me", status: "needs_approval"})

    assert %ApprovalCard{} = Approvals.live_card(p.id)

    assert {:error, :draft_only} =
             Approvals.decide_approve(
               Approvals.live_card(p.id).canvas_id,
               ctx.h1,
               Approvals.fingerprint(p)
             )

    assert Fake.calls(:publish) == []
  end

  test "an automatic home link cannot make a missing caption complete", ctx do
    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{home_url: "https://example.org"})

    assert {:error, {:incomplete_post, ["Add the post text."]}} =
             AgentDrafts.create_agent_drafts(
               {:tenant, ctx.org_id},
               profile.id,
               %{account_ids: [ctx.a.id], scheduled_at: future()},
               agent_id: ctx.g.id
             )

    assert Repo.aggregate(Post, :count) == 0
  end

  test "a new-job confirmation never silently becomes an existing-job retry", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Approved", scheduled_at: future()})
    {:ok, p} = Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    p =
      Repo.update!(
        Ecto.Changeset.change(p,
          external_id: "newly-appeared-job",
          refused_reason: "media_rejected"
        )
      )

    assert {:error, :publish_job_changed} =
             Publishing.retry_publish(ctx.org_id, p.id, ctx.h1.id, scheduled_at: future())

    assert Repo.get!(Post, p.id) == p
    assert Fake.calls(:publish) == []
    assert Fake.calls(:retry) == []
  end

  test "every destination preserves its existing text measurement at the boundary", ctx do
    now = DateTime.utc_now()
    image = media_file!(ctx.org_id, "image/png")
    video = media_file!(ctx.org_id, "video/mp4")

    for platform <- ["instagram", "tiktok", "youtube"] do
      account = %{ctx.a | platform: platform}
      max = Platform.Social.PlatformLimits.get(platform).max_body
      file = if platform == "instagram", do: image, else: video

      p = %Post{
        body: String.duplicate("a", max),
        scheduled_at: DateTime.add(now, 1),
        platform_options: %{"title" => "Video"},
        media_file_ids: [file.id],
        media_meta: %{file.id => %{"duration_s" => 30, "width" => 1080, "height" => 1920}}
      }

      assert :ok = PublishingCompleteness.check(p, account, now)

      assert {:error, {:incomplete_post, [_]}} =
               PublishingCompleteness.check(%{p | body: p.body <> "a"}, account, now)
    end
  end

  test "pending uploads cannot enter publishing review", ctx do
    file = media_file!(ctx.org_id, "video/mp4")
    Repo.update!(Ecto.Changeset.change(file, content_hash: nil, ingest_status: "pending"))

    assert {:error, {:incomplete_post, ["Finish uploading the media before review."]}} =
             Social.create_post(ctx.org_id, ctx.a, %{
               body: "Caption",
               media_file_ids: [file.id],
               scheduled_at: future(),
               status: "needs_approval"
             })
  end

  test "incomplete new-job retry preserves missing lines through its nested rollback", ctx do
    {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Approved", scheduled_at: future()})
    {:ok, p} = Social.approve_post(ctx.org_id, p.id, ctx.h1.id)
    Repo.update!(Ecto.Changeset.change(ctx.a, platform: "youtube"))
    p = Repo.update!(Post.refusal_changeset(p, "media_rejected", "Old failure", nil))

    assert {:error,
            {:incomplete_post,
             ["Add a video title (YouTube needs one, up to 100 characters).", "Add a video."]}} =
             Publishing.retry_publish(ctx.org_id, p.id, ctx.h1.id, scheduled_at: future())

    assert Repo.get!(Post, p.id) == p
    assert Fake.calls(:publish) == []
    assert Fake.calls(:retry) == []
  end

  test "deleted media and a deleted selected cover refuse approval before publishing", ctx do
    video = media_file!(ctx.org_id, "video/mp4")
    cover = media_file!(ctx.org_id, "image/png")

    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Video",
        scheduled_at: future(),
        media_file_ids: [video.id],
        cover_file_id: cover.id
      })

    Repo.update!(Ecto.Changeset.change(cover, deleted_at: DateTime.utc_now()))

    assert {:error, {:incomplete_post, ["cover must exist in the profile's org"]}} =
             Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    assert Repo.get!(Post, p.id) == p
    {:ok, p} = Social.set_cover(ctx.org_id, ctx.h1.id, p.id, :clear)
    Repo.update!(Ecto.Changeset.change(video, deleted_at: DateTime.utc_now()))

    assert {:error, {:incomplete_post, ["A media file is missing or not in this org"]}} =
             Social.approve_post(ctx.org_id, p.id, ctx.h1.id)

    assert Repo.get!(Post, p.id) == p
    assert Fake.calls(:publish) == []
  end

  test "new review fields do not broaden denied non-approver Queue disclosure", ctx do
    ctx = with_ideas_runtime(ctx)
    {:ok, account} = Social.update_account(ctx.org_id, ctx.a, %{platform: "youtube"})
    video = media_file!(ctx.org_id, "video/mp4")

    {:ok, p} =
      Social.create_post(ctx.org_id, account, %{
        body: "Legacy visible caption",
        title: "Restricted publishing title",
        scheduled_at: future(),
        media_file_ids: [video.id],
        status: "needs_approval"
      })

    {:ok, _} =
      Social.set_platform_options(ctx.org_id, ctx.h1.id, p.id, %{
        "title" => "Restricted publishing title",
        "first_comment" => "Restricted first comment"
      })

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    group = %{key: p.id, idea: nil, posts: [p]}

    html =
      Phoenix.LiveViewTest.render_component(PlatformWeb.SocialIdeaCard,
        id: "denied-fields",
        group: group,
        viewer: {:user, ctx.n.id},
        profiles: %{ctx.profile.id => ctx.profile}
      )

    assert html =~ "Legacy visible caption"
    refute html =~ "Restricted publishing title"
    refute html =~ "Restricted first comment"
    refute html =~ "publishing-review-details"

    html =
      Phoenix.LiveViewTest.render_component(PlatformWeb.SocialIdeaCard,
        id: "reviewer-fields",
        group: group,
        viewer: {:user, ctx.h1.id},
        profiles: %{ctx.profile.id => ctx.profile}
      )

    assert html =~ "Restricted publishing title"
    assert html =~ "Restricted first comment"
  end

  test "direct review request validates the persisted row rather than a stale struct", ctx do
    {:ok, p} =
      Social.create_post(ctx.org_id, ctx.a, %{body: "Previously complete", scheduled_at: future()})

    Repo.update!(Ecto.Changeset.change(p, status: "needs_approval", body: "   "))
    stale = %{p | status: "needs_approval"}

    assert {:error, {:incomplete_post, ["Add the post text."]}} =
             Approvals.request_approval(stale)

    assert Repo.aggregate(ApprovalCard, :count) == 0
  end

  test "failed clip same-job compatibility ignores elapsed local completeness but keeps its schedule",
       ctx do
    p = failed_clip!(ctx, "existing-clip-job")
    past = DateTime.add(DateTime.utc_now(), -3600)
    p = Repo.update!(Ecto.Changeset.change(p, body: "", scheduled_at: past))
    assert {:ok, retried} = Social.retry_post(ctx.org_id, p.id, ctx.h1.id)
    assert retried.external_id == "existing-clip-job"
    assert retried.scheduled_at == past
    assert Fake.calls(:publish) == []
    assert [{:retry, [_account, "existing-clip-job"], _}] = Fake.calls(:retry)
  end

  test "failed clip same-job operation refuses any supplied schedule without writes", ctx do
    p = failed_clip!(ctx, "existing-clip-job")

    assert {:error, :existing_job_schedule_not_allowed} =
             Social.retry_post(ctx.org_id, p.id, ctx.h1.id, scheduled_at: future())

    assert Repo.get!(Post, p.id) == p
    assert Fake.calls(:publish) == []
    assert Fake.calls(:retry) == []
  end

  test "failed clip without a job requires explicit time before guarded new creation", ctx do
    p = failed_clip!(ctx, nil)
    assert {:error, :publish_time_required} = Social.retry_post(ctx.org_id, p.id, ctx.h1.id)
    assert Repo.get!(Post, p.id) == p
    at = future()
    assert {:ok, retried} = Social.retry_post(ctx.org_id, p.id, ctx.h1.id, scheduled_at: at)
    assert DateTime.compare(retried.scheduled_at, at) == :eq
    assert length(Fake.calls(:publish)) == 1
    assert Fake.calls(:retry) == []
  end

  for operation <- [:cover, :options] do
    test "#{operation} preserves draft state and cannot submit it", ctx do
      {:ok, p} = Social.create_post(ctx.org_id, ctx.a, %{body: "Unfinished"})

      result =
        case unquote(operation) do
          :cover ->
            Social.set_cover(ctx.org_id, ctx.h1.id, p.id, :clear)

          :options ->
            Social.set_platform_options(ctx.org_id, ctx.h1.id, p.id, %{
              "first_comment" => "Optional"
            })
        end

      assert {:ok, edited} = result
      assert edited.status == "draft"
      assert Repo.aggregate(ApprovalCard, :count) == 0
      assert Fake.calls(:publish) == []
    end
  end

  for status <- [:failed, :approved] do
    test "#{status} retry binds the rendered job A when the fresh read now contains B", ctx do
      post = failed_clip!(ctx, "rendered-A")

      if unquote(status) == :approved do
        Repo.update!(
          Ecto.Changeset.change(post, status: "approved", refused_reason: "media_rejected")
        )
      end

      post =
        Repo.get!(Post, post.id)
        |> Ecto.Changeset.change(external_id: "current-B")
        |> Repo.update!()

      before = Repo.get!(Post, post.id)

      result =
        if unquote(status) == :failed do
          Social.retry_post(ctx.org_id, post.id, ctx.h1.id, expected_external_id: "rendered-A")
        else
          Publishing.retry_publish(ctx.org_id, post.id, ctx.h1.id,
            expected_external_id: "rendered-A"
          )
        end

      assert result == {:error, :publish_job_changed}

      nil_result =
        if unquote(status) == :failed do
          Social.retry_post(ctx.org_id, post.id, ctx.h1.id, expected_external_id: nil)
        else
          Publishing.retry_publish(ctx.org_id, post.id, ctx.h1.id, expected_external_id: nil)
        end

      assert nil_result == {:error, :publish_job_changed}
      assert Repo.get!(Post, post.id) == before
      assert Fake.calls() == []
    end
  end
end
