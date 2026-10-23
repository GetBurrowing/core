defmodule Platform.Social.AgentDraftsTest do
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, Post}

  @home "https://www.youtube.com/@htc"

  setup do
    org_a = org_id!()
    org_b = org_id!()

    {:ok, profile} =
      Social.create_profile(org_a, %{name: "HTC", home_url: @home, space_id: channel!(org_a).id})

    {:ok, acc1} = Social.create_account(org_a, profile, %{platform: "x", handle: "@htc"})
    {:ok, acc2} = Social.create_account(org_a, profile, %{platform: "linkedin", handle: "htc"})
    {:ok, archived} = Social.create_account(org_a, profile, %{platform: "tiktok"})
    {:ok, archived} = Social.archive_account(org_a, archived)

    {:ok, other_profile} =
      Social.create_profile(org_a, %{name: "Other show", space_id: channel!(org_a).id})

    {:ok, other_acc} = Social.create_account(org_a, other_profile, %{platform: "x"})

    {:ok, profile_b} =
      Social.create_profile(org_b, %{name: "B show", space_id: channel!(org_b).id})

    {:ok, acc_b} = Social.create_account(org_b, profile_b, %{platform: "x"})

    %{
      org_a: org_a,
      org_b: org_b,
      scope: {:tenant, org_a},
      scope_b: {:tenant, org_b},
      profile: profile,
      acc1: acc1,
      acc2: acc2,
      archived: archived,
      other_acc: other_acc,
      profile_b: profile_b,
      acc_b: acc_b,
      agent: agent!(),
      user: user!()
    }
  end

  defp post_count, do: Repo.aggregate(Post, :count)
  defp clip_count, do: Repo.aggregate(Clip, :count)

  defp draft!(ctx, attrs \\ %{}) do
    {:ok, [post]} =
      AgentDrafts.create_agent_drafts(
        ctx.scope,
        ctx.profile.id,
        Map.merge(%{"account_ids" => [ctx.acc1.id], "body" => "hi"}, attrs)
      )

    post
  end

  describe "create_agent_drafts/3" do
    test "one needs_approval post per account, home_url as link, appended once", ctx do
      assert {:ok, posts} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id, ctx.acc2.id],
                 "body" => "New episode"
               })

      assert Enum.map(posts, & &1.account_id) == [ctx.acc1.id, ctx.acc2.id]

      for post <- posts do
        row = Repo.get!(Post, post.id)
        assert row.status == "needs_approval"
        assert row.link_url == @home
        assert row.body == "New episode\n" <> @home
        assert row.approved_by_user_id == nil
      end
    end

    test "the YouTube episode at start_s becomes the link; a body holding it is not re-appended",
         ctx do
      post =
        draft!(ctx, %{"episode_url" => "https://youtu.be/abc123?si=x", "start_s" => 125.7})

      assert post.link_url == "https://www.youtube.com/watch?v=abc123&t=125"
      assert post.body == "hi\nhttps://www.youtube.com/watch?v=abc123&t=125"

      body = "Clip: https://www.youtube.com/watch?v=abc123&t=30 enjoy"

      post =
        draft!(ctx, %{
          "body" => body,
          "episode_url" => "https://www.youtube.com/watch?v=abc123&t=99",
          "start_s" => 30
        })

      assert post.link_url == "https://www.youtube.com/watch?v=abc123&t=30"
      assert post.body == body
    end

    test "an explicit link_url is kept and home_url is not appended", ctx do
      post = draft!(ctx, %{"link_url" => "https://x.test/p"})
      assert post.link_url == "https://x.test/p"
      assert post.body == "hi\nhttps://x.test/p"
      refute post.body =~ @home
    end

    test "status draft is allowed; atom keys work too", ctx do
      assert {:ok, [post]} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 account_ids: [ctx.acc1.id],
                 status: "draft"
               })

      assert post.status == "draft"
    end

    test "every status past needs_approval (or unknown) is refused in code, no row", ctx do
      before = post_count()

      for status <- ~w(approved scheduled published failed bogus) do
        assert {:error, :status_not_allowed} =
                 AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   "status" => status
                 })
      end

      assert post_count() == before
    end

    test "published with no approver is :status_not_allowed from the code layer, not Postgrex",
         ctx do
      result =
        AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
          "account_ids" => [ctx.acc1.id],
          "status" => "published"
        })

      assert result == {:error, :status_not_allowed}
    end

    test "every human/publisher field is refused by name, never dropped", ctx do
      before = post_count()

      for field <- AgentDrafts.forbidden_fields() do
        assert {:error, :field_not_allowed, [^field]} =
                 AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   field => "x"
                 })
      end

      assert {:error, :field_not_allowed, ["approved_by_user_id", "approved_at"]} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 :account_ids => [ctx.acc1.id],
                 :approved_by_user_id => ctx.user.id,
                 :approved_at => DateTime.utc_now()
               })

      assert post_count() == before
    end

    test "all or none: an archived, foreign-profile or other-org account inserts nothing", ctx do
      before = post_count()

      assert {:error, :account_archived} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id, ctx.archived.id]
               })

      assert {:error, :not_found} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id, ctx.other_acc.id]
               })

      assert {:error, :not_found} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id, ctx.acc_b.id]
               })

      assert {:error, :no_accounts} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{"account_ids" => []})

      assert post_count() == before
    end

    test "all or none across a changeset failure on a later row", ctx do
      before = post_count()

      assert {:error, %Ecto.Changeset{}} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id, ctx.acc2.id],
                 "scheduled_at" => DateTime.add(DateTime.utc_now(), -60)
               })

      assert post_count() == before
    end

    test "scheduled_at must be in the future", ctx do
      assert {:error, cs} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id],
                 "scheduled_at" => "2001-01-01T00:00:00Z"
               })

      assert errors_on(cs)[:scheduled_at] == ["must be in the future"]

      future = DateTime.add(DateTime.utc_now(), 3600)
      post = draft!(ctx, %{"scheduled_at" => future})
      assert post.status == "needs_approval"
      assert post.scheduled_at
    end

    test "task, meeting and media refs must exist in the profile's org", ctx do
      before = post_count()

      for {field, value} <- [
            {"task_id", task!(ctx.org_b).id},
            {"task_id", Ecto.UUID.generate()},
            {"meeting_id", meeting!(ctx.org_b).id},
            {"media_file_ids", [file!(ctx.org_b).id]},
            {"media_file_ids", [Ecto.UUID.generate()]}
          ] do
        assert {:error, cs} =
                 AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   field => value
                 })

        assert errors_on(cs)[String.to_existing_atom(field)] == [
                 "must exist in the profile's org"
               ]
      end

      assert post_count() == before

      task = task!(ctx.org_a)
      meeting = meeting!(ctx.org_a)
      file = file!(ctx.org_a)

      post =
        draft!(ctx, %{
          "task_id" => task.id,
          "meeting_id" => meeting.id,
          "media_file_ids" => [file.id],
          "segment_ids" => ["s1"],
          "end_s" => 40
        })

      assert {post.task_id, post.meeting_id, post.media_file_ids} ==
               {task.id, meeting.id, [file.id]}
    end

    test "another org's profile is not_found, like a missing id; a client org_id never widens",
         ctx do
      before = post_count()

      for scope <- [ctx.scope_b, ctx.org_b] do
        assert {:error, :not_found} =
                 AgentDrafts.create_agent_drafts(scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   "org_id" => ctx.org_a
                 })
      end

      assert {:error, :not_found} =
               AgentDrafts.create_agent_drafts(ctx.scope, Ecto.UUID.generate(), %{
                 "account_ids" => [ctx.acc1.id]
               })

      assert post_count() == before
    end

    test ":root may draft in any org", ctx do
      assert {:ok, [post]} =
               AgentDrafts.create_agent_drafts(:root, ctx.profile_b.id, %{
                 "account_ids" => [ctx.acc_b.id]
               })

      assert post.status == "needs_approval"
    end
  end

  describe "update_agent_draft/3" do
    test "edits a needs_approval post's fields", ctx do
      post = draft!(ctx)

      assert {:ok, updated} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"body" => "edited"})

      assert updated.body == "edited"
      assert updated.status == "needs_approval"
    end

    test "draft -> needs_approval is allowed; needs_approval -> draft is refused", ctx do
      post = draft!(ctx, %{"status" => "draft"})

      assert {:ok, %{status: "needs_approval"}} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"status" => "needs_approval"})

      before = Repo.get!(Post, post.id)

      assert {:error, :status_not_allowed} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{
                 "status" => "draft",
                 "body" => "x"
               })

      assert Repo.get!(Post, post.id) == before
    end

    test "status past needs_approval is refused and the post stays needs_approval", ctx do
      post = draft!(ctx)
      before = Repo.get!(Post, post.id)

      for status <- ~w(approved scheduled published failed) do
        assert {:error, :status_not_allowed} =
                 AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"status" => status})
      end

      assert Repo.get!(Post, post.id) == before
    end

    test "draft -> scheduled is refused", ctx do
      post = draft!(ctx, %{"status" => "draft"})

      assert {:error, :status_not_allowed} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"status" => "scheduled"})

      assert Repo.get!(Post, post.id).status == "draft"
    end

    test "a human-approved post is :post_locked (re-checked under the lock), row identical",
         ctx do
      post = draft!(ctx)
      make_approver!(ctx.org_a, ctx.profile, ctx.user)
      {:ok, _} = Social.approve_post(ctx.org_a, post.id, ctx.user.id)
      before = Repo.get!(Post, post.id)
      assert before.status == "approved"

      assert {:error, :post_locked} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"body" => "sneaky"})

      assert {:error, :post_locked} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"status" => "needs_approval"})

      assert Repo.get!(Post, post.id) == before
    end

    test "published and failed posts are :post_locked too", ctx do
      for status <- ~w(published failed) do
        post = draft!(ctx)

        Repo.update_all(from(p in Post, where: p.id == ^post.id),
          set: [status: status, approved_by_user_id: ctx.user.id, approved_at: DateTime.utc_now()]
        )

        before = Repo.get!(Post, post.id)

        assert {:error, :post_locked} =
                 AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"body" => "x"})

        assert Repo.get!(Post, post.id) == before
      end
    end

    test "forbidden fields are refused by name and the row is unchanged", ctx do
      post = draft!(ctx)
      before = Repo.get!(Post, post.id)

      for field <- AgentDrafts.forbidden_fields() do
        assert {:error, :field_not_allowed, [^field]} =
                 AgentDrafts.update_agent_draft(ctx.scope, post.id, %{field => "x", "body" => "y"})
      end

      assert Repo.get!(Post, post.id) == before
    end

    test "rejection fields are never touched by an agent update", ctx do
      post = draft!(ctx)
      at = DateTime.utc_now()

      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [rejection_reason: "too long", rejected_at: at]
      )

      assert {:ok, _} = AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"body" => "shorter"})
      row = Repo.get!(Post, post.id)
      assert row.rejection_reason == "too long"
      assert row.rejected_at == at
    end

    test "cross-org update is not_found and the row is unchanged", ctx do
      post = draft!(ctx)
      before = Repo.get!(Post, post.id)

      assert {:error, :not_found} =
               AgentDrafts.update_agent_draft(ctx.scope_b, post.id, %{
                 "body" => "pwned",
                 "org_id" => ctx.org_a
               })

      assert {:error, :not_found} =
               AgentDrafts.update_agent_draft(ctx.scope, Ecto.UUID.generate(), %{"body" => "x"})

      assert Repo.get!(Post, post.id) == before
    end

    test "cross-org refs on update are refused", ctx do
      post = draft!(ctx)

      assert {:error, cs} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{
                 "task_id" => task!(ctx.org_b).id
               })

      assert errors_on(cs)[:task_id] == ["must exist in the profile's org"]
    end
  end

  describe "list_posts with a profile filter" do
    test "filters by profile and status and carries the rejection and error fields", ctx do
      post = draft!(ctx)
      _draft = draft!(ctx, %{"status" => "draft"})

      {:ok, [_other]} =
        AgentDrafts.create_agent_drafts(:root, ctx.profile_b.id, %{
          "account_ids" => [ctx.acc_b.id]
        })

      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [rejection_reason: "off brand", rejected_at: DateTime.utc_now()]
      )

      assert [row] =
               Social.list_posts(ctx.scope, profile_id: ctx.profile.id, status: "needs_approval")

      assert row.id == post.id
      assert row.rejection_reason == "off brand"
      assert row.rejected_at
      assert Map.has_key?(row, :error)

      assert length(Social.list_posts(ctx.scope, profile_id: ctx.profile.id)) == 2
      assert Social.list_posts(ctx.scope_b, profile_id: ctx.profile.id) == []
      assert Social.list_posts(ctx.scope, profile_id: "nope") == []
    end
  end

  describe "propose_clip/3" do
    @good %{
      "source_url" => "https://youtu.be/abc123",
      "start_s" => 10,
      "end_s" => 40,
      "caption" => "the bit",
      "speaker" => "Jo"
    }

    test "creates one candidate clip under the profile, whatever status is sent", ctx do
      before = clip_count()

      assert {:ok, clip} =
               AgentDrafts.propose_clip(
                 ctx.scope,
                 ctx.profile.id,
                 Map.put(@good, "status", "rendered")
               )

      assert clip_count() == before + 1
      row = Repo.get!(Clip, clip.id)

      assert {row.profile_id, row.status, row.start_s, row.end_s} ==
               {ctx.profile.id, "candidate", 10.0, 40.0}

      assert {row.caption, row.speaker} == {"the bit", "Jo"}
    end

    test "bad ranges and urls are refused before the DB; no row", ctx do
      before = clip_count()

      for {attrs, error} <- [
            {%{"start_s" => 10, "end_s" => 10}, :invalid_range},
            {%{"start_s" => 10, "end_s" => 5}, :invalid_range},
            {%{"start_s" => -1, "end_s" => 5}, :invalid_range},
            {%{"end_s" => nil}, :invalid_range},
            {%{"start_s" => "10"}, :invalid_range},
            {%{"source_url" => nil}, :invalid_source_url},
            {%{"source_url" => "ftp://x.test/a"}, :invalid_source_url},
            {%{"source_url" => "not a url"}, :invalid_source_url}
          ] do
        assert {:error, ^error} =
                 AgentDrafts.propose_clip(ctx.scope, ctx.profile.id, Map.merge(@good, attrs))
      end

      assert {:error, :invalid_source_url} =
               AgentDrafts.propose_clip(
                 ctx.scope,
                 ctx.profile.id,
                 Map.delete(@good, "source_url")
               )

      assert clip_count() == before
    end

    test "another org's profile is not_found", ctx do
      before = clip_count()
      assert {:error, :not_found} = AgentDrafts.propose_clip(ctx.scope_b, ctx.profile.id, @good)
      assert clip_count() == before
    end
  end

  describe "visible_orgs/1 (the RBAC swap point)" do
    test "root sees all, a tenant its own org, anything else nothing", ctx do
      assert Social.visible_orgs(:root) == :all
      assert Social.visible_orgs({:tenant, ctx.org_a}) == [ctx.org_a]
      assert Social.visible_orgs(ctx.org_a) == [ctx.org_a]
      assert Social.visible_orgs(nil) == []
      assert Social.visible_orgs({:tenant, "nope"}) == []
      assert Social.org_visible?(ctx.scope, ctx.org_a)
      refute Social.org_visible?(ctx.scope, ctx.org_b)
      assert Social.org_visible?(:root, ctx.org_b)
      refute Social.org_visible?(:root, "nope")
    end
  end

  # Task 01a165ec stage 2: the agent path runs the same cover rule as the
  # human path (Platform.Social.Cover).
  describe "cover" do
    setup ctx do
      video = media_file!(ctx.org_a, "video/mp4")

      %{
        video: video,
        png: media_file!(ctx.org_a, "image/png"),
        video_attrs: %{
          "media_file_ids" => [video.id],
          "media_meta" => %{video.id => %{"duration_s" => 42.5}}
        }
      }
    end

    defp cover_draft!(ctx, attrs) do
      # media_meta is not agent-castable: seed it through the general path.
      post = draft!(ctx, %{"media_file_ids" => [ctx.video.id], "status" => "draft"})

      {:ok, post} =
        Social.update_post(ctx.org_a, post, %{media_meta: ctx.video_attrs["media_meta"]})

      if attrs == %{},
        do: post,
        else: elem(AgentDrafts.update_agent_draft(ctx.scope, post.id, attrs), 1)
    end

    defp cover_errors({:error, %Ecto.Changeset{} = cs}), do: errors_on(cs)

    test "create and update round-trip both fields, one at a time", ctx do
      assert {:ok, [post]} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.acc1.id],
                 "body" => "clip",
                 "media_file_ids" => [ctx.video.id],
                 "cover_file_id" => ctx.png.id
               })

      assert post.cover_file_id == ctx.png.id

      post = cover_draft!(ctx, %{})

      assert {:ok, %Post{cover_offset_ms: 2_000, cover_file_id: nil}} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"cover_offset_ms" => 2_000})

      assert {:ok, %Post{cover_file_id: png_id, cover_offset_ms: nil}} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"cover_file_id" => ctx.png.id})

      assert png_id == ctx.png.id

      assert {:ok, %Post{cover_file_id: nil, cover_offset_ms: nil}} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{
                 "cover_file_id" => nil,
                 "cover_offset_ms" => nil
               })
    end

    test "surfaces the same refusals as the human path", ctx do
      post = cover_draft!(ctx, %{})
      pdf = media_file!(ctx.org_a, "application/pdf")
      foreign = media_file!(ctx.org_b, "image/png")
      update = &AgentDrafts.update_agent_draft(ctx.scope, post.id, &1)

      assert %{cover_file_id: ["cover must be a JPG or PNG image"]} =
               cover_errors(update.(%{"cover_file_id" => pdf.id}))

      assert %{cover_file_id: ["cover must exist in the profile's org"]} =
               cover_errors(update.(%{"cover_file_id" => foreign.id}))

      assert %{cover_offset_ms: ["cover frame is past the end of the video (0:42)"]} =
               cover_errors(update.(%{"cover_offset_ms" => 50_000}))

      assert %{cover_file_id: ["choose either an uploaded cover or a frame, not both"]} =
               cover_errors(update.(%{"cover_file_id" => ctx.png.id, "cover_offset_ms" => 1}))

      # No duration known: a fresh video draft without media_meta.
      assert %{cover_offset_ms: ["the video's duration is unknown, so a frame cannot be checked"]} =
               cover_errors(
                 AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   "media_file_ids" => [ctx.video.id],
                   "cover_offset_ms" => 1_000
                 })
               )

      assert %{cover_file_id: ["a cover applies only to a video post"]} =
               cover_errors(
                 AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                   "account_ids" => [ctx.acc1.id],
                   "media_file_ids" => [ctx.png.id],
                   "cover_file_id" => ctx.png.id
                 })
               )

      assert %Post{cover_file_id: nil, cover_offset_ms: nil} = Repo.get!(Post, post.id)
    end

    test "cover_error is the publisher's: refused by name", ctx do
      post = cover_draft!(ctx, %{})

      assert {:error, :field_not_allowed, ["cover_error"]} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"cover_error" => "x"})
    end
  end
end
